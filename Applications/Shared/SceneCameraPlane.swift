import NotebookCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The camera projects a prepared coordinate system. Neither a new sample nor
/// its screen rounding changes the physical bounds of the hosted content.
struct SceneCameraProjection: Equatable {
  let scale: Double
  let translation: SpatialPoint

  init(anchor: SessionPresence, current: SessionPresence) {
    precondition(anchor.boardID == current.boardID)
    scale = current.camera.scale / anchor.camera.scale
    // A synchronous native sample may arrive before the geometry producer
    // rebases a far jump. Preserve exact nearby deltas, but never overflow
    // Int64 while putting an unrelated old basis far outside this viewport.
    // The latter is only a transient display transform, not a world address.
    func axis(_ currentTile: Int64, _ anchorTile: Int64, _ currentLocal: Double, _ anchorLocal: Double) -> Double {
      let delta = anchorTile.subtractingReportingOverflow(currentTile)
      let tiles = delta.overflow ? Double(anchorTile) - Double(currentTile) : Double(delta.partialValue)
      return tiles * WorldPoint.tileSize + anchorLocal - currentLocal
    }
    let delta = SpatialPoint(
      x: axis(current.camera.center.tileX, anchor.camera.center.tileX,
        current.camera.center.localX, anchor.camera.center.localX),
      y: axis(current.camera.center.tileY, anchor.camera.center.tileY,
        current.camera.center.localY, anchor.camera.center.localY))
    translation = .init(
      x: current.viewport.x / 2 + delta.x * current.camera.scale - anchor.viewport.x / 2 * scale,
      y: current.viewport.y / 2 + delta.y * current.camera.scale - anchor.viewport.y / 2 * scale)
  }

  static func requiresRebase(anchor: SessionPresence, current: SessionPresence) -> Bool {
    guard anchor.boardID == current.boardID, anchor.viewport == current.viewport else { return true }
    // Magnification needs fresh vector/text density while fingers remain down.
    // Zooming OUT does not: the prepared pixels already exceed the requested
    // density. Rebuilding every hosted program on the way out and again on
    // return caused main-thread stalls without adding any visible detail.
    let ratio = current.camera.scale / anchor.camera.scale
    if ratio > sqrt(2.0) { return true }
    let x = anchor.camera.center.tileX.subtractingReportingOverflow(current.camera.center.tileX)
    let y = anchor.camera.center.tileY.subtractingReportingOverflow(current.camera.center.tileY)
    guard !x.overflow, !y.overflow, x.partialValue > -4096, x.partialValue < 4096,
      y.partialValue > -4096, y.partialValue < 4096 else { return true }
    let delta = anchor.camera.center.delta(to: current.camera.center)
    return max(abs(delta.x), abs(delta.y)) * anchor.camera.scale > max(anchor.viewport.x, anchor.viewport.y) * 8
  }

  func project(_ point: SpatialPoint) -> SpatialPoint {
    .init(x: point.x * scale + translation.x, y: point.y * scale + translation.y)
  }
}

/// Handlers read the latest projection without subscribing physical content to
/// every camera sample. This value owns no camera and never writes presence.
@MainActor
protocol ScenePlaneProjectionObserver: AnyObject {
  func scenePlaneDidProject()
}

@MainActor
final class ScenePlaneProjection {
  private final class Observer {
    weak var value: (any ScenePlaneProjectionObserver)?
    init(_ value: any ScenePlaneProjectionObserver) { self.value = value }
  }
  private var observers: [ObjectIdentifier: Observer] = [:]
  private(set) var current: SessionPresence
  func register(_ observer: any ScenePlaneProjectionObserver) { observers[ObjectIdentifier(observer)] = Observer(observer) }
  func remove(_ observer: any ScenePlaneProjectionObserver) { observers[ObjectIdentifier(observer)] = nil }
  func didProject() {
    for (id, observer) in observers {
      guard let value = observer.value else { observers[id] = nil; continue }
      value.scenePlaneDidProject()
    }
  }
  init(_ current: SessionPresence) { self.current = current }
  func update(_ current: SessionPresence) { self.current = current }
}

