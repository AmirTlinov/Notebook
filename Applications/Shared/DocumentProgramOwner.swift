#if os(iOS)
import Foundation
import NotebookCore
import UIKit
import WebKit

/// Owns executable blocks, their state applications and checkpoint completion.
/// Paper preparation reads this owner but never joins an unrelated checkpoint.
@MainActor
final class DocumentProgramOwner {
  struct PausedProgram {
    let programIdentity: DocumentProgramIdentity
    let value: JSONValue
    let size: CGSize
    let raster: RasterLease
  }
  private struct Context {
    let input: DocumentPagePresentation
    let layout: DocumentLayoutRecord
    let pages: Set<Int>
    let currentPage: Int?
    let visibleIDs: Set<String>
    let preparationPage: Int?
    let blocked: Bool
    let contacts: Set<String>
    let densities: [String: Double]
  }
  private struct Job {
    let id: UUID
    let task: Task<Void, Never>
    var preservesRuntime = false
  }
  private struct ReplacementState {
    let identity: DocumentProgramIdentity
    let value: JSONValue
    let version: ContentFieldVersion?
  }
  private struct Application {
    let id: UUID
    let version: ContentFieldVersion?
    let task: Task<Void, Never>
  }
  let documentID: UUID
  let resources: SceneRenderResources
  private var context: Context?
  private(set) var runtimes: [String: DocumentBlockRuntime] = [:]
  private var pausedPrograms: [String: PausedProgram] = [:]
  private(set) var liveIDs: Set<String> = []
  private(set) var retiringIDs: Set<String> = []
  private var previewID: String?
  private(set) var pauseFailures: [String: String] = [:]
  private var jobs: [String: Job] = [:]
  private var applications: [String: Application] = [:]
  // A saved geometry handoff lasts only until the replacement is created.
  // The old presentation input may not yet contain the writer's receipt.
  private var replacementStates: [String: ReplacementState] = [:]
  private var retirementAttempts: [String: String] = [:]
  private var stopped = false
  private var boundaryTask: (id: UUID, task: Task<Bool, Never>)?
  private var boundaryGeneration: UInt64 = 0
  private var boundarySuspendsPrograms = false
  private var parkedForReturn = false
  private var parkedPrograms: Set<String> = []
  private var returnEvictions: Set<String> = []
  var onChange: () -> Void = {}
  var onMount: (WKWebView, CGSize) -> Void = { _, _ in }
  var onLink: (String, DocumentProgramIdentity, String) -> Void = { _, _, _ in }
  var hasFocus: Bool { runtimes.values.contains { $0.focused } }
  var visibleIDs: Set<String> { context?.visibleIDs ?? [] }
  var retainedIDs: Set<String> {
    guard let context else { return [] }
    let ids = Set(context.input.document.blocks.filter { $0.kind == .interactive }.map(\.id))
    return context.layout.blockIDs(on: context.pages).intersection(ids)
  }

  init(documentID: UUID, resources: SceneRenderResources) {
    self.documentID = documentID; self.resources = resources
  }

  /// Freeze the authored model immediately, even without pool pressure.
  /// A hidden source editor or confirmed return context keeps its heap, not its clock.
  func parkForReturn() {
    guard !parkedForReturn, !stopped else { return }
    parkedForReturn = true
    for (id, runtime) in runtimes {
      if !runtime.ready, runtime.webView == nil { retireImmediately(id, runtime: runtime); continue }
      liveIDs.remove(id)
      offerReturnReclamation(id, runtime: runtime)
      if jobs[id] == nil { startCheckpoint(id, runtime: runtime, keepsPicture: false, keepsRuntime: true) }
    }
  }

  private func offerReturnReclamation(_ id: String, runtime: DocumentBlockRuntime) {
    runtime.offerReturnReclamation { [weak self, weak runtime] in
      guard let self, let runtime, parkedForReturn, runtimes[id] === runtime else { return }
      if parkedPrograms.contains(id), pauseFailures[id] == nil { retireImmediately(id, runtime: runtime); return }
      returnEvictions.insert(id)
      if jobs[id] == nil { startCheckpoint(id, runtime: runtime, keepsPicture: false) }
    }
  }

