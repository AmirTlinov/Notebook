import NotebookCore
import SwiftUI
import WebKit

/// Failure provenance is captured by the operation that failed, before a newer
/// source, policy or native presenter can replace its callbacks.
struct AgentWebSourceFailure: Equatable, Sendable {
  let diagnostic: RenderDiagnostic
  let source: AgentElement
  let leaseID: UUID
  let loadToken: String
  /// nil denotes program/navigation preparation; a snapshot failure belongs
  /// only to its submitted crop and density.
  let policy: AgentSnapshotPolicy?
  let rasterAdmission: SceneRasterAdmission?

  func canResumeCapture(with current: SceneRasterAdmission) -> Bool {
    guard diagnostic.kind == "resource_limit", let policy, let rasterAdmission else { return false }
    return Self.captureFitsAfterImprovement(source: source, policy: policy, previous: rasterAdmission, current: current)
  }

  static func captureFitsAfterImprovement(source: AgentElement, policy: AgentSnapshotPolicy,
    previous: SceneRasterAdmission, current: SceneRasterAdmission) -> Bool {
    guard let pixels = policy.pixelSize(for: source),
      let budget = SceneRenderResources.webSnapshotBudget(pixelSize: pixels)
    else { return false }
    func available(_ admission: SceneRasterAdmission) -> Int {
      min(admission.byteLimit - admission.heldBytes,
        admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    }
    let improved = available(current) > available(previous)
      || current.countLimit - current.pinnedCount - current.reservedCount
        > previous.countLimit - previous.pinnedCount - previous.reservedCount
    return improved && current.fits(additionalBytes: budget.capture, additionalCount: 1)
  }
}

#if os(iOS)
  struct AgentWebElementView: UIViewRepresentable {
    let element: AgentElement
    let lease: WebSurfaceLease
    let snapshotPolicy: AgentSnapshotPolicy
    var focus: InteractiveElementReference? = nil
    let onRenderReady: (Bool) -> Void
    var onInteractionReady: (Bool) -> Void = { _ in }
    var onInteraction: () -> Void = {}
    var onInstalled: (SceneSourceInstallation) -> Void = { _ in }
    var onFailure: (AgentWebSourceFailure) -> Void = { _ in }
    let onState: (JSONValue) -> Bool

    func makeCoordinator() -> AgentWebCoordinator {
      AgentWebCoordinator(
        lease: lease,
        snapshotPolicy: snapshotPolicy,
        onRenderReady: onRenderReady,
        onInteractionReady: onInteractionReady,
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
        contentSize: physicalSize, holdsFingerInput: true)
      // The camera projects WebKit's existing backing. Rasterizing this outer
      // layer again can retain a minified copy across a camera refinement.
      view.layer.shouldRasterize = false
      return view
    }

    static func dismantleUIView(_ view: PhysicalWebViewport, coordinator: AgentWebCoordinator) {
      coordinator.invalidate()
      view.retire()
    }

    func updateUIView(_ view: PhysicalWebViewport, context: Context) {
      guard let webView = view.webView else { return }
      view.setContentSize(physicalSize)
      view.layoutIfNeeded()
      context.coordinator.use(onRenderReady: onRenderReady)
      context.coordinator.use(onInteractionReady: onInteractionReady)
      context.coordinator.use(onInteraction: onInteraction)
      context.coordinator.bindPresentation(to: focus)
      view.onInstalled = { [weak coordinator = context.coordinator] in
        guard let installation = coordinator?.installation(for: element), installation.isInstalled else { return }
        onInstalled(installation)
      }
      context.coordinator.use(onFailure: onFailure)
      context.coordinator.use(onState: onState)
      context.coordinator.load(element, policy: snapshotPolicy, in: webView)
      view.onInstalled?()
    }
  }

  /// Project the admitted pixels directly. A second Core Animation raster
  /// both duplicates the backing and can retain a minified image across zoom.
  struct AgentElementSnapshotView: UIViewRepresentable {
    @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
    @Environment(\.scenePlaneProjection) private var projection
    weak var raster: RasterLease?
    var onInstalled: (RasterLease) -> Void = { _ in }
    var onSourceInstalled: (SceneSourceInstallation, RasterLease) -> Void = { _, _ in }

    func makeUIView(context: Context) -> AgentSnapshotRasterView {
      AgentSnapshotRasterView()
    }

    func updateUIView(_ view: AgentSnapshotRasterView, context: Context) {
      view.bindSceneLifecycle(to: model)
      view.bindProjection(projection)
      view.onRasterInstalled = { [weak view] raster in
        onInstalled(raster)
        if let view { onSourceInstalled(view.installation(for: raster), raster) }
      }
      guard let raster, !raster.isReleased else { return }
      view.updateRaster(raster)
    }

    static func dismantleUIView(_ view: AgentSnapshotRasterView, coordinator: ()) {
      view.uninstall()
    }
  }

  /// The physical bounds determine backing allocation. An external camera
  /// transform only projects this completed raster and never raises its density.
  final class AgentSnapshotRasterView: UIView, NotebookScenePresentationOwner, SceneSourceInstallationOwner, ScenePlaneProjectionObserver {
    private weak var sceneModel: NotebookAppModel?
    private var isRetired = false
    private var retainedRaster: RasterLease?
    private let cropLayer = CALayer()
    private weak var projection: ScenePlaneProjection?
    var onRasterInstalled: ((RasterLease) -> Void)?