private struct ScenePlaneProjectionKey: EnvironmentKey {
  static let defaultValue: ScenePlaneProjection? = nil
}
extension EnvironmentValues {
  var scenePlaneProjection: ScenePlaneProjection? {
    get { self[ScenePlaneProjectionKey.self] }
    set { self[ScenePlaneProjectionKey.self] = newValue }
  }
}

/// Counts the two distinct operations performed by the physical camera owner.
/// A scheduling sample is not evidence of a display presentation.
@MainActor
protocol SceneCameraPlaneActivity: AnyObject {
  var contentPublicationCount: Int { get }
  var cameraProjectionCount: Int { get }
}

/// A publication holds a weak claim on its actual native host. Detaching or
/// replacing that host revokes the claim without waiting for a SwiftUI callback.
@MainActor
final class SceneCameraPlaneInstallation {
  private weak var owner: (any SceneCameraPlaneInstallationOwner)?
  var isInstalled: Bool { owner?.isShowing(self) == true }
  func bind(_ owner: any SceneCameraPlaneInstallationOwner) { self.owner = owner }
}

@MainActor
protocol SceneCameraPlaneInstallationOwner: AnyObject {
  func isShowing(_ installation: SceneCameraPlaneInstallation) -> Bool
}

/// `revision` names the workset and its interaction mode, not the camera.
/// During a camera contact only that contract can replace the hosting root.
/// Settlement rebases its input window once before the next contact; visible
/// content outside the old window then receives native input at its new place.
/// The host and physical WebKit surfaces retain their identity.
struct SceneCameraPlane<Revision: Equatable, Content: View>: View {
  let presence: SessionPresence
  let revision: Revision
  var reanchorsOnRevision = true
  var isCameraActive = false
  var installation: SceneCameraPlaneInstallation? = nil
  var observation: NotebookSceneObservationContext? = nil
  #if os(macOS)
  var hitRegions: ((SessionPresence) -> [CGRect])? = nil
  #endif
  @ViewBuilder let content: (SessionPresence) -> Content

  var body: some View {
    #if os(macOS)
    NativeSceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision,
      isCameraActive: isCameraActive, installation: installation, observation: observation,
      hitRegions: hitRegions, content: content)
      .frame(width: presence.viewport.x, height: presence.viewport.y)
    #else
    NativeSceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision,
      isCameraActive: isCameraActive, installation: installation, observation: observation, content: content)
      .frame(width: presence.viewport.x, height: presence.viewport.y)
    #endif
  }
}

#if os(iOS)
/// A source keeps its canonical physical bounds inside the prepared camera
/// plane. SwiftUI publishes its contents, but cannot round a scaled frame and
/// then hand those rounded bounds back to WebKit as another projection.
struct SceneElementPose<Content: View>: UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  @Environment(\.scenePlaneProjection) private var projection
  @Environment(\.workspaceSceneFrame) private var sceneFrame
  @Environment(\.sceneComposition) private var composition
  let frame: CGRect
  let contentSize: CGSize
  var observationElementID: String? = nil
  var observationElementStamp: VersionStamp? = nil
  @ViewBuilder let content: () -> Content

  func makeUIViewController(context: Context) -> SceneElementPoseController {
    SceneElementPoseController()
  }

  func updateUIViewController(_ controller: SceneElementPoseController, context: Context) {
    controller.bindSceneLifecycle(to: model)
    controller.observationElementID = observationElementID
    let contents = content().environment(\.scenePlaneProjection, projection)
      .environment(\.workspaceSceneFrame, sceneFrame).environment(\.sceneComposition, composition)
      .frame(width: contentSize.width, height: contentSize.height).ignoresSafeArea()
    controller.update(frame: frame, contentSize: contentSize,
      content: model.map { AnyView(contents.environment($0)) } ?? AnyView(contents),
      observationStamp: observationElementStamp)
  }

  static func dismantleUIViewController(_ controller: SceneElementPoseController, coordinator: ()) {
    controller.uninstall()
  }
}

