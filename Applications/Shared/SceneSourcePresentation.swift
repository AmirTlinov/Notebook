import Foundation
import NotebookCore
import QuartzCore
import SwiftUI

/// Evidence belongs to the native consumer, not to a source hash remembered by
/// a cohort. Detach, replacement, opacity and runtime navigation revoke it at
/// the same owner which displays the pixels.
@MainActor
protocol SceneSourceInstallationOwner: AnyObject {
  func isShowing(_ installation: SceneSourceInstallation) -> Bool
}

@MainActor
final class SceneSourceInstallation {
  let source: SceneRasterSource
  let entryID: UUID?
  let runtimeToken: String?
  let requiresVisibility: Bool
  private weak var owner: (any SceneSourceInstallationOwner)?
  init(source: SceneRasterSource, entryID: UUID? = nil, runtimeToken: String? = nil,
    requiresVisibility: Bool = true, owner: any SceneSourceInstallationOwner) {
    self.source = source; self.entryID = entryID; self.runtimeToken = runtimeToken; self.owner = owner
    self.requiresVisibility = requiresVisibility
  }
  var isInstalled: Bool { owner?.isShowing(self) == true }
}

@MainActor
enum SceneSourceVisibility {
  #if os(iOS)
  static func isVisible(_ view: UIView) -> Bool {
    !visibleRect(view).isEmpty
  }
  static func visibleRect(_ view: UIView) -> CGRect {
    guard isMounted(view), let window = view.window else { return .null }
    var visible = view.convert(view.bounds, to: window).intersection(window.bounds)
    var ancestor = view.superview
    while let current = ancestor {
      if current.clipsToBounds || current.layer.masksToBounds {
        visible = visible.intersection(current.convert(current.bounds, to: window))
      }
      ancestor = current.superview
    }
    guard !visible.isNull, !visible.isEmpty else { return .null }
    return view.convert(visible, from: window).intersection(view.bounds)
  }
  static func isMounted(_ view: UIView) -> Bool {
    guard let window = view.window, !window.isHidden, !view.bounds.isEmpty else { return false }
    var ancestor: UIView? = view
    while let current = ancestor {
      guard !current.isHidden, current.alpha > 0.001 else { return false }
      ancestor = current.superview
    }
    return true
  }
  #else
  static func isVisible(_ view: NSView) -> Bool {
    isMounted(view) && !view.visibleRect.isEmpty
  }
  static func isMounted(_ view: NSView) -> Bool {
    guard let window = view.window, window.isVisible, !view.bounds.isEmpty else { return false }
    var ancestor: NSView? = view
    while let current = ancestor {
      guard !current.isHidden, current.alphaValue > 0.001 else { return false }
      ancestor = current.superview
    }
    return true
  }
  #endif
}

/// Readiness belongs to a source at its physical address. A global SQL cursor
/// or another program's completion cannot acknowledge these pixels.
struct SceneSourceAddress: Hashable, Sendable {
  let plane: SceneCompositionPlane
  let elementID: String
}

struct SceneSourceDemand: Equatable, Sendable {
  let source: AgentElement
  let minimumScale: Double
  var region: PageRect? = nil
  var worldOrigin: WorldPoint? = nil
  var rasterSource: SceneRasterSource { region.map { .agentRegion(source, $0) } ?? .agent(source) }
  var policy: AgentSnapshotPolicy { region.map { .region($0, scale: minimumScale) } ?? .exact(scale: minimumScale) }
  static func == (left: Self, right: Self) -> Bool {
    left.rasterSource == right.rasterSource && left.minimumScale == right.minimumScale
  }
}

struct SceneSourceReceipt: Sendable {
  enum Status: Equatable, Sendable { case pending, ready, failed(String) }
  let demand: SceneSourceDemand
  let installedSource: AgentElement?
  let installedScale: Double
  let status: Status
  var installedRegion: PageRect? = nil

  var hasCurrentPixels: Bool {
    guard status == .ready, let installedSource else { return false }
    return SceneRasterSource.agent(installedSource) == .agent(demand.source)
      && installedRegion == demand.region
      && installedScale + 0.000_001 >= demand.minimumScale
  }
}

