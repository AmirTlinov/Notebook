import NotebookCore
import SwiftUI
import WebKit

/// The accepted source owns its one native executor before SwiftUI mounts it.
/// A representable borrows this exact session; mounting never constructs or
/// navigates a replacement browser. Retirement keeps the coordinator's existing
/// checkpoint/physical-capture tail rather than returning its grant early.
@MainActor
final class AgentWebNativeSession {
  let lease: WebSurfaceLease
  let coordinator: AgentWebCoordinator
  let webView: WKWebView
  private(set) var isRetired = false

  init(lease: WebSurfaceLease, resources: SceneRenderResources = .shared,
    snapshotPolicy: AgentSnapshotPolicy) {
    self.lease = lease
    coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      snapshotPolicy: snapshotPolicy, onState: { _, _ in false })
    webView = AgentWebCoordinator.makeWebView(coordinator: coordinator)
  }

  func retire() {
    guard !isRetired else { return }
    isRetired = true
    // Revoke this exact installation before retirement clears its callbacks.
    // An already installed raster can then take over without another update.
    webView.removeFromSuperview()
    coordinator.didDetachPresentation()
    coordinator.retireAfterCheckpoint()
  }

  isolated deinit { retire() }
}

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
  var stateCreditBytes: Int = 0

  func canResumeCapture(with current: SceneRasterAdmission, restartingRuntime: Bool = false) -> Bool {
    guard diagnostic.kind == "resource_limit", let policy, let rasterAdmission else { return false }
    return Self.captureFitsAfterImprovement(source: source, policy: policy, previous: rasterAdmission, current: current,
      restartingBytes: restartingRuntime ? stateCreditBytes : 0)
  }

  static func captureFitsAfterImprovement(source: AgentElement, policy: AgentSnapshotPolicy,
    previous: SceneRasterAdmission, current: SceneRasterAdmission, restartingBytes: Int = 0) -> Bool {
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
    return improved && current.fits(additionalBytes: budget.capture + restartingBytes, additionalCount: 1)
  }
}

