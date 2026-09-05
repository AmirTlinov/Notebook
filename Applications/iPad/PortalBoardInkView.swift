import NotebookCore
import SwiftUI

/// Portals and active boards project the same prepared vector mesh.
struct PortalBoardInkView: UIViewRepresentable {
  let boardID: UUID
  let journal: SpatialInkJournal?
  let camera: SpatialCamera
  let viewport: SpatialPoint
  func makeCoordinator() -> SpatialInkMeshPreparation { SpatialInkMeshPreparation() }
  func makeUIView(context: Context) -> InkCanvasView { InkCanvasView(frame: .zero) }
  func updateUIView(_ view: InkCanvasView, context: Context) {
    view.project(camera: camera, viewport: viewport)
    let pending = context.coordinator.update(surface: .board(boardID), journal: journal) { [weak view] mesh in
      if let mesh { view?.applySpatial(mesh) } else { view?.finishSpatialPreparation() }
    }
    if pending { view.prepareForDrawing() }
  }
  static func dismantleUIView(_ view: InkCanvasView, coordinator: SpatialInkMeshPreparation) { coordinator.cancel() }
}