  func resumeFromReturn() {
    guard parkedForReturn else { return }
    parkedForReturn = false; returnEvictions.removeAll()
    for (block, runtime) in runtimes {
      runtime.offerReturnReclamation(nil)
      // A quick return cannot cancel the durable-write boundary and restart
      // the clock before that write is accepted.
      guard jobs[block] == nil, parkedPrograms.remove(block) != nil else { continue }
      if pauseFailures[block] != nil {
        startCheckpoint(block, runtime: runtime, keepsPicture: false, keepsRuntime: true)
        continue
      }
      _ = startResume(block, runtime: runtime)
    }
    reconcile(); onChange()
  }

  func update(input: DocumentPagePresentation, layout: DocumentLayoutRecord, pages: Set<Int>,
    currentPage: Int?, visibleIDs: Set<String>, preparationPage: Int?, blocked: Bool, contacts: Set<String>, densities: [String: Double]) {
    guard !stopped else { return }
    context = .init(input: input, layout: layout, pages: pages, currentPage: currentPage,
      visibleIDs: visibleIDs, preparationPage: preparationPage, blocked: blocked, contacts: contacts, densities: densities)
    reconcile()
  }

  func paused(_ id: String) -> PausedProgram? {
    guard let saved = pausedPrograms[id], let context,
      context.input.document.programIdentity(blockID: id) == saved.programIdentity,
      let block = context.input.document.blocks.first(where: { $0.id == id }),
      let region = context.layout.regions.first(where: { $0.id == id }),
      abs(saved.size.width - region.frame.width) < 1 / 32, saved.size.height == block.height,
      (context.input.state.records.first(where: { $0.id == id })?.value ?? block.initialState) == saved.value else { return nil }
    return saved
  }

  func presents(_ id: String) -> Bool {
    guard pauseFailures[id] == nil, !retiringIDs.contains(id) else { return false }
    guard let input = context?.input, let block = input.document.blocks.first(where: { $0.id == id }) else { return false }
    if paused(id) != nil { return true }
    guard let runtime = runtimes[id], runtime.programIdentity == input.document.programIdentity(blockID: id) else { return false }
    let record = input.state.records.first { $0.id == id }
    return runtime.presents(record?.value ?? block.initialState, version: record?.valueVersion)
  }

  func retry(_ id: String) {
    guard retainedIDs.contains(id) else { return }
    let retryCheckpoint = pauseFailures.removeValue(forKey: id) != nil && parkedPrograms.remove(id) != nil
    retirementAttempts[id] = nil
    // Retry may finish a failed freeze/write while execution is suspended,
    // but an author reload still needs an explicit return to running.
    if !boundarySuspendsPrograms { runtimes[id]?.retry() }
    if retryCheckpoint, let runtime = runtimes[id], jobs[id] == nil {
      startCheckpoint(id, runtime: runtime, keepsPicture: false, keepsRuntime: true)
    }
    reconcile(); onChange()
  }

  func blurFocused() async {
    for runtime in runtimes.values where runtime.focused { await runtime.blur() }
  }