#if os(iOS)
  struct AgentWebElementView: UIViewRepresentable {
    let element: AgentElement
    var stateBasis: NotebookProgramStateBasis? = nil
    var programOwner: NotebookAppModel? = nil
    var allowsStateCommits = true
    let session: AgentWebNativeSession
    let snapshotPolicy: AgentSnapshotPolicy
    var preparesPassiveSnapshot = true
    var showsContent = true
    var focus: InteractiveElementReference? = nil
    let onRenderReady: (Bool) -> Void
    var onInteractionReady: (Bool) -> Void = { _ in }
    var onInteraction: () -> Void = {}
    var onInstalled: (SceneSourceInstallation) -> Void = { _ in }
    var onFramePainted: (SceneSourceInstallation) -> Void = { _ in }
    var onFailure: (AgentWebSourceFailure) -> Void = { _ in }
    let onState: NotebookProgramStateWriter

    func makeCoordinator() -> AgentWebCoordinator {
      session.coordinator
    }

    private var physicalSize: CGSize {
      CGSize(width: element.frame.width, height: element.frame.height)
    }

    func makeUIView(context: Context) -> PhysicalWebViewport {
      let view = PhysicalWebViewport(
        webView: session.webView,
        contentSize: physicalSize, holdsFingerInput: true)
      // The camera projects WebKit's existing backing. Rasterizing this outer
      // layer again can retain a minified copy across a camera refinement.
      view.layer.shouldRasterize = false
      return view
    }

    static func dismantleUIView(_ view: PhysicalWebViewport, coordinator: AgentWebCoordinator) {
      view.retire()
      coordinator.didDetachPresentation()
    }

    func updateUIView(_ view: PhysicalWebViewport, context: Context) {
      guard !session.isRetired, let webView = view.webView else { return }
      view.setContentSize(physicalSize)
      view.layoutIfNeeded()
      configure(context.coordinator, webView: webView)
      view.onInstalled = { [weak coordinator = context.coordinator] in
        guard let installation = coordinator?.installation(for: element) else { return }
        onInstalled(installation)
      }
      // The native owner reveals its output before it acknowledges installation.
      // An outer SwiftUI opacity may be applied after updateUIView and supplies
      // no subsequent mount/layout event to finish that same installation.
      UIView.performWithoutAnimation { view.alpha = showsContent ? 1 : 0 }
      view.onInstalled?()
    }

    /// Called by the accepted preparation request, before its @State update
    /// schedules native mounting. The same configuration handles later edits.
    func prepare() {
      guard !session.isRetired else { return }
      if session.webView.bounds.size != physicalSize {
        session.webView.bounds = CGRect(origin: .zero, size: physicalSize)
      }
      configure(session.coordinator, webView: session.webView, mounted: session.webView.superview != nil)
    }

    private func configure(_ coordinator: AgentWebCoordinator, webView: WKWebView, mounted: Bool = true) {
      guard !session.isRetired else { return }
      coordinator.use(onRenderReady: onRenderReady)
      coordinator.use(onInteractionReady: onInteractionReady)
      coordinator.use(onInteraction: onInteraction)
      coordinator.use(onFramePainted: onFramePainted)
      coordinator.use(onSourceInstalled: onInstalled)
      coordinator.bindPresentation(to: focus)
      coordinator.use(onFailure: onFailure)
      coordinator.use(onState: onState, enabled: allowsStateCommits)
      coordinator.programOwner = programOwner
      // An unmounted source can navigate, but cannot certify a physical image.
      // The native handoff enables the same producer if a bridge needs pixels.
      coordinator.use(passiveSnapshot: mounted && preparesPassiveSnapshot)
      coordinator.load(element, basis: stateBasis, policy: snapshotPolicy, in: webView)
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

    override func layoutSubviews() {
      super.layoutSubviews(); layoutRaster(); updateSampling()
      // SwiftUI can install the image before assigning the representable its
      // first nonempty bounds. That earlier callback cannot certify pixels;
      // layout must deliver the real installation, without an unrelated edit.
      if let retainedRaster, window != nil { onRasterInstalled?(retainedRaster) }
    }

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
      if let retainedRaster { onRasterInstalled?(retainedRaster) }
    }

    /// Window transfer preserves this presenter's pixels. Actual dismantle or
    /// the model's durable shutdown ends its lease even if UIKit caches the view.
    /// Other borrowers of the same cache entry are not revoked.
    func uninstall() {
      guard !isRetired else { return }
      isRetired = true
      if let retainedRaster { onRasterInstalled?(retainedRaster) }
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
    var stateBasis: NotebookProgramStateBasis? = nil
    var programOwner: NotebookAppModel? = nil
    var allowsStateCommits = true
    let session: AgentWebNativeSession
    let snapshotPolicy: AgentSnapshotPolicy
    var preparesPassiveSnapshot = true
    var showsContent = true
    var focus: InteractiveElementReference? = nil
    let onRenderReady: (Bool) -> Void
    var onInteractionReady: (Bool) -> Void = { _ in }
    var onInteraction: () -> Void = {}
    var onInstalled: (SceneSourceInstallation) -> Void = { _ in }
    var onFramePainted: (SceneSourceInstallation) -> Void = { _ in }
    var onFailure: (AgentWebSourceFailure) -> Void = { _ in }
    let onState: NotebookProgramStateWriter

    func makeCoordinator() -> AgentWebCoordinator {
      session.coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
      session.webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: AgentWebCoordinator) {
      webView.removeFromSuperview()
      coordinator.didDetachPresentation()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      guard !session.isRetired else { return }
      configure(context.coordinator, webView: webView)
      webView.alphaValue = showsContent ? 1 : 0
      if let installation = context.coordinator.installation(for: element) { onInstalled(installation) }
    }

    func prepare() {
      guard !session.isRetired else { return }
      let size = CGSize(width: element.frame.width, height: element.frame.height)
      if session.webView.frame.size != size { session.webView.setFrameSize(size) }
      configure(session.coordinator, webView: session.webView, mounted: session.webView.superview != nil)
    }

    private func configure(_ coordinator: AgentWebCoordinator, webView: WKWebView, mounted: Bool = true) {
      guard !session.isRetired else { return }
      coordinator.use(onRenderReady: onRenderReady)
      coordinator.use(onInteractionReady: onInteractionReady)
      coordinator.use(onInteraction: onInteraction)
      coordinator.use(onFramePainted: onFramePainted)
      coordinator.use(onSourceInstalled: onInstalled)
      coordinator.bindPresentation(to: focus)
      coordinator.use(onFailure: onFailure)
      coordinator.use(onState: onState, enabled: allowsStateCommits)
      coordinator.programOwner = programOwner
      coordinator.use(passiveSnapshot: mounted && preparesPassiveSnapshot)
      coordinator.load(element, basis: stateBasis, policy: snapshotPolicy, in: webView)
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
      if let retainedRaster { onRasterInstalled?(retainedRaster) }
    }

    func uninstall() {
      guard !isRetired else { return }
      isRetired = true
      if let retainedRaster { onRasterInstalled?(retainedRaster) }
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
  let programPackage: String?
  init(_ element: AgentElement) {
    id = element.id; kind = element.kind; source = element.source
    html = element.html; css = element.css; javaScript = element.javaScript; programPackage = element.programPackage
  }
}

extension AgentElement {
  /// Only a proven static SVG can avoid a persistent WebKit runtime. Empty
  /// JavaScript alone says nothing about HTML controls, links or inline code.
  /// This is a rendering choice, not an HTML sanitizer or another SVG renderer.
  var requiresLiveRuntime: Bool {
    guard kind == .web else { return false }
    guard javaScript.isEmpty, css.isEmpty, programPackage == nil else { return true }
    return StaticSVGClassification.shared.kind(html) == .runtime
  }

  /// A self-contained viewport with outlined glyphs has no browser layout or
  /// font dependency. Keep text/CSS and intrinsic HTML sizing with WebKit rather
  /// than silently substituting fonts or changing the picture's placement.
  var usesNativeSVGRaster: Bool {
    kind == .web && javaScript.isEmpty && css.isEmpty && programPackage == nil
      && frame.width > 0 && frame.height > 0 && frame.width <= 16_384 && frame.height <= 16_384
      && frame.width * frame.height <= 16_777_216
      && html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg")
      && StaticSVGClassification.shared.kind(html) == .vector
  }

}

/// XML proof belongs to immutable source, not a camera frame. The thread-safe
/// cache uses 128-entry / 4 MiB eviction targets for keys, not rendered content.
/// Equality is the entire source string; no truncated digest can certify code.
private final class StaticSVGClassification: @unchecked Sendable {
  static let shared = StaticSVGClassification()
  private let results = NSCache<NSString, NSNumber>()
  private init() { results.countLimit = 128; results.totalCostLimit = 4 * 1024 * 1024 }
  enum Kind: Int { case runtime, browser, vector }
  func kind(_ html: String) -> Kind {
    let key = html as NSString
    if let hit = results.object(forKey:key) { return Kind(rawValue: hit.intValue)! }
    let drawing = StaticSVGContent(), bytes = Data(html.utf8)
    let parser = XMLParser(data:bytes)
    parser.shouldResolveExternalEntities = false; parser.delegate = drawing
    let value: Kind = parser.parse() && drawing.isDrawing ? (drawing.isVectorViewport ? .vector : .browser) : .runtime
    results.setObject(NSNumber(value:value.rawValue),forKey:key,cost:bytes.count)
    return value
  }
}

private final class StaticSVGContent: NSObject, XMLParserDelegate {
  private(set) var isDrawing = false
  private(set) var isVectorViewport = false
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
    if depth == 0 {
      isVectorViewport = attributes["width"] == "100%" && attributes["height"] == "100%"
        && attributes["x"] == nil && attributes["y"] == nil
    }
    if ["text", "tspan", "textPath"].contains(name) { isVectorViewport = false }
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
  private var reservation: RasterReservation?
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
  /// The validated temporary pixels now own this exact grant. WebKit's
  /// surface borrow still ends only at the submitted callback's completion.
  func transferReservationToCut() {
    precondition(!isComplete && reservation != nil)
    reservation = nil
  }
  func finish() {
    guard !isComplete else { return }
    isComplete = true; reservation?.release(); reservation = nil
    borrow?.release(); borrow = nil; lease = nil
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
  isolated deinit { reservation?.release(); borrow?.release() }
}

private enum AgentCurrentFrameDestination: Equatable { case cache, acceptedTurn }

@MainActor
private enum AgentCurrentFrame {
  case raster(RasterLease)
  case cut(SceneRasterCut)
}

/// The reader may time out while WebKit still owns its submitted backing.
/// Completion closes the continuation once; the capture keeps its accounting
/// until WebKit's real callback even if that reader is already gone.
@MainActor
private final class AgentCurrentFrameResult {
  var continuation: CheckedContinuation<AgentCurrentFrame?, Error>?
  func finish(_ result: Result<AgentCurrentFrame?, Error>) {
    guard let continuation else {
      if case .success(.some(.raster(let raster))) = result { raster.release() }
      return
    }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

@MainActor
final class AgentWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, SceneSourceInstallationOwner {
  private final class Presentation {
    weak var visibleOwner: AgentWebCoordinator?
    var retiringOwner: AgentWebCoordinator?
    var retiringWeb: WKWebView?
    var owner: AgentWebCoordinator? { retiringOwner ?? visibleOwner }
    init(owner: AgentWebCoordinator) { visibleOwner = owner }
  }
  private static var presentations: [ObjectIdentifier: Presentation] = [:]
  weak var programOwner: NotebookAppModel?
  struct ModelCheckpoint {
    let source: AgentElement
    let basis: NotebookProgramStateBasis
  }
  private var checkpointTask: Task<ModelCheckpoint, Error>?
  private var stateTransfer: NotebookProgramStateTransfer?
  private var allowsStateCommits = true
  private var commitsClosedBeforeReady = false
  private var restartsAfterBoundary = false
  private var initialStateEncoding: NotebookProgramStateEncoding?
  private var checkpointID: UUID?
  private var checkpointedSource: AgentElement?
  private var frozenCheckpoint: (snapshot: NotebookProgramStateTransfer.Checkpoint, basis: NotebookProgramStateBasis, rendered: AgentElement, revision: UInt64)?
  private var checkpointSelection: ProgramSemanticSelection?
  private var checkpointWasCaptured = false
  private var attentionPauseID: UUID? {
    didSet {
      #if os(iOS)
      attachedWebView?.isUserInteractionEnabled = attentionPauseID == nil
      #endif
    }
  }
  private var retirementTask: Task<Void, Never>?
  private var presentationFocus: InteractiveElementReference?
  private var presentationToken = UUID()
  private let lease: WebSurfaceLease
  private let resources: SceneRenderResources
  let programAssets = NotebookProgramAssets()
  var programStore: NotebookStore?
  private var programLoadTask: Task<Void, Never>?
  private var packageNavigationURL: URL?
  private var snapshotPolicy: AgentSnapshotPolicy
  private(set) var snapshotFailure: SceneRenderError?
  private var onState: NotebookProgramStateWriter
  private var onRenderReady: (Bool) -> Void
  private var onSnapshotPrepared: ((RasterLease) -> Void)?
  private var onInteractionReady: (Bool) -> Void
  private var onInteraction: () -> Void = {}
  private var onFramePainted: (SceneSourceInstallation) -> Void = { _ in }
  private var onSourceInstalled: (SceneSourceInstallation) -> Void = { _ in }
  private var publishedInstallation: SceneSourceInstallation?
  private var onFailure: (AgentWebSourceFailure) -> Void
  var onSessionSuperseded: () -> Void = {}
  private var renderIsReady = false
  private var isInvalidated = false
  private var activeNavigation: WKNavigation?
  private weak var attachedWebView: WKWebView?
  private var loadedElement: AgentElement?
  private var programBasis: NotebookProgramStateBasis?
  private(set) var loadToken: String?
  private var runtimeLoaded = false
  private var resumeFailed = false
  #if os(iOS)
  private var resumeRetry: UIButton?
  #else
  private var resumeRetry: NSButton?
  #endif
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
  private var passiveCapture: AgentSnapshotCapture?
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
    onState: @escaping NotebookProgramStateWriter
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

  func use(onFramePainted: @escaping (SceneSourceInstallation) -> Void) {
    guard !isInvalidated else { return }
    self.onFramePainted = onFramePainted
  }

  func use(onSourceInstalled: @escaping (SceneSourceInstallation) -> Void) {
    guard !isInvalidated else { return }
    self.onSourceInstalled = onSourceInstalled
  }

  func didDetachPresentation() {
    guard let element = loadedElement, let installation = installation(for: element),
      !installation.isInstalled else { return }
    onSourceInstalled(installation)
  }

  /// Changing accepted state rebinds this same native executor. Its exact
  /// source installation must not wait for a passive cache snapshot to finish.
  private func publishCurrentSourceInstallation() {
    guard let element = loadedElement, let token = loadToken,
      let installation = installation(for: element) else { return }
    Task { @MainActor [weak self] in
      guard let self, accepts(token), installation.isInstalled,
        publishedInstallation?.runtimeToken != installation.runtimeToken
          || publishedInstallation?.source != installation.source else { return }
      publishedInstallation = installation
      onSourceInstalled(installation)
    }
  }

  /// A real WebKit image certifies native pixels independently of passive
  /// cache admission, mipmap construction or the earlier JavaScript-ready edge.
  private func publishFramePainted(_ element: AgentElement, token: String) {
    guard accepts(token), let installation = installation(for: element) else { return }
    Task { @MainActor [weak self] in
      guard let self, accepts(token), installation.isInstalled else { return }
      onFramePainted(installation)
    }
  }

  func hasLiveSource(_ element: AgentElement) -> Bool {
    guard !isInvalidated, !lease.isReleased, runtimeLoaded, let loadedElement else { return false }
    return appliedState == loadedElement.state && SceneRasterSource.agent(loadedElement) == .agent(element)
  }

  #if DEBUG
  func preparationDiagnostic() -> String {
    "invalidated=\(isInvalidated),released=\(lease.isReleased),runtimeLoaded=\(runtimeLoaded),loadFailed=\(loadFailed),token=\(loadToken ?? "none"),url=\(attachedWebView?.url?.absoluteString ?? "none"),loading=\(attachedWebView?.isLoading == true),programLoad=\(programLoadTask != nil),checkpoint=\(checkpointTask != nil),retirement=\(retirementTask != nil),stateApplication=\(stateApplication != nil),loadedState=\(String(describing: loadedElement?.state)),appliedState=\(String(describing: appliedState)),stateToApply=\(String(describing: stateToApply)),basis=\(String(describing: programBasis)),failure=\(String(describing: snapshotFailure))"
  }
  static func checkpointDiagnostics(ownedBy model: NotebookAppModel) -> [String] {
    presentations.values.compactMap(\.owner).filter { $0.programOwner === model }.map { $0.preparationDiagnostic() }
  }
  #endif

  func bindPresentation(to focus: InteractiveElementReference?) {
    guard !isInvalidated else { return }
    if presentationFocus != focus { presentationToken = UUID(); presentationFocus = focus }
    if focus == nil { Self.presentations[ObjectIdentifier(self)] = nil }
    else if Self.presentations[ObjectIdentifier(self)] == nil { Self.presentations[ObjectIdentifier(self)] = .init(owner: self) }
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
        physicalSize: .init(width: element.frame.width, height: element.frame.height), region: region, resources: resources,
        semanticSelection: owner.checkpointWasCaptured && owner.checkpointedSource == element
          ? owner.checkpointSelection?.mapped(from: .init(x: 0, y: 0, width: element.frame.width, height: element.frame.height), into: region) : nil),
      installation.isInstalled else { return nil }
    return try pixels.retainRaster(source: .agentRegion(element, region), resources: resources)
  }
  #endif

  /// Explicitly requests a current frame from the installed running context. A missing,
  /// hidden, replaced or ambiguous owner cannot be substituted with cache data
  /// or with a newly booted program.
  static func captureCurrent(focus: InteractiveElementReference, element: AgentElement,
    resources: SceneRenderResources = .shared) async throws -> RasterLease? {
    guard let owner = try currentCaptureOwner(focus: focus, element: element, resources: resources) else { return nil }
    return try await owner.captureCurrent(element: element)
  }

  /// Only the accepted turn requests this temporary input-priority cut. It
  /// does not update the passive cache or prepare mipmaps for future readers.
  static func captureCurrentCut(focus: InteractiveElementReference, element: AgentElement,
    resources: SceneRenderResources = .shared) async throws -> SceneRasterCut? {
    guard let owner = try currentCaptureOwner(focus: focus, element: element, resources: resources),
      let frame = try await owner.captureFrame(element: element, destination: .acceptedTurn) else { return nil }
    guard case .cut(let cut) = frame else { preconditionFailure("Current cut returned a cached raster") }
    return cut
  }

  /// A finite accepted cohort may borrow only already installed executors.
  /// This lookup never boots a runtime or allocates snapshot backing.
  static func currentInstallation(focus: InteractiveElementReference, element: AgentElement,
    resources: SceneRenderResources = .shared) throws -> SceneSourceInstallation? {
    try currentCaptureOwner(focus: focus, element: element, resources: resources)?.installation(for: element)
  }

  private static func currentCaptureOwner(focus: InteractiveElementReference, element: AgentElement,
    resources: SceneRenderResources) throws -> AgentWebCoordinator? {
    presentations = presentations.filter { $0.value.owner != nil }
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.resources === resources && $0.presentationFocus == focus
        && $0.installation(for: element)?.isInstalled == true
    }
    guard !owners.isEmpty else { return nil }
    guard owners.count == 1 else { throw SceneRenderError.snapshotPending("ambiguous_live_element_" + element.id) }
    return owners[0]
  }

  static func resumeCurrent(focus: InteractiveElementReference) async {
    for owner in presentations.values.compactMap(\.owner) where owner.presentationFocus == focus && !owner.isInvalidated {
      await owner.resumeProgram()
    }
  }

  @discardableResult
  private func resumeProgram() async -> Bool {
    guard programOwner?.permitsAuthoredWork != false else { return false }
    guard frozenCheckpoint == nil, stateTransfer?.hasPendingCheckpoint != true, stateTransfer?.hasFailure != true else { return false }
    guard let web = attachedWebView, let token = loadToken else { return false }
    if restartsAfterBoundary, let element = loadedElement {
      beginLoad(element, in: web, snapshotOnly: snapshotOnly)
      return true
    }
    do {
      _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", expectedToken: token, in: web)
      guard accepts(token), attachedWebView === web,
        programOwner?.permitsAuthoredWork != false else { return false }
      if commitsClosedBeforeReady {
        _ = try await NotebookProgramBridge.lifecycle("setCommitEnabled", controller: "notebookProgram",
          argument: .bool(allowsStateCommits), expectedToken: token, in: web)
        guard accepts(token), attachedWebView === web,
          programOwner?.permitsAuthoredWork != false else { return false }
        commitsClosedBeforeReady = false
      }
      resumeFailed = false; resumeRetry?.removeFromSuperview(); resumeRetry = nil
      web.evaluateJavaScript("document.body.inert=false", completionHandler: nil)
      #if os(iOS)
      web.isUserInteractionEnabled = true
      #endif
      checkpointedSource = nil; checkpointSelection = nil; checkpointWasCaptured = false; attentionPauseID = nil
      publishInteractionReadiness(runtimeLoaded, token: token)
      if let loadedElement, appliedState != loadedElement.state {
        stateToApply = loadedElement.state; applyCurrentState()
      } else { captureSnapshot(of: web, token: token) }
      return true
    } catch {
      guard accepts(token), attachedWebView === web else { return false }
      resumeFailed = true
      web.evaluateJavaScript("document.body.inert=true", completionHandler: nil)
      #if os(iOS)
      web.isUserInteractionEnabled = false
      #endif
      publishInteractionReadiness(false, token: token); setRenderReady(false, token: token)
      if let element = loadedElement { resources.record(.init(kind: "program_resume_error", elementID: element.id,
        message: String(error.localizedDescription.prefix(2000))), for: element) }
      showResumeRetry(over: web)
      return false
    }
  }

  private func showResumeRetry(over web: WKWebView) {
    if let resumeRetry { resumeRetry.isEnabled = true; return }
    guard let host = web.superview else { return }
    let title = stateTransfer?.hasFailure == true ? "Повторить сохранение" : "Повторить запуск"
    #if os(iOS)
    let button = UIButton(type: .system)
    button.configuration = .tinted(); button.setTitle(title, for: .normal)
    button.accessibilityIdentifier = "program-resume-retry-" + (loadedElement?.id ?? "")
    button.addTarget(self, action: #selector(retryProgramResume), for: .touchUpInside)
    #else
    let button = NSButton(title: title, target: self, action: #selector(retryProgramResume))
    button.identifier = .init("program-resume-retry-" + (loadedElement?.id ?? ""))
    #endif
    button.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(button); resumeRetry = button
    NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      button.centerYAnchor.constraint(equalTo: host.centerYAnchor), button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
  }

  @objc private func retryProgramResume() {
    guard resumeFailed || stateTransfer?.hasFailure == true else { return }
    resumeRetry?.isEnabled = false
    Task { @MainActor [weak self] in
      guard let self else { return }
      stateTransfer?.retry()
      do {
        try await stateTransfer?.drain()
        if resumeFailed { await resumeProgram() }
        else { resumeRetry?.removeFromSuperview(); resumeRetry = nil }
      } catch { resumeRetry?.isEnabled = true }
    }
  }

  static func resumePrograms(ownedBy model: NotebookAppModel) async {
    for entry in Array(presentations.values) where entry.retiringOwner == nil {
      if let owner = entry.owner, owner.programOwner === model { await owner.resumeProgram() }
    }
  }

  /// Existing presentation ownership crosses a native dismantle until the
  /// writer acknowledges the final model. The keyed allocator cannot grant a
  /// duplicate executor for this same physical source during that drain.
  func retireAfterCheckpoint() {
    guard !isInvalidated, retirementTask == nil else { return }
    guard let model = programOwner, let focus = presentationFocus, let element = loadedElement,
      programBasis != nil, let web = attachedWebView else { invalidate(); lease.release(); return }
    let entry = Self.presentations[ObjectIdentifier(self)] ?? Presentation(owner: self)
    entry.retiringOwner = self; entry.retiringWeb = web
    Self.presentations[ObjectIdentifier(self)] = entry
    onRenderReady = { _ in }; onInteractionReady = { _ in }
    onInteraction = {}; onFramePainted = { _ in }; onSourceInstalled = { _ in }; onFailure = { _ in }
    retirementTask = Task { @MainActor [self, model, web] in
      defer { retirementTask = nil }
      do {
        try Task.checkCancellation()
        guard !isInvalidated else { return }
        if !runtimeLoaded { try await finishAcceptedBeforeReady() }
        try Task.checkCancellation()
        guard !isInvalidated else { return }
        if runtimeLoaded {
          _ = try await checkpointModel(element: loadedElement ?? element) { rendered, value, basis, admittedBytes in
            guard let accepted = try await model.checkpointProgramState(focus: focus, rendered: rendered, value: value, basis: basis, admittedStateBytes: admittedBytes) else {
              throw NotebookProgramCheckpointError.superseded
            }
            return accepted
          }
        }
        invalidate(); lease.release()
      } catch {
        // Only the addressed writer can distinguish removal/replacement from
        // a page merely leaving the UI working set. A stale heap is disposable;
        // an I/O failure is not permission to discard unsaved model state.
        if error is NotebookProgramCheckpointError { discardSupersededSession() }
        else if !isInvalidated {
          model.showCue("Не удалось сохранить состояние программы. Повторите сохранение.")
          // Keep both the browser and its real ledger lease for explicit retry.
          _ = web
        }
      }
    }
  }

  private func discardSupersededSession() {
    let notify = onSessionSuperseded
    onSessionSuperseded = {}
    invalidate(); lease.release()
    notify()
  }

  /// No author state belongs to a workspace whose bootstrap was rejected.
  /// This terminal boundary also withdraws an executor already held for retry.
  static func abortBootstrapPreparations(ownedBy model: NotebookAppModel) {
    let owners = presentations.values.compactMap(\.owner).filter { $0.programOwner === model }
    for owner in owners {
      owner.retirementTask?.cancel()
      owner.invalidate()
      owner.lease.release()
    }
  }

  static func retryRetirements(ownedBy model: NotebookAppModel) {
    for entry in Array(presentations.values) where entry.retiringOwner?.programOwner === model {
      entry.retiringOwner?.stateTransfer?.retry()
      entry.retiringOwner?.retireAfterCheckpoint()
    }
  }

  static func checkpointPrograms(ownedBy model: NotebookAppModel, resume: Bool,
    focus: InteractiveElementReference? = nil) async -> Bool {
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.programOwner === model && !$0.isInvalidated && (focus == nil || $0.presentationFocus == focus)
    }
    let tasks = owners.map { owner in Task { @MainActor in
      if let retiring = owner.retirementTask { await retiring.value }
      guard !owner.isInvalidated, let focus = owner.presentationFocus,
        let element = owner.loadedElement, owner.programBasis != nil else { return true }
      do {
        if !owner.runtimeLoaded {
          try await owner.finishAcceptedBeforeReady()
          if !owner.runtimeLoaded {
            if resume { return await owner.resumeProgram() }
            return true
          }
        }
        _ = try await owner.checkpointModel(element: owner.loadedElement ?? element) { rendered, value, basis, admittedBytes in
          guard let accepted = try await model.checkpointProgramState(focus: focus, rendered: rendered, value: value, basis: basis, admittedStateBytes: admittedBytes) else {
            throw NotebookProgramCheckpointError.superseded
          }
          return accepted
        }
        if presentations[ObjectIdentifier(owner)]?.retiringOwner != nil { owner.invalidate(); owner.lease.release() }
        else if resume { return await owner.resumeProgram() }
        return true
      } catch {
        if error is NotebookProgramCheckpointError {
          owner.discardSupersededSession(); return true
        }
        owner.resources.record(.init(kind: "program_checkpoint_error", elementID: element.id,
          message: String(error.localizedDescription.prefix(2000))), for: owner.loadedElement ?? element)
        if resume { await owner.resumeProgram() }
        return false
      }
    } }
    var accepted = true
    for task in tasks { if !(await task.value) { accepted = false } }
    return accepted
  }

  private func finishAcceptedBeforeReady() async throws {
    guard let web = attachedWebView, let token = loadToken else { return }
    programLoadTask?.cancel()
    if let programLoadTask { await programLoadTask.value }
    guard accepts(token), attachedWebView === web else { throw CancellationError() }
    commitsClosedBeforeReady = true
    guard let stateTransfer else {
      // This source has no heap yet. Cancelling its initial-state preparation
      // closes that attempt; foreground resumes through a fresh navigation.
      restartsAfterBoundary = true
      web.stopLoading()
      return
    }
    let borrow = try lease.borrow(); defer { borrow.release() }
    let hasHeap = try await stateTransfer.finishAccepted(controller: "notebookProgram", expectedToken: token, in: web)
    guard accepts(token), attachedWebView === web else { throw CancellationError() }
    restartsAfterBoundary = !hasHeap
  }

  /// One in-flight checkpoint owns the stopped model for navigation, native
  /// dismantle and pixel capture alike. The writer remains the model's writer.
  private func checkpointModel(element: AgentElement,
    persist: @escaping @MainActor (AgentElement, JSONValue, NotebookProgramStateBasis, Int) async throws -> NotebookProgramStateBasis?) async throws -> ModelCheckpoint {
    if let checkpointTask { return try await checkpointTask.value }
    if let checkpointedSource, checkpointedSource == loadedElement, let programBasis {
      return .init(source: checkpointedSource, basis: programBasis)
    }
    guard let web = attachedWebView, let token = loadToken, runtimeLoaded,
      let initialSource = loadedElement, AgentProgramSource(initialSource) == AgentProgramSource(element) else {
      throw SceneRenderError.snapshotPending("program_checkpoint_owner")
    }
    let id = UUID()
    checkpointID = id
    let task = Task { @MainActor [self, web] in
      let borrow = try lease.borrow(); defer { borrow.release() }
      guard let stateTransfer else { throw CancellationError() }
      NotebookNavigationObservation.webPreparation("checkpoint_state_drain", ownerID: lease.id, sourceID: element.id)
      try await stateTransfer.drain()
      NotebookNavigationObservation.webPreparation("checkpoint_state_drained", ownerID: lease.id, sourceID: element.id)
      try Task.checkCancellation()
      guard accepts(token), attachedWebView === web else { throw CancellationError() }
      if frozenCheckpoint == nil {
        NotebookNavigationObservation.webPreparation("checkpoint_model_apply", ownerID: lease.id, sourceID: element.id)
        // An agent/local writer can have installed a newer model cut while its
        // existing browser is still applying that state. Freeze only after this
        // executor has received the accepted cut; later queued values survive.
        while stateToApply != nil || stateApplication != nil {
          applyCurrentState()
          guard let application = stateApplication else { break }
          await application.value
          try Task.checkCancellation()
          guard accepts(token), attachedWebView === web,
            loadedElement.map({ AgentProgramSource($0) == AgentProgramSource(element) }) == true else { throw CancellationError() }
        }
        guard let rendered = loadedElement, let basis = programBasis,
          appliedState == rendered.state else {
          throw SceneRenderError.snapshotPending("program_state_application")
        }
        let revision = localStateRevision
        NotebookNavigationObservation.webPreparation("checkpoint_browser_freeze", ownerID: lease.id, sourceID: element.id)
        let descriptor = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram",
          argument: .object(["retry": .bool(true), "serialized": .bool(true)]), expectedToken: token, in: web)
        let snapshot = try await stateTransfer.checkpoint(NotebookProgramBridge.stateSnapshot(descriptor)) { revision, offset in
          try await NotebookProgramBridge.readState(revision, offset: offset, controller: "notebookProgram", expectedToken: token, in: web)
        }
        guard accepts(token), attachedWebView === web,
          loadedElement.map({ AgentProgramSource($0) == AgentProgramSource(rendered) }) == true else { snapshot.release(); throw CancellationError() }
        // The writer validates the model cut which supplied this browser
        // state. A newer accepted basis cannot authorize an older snapshot.
        frozenCheckpoint = (snapshot, basis, rendered, revision)
      }
      let frozen = frozenCheckpoint!, value = frozen.snapshot.value
      let basis = frozen.basis, rendered = frozen.rendered, revision = frozen.revision
      try Task.checkCancellation()
      NotebookNavigationObservation.webPreparation("checkpoint_model_persist", ownerID: lease.id, sourceID: element.id)
      guard let acceptedBasis = try await persist(rendered, value, basis, frozen.snapshot.admittedBytes) else { throw SceneRenderError.snapshotPending("program_checkpoint_not_accepted") }
      try Task.checkCancellation()
      guard accepts(token), localStateRevision == revision, let current = loadedElement,
        AgentProgramSource(current) == AgentProgramSource(element),
        current.state == rendered.state || current.state == value else { throw CancellationError() }
      let accepted = current.updating(state: value)
      let selection = await NotebookProgramBridge.semanticSelection(controller: "notebookProgram", expectedToken: token, in: web)
      guard accepts(token), localStateRevision == revision, hasLiveSource(current) else { throw CancellationError() }
      checkpointSelection = selection; checkpointWasCaptured = false
      loadedElement = accepted; appliedState = value; stateToApply = nil; programBasis = acceptedBasis; checkpointedSource = accepted
      frozen.snapshot.release(); frozenCheckpoint = nil
      return ModelCheckpoint(source: accepted, basis: acceptedBasis)
    }
    checkpointTask = task
    defer { if checkpointID == id { checkpointTask = nil; checkpointID = nil } }
    do { return try await task.value }
    catch {
      if error is NotebookProgramCheckpointError { discardSupersededSession() }
      throw error
    }
  }

  /// An accepted model checkpoint does not depend on passive image admission.
  static func checkpointStateCurrent(focus: InteractiveElementReference, element: AgentElement,
    persist: @escaping @MainActor (JSONValue, NotebookProgramStateBasis, Int) async throws -> NotebookProgramStateBasis?,
    resources: SceneRenderResources = .shared) async throws -> ModelCheckpoint {
    let owner = try checkpointOwner(focus: focus, element: element, resources: resources)
    return try await owner.checkpointModel(element: element) { _, value, basis, admittedBytes in
      try await persist(value, basis, admittedBytes)
    }
  }

  private static func checkpointOwner(focus: InteractiveElementReference, element: AgentElement,
    resources: SceneRenderResources) throws -> AgentWebCoordinator {
    presentations = presentations.filter { $0.value.owner != nil }
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.resources === resources && $0.presentationFocus == focus && $0.hasLiveSource(element)
    }
    guard owners.count == 1, let owner = owners.first, owner.programBasis != nil else {
      throw SceneRenderError.snapshotPending("program_checkpoint_owner")
    }
    return owner
  }

  static func checkpointCurrent(focus: InteractiveElementReference, element: AgentElement,
    persist: @escaping @MainActor (JSONValue, NotebookProgramStateBasis, Int) async throws -> NotebookProgramStateBasis?,
    resources: SceneRenderResources = .shared) async throws -> (AgentElement, RasterLease) {
    let owner = try checkpointOwner(focus: focus, element: element, resources: resources)
    do {
      // The executing context owns the source/state it actually observed. A
      // scene read window may already have evicted this body during retirement.
      let accepted = try await owner.checkpointModel(element: element) { _, value, basis, admittedBytes in try await persist(value, basis, admittedBytes) }
      try Task.checkCancellation()
      guard let pixels = try await owner.captureCurrent(element: accepted.source) else {
        throw SceneRenderError.snapshotPending("program_checkpoint_picture")
      }
      if Task.isCancelled { pixels.release(); throw CancellationError() }
      owner.checkpointWasCaptured = true
      return (accepted.source, pixels)
    } catch { await owner.resumeProgram(); throw error }
  }

  static func pauseForAttention(focus: InteractiveElementReference, element: AgentElement,
    model: NotebookAppModel) async throws -> NotebookProgramAttentionPause {
    let owners = presentations.values.compactMap(\.owner).filter {
      $0.programOwner === model && $0.presentationFocus == focus && $0.hasLiveSource(element)
    }
    guard owners.count == 1, let owner = owners.first,
      let token = owner.loadToken else { throw SceneRenderError.snapshotPending("program_attention_owner") }
    let attentionID = UUID(); owner.attentionPauseID = attentionID
    let (accepted, pixels) = try await checkpointCurrent(focus: focus, element: element, persist: { value, basis, admittedBytes in
      guard let accepted = try await model.checkpointProgramState(focus: focus, rendered: element, value: value, basis: basis, admittedStateBytes: admittedBytes) else {
        throw NotebookProgramCheckpointError.superseded
      }
      return accepted
    })
    pixels.release()
    return .init(value: accepted.state, isCurrent: { [weak owner] in
      guard let owner, let model = owner.programOwner else { return false }
      return owner.accepts(token) && owner.attentionPauseID == attentionID
        && owner.checkpointedSource == accepted && owner.checkpointWasCaptured
        && model.programStateBasis(focus: focus, rendered: accepted) == owner.programBasis
    }, resume: { [weak owner] in
      guard let owner, owner.accepts(token), owner.attentionPauseID == attentionID,
        owner.checkpointedSource == accepted else { return }
      await owner.resumeProgram()
    })
  }

  private func captureCurrent(element: AgentElement) async throws -> RasterLease? {
    guard let frame = try await captureFrame(element: element, destination: .cache) else { return nil }
    guard case .raster(let raster) = frame else { preconditionFailure("Cached capture returned a current cut") }
    return raster
  }

  private func captureFrame(element: AgentElement, destination: AgentCurrentFrameDestination) async throws -> AgentCurrentFrame? {
    try Task.checkCancellation()
    guard let installation = installation(for: element), installation.isInstalled,
      let web = attachedWebView, let token = loadToken else { return nil }
    let policy = snapshotPolicy
    guard let pixels = policy.pixelSize(for: element),
      let configuration = Self.snapshotConfiguration(for: element, policy: policy, backingScale: snapshotScale(of: web)),
      pixels.width < CGFloat(Int.max - 2), pixels.height < CGFloat(Int.max - 2),
      let reservation = destination == .acceptedTurn
        ? resources.reserveCurrentWebCut(pixelSize: pixels) : resources.reserveWebSnapshot(pixelSize: pixels)
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
        let leaseID = lease.id
        if destination == .acceptedTurn {
          NotebookNavigationObservation.webPreparation("accepted_capture_submitted", ownerID: leaseID, sourceID: element.id)
        }
        web.takeSnapshot(with: configuration) { [weak self, capture, installation] image, error in
          if destination == .acceptedTurn {
            NotebookNavigationObservation.webPreparation("accepted_capture_callback", ownerID: leaseID, sourceID: element.id)
          }
          // WebKit delivers this callback on MainActor. An accepted turn only
          // transfers these pixels; queuing another task delays every slot's
          // completion behind unrelated view and passive preparation work.
          if destination == .acceptedTurn {
            defer {
              deadline.cancel(); capture.finish(); self?.submittedCaptures[capture.id] = nil
            }
            guard let self, accepts(token), !capture.isCancelled, installation.isInstalled,
              hasLiveSource(element) else { result.finish(.success(nil)); return }
            if let error { result.finish(.failure(error)); return }
            guard let image else { result.finish(.failure(SceneRenderError.snapshotPending(element.id))); return }
            publishFramePainted(element, token: token)
            guard let cut = resources.currentWebCut(image, for: policy.rasterSource(for: element), reservation: reservation)
            else { result.finish(.failure(SceneRenderError.resourceLimit)); return }
            capture.transferReservationToCut()
            guard cut.pixelScale + 0.000_001 >= policy.minimumScale(for: element) else {
              result.finish(.failure(SceneRenderError.snapshotPending("live_capture_density_" + element.id))); return
            }
            result.finish(.success(.cut(cut))); return
          }
          Task { @MainActor [weak self] in
            defer {
              deadline.cancel(); capture.finish(); self?.submittedCaptures[capture.id] = nil
            }
            guard let self, accepts(token), !capture.isCancelled, installation.isInstalled,
              hasLiveSource(element) else { result.finish(.success(nil)); return }
            if let error { result.finish(.failure(error)); return }
            guard let image else { result.finish(.failure(SceneRenderError.snapshotPending(element.id))); return }
            publishFramePainted(element, token: token)
            let prepared = await resources.storeWebSnapshot(image, for: policy.rasterSource(for: element), reservation: reservation,
              semanticSelection: self.checkpointedSource == element ? self.checkpointSelection : nil,
              permitsPublication: { [weak self] in self?.accepts(token) == true && !capture.isCancelled
                && installation.isInstalled && self?.hasLiveSource(element) == true })
            guard accepts(token), !capture.isCancelled, installation.isInstalled, hasLiveSource(element)
            else { prepared?.release(); result.finish(.success(nil)); return }
            guard let raster = prepared else { result.finish(.failure(SceneRenderError.resourceLimit)); return }
            guard raster.pixelScale + 0.000_001 >= policy.minimumScale(for: element) else {
              raster.release(); result.finish(.failure(SceneRenderError.snapshotPending("live_capture_density_" + element.id))); return
            }
            result.finish(.success(.raster(raster)))
          }
        }
      }
    }, onCancel: {
      Task { @MainActor in capture.cancel(); result.finish(.failure(CancellationError())) }
    })
  }

  func use(onFailure: @escaping (AgentWebSourceFailure) -> Void) {
    guard !isInvalidated else { return }
    self.onFailure = onFailure
  }

  func use(onState: @escaping NotebookProgramStateWriter, enabled: Bool = true) {
    guard !isInvalidated else { return }
    self.onState = onState
    guard allowsStateCommits != enabled else { return }
    allowsStateCommits = enabled
    if let web = attachedWebView, let token = loadToken {
      web.callAsyncJavaScript("if(typeof notebookLoadToken !== 'undefined' && notebookLoadToken===token) window.notebookProgram?.setCommitEnabled(enabled);return true;",
        arguments: ["token": token, "enabled": enabled], in: nil, in: .page, completionHandler: nil)
    }
  }

  /// Dismantling ends this owner session. Neither a queued script message nor an
  /// already running WebKit completion may publish into its next owner.
  func invalidate() {
    let retiringToken = loadToken
    stateTransfer?.revoke()
    frozenCheckpoint = nil
    programLoadTask?.cancel(); programLoadTask = nil
    resumeRetry?.removeFromSuperview(); resumeRetry = nil; resumeFailed = false; programAssets.revokeAll(); packageNavigationURL = nil
    checkpointTask?.cancel(); checkpointTask = nil; checkpointID = nil; checkpointedSource = nil; checkpointSelection = nil; checkpointWasCaptured = false; attentionPauseID = nil
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
    passiveCapture?.cancel(); passiveCapture = nil
    onRenderReady = { _ in }
    onSnapshotPrepared = nil
    onInteractionReady = { _ in }
    onInteraction = {}
    onFramePainted = { _ in }
    onSourceInstalled = { _ in }; publishedInstallation = nil
    onFailure = { _ in }
    onSessionSuperseded = {}
    onState = { _, _ in false }
    if let web = attachedWebView, let retiringToken { retireRuntimeDocument(token: retiringToken, in: web) }
    attachedWebView?.stopLoading()
    attachedWebView?.navigationDelegate = nil
    attachedWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    attachedWebView = nil; stateTransfer = nil; initialStateEncoding = nil
    if let admissionObserver { NotificationCenter.default.removeObserver(admissionObserver) }
    admissionObserver = nil
  }

  /// A queued retirement belongs to the old document, even if WebKit executes
  /// it only after a replacement navigation has already entered this surface.
  private func retireRuntimeDocument(token: String, in web: WKWebView) {
    web.callAsyncJavaScript("""
      if(typeof notebookLoadToken==='undefined'||notebookLoadToken!==token)return false;
      window.notebookFingerInput?.stop();
      void window.notebookProgram?.dispose().catch(()=>{});
      return true;
      """, arguments: ["token": token], in: nil, in: .page, completionHandler: nil)
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

  func load(_ element: AgentElement, basis: NotebookProgramStateBasis? = nil, policy: AgentSnapshotPolicy? = nil, in webView: WKWebView) {
    guard !isInvalidated, !lease.isReleased, attachedWebView === webView else { return }
    // A checkpoint receipt precedes SwiftUI's echo. An old projection may still
    // visit this mounted view; it cannot roll the admitted model back or restart
    // a frozen browser. Geometry continues through the same physical view.
    var element = element, basis = basis
    if let current = programBasis, let loadedElement,
      AgentProgramSource(loadedElement) == AgentProgramSource(element),
      basis == nil || basis.map({ current == $0 || current.hasNewerState(than: $0) }) == true {
      element = element.updating(state: loadedElement.state); basis = current
    }
    let sourceChanged = programBasis.map { previous in basis.map { !previous.hasSameSource(as: $0) } ?? true } ?? (basis != nil && loadedElement != nil)
    let resumesAttention = attentionPauseID != nil && (programBasis != basis || loadedElement != element)
    if programBasis != basis { checkpointedSource = nil; checkpointSelection = nil; checkpointWasCaptured = false; attentionPauseID = nil }
    programBasis = basis
    if resumesAttention, !sourceChanged, let token = loadToken {
      Task { @MainActor [weak self] in
        guard let self, accepts(token) else { return }
        await resumeProgram()
      }
    }
    let policyChanged = policy.map { $0 != snapshotPolicy } ?? false
    if policyChanged { readinessGeneration &+= 1 }
    if let policy { snapshotPolicy = policy }
    guard loadedElement != element || sourceChanged else {
      if policyChanged, runtimeLoaded, appliedState == element.state, let token = loadToken {
        snapshotFailure = nil
        if publishPreparedSnapshot(element, token: token) { return }
        setRenderReady(false, token: token)
        beginPreparationDeadline(token: token, policy: snapshotPolicy)
        captureSnapshot(of: webView, token: token)
      }
      // Updating the representable replaces its callbacks, not its request.
      // Readiness is published only by an actual preparation transition.
      return
    }
    if !sourceChanged, let previous = loadedElement, AgentProgramSource(previous) == AgentProgramSource(element) {
      if previous.state != element.state, let preparation = preNavigationPreparation {
        // No author has observed this initial cut yet. Replace its queued
        // packet instead of navigating it and applying the newer cut afterward.
        beginLoad(element, in: webView, snapshotOnly: snapshotOnly, joiningInitialPreparation: preparation)
        return
      }
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
          if previous.state == element.state,
            previous.frame.width == element.frame.width, previous.frame.height == element.frame.height,
            publishPreparedSnapshot(element, token: token) { return }
          setRenderReady(false, token: token)
          beginPreparationDeadline(token: token)
        }
        if !resumesAttention { applyCurrentState() }
      }
      return
    }
    recoveryAttempts = 0
    beginLoad(element, in: webView)
  }

  /// A camera may ask for less density and then return to the already prepared
  /// density. That is not a new program frame or state. In particular, dozens
  /// of visible controls must not all takeSnapshot at every zoom bucket.
  private func publishPreparedSnapshot(_ element: AgentElement, token: String) -> Bool {
    guard let raster = resources.retainRaster(for: snapshotPolicy.rasterSource(for: element),
      minimumScale: snapshotPolicy.minimumScale(for: element)) else { return false }
    preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
    lastCaptureFailure = nil; snapshotFailure = nil; needsSnapshot = false
    if renderIsReady { publishRenderReadiness(true, token: token) }
    else { setRenderReady(true, token: token) }
    guard let onSnapshotPrepared else { raster.release(); return true }
    // Both a completed capture and adequate cached pixels finish the same
    // consumer. A harmless density retarget must not strand its executor.
    // Pin now, but let WebKit's submitted capture finish before the reader can
    // close its window. Check the latest demand, not an obsolete zoom bucket.
    Task { @MainActor [weak self] in
      guard let self, accepts(token), renderIsReady, snapshotFailure == nil,
        let current = loadedElement, appliedState == current.state,
        SceneRasterSource.agent(current) == .agent(element),
        raster.image(for: snapshotPolicy.rasterSource(for: current),
          minimumScale: snapshotPolicy.minimumScale(for: current)) != nil else {
        raster.release(); return
      }
      onSnapshotPrepared(raster)
    }
    return true
  }

  /// One leased background executor may navigate between independent raster
  /// jobs. Each navigation receives a fresh nonce; old scripts and snapshots
  /// lose publication rights before the next source enters that same WebKit.
  func loadRasterJob(_ element: AgentElement, policy: AgentSnapshotPolicy, in webView: WKWebView) {
    precondition(lease.priority == .background || lease.priority == .visible)
    guard !isInvalidated, !lease.isReleased, attachedWebView === webView else { return }
    snapshotPolicy = policy
    recoveryAttempts = 0
    beginLoad(element, in: webView, snapshotOnly: true)
  }

  private var snapshotOnly = false
  private var preparesPassiveSnapshot = true
  private var loadFailed = false
  private var staticRasterShellReady = false

  private var preNavigationPreparation: Task<Void, Never>? {
    guard !runtimeLoaded, activeNavigation == nil, stateTransfer == nil else { return nil }
    return programLoadTask
  }

  /// The mounted view requests a passive copy only when it is actually using
  /// one (including the bridge from an old raster). A live cold program owns
  /// its native output; turns and checkpoints borrow that output explicitly.
  func use(passiveSnapshot requested: Bool) {
    guard preparesPassiveSnapshot != requested else { return }
    preparesPassiveSnapshot = requested
    if !requested {
      needsSnapshot = false
      passiveCapture?.cancel()
      if runtimeLoaded {
        preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
      }
    } else if runtimeLoaded, let token = loadToken, let web = attachedWebView {
      captureSnapshot(of: web, token: token)
    }
  }

  private func beginLoad(_ element: AgentElement, in webView: WKWebView, snapshotOnly: Bool = false,
    joiningInitialPreparation: Task<Void, Never>? = nil) {
    NotebookNavigationObservation.webPreparation("source_accepted", ownerID: lease.id, sourceID: element.id)
    let staticRaster = snapshotOnly && element.kind == .web && !element.requiresLiveRuntime
    let reusesStaticShell = staticRaster && staticRasterShellReady
    staticRasterShellReady = reusesStaticShell
    loadFailed = false
    frozenCheckpoint = nil
    stateTransfer?.revoke()
    stateTransfer = nil
    self.snapshotOnly = snapshotOnly
    commitsClosedBeforeReady = false; restartsAfterBoundary = false
    programLoadTask?.cancel(); programLoadTask = nil
    initialStateEncoding = nil
    resumeRetry?.removeFromSuperview(); resumeRetry = nil; resumeFailed = false; programAssets.revokeAll(); packageNavigationURL = nil
    checkpointTask?.cancel(); checkpointTask = nil; checkpointID = nil; checkpointedSource = nil; checkpointSelection = nil; checkpointWasCaptured = false; attentionPauseID = nil
    readinessGeneration &+= 1
    stateApplicationID = nil; stateApplication?.cancel(); stateApplication = nil
    passiveCapture?.cancel(); passiveCapture = nil
    snapshotInFlight = false; needsSnapshot = false; runtimeLoaded = false
    fingerRegions = nil
    activeNavigation = nil
    if !reusesStaticShell, loadedElement != nil, joiningInitialPreparation == nil {
      if let token = loadToken { retireRuntimeDocument(token: token, in: webView) }
      webView.stopLoading()
    }
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
    if staticRaster {
      // XML classification proves there is no author execution, CSS or external
      // asset. The existing browser retains its font/layout semantics, while
      // the next drawing replaces only its DOM, not its navigation/runtime.
      if reusesStaticShell {
        webView.callAsyncJavaScript("document.body.innerHTML=html; document.body.getBoundingClientRect(); await document.fonts.ready; return true;",
          arguments: ["html": element.html], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, accepts(token), attachedWebView === webView else { return }
            switch result {
            case .success: acceptRuntimeReady(regions: [:], token: token, in: webView)
            case .failure(let error): record(error, kind: "render_error", token: token)
            }
          }
      } else {
        let document = Self.staticRasterDocument(element, token: token)
        NotebookNavigationObservation.webPreparation("navigation_requested", ownerID: lease.id, sourceID: element.id)
        activeNavigation = webView.loadHTMLString(document, baseURL: nil)
        NotebookNavigationObservation.webPreparation("navigation_returned", ownerID: lease.id, sourceID: element.id)
      }
      return
    }
    // An inline program with a small initial state already has everything
    // needed for navigation. Do not queue its first request behind the next
    // native constructions merely to encode a bounded JSON value.
    if element.programPackage == nil, joiningInitialPreparation == nil {
      do {
        if case .prepared(let encoded) = try NotebookProgramStateEncoding.prepareImmediately(element.state,
          resources: resources, forHTML: true) {
          try installProgramNavigation(element, encoded: encoded, token: token, in: webView)
          return
        }
      } catch {
        guard !Task.isCancelled, accepts(token), attachedWebView === webView else { return }
        record(error, kind: "program_asset_error", token: token, source: element)
        return
      }
    }
    programLoadTask = Task { @MainActor [weak self, weak webView] in
      guard let self, let webView else { return }
      defer { if accepts(token) { programLoadTask = nil } }
      do {
        if let joiningInitialPreparation { await joiningInitialPreparation.value }
        try Task.checkCancellation()
        guard accepts(token), attachedWebView === webView else { return }
        let encoded = try await NotebookProgramStateEncoding.prepare(element.state, resources: resources, forHTML: true)
        guard !Task.isCancelled, accepts(token), attachedWebView === webView else { return }
        if let hash = element.programPackage {
          guard let store = programStore ?? programOwner?.store else { throw SceneRenderError.snapshotPending("program_store") }
          let package = try await Task.detached(priority: .userInitiated) { try store.readProgramPackage(hash) }.value
          try installProgramNavigation(element, encoded: encoded, token: token, in: webView, assets: (store, package))
        } else {
          try installProgramNavigation(element, encoded: encoded, token: token, in: webView)
        }
      } catch {
        guard !Task.isCancelled, accepts(token) else { return }
        initialStateEncoding = nil
        record(error, kind: "program_asset_error", token: token, source: element)
      }
    }
  }

  private func installProgramNavigation(_ element: AgentElement, encoded: NotebookProgramStateEncoding,
    token: String, in webView: WKWebView, assets: (store: NotebookStore, package: NotebookProgramPackage)? = nil) throws {
    guard !Task.isCancelled, accepts(token), attachedWebView === webView else { return }
    initialStateEncoding = encoded
    // Initial state owns its admission before the program can reserve commit
    // credit. Reserving all remaining capacity before encoding would make this
    // not-yet-navigated source wait for bytes held by its own unused credit.
    stateTransfer = NotebookProgramStateTransfer(resources: resources,
      grantsInitialCredit: !snapshotOnly && (lease.priority == .input || lease.priority == .liveProgram))
    if let assets {
      let url = try programAssets.register(store: assets.store, package: assets.package) { origin in
        Self.document(for: element, stateJSON: encoded.htmlJSON, token: token, package: assets.package, origin: origin,
          stateCredit: stateTransfer?.initialCredit ?? 0, commitsEnabled: !snapshotOnly && allowsStateCommits)
      }
      packageNavigationURL = url
      let request = URLRequest(url: url)
      NotebookNavigationObservation.webPreparation("navigation_requested", ownerID: lease.id, sourceID: element.id)
      activeNavigation = webView.load(request)
      NotebookNavigationObservation.webPreparation("navigation_returned", ownerID: lease.id, sourceID: element.id)
    } else {
      let document = Self.document(for: element, stateJSON: encoded.htmlJSON, token: token,
        stateCredit: stateTransfer?.initialCredit ?? 0, commitsEnabled: !snapshotOnly && allowsStateCommits)
      let html = document.before + element.html + document.after
      NotebookNavigationObservation.webPreparation("navigation_requested", ownerID: lease.id, sourceID: element.id)
      activeNavigation = webView.loadHTMLString(html, baseURL: nil)
      NotebookNavigationObservation.webPreparation("navigation_returned", ownerID: lease.id, sourceID: element.id)
    }
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
          let encoded = try await NotebookProgramStateEncoding.prepare(next, resources: resources)
          let accepted = try await encoded.send(controller: "notebookProgram", revision: String(expectedRevision), expectedToken: token, in: web)
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
      guard !Task.isCancelled else { return }
      finishCurrentState(token: token)
    }
  }

  private func finishCurrentState(token: String) {
    guard accepts(token), let web = attachedWebView,
      appliedState == loadedElement?.state else { return }
    publishCurrentSourceInstallation()
    captureSnapshot(of: web, token: token)
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
      passiveCapture?.cancel(); passiveCapture = nil
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
    if object["kind"] as? String == "runtimeReady", let web = attachedWebView {
      acceptRuntimeReady(regions: object["regions"] ?? [:], token: token, in: web)
    } else if object["kind"] as? String == "diagnostic",
      let kind = object["category"] as? String, let message = object["message"] as? String {
      let diagnostic = RenderDiagnostic(kind: kind, elementID: element.id, message: String(message.prefix(2000)))
      if kind == "javascript_error" || kind == "program_ready_error" || kind == "render_error" { fail(diagnostic, token: token) }
      else { resources.record(diagnostic, for: element) }
    } else if object["kind"] as? String == "fingerRegions", let value = object["value"] {
      receiveFingerRegions(value)
    } else if object["kind"] as? String == "interaction", runtimeLoaded {
      onInteraction()
    } else if object["kind"] as? String == "stateCredit", let bytes = object["bytes"] as? Int,
      let web = attachedWebView {
      stateTransfer?.requestCredit(bytes) { NotebookProgramBridge.grantStateCredit($0, controller: "notebookProgram", expectedToken: token, in: web) }
    } else if object["kind"] as? String == "state",
      let data = try? JSONSerialization.data(withJSONObject: object["snapshot"] ?? [:]),
      let descriptor = try? JSONDecoder().decode(NotebookProgramStateTransfer.Snapshot.self, from: data),
      let stateTransfer, let web = attachedWebView, let borrow = try? lease.borrow() {
      let writer = onState, model = programOwner, sourceBasis = programBasis
      stateTransfer.receive(descriptor, retaining: borrow,
        read: { try await NotebookProgramBridge.readState($0, offset: $1, controller: "notebookProgram", expectedToken: token, in: web) },
        acknowledge: { try await NotebookProgramBridge.acknowledgeState($0, controller: "notebookProgram", expectedToken: token, in: web) },
        accept: { [self] value, sequence in
          let (admitted, receipt) = await withCheckedContinuation { continuation in
            if writer(value, .init(admittedBytes: descriptor.cost, sourceBasis: sourceBasis) { continuation.resume(returning: (true, $0)) }) {
              NotebookNavigationObservation.webPreparation("state_write_admitted", ownerID: lease.id, sourceID: element.id)
            } else {
              continuation.resume(returning: (false, nil as NotebookProgramStateBasis?))
            }
          }
          guard admitted || model == nil else { throw SceneRenderError.snapshotPending("program_state_not_accepted") }
          guard receipt != nil || model == nil else { throw NotebookProgramCheckpointError.superseded }
          if accepts(token) {
            localStateRevision = sequence; appliedState = value; stateToApply = nil
            if let current = loadedElement {
              loadedElement = current.updating(state: value)
              if let receipt { programBasis = receipt }
            }
            if runtimeLoaded { preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil; passiveCapture?.cancel() }
            publishCurrentSourceInstallation()
            setRenderReady(false, token: token)
            if runtimeLoaded { applyCurrentState() }
          }
          // The exact write receipt and its credit outlive a dismantled view.
        }, onFailure: { [weak self] error in
          guard let self, accepts(token), self.stateTransfer?.hasFailure == true else { return }
          // Transport refusal must not enter fail(), which retires this exact
          // live executor through the raster owner. Its FIFO still owns state.
          resources.record(.init(kind: "program_state_error", elementID: element.id,
            message: String(error.localizedDescription.prefix(2000))), for: element)
          programOwner?.showCue("Не удалось сохранить состояние программы. Повторите сохранение.")
          showResumeRetry(over: web)
        })
    }
  }

  private func acceptRuntimeReady(regions: Any, token: String, in web: WKWebView) {
    guard accepts(token), !loadFailed, !runtimeLoaded, attachedWebView === web,
      let element = loadedElement else { return }
    receiveFingerRegions(regions)
    runtimeLoaded = true; initialStateEncoding = nil
    NotebookNavigationObservation.webPreparation("runtime_ready", ownerID: lease.id, sourceID: element.id)
    staticRasterShellReady = snapshotOnly && element.kind == .web && !element.requiresLiveRuntime
    #if os(iOS)
      NotebookInteractionDiagnostics.bind(web, elementID: element.id, token: token, ready: true)
    #endif
    // The initial HTML already owns the accepted state. Starting a transfer
    // task with an empty queue delays installation and the first passive image.
    if stateToApply == nil { finishCurrentState(token: token) }
    else { applyCurrentState() }
    // WebKit delivers this event outside representable update. Complete the
    // accepted state turn before notifying its presenter, without another hop.
    if accepts(token), !resumeFailed { onInteractionReady(true) }
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url, scheme = url?.scheme
    let packaged = packageNavigationURL != nil && packageNavigationURL == url && navigationAction.navigationType == .other
    if packaged { packageNavigationURL = nil }
    let allowed = !isInvalidated && !lease.isReleased && attachedWebView === webView
      && (packaged || scheme == nil || scheme == "about")
    if allowed {
      NotebookNavigationObservation.webPreparation("navigation_policy", ownerID: lease.id, sourceID: loadedElement?.id)
    }
    decisionHandler(allowed ? .allow : .cancel)
  }

  private func captureSnapshot(of webView: WKWebView, token: String) {
    guard accepts(token), let element = loadedElement, appliedState == element.state else { return }
    guard snapshotOnly || preparesPassiveSnapshot else {
      preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
      return
    }
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
      Task { @MainActor [weak self] in
        defer { capture.finish(); self?.submittedCaptures[capture.id] = nil }
        guard let self else { return }
        if !capture.isCancelled {
          await completeSnapshot(image, error: error, token: token, element: element, reservation: reservation,
            policy: policy, permitsPublication: { !capture.isCancelled })
        }
        if accepts(token) {
          snapshotInFlight = false; passiveCapture = nil
          if needsSnapshot, let web = attachedWebView {
            needsSnapshot = false; captureSnapshot(of: web, token: token)
          }
        }
      }
    }
  }

  /// The same grant stays alive when a representable is dismantled while its
  /// callback is held by WebKit. This does not acquire another surface slot.
  func holdSubmittedSnapshot(_ reservation: RasterReservation) -> AgentSnapshotCapture {
    precondition(!isInvalidated)
    let capture = AgentSnapshotCapture(reservation: reservation, lease: lease)
    passiveCapture = capture; submittedCaptures[capture.id] = capture
    return capture
  }

  func completeSnapshot(_ image: AgentSnapshotImage?, error: (any Error)?, token: String,
    element: AgentElement, reservation: RasterReservation, policy: AgentSnapshotPolicy? = nil,
    permitsPublication: @escaping @MainActor () -> Bool = { true }) async {
    defer { reservation.release() }
    guard permitsPublication(), accepts(token), let loadedElement,
      appliedState == element.state,
      SceneRasterSource.agent(loadedElement) == .agent(element) else { return }
    if let error {
      record(error, kind: "snapshot_error", token: token, source: element, policy: policy ?? snapshotPolicy)
    } else if let image {
      publishFramePainted(element, token: token)
      let capturedPolicy = policy ?? snapshotPolicy
      let source = capturedPolicy.rasterSource(for: element)
      let stillCurrent: @MainActor () -> Bool = { [weak self] in
        guard permitsPublication(), let self, accepts(token), let current = self.loadedElement else { return false }
        return appliedState == element.state && SceneRasterSource.agent(current) == .agent(element)
      }
      let prepared = await resources.storeWebSnapshot(image, for: source, reservation: reservation,
        permitsPublication: stillCurrent)
      guard stillCurrent() else { prepared?.release(); return }
      if let prepared {
        defer { prepared.release() }
        // A denser whole-source capture can already satisfy a later zoom-out.
        // Crops, changed state and insufficient density still require the next
        // capture; exact policy equality is not a pixel-adequacy criterion.
        if !publishPreparedSnapshot(element, token: token) {
          if capturedPolicy != snapshotPolicy { needsSnapshot = true }
          else {
            fail(.init(kind: "snapshot_error", elementID: element.id,
              message: "The completed snapshot does not contain the requested pixel density."), token: token, policy: capturedPolicy)
          }
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

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard !isInvalidated, attachedWebView === webView, let navigation,
      navigation === activeNavigation else { return }
    NotebookNavigationObservation.webPreparation("navigation_started", ownerID: lease.id, sourceID: loadedElement?.id)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard !isInvalidated, attachedWebView === webView, let navigation,
      navigation === activeNavigation else { return }
    NotebookNavigationObservation.webPreparation("navigation_committed", ownerID: lease.id, sourceID: loadedElement?.id)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    fail(navigation: navigation, in: webView, error: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard attachedWebView === webView, let token = loadToken, accepts(token), let element = loadedElement else { return }
    staticRasterShellReady = false
    guard recoveryAttempts < 2 else {
      fail(.init(kind: "web_process_terminated", elementID: element.id,
        message: "WebKit terminated repeatedly. Retry the surface explicitly."), token: token)
      return
    }
    recoveryAttempts += 1
    beginLoad(element, in: webView, snapshotOnly: snapshotOnly)
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
      rasterAdmission: policy == nil ? nil : lastCaptureAdmission,
      stateCreditBytes: stateTransfer?.admittedCreditBytes ?? 0)
    lastCaptureFailure = policy == nil ? nil : failure
    if policy == nil {
      // A terminal program/navigation failure revokes live installation too.
      // Only a failed capture can leave a functioning program interactive.
      runtimeLoaded = false; needsSnapshot = false; loadFailed = true; staticRasterShellReady = false
      publishInteractionReadiness(false, token: token)
    }
    snapshotFailure = diagnostic.kind == "resource_limit" ? .resourceLimit : .snapshotPending(element.id)
    preparationDeadline?.cancel(); preparationDeadline = nil; preparationDeadlineAt = nil
    passiveCapture?.cancel(); passiveCapture = nil
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
      guard let self, accepts(token), (runtimeLoaded && !resumeFailed) == ready else { return }
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
    let constructionBegan = ContinuousClock.now
    NotebookNavigationObservation.webPreparation("native_init_started", ownerID: coordinator.lease.id)
    let controller = WKUserContentController()
    controller.add(coordinator, name: "notebook")
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = controller
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(coordinator.programAssets, forURLScheme: NotebookProgramAssets.scheme)
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
    NotebookNavigationObservation.webPreparation("native_init_finished", ownerID: coordinator.lease.id)
    // Report only this synchronous construction, excluding queue/navigation
    // waits. Admission resumes consumers through their async continuations.
    coordinator.lease.finishConstruction(elapsed: constructionBegan.duration(to: .now))
    return webView
  }

  private static func document(for element: AgentElement, stateJSON: String, token: String, package: NotebookProgramPackage? = nil, origin: URL? = nil, stateCredit: Int = 0, commitsEnabled: Bool = true) -> NotebookProgramAssets.Document {
    #if os(iOS)
      let interactionScript = NotebookInteractionDiagnostics.script
    #else
      let interactionScript = ""
    #endif
    let policy = origin.map(NotebookProgramAssets.policy) ?? "default-src 'none'; img-src data: blob:; media-src data: blob:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none';"
    let style = package.flatMap { package in origin.map { NotebookProgramAssets.style(package, origin: $0) } } ?? ""
    let script = package.flatMap { package in origin.map { NotebookProgramAssets.script(package, origin: $0) } }
      ?? "<script>const program=document.createElement('script');program.textContent=\(json(.string(element.javaScript)));document.body.append(program);</script>"
    return .init(before: """
      <!doctype html>
      <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
      <meta http-equiv="Content-Security-Policy" content="\(policy)">
      <style>
        :root { color-scheme: light; }
        html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: transparent; }
        body { box-sizing: border-box; color: #171714; font: 17px/1.42 -apple-system, BlinkMacSystemFont, sans-serif; }
        *, *::before, *::after { box-sizing: border-box; }
        \(element.css)
      </style>
      \(style)
      <script>
        const notebookLoadToken = '\(token)';
        \(interactionScript)
        for (const kind of ['pointerdown', 'keydown']) addEventListener(kind, event => {
          if (event.isTrusted && (kind === 'keydown' || window.notebookFingerInput.forEvent(event) === 'input')) {
            window.notebookProgram?.setCommitEnabled(true);
            window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'interaction'});
          }
        }, true);
        window.notebookDiagnostic = (category, message) => window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'diagnostic',category,message:String(message)});
        addEventListener('error', event => window.notebookDiagnostic('javascript_error', event.message || 'Resource load error'));
        addEventListener('unhandledrejection', event => window.notebookDiagnostic('javascript_error', event.reason));
        \(NotebookProgramBridge.script)
        window.notebookProgram=createNotebookProgram({state:\(stateJSON),
          stateTransport:{credit:\(stateCredit),enabled:\(commitsEnabled),
            onSnapshot:snapshot=>window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'state',snapshot}),
            requestCredit:bytes=>window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'stateCredit',bytes})},
          report:window.notebookDiagnostic});
        window.notebook=notebookProgram.api;
        \(AgentWebFingerRegions.script)
      </script>
      </head><body>
      """, after: """
      \(script)
      <script>
        // Readiness belongs to this document. Starting it here avoids a
        // navigation callback -> native queue -> WebKit round trip per source.
        addEventListener('load', async () => {
          try {
            await document.fonts.ready;
            await Promise.all([...document.images].map(image => image.decode().catch(() => {})));
            await window.notebookProgram.start({requiresReady:\(element.programPackage != nil || !element.javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || element.html.localizedCaseInsensitiveContains("<script"))});
            for (const image of document.images) if (!image.naturalWidth) window.notebookDiagnostic('load_error', 'Image failed to load');
            if (Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) > innerHeight + 1 || Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) > innerWidth + 1) window.notebookDiagnostic('overflow', 'Content exceeds its frame');
            const regions = window.notebookFingerInput.start();
            window.webkit.messageHandlers.notebook.postMessage({token:notebookLoadToken,kind:'runtimeReady',regions});
          } catch (error) { window.notebookDiagnostic('render_error', String(error)); }
        }, {once:true});
      </script>
      </body></html>
      """)
  }

  private static func staticRasterDocument(_ element: AgentElement, token: String) -> String {
    precondition(element.kind == .web && !element.requiresLiveRuntime)
    return """
      <!doctype html><html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
      <style>
        :root { color-scheme: light; }
        html,body { width:100%; height:100%; margin:0; overflow:hidden; background:transparent; }
        body { box-sizing:border-box; color:#171714; font:17px/1.42 -apple-system,BlinkMacSystemFont,sans-serif; }
        *,*::before,*::after { box-sizing:border-box; }
      </style></head><body>\(element.html)
      <script>addEventListener('load', async () => {
        try {
          await document.fonts.ready;
          window.webkit.messageHandlers.notebook.postMessage({token:'\(token)',kind:'runtimeReady'});
        } catch (error) {
          window.webkit.messageHandlers.notebook.postMessage({token:'\(token)',kind:'diagnostic',category:'render_error',message:String(error)});
        }
      }, {once:true});</script></body></html>
      """
  }

  private static func json(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
  }


}
