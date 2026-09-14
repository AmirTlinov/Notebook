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
    let blocked: Bool
    let contacts: Set<String>
    let densities: [String: Double]
  }
  private struct Job {
    let id: UUID
    let task: Task<Void, Never>
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
  private(set) var requestedID: String?
  private var previewID: String?
  private(set) var pauseFailures: [String: String] = [:]
  private var jobs: [String: Job] = [:]
  private var applications: [String: Application] = [:]
  private var retirementAttempts: [String: String] = [:]
  private var stopped = false
  var onChange: () -> Void = {}
  var onFailure: (String, Error) -> Void = { _, _ in }
  var onMount: (WKWebView, CGSize) -> Void = { _, _ in }
  var onLink: (String, ContentFieldVersion, String) -> Void = { _, _, _ in }
  var hasFocus: Bool { runtimes.values.contains { $0.focused } }
  var retainedIDs: Set<String> {
    guard let context else { return [] }
    let ids = Set(context.input.document.blocks.filter { $0.kind == .interactive }.map(\.id))
    return context.layout.blockIDs(on: context.pages).intersection(ids)
  }

  init(documentID: UUID, resources: SceneRenderResources) {
    self.documentID = documentID; self.resources = resources
  }

  func update(input: DocumentPagePresentation, layout: DocumentLayoutRecord, pages: Set<Int>,
    currentPage: Int?, blocked: Bool, contacts: Set<String>, densities: [String: Double]) {
    guard !stopped else { return }
    context = .init(input: input, layout: layout, pages: pages, currentPage: currentPage,
      blocked: blocked, contacts: contacts, densities: densities)
    reconcile()
  }

  func paused(_ id: String) -> PausedProgram? {
    guard let saved = pausedPrograms[id], let input = context?.input,
      input.document.sourceVersion(blockID: id) == saved.sourceVersion,
      let block = input.document.blocks.first(where: { $0.id == id }),
      (input.state.records.first(where: { $0.id == id })?.value ?? block.initialState) == saved.value else { return nil }
    return saved
  }

  func activate(_ id: String) {
    guard retainedIDs.contains(id) else { return }
    requestedID = id; pauseFailures[id] = nil
    reconcile(); onChange()
  }

  func retry(_ id: String) {
    pauseFailures[id] = nil; retirementAttempts[id] = nil; runtimes[id]?.retry(); activate(id)
  }

  func blurFocused() async {
    for runtime in runtimes.values where runtime.focused { await runtime.blur() }
  }

  private func reconcile() {
    guard !stopped, let context else { return }
    let input = context.input, retained = retainedIDs
    pausedPrograms = pausedPrograms.filter { retained.contains($0.key) && paused($0.key) != nil }
    pauseFailures = pauseFailures.filter { retained.contains($0.key) }
    let currentIDs = context.layout.blockIDs(on: [context.currentPage ?? input.pageIndex])
    let blocks = input.document.blocks.filter { $0.kind == .interactive && retained.contains($0.id) }
    let ordered = (blocks.filter { currentIDs.contains($0.id) } + blocks.filter { !currentIDs.contains($0.id) }).map(\.id)
    let automaticCount = min(resources.maximumPassiveLivePrograms, max(0, resources.maximumWebSurfaces - 3))
    var desired = Set(ordered.prefix(automaticCount))
    if let requestedID, retained.contains(requestedID) { desired.insert(requestedID) }
    else { requestedID = nil }
    if !context.blocked { liveIDs = desired }
    if let previewID, !retained.contains(previewID) || liveIDs.contains(previewID) { self.previewID = nil }
    if previewID == nil {
      previewID = ordered.first { !liveIDs.contains($0) && paused($0) == nil && pauseFailures[$0] == nil }
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
          value: state, stateVersion: record?.valueVersion, width: region.frame.width, resources: resources)
        runtime.onChange = { [weak self, weak runtime] in
          guard let self, let runtime, runtimes[id] === runtime else { return }
          if let failure = runtime.failure { onFailure(id, failure) }
          reconcile(); onChange()
        }
        runtime.onFocus = { [weak self] _ in self?.reconcile(); self?.onChange() }
        runtime.onStateChange = { [weak self, weak runtime] value in
          guard let self, let runtime, runtimes[id] === runtime, let input = self.context?.input,
            input.document.sourceVersion(blockID: id) == runtime.sourceVersion else { return nil }
          return input.onStateChange(id, value)
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
      runtime.start(priority: id == requestedID ? .input : (liveIDs.contains(id) ? .liveProgram : .visible))
      if !runtime.focused, context.contacts.isEmpty, jobs[id] == nil,
        applications[id]?.version != record?.valueVersion || applications[id] == nil {
        apply(state, version: record?.valueVersion, to: runtime)
      }
    }
    for (id, runtime) in runtimes {
      let outside = !retained.contains(id)
      if outside && (!input.document.blocks.contains { $0.id == id }
        || input.document.sourceVersion(blockID: id) != runtime.sourceVersion || !runtime.ready) {
        if !context.blocked, !runtime.focused, !context.contacts.contains(id) { retireImmediately(id, runtime: runtime) }
        continue
      }
      let shouldRetire = outside || !liveIDs.contains(id)
      if !shouldRetire || context.blocked || runtime.focused || context.contacts.contains(id) {
        jobs[id]?.task.cancel()
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

  private func startCheckpoint(_ block: String, runtime: DocumentBlockRuntime, keepsPicture: Bool) {
    let id = UUID()
    applications[block]?.task.cancel(); applications[block] = nil
    retiringIDs.insert(block)
    let task = Task { @MainActor [weak self, weak runtime] in
      guard let self, let runtime else { return }
      defer {
        if jobs[block]?.id == id { jobs[block] = nil; retiringIDs.remove(block) }
        if !stopped { reconcile(); onChange() }
      }
      guard let context = self.context else { return }
      var pixels: RasterLease?
      defer { pixels?.release() }
      do {
        let value = try await runtime.checkpoint()
        try Task.checkCancellation()
        if keepsPicture {
          let width = max(1, Int(ceil(runtime.blockWidth * (context.densities[block] ?? 2))))
          pixels = try await runtime.capture(sourceOffset: 0, height: runtime.block.height, pixelWidth: width)
        }
        let accepted = try await context.input.onStateCheckpoint(block, value, runtime.sourceVersion)
        try Task.checkCancellation()
        guard accepted else {
          if keepsPicture { pauseFailures[block] = "document_state_checkpoint_not_accepted" }
          await runtime.resume(); return
        }
        guard !stopped, runtimes[block] === runtime, let latest = self.context,
          !latest.blocked, !latest.contacts.contains(block), !runtime.focused, !liveIDs.contains(block),
          latest.input.document.sourceVersion(blockID: block) == runtime.sourceVersion,
          runtime.value == value, keepsPicture || !retainedIDs.contains(block) else {
          await runtime.resume(); return
        }
        if let pixels, keepsPicture { pausedPrograms[block] = .init(sourceVersion: runtime.sourceVersion, value: value, raster: pixels); self.previewID = nil }
        pixels = nil
        runtimes[block] = nil; retiringIDs.remove(block)
        onChange() // Replace the viewport before releasing its native lease.
        runtime.stop()
      } catch {
        if !stopped, runtimes[block] === runtime {
          await runtime.resume()
          if !(error is CancellationError), keepsPicture { pauseFailures[block] = String(describing: error) }
        }
      }
    }
    jobs[block] = .init(id: id, task: task)
  }

  private func retireImmediately(_ id: String, runtime: DocumentBlockRuntime) {
    jobs[id]?.task.cancel(); applications[id]?.task.cancel(); applications[id] = nil
    runtime.stop(); runtimes[id] = nil; retiringIDs.remove(id); retirementAttempts[id] = nil
  }

  func stop() {
    guard !stopped else { return }; stopped = true
    jobs.values.forEach { $0.task.cancel() }; jobs.removeAll()
    applications.values.forEach { $0.task.cancel() }; applications.removeAll()
    runtimes.values.forEach { $0.stop() }; runtimes.removeAll(); pausedPrograms.removeAll(); context = nil
  }
  isolated deinit { stop() }
}
#endif