  private func reconcile() {
    guard !stopped, !parkedForReturn, !boundarySuspendsPrograms, let context else { return }
    let input = context.input, retained = retainedIDs
    replacementStates = replacementStates.filter { id, handoff in
      input.document.blocks.contains { $0.id == id && $0.kind == .interactive }
        && input.document.programIdentity(blockID: id) == handoff.identity
    }
    pausedPrograms = pausedPrograms.filter { retained.contains($0.key) && paused($0.key) != nil }
    pauseFailures = pauseFailures.filter { retained.contains($0.key) }
    let currentIDs = context.layout.blockIDs(on: [context.currentPage ?? input.pageIndex])
    let blocks = input.document.blocks.filter { $0.kind == .interactive && retained.contains($0.id) }
    let ordered = (blocks.filter { currentIDs.contains($0.id) } + blocks.filter { !currentIDs.contains($0.id) }).map(\.id)
    var desired = context.visibleIDs.intersection(retained)
    desired.formUnion(runtimes.filter { $0.value.focused || context.contacts.contains($0.key) }.map(\.key))
    if !context.blocked { liveIDs = desired }
    let previewPages = context.preparationPage.map { Set([$0]) } ?? context.pages.subtracting(context.currentPage.map { [$0] } ?? [])
    let previewCandidates = context.layout.blockIDs(on: previewPages).intersection(retained)
    if let previewID, context.blocked || !previewCandidates.contains(previewID) || liveIDs.contains(previewID)
      || runtimes[previewID]?.failure != nil { self.previewID = nil }
    if previewID == nil, !context.blocked {
      previewID = ordered.first { previewCandidates.contains($0) && !liveIDs.contains($0) && paused($0) == nil
        && pauseFailures[$0] == nil && runtimes[$0]?.failure == nil }
    }
    var demanded = liveIDs
    if let previewID { demanded.insert(previewID) }
    for block in blocks where demanded.contains(block.id) {
      let id = block.id
      guard let region = context.layout.regions.first(where: { $0.id == id }) else { continue }
      let programIdentity = input.document.programIdentity(blockID: id)
      if let old = runtimes[id], !old.matches(block, programIdentity: programIdentity, width: region.frame.width) {
        guard !context.blocked, !old.focused, !context.contacts.contains(id) else { continue }
        if old.programIdentity != programIdentity { retireImmediately(id, runtime: old) }
        else {
          // Geometry does not revoke this author's already accepted commits.
          // Keep the same executor and its Retry until the existing boundary
          // has saved it; only then may the new viewport replace its heap.
          if old.failure == nil, jobs[id] == nil, pauseFailures[id] == nil {
            startCheckpoint(id, runtime: old, keepsPicture: false, keepsRuntime: true)
          }
          continue
        }
      }
      let record = input.state.records.first { $0.id == id }
      var state = record?.value ?? block.initialState, stateVersion = record?.valueVersion
      if runtimes[id] == nil {
        if let handoff = replacementStates.removeValue(forKey: id), handoff.identity == programIdentity {
          // Same causal rule as runtime.apply: only a strictly older input is
          // superseded. Equal, newer and concurrent input remain authoritative.
          let inputIsOlder = if let version = stateVersion {
            handoff.version.map { $0.includes(version) && !version.includes($0) } ?? false
          } else { true }
          if inputIsOlder { state = handoff.value; stateVersion = handoff.version }
        }
        let runtime = DocumentBlockRuntime(documentID: documentID, block: block, programIdentity: programIdentity,
          value: state, stateVersion: stateVersion, width: region.frame.width, resources: resources, programStore: input.programStore)
        runtime.onChange = { [weak self, weak runtime] in
          guard let self, let runtime, runtimes[id] === runtime else { return }
          reconcile(); onChange()
        }
        runtime.onFocus = { [weak self] _ in self?.reconcile(); self?.onChange() }
        // This accepted runtime addresses the captured source even while its
        // presentation retires. The app/SQLite writer fences a changed program.
        let writeState = input.onStateChange
        runtime.onStateChange = { value in try await writeState(id, value) }
        runtime.onStateDrained = input.onStateDrained
        runtime.onStateCheckpoint = { [weak self, weak runtime] value, stateVersion in
          guard let self, let runtime, runtimes[id] === runtime, let input = self.context?.input,
            input.document.programIdentity(blockID: id) == runtime.programIdentity else { return nil }
          return try await input.onStateCheckpoint(id, value, runtime.programIdentity, stateVersion)
        }
        runtime.onMount = { [weak self] web, size in self?.onMount(web, size) }
        runtime.onLink = { [weak self, weak runtime] href in
          guard let self, let runtime, runtimes[id] === runtime else { return }
          onLink(id, runtime.programIdentity, href)
        }
        runtimes[id] = runtime
      }
      guard let runtime = runtimes[id] else { continue }
      runtime.requiresStateAcceptance = true
      runtime.start(priority: liveIDs.contains(id) ? .liveProgram : .visible)
      if !runtime.focused, context.contacts.isEmpty, jobs[id] == nil, pauseFailures[id] == nil,
        applications[id]?.version != stateVersion || applications[id] == nil {
        apply(state, version: stateVersion, to: runtime)
      }
    }
    for (id, runtime) in runtimes {
      let outside = !retained.contains(id)
      // A queued acquisition has no author yet. A created WebKit may already
      // have accepted state before ready, so it leaves through the same drain.
      if !demanded.contains(id), !runtime.ready, runtime.failure == nil, !context.blocked, !runtime.focused, !context.contacts.contains(id) {
        if runtime.webView == nil || !input.document.blocks.contains(where: { $0.id == id })
          || input.document.programIdentity(blockID: id) != runtime.programIdentity { retireImmediately(id, runtime: runtime) }
        else if jobs[id] == nil { startCheckpoint(id, runtime: runtime, keepsPicture: false) }
        continue
      }
      if outside && (!input.document.blocks.contains { $0.id == id }
        || input.document.programIdentity(blockID: id) != runtime.programIdentity) {
        if !context.blocked, !runtime.focused, !context.contacts.contains(id) { retireImmediately(id, runtime: runtime) }
        continue
      }
      let shouldRetire = outside || !liveIDs.contains(id)
      if !shouldRetire || context.blocked || runtime.focused || context.contacts.contains(id) {
        if jobs[id]?.preservesRuntime != true { jobs[id]?.task.cancel() }
        continue
      }
      guard runtime.ready, jobs[id] == nil, pauseFailures[id] == nil else { continue }
      let attempt = input.token + "|" + retained.sorted().joined(separator: "|")
      if outside, retirementAttempts[id] == attempt { continue }
      if outside { retirementAttempts[id] = attempt }
      startCheckpoint(id, runtime: runtime, keepsPicture: !outside)
    }
  }