@MainActor
final class SceneElementPoseController: UIViewController, NotebookScenePresentationOwner {
  var observationElementID: String?
  var observationElementStamp: VersionStamp?
  private weak var sceneModel: NotebookAppModel?
  private var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(EmptyView()))
  private(set) var isRetired = false
  var contentView: UIView { host?.view ?? view }

  func bindSceneLifecycle(to model: NotebookAppModel?) {
    guard !isRetired, sceneModel !== model else { return }
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = model
    model?.registerScenePresentation(self)
  }

  override func loadView() {
    let container = ScenePlaneContainer()
    container.backgroundColor = .clear; container.isOpaque = false
    container.clipsToBounds = false
    view = container
    guard let host else { return }
    host.view.backgroundColor = .clear; host.view.isOpaque = false
    host.view.clipsToBounds = false; host.view.autoresizingMask = []
    host.safeAreaRegions = []
    addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
    container.host = host.view
  }

  func update(frame: CGRect, contentSize: CGSize, content: AnyView, observationStamp: VersionStamp? = nil) {
    guard !isRetired, frame.width > 0, frame.height > 0,
      contentSize.width > 0, contentSize.height > 0 else { return }
    loadViewIfNeeded()
    guard let host else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    host.view.bounds = CGRect(origin: .zero, size: contentSize)
    host.view.transform = CGAffineTransform(scaleX: frame.width / contentSize.width,
      y: frame.height / contentSize.height)
    host.view.center = CGPoint(x: frame.midX, y: frame.midY)
    host.rootView = content
    observationElementStamp = observationStamp
    // A rebase installs the source's native content under its final matrix in
    // this transaction. Camera samples subsequently transform the parent only.
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    NotebookSceneObservation.element(observationElementID, stamp: observationElementStamp,
      host: host.view, event: "element_update_before_commit")
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    NotebookSceneObservation.element(observationElementID, stamp: observationElementStamp,
      host: host?.viewIfLoaded, event: "element_did_layout")
  }

  func uninstall() {
    guard !isRetired else { return }
    NotebookSceneObservation.retire(observationElementID, host: host?.viewIfLoaded)
    isRetired = true
    sceneModel?.unregisterScenePresentation(self); sceneModel = nil
    if let host {
      host.rootView = AnyView(EmptyView())
      if host.isViewLoaded { host.view.setNeedsLayout(); host.view.layoutIfNeeded() }
      if host.parent != nil { host.willMove(toParent: nil) }
      if host.isViewLoaded { host.view.removeFromSuperview() }
      host.removeFromParent()
      self.host = nil
    }
  }
}

private struct NativeSceneCameraPlane<Revision: Equatable, Content: View>: UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  let presence: SessionPresence
  let revision: Revision
  let reanchorsOnRevision: Bool
  let isCameraActive: Bool
  let installation: SceneCameraPlaneInstallation?
  let observation: NotebookSceneObservationContext?
  let content: (SessionPresence) -> Content

  func makeUIViewController(context: Context) -> SceneCameraPlaneController<Revision> {
    SceneCameraPlaneController()
  }
  func updateUIViewController(_ controller: SceneCameraPlaneController<Revision>, context: Context) {
    controller.bindSceneLifecycle(to: model)
    controller.observation = observation
    controller.update(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision,
      isCameraActive: isCameraActive, installation: installation) { anchor, projection in
      AnyView(content(anchor).environment(\.scenePlaneProjection, projection)
        .frame(width: anchor.viewport.x, height: anchor.viewport.y).ignoresSafeArea())
    }
  }
  static func dismantleUIViewController(_ controller: SceneCameraPlaneController<Revision>, coordinator: ()) {
    controller.uninstall()
  }
}

