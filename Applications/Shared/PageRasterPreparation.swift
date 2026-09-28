import NotebookCore
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
    let element: AgentElement
    let policy: AgentSnapshotPolicy
    let store: NotebookStore?
    let permits: @MainActor () -> Bool
    let completion: CheckedContinuation<RasterLease, any Error>
  }
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

  init(resources: SceneRenderResources = .shared) { self.resources = resources }

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
    page == displayedIndex || page == targetIndex || (targetIndex == nil && displayedContentReady)
  }

  func prepare(_ element: AgentElement, policy: AgentSnapshotPolicy, pageIndex: Int, store: NotebookStore? = nil,
    permits: @escaping @MainActor () -> Bool) async throws -> RasterLease {
    try Task.checkCancellation()
    if let raster = resources.retainRaster(for: policy.rasterSource(for: element),
      minimumScale: policy.minimumScale(for: element)) { return raster }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { completion in
        pending.append(.init(id: id, pageIndex: pageIndex, element: element, policy: policy, store: store,
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
    let admitted = pending.filter { canPrepare($0.pageIndex) }.count + active.count
    while workers.count < capacity, workers.count < admitted {
      let id = UUID()
      workers[id] = Task { await run(workerID: id) }
    }
  }

  private func priority(_ page: Int) -> Int {
    page == displayedIndex ? 0 : page == targetIndex ? 1 : 2 + abs(page - displayedIndex)
  }

  private func run(workerID: UUID) async {
    var executor = idleExecutors.popLast()
    defer {
      // A visibility receipt may follow completion by one native transaction.
      // Keep the admitted shell while its queued consumer waits for that event.
      if let executor, !Task.isCancelled, !pending.isEmpty { idleExecutors.append(executor) }
      else { executor?.close() }
      workers[workerID] = nil
      startWorkers()
    }
    while !Task.isCancelled {
      // Equal priority preserves arrival order. Newly requested landings move
      // ahead of speculation without interrupting a submitted image capture.
      let eligible = pending.indices.filter { canPrepare(pending[$0].pageIndex) }
      guard let index = eligible.min(by: { priority(pending[$0].pageIndex) < priority(pending[$1].pageIndex) }) else { return }
      let request = pending.remove(at: index)
      guard request.permits() else {
        request.completion.resume(throwing: CancellationError()); continue
      }
      active[request.id] = (request, workerID)
      do {
        let raster: RasterLease
        if request.element.usesNativeSVGRaster {
          raster = try await resources.prepareRaster(request.element,
            captureRequest: .init(policy: request.policy), permitsPreparation: request.permits)
        } else {
          if executor == nil {
            executor = try await SceneWebRasterPreparation.create(resources: resources,
              priority: .visible, permitsPreparation: request.permits)
            executorCount += 1
          }
          raster = try await executor!.prepare(request.element,
            requestedScale: request.policy.minimumScale(for: request.element),
            captureRequest: .init(policy: request.policy), programStore: request.store, permitsPreparation: request.permits)
        }
        if active.removeValue(forKey: request.id) != nil {
          completedCount += 1
          request.completion.resume(returning: raster)
        } else { raster.release() }
      } catch {
        executor?.close(); executor = nil
        if active.removeValue(forKey: request.id) != nil {
          request.completion.resume(throwing: error)
        }
      }
    }
  }

  private func closeIdleExecutors() {
    for executor in idleExecutors { executor.close() }
    idleExecutors.removeAll()
  }

  isolated deinit { closeIdleExecutors() }
}