  private func apply(_ state: JSONValue, version: ContentFieldVersion?, to runtime: DocumentBlockRuntime) {
    let block = runtime.block.id, id = UUID()
    applications[block]?.task.cancel()
    let task = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      defer { if applications[block]?.id == id { applications[block] = nil } }
      guard !Task.isCancelled, !stopped, runtimes[block] === runtime else { return }
      try? await runtime.apply(state, stateVersion: version)
    }
    applications[block] = .init(id: id, version: version, task: task)
  }

  private func startCheckpoint(_ block: String, runtime: DocumentBlockRuntime, keepsPicture: Bool, keepsRuntime: Bool = false) {
    let id = UUID()
    applications[block]?.task.cancel(); applications[block] = nil
    retiringIDs.insert(block)
    let task = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      defer {
        if jobs[block]?.id == id { jobs[block] = nil; retiringIDs.remove(block) }
        if runtimes[block] === runtime {
          runtime.cancelReturnReclamation()
          if parkedForReturn {
            if parkedPrograms.contains(block) { offerReturnReclamation(block, runtime: runtime) }
            else if jobs[block] == nil {
              startCheckpoint(block, runtime: runtime, keepsPicture: false, keepsRuntime: true)
            }
          }
        }
        if !stopped { reconcile(); onChange() }
      }
      guard let context = self.context else { return }
      var pixels: RasterLease?
      defer { pixels?.release() }
      do {
        if keepsRuntime { await runtime.blur() }
        let value = try await runtime.checkpoint()
        try Task.checkCancellation()
        if keepsPicture {
          let width = max(1, Int(ceil(runtime.blockWidth * (context.densities[block] ?? 2))))
          do { pixels = try await runtime.capture(sourceOffset: 0, height: runtime.block.height, pixelWidth: width) }
          catch SceneRenderError.resourceLimit {
            // An offscreen former input owner may keep a useful image, but its
            // optional pixels cannot pin the executor ahead of visible work.
            // A requested cut still owns its capture and explicit failure.
            guard self.previewID != block, !self.liveIDs.contains(block) else { throw SceneRenderError.resourceLimit }
          }
        }
        guard !stopped, runtimes[block] === runtime else { return }
        if let latest = self.context, !latest.blocked, !runtime.focused,
          !latest.contacts.contains(block),
          latest.input.document.programIdentity(blockID: block) == runtime.programIdentity,
          let source = latest.input.document.blocks.first(where: { $0.id == block }),
          let region = latest.layout.regions.first(where: { $0.id == block }),
          !runtime.matches(source, programIdentity: runtime.programIdentity, width: region.frame.width) {
          // Recheck after the write: the layout may have returned while this
          // boundary was pending, or the source may have been superseded.
          let handoff = ReplacementState(identity: runtime.programIdentity, value: value,
            version: runtime.acceptedStateVersion)
          retireImmediately(block, runtime: runtime)
          replacementStates[block] = handoff
          return
        }
        if keepsRuntime {
          pauseFailures[block] = nil
          if parkedForReturn, !returnEvictions.contains(block) {
            parkedPrograms.insert(block)
          } else if !parkedForReturn {
            parkedPrograms.remove(block)
            guard await resume(block, runtime: runtime) else { return }
          } else { retireImmediately(block, runtime: runtime) }
          return
        }
        guard let latest = self.context,
          !latest.blocked, !latest.contacts.contains(block), !runtime.focused, !liveIDs.contains(block),
          latest.input.document.programIdentity(blockID: block) == runtime.programIdentity,
          runtime.value == value, keepsPicture || parkedForReturn || !retainedIDs.contains(block) || !runtime.ready else {
          await resume(block, runtime: runtime); return
        }
        if parkedForReturn, !returnEvictions.contains(block) {
          parkedPrograms.insert(block)
          return
        }
        if let pixels, keepsPicture {
          pausedPrograms[block] = .init(programIdentity: runtime.programIdentity, value: value,
            size: .init(width: runtime.blockWidth, height: runtime.block.height), raster: pixels)
          self.previewID = nil
        }
        pixels = nil
        runtimes[block] = nil; retiringIDs.remove(block)
        onChange() // Replace the viewport before releasing its native lease.
        runtime.stop()
      } catch {
        if !stopped, runtimes[block] === runtime {
          if error is NotebookProgramCheckpointError {
            retireImmediately(block, runtime: runtime); return
          }
          if error is CancellationError {
            await resume(block, runtime: runtime)
          } else {
            // A failed author hook or writer retains the same suspended heap.
            // Only explicit Retry may continue its unfinished lifecycle stage.
            parkedPrograms.insert(block)
            pauseFailures[block] = String(describing: error)
          }
        }
      }
    }
    jobs[block] = .init(id: id, task: task, preservesRuntime: keepsRuntime)
  }

  /// Explicit background/close boundary, independent of page raster work.
  /// Each admitted runtime finishes its own author model; a hung neighbour
  /// cannot serialize the remaining programs behind its deadline.
  func checkpointAll(resume: Bool) async -> Bool {
    guard !stopped else { return false }
    boundaryGeneration &+= 1
    let request = boundaryGeneration
    boundarySuspendsPrograms = true
    let failuresAtAdmission = Set(pauseFailures.keys)
    let applying = applications.values.map(\.task)
    applying.forEach { $0.cancel() }; applications.removeAll()
    let boundary: (id: UUID, task: Task<Bool, Never>)
    if let running = boundaryTask { boundary = running }
    else {
      let task = Task { @MainActor [self] in
        // An already admitted state application finishes before the freeze;
        // cancellation cannot leave a late WebKit write beyond this boundary.
        for application in applying { await application.value }
        let tasks = runtimes.map { block, runtime in Task { @MainActor [self] in
          if let job = jobs[block] {
            await job.task.value
            if pauseFailures[block] != nil { return false }
          }
          if pauseFailures[block] != nil, !failuresAtAdmission.contains(block) { return false }
          guard !stopped, runtimes[block] === runtime, context != nil else { return true }
          do {
            await runtime.blur()
            _ = try await runtime.checkpoint()
            return true
          } catch {
            if error is NotebookProgramCheckpointError { return true }
            parkedPrograms.insert(block); pauseFailures[block] = String(describing: error)
            onChange(); return false
          }
        } }
        var accepted = true
        for task in tasks { if !(await task.value) { accepted = false } }
        return accepted
      }
      boundary = (UUID(), task); boundaryTask = boundary
    }
    let accepted = await boundary.task.value
    if boundaryTask?.id == boundary.id { boundaryTask = nil }
    guard !stopped else { return false }
    // A later pause beats an older caller's automatic resume, and a later
    // explicit resume joins this same checkpoint rather than racing it.
    if resume, boundaryGeneration == request { return await resumeAll() && accepted }
    return accepted
  }

  @discardableResult
  func resumeAll() async -> Bool {
    guard !stopped else { return false }
    boundaryGeneration &+= 1
    let request = boundaryGeneration
    if let boundary = boundaryTask {
      _ = await boundary.task.value
      if boundaryTask?.id == boundary.id { boundaryTask = nil }
    }
    guard !stopped, boundaryGeneration == request else { return false }
    boundarySuspendsPrograms = false
    guard !parkedForReturn else { return pauseFailures.isEmpty }
    for (block, runtime) in runtimes where !parkedPrograms.contains(block) && pauseFailures[block] == nil {
      guard !stopped, boundaryGeneration == request, !parkedForReturn else { return false }
      while runtimes[block] === runtime, let job = jobs[block] {
        await job.task.value
        guard !stopped, boundaryGeneration == request, !parkedForReturn else { return false }
      }
      if runtimes[block] === runtime { await startResume(block, runtime: runtime).value }
    }
    guard !stopped, boundaryGeneration == request else { return false }
    reconcile(); onChange()
    return pauseFailures.isEmpty
  }

  /// Releasing attention is not a new foreground intent. It must respect the
  /// global fence and still refer to the exact pause it originally retained.
  func resumeAfterAttention(_ block: String, runtime: DocumentBlockRuntime, attentionID: UUID) async {
    func permitted() -> Bool {
      !stopped && !boundarySuspendsPrograms && !parkedForReturn && runtimes[block] === runtime
        && runtime.attentionPauseID == attentionID && pauseFailures[block] == nil
    }
    guard permitted() else { return }
    while let job = jobs[block] {
      await job.task.value
      guard permitted() else { return }
    }
    await startResume(block, runtime: runtime, attentionID: attentionID).value
  }

  /// Both explicit resume routes use the existing per-program lifecycle job.
  /// A newly requested checkpoint therefore waits for an admitted resume.
  private func startResume(_ block: String, runtime: DocumentBlockRuntime, attentionID: UUID? = nil) -> Task<Void, Never> {
    let id = UUID()
    let task = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      if attentionID == nil || runtime.attentionPauseID == attentionID { await resume(block, runtime: runtime) }
      if jobs[block]?.id == id { jobs[block] = nil; retiringIDs.remove(block) }
      if !stopped, runtimes[block] === runtime {
        if parkedForReturn { startCheckpoint(block, runtime: runtime, keepsPicture: false, keepsRuntime: true) }
        else { reconcile() }
        onChange()
      }
    }
    jobs[block] = .init(id: id, task: task, preservesRuntime: true)
    return task
  }

  @discardableResult
  private func resume(_ block: String, runtime: DocumentBlockRuntime) async -> Bool {
    guard !stopped, !boundarySuspendsPrograms, !parkedForReturn, runtimes[block] === runtime else { return false }
    let resumed = await runtime.resume()
    guard !stopped, !boundarySuspendsPrograms, !parkedForReturn, runtimes[block] === runtime else { return false }
    if !resumed {
      parkedPrograms.insert(block); pauseFailures[block] = "program_resume_failed"
      onChange()
    }
    return resumed
  }

  private func retireImmediately(_ id: String, runtime: DocumentBlockRuntime) {
    jobs[id]?.task.cancel(); applications[id]?.task.cancel(); applications[id] = nil
    runtime.stop(); runtimes[id] = nil; retiringIDs.remove(id); retirementAttempts[id] = nil
    parkedPrograms.remove(id); returnEvictions.remove(id)
    pauseFailures[id] = nil; replacementStates[id] = nil
  }

  func stop() {
    guard !stopped else { return }; stopped = true
    boundaryGeneration &+= 1; boundarySuspendsPrograms = true
    boundaryTask?.task.cancel(); boundaryTask = nil
    jobs.values.forEach { $0.task.cancel() }; jobs.removeAll()
    applications.values.forEach { $0.task.cancel() }; applications.removeAll()
    runtimes.values.forEach { $0.stop() }; runtimes.removeAll(); pausedPrograms.removeAll(); context = nil
    parkedPrograms.removeAll(); returnEvictions.removeAll()
    replacementStates.removeAll()
  }
  isolated deinit { stop() }
}
#endif