@MainActor
final class SceneCameraPlaneController<Revision: Equatable>: UIViewController, SceneCameraPlaneActivity, NotebookScenePresentationOwner, SceneCameraPlaneInstallationOwner, SceneNativeCameraOwner {
  var observation: NotebookSceneObservationContext?
  private weak var sceneModel: NotebookAppModel?
  private weak var cameraProjection: SceneNativeCameraProjection?
  private var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(EmptyView()))
  private var anchor: SessionPresence?
  private var revision: Revision?
  private var projection: ScenePlaneProjection?
  private var installation: SceneCameraPlaneInstallation?
  private var hasInstalledLayout = false
  private(set) var isRetired = false
  private(set) var contentPublicationCount = 0
  private(set) var cameraProjectionCount = 0
  var contentView: UIView { host?.view ?? view }

  func bindSceneLifecycle(to model: NotebookAppModel?) {
    bindCameraProjection(to: model?.nativeCameraProjection)
    guard !isRetired, sceneModel !== model else { return }
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = model
    model?.registerScenePresentation(self)
  }

  func bindCameraProjection(to projection: SceneNativeCameraProjection?) {
    guard !isRetired, cameraProjection !== projection else { return }
    cameraProjection?.remove(self)
    cameraProjection = projection
    projection?.register(self)
  }

  override func loadView() {
    let container = ScenePlaneContainer()
    container.backgroundColor = .clear
    container.isOpaque = false
    view = container
    guard let host else { return }
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    host.view.clipsToBounds = false
    host.view.autoresizingMask = []
    host.safeAreaRegions = []
    addChild(host)
    view.addSubview(host.view)
    host.didMove(toParent: self)
    container.host = host.view
  }

  func update(presence: SessionPresence, revision: Revision, reanchorsOnRevision: Bool = true,
    isCameraActive: Bool = false,
    installation: SceneCameraPlaneInstallation? = nil,
    content: (SessionPresence, ScenePlaneProjection) -> AnyView) {
    guard !isRetired else { return }
    loadViewIfNeeded()
    guard let host else { return }
    // SwiftUI may deliver the configuration from before the most recent
    // native contact callback. It owns source publication, never a rollback
    // of the camera which the model has already accepted.
    let presence = cameraProjection?.current(for: presence.boardID) ?? presence
    self.installation = installation
    installation?.bind(self)
    hasInstalledLayout = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let needsRebase = anchor.map {
      SceneCameraProjection.requiresRebase(anchor: $0, current: presence)
        || (!isCameraActive && $0.camera != presence.camera)
    } ?? true
    if needsRebase || self.revision != revision {
      let previousAnchor = anchor
      if needsRebase || reanchorsOnRevision { anchor = presence }
      self.revision = revision
      let projection = self.projection ?? ScenePlaneProjection(presence)
      projection.update(presence)
      self.projection = projection
      let prepared = anchor ?? presence
      host.view.bounds = CGRect(x: 0, y: 0, width: prepared.viewport.x, height: prepared.viewport.y)
      applyCamera(presence, countsProjection: false)
      host.rootView = content(prepared, projection)
      if previousAnchor != anchor || installation != nil {
        // Replacing rootView schedules SwiftUI layout; it does not move the
        // mounted bodies yet. Native layout must see the final transform when
        // it aligns physical views to device pixels. Layout under the old
        // matrix followed by a new matrix preserves the wrong pixel phase.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
      }
      contentPublicationCount += 1
    }
    applyCamera(presence, countsProjection: true)
    hasInstalledLayout = true
    observe("plane_update_before_commit")
  }

  func projectSceneCamera(_ presence: SessionPresence) {
    guard !isRetired, anchor?.boardID == presence.boardID else { return }
    applyCamera(presence, countsProjection: true)
    observe("plane_native_projection_before_commit", presence: presence)
  }

  private func applyCamera(_ presence: SessionPresence, countsProjection: Bool) {
    guard let anchor, let host, anchor.boardID == presence.boardID else { return }
    projection?.update(presence)
    let matrix = SceneCameraProjection(anchor: anchor, current: presence)
    host.view.transform = CGAffineTransform(scaleX: matrix.scale, y: matrix.scale)
    host.view.center = CGPoint(x: anchor.viewport.x / 2 * matrix.scale + matrix.translation.x,
      y: anchor.viewport.y / 2 * matrix.scale + matrix.translation.y)
    projection?.didProject()
    if countsProjection { cameraProjectionCount += 1 }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let host { host.view.layoutIfNeeded(); hasInstalledLayout = true }
    projection?.didProject()
    observe("plane_did_layout")
  }

  private func observe(_ event: String, presence: SessionPresence? = nil) {
    NotebookSceneObservation.plane(observation, model: sceneModel, presence: presence ?? projection?.current,
      anchor: anchor, host: host?.viewIfLoaded, event: event, publications: contentPublicationCount,
      projections: cameraProjectionCount, installed: installation?.isInstalled == true)
  }

  func isShowing(_ installation: SceneCameraPlaneInstallation) -> Bool {
    guard !isRetired, self.installation === installation, hasInstalledLayout,
      let host = host?.view, let window = view.window, host.window === window,
      host.isDescendant(of: view) else { return false }
    // The unclipped host retains the old camera basis. Its own rectangle may
    // leave the viewport while prepared children outside that rectangle enter
    // it. Plane installation belongs to the fixed viewport; each child's
    // source/raster installation separately proves its actual visible pixels.
    return SceneSourceVisibility.isMounted(host) && SceneSourceVisibility.isVisible(view)
  }

  /// UIKit may retain an unmounted controller. Its last content is no longer a
  /// shown owner: release the SwiftUI subtree rather than waiting for deinit.
  /// Dismantling is terminal; a new representable creates its own ready owner.
  func uninstall() {
    guard !isRetired else { return }
    observe("plane_retire")
    isRetired = true
    cameraProjection?.remove(self)
    cameraProjection = nil
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = nil
    if let host {
      host.rootView = AnyView(EmptyView())
      // Replacing the value alone leaves the previous DisplayList in a UIKit-
      // retained hosting view. Retire this host's paint before detaching it;
      // an offscreen owner cannot rely on another frame to process the change.
      if host.isViewLoaded {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
      }
      if host.parent != nil { host.willMove(toParent: nil) }
      if host.isViewLoaded { host.view.removeFromSuperview() }
      host.removeFromParent()
      self.host = nil
    }
    anchor = nil; revision = nil; projection = nil; installation = nil; hasInstalledLayout = false
  }
}

