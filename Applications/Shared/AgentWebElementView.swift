import NotebookCore
import SwiftUI
import WebKit

#if os(iOS)
  struct AgentWebElementView: UIViewRepresentable {
    let element: AgentElement
    let lease: WebSurfaceLease
    let snapshotPolicy: AgentSnapshotPolicy
    let onRenderReady: (Bool) -> Void
    var onFailure: (RenderDiagnostic) -> Void = { _ in }
    let onState: (JSONValue) -> Void

    func makeCoordinator() -> AgentWebCoordinator {
      AgentWebCoordinator(
        lease: lease,
        snapshotPolicy: snapshotPolicy,
        onRenderReady: onRenderReady,
        onFailure: onFailure,
        onState: onState
      )
    }

    private var physicalSize: CGSize {
      CGSize(width: element.frame.width, height: element.frame.height)
    }

    func makeUIView(context: Context) -> PhysicalWebViewport {
      let view = PhysicalWebViewport(
        webView: AgentWebCoordinator.makeWebView(coordinator: context.coordinator),
        contentSize: physicalSize)
      // Filter the completed physical surface, not individual WebKit tiles.
      // The camera transforms this layer without changing its raster scale.
      view.layer.shouldRasterize = true
      view.layer.minificationFilter = .trilinear
      return view
    }

    static func dismantleUIView(_ view: PhysicalWebViewport, coordinator: AgentWebCoordinator) {
      coordinator.invalidate()
    }

    func updateUIView(_ view: PhysicalWebViewport, context: Context) {
      view.layer.rasterizationScale = snapshotPolicy.rasterizationScale(
        for: element, displayScale: context.environment.displayScale)
      view.setContentSize(physicalSize)
      context.coordinator.use(onRenderReady: onRenderReady)
      context.coordinator.use(onFailure: onFailure)
      context.coordinator.use(onState: onState)
      context.coordinator.load(element, in: view.webView)
    }
  }

  /// Project the admitted pixels directly. A second Core Animation raster
  /// both duplicates the backing and can retain a minified image across zoom.
  struct AgentElementSnapshotView: UIViewRepresentable {
    @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
    weak var raster: RasterLease?

    func makeUIView(context: Context) -> AgentSnapshotRasterView {
      AgentSnapshotRasterView()
    }

    func updateUIView(_ view: AgentSnapshotRasterView, context: Context) {
      view.bindSceneLifecycle(to: model)
      guard let raster, !raster.isReleased else { return }
      view.updateRaster(raster, displayScale: context.environment.displayScale)
    }

    static func dismantleUIView(_ view: AgentSnapshotRasterView, coordinator: ()) {
      view.uninstall()
    }
  }

  /// The physical bounds determine backing allocation. An external camera
  /// transform only projects this completed raster and never raises its density.
  final class AgentSnapshotRasterView: UIView, NotebookScenePresentationOwner {
    private weak var sceneModel: NotebookAppModel?
    private var isRetired = false
    private var pixelSize: CGSize = .zero
    private var displayScale: CGFloat = 1
    private var retainedRaster: RasterLease?

    init() {
      super.init(frame: .zero)
      isOpaque = false
      isUserInteractionEnabled = false
      layer.shouldRasterize = false
      layer.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func bindSceneLifecycle(to model: NotebookAppModel?) {
      guard !isRetired, sceneModel !== model else { return }
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = model
      model?.registerScenePresentation(self)
    }

    /// A tile's cohort may end while this native view is still shown. Its
    /// independent lease retains the same cache entry, without another bitmap.
    func updateRaster(_ source: RasterLease, displayScale: CGFloat) {
      guard !isRetired else { return }
      if let current = retainedRaster,
        !current.isReleased, current.entryID == source.entryID {
        installRaster(current, displayScale: displayScale)
      } else if let copy = source.retainedCopy() {
        installRaster(copy, displayScale: displayScale)
      }
    }

    private func installRaster(_ raster: RasterLease, displayScale: CGFloat) {
      guard !isRetired else { return }
      let image = raster.image
      if (layer.contents as AnyObject?) !== image.cgImage { layer.contents = image.cgImage }
      retainedRaster = raster
      layer.contentsScale = image.scale
      pixelSize = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
      self.displayScale = displayScale
      updateRasterizationScale()
    }

    /// Window transfer preserves this presenter's pixels. Actual dismantle or
    /// the model's durable shutdown ends its lease even if UIKit caches the view.
    /// Other borrowers of the same cache entry are not revoked.
    func uninstall() {
      guard !isRetired else { return }
      isRetired = true
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = nil
      layer.contents = nil
      retainedRaster = nil
      pixelSize = .zero
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateRasterizationScale()
    }

    private func updateRasterizationScale() {
      guard bounds.width > 0, bounds.height > 0, pixelSize.width > 0, pixelSize.height > 0 else { return }
      layer.rasterizationScale = min(max(1, displayScale),
        pixelSize.width / bounds.width, pixelSize.height / bounds.height)
    }
  }

#else
  struct AgentWebElementView: NSViewRepresentable {
    let element: AgentElement
    let lease: WebSurfaceLease
    let snapshotPolicy: AgentSnapshotPolicy
    let onRenderReady: (Bool) -> Void
    var onFailure: (RenderDiagnostic) -> Void = { _ in }
    let onState: (JSONValue) -> Void

    func makeCoordinator() -> AgentWebCoordinator {
      AgentWebCoordinator(
        lease: lease,
        snapshotPolicy: snapshotPolicy,
        onRenderReady: onRenderReady,
        onFailure: onFailure,
        onState: onState
      )
    }

    func makeNSView(context: Context) -> WKWebView {
      AgentWebCoordinator.makeWebView(coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: AgentWebCoordinator) {
      coordinator.invalidate()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      context.coordinator.use(onRenderReady: onRenderReady)
      context.coordinator.use(onFailure: onFailure)
      context.coordinator.use(onState: onState)
      context.coordinator.load(element, in: webView)
    }
  }

  struct AgentElementSnapshotView: NSViewRepresentable {
    @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
    weak var raster: RasterLease?

    func makeNSView(context: Context) -> AgentSnapshotRasterView {
      AgentSnapshotRasterView()
    }

    func updateNSView(_ view: AgentSnapshotRasterView, context: Context) {
      view.bindSceneLifecycle(to: model)
      guard let raster, !raster.isReleased else { return }
      view.updateRaster(raster, displayScale: context.environment.displayScale)
    }

    static func dismantleNSView(_ view: AgentSnapshotRasterView, coordinator: ()) {
      view.uninstall()
    }
  }

  final class AgentSnapshotRasterView: NSImageView, NotebookScenePresentationOwner {
    private weak var sceneModel: NotebookAppModel?
    private var isRetired = false
    private var retainedRaster: RasterLease?
    private var pixelSize: CGSize = .zero
    private var displayScale: CGFloat = 1

    init() {
      super.init(frame: .zero)
      imageScaling = .scaleAxesIndependently
      wantsLayer = true
      layer?.shouldRasterize = false
      layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func bindSceneLifecycle(to model: NotebookAppModel?) {
      guard !isRetired, sceneModel !== model else { return }
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = model
      model?.registerScenePresentation(self)
    }

    func updateRaster(_ source: RasterLease, displayScale: CGFloat) {
      guard !isRetired else { return }
      if let current = retainedRaster,
        !current.isReleased, current.entryID == source.entryID {
        installRaster(current, displayScale: displayScale)
      } else if let copy = source.retainedCopy() {
        installRaster(copy, displayScale: displayScale)
      }
    }

    private func installRaster(_ raster: RasterLease, displayScale: CGFloat) {
      guard !isRetired else { return }
      let image = raster.image
      if self.image !== image { self.image = image }
      retainedRaster = raster
      pixelSize = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        .map { CGSize(width: $0.width, height: $0.height) } ?? .zero
      self.displayScale = displayScale
      updateRasterizationScale()
    }

    func uninstall() {
      guard !isRetired else { return }
      isRetired = true
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = nil
      image = nil
      layer?.contents = nil
      retainedRaster = nil
      pixelSize = .zero
    }

    override func layout() {
      super.layout()
      updateRasterizationScale()
    }

    private func updateRasterizationScale() {
      guard bounds.width > 0, bounds.height > 0, pixelSize.width > 0, pixelSize.height > 0 else { return }
      layer?.rasterizationScale = min(max(1, displayScale),
        pixelSize.width / bounds.width, pixelSize.height / bounds.height)
    }
  }

#endif

#if os(iOS)
typealias AgentSnapshotImage = UIImage
#else
typealias AgentSnapshotImage = NSImage
#endif

/// Physical layout remains canonical. This policy controls only the number of
/// pixels allocated for its raster: display samples are bounded, exact exports
/// request their declared density and may be refused by the resource owner.
enum AgentSnapshotPolicy: Equatable {
  case display(scale: Double)
  case exact(scale: Double)

  func rasterizationScale(for element: AgentElement, displayScale: CGFloat) -> CGFloat {
    let width = element.frame.width, height = element.frame.height
    if let pixels = pixelSize(for: element) {
      return min(max(1, displayScale), pixels.width / width, pixels.height / height)
    }
    // A source that cannot produce a valid whole-frame snapshot still must not
    // allocate its uncapped canonical dimensions before reporting that refusal.
    return min(max(1, displayScale), 2048 / max(width, height))
  }

  func pixelSize(for element: AgentElement) -> CGSize? {
    let width = element.frame.width, height = element.frame.height
    let density: Double
    switch self {
    case .display(let scale):
      density = min(max(1, scale), 2048 / max(width, height), sqrt(4_194_304 / (width * height)))
    case .exact(let scale): density = scale
    }
    guard density.isFinite, density > 0 else { return nil }
    // WebKit derives height from the output width. Quantize that one axis and
    // derive the other, otherwise a very narrow frame can allocate far beyond
    // the predicted height after its width rounds up to one pixel.
    let pixelWidth: Double
    switch self {
    case .display: pixelWidth = floor(width * density)
    case .exact:
      // Exact admission checks both raster axes. Round the requested height up
      // before deriving width so a wide fractional frame cannot lose density
      // when WebKit rounds its resulting height down.
      pixelWidth = max(ceil(width * density), ceil(ceil(height * density) * (width / height)))
    }
    let pixelHeight = ceil(pixelWidth * (height / width))
    guard pixelWidth >= 1, pixelHeight >= 1, pixelWidth.isFinite, pixelHeight.isFinite else { return nil }
    if case .display = self, max(pixelWidth, pixelHeight) > 2048 || pixelWidth * pixelHeight > 4_194_304 {
      return nil
    }
    return CGSize(width: pixelWidth, height: pixelHeight)
  }
}

/// State and physical placement are inputs to an existing program, not new
/// programs. This identity survives a commit echo, resize and camera move.
struct AgentProgramSource: Equatable {
  let id: String
  let kind: AgentElementKind
  let source: String
  let html: String
  let css: String
  let javaScript: String
  init(_ element: AgentElement) {
    id = element.id; kind = element.kind; source = element.source
    html = element.html; css = element.css; javaScript = element.javaScript
  }
}

/// Publication can be revoked before WebKit returns. Its submitted backing
/// and executor remain owned by the actual completion, not by the reader task.
@MainActor
final class AgentSnapshotCapture {
  let id = UUID()
  private let reservation: RasterReservation
  private var lease: WebSurfaceLease?
  private(set) var isCancelled = false
  private(set) var isComplete = false
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  init(reservation: RasterReservation, lease: WebSurfaceLease) {
    precondition(!reservation.isReleased && !lease.isReleased)
    self.reservation = reservation; self.lease = lease
  }
  func cancel() { isCancelled = true }
  func finish() {
    guard !isComplete else { return }
    isComplete = true; reservation.release(); lease = nil
    let pending = waiters; waiters.removeAll()
    for waiter in pending.values { waiter.resume() }
  }
  /// A deadline stops the reader, never the accounting of submitted work.
  func waitForCompletion(deadline: ContinuousClock.Instant? = nil) async throws {
    guard !isComplete else { return }
    let id = UUID()
    var timeout: Task<Void, Never>?
    defer { timeout?.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      waiters[id] = continuation
      if let deadline {
        timeout = Task { @MainActor [weak self] in
          do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
          self?.waiters.removeValue(forKey: id)?.resume(throwing: SceneRenderError.snapshotPending("agent_capture_drain"))
        }
      }
    }
  }
  isolated deinit { reservation.release() }
}

@MainActor
final class AgentWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private let lease: WebSurfaceLease
  private let resources: SceneRenderResources
  private var snapshotPolicy: AgentSnapshotPolicy
  private(set) var snapshotFailure: SceneRenderError?
  private var onState: (JSONValue) -> Void
  private var onRenderReady: (Bool) -> Void
  private var onFailure: (RenderDiagnostic) -> Void
  private var renderIsReady = false
  private var isInvalidated = false
  private var activeNavigation: WKNavigation?
  private weak var attachedWebView: WKWebView?
  private var loadedElement: AgentElement?
  private(set) var loadToken: String?
  private var runtimeLoaded = false
  private var appliedState: JSONValue?
  private var stateApplication: Task<Void, Never>?
  private var stateApplicationID: UUID?
  private var currentCapture: AgentSnapshotCapture?
  private var submittedCaptures: [UUID: AgentSnapshotCapture] = [:]
  var pendingSnapshotCaptures: [AgentSnapshotCapture] { Array(submittedCaptures.values) }
  private var snapshotInFlight = false
  private var needsSnapshot = false
  private var preparationDeadline: Task<Void, Never>?
  private var recoveryAttempts = 0

  init(
    lease: WebSurfaceLease,
    resources: SceneRenderResources = .shared,
    snapshotPolicy: AgentSnapshotPolicy = .display(scale: 2),
    onRenderReady: @escaping (Bool) -> Void = { _ in },
    onFailure: @escaping (RenderDiagnostic) -> Void = { _ in },
    onState: @escaping (JSONValue) -> Void
  ) {
    self.lease = lease
    self.resources = resources
    self.snapshotPolicy = snapshotPolicy
    self.onRenderReady = onRenderReady
    self.onFailure = onFailure
    self.onState = onState
  }

  func use(onRenderReady: @escaping (Bool) -> Void) {
    guard !isInvalidated else { return }
    self.onRenderReady = onRenderReady
  }

  func use(onFailure: @escaping (RenderDiagnostic) -> Void) {
    guard !isInvalidated else { return }
    self.onFailure = onFailure
  }

  func use(onState: @escaping (JSONValue) -> Void) {
    guard !isInvalidated else { return }
    self.onState = onState
  }

  /// Dismantling ends this owner session. Neither a queued script message nor an
  /// already running WebKit completion may publish into its next owner.
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    loadToken = nil
    loadedElement = nil
    appliedState = nil
    activeNavigation = nil
    renderIsReady = false
    stateApplicationID = nil; stateApplication?.cancel(); stateApplication = nil
    preparationDeadline?.cancel(); preparationDeadline = nil
    currentCapture?.cancel(); currentCapture = nil
    onRenderReady = { _ in }
    onFailure = { _ in }
    onState = { _ in }
    attachedWebView?.stopLoading()
    attachedWebView?.navigationDelegate = nil
    attachedWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    attachedWebView = nil
  }

  private func accepts(_ token: String) -> Bool {
    !isInvalidated && !lease.isReleased && loadToken == token
  }

  func load(_ element: AgentElement, in webView: WKWebView) {
    guard !isInvalidated, !lease.isReleased, attachedWebView === webView else { return }
    guard loadedElement != element else {
      if let token = loadToken { publishRenderReadiness(renderIsReady, token: token) }
      return
    }
    if let previous = loadedElement, AgentProgramSource(previous) == AgentProgramSource(element) {
      loadedElement = element
      if previous.state != element.state || previous.frame.width != element.frame.width || previous.frame.height != element.frame.height {
        snapshotFailure = nil
        if let token = loadToken {
          setRenderReady(false, token: token)
          beginPreparationDeadline(token: token)
        }
        applyCurrentState()
      } else if let token = loadToken { publishRenderReadiness(renderIsReady, token: token) }
      return
    }
    recoveryAttempts = 0
    beginLoad(element, in: webView)
  }

  /// One leased background executor may navigate between independent raster
  /// jobs. Each navigation receives a fresh nonce; old scripts and snapshots
  /// lose publication rights before the next source enters that same WebKit.
  func loadRasterJob(_ element: AgentElement, policy: AgentSnapshotPolicy, in webView: WKWebView) {
    precondition(lease.priority == .background)
    guard !isInvalidated, !lease.isReleased, attachedWebView === webView else { return }
    snapshotPolicy = policy
    recoveryAttempts = 0
    beginLoad(element, in: webView)
  }

  private func beginLoad(_ element: AgentElement, in webView: WKWebView) {
    stateApplicationID = nil; stateApplication?.cancel(); stateApplication = nil
    currentCapture?.cancel(); currentCapture = nil
    snapshotInFlight = false; needsSnapshot = false; runtimeLoaded = false
    activeNavigation = nil
    webView.stopLoading()
    let token = "\(lease.id.uuidString)/\(UUID().uuidString)"
    loadToken = token
    loadedElement = element
    appliedState = element.state
    snapshotFailure = nil
    renderIsReady = false
    publishRenderReadiness(false, token: token)
    beginPreparationDeadline(token: token)
    activeNavigation = webView.loadHTMLString(Self.document(for: element, token: token), baseURL: nil)
  }

  private func applyCurrentState() {
    guard runtimeLoaded, stateApplication == nil, let token = loadToken, accepts(token) else { return }
    let id = UUID(); stateApplicationID = id
    stateApplication = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if stateApplicationID == id { stateApplicationID = nil; stateApplication = nil } }
      while !Task.isCancelled, accepts(token), let web = attachedWebView, let element = loadedElement {
        if appliedState == element.state { break }
        do {
          let state = try JSONSerialization.jsonObject(with: JSONEncoder().encode(element.state), options: .fragmentsAllowed)
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            web.callAsyncJavaScript("window.notebookApplyState(state); return true;",
              arguments: ["state": state], in: nil, in: .page) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
              }
          }
          guard accepts(token), !Task.isCancelled else { return }
          appliedState = element.state
        } catch {
          if accepts(token), !Task.isCancelled { record(error, kind: "render_error", token: token) }
          return
        }
        guard accepts(token), !Task.isCancelled else { return }
        if loadedElement == element { break }
      }
      guard accepts(token), !Task.isCancelled, let web = attachedWebView else { return }
      captureSnapshot(of: web, token: token)
    }
  }

  private func beginPreparationDeadline(token: String) {
    preparationDeadline?.cancel()
    preparationDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, accepts(token) else { return }
      currentCapture?.cancel(); currentCapture = nil
      fail(.init(kind: "preparation_timeout", elementID: loadedElement?.id,
        message: "WebKit did not complete source preparation and a snapshot before the deadline."), token: token)
    }
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "notebook", message.webView === attachedWebView,
      let object = message.body as? [String: Any] else { return }
    receive(object)
  }

  /// The script embeds its immutable load identity, not a mutable native value:
  /// a timer from the preceding document cannot commit into the current source.
  func receive(_ object: [String: Any]) {
    guard let token = object["token"] as? String, accepts(token), let element = loadedElement else { return }
    if object["kind"] as? String == "diagnostic",
      let kind = object["category"] as? String, let message = object["message"] as? String {
      resources.record(.init(kind: kind, elementID: element.id, message: String(message.prefix(2000))), for: element)
    } else if object["kind"] as? String == "state", let state = object["value"], let value = Self.decodeState(state) {
      onState(value)
    }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme
    decisionHandler(!isInvalidated && !lease.isReleased && attachedWebView === webView
      && (scheme == nil || scheme == "about") ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let navigation, navigation === activeNavigation, attachedWebView === webView,
      let token = loadToken, accepts(token) else { return }
    #if os(iOS)
      let frameReadiness = """
        await new Promise(resolve => requestAnimationFrame(
          () => requestAnimationFrame(resolve)
        ));
        """
    #else
      // The public snapshot includes pending pixels; it does not advance an
      // arbitrary program's rAF or claim that its computation has finished.
      let frameReadiness = ""
    #endif
    webView.callAsyncJavaScript(
      """
      await document.fonts.ready;
      await Promise.all([...document.images].map(image => image.decode().catch(() => {})));
      await window.notebookReadyPromise;
      \(frameReadiness)
      for (const image of document.images) if (!image.naturalWidth) window.notebookDiagnostic('load_error', 'Image failed to load');
      if (Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) > innerHeight + 1 || Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) > innerWidth + 1) window.notebookDiagnostic('overflow', 'Content exceeds its frame');
      return true;
      """,
      arguments: [:], in: nil, in: .page,
      completionHandler: { [weak self, weak webView] result in
        guard let self, let webView, accepts(token), attachedWebView === webView else { return }
        switch result {
        case .success:
          runtimeLoaded = true
          applyCurrentState()
        case .failure(let error):
          record(error, kind: "render_error", token: token)
          setRenderReady(false, token: token)
        }
      }
    )
  }

  private func captureSnapshot(of webView: WKWebView, token: String) {
    guard accepts(token), let element = loadedElement else { return }
    if snapshotInFlight { needsSnapshot = true; return }
    guard let pixels = snapshotPolicy.pixelSize(for: element),
      let configuration = Self.snapshotConfiguration(for: element, policy: snapshotPolicy, backingScale: snapshotScale(of: webView)),
      pixels.width.isFinite, pixels.height.isFinite,
      pixels.width < CGFloat(Int.max - 2), pixels.height < CGFloat(Int.max - 2),
      let reservation = resources.reserveRaster(pixelWidth: Int(pixels.width) + 2, pixelHeight: Int(pixels.height) + 2)
    else {
      fail(.init(kind: "resource_limit", elementID: element.id,
        message: "The requested snapshot exceeds the raster resource budget."), token: token)
      return
    }
    snapshotInFlight = true
    let capture = holdSubmittedSnapshot(reservation)
    webView.takeSnapshot(with: configuration) { [weak self, capture] image, error in
      defer { capture.finish(); self?.submittedCaptures[capture.id] = nil }
      guard let self, !capture.isCancelled else { return }
      if accepts(token) { snapshotInFlight = false; currentCapture = nil }
      completeSnapshot(image, error: error, token: token, element: element, reservation: reservation)
      if accepts(token), needsSnapshot, let web = attachedWebView {
        needsSnapshot = false; captureSnapshot(of: web, token: token)
      }
    }
  }

  /// The same grant stays alive when a representable is dismantled while its
  /// callback is held by WebKit. This does not acquire another surface slot.
  func holdSubmittedSnapshot(_ reservation: RasterReservation) -> AgentSnapshotCapture {
    precondition(!isInvalidated)
    let capture = AgentSnapshotCapture(reservation: reservation, lease: lease)
    currentCapture = capture; submittedCaptures[capture.id] = capture
    return capture
  }

  func completeSnapshot(_ image: AgentSnapshotImage?, error: (any Error)?, token: String,
    element: AgentElement, reservation: RasterReservation) {
    defer { reservation.release() }
    guard accepts(token), let loadedElement,
      SceneRasterSource.agent(loadedElement) == .agent(element) else { return }
    if let error {
      record(error, kind: "snapshot_error", token: token)
    } else if let image {
      if resources.store(image, for: element, reservation: reservation) {
        preparationDeadline?.cancel(); preparationDeadline = nil
        setRenderReady(true, token: token)
      } else {
        fail(.init(kind: "resource_limit", elementID: element.id,
          message: "The completed raster could not be admitted to the resource budget."), token: token)
      }
    } else {
      fail(.init(kind: "snapshot_error", elementID: element.id,
        message: "WebKit returned no image for the completed surface."), token: token)
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    fail(navigation: navigation, in: webView, error: error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    fail(navigation: navigation, in: webView, error: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard attachedWebView === webView, let token = loadToken, accepts(token), let element = loadedElement else { return }
    guard recoveryAttempts < 2 else {
      fail(.init(kind: "web_process_terminated", elementID: element.id,
        message: "WebKit terminated repeatedly. Retry the surface explicitly."), token: token)
      return
    }
    recoveryAttempts += 1
    beginLoad(element, in: webView)
  }

  private func fail(navigation: WKNavigation?, in webView: WKWebView, error: any Error) {
    guard let navigation, navigation === activeNavigation, attachedWebView === webView,
      let token = loadToken, accepts(token) else { return }
    record(error, kind: "load_error", token: token)
    setRenderReady(false, token: token)
  }

  private func record(_ error: any Error, kind: String, token: String) {
    guard accepts(token), let element = loadedElement else { return }
    fail(.init(kind: kind, elementID: element.id,
      message: String(error.localizedDescription.prefix(2000))), token: token)
  }

  private func fail(_ diagnostic: RenderDiagnostic, token: String) {
    guard accepts(token), let element = loadedElement else { return }
    snapshotFailure = diagnostic.kind == "resource_limit" ? .resourceLimit : .snapshotPending(element.id)
    preparationDeadline?.cancel(); preparationDeadline = nil
    currentCapture?.cancel(); currentCapture = nil
    resources.record(diagnostic, for: element)
    setRenderReady(false, token: token)
    Task { @MainActor [weak self] in
      guard let self, accepts(token) else { return }
      onFailure(diagnostic)
    }
  }

  private func setRenderReady(_ ready: Bool, token: String) {
    guard accepts(token), renderIsReady != ready else { return }
    renderIsReady = ready
    publishRenderReadiness(ready, token: token)
  }

  private func publishRenderReadiness(_ ready: Bool, token: String) {
    Task { @MainActor [weak self] in
      guard let self, accepts(token) else { return }
      onRenderReady(ready)
    }
  }

  private func snapshotScale(of webView: WKWebView) -> CGFloat {
    #if os(iOS)
      webView.traitCollection.displayScale
    #else
      webView.window?.backingScaleFactor ?? 2
    #endif
  }

  static func snapshotConfiguration(for element: AgentElement, policy: AgentSnapshotPolicy,
    backingScale: CGFloat) -> WKSnapshotConfiguration? {
    guard let pixels = policy.pixelSize(for: element) else { return nil }
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    configuration.rect = CGRect(x: 0, y: 0, width: element.frame.width, height: element.frame.height)
    // WKSnapshotConfiguration measures output width in points, not pixels.
    configuration.snapshotWidth = NSNumber(value: Double(pixels.width / max(1, backingScale)))
    return configuration
  }

  static func makeWebView(
    coordinator: AgentWebCoordinator
  ) -> WKWebView {
    precondition(!coordinator.isInvalidated && !coordinator.lease.isReleased, "WebKit requires an active, parent-owned lease.")
    precondition(coordinator.attachedWebView == nil, "A lease session mounts exactly one WebKit surface.")
    let controller = WKUserContentController()
    controller.add(coordinator, name: "notebook")
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = controller
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    coordinator.attachedWebView = webView
    #if os(iOS)
      webView.isOpaque = false
      webView.backgroundColor = .clear
      webView.scrollView.backgroundColor = .clear
      webView.scrollView.contentInsetAdjustmentBehavior = .never
      webView.scrollView.isScrollEnabled = false
      webView.scrollView.minimumZoomScale = 1
      webView.scrollView.maximumZoomScale = 1
      webView.scrollView.pinchGestureRecognizer?.isEnabled = false
    #else
      webView.setValue(false, forKey: "drawsBackground")
      webView.allowsMagnification = false
    #endif
    return webView
  }

  private static func document(for element: AgentElement, token: String) -> String {
    let state = json(element.state).replacingOccurrences(
      of: "</script>",
      with: "<\\/script>",
      options: [.caseInsensitive]
    )
    return """
      <!doctype html>
      <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; media-src data: blob:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none';">
      <style>
        :root { color-scheme: light; }
        html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: transparent; }
        body { box-sizing: border-box; color: #171714; font: 17px/1.42 -apple-system, BlinkMacSystemFont, sans-serif; }
        *, *::before, *::after { box-sizing: border-box; }
        \(element.css)
      </style>
      <script>
        const notebookLoadToken = '\(token)';
        window.notebookDiagnostic = (category, message) => window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'diagnostic',category,message:String(message)});
        addEventListener('error', event => window.notebookDiagnostic('javascript_error', event.message || 'Resource load error'));
        addEventListener('unhandledrejection', event => window.notebookDiagnostic('javascript_error', event.reason));
        let notebookState = \(state);
        const notebookCanonical = value => JSON.stringify(value, (_,v) => v && typeof v === 'object' && !Array.isArray(v)
          ? Object.fromEntries(Object.keys(v).sort().map(key => [key,v[key]])) : v);
        window.notebookApplyState = value => {
          if (notebookCanonical(value) === notebookCanonical(notebookState)) return;
          notebookState = value;
          dispatchEvent(new CustomEvent('notebookstate', { detail: value }));
        };
        window.notebook = Object.freeze({
          get state() { return notebookState; },
          commit(value) {
            if (notebookCanonical(value) === notebookCanonical(notebookState)) return;
            notebookState = value;
            window.webkit.messageHandlers.notebook.postMessage({ token: notebookLoadToken, kind: 'state', value });
          },
          ready(promise) {
            window.notebookReadyPromise = Promise.resolve(promise);
            return window.notebookReadyPromise;
          }
        });
      </script>
      </head><body>
      \(element.html)
      <script>const program=document.createElement('script');program.textContent=\(json(.string(element.javaScript)));document.body.append(program);</script>
      </body></html>
      """
  }

  private static func json(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
  }

  static func decodeState(_ object: Any) -> JSONValue? {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.fragmentsAllowed]
      )
    else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }
}