/// A large source keeps its canonical viewport and program. Only visible local
/// pixels enter the raster pool. Snapping the crop to 256 output pixels gives
/// small camera translations reuse without tying geometry to pixel completion.
enum SceneSourceCapture {
  static func origin(element: SpatialElement, plane: SceneCompositionPlane, frame: WorkspaceSceneFrame) -> WorldPoint {
    if let itemID = plane.coverID,
      let carrier = frame.worksets[plane.boardID]?.items.first(where: { $0.id == itemID }) {
      return carrier.center.offsetBy(x: -carrier.geometry.width / 2 + element.frame.x,
        y: -carrier.geometry.height / 2 + element.frame.y)
    }
    return (element.worldOrigin ?? .zero).offsetBy(x: element.frame.x, y: element.frame.y)
  }

  static func visibleRect(source: AgentElement, origin: WorldPoint, presence: SessionPresence) -> CGRect {
    let topLeft = presence.camera.screenToWorld(.zero, viewport: presence.viewport)
    let delta = origin.delta(to: topLeft)
    return CGRect(x: delta.x, y: delta.y, width: presence.viewport.x / presence.camera.scale,
      height: presence.viewport.y / presence.camera.scale)
      .intersection(CGRect(x: 0, y: 0, width: source.frame.width, height: source.frame.height))
  }

  static func region(element: SpatialElement, plane: SceneCompositionPlane,
    presence: SessionPresence, frame: WorkspaceSceneFrame, density: Double) -> PageRect? {
    let width = element.frame.width, height = element.frame.height
    guard width * density > 2048 || height * density > 2048
      || width * height * density * density > 4_194_304 else { return nil }
    let topLeft = presence.camera.screenToWorld(.zero, viewport: presence.viewport)
    let origin = origin(element: element, plane: plane, frame: frame)
    let delta = origin.delta(to: topLeft)
    let visible = CGRect(x: delta.x, y: delta.y, width: presence.viewport.x / presence.camera.scale,
      height: presence.viewport.y / presence.camera.scale)
      .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    let step = 256 / density
    guard !visible.isNull, !visible.isEmpty else {
      // A finite metadata window includes overscan owners. Their nearest cell
      // stays bounded and cannot masquerade as coverage after entering view.
      let x = min(max(0, floor(delta.x / step) * step), max(0, width - step))
      let y = min(max(0, floor(delta.y / step) * step), max(0, height - step))
      return .init(x: x, y: y, width: min(step, width - x), height: min(step, height - y))
    }
    let x = max(0, floor(visible.minX / step) * step), y = max(0, floor(visible.minY / step) * step)
    let right = min(width, ceil(visible.maxX / step) * step), bottom = min(height, ceil(visible.maxY / step) * step)
    return .init(x: x, y: y, width: right - x, height: bottom - y)
  }
}

/// Existing tile presenters receive a source's whole affected fragment set in
/// one native transaction. SwiftUI then binds the new immutable paint receipt;
/// it does not independently stagger pixel replacement across those views.
@MainActor
final class SceneTilePresentationRegistry {
  private struct Address: Hashable {
    let plane: SceneCompositionPlane
    let tile: CompositionTile
    let range: ScenePaintRange
    init(_ key: SceneCompositionTileKey) { plane = key.plane; tile = key.tile; range = key.range }
  }
  private struct WeakPresenter {
    weak var view: AgentSnapshotRasterView?
    weak var cohort: SceneCompositionCohort?
    let key: SceneCompositionTileKey
  }
  private var presenters: [Address: WeakPresenter] = [:]

  func register(_ view: AgentSnapshotRasterView, key: SceneCompositionTileKey, cohort: SceneCompositionCohort) {
    presenters[Address(key)] = .init(view: view, cohort: cohort, key: key)
  }

  func install(_ rasters: [SceneCompositionTileKey: RasterLease]) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    presenters = presenters.filter { $0.value.view != nil }
    for (key, raster) in rasters {
      guard let presenter = presenters[Address(key)], let view = presenter.view, view.window != nil else { continue }
      // An older captured cohort stops proving this fragment before its
      // presenter's bytes change. Its independent lease still remains valid.
      presenter.cohort?.didReplaceTile(presenter.key)
      view.updateRaster(raster)
    }
  }
}
