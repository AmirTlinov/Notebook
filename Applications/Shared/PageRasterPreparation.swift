import NotebookCore
import Observation
import SwiftUI

/// One producer for passive material in the bounded page window. Consumers
/// retain ordinary RasterLeases; this queue is not another image cache. A cold
/// sheet reuses at most two WebKit executors; visible interactive programs retain their
/// own independent runtimes and never execute state writes through this queue.
@MainActor
final class PageRasterPreparation {
  struct Context {
    let owner: PageRasterPreparation
    let pageIndex: Int
  }
  private struct Request {
    let id: UUID
    let pageIndex: Int
    let pageID: UUID?
    let element: AgentElement
    let policy: AgentSnapshotPolicy
    let store: NotebookStore?
    let permits: @MainActor () -> Bool
    let completion: CheckedContinuation<RasterLease, any Error>
  }
  private struct ViewportDemand {
    let pageIndex: Int
    let sources: [String: AgentElement]
    let visible: Set<String>
  }
  private var viewports: [UUID: ViewportDemand] = [:]
  /// The read-window page owner publishes membership before enqueuing any
  /// source. A reordered UUID keeps its demand; a replacement slot cannot.
  func updateViewport(pageID: UUID, pageIndex: Int, sources: [AgentElement], visible: Set<String>) {
    viewports[pageID] = .init(pageIndex: pageIndex,
      sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, agentElementSnapshotSource($0)) }), visible: visible)
    startWorkers()
  }
  func moveViewport(pageID: UUID, pageIndex: Int) {
    guard let old = viewports[pageID] else { return }
    viewports[pageID] = .init(pageIndex: pageIndex, sources: old.sources, visible: old.visible)
    startWorkers()
  }
  func retireViewport(pageID: UUID) { viewports[pageID] = nil }

  private let resources: SceneRenderResources
  private var pending: [Request] = []
  private var active: [UUID: (request: Request, workerID: UUID)] = [:]
  private var workers: [UUID: Task<Void, Never>] = [:]
  private var displayedIndex = 0
  private var targetIndex: Int?
  private var displayedContentReady = true
  private var idleExecutors: [SceneWebRasterPreparation] = []
  private(set) var executorCount = 0
  private(set) var completedCount = 0

  init(resources: SceneRenderResources = .shared) {
    self.resources = resources
    observeOptionalPreparation()
  }

  private func observeOptionalPreparation() {
    _ = withObservationTracking { resources.optionalPreparationGeneration } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeOptionalPreparation() }
    }
    if !resources.allowsOptionalPreparation { closeIdleExecutors() }
    startWorkers()
  }

  /// Current-page material and an accepted landing never wait for speculation.
  /// The native controller latches the current host's first content receipt.
  /// Local revisions do not make that host cold again. A requested landing
  /// suspends new unrelated work; captures already submitted retain their fence.
  func prioritize(displayed: Int, target: Int?, displayedContentReady: Bool = true) {
    displayedIndex = displayed; targetIndex = target
    self.displayedContentReady = displayedContentReady
    startWorkers()
  }

  private func canPrepare(_ page: Int) -> Bool {
    page == displayedIndex || page == targetIndex
      || (resources.allowsOptionalPreparation && targetIndex == nil && displayedContentReady)
  }

  private func purpose(for request: Request) -> ScenePreparationPurpose {
    let page = pageIndex(for: request)
    return page == displayedIndex || page == targetIndex ? .required : .optional
  }

  func prepare(_ element: AgentElement, policy: AgentSnapshotPolicy, pageIndex: Int, pageID: UUID? = nil, store: NotebookStore? = nil,
    permits: @escaping @MainActor () -> Bool) async throws -> RasterLease {
    try Task.checkCancellation()
    if let raster = resources.retainRaster(for: policy.rasterSource(for: element),
      minimumScale: policy.minimumScale(for: element)) { return raster }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { completion in
        pending.append(.init(id: id, pageIndex: pageIndex, pageID: pageID, element: element, policy: policy, store: store,
          permits: permits, completion: completion))
        startWorkers()
      }
    } onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } }
  }

  private func cancel(_ id: UUID) {
    if let index = pending.firstIndex(where: { $0.id == id }) {
      pending.remove(at: index).completion.resume(throwing: CancellationError())
      if pending.isEmpty { closeIdleExecutors() }
    } else if let running = active.removeValue(forKey: id) {
      // Cancel only this executor. Its submitted capture keeps the physical
      // lease until completion; the other lane and pending landing survive.
      running.request.completion.resume(throwing: CancellationError())
      workers[running.workerID]?.cancel()
    }
  }

  private func startWorkers() {
    // Two is the pool's existing transient allowance, not a new quota. Serial
    // WebKit navigation/snapshot round trips cannot prepare a dense neighbour
    // while one process also handles every element of the displayed page.
    let capacity = max(1, min(2, resources.maximumBackgroundWebSurfaces))
    let admitted = pending.filter { canPrepare(pageIndex(for: $0)) }.count + active.count
    while workers.count < capacity, workers.count < admitted {
      let id = UUID()
      workers[id] = Task { await run(workerID: id) }
    }
  }

  private func pageIndex(for request: Request) -> Int {
    request.pageID.flatMap { viewports[$0]?.pageIndex } ?? request.pageIndex
  }
  private func priority(_ request: Request) -> Int {
    let page = pageIndex(for: request)
    let viewport = request.pageID.flatMap { viewports[$0] }
    let visible = viewport?.sources[request.element.id] == request.element
      && viewport?.visible.contains(request.element.id) == true
    if page == displayedIndex, visible { return 0 }
    // An accepted turn requires the complete target, including its offscreen
    // sources. Idle prefetch never displaces the displayed viewport.
    if page == targetIndex { return 1 }
    if page == displayedIndex { return 2 }
    return 3 + abs(page - displayedIndex)
  }

  private func run(workerID: UUID) async {
    var executor: SceneWebRasterPreparation?
    defer {
      // A visibility receipt may follow completion by one native transaction.
      // Keep the admitted shell while its queued consumer waits for that event.
      if let executor { parkIdleExecutor(executor) }
      workers[workerID] = nil
      startWorkers()
    }
    while !Task.isCancelled {
      // Equal priority preserves arrival order. Newly requested landings move
      // ahead of speculation without interrupting a submitted image capture.
      let eligible = pending.indices.filter { canPrepare(pageIndex(for: pending[$0])) }
      guard let index = eligible.min(by: { priority(pending[$0]) < priority(pending[$1]) }) else { return }
      let request = pending.remove(at: index)
      guard request.permits() else {
        request.completion.resume(throwing: CancellationError()); continue
      }
      let optionalGeneration = resources.optionalPreparationGeneration
      active[request.id] = (request, workerID)
      do {
        let raster: RasterLease
        if request.element.usesNativeSVGRaster {
          if let previous = executor { executor = nil; parkIdleExecutor(previous) }
          raster = try await resources.prepareRaster(request.element,
            captureRequest: .init(policy: request.policy),
            purpose: { [weak self] in self?.purpose(for: request) ?? .optional },
            permitsPreparation: request.permits)
        } else {
          if executor == nil {
            executor = idleExecutors.popLast()
            executor?.offerIdleReclamation(nil)
          }
          if executor == nil {
            executor = try await SceneWebRasterPreparation.create(resources: resources,
              priority: .visible, purpose: { [weak self] in self?.purpose(for: request) ?? .optional },
              permitsPreparation: request.permits)
            executorCount += 1
          }
          raster = try await executor!.prepare(request.element,
            requestedScale: request.policy.minimumScale(for: request.element),
            captureRequest: .init(policy: request.policy), programStore: request.store,
            purpose: { [weak self] in self?.purpose(for: request) ?? .optional },
            permitsPreparation: request.permits)
        }
        if active.removeValue(forKey: request.id) != nil {
          completedCount += 1
          request.completion.resume(returning: raster)
        } else { raster.release() }
      } catch {
        executor?.close(); executor = nil
        if active.removeValue(forKey: request.id) != nil {
          if error is CancellationError, !Task.isCancelled, request.permits(),
            optionalGeneration != resources.optionalPreparationGeneration || purpose(for: request) == .required {
            // Pool admission was revoked before submission. Keep this exact
            // demand parked, or retry its newly accepted current/target role.
            pending.insert(request, at: 0)
          } else { request.completion.resume(throwing: error) }
        }
      }
    }
  }

  private func closeIdleExecutors() {
    let idle = idleExecutors; idleExecutors.removeAll()
    for executor in idle { executor.close() }
  }

  private func parkIdleExecutor(_ executor: SceneWebRasterPreparation) {
    guard !Task.isCancelled, !pending.isEmpty, resources.allowsOptionalPreparation else { executor.close(); return }
    idleExecutors.append(executor)
    executor.offerIdleReclamation { [weak self, weak executor] in
      guard let executor else { return }
      self?.retireIdleExecutor(executor)
    }
  }

  private func retireIdleExecutor(_ executor: SceneWebRasterPreparation) {
    guard let index = idleExecutors.firstIndex(where: { $0 === executor }) else { return }
    idleExecutors.remove(at: index).close()
  }

  isolated deinit { closeIdleExecutors() }
}
