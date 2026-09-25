import NotebookCore
import WebKit

/// One source job owns its latest camera crop/density. Retargeting delivers an
/// event to that job's admitted executor; waiting for admission needs no poll.
@MainActor
final class SceneRasterCaptureRequest {
  private(set) var policy: AgentSnapshotPolicy
  fileprivate var onPolicyChange: ((AgentSnapshotPolicy) -> Void)?
  init(policy: AgentSnapshotPolicy) { self.policy = policy }
  func update(_ policy: AgentSnapshotPolicy) {
    guard self.policy != policy else { return }
    self.policy = policy
    onPolicyChange?(policy)
  }
}

/// One sequential renderer owns one temporary WebKit, not one process session
/// per source. Human web surfaces keep their independent data stores and leases.
@MainActor
final class SceneWebRasterPreparation {
  private let resources: SceneRenderResources
  private let lease: WebSurfaceLease
  private let coordinator: AgentWebCoordinator
  private let web: WKWebView
  #if os(iOS)
    private let host: NotebookPreparationHost
  #else
    private let window: NSWindow
  #endif
  private var isClosed = false
  private var closingCaptures: [AgentSnapshotCapture] = []
  private var closeTask: Task<Void, Never>?
  private struct Job {
    let id: UUID
    let element: AgentElement
    let capture: SceneRasterCaptureRequest
    let completion: CheckedContinuation<RasterLease, any Error>
  }
  private var job: Job?
  private(set) var completedJobCount = 0
  var webIdentity: ObjectIdentifier { ObjectIdentifier(web) }
  var loadToken: String? { coordinator.loadToken }

  static func create(resources: SceneRenderResources,
    executionSource: InteractiveElementReference? = nil,
    priority: WebPriority = .background,
    permitsPreparation: @MainActor () -> Bool) async throws -> SceneWebRasterPreparation {
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    let lease = try await resources.acquireWebSurface(priority: priority, source: executionSource)
    do {
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      return try Self(resources: resources, lease: lease)
    } catch { lease.release(); throw error }
  }

  private init(resources: SceneRenderResources, lease: WebSurfaceLease) throws {
    self.resources = resources; self.lease = lease
    #if os(iOS)
      guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) else {
        throw SceneRenderError.snapshotPending("preparation_scene")
      }
      host = try NotebookPreparationHost(windowScene: scene)
    #endif
    coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _, _ in false })
    web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    #if os(iOS)
      host.view.addSubview(web)
    #else
      window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 1, height: 1),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = web
    #endif
    coordinator.use(onSnapshotPrepared: { [weak self] raster in
      guard let self, let job,
        raster.image(for: job.capture.policy.rasterSource(for: job.element),
          minimumScale: job.capture.policy.minimumScale(for: job.element)) != nil else {
        raster.release(); return
      }
      finish(.success(raster))
    })
    coordinator.use(onFailure: { [weak self] _ in
      guard let self, let job else { return }
      finish(.failure(coordinator.snapshotFailure ?? SceneRenderError.snapshotPending(job.element.id)))
    })
  }

  func prepare(_ element: AgentElement, requestedScale: Double, region: PageRect? = nil,
    captureRequest: SceneRasterCaptureRequest? = nil, programStore: NotebookStore? = nil,
    permitsPreparation: @MainActor () -> Bool) async throws -> RasterLease {
    precondition(job == nil, "A raster executor runs exactly one job at a time")
    guard !isClosed else { throw CancellationError() }
    let request = captureRequest ?? SceneRasterCaptureRequest(policy:
      region.map { .region($0, scale: requestedScale) } ?? .exact(scale: requestedScale))
    let policy = request.policy
    guard requestedScale.isFinite, requestedScale > 0,
      policy.pixelSize(for: element) != nil else { throw SceneRenderError.resourceLimit }
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    if let raster = resources.retainRaster(for: policy.rasterSource(for: element),
      minimumScale: policy.minimumScale(for: element)) { return raster }
    let id = UUID()
    do {
      let raster: RasterLease = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { completion in
          precondition(request.onPolicyChange == nil, "A capture request belongs to one admitted executor")
          job = Job(id: id, element: element, capture: request, completion: completion)
          request.onPolicyChange = { [weak self] policy in self?.retarget(id, policy: policy) }
          place(element, policy: policy)
          // The coordinator owns the versioned render/capture deadline and its
          // actual ready/error events. There is no second overall stage timer.
          coordinator.programStore = programStore
          coordinator.loadRasterJob(element, policy: policy, in: web)
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          guard let self, job?.id == id else { return }
          close()
        }
      }
      guard !Task.isCancelled, permitsPreparation() else { raster.release(); throw CancellationError() }
      completedJobCount += 1
      return raster
    } catch { close(); throw error }
  }

  private func retarget(_ id: UUID, policy: AgentSnapshotPolicy) {
    guard let job, job.id == id, !isClosed else { return }
    guard policy.pixelSize(for: job.element) != nil else { finish(.failure(SceneRenderError.resourceLimit)); return }
    place(job.element, policy: policy)
    // Only capture geometry changes; the admitted program, focus and its
    // pending readiness promise retain their one source/load identity.
    coordinator.load(job.element, policy: policy, in: web)
  }

  private func finish(_ result: Result<RasterLease, any Error>) {
    guard let job else { if case .success(let raster) = result { raster.release() }; return }
    self.job = nil; job.capture.onPolicyChange = nil
    job.completion.resume(with: result)
  }

  private func place(_ element: AgentElement, policy: AgentSnapshotPolicy) {
    let size = CGSize(width: element.frame.width, height: element.frame.height)
    let crop = policy.captureRect(for: element)
    #if os(iOS)
      host.resize(to: crop.size)
      web.frame = CGRect(origin: .init(x: -crop.minX, y: -crop.minY), size: size)
    #else
      window.setContentSize(crop.size); window.setFrameOrigin(.init(x: -20_000 - crop.width, y: -20_000 - crop.height))
      web.frame = CGRect(origin: .init(x: -crop.minX, y: -crop.minY), size: size); window.orderBack(nil)
    #endif
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    finish(.failure(CancellationError()))
    coordinator.invalidate()
    #if os(iOS)
      web.removeFromSuperview(); host.close()
    #else
      window.orderOut(nil); window.contentView = nil; window.close()
    #endif
    closingCaptures = coordinator.pendingSnapshotCaptures
    if closingCaptures.isEmpty { lease.release() }
    else {
      // The callback may outlive this executor. A bounded reader timeout does
      // not free its WebKit slot or submitted snapshot backing prematurely.
      closeTask = Task { [captures = closingCaptures, lease] in
        for capture in captures { try? await capture.waitForCompletion() }
        lease.release()
      }
    }
  }

  func closeAndDrain() async throws {
    close()
    let deadline = ContinuousClock.now + .seconds(8)
    for capture in closingCaptures { try await capture.waitForCompletion(deadline: deadline) }
    if let closeTask { await closeTask.value }
  }
  isolated deinit { close() }
}
