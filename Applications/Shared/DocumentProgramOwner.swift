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
    let sourceVersion: ContentFieldVersion
    let value: JSONValue
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
  private var retirementAttempts: [String: String] = [:]
  private var stopped = false
  private var boundaryTask: Task<Bool, Never>?
  private var parkedForReturn = false
  private var parkedPrograms: Set<String> = []
  private var returnEvictions: Set<String> = []
  var onChange: () -> Void = {}
  var onMount: (WKWebView, CGSize) -> Void = { _, _ in }
  var onLink: (String, ContentFieldVersion, String) -> Void = { _, _, _ in }
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
      if !runtime.ready { retireImmediately(id, runtime: runtime); continue }
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
      let id = UUID()
      let task = Task { @MainActor [weak self, weak runtime] in
        guard let self, let runtime else { return }
        await runtime.resume()
        if jobs[block]?.id == id { jobs[block] = nil; retiringIDs.remove(block) }
        if !stopped, runtimes[block] === runtime {
          if parkedForReturn { startCheckpoint(block, runtime: runtime, keepsPicture: false, keepsRuntime: true) }
          else { reconcile() }
          onChange()
        }
      }
      jobs[block] = .init(id: id, task: task, preservesRuntime: true)
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
    guard let saved = pausedPrograms[id], let input = context?.input,
      input.document.sourceVersion(blockID: id) == saved.sourceVersion,
      let block = input.document.blocks.first(where: { $0.id == id }),
      (input.state.records.first(where: { $0.id == id })?.value ?? block.initialState) == saved.value else { return nil }
    return saved
  }

  func presents(_ id: String) -> Bool {
    guard pauseFailures[id] == nil, !retiringIDs.contains(id) else { return false }
    guard let input = context?.input, let block = input.document.blocks.first(where: { $0.id == id }) else { return false }
    if paused(id) != nil { return true }
    guard let runtime = runtimes[id], runtime.sourceVersion == input.document.sourceVersion(blockID: id) else { return false }
    let record = input.state.records.first { $0.id == id }
    return runtime.presents(record?.value ?? block.initialState, version: record?.valueVersion)
  }

  func retry(_ id: String) {
    guard retainedIDs.contains(id) else { return }
    let retryCheckpoint = pauseFailures.removeValue(forKey: id) != nil && parkedPrograms.remove(id) != nil
    retirementAttempts[id] = nil; runtimes[id]?.retry()
    if retryCheckpoint, let runtime = runtimes[id], jobs[id] == nil {
      startCheckpoint(id, runtime: runtime, keepsPicture: false, keepsRuntime: true)
    }
    reconcile(); onChange()
  }

  func blurFocused() async {
    for runtime in runtimes.values where runtime.focused { await runtime.blur() }
  }

  private func reconcile() {
    guard !stopped, !parkedForReturn, let context else { return }
    let input = context.input, retained = retainedIDs
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
      let sourceVersion = input.document.sourceVersion(blockID: id)
      if let old = runtimes[id], !old.matches(block, sourceVersion: sourceVersion, width: region.frame.width) {
        guard !context.blocked, !old.focused, !context.contacts.contains(id) else { continue }
        retireImmediately(id, runtime: old)
      }
      let record = input.state.records.first { $0.id == id }
      let state = record?.value ?? block.initialState
      if runtimes[id] == nil {
        let runtime = DocumentBlockRuntime(documentID: documentID, block: block, sourceVersion: sourceVersion,
          value: state, stateVersion: record?.valueVersion, width: region.frame.width, resources: resources, programStore: input.programStore)
        runtime.onChange = { [weak self, weak runtime] in
          guard let self, let runtime, runtimes[id] === runtime else { return }
          reconcile(); onChange()
        }
        runtime.onFocus = { [weak self] _ in self?.reconcile(); self?.onChange() }
        runtime.onStateChange = { [weak self, weak runtime] value in
          guard let self, let runtime, runtimes[id] === runtime, let input = self.context?.input,
            input.document.sourceVersion(blockID: id) == runtime.sourceVersion else { return nil }
          return input.onStateChange(id, value)
        }
        runtime.onStateCheckpoint = { [weak self, weak runtime] value, stateVersion in
          guard let self, let runtime, runtimes[id] === runtime, let input = self.context?.input,
            input.document.sourceVersion(blockID: id) == runtime.sourceVersion else { return nil }
          return try await input.onStateCheckpoint(id, value, runtime.sourceVersion, stateVersion)
        }
        runtime.onMount = { [weak self] web, size in self?.onMount(web, size) }
        runtime.onLink = { [weak self, weak runtime] href in
          guard let self, let runtime, runtimes[id] === runtime else { return }
          onLink(id, runtime.sourceVersion, href)
        }
        runtimes[id] = runtime
      }
      guard let runtime = runtimes[id] else { continue }
      runtime.requiresStateAcceptance = true
      runtime.start(priority: liveIDs.contains(id) ? .liveProgram : .visible)
      if !runtime.focused, context.contacts.isEmpty, jobs[id] == nil, pauseFailures[id] == nil,
        applications[id]?.version != record?.valueVersion || applications[id] == nil {
        apply(state, version: record?.valueVersion, to: runtime)
      }
    }
    for (id, runtime) in runtimes {
      let outside = !retained.contains(id)
      // A no-longer-visible queued start has never accepted input. It cannot
      // keep its old place ahead of the new visible controls.
      if !demanded.contains(id), !runtime.ready, runtime.failure == nil, !context.blocked, !runtime.focused, !context.contacts.contains(id) {
        retireImmediately(id, runtime: runtime); continue
      }
      if outside && (!input.document.blocks.contains { $0.id == id }
        || input.document.sourceVersion(blockID: id) != runtime.sourceVersion || !runtime.ready) {
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
        if keepsRuntime {
          pauseFailures[block] = nil
          if parkedForReturn, !returnEvictions.contains(block) {
            parkedPrograms.insert(block)
          } else if !parkedForReturn {
            parkedPrograms.remove(block)
            await runtime.resume()
          } else { retireImmediately(block, runtime: runtime) }
          return
        }
        guard let latest = self.context,
          !latest.blocked, !latest.contacts.contains(block), !runtime.focused, !liveIDs.contains(block),
          latest.input.document.sourceVersion(blockID: block) == runtime.sourceVersion,
          runtime.value == value, keepsPicture || parkedForReturn || !retainedIDs.contains(block) else {
          await runtime.resume(); return
        }
        if parkedForReturn, !returnEvictions.contains(block) {
          parkedPrograms.insert(block)
          return
        }
        if let pixels, keepsPicture { pausedPrograms[block] = .init(sourceVersion: runtime.sourceVersion, value: value, raster: pixels); self.previewID = nil }
        pixels = nil
        runtimes[block] = nil; retiringIDs.remove(block)
        onChange() // Replace the viewport before releasing its native lease.
        runtime.stop()
      } catch {
        if !stopped, runtimes[block] === runtime {
          if error is NotebookProgramCheckpointError {
            retireImmediately(block, runtime: runtime); return
          }
          if keepsRuntime || parkedForReturn {
            parkedPrograms.insert(block)
            pauseFailures[block] = String(describing: error)
          } else {
            await runtime.resume()
            if !(error is CancellationError), keepsPicture { pauseFailures[block] = String(describing: error) }
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
    if let boundaryTask {
      let accepted = await boundaryTask.value
      if resume { await resumeAll() }
      return accepted
    }
    let task = Task { @MainActor [self] in
      let tasks = runtimes.map { block, runtime in Task { @MainActor [self] in
        if let job = jobs[block] { await job.task.value }
        guard !stopped, runtimes[block] === runtime, runtime.ready, context != nil else { return true }
        do {
          await runtime.blur()
          _ = try await runtime.checkpoint()
          return true
        } catch {
          if error is NotebookProgramCheckpointError { return true }
          pauseFailures[block] = String(describing: error); return false
        }
      } }
      var accepted = true
      for task in tasks { if !(await task.value) { accepted = false } }
      return accepted
    }
    boundaryTask = task
    let accepted = await task.value; boundaryTask = nil
    if resume { await resumeAll() }
    return accepted
  }

  func resumeAll() async {
    guard !parkedForReturn else { return }
    for (block, runtime) in runtimes where !parkedPrograms.contains(block)
      && pauseFailures[block] == nil && jobs[block]?.preservesRuntime != true { await runtime.resume() }
    if !stopped { reconcile(); onChange() }
  }

  private func retireImmediately(_ id: String, runtime: DocumentBlockRuntime) {
    jobs[id]?.task.cancel(); applications[id]?.task.cancel(); applications[id] = nil
    runtime.stop(); runtimes[id] = nil; retiringIDs.remove(id); retirementAttempts[id] = nil
    parkedPrograms.remove(id); returnEvictions.remove(id)
  }

  func stop() {
    guard !stopped else { return }; stopped = true
    boundaryTask?.cancel(); boundaryTask = nil
    jobs.values.forEach { $0.task.cancel() }; jobs.removeAll()
    applications.values.forEach { $0.task.cancel() }; applications.removeAll()
    runtimes.values.forEach { $0.stop() }; runtimes.removeAll(); pausedPrograms.removeAll(); context = nil
    parkedPrograms.removeAll(); returnEvictions.removeAll()
  }
  isolated deinit { stop() }
}
#endif