    init() {
      super.init(frame: .zero)
      isOpaque = false
      isUserInteractionEnabled = false
      layer.shouldRasterize = false
      layer.minificationFilter = .trilinear
      cropLayer.shouldRasterize = false
      cropLayer.minificationFilter = .trilinear
      layer.addSublayer(cropLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func bindSceneLifecycle(to model: NotebookAppModel?) {
      guard !isRetired, sceneModel !== model else { return }
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = model
      model?.registerScenePresentation(self)
    }

    func bindProjection(_ projection: ScenePlaneProjection?) {
      guard self.projection !== projection else { return }
      self.projection?.remove(self); self.projection = projection; projection?.register(self)
    }
    func scenePlaneDidProject() { updateSampling() }
    private func updateSampling() {
      guard let raster = retainedRaster, !raster.isReleased else { return }
      let region = raster.source.captureRegion
      let physical = region.flatMap { region in raster.source.agentElement.map { source in
        CGRect(x: region.x / source.frame.width * bounds.width, y: region.y / source.frame.height * bounds.height,
          width: region.width / source.frame.width * bounds.width, height: region.height / source.frame.height * bounds.height)
      }} ?? bounds
      let projected = convert(physical, to: window)
      let scale = window?.screen.scale ?? traitCollection.displayScale
      let pixelSize = projected.isEmpty ? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        : CGSize(width: projected.width * scale, height: projected.height * scale)
      let image = raster.sampledImage(for: pixelSize)
      let target = region == nil ? layer : cropLayer
      let filter: CALayerContentsFilter = raster.hasMipmaps ? .linear : .trilinear
      guard (target.contents as AnyObject?) !== image || target.minificationFilter != filter else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      target.minificationFilter = filter; target.contents = image
      CATransaction.commit()
    }

    /// A tile's cohort may end while this native view is still shown. Its
    /// independent lease retains the same cache entry, without another bitmap.
    func installation(for raster: RasterLease, requiresVisibility: Bool = true) -> SceneSourceInstallation {
      .init(source: raster.source, entryID: raster.entryID, requiresVisibility: requiresVisibility, owner: self)
    }

    func isShowing(_ installation: SceneSourceInstallation) -> Bool {
      guard !isRetired, let raster = retainedRaster, !raster.isReleased else { return false }
      return raster.entryID == installation.entryID && raster.source == installation.source
        && (installation.requiresVisibility ? SceneSourceVisibility.isVisible(self) : SceneSourceVisibility.isMounted(self))
    }

    func updateRaster(_ source: RasterLease) {
      guard !isRetired else { return }
      if let current = retainedRaster,
        !current.isReleased, current.entryID == source.entryID {
        installRaster(current)
      } else if let copy = source.retainedCopy() {
        installRaster(copy)
      }
    }

    private func installRaster(_ raster: RasterLease) {
      guard !isRetired else { return }
      let image = raster.image
      retainedRaster = raster
      if let source = raster.source.agentElement, !source.requiresLiveRuntime {
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = source.source
      }
      if raster.source.captureRegion != nil {
        layer.contents = nil
        cropLayer.contentsScale = image.scale
        layoutRaster()
      } else {
        cropLayer.contents = nil
        layer.contentsScale = image.scale
      }
      updateSampling()
      if window != nil { onRasterInstalled?(raster) }
    }

    override func layoutSubviews() { super.layoutSubviews(); layoutRaster(); updateSampling() }

    private func layoutRaster() {
      guard let raster = retainedRaster, let region = raster.source.captureRegion,
        let source = raster.source.agentElement else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      cropLayer.frame = CGRect(x: region.x / source.frame.width * bounds.width,
        y: region.y / source.frame.height * bounds.height,
        width: region.width / source.frame.width * bounds.width,
        height: region.height / source.frame.height * bounds.height)
      CATransaction.commit()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      updateSampling()
      if window != nil, let retainedRaster { onRasterInstalled?(retainedRaster) }
    }

    /// Window transfer preserves this presenter's pixels. Actual dismantle or
    /// the model's durable shutdown ends its lease even if UIKit caches the view.
    /// Other borrowers of the same cache entry are not revoked.
    func uninstall() {
      guard !isRetired else { return }
      isRetired = true
      projection?.remove(self); projection = nil
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = nil
      layer.contents = nil
      cropLayer.contents = nil
      retainedRaster = nil
      onRasterInstalled = nil
    }


  }

#else
  struct AgentWebElementView: NSViewRepresentable {
    let element: AgentElement
    let lease: WebSurfaceLease
    let snapshotPolicy: AgentSnapshotPolicy
    var focus: InteractiveElementReference? = nil
    let onRenderReady: (Bool) -> Void
    var onInteractionReady: (Bool) -> Void = { _ in }
    var onInteraction: () -> Void = {}
    var onInstalled: (SceneSourceInstallation) -> Void = { _ in }
    var onFailure: (AgentWebSourceFailure) -> Void = { _ in }
    let onState: (JSONValue) -> Bool

    func makeCoordinator() -> AgentWebCoordinator {
      AgentWebCoordinator(
        lease: lease,
        snapshotPolicy: snapshotPolicy,
        onRenderReady: onRenderReady,
        onInteractionReady: onInteractionReady,
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
      context.coordinator.use(onInteractionReady: onInteractionReady)
      context.coordinator.use(onInteraction: onInteraction)
      context.coordinator.use(onFailure: onFailure)
      context.coordinator.use(onState: onState)
      context.coordinator.load(element, policy: snapshotPolicy, in: webView)
      context.coordinator.bindPresentation(to: focus)
      if let installation = context.coordinator.installation(for: element), installation.isInstalled { onInstalled(installation) }
    }
  }

  struct AgentElementSnapshotView: NSViewRepresentable {
    @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
    weak var raster: RasterLease?
    var onInstalled: (RasterLease) -> Void = { _ in }
    var onSourceInstalled: (SceneSourceInstallation, RasterLease) -> Void = { _, _ in }

    func makeNSView(context: Context) -> AgentSnapshotRasterView {
      AgentSnapshotRasterView()
    }

    func updateNSView(_ view: AgentSnapshotRasterView, context: Context) {
      view.bindSceneLifecycle(to: model)
      view.onRasterInstalled = { [weak view] raster in
        onInstalled(raster)
        if let view { onSourceInstalled(view.installation(for: raster), raster) }
      }
      guard let raster, !raster.isReleased else { return }
      view.updateRaster(raster)
    }

    static func dismantleNSView(_ view: AgentSnapshotRasterView, coordinator: ()) {
      view.uninstall()
    }
  }

  final class AgentSnapshotRasterView: NSImageView, NotebookScenePresentationOwner, SceneSourceInstallationOwner {
    // Bitmap dimensions are source resolution, never layout. NSImageView's
    // intrinsic pixel size otherwise overrides SwiftUI's projected tile frame.
    override var intrinsicContentSize: NSSize {
      .init(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    private weak var sceneModel: NotebookAppModel?
    private var isRetired = false
    private var retainedRaster: RasterLease?
    private let cropLayer = CALayer()
    var onRasterInstalled: ((RasterLease) -> Void)?
    override var isFlipped: Bool { true }

    init() {
      super.init(frame: .zero)
      imageScaling = .scaleAxesIndependently
      wantsLayer = true
      layer?.shouldRasterize = false
      layer?.minificationFilter = .trilinear
      cropLayer.shouldRasterize = false; cropLayer.minificationFilter = .trilinear
      layer?.addSublayer(cropLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func bindSceneLifecycle(to model: NotebookAppModel?) {
      guard !isRetired, sceneModel !== model else { return }
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = model
      model?.registerScenePresentation(self)
    }

    func installation(for raster: RasterLease, requiresVisibility: Bool = true) -> SceneSourceInstallation {
      .init(source: raster.source, entryID: raster.entryID, requiresVisibility: requiresVisibility, owner: self)
    }

    func isShowing(_ installation: SceneSourceInstallation) -> Bool {
      guard !isRetired, let raster = retainedRaster, !raster.isReleased else { return false }
      return raster.entryID == installation.entryID && raster.source == installation.source
        && (installation.requiresVisibility ? SceneSourceVisibility.isVisible(self) : SceneSourceVisibility.isMounted(self))
    }

    func updateRaster(_ source: RasterLease) {
      guard !isRetired else { return }
      if let current = retainedRaster,
        !current.isReleased, current.entryID == source.entryID {
        installRaster(current)
      } else if let copy = source.retainedCopy() {
        installRaster(copy)
      }
    }

    private func installRaster(_ raster: RasterLease) {
      guard !isRetired else { return }
      let image = raster.image
      retainedRaster = raster
      if raster.source.captureRegion != nil {
        self.image = nil
        cropLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layoutRaster()
      } else {
        cropLayer.contents = nil
        if self.image !== image { self.image = image }
      }
      if window != nil { onRasterInstalled?(raster) }
    }

    override func layout() { super.layout(); layoutRaster() }

    private func layoutRaster() {
      guard let raster = retainedRaster, let region = raster.source.captureRegion,
        let source = raster.source.agentElement else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      cropLayer.frame = CGRect(x: region.x / source.frame.width * bounds.width,
        y: region.y / source.frame.height * bounds.height,
        width: region.width / source.frame.width * bounds.width,
        height: region.height / source.frame.height * bounds.height)
      CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil, let retainedRaster { onRasterInstalled?(retainedRaster) }
    }

    func uninstall() {
      guard !isRetired else { return }
      isRetired = true
      sceneModel?.unregisterScenePresentation(self)
      sceneModel = nil
      image = nil
      layer?.contents = nil
      cropLayer.contents = nil
      retainedRaster = nil
      onRasterInstalled = nil
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
enum AgentSnapshotPolicy: Equatable, Sendable {
  case display(scale: Double)
  case exact(scale: Double)
  case region(PageRect, scale: Double)

  func captureRect(for element: AgentElement) -> CGRect {
    if case .region(let region, _) = self {
      return CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    }
    return CGRect(x: 0, y: 0, width: element.frame.width, height: element.frame.height)
  }

  func rasterSource(for element: AgentElement) -> SceneRasterSource {
    if case .region(let region, _) = self { return .agentRegion(element, region) }
    return .agent(element)
  }

  func minimumScale(for element: AgentElement) -> Double {
    switch self {
    case .exact(let scale), .region(_, let scale): return scale
    case .display:
      guard let pixels = pixelSize(for: element) else { return 0 }
      let rect = captureRect(for: element)
      return min(pixels.width / rect.width, pixels.height / rect.height)
    }
  }

  func rasterizationScale(for element: AgentElement, displayScale: CGFloat) -> CGFloat {
    let rect = captureRect(for: element), width = rect.width, height = rect.height
    if let pixels = pixelSize(for: element) {
      return min(max(1, displayScale), pixels.width / width, pixels.height / height)
    }
    // A source that cannot produce a valid whole-frame snapshot still must not
    // allocate its uncapped canonical dimensions before reporting that refusal.
    return min(max(1, displayScale), 2048 / max(width, height))
  }

  func pixelSize(for element: AgentElement) -> CGSize? {
    let rect = captureRect(for: element), width = rect.width, height = rect.height
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      rect.minX >= 0, rect.minY >= 0,
      rect.maxX <= element.frame.width + 0.000_001, rect.maxY <= element.frame.height + 0.000_001 else { return nil }
    let density: Double
    switch self {
    case .display(let scale):
      density = min(scale, 2048 / max(width, height), sqrt(4_194_304 / (width * height)))
    case .exact(let scale), .region(_, let scale): density = scale
    }
    guard density.isFinite, density > 0 else { return nil }
    // WebKit derives height from the output width. Quantize that one axis and
    // derive the other, otherwise a very narrow frame can allocate far beyond
    // the predicted height after its width rounds up to one pixel.
    let pixelWidth: Double
    switch self {
    case .display: pixelWidth = floor(width * density)
    case .exact, .region:
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
    if case .region = self, max(pixelWidth, pixelHeight) > 4096 || pixelWidth * pixelHeight > 8_388_608 {
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

extension AgentElement {
  /// Only a proven static SVG can retire its WebKit after preparation. Empty
  /// JavaScript alone says nothing about HTML controls, links or inline code.
  /// This is a rendering choice, not an HTML sanitizer or another SVG renderer.
  var requiresLiveRuntime: Bool {
    guard kind == .web else { return false }
    guard javaScript.isEmpty, css.isEmpty else { return true }
    let drawing = StaticSVGContent()
    let parser = XMLParser(data: Data(html.utf8))
    parser.shouldResolveExternalEntities = false
    parser.delegate = drawing
    return !(parser.parse() && drawing.isDrawing)
  }
}

private final class StaticSVGContent: NSObject, XMLParserDelegate {
  private(set) var isDrawing = false
  private var depth = 0
  private static let elements: Set<String> = ["svg", "g", "defs", "title", "desc", "path", "rect", "circle",
    "ellipse", "line", "polyline", "polygon", "text", "tspan", "textPath", "linearGradient", "radialGradient",
    "stop", "clipPath", "mask", "pattern", "marker", "symbol", "use"]

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]) {
    guard Self.elements.contains(name), depth > 0 || name == "svg",
      attributes.allSatisfy({ key, value in
        let key = key.lowercased()
        if key.hasPrefix("on") || ["style", "tabindex", "contenteditable"].contains(key) { return false }
        if key == "href" || key == "xlink:href" { return value.hasPrefix("#") }
        return true
      }) else { isDrawing = false; parser.abortParsing(); return }
    depth += 1
    isDrawing = true
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    depth -= 1
  }

  func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
    isDrawing = false; parser.abortParsing()
  }

  func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
    publicID: String?, systemID: String?) {
    isDrawing = false; parser.abortParsing()
  }
}

/// Publication can be revoked before WebKit returns. Its submitted backing
/// and executor remain owned by the actual completion, not by the reader task.
@MainActor
final class AgentSnapshotCapture {
  let id = UUID()
  private let reservation: RasterReservation
  private var lease: WebSurfaceLease?
  private var borrow: WebSurfaceBorrow?
  private(set) var isCancelled = false
  private(set) var isComplete = false
  private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  init(reservation: RasterReservation, lease: WebSurfaceLease) {
    precondition(!reservation.isReleased && !lease.isReleased)
    self.reservation = reservation; self.lease = lease
    borrow = try? lease.borrow()
    precondition(borrow != nil)
  }
  func cancel() { isCancelled = true }
  func finish() {
    guard !isComplete else { return }
    isComplete = true; reservation.release(); borrow?.release(); borrow = nil; lease = nil
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
  isolated deinit { reservation.release(); borrow?.release() }
}

/// The reader may time out while WebKit still owns its submitted backing.
/// Completion closes the continuation once; the capture keeps its accounting
/// until WebKit's real callback even if that reader is already gone.
@MainActor
private final class AgentCurrentFrameResult {
  var continuation: CheckedContinuation<RasterLease?, Error>?
  func finish(_ result: Result<RasterLease?, Error>) {
    guard let continuation else {
      if case .success(let raster) = result { raster?.release() }
      return
    }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

@MainActor
final class AgentWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, SceneSourceInstallationOwner {
  private struct WeakPresentation { weak var owner: AgentWebCoordinator? }
  private static var presentations: [ObjectIdentifier: WeakPresentation] = [:]
  private var presentationFocus: InteractiveElementReference?
  private var presentationToken = UUID()
  private let lease: WebSurfaceLease
  private let resources: SceneRenderResources
  private var snapshotPolicy: AgentSnapshotPolicy
  private(set) var snapshotFailure: SceneRenderError?
  private var onState: (JSONValue) -> Bool
  private var onRenderReady: (Bool) -> Void
  private var onSnapshotPrepared: ((RasterLease) -> Void)?
  private var onInteractionReady: (Bool) -> Void
  private var onInteraction: () -> Void = {}
  private var onFailure: (AgentWebSourceFailure) -> Void
  private var renderIsReady = false
  private var isInvalidated = false
  private var activeNavigation: WKNavigation?
  private weak var attachedWebView: WKWebView?
  private var loadedElement: AgentElement?
  private(set) var loadToken: String?
  private var runtimeLoaded = false
  private var fingerRegions: AgentWebFingerRegions?
  func fingerInput(at point: CGPoint, in size: CGSize) -> AgentWebFingerInput {
    guard runtimeLoaded else { return .input }
    return fingerRegions?.input(at: point, in: size) ?? .input
  }
  private func receiveFingerRegions(_ value: Any) {
    guard let next = AgentWebFingerRegions(value) else { fingerRegions = nil; return }
    guard next.revision > (fingerRegions?.revision ?? -1) else { return }
    fingerRegions = next
  }
  private var appliedState: JSONValue?
  private var localStateRevision: UInt64 = 0
  private var stateToApply: JSONValue?
  private var stateApplication: Task<Void, Never>?
  private var stateApplicationID: UUID?
  private var currentCapture: AgentSnapshotCapture?
  private var submittedCaptures: [UUID: AgentSnapshotCapture] = [:]
  var pendingSnapshotCaptures: [AgentSnapshotCapture] { Array(submittedCaptures.values) }
  private var snapshotInFlight = false
  private var needsSnapshot = false
  private var preparationDeadline: Task<Void, Never>?
  private var preparationDeadlineAt: ContinuousClock.Instant?
  private var recoveryAttempts = 0
  private var admissionObserver: NSObjectProtocol?
  private var lastCaptureAdmission: SceneRasterAdmission?
  private var lastCaptureFailure: AgentWebSourceFailure?
  private var readinessGeneration: UInt64 = 0

  init(
    lease: WebSurfaceLease,
    resources: SceneRenderResources = .shared,
    snapshotPolicy: AgentSnapshotPolicy = .display(scale: 2),
    onRenderReady: @escaping (Bool) -> Void = { _ in },
    onInteractionReady: @escaping (Bool) -> Void = { _ in },
    onFailure: @escaping (AgentWebSourceFailure) -> Void = { _ in },
    onState: @escaping (JSONValue) -> Bool
  ) {
    self.lease = lease
    self.resources = resources
    self.snapshotPolicy = snapshotPolicy
    self.onRenderReady = onRenderReady
    self.onInteractionReady = onInteractionReady
    self.onFailure = onFailure
    self.onState = onState
    super.init()
    admissionObserver = NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
      object: resources, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.retryAfterAdmission() }
    }
  }

  func use(onRenderReady: @escaping (Bool) -> Void) {
    guard !isInvalidated else { return }
    self.onRenderReady = onRenderReady
  }

  /// The raster reader takes its pin in the actual capture completion, before
  /// another admission can reclaim the cache entry. Live UI keeps its separate
  /// deferred readiness callback; an image is not an input installation proof.
  func use(onSnapshotPrepared: ((RasterLease) -> Void)?) {
    guard !isInvalidated else { return }
    self.onSnapshotPrepared = onSnapshotPrepared
  }

  func use(onInteractionReady: @escaping (Bool) -> Void) {
    guard !isInvalidated else { return }
    self.onInteractionReady = onInteractionReady
  }

  func use(onInteraction: @escaping () -> Void) {
    guard !isInvalidated else { return }
    self.onInteraction = onInteraction
  }

  func hasLiveSource(_ element: AgentElement) -> Bool {
    guard !isInvalidated, !lease.isReleased, runtimeLoaded, let loadedElement else { return false }
    return appliedState == loadedElement.state && SceneRasterSource.agent(loadedElement) == .agent(element)
  }

  func bindPresentation(to focus: InteractiveElementReference?) {
    guard !isInvalidated else { return }
    if presentationFocus != focus { presentationToken = UUID(); presentationFocus = focus }
    Self.presentations[ObjectIdentifier(self)] = focus == nil ? nil : .init(owner: self)
  }

  func installation(for element: AgentElement) -> SceneSourceInstallation? {
    guard hasLiveSource(element), let loadToken else { return nil }
    return .init(source: .agent(element), runtimeToken: loadToken + "/" + presentationToken.uuidString, owner: self)
  }

  func isShowing(_ installation: SceneSourceInstallation) -> Bool {
    guard let source = installation.source.agentElement, hasLiveSource(source), let loadToken,
      installation.runtimeToken == loadToken + "/" + presentationToken.uuidString,
      let web = attachedWebView else { return false }
    return SceneSourceVisibility.isVisible(web)
  }

  #if os(iOS)
  /// Copies the already displayed native subtree in the Send event itself.
  /// A later JavaScript animation cannot change this immutable regional value.
  static func capturePresented(focus: InteractiveElementReference, element: AgentElement, region: PageRect,
    resources: SceneRenderResources = .shared) throws -> RasterLease? {
    presentations = presentations.filter { $0.value.owner != nil }
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.resources === resources && $0.presentationFocus == focus
        && $0.installation(for: element)?.isInstalled == true
    }
    guard !owners.isEmpty else { return nil }
    guard owners.count == 1 else { throw SceneRenderError.snapshotPending("ambiguous_live_element_" + element.id) }
    let owner = owners[0]
    guard let installation = owner.installation(for: element), installation.isInstalled,
      let web = owner.attachedWebView,
      let pixels = try NotebookSubmittedPixels.capture(view: web,
        physicalSize: .init(width: element.frame.width, height: element.frame.height), region: region, resources: resources),
      installation.isInstalled else { return nil }
    return try pixels.retainRaster(source: .agentRegion(element, region), resources: resources)
  }
  #endif

  /// Explicitly requests a current frame from the installed running context. A missing,
  /// hidden, replaced or ambiguous owner cannot be substituted with cache data
  /// or with a newly booted program.
  static func captureCurrent(focus: InteractiveElementReference, element: AgentElement,
    resources: SceneRenderResources = .shared) async throws -> RasterLease? {
    presentations = presentations.filter { $0.value.owner != nil }
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.resources === resources && $0.presentationFocus == focus
        && $0.installation(for: element)?.isInstalled == true
    }
    guard !owners.isEmpty else { return nil }
    guard owners.count == 1 else { throw SceneRenderError.snapshotPending("ambiguous_live_element_" + element.id) }
    return try await owners[0].captureCurrent(element: element)
  }

  static func resumeCurrent(focus: InteractiveElementReference) async {
    for owner in presentations.values.compactMap(\.owner) where owner.presentationFocus == focus && !owner.isInvalidated {
      if let web = owner.attachedWebView { _ = try? await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web) }
    }
  }

  /// The existing spatial owner keeps this viewport until the writer confirms
  /// its stopped model. A failed write/capture resumes it instead of losing it.
  static func checkpointCurrent(focus: InteractiveElementReference, element: AgentElement,
    persist: @MainActor (JSONValue) async throws -> Bool,
    resources: SceneRenderResources = .shared) async throws -> (AgentElement, RasterLease) {
    presentations = presentations.filter { $0.value.owner != nil }
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.resources === resources && $0.presentationFocus == focus && $0.hasLiveSource(element)
    }
    guard owners.count == 1, let owner = owners.first, let web = owner.attachedWebView,
      let token = owner.loadToken else { throw SceneRenderError.snapshotPending("program_checkpoint_owner") }
    let borrow = try owner.lease.borrow(); defer { borrow.release() }
    let revision = owner.localStateRevision
    do {
      let value = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
      try Task.checkCancellation()
      guard owner.accepts(token), owner.localStateRevision == revision, owner.hasLiveSource(element) else { throw CancellationError() }
      guard try await persist(value) else { throw SceneRenderError.snapshotPending("program_checkpoint_not_accepted") }
      try Task.checkCancellation()
      guard owner.accepts(token), owner.localStateRevision == revision, let current = owner.loadedElement,
        AgentProgramSource(current) == AgentProgramSource(element),
        current.state == element.state || current.state == value else { throw CancellationError() }
      let accepted = current.updating(state: value)
      owner.loadedElement = accepted; owner.appliedState = value; owner.stateToApply = nil
      guard let pixels = try await owner.captureCurrent(element: accepted) else {
        throw SceneRenderError.snapshotPending("program_checkpoint_picture")
      }
      if Task.isCancelled { pixels.release(); throw CancellationError() }
      return (accepted, pixels)
    } catch {
      if owner.accepts(token) {
        _ = try? await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
      }
      throw error
    }
  }

  private func captureCurrent(element: AgentElement) async throws -> RasterLease? {
    try Task.checkCancellation()
    guard let installation = installation(for: element), installation.isInstalled,
      let web = attachedWebView, let token = loadToken else { return nil }
    let policy = snapshotPolicy
    guard let pixels = policy.pixelSize(for: element),
      let configuration = Self.snapshotConfiguration(for: element, policy: policy, backingScale: snapshotScale(of: web)),
      pixels.width < CGFloat(Int.max - 2), pixels.height < CGFloat(Int.max - 2),
      let reservation = resources.reserveWebSnapshot(pixelSize: pixels)
    else { throw SceneRenderError.resourceLimit }
    let capture = AgentSnapshotCapture(reservation: reservation, lease: lease)
    submittedCaptures[capture.id] = capture
    let result = AgentCurrentFrameResult()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        result.continuation = continuation
        let deadline = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(8)) } catch { return }
          result.finish(.failure(SceneRenderError.snapshotPending("live_capture_" + element.id)))
        }
        web.takeSnapshot(with: configuration) { [weak self, capture, installation] image, error in
          defer {
            deadline.cancel(); capture.finish(); self?.submittedCaptures[capture.id] = nil
          }
          guard let self, accepts(token), !capture.isCancelled, installation.isInstalled,
            hasLiveSource(element) else { result.finish(.success(nil)); return }
          if let error { result.finish(.failure(error)); return }
          guard let image else { result.finish(.failure(SceneRenderError.snapshotPending(element.id))); return }
          guard let raster = resources.storeWebSnapshot(image, for: policy.rasterSource(for: element), reservation: reservation)
          else { result.finish(.failure(SceneRenderError.resourceLimit)); return }
          guard raster.pixelScale + 0.000_001 >= policy.minimumScale(for: element) else {
            raster.release(); result.finish(.failure(SceneRenderError.snapshotPending("live_capture_density_" + element.id))); return
          }
          result.finish(.success(raster))
        }
      }
    }, onCancel: {
      Task { @MainActor in result.finish(.failure(CancellationError())) }
    })
  }

