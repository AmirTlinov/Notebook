import NotebookCore
import SwiftUI

private struct MacDocumentDisplayScaleKey: EnvironmentKey {
  static let defaultValue = 1.0
}
extension EnvironmentValues {
  var macDocumentDisplayScale: Double {
    get { self[MacDocumentDisplayScaleKey.self] }
    set { self[MacDocumentDisplayScaleKey.self] = newValue }
  }
}

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
      model.boardHierarchy?.board(presence.boardID)?.focusedCenter(of: id) != nil {
      let geometry = model.itemGeometry(id)
      SceneCameraPlane(presence: presence,
        revision: Revision(item: id, page: presence.notebookPageID,
          documentPage: presence.documentPageIndex, content: model.collaborationReadEpoch),
        reanchorsOnRevision: false, isCameraActive: model.presencePhase == .active,
        hitRegions: { anchor in [NotebookAttentionProjection.readingPaperFrame(model:model,presence:anchor) ?? .zero] }) { anchor in
        let frame = NotebookAttentionProjection.readingPaperFrame(model:model,presence:anchor) ?? .zero
        // WebKit owns document projection through pageZoom. Supply its native
        // host in screen points rather than applying a second ancestor scale.
        let projectedDocument = presence.mode == .document
        Group {
          if presence.mode == .page {
            MacNotebookPageSurface(notebookID: id, displayProjection: anchor.camera.scale)
          } else if presence.mode == .document, let document = model.documents[id], let state = model.documentStates[id] {
            MacDocumentSurface(document: document, state: state, onLayout: { documentLayout = $0 })
              .environment(\.macDocumentDisplayScale, anchor.camera.scale)
          } else {
            VStack(spacing: 12) {
              if let error = model.persistenceFailure { Text(error).foregroundStyle(.secondary) }
              else { ProgressView(presence.mode == .page ? "Открываем лист…" : "Открываем документ…") }
            }
          }
        }
        .frame(width: projectedDocument ? frame.width : geometry.width,
          height: projectedDocument ? frame.height : geometry.height)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: geometry.cornerRadius))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .scaleEffect(projectedDocument ? 1 : anchor.camera.scale)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .environment(model).environment(\.sceneComposition, .init(nil))
        .environment(\.workspaceSceneFrame, nil)
      }
      .accessibilityIdentifier("mac-reading-surface")
    }
  }


}

enum MacReadingCamera {
  enum Fit { case width, page, actual }
  static let horizontalMargin = 24.0

  private static func available(_ viewport: SpatialPoint) -> SpatialPoint {
    // A reader has side gutters, not a footer outside the physical paper.
    .init(x: max(1, viewport.x - horizontalMargin * 2), y: viewport.y)
  }

  static func fitted(center: WorldPoint, geometry: WorkspaceItemGeometry, viewport: SpatialPoint, fit: Fit) -> SpatialCamera {
    let space = available(viewport)
    let width = space.x / geometry.width
    let height = space.y / geometry.height
    let scale: Double = switch fit {
    case .width: width
    case .page: min(width, height)
    case .actual: 1
    }
    return top(.init(center: center, scale: scale), center: center, geometry: geometry, viewport: viewport)
  }

  static func top(_ camera: SpatialCamera, center: WorldPoint, geometry: WorkspaceItemGeometry, viewport: SpatialPoint) -> SpatialCamera {
    let y = max(0, geometry.height / 2 - viewport.y / (2 * camera.scale))
    return .init(center: center.offsetBy(x: center.delta(to: camera.center).x, y: -y), scale: camera.scale)
  }

  static func constrained(_ camera: SpatialCamera, center: WorldPoint, geometry: WorkspaceItemGeometry, viewport: SpatialPoint) -> SpatialCamera {
    geometry.readingCamera(camera, centeredOn: center, viewport: available(viewport), maximumScale: 8)
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

// The reader, contact picker and selection controls share the physical paper
// projection even when no board composition has ever been installed.
extension NotebookAttentionProjection {
  static func readingPaperFrame(model:NotebookAppModel,presence:SessionPresence) -> CGRect? {
    guard presence.mode == .page || presence.mode == .document, let id = presence.focusedItemID,
      let center = model.boardHierarchy?.board(presence.boardID)?.focusedCenter(of:id) else { return nil }
    let box = model.itemGeometry(id).screenFrame(center:center,camera:presence.camera,viewport:presence.viewport)
    return .init(x:box.x,y:box.y,width:box.width,height:box.height)
  }
}
