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
    let delta = current.camera.center.delta(to: anchor.camera.center)
    translation = .init(
      x: current.viewport.x / 2 + delta.x * current.camera.scale - anchor.viewport.x / 2 * scale,
      y: current.viewport.y / 2 + delta.y * current.camera.scale - anchor.viewport.y / 2 * scale)
  }

  static func requiresRebase(anchor: SessionPresence, current: SessionPresence) -> Bool {
    guard anchor.boardID == current.boardID, anchor.viewport == current.viewport else { return true }
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
final class ScenePlaneProjection {
  private(set) var current: SessionPresence
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
  @ViewBuilder let content: (SessionPresence) -> Content

  var body: some View {
    NativeSceneCameraPlane(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision, isCameraActive: isCameraActive, content: content)
      .frame(width: presence.viewport.x, height: presence.viewport.y)
  }
}

#if os(iOS)
private struct NativeSceneCameraPlane<Revision: Equatable, Content: View>: UIViewControllerRepresentable {
  let presence: SessionPresence
  let revision: Revision
  let reanchorsOnRevision: Bool
  let isCameraActive: Bool
  let content: (SessionPresence) -> Content

  func makeUIViewController(context: Context) -> SceneCameraPlaneController<Revision> {
    SceneCameraPlaneController()
  }
  func updateUIViewController(_ controller: SceneCameraPlaneController<Revision>, context: Context) {
    controller.update(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision, isCameraActive: isCameraActive) { anchor, projection in
      AnyView(content(anchor).environment(\.scenePlaneProjection, projection)
        .frame(width: anchor.viewport.x, height: anchor.viewport.y).ignoresSafeArea())
    }
  }
}

@MainActor
final class SceneCameraPlaneController<Revision: Equatable>: UIViewController, SceneCameraPlaneActivity {
  private let host = UIHostingController(rootView: AnyView(EmptyView()))
  private var anchor: SessionPresence?
  private var revision: Revision?
  private var projection: ScenePlaneProjection?
  private(set) var contentPublicationCount = 0
  private(set) var cameraProjectionCount = 0
  var contentView: UIView { host.view }

  override func loadView() {
    let container = ScenePlaneContainer()
    container.backgroundColor = .clear
    container.isOpaque = false
    view = container
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
    content: (SessionPresence, ScenePlaneProjection) -> AnyView) {
    loadViewIfNeeded()
    let needsRebase = anchor.map {
      SceneCameraProjection.requiresRebase(anchor: $0, current: presence)
        || (!isCameraActive && $0.camera != presence.camera)
    } ?? true
    if needsRebase || self.revision != revision {
      if needsRebase || reanchorsOnRevision { anchor = presence }
      self.revision = revision
      let projection = self.projection ?? ScenePlaneProjection(presence)
      projection.update(presence)
      self.projection = projection
      let prepared = anchor ?? presence
      host.rootView = content(prepared, projection)
      host.view.bounds = CGRect(x: 0, y: 0, width: prepared.viewport.x, height: prepared.viewport.y)
      contentPublicationCount += 1
    }
    guard let anchor else { return }
    projection?.update(presence)
    let matrix = SceneCameraProjection(anchor: anchor, current: presence)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    host.view.transform = CGAffineTransform(scaleX: matrix.scale, y: matrix.scale)
    host.view.center = CGPoint(x: anchor.viewport.x / 2 * matrix.scale + matrix.translation.x,
      y: anchor.viewport.y / 2 * matrix.scale + matrix.translation.y)
    CATransaction.commit()
    cameraProjectionCount += 1
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
  let presence: SessionPresence
  let revision: Revision
  let reanchorsOnRevision: Bool
  let isCameraActive: Bool
  let content: (SessionPresence) -> Content

  func makeNSView(context: Context) -> SceneCameraPlaneView<Revision> { SceneCameraPlaneView() }
  func updateNSView(_ view: SceneCameraPlaneView<Revision>, context: Context) {
    view.update(presence: presence, revision: revision, reanchorsOnRevision: reanchorsOnRevision, isCameraActive: isCameraActive) { anchor, projection in
      AnyView(content(anchor).environment(\.scenePlaneProjection, projection)
        .frame(width: anchor.viewport.x, height: anchor.viewport.y).ignoresSafeArea())
    }
  }
}

@MainActor
final class SceneCameraPlaneView<Revision: Equatable>: NSView, SceneCameraPlaneActivity {
  private let host = NSHostingView(rootView: AnyView(EmptyView()))
  private var anchor: SessionPresence?
  private var revision: Revision?
  private var projection: ScenePlaneProjection?
  private(set) var contentPublicationCount = 0
  private(set) var cameraProjectionCount = 0
  override var isFlipped: Bool { true }
  var contentView: NSView { host }

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
    content: (SessionPresence, ScenePlaneProjection) -> AnyView) {
    let needsRebase = anchor.map {
      SceneCameraProjection.requiresRebase(anchor: $0, current: presence)
        || (!isCameraActive && $0.camera != presence.camera)
    } ?? true
    if needsRebase || self.revision != revision {
      if needsRebase || reanchorsOnRevision { anchor = presence }
      self.revision = revision
      let projection = self.projection ?? ScenePlaneProjection(presence)
      projection.update(presence)
      self.projection = projection
      let prepared = anchor ?? presence
      host.rootView = content(prepared, projection)
      host.frame = CGRect(x: 0, y: 0, width: prepared.viewport.x, height: prepared.viewport.y)
      contentPublicationCount += 1
    }
    guard let anchor else { return }
    projection?.update(presence)
    let matrix = SceneCameraProjection(anchor: anchor, current: presence)
    // AppKit's bounds transform also supplies exact native event conversion;
    // a layer-only transform would leave hit testing in the old camera.
    bounds = CGRect(x: -matrix.translation.x / matrix.scale,
      y: -matrix.translation.y / matrix.scale,
      width: presence.viewport.x / matrix.scale, height: presence.viewport.y / matrix.scale)
    cameraProjectionCount += 1
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self || hit === host ? nil : hit
  }
}
#endif
