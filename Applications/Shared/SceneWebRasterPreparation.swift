import NotebookCore
import WebKit

/// One sequential renderer owns one temporary WebKit, not one process session
/// per source. Human web surfaces keep their independent data stores and leases.
@MainActor
final class SceneWebRasterPreparation {
  private let resources: SceneRenderResources
  private let lease: WebSurfaceLease
  private let coordinator: AgentWebCoordinator
  private let web: WKWebView
  #if os(iOS)
    private let window: UIWindow
  #else
    private let window: NSWindow
  #endif
  private var isClosed = false
  private var closingCaptures: [AgentSnapshotCapture] = []
  private var closeTask: Task<Void, Never>?
  private var isPreparing = false
  private(set) var completedJobCount = 0
  var webIdentity: ObjectIdentifier { ObjectIdentifier(web) }
  var loadToken: String? { coordinator.loadToken }

  static func create(resources: SceneRenderResources,
    executionSource: InteractiveElementReference? = nil,
    permitsPreparation: @MainActor () -> Bool) async throws -> SceneWebRasterPreparation {
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    let lease = try await resources.acquireWebSurface(priority: .background, source: executionSource,
      deadline: .now + .seconds(8))
    do {
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      return try Self(resources: resources, lease: lease)
    } catch { lease.release(); throw error }
  }

  private init(resources: SceneRenderResources, lease: WebSurfaceLease) throws {
    self.resources = resources; self.lease = lease
    coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in })
    web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    #if os(iOS)
      guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) else {
        coordinator.invalidate(); throw SceneRenderError.snapshotPending("preparation_scene")
      }
      window = NotebookPreparationWindow(windowScene: scene)
      let controller = UIViewController()
      controller.view.backgroundColor = .clear
      controller.view.addSubview(web)
      window.rootViewController = controller
    #else
      window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 1, height: 1),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = web
    #endif
  }

  func prepare(_ element: AgentElement, requestedScale: Double, region: PageRect? = nil,
    currentPolicy: (@MainActor () -> AgentSnapshotPolicy)? = nil,
    permitsPreparation: @MainActor () -> Bool) async throws -> RasterLease {
    precondition(!isPreparing, "A raster executor runs exactly one job at a time")
    guard !isClosed else { throw CancellationError() }
    var policy: AgentSnapshotPolicy = currentPolicy?()
      ?? region.map { .region($0, scale: requestedScale) } ?? .exact(scale: requestedScale)
    guard requestedScale.isFinite, requestedScale > 0,
      policy.pixelSize(for: element) != nil else { throw SceneRenderError.resourceLimit }
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    if let raster = resources.retainRaster(for: policy.rasterSource(for: element),
      minimumScale: policy.minimumScale(for: element)) { return raster }
    isPreparing = true
    defer { isPreparing = false }
    place(element, policy: policy)
    coordinator.loadRasterJob(element, policy: policy, in: web)
    let deadline = ContinuousClock.now + .seconds(8)
    do {
      while true {
        try Task.checkCancellation()
        guard permitsPreparation() else { throw CancellationError() }
        if let next = currentPolicy?(), next != policy {
          guard next.pixelSize(for: element) != nil else { throw SceneRenderError.resourceLimit }
          policy = next
          place(element, policy: policy)
          // A camera request changes only this executor's capture window. It
          // must not restart the program or its still-running readiness promise.
          coordinator.load(element, policy: policy, in: web)
        }
        if let raster = resources.retainRaster(for: policy.rasterSource(for: element),
          minimumScale: policy.minimumScale(for: element)) {
          completedJobCount += 1
          return raster
        }
        if let failure = coordinator.snapshotFailure { throw failure }
        guard ContinuousClock.now < deadline else { throw SceneRenderError.snapshotPending(element.id) }
        try await Task.sleep(for: .milliseconds(20))
      }
    } catch { close(); throw error }
  }

  private func place(_ element: AgentElement, policy: AgentSnapshotPolicy) {
    let size = CGSize(width: element.frame.width, height: element.frame.height)
    let crop = policy.captureRect(for: element)
    #if os(iOS)
      window.frame = CGRect(origin: .init(x: -20_000 - crop.width, y: -20_000 - crop.height), size: crop.size)
      web.frame = CGRect(origin: .init(x: -crop.minX, y: -crop.minY), size: size)
      window.isHidden = false
    #else
      window.setContentSize(crop.size); window.setFrameOrigin(.init(x: -20_000 - crop.width, y: -20_000 - crop.height))
      web.frame = CGRect(origin: .init(x: -crop.minX, y: -crop.minY), size: size); window.orderBack(nil)
    #endif
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true; coordinator.invalidate()
    #if os(iOS)
      web.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
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