  func use(onFailure: @escaping (AgentWebSourceFailure) -> Void) {
    guard !isInvalidated else { return }
    self.onFailure = onFailure
  }

  func use(onState: @escaping (JSONValue) -> Bool) {
    guard !isInvalidated else { return }
    self.onState = onState
  }

  /// Dismantling ends this owner session. Neither a queued script message nor an
  /// already running WebKit completion may publish into its next owner.
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    #if os(iOS)
      if let web = attachedWebView { NotebookInteractionDiagnostics.retire(web) }
    #endif
    Self.presentations[ObjectIdentifier(self)] = nil
    presentationFocus = nil; presentationToken = UUID()
    loadToken = nil
    loadedElement = nil
    appliedState = nil
    stateToApply = nil
    activeNavigation = nil
    renderIsReady = false
    stateApplicationID = nil; stateApplication?.cancel(); stateApplication = nil
    preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
    currentCapture?.cancel(); currentCapture = nil
    onRenderReady = { _ in }
    onSnapshotPrepared = nil
    onInteractionReady = { _ in }
    onInteraction = {}
    onFailure = { _ in }
    onState = { _ in false }
    attachedWebView?.evaluateJavaScript("void notebookProgram.dispose().catch(()=>{})", completionHandler: nil)
    attachedWebView?.stopLoading()
    attachedWebView?.navigationDelegate = nil
    attachedWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    attachedWebView = nil
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
    admissionObserver = nil
  }