private final class ScenePlaneContainer: UIView {
  weak var host: UIView?
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self || hit === host ? nil : hit
  }
}
#else
private struct NativeSceneCameraPlane<Revision: Equatable, Content: View>: NSViewRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  let presence: SessionPresence
  let revision: Revision
  let reanchorsOnRevision: Bool
  let isCameraActive: Bool
  let installation: SceneCameraPlaneInstallation?
  let observation: NotebookSceneObservationContext?
  let hitRegions: ((SessionPresence) -> [CGRect])?
  let content: (SessionPresence) -> Content

  func makeNSView(context: Context) -> SceneCameraPlaneView<Revision> { SceneCameraPlaneView() }
  func updateNSView(_ view: SceneCameraPlaneView<Revision>, context: Context) {
    view.bindSceneLifecycle(to: model)
    view.update(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision,
      isCameraActive: isCameraActive, installation: installation, hitRegions: hitRegions) { anchor, projection in
      AnyView(content(anchor).environment(\.scenePlaneProjection, projection)
        .frame(width: anchor.viewport.x, height: anchor.viewport.y).ignoresSafeArea())
    }
  }
  static func dismantleNSView(_ view: SceneCameraPlaneView<Revision>, coordinator: ()) {
    view.uninstall()
  }
}

@MainActor
final class SceneCameraPlaneView<Revision: Equatable>: NSView, SceneCameraPlaneActivity, NotebookScenePresentationOwner, SceneCameraPlaneInstallationOwner {
  private weak var sceneModel: NotebookAppModel?
  private let host = NSHostingView(rootView: AnyView(EmptyView()))
  private var inputRegions: [CGRect] = []
  private var anchor: SessionPresence?
  private var revision: Revision?
  private var projection: ScenePlaneProjection?
  private var installation: SceneCameraPlaneInstallation?
  private var hasInstalledLayout = false
  private(set) var isRetired = false
  private(set) var contentPublicationCount = 0
  private(set) var cameraProjectionCount = 0
  override var isFlipped: Bool { true }
  var contentView: NSView { host }

