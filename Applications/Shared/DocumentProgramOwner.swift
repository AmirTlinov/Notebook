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
    let sourceBasis: String
    let value: JSONValue
    let size: CGSize
    let raster: RasterLease
  }
  private struct Context {
    let input: DocumentPagePresentation
    let layout: DocumentLayoutRecord
    let programs: [DocumentProgramSource]
    let programsByID: [String: DocumentProgramSource]
    let recordsByID: [String: DocumentStateRecord]
    let retainedIDs: Set<String>
    let unresolvedProgramIDs: Set<String>
    let pages: Set<Int>
    let currentPage: Int?
    let visibleIDs: Set<String>
    let preparationPage: Int?
    let blocked: Bool
    let contacts: Set<String>
    let densities: [String: Double]
  }
  private struct Job {
    enum Kind { case checkpoint(keepsRuntime: Bool), resume }
    let id: UUID
    let task: Task<Void, Never>
    let kind: Kind
    var preservesRuntime: Bool {
      switch kind { case .checkpoint(let keepsRuntime): keepsRuntime; case .resume: true }
    }
    var isCheckpoint: Bool { if case .checkpoint = kind { true } else { false } }
  }
  private struct Application {
    let id: UUID
    let version: ContentFieldVersion?
    let task: Task<Void, Never>
  }
  /// Everything that must end with this exact heap lives in its slot. Removing
  /// the slot makes completion from an older source unable to change its successor.
  private final class Slot {
    let runtime: DocumentBlockRuntime
    var job: Job?
    var application: Application?
    var pauseFailure: String?
    var retirementAttempt: String?
    var parked = false
    var returnEviction = false
    init(_ runtime: DocumentBlockRuntime) { self.runtime = runtime }
  }
  let documentID: UUID
  let resources: SceneRenderResources
  private var context: Context?
  private var slots: [String: Slot] = [:]
  private var pausedPrograms: [String: PausedProgram] = [:]
  private(set) var liveIDs: Set<String> = []
  private var previewID: String?
  private var stopped = false
  private var boundaryTask: (id: UUID, task: Task<Bool, Never>)?
  private var boundaryGeneration: UInt64 = 0
  private var boundarySuspendsPrograms = false
  private var parkedForReturn = false
  var onChange: () -> Void = {}
  var onMount: (WKWebView, CGSize) -> Void = { _, _ in }
  var onLinkAdmission: (String, String, _ includingAcceptedContact: Bool) -> DocumentLinkAdmission? = { _, _, _ in nil }
  var onLink: (String, String, DocumentLinkActivation) -> Void = { _, _, _ in }
  var hasFocus: Bool { slots.values.contains { $0.runtime.focused } }
  var hasRuntimes: Bool { !slots.isEmpty }
  var runtimeIDs: Set<String> { Set(slots.keys) }
  var activeRuntimes: [DocumentBlockRuntime] { slots.values.map(\.runtime) }
  func runtime(for id: String) -> DocumentBlockRuntime? { slots[id]?.runtime }
  func pauseFailure(for id: String) -> String? { slots[id]?.pauseFailure }
  func isRetiring(_ id: String) -> Bool { slots[id]?.job?.isCheckpoint == true }
  func allowsInteraction(_ id: String) -> Bool {
    guard liveIDs.contains(id), let slot = slots[id], !slot.parked, slot.job == nil,
      slot.pauseFailure == nil, let context, let source = context.programsByID[id] else { return false }
    let record = context.recordsByID[id]
    return slot.runtime.presents(record?.value ?? source.initialState, version: record?.valueVersion)
  }
  private var hasPauseFailures: Bool { slots.values.contains { $0.pauseFailure != nil } }
  var visibleIDs: Set<String> { context?.visibleIDs ?? [] }
  var retainedIDs: Set<String> { context?.retainedIDs ?? [] }

  init(documentID: UUID, resources: SceneRenderResources) {
    self.documentID = documentID; self.resources = resources
  }

  /// Freeze the authored model immediately, even without pool pressure.
  /// A hidden source editor or confirmed return context keeps its heap, not its clock.
  func parkForReturn() {
    guard !parkedForReturn, !stopped else { return }
    parkedForReturn = true
    for (id, slot) in slots {
      let runtime = slot.runtime
      if !runtime.ready, runtime.webView == nil { retireImmediately(id, runtime: runtime); continue }
      liveIDs.remove(id)
      offerPausedReclamation(id, runtime: runtime)
      if slot.job == nil { startCheckpoint(id, runtime: runtime, keepsPicture: false, keepsRuntime: true) }
    }
  }

  private func offerPausedReclamation(_ id: String, runtime: DocumentBlockRuntime) {
    runtime.offerReturnReclamation { [weak self, weak runtime] in
      guard let self, let runtime else { return }
      guard slots[id]?.runtime === runtime, !liveIDs.contains(id), !runtime.focused,
        runtime.attentionPauseID == nil, context?.contacts.contains(id) != true else {
        runtime.cancelReturnReclamation(); return
      }
      if slots[id]?.parked == true, slots[id]?.pauseFailure == nil, slots[id]?.job == nil {
        retireImmediately(id, runtime: runtime); onChange(); return
      }
      slots[id]?.returnEviction = true
      if slots[id]?.job == nil { startCheckpoint(id, runtime: runtime, keepsPicture: retainedIDs.contains(id), keepsRuntime: true) }
    }
  }

  func resumeFromReturn() {
    guard parkedForReturn else { return }
    parkedForReturn = false
    for (block, slot) in slots {
      slot.returnEviction = false
      slot.runtime.offerReturnReclamation(nil)
      if slot.job == nil, slot.parked, slot.pauseFailure != nil {
        slot.parked = false
        startCheckpoint(block, runtime: slot.runtime, keepsPicture: false, keepsRuntime: true)
      }
    }
    // Reconciliation resumes only the demanded programs. Other accepted
    // heaps remain paused and available for pressure reclamation.
    reconcile(); onChange()
  }

  func update(input: DocumentPagePresentation, layout: DocumentLayoutRecord, programs: [DocumentProgramSource], pages: Set<Int>,
    currentPage: Int?, visibleIDs: Set<String>, preparationPage: Int?, blocked: Bool, contacts: Set<String>, densities: [String: Double], unresolvedProgramIDs: Set<String> = []) {
    guard !stopped else { return }
    context = .init(input: input, layout: layout, programs: programs,
      programsByID: Dictionary(programs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      recordsByID: Dictionary(input.state.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      retainedIDs: layout.blockIDs(on: pages, kind: .program).intersection(Set(programs.map(\.id)).union(unresolvedProgramIDs)),
      unresolvedProgramIDs: unresolvedProgramIDs, pages: pages, currentPage: currentPage,
      visibleIDs: visibleIDs, preparationPage: preparationPage, blocked: blocked, contacts: contacts, densities: densities)
    reconcile()
  }

  func paused(_ id: String) -> PausedProgram? {
    guard let saved = pausedPrograms[id], let context,
      let block = context.programsByID[id], block.sourceBasis == saved.sourceBasis,
      saved.size == viewportSize(id),
      (context.recordsByID[id]?.value ?? block.initialState) == saved.value else { return nil }
    return saved
  }

  private func viewportSize(_ id: String) -> CGSize {
    context?.layout.programSize(id) ?? .init(width: 1, height: 1)
  }

  func presents(_ id: String) -> Bool {
    guard slots[id]?.pauseFailure == nil, slots[id]?.job == nil else { return false }
    if liveIDs.contains(id), slots[id]?.parked == true { return false }
    guard let context, let block = context.programsByID[id] else { return false }
    if paused(id) != nil { return true }
    guard let runtime = slots[id]?.runtime, runtime.sourceBasis == block.sourceBasis else { return false }
    let record = context.recordsByID[id]
    return runtime.presents(record?.value ?? block.initialState, version: record?.valueVersion)
  }

  func retry(_ id: String) {
    guard retainedIDs.contains(id) else { return }
    let slot = slots[id]
    let retryCheckpoint = slot?.pauseFailure != nil && slot?.parked == true
    slot?.pauseFailure = nil
    if retryCheckpoint { slot?.parked = false }
    slot?.retirementAttempt = nil
    // Retry may finish a failed freeze/write while execution is suspended,
    // but an author reload still needs an explicit return to running.
    if !boundarySuspendsPrograms { slot?.runtime.retry() }
    if retryCheckpoint, let runtime = slot?.runtime, slot?.job == nil {
      startCheckpoint(id, runtime: runtime, keepsPicture: false, keepsRuntime: true)
    }
    reconcile(); onChange()
  }

  func blurFocused() async {
    for slot in slots.values where slot.runtime.focused { await slot.runtime.blur() }
  }

  private func reconcile() {
    guard !stopped, !parkedForReturn, !boundarySuspendsPrograms, let context else { return }
    let input = context.input, retained = retainedIDs
    pausedPrograms = pausedPrograms.filter { retained.contains($0.key) && (context.unresolvedProgramIDs.contains($0.key) || paused($0.key) != nil) }
    let currentIDs = context.layout.blockIDs(on: [context.currentPage ?? input.pageIndex], kind: .program)
    let blocks = context.programs.filter { retained.contains($0.id) }
    let ordered = (blocks.filter { currentIDs.contains($0.id) } + blocks.filter { !currentIDs.contains($0.id) }).map(\.id)
    var desired = context.visibleIDs.intersection(retained)
    desired.formUnion(slots.filter { $0.value.runtime.focused || context.contacts.contains($0.key) }.map(\.key))
    if !context.blocked { liveIDs = desired }
    let previewPages = context.preparationPage.map { Set([$0]) } ?? context.pages.subtracting(context.currentPage.map { [$0] } ?? [])
    let previewCandidates = context.layout.blockIDs(on: previewPages, kind: .program).intersection(retained)
    if let previewID, context.blocked || !previewCandidates.contains(previewID) || liveIDs.contains(previewID)
      || slots[previewID]?.runtime.failure != nil { self.previewID = nil }
    if previewID == nil, !context.blocked {
      previewID = ordered.first { previewCandidates.contains($0) && !liveIDs.contains($0) && paused($0) == nil
        && slots[$0]?.pauseFailure == nil && slots[$0]?.runtime.failure == nil }
    }
    var demanded = liveIDs
    if let previewID { demanded.insert(previewID) }
    for block in blocks where demanded.contains(block.id) {
      let id = block.id
      guard let size = context.layout.programSize(id) else { continue }
      if let old = slots[id]?.runtime, !old.matches(block) {
        guard !context.blocked, !old.focused, !context.contacts.contains(id) else { continue }
        retireImmediately(id, runtime: old)
      }
      let record = context.recordsByID[id]
      let state = record?.value ?? block.initialState, stateVersion = record?.valueVersion
      if slots[id]?.runtime == nil {
        let runtime = DocumentBlockRuntime(documentID: documentID, program: block,
          value: state, stateVersion: stateVersion, width: size.width, height: size.height, resources: resources, programStore: input.programStore)
        runtime.onChange = { [weak self, weak runtime] in
          guard let self, let runtime, slots[id]?.runtime === runtime else { return }
          reconcile(); onChange()
        }
        runtime.onFocus = { [weak self, weak runtime] _ in
          guard let self, let runtime, slots[id]?.runtime === runtime else { return }
          reconcile(); onChange()
        }
        // Accepted state retains its original program through presentation
        // retirement; the common writer fences a replaced executable source.
        let writeState = input.onStateChange
        runtime.onStateChange = { value in try await writeState(block, value) }
        runtime.onStateDrained = input.onStateDrained
        runtime.onStateCheckpoint = { [weak self, weak runtime] value, stateVersion in
          guard let self, let runtime, slots[id]?.runtime === runtime, let input = self.context?.input,
            self.context?.programsByID[id]?.sourceBasis == runtime.sourceBasis else { return nil }
          return try await input.onStateCheckpoint(id, value, runtime.program, stateVersion)
        }
        runtime.onMount = { [weak self] web, size in self?.onMount(web, size) }
        runtime.onLinkAdmission = { [weak self, weak runtime] includingAcceptedContact in
          guard let self, let runtime, slots[id]?.runtime === runtime, liveIDs.contains(id) else { return nil }
          return onLinkAdmission(id, runtime.sourceBasis, includingAcceptedContact)
        }
        runtime.onLink = { [weak self, weak runtime] activation in
          guard let self, let runtime, slots[id]?.runtime === runtime else { return }
          onLink(id, runtime.sourceBasis, activation)
        }
        slots[id] = Slot(runtime)
      }
      guard let runtime = slots[id]?.runtime else { continue }
      if !context.blocked, !runtime.focused, !context.contacts.contains(id) {
        runtime.updateViewport(width: size.width, height: size.height)
      }
      runtime.requiresStateAcceptance = true
      runtime.start(priority: liveIDs.contains(id) ? .liveProgram : .visible)
      if slots[id]?.parked == true, slots[id]?.job == nil, slots[id]?.pauseFailure == nil,
        liveIDs.contains(id) {
        runtime.offerReturnReclamation(nil); slots[id]?.returnEviction = false
        slots[id]?.parked = false; pausedPrograms[id] = nil
        _ = startResume(id, runtime: runtime)
        continue
      }
      if !runtime.focused, context.contacts.isEmpty, slots[id]?.job == nil, slots[id]?.pauseFailure == nil,
        slots[id]?.application?.version != stateVersion || slots[id]?.application == nil {
        apply(state, version: stateVersion, to: runtime)
      }
    }
    var attempt: String?
    for (id, slot) in slots {
      let runtime = slot.runtime
      // An unresolved successor descriptor cannot revoke or reconfigure an
      // accepted runtime. Other resolved slots can progress independently.
      if context.unresolvedProgramIDs.contains(id) { continue }
      let outside = !retained.contains(id)
      // A queued acquisition has no author yet. A created WebKit may already
      // have accepted state before ready, so it leaves through the same drain.
      if !demanded.contains(id), !runtime.ready, runtime.failure == nil, !context.blocked, !runtime.focused, !context.contacts.contains(id) {
        if runtime.webView == nil || context.programsByID[id]?.sourceBasis != runtime.sourceBasis { retireImmediately(id, runtime: runtime) }
        else if slot.job == nil { startCheckpoint(id, runtime: runtime, keepsPicture: false) }
        continue
      }
      if outside && context.programsByID[id]?.sourceBasis != runtime.sourceBasis {
        if !context.blocked, !runtime.focused, !context.contacts.contains(id) { retireImmediately(id, runtime: runtime) }
        continue
      }
      let shouldRetire = outside || !liveIDs.contains(id)
      if !shouldRetire || context.blocked || runtime.focused || context.contacts.contains(id) {
        if slot.job?.preservesRuntime != true { slot.job?.task.cancel() }
        continue
      }
      guard runtime.ready, slot.job == nil, slot.pauseFailure == nil else { continue }
      if slot.parked { offerPausedReclamation(id, runtime: runtime); continue }
      if outside {
        if attempt == nil { attempt = input.token + "|" + retained.sorted().joined(separator: "|") }
        if slot.retirementAttempt == attempt { continue }
        slot.retirementAttempt = attempt
      }
      startCheckpoint(id, runtime: runtime, keepsPicture: !outside, keepsRuntime: true)
    }
  }

  private func apply(_ state: JSONValue, version: ContentFieldVersion?, to runtime: DocumentBlockRuntime) {
    let block = runtime.program.id, id = UUID()
    slots[block]?.application?.task.cancel()
    let task = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      defer { if slots[block]?.application?.id == id { slots[block]?.application = nil } }
      guard !Task.isCancelled, !stopped, slots[block]?.runtime === runtime else { return }
      try? await runtime.apply(state, stateVersion: version)
    }
    slots[block]?.application = .init(id: id, version: version, task: task)
  }

  private func startCheckpoint(_ block: String, runtime: DocumentBlockRuntime, keepsPicture: Bool, keepsRuntime: Bool = false) {
    let id = UUID()
    slots[block]?.application?.task.cancel(); slots[block]?.application = nil
    let task = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      defer {
        if slots[block]?.job?.id == id { slots[block]?.job = nil }
        if slots[block]?.runtime === runtime {
          runtime.cancelReturnReclamation()
          if slots[block]?.parked == true, slots[block]?.pauseFailure == nil {
            offerPausedReclamation(block, runtime: runtime)
          } else if parkedForReturn, slots[block]?.job == nil, slots[block]?.pauseFailure == nil {
            startCheckpoint(block, runtime: runtime, keepsPicture: false, keepsRuntime: true)
          }
        }
        if !stopped { reconcile(); onChange() }
      }
      guard !Task.isCancelled, !stopped, slots[block]?.runtime === runtime, let context = self.context else { return }
      var pixels: RasterLease?
      defer { pixels?.release() }
      do {
        if keepsRuntime { await runtime.blur() }
        let value = try await runtime.checkpoint()
        try Task.checkCancellation()
        if keepsPicture {
          let width = max(1, Int(ceil(runtime.blockWidth * (context.densities[block] ?? 2))))
          do { pixels = try await runtime.capture(sourceOffset: 0, height: runtime.viewportSize.height, pixelWidth: width) }
          catch SceneRenderError.resourceLimit {
            // An offscreen former input owner may keep a useful image, but its
            // optional pixels cannot pin the executor ahead of visible work.
            // A requested cut still owns its capture and explicit failure.
            guard self.previewID != block, !self.liveIDs.contains(block) else { throw SceneRenderError.resourceLimit }
          }
        }
        guard !stopped, slots[block]?.runtime === runtime else { return }
        guard let latest = self.context,
          latest.programsByID[block]?.sourceBasis == runtime.sourceBasis else {
          retireImmediately(block, runtime: runtime); return
        }
        if let pixels, keepsPicture {
          pausedPrograms[block] = .init(sourceBasis: runtime.sourceBasis, value: value,
            size: runtime.viewportSize, raster: pixels)
          self.previewID = nil
        }
        pixels = nil
        if keepsRuntime, !(slots[block]?.returnEviction == true) {
          slots[block]?.pauseFailure = nil
          if parkedForReturn || (!liveIDs.contains(block) && !runtime.focused && !latest.contacts.contains(block)) {
            slots[block]?.parked = true
          } else {
            slots[block]?.parked = false; pausedPrograms[block] = nil
            _ = await resume(block, runtime: runtime)
          }
          return
        }
        guard !latest.blocked, !latest.contacts.contains(block), !runtime.focused, !liveIDs.contains(block) else {
          _ = await resume(block, runtime: runtime); return
        }
        slots[block] = nil
        onChange()
        runtime.stop()
      } catch {
        if !stopped, slots[block]?.runtime === runtime {
          if error is NotebookProgramCheckpointError {
            retireImmediately(block, runtime: runtime); return
          }
          if error is CancellationError {
            await resume(block, runtime: runtime)
          } else {
            // A failed author hook or writer retains the same suspended heap.
            // Only explicit Retry may continue its unfinished lifecycle stage.
            slots[block]?.parked = true
            slots[block]?.pauseFailure = String(describing: error)
          }
        }
      }
    }
    slots[block]?.job = .init(id: id, task: task, kind: .checkpoint(keepsRuntime: keepsRuntime))
  }

  /// Navigation finishes only the editing program. Retiring the document
  /// retains its separate all-runtime durability boundary.
  func checkpointFocused(resume: Bool) async -> Bool {
    let focused = slots.filter { $0.value.runtime.focused }
    for (block, slot) in focused {
      let runtime = slot.runtime
      slot.application?.task.cancel()
      if let application = slot.application { await application.task.value }
      if let job = slot.job { await job.task.value }
      guard !stopped, slots[block]?.runtime === runtime else { continue }
      do {
        await runtime.blur()
        _ = try await runtime.checkpoint()
        if resume, !boundarySuspendsPrograms, !parkedForReturn, slots[block]?.runtime === runtime {
          await startResume(block, runtime: runtime).value
          if slots[block]?.pauseFailure != nil { return false }
        }
      } catch {
        if error is NotebookProgramCheckpointError { continue }
        guard !stopped, slots[block] === slot else { continue }
        slot.parked = true; slot.pauseFailure = String(describing: error)
        onChange(); return false
      }
    }
    return true
  }

  /// Explicit background/close boundary, independent of page raster work.
  /// Each admitted runtime finishes its own author model; a hung neighbour
  /// cannot serialize the remaining programs behind its deadline.
  func checkpointAll(resume: Bool) async -> Bool {
    guard !stopped else { return false }
    boundaryGeneration &+= 1
    let request = boundaryGeneration
    boundarySuspendsPrograms = true
    let failuresAtAdmission = Set(slots.filter { $0.value.pauseFailure != nil }.keys)
    let applying = slots.values.compactMap { $0.application?.task }
    applying.forEach { $0.cancel() }
    slots.values.forEach { $0.application = nil }
    let boundary: (id: UUID, task: Task<Bool, Never>)
    if let running = boundaryTask { boundary = running }
    else {
      let task = Task { @MainActor [self] in
        // An already admitted state application finishes before the freeze;
        // cancellation cannot leave a late WebKit write beyond this boundary.
        for application in applying { await application.value }
        let tasks = slots.map { block, slot in Task { @MainActor [self] in
          let runtime = slot.runtime, joinedJob = slot.job
          if let joinedJob { await joinedJob.task.value }
          // A superseded retry can retire this slot while its waiter still
          // retains the previous failure. Only the current heap owns a result.
          guard !stopped, slots[block] === slot, context != nil else { return true }
          if slot.pauseFailure != nil, joinedJob != nil || !failuresAtAdmission.contains(block) { return false }
          do {
            await runtime.blur()
            _ = try await runtime.checkpoint()
            return true
          } catch {
            if error is NotebookProgramCheckpointError { return true }
            guard !stopped, slots[block] === slot else { return true }
            slot.parked = true; slot.pauseFailure = String(describing: error)
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
    guard !parkedForReturn else { return !hasPauseFailures }
    for (block, slot) in slots where !slot.parked && slot.pauseFailure == nil {
      let runtime = slot.runtime
      guard !stopped, boundaryGeneration == request, !parkedForReturn else { return false }
      while slots[block]?.runtime === runtime, let job = slots[block]?.job {
        await job.task.value
        guard !stopped, boundaryGeneration == request, !parkedForReturn else { return false }
      }
      if slots[block]?.runtime === runtime { await startResume(block, runtime: runtime).value }
    }
    guard !stopped, boundaryGeneration == request else { return false }
    reconcile(); onChange()
    return !hasPauseFailures
  }

  /// Releasing attention is not a new foreground intent. It must respect the
  /// global fence and still refer to the exact pause it originally retained.
  func resumeAfterAttention(_ block: String, runtime: DocumentBlockRuntime, attentionID: UUID) async {
    func permitted() -> Bool {
      !stopped && !boundarySuspendsPrograms && !parkedForReturn && slots[block]?.runtime === runtime
        && runtime.attentionPauseID == attentionID && slots[block]?.pauseFailure == nil
    }
    guard permitted() else { return }
    if !liveIDs.contains(block), !runtime.focused {
      runtime.attentionPauseID = nil
      if slots[block]?.parked == true { offerPausedReclamation(block, runtime: runtime) }
      return
    }
    while let job = slots[block]?.job {
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
      if slots[block]?.job?.id == id { slots[block]?.job = nil }
      if !stopped, slots[block]?.runtime === runtime {
        if parkedForReturn { startCheckpoint(block, runtime: runtime, keepsPicture: false, keepsRuntime: true) }
        else { reconcile() }
        onChange()
      }
    }
    slots[block]?.job = .init(id: id, task: task, kind: .resume)
    return task
  }

  @discardableResult
  private func resume(_ block: String, runtime: DocumentBlockRuntime) async -> Bool {
    guard !stopped, !boundarySuspendsPrograms, !parkedForReturn, slots[block]?.runtime === runtime else { return false }
    if let source = context?.programsByID[block] {
      let record = context?.recordsByID[block]
      try? await runtime.apply(record?.value ?? source.initialState, stateVersion: record?.valueVersion)
    }
    guard !stopped, !boundarySuspendsPrograms, !parkedForReturn, slots[block]?.runtime === runtime else { return false }
    let resumed = await runtime.resume()
    guard !stopped, !boundarySuspendsPrograms, !parkedForReturn, slots[block]?.runtime === runtime else { return false }
    if resumed { slots[block]?.parked = false }
    else {
      slots[block]?.parked = true; slots[block]?.pauseFailure = "program_resume_failed"
      onChange()
    }
    return resumed
  }

  private func retireImmediately(_ id: String, runtime: DocumentBlockRuntime) {
    guard let slot = slots[id], slot.runtime === runtime else { return }
    slot.job?.task.cancel(); slot.application?.task.cancel()
    slots[id] = nil
    runtime.stop()
  }

  func stop() {
    guard !stopped else { return }; stopped = true
    boundaryGeneration &+= 1; boundarySuspendsPrograms = true
    boundaryTask?.task.cancel(); boundaryTask = nil
    for slot in slots.values {
      slot.job?.task.cancel(); slot.application?.task.cancel(); slot.runtime.stop()
    }
    slots.removeAll(); pausedPrograms.removeAll(); context = nil
  }
  isolated deinit { stop() }
}
#endif