  private func retryAfterAdmission() {
    guard snapshotFailure == .resourceLimit, runtimeLoaded, let web = attachedWebView,
      let token = loadToken, accepts(token), let failure = lastCaptureFailure,
      failure.policy == snapshotPolicy, loadedElement.map({ SceneRasterSource.agent($0) == .agent(failure.source) }) == true,
      failure.canResumeCapture(with: resources.rasterAdmission) else { return }
    snapshotFailure = nil; lastCaptureFailure = nil
    beginPreparationDeadline(token: token, policy: snapshotPolicy)
    captureSnapshot(of: web, token: token)
  }

  private func accepts(_ token: String) -> Bool {
    !isInvalidated && !lease.isReleased && loadToken == token
  }

  func load(_ element: AgentElement, policy: AgentSnapshotPolicy? = nil, in webView: WKWebView) {
    guard !isInvalidated, !lease.isReleased, attachedWebView === webView else { return }
    let policyChanged = policy.map { $0 != snapshotPolicy } ?? false
    if policyChanged { readinessGeneration &+= 1 }
    if let policy { snapshotPolicy = policy }
    guard loadedElement != element else {
      if policyChanged, runtimeLoaded, appliedState == element.state, let token = loadToken {
        snapshotFailure = nil
        setRenderReady(false, token: token)
        beginPreparationDeadline(token: token, policy: snapshotPolicy)
        captureSnapshot(of: webView, token: token)
      }
      // Updating the representable replaces its callbacks, not its request.
      // Readiness is published only by an actual preparation transition.
      return
    }
    if let previous = loadedElement, AgentProgramSource(previous) == AgentProgramSource(element) {
      loadedElement = element
      if previous.state != element.state {
        #if os(iOS)
          NotebookInteractionDiagnostics.state(element.state, stage: "native_projection", webView: webView, revision: localStateRevision)
        #endif
        stateToApply = appliedState == element.state ? nil : element.state
      }
      if policyChanged || previous.state != element.state || previous.frame.width != element.frame.width || previous.frame.height != element.frame.height {
        snapshotFailure = nil
        if let token = loadToken {
          setRenderReady(false, token: token)
          beginPreparationDeadline(token: token)
        }
        applyCurrentState()
      }
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
    readinessGeneration &+= 1
    stateApplicationID = nil; stateApplication?.cancel(); stateApplication = nil
    currentCapture?.cancel(); currentCapture = nil
    snapshotInFlight = false; needsSnapshot = false; runtimeLoaded = false
    fingerRegions = nil
    activeNavigation = nil
    webView.evaluateJavaScript("void window.notebookProgram?.dispose().catch(()=>{})", completionHandler: nil)
    webView.stopLoading()
    let token = "\(lease.id.uuidString)/\(UUID().uuidString)"
    loadToken = token
    #if os(iOS)
      NotebookInteractionDiagnostics.bind(webView, elementID: element.id, token: token, ready: false)
    #endif
    loadedElement = element
    appliedState = element.state
    localStateRevision = 0; stateToApply = nil
    snapshotFailure = nil; lastCaptureFailure = nil
    renderIsReady = false
    publishRenderReadiness(false, token: token)
    publishInteractionReadiness(false, token: token)
    beginPreparationDeadline(token: token)
    activeNavigation = webView.loadHTMLString(Self.document(for: element, token: token), baseURL: nil)
  }

  private func applyCurrentState() {
    guard runtimeLoaded, stateApplication == nil, let token = loadToken, accepts(token) else { return }
    let id = UUID(); stateApplicationID = id
    stateApplication = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if stateApplicationID == id { stateApplicationID = nil; stateApplication = nil } }
      while !Task.isCancelled, accepts(token), let web = attachedWebView,
        let element = loadedElement, let next = stateToApply {
        stateToApply = nil
        let expectedRevision = localStateRevision
        #if os(iOS)
          NotebookInteractionDiagnostics.state(next, stage: "native_apply_submitted", webView: web, revision: expectedRevision)
        #endif
        do {
          let state = try JSONSerialization.jsonObject(with: JSONEncoder().encode(next), options: .fragmentsAllowed)
          let accepted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            web.callAsyncJavaScript("return await window.notebookProgram.apply(state, revision);",
              arguments: ["state": state, "revision": String(expectedRevision)], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Bool == true)
                case .failure(let error): continuation.resume(throwing: error)
                }
              }
          }
          guard accepts(token), !Task.isCancelled else { return }
          #if os(iOS)
            NotebookInteractionDiagnostics.state(next, stage: "native_apply_completed", webView: web, revision: expectedRevision, accepted: accepted)
          #endif
          if accepted, localStateRevision == expectedRevision { appliedState = next }
        } catch {
          if accepts(token), !Task.isCancelled { record(error, kind: "render_error", token: token, source: element) }
          return
        }
        guard accepts(token), !Task.isCancelled else { return }
      }
      guard accepts(token), !Task.isCancelled, let web = attachedWebView,
        appliedState == loadedElement?.state else { return }
      captureSnapshot(of: web, token: token)
    }
  }

  private func beginPreparationDeadline(token: String, policy: AgentSnapshotPolicy? = nil) {
    preparationDeadlineAt = .now + .seconds(8)
    retargetPreparationDeadline(token: token, policy: policy)
  }

  private func retargetPreparationDeadline(token: String, policy: AgentSnapshotPolicy?) {
    guard let source = loadedElement else { return }
    let deadline = preparationDeadlineAt ?? (.now + .seconds(8))
    preparationDeadlineAt = deadline; preparationDeadline?.cancel()
    preparationDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(until: deadline) } catch { return }
      guard let self, !Task.isCancelled, accepts(token) else { return }
      currentCapture?.cancel(); currentCapture = nil
      fail(.init(kind: "preparation_timeout", elementID: source.id,
        message: "WebKit did not complete source preparation and a snapshot before the deadline."),
        token: token, source: source, policy: policy)
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
    #if os(iOS)
      if object["kind"] as? String == "interactionObservation", let web = attachedWebView {
        NotebookInteractionDiagnostics.dom(object, webView: web, elementID: element.id, token: token, ready: runtimeLoaded)
        return
      }
    #endif
    if object["kind"] as? String == "diagnostic",
      let kind = object["category"] as? String, let message = object["message"] as? String {
      let diagnostic = RenderDiagnostic(kind: kind, elementID: element.id, message: String(message.prefix(2000)))
      if kind == "javascript_error" || kind == "program_ready_error" { fail(diagnostic, token: token) }
      else { resources.record(diagnostic, for: element) }
    } else if object["kind"] as? String == "fingerRegions", let value = object["value"] {
      receiveFingerRegions(value)
    } else if object["kind"] as? String == "interaction", runtimeLoaded {
      onInteraction()
    } else if object["kind"] as? String == "state",
      let sequence = (object["revision"] as? String).flatMap(UInt64.init), sequence > localStateRevision,
      let state = object["value"], let value = Self.decodeState(state) {
      // This is already the program's current value, not a request to apply an
      // older persistence echo. A queued native application also carries this
      // revision into WebKit, where even an as-yet-undelivered input can reject it.
      localStateRevision = sequence
      // Passive renderers and an unfocused program may compute local state,
      // but have not admitted a human write. Only the input owner's positive
      // acknowledgement advances the canonical live value; it is not a save.
      let admitted = onState(value)
      #if os(iOS)
        if let web = attachedWebView {
          NotebookInteractionDiagnostics.state(value, stage: "program_commit", webView: web, revision: sequence, accepted: admitted)
        }
      #endif
      guard admitted else {
        if appliedState != loadedElement?.state {
          stateToApply = loadedElement?.state; applyCurrentState()
        }
        return
      }
      appliedState = value; stateToApply = nil
      if runtimeLoaded {
        preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
        currentCapture?.cancel()
      }
      setRenderReady(false, token: token)
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
      let token = loadToken, accepts(token), let element = loadedElement else { return }
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
      await window.notebookProgram.start({requiresReady:\(!element.javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || element.html.localizedCaseInsensitiveContains("<script"))});
      \(frameReadiness)
      for (const image of document.images) if (!image.naturalWidth) window.notebookDiagnostic('load_error', 'Image failed to load');
      if (Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) > innerHeight + 1 || Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) > innerWidth + 1) window.notebookDiagnostic('overflow', 'Content exceeds its frame');
      return window.notebookFingerInput.start();
      """,
      arguments: [:], in: nil, in: .page,
      completionHandler: { [weak self, weak webView] result in
        guard let self, let webView, accepts(token), attachedWebView === webView else { return }
        switch result {
        case .success(let value):
          receiveFingerRegions(value)
          runtimeLoaded = true
          #if os(iOS)
            if let element = loadedElement { NotebookInteractionDiagnostics.bind(webView, elementID: element.id, token: token, ready: true) }
          #endif
          publishInteractionReadiness(true, token: token)
          applyCurrentState()
        case .failure(let error):
          record(error, kind: "render_error", token: token, source: element)
          setRenderReady(false, token: token)
        }
      }
    )
  }

  private func captureSnapshot(of webView: WKWebView, token: String) {
    guard accepts(token), let element = loadedElement, appliedState == element.state else { return }
    if snapshotInFlight { needsSnapshot = true; return }
    lastCaptureAdmission = resources.rasterAdmission
    let policy = snapshotPolicy
    retargetPreparationDeadline(token: token, policy: policy)
    guard let pixels = policy.pixelSize(for: element),
      let configuration = Self.snapshotConfiguration(for: element, policy: policy, backingScale: snapshotScale(of: webView)),
      pixels.width.isFinite, pixels.height.isFinite,
      pixels.width < CGFloat(Int.max - 2), pixels.height < CGFloat(Int.max - 2),
      let reservation = resources.reserveWebSnapshot(pixelSize: pixels)
    else {
      fail(.init(kind: "resource_limit", elementID: element.id,
        message: "The requested snapshot exceeds the raster resource budget."), token: token, policy: policy)
      return
    }
    snapshotInFlight = true
    let capture = holdSubmittedSnapshot(reservation)
    webView.takeSnapshot(with: configuration) { [weak self, capture] image, error in
      defer { capture.finish(); self?.submittedCaptures[capture.id] = nil }
      guard let self else { return }
      if accepts(token) { snapshotInFlight = false; currentCapture = nil }
      if !capture.isCancelled {
        completeSnapshot(image, error: error, token: token, element: element, reservation: reservation, policy: policy)
      }
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
    element: AgentElement, reservation: RasterReservation, policy: AgentSnapshotPolicy? = nil) {
    defer { reservation.release() }
    guard accepts(token), let loadedElement,
      appliedState == element.state,
      SceneRasterSource.agent(loadedElement) == .agent(element) else { return }
    if let error {
      record(error, kind: "snapshot_error", token: token, source: element, policy: policy ?? snapshotPolicy)
    } else if let image {
      let capturedPolicy = policy ?? snapshotPolicy
      let source = capturedPolicy.rasterSource(for: element)
      if resources.storeWebSnapshot(image, for: source, reservation: reservation) != nil {
        // A capture submitted before a density change is a useful fallback,
        // but cannot acknowledge the newer demand. The one queued capture
        // uses the latest policy without reloading the running program.
        if (policy == nil || policy == snapshotPolicy),
          resources.image(for: source, minimumScale: capturedPolicy.minimumScale(for: element)) != nil {
          preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil; lastCaptureFailure = nil
          setRenderReady(true, token: token)
          if let onSnapshotPrepared,
            let raster = resources.retainRaster(for: source, minimumScale: capturedPolicy.minimumScale(for: element)) {
            let generation = readinessGeneration
            // Keep the pixels pinned now, but deliver outside WebKit's capture
            // callback, like the existing readiness event. A consumer may close
            // its window immediately; the submitted capture must finish first.
            Task { @MainActor [weak self] in
              guard let self, accepts(token), readinessGeneration == generation else { raster.release(); return }
              onSnapshotPrepared(raster)
            }
          }
        } else if capturedPolicy != snapshotPolicy { needsSnapshot = true }
        else {
          fail(.init(kind: "snapshot_error", elementID: element.id,
            message: "The completed snapshot does not contain the requested pixel density."), token: token, policy: capturedPolicy)
        }
      } else {
        fail(.init(kind: "resource_limit", elementID: element.id,
          message: "The completed raster could not be admitted to the resource budget."), token: token, policy: capturedPolicy)
      }
    } else {
      fail(.init(kind: "snapshot_error", elementID: element.id,
        message: "WebKit returned no image for the completed surface."), token: token, policy: policy ?? snapshotPolicy)
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

  private func record(_ error: any Error, kind: String, token: String, source: AgentElement? = nil, policy: AgentSnapshotPolicy? = nil) {
    guard accepts(token), let element = source ?? loadedElement else { return }
    fail(.init(kind: kind, elementID: element.id,
      message: String(error.localizedDescription.prefix(2000))), token: token, source: element, policy: policy)
  }

  private func fail(_ diagnostic: RenderDiagnostic, token: String, source: AgentElement? = nil, policy: AgentSnapshotPolicy? = nil) {
    guard accepts(token), let loadedElement, let element = source ?? self.loadedElement,
      SceneRasterSource.agent(loadedElement) == .agent(element),
      policy == nil || policy == snapshotPolicy else { return }
    let failure = AgentWebSourceFailure(diagnostic: diagnostic, source: element,
      leaseID: lease.id, loadToken: token, policy: policy,
      rasterAdmission: policy == nil ? nil : lastCaptureAdmission)
    lastCaptureFailure = policy == nil ? nil : failure
    if policy == nil {
      // A terminal program/navigation failure revokes live installation too.
      // Only a failed capture can leave a functioning program interactive.
      runtimeLoaded = false; needsSnapshot = false
      publishInteractionReadiness(false, token: token)
    }
    snapshotFailure = diagnostic.kind == "resource_limit" ? .resourceLimit : .snapshotPending(element.id)
    preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
    currentCapture?.cancel(); currentCapture = nil
    resources.record(diagnostic, for: element)
    setRenderReady(false, token: token)
    Task { @MainActor [weak self] in
      guard let self, accepts(token), self.loadedElement.map({ SceneRasterSource.agent($0) == .agent(failure.source) }) == true,
        failure.policy == nil || (failure.policy == snapshotPolicy && lastCaptureFailure == failure) else { return }
      onFailure(failure)
    }
  }

  private func setRenderReady(_ ready: Bool, token: String) {
    guard accepts(token), renderIsReady != ready else { return }
    renderIsReady = ready
    publishRenderReadiness(ready, token: token)
  }

  private func publishRenderReadiness(_ ready: Bool, token: String) {
    let generation = readinessGeneration
    Task { @MainActor [weak self] in
      guard let self, accepts(token), readinessGeneration == generation,
        renderIsReady == ready else { return }
      onRenderReady(ready)
    }
  }

  private func publishInteractionReadiness(_ ready: Bool, token: String) {
    Task { @MainActor [weak self] in
      guard let self, accepts(token), runtimeLoaded == ready else { return }
      onInteractionReady(ready)
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
    configuration.rect = policy.captureRect(for: element)
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
      // This scroll view is a transparent canvas source, not a scrolling
      // screen beneath navigation chrome. Edge decorations must not become
      // authored pixels in either its live surface or a WebKit snapshot.
      webView.scrollView.topEdgeEffect.isHidden = true
      webView.scrollView.bottomEdgeEffect.isHidden = true
      webView.scrollView.leftEdgeEffect.isHidden = true
      webView.scrollView.rightEdgeEffect.isHidden = true
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
    #if os(iOS)
      let interactionScript = NotebookInteractionDiagnostics.script
    #else
      let interactionScript = ""
    #endif
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
        \(interactionScript)
        for (const kind of ['pointerdown', 'keydown']) addEventListener(kind, event => {
          if (event.isTrusted && (kind === 'keydown' || window.notebookFingerInput.forEvent(event) === 'input'))
            window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'interaction'});
        }, true);
        window.notebookDiagnostic = (category, message) => window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'diagnostic',category,message:String(message)});
        addEventListener('error', event => window.notebookDiagnostic('javascript_error', event.message || 'Resource load error'));
        addEventListener('unhandledrejection', event => window.notebookDiagnostic('javascript_error', event.reason));
        \(NotebookProgramBridge.script)
        window.notebookProgram=createNotebookProgram({state:\(state),
          onCommit:(value,revision)=>window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'state',value,revision}),
          report:window.notebookDiagnostic});
        window.notebook=notebookProgram.api;
        \(AgentWebFingerRegions.script)
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
