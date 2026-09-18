import NotebookCore
import SwiftUI

/// Reading is the focused material, not a magnified board with its neighbours.
/// Its scroll/zoom is still the local SessionPresence camera.
struct MacReadingSurface: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  @Binding var documentLayout: DocumentPageLayout?

  private struct Revision: Equatable {
    let item: UUID
    let page: UUID?
    let documentPage: Int
    let content: UInt64
  }

  var body: some View {
    if let id = presence.focusedItemID,
      let center = model.boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id) {
      let geometry = model.itemGeometry(id)
      SceneCameraPlane(presence: presence,
        revision: Revision(item: id, page: presence.notebookPageID,
          documentPage: presence.documentPageIndex, content: model.collaborationReadEpoch),
        reanchorsOnRevision: false, isCameraActive: model.presencePhase == .active,
        hitRegions: { anchor in [paperFrame(center: center, geometry: geometry, presence: anchor)] }) { anchor in
        let frame = paperFrame(center: center, geometry: geometry, presence: anchor)
        Group {
          if presence.mode == .page, let page = model.activePage {
            PageSurface(page: page, isCurrent: true, isInteractive: true, isVisible: true,
              onRenderReady: .init { _ in }, displayProjection: anchor.camera.scale)
          } else if presence.mode == .document, let document = model.documents[id], let state = model.documentStates[id] {
            MacDocumentSurface(document: document, state: state, onLayout: { documentLayout = $0 })
          } else {
            VStack(spacing: 12) {
              if let error = model.persistenceFailure { Text(error).foregroundStyle(.secondary) }
              else { ProgressView(presence.mode == .page ? "Открываем лист…" : "Открываем документ…") }
            }
          }
        }
        .frame(width: geometry.width, height: geometry.height)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: geometry.cornerRadius))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .scaleEffect(anchor.camera.scale)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .environment(model).environment(\.sceneComposition, .init(nil))
        .environment(\.workspaceSceneFrame, nil)
      }
      .accessibilityIdentifier("mac-reading-surface")
    }
  }

  private func paperFrame(center: WorldPoint, geometry: WorkspaceItemGeometry, presence: SessionPresence) -> CGRect {
    let point = presence.camera.worldToScreen(center, viewport: presence.viewport)
    let width = geometry.width * presence.camera.scale, height = geometry.height * presence.camera.scale
    return .init(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
  }
}

enum MacReadingCamera {
  enum Fit { case width, page, actual }
  static let margin = 24.0

  static func fitted(center: WorldPoint, geometry: WorkspaceItemGeometry, viewport: SpatialPoint, fit: Fit) -> SpatialCamera {
    let width = max(1, viewport.x - margin * 2) / geometry.width
    let height = max(1, viewport.y - margin * 2) / geometry.height
    let scale: Double = switch fit {
    case .width: width
    case .page: min(width, height)
    case .actual: 1
    }
    return top(.init(center: center, scale: scale), center: center, geometry: geometry, viewport: viewport)
  }

  static func top(_ camera: SpatialCamera, center: WorldPoint, geometry: WorkspaceItemGeometry, viewport: SpatialPoint) -> SpatialCamera {
    let y = max(0, geometry.height / 2 - (viewport.y / 2 - margin) / camera.scale)
    return .init(center: center.offsetBy(x: center.delta(to: camera.center).x, y: -y), scale: camera.scale)
  }

  static func constrained(_ camera: SpatialCamera, center: WorldPoint, geometry: WorkspaceItemGeometry, viewport: SpatialPoint) -> SpatialCamera {
    let minimum = min(max(1, viewport.x - margin * 2) / geometry.width,
      max(1, viewport.y - margin * 2) / geometry.height)
    let scale = min(8, max(minimum, camera.scale))
    let x = max(0, geometry.width / 2 - (viewport.x / 2 - margin) / scale)
    let y = max(0, geometry.height / 2 - (viewport.y / 2 - margin) / scale)
    let offset = center.delta(to: camera.center)
    return .init(center: center.offsetBy(x: min(x, max(-x, offset.x)), y: min(y, max(-y, offset.y))), scale: scale)
  }
}

extension NotebookAppModel {
  func macConstrainReading(_ camera: SpatialCamera, presence: SessionPresence) -> SpatialCamera {
    guard presence.mode == .page || presence.mode == .document, let id = presence.focusedItemID,
      let center = boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id) else { return camera }
    return MacReadingCamera.constrained(camera, center: center, geometry: itemGeometry(id), viewport: presence.viewport)
  }

  func macFitReading(_ fit: MacReadingCamera.Fit) {
    afterPageInput { [self] in
      guard let p = presence, let id = p.focusedItemID,
        let center = boardHierarchy?.board(p.boardID)?.focusedCenter(of: id) else { return }
      updatePresence(p.replacingCamera(MacReadingCamera.fitted(center: center, geometry: itemGeometry(id), viewport: p.viewport, fit: fit)), settled: true)
    }
  }

  func macReadingTop() {
    guard let p = presence, let id = p.focusedItemID,
      let center = boardHierarchy?.board(p.boardID)?.focusedCenter(of: id) else { return }
    updatePresence(p.replacingCamera(MacReadingCamera.top(p.camera, center: center, geometry: itemGeometry(id), viewport: p.viewport)), settled: true)
  }
}