  func bindSceneLifecycle(to model: NotebookAppModel?) {
    guard !isRetired, sceneModel !== model else { return }
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = model
    model?.registerScenePresentation(self)
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    host.sizingOptions = []
    addSubview(host)
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init()") }

  func update(presence: SessionPresence, revision: Revision, reanchorsOnRevision: Bool = true,
    isCameraActive: Bool = false,
    installation: SceneCameraPlaneInstallation? = nil,
    hitRegions: ((SessionPresence) -> [CGRect])? = nil,
    content: (SessionPresence, ScenePlaneProjection) -> AnyView) {
    guard !isRetired else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    self.installation = installation
    installation?.bind(self)
    hasInstalledLayout = false
    let needsRebase = anchor.map {
      SceneCameraProjection.requiresRebase(anchor: $0, current: presence)
        // Ending a wheel pan does not change density. Keep its native
        // translation instead of relocating the SwiftUI/WebKit subtree at
        // every pause between wheel samples. Zoom still settles at exact LOD.
        || (!isCameraActive && $0.camera.scale != presence.camera.scale)
    } ?? true
    if needsRebase || self.revision != revision {
      let previousAnchor = anchor
      if needsRebase || reanchorsOnRevision { anchor = presence }
      self.revision = revision
      let projection = self.projection ?? ScenePlaneProjection(presence)
      projection.update(presence)
      self.projection = projection
      let prepared = anchor ?? presence
      inputRegions = hitRegions?(prepared) ?? []
      host.rootView = content(prepared, projection)
      host.frame = CGRect(x: 0, y: 0, width: prepared.viewport.x, height: prepared.viewport.y)
      if previousAnchor != anchor || installation != nil {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
      }
      contentPublicationCount += 1
    }
    projection?.update(presence)
    applyCameraProjection()
    cameraProjectionCount += 1
    hasInstalledLayout = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // SwiftUI may resize the native frame after updateNSView. AppKit preserves
    // an explicit bounds transform while resizing, which otherwise stretches
    // split-pane paper on one axis and retains that distortion after return.
    CATransaction.begin(); CATransaction.setDisableActions(true)
    applyCameraProjection()
    CATransaction.commit()
  }

  private func applyCameraProjection() {
    guard let anchor, let current = projection?.current, frame.width > 0, frame.height > 0 else { return }
    let matrix = SceneCameraProjection(anchor: anchor, current: current)
    // Only the camera scales content. The physical frame, not a proposed
    // SwiftUI viewport, determines the native bounds at this layout stage.
    let projected = CGRect(x: -matrix.translation.x / matrix.scale,
      y: -matrix.translation.y / matrix.scale,
      width: frame.width / matrix.scale, height: frame.height / matrix.scale)
    if bounds != projected { bounds = projected }
    projection?.didProject()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if host.window != nil { host.layoutSubtreeIfNeeded(); hasInstalledLayout = true }
  }

  func isShowing(_ installation: SceneCameraPlaneInstallation) -> Bool {
    !isRetired && self.installation === installation && hasInstalledLayout
      && window != nil && window?.isVisible == true && !isHiddenOrHasHiddenAncestor
      && !host.visibleRect.isEmpty
  }

  func uninstall() {
    guard !isRetired else { return }
    isRetired = true
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = nil
    host.rootView = AnyView(EmptyView())
    anchor = nil; revision = nil; projection = nil; installation = nil; hasInstalledLayout = false
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isRetired else { return nil }
    let hit = super.hitTest(point)
    guard hit !== self else { return nil }
    // SwiftUI gestures live on NSHostingView itself. Retain that responder only
    // over published materials; the empty plane still passes through to camera input.
    if hit === host, !inputRegions.contains(where: { $0.contains(host.convert(point, from: superview)) }) { return nil }
    return hit
  }
}
#endif
