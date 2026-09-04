import NotebookCore
import SwiftUI

/// The portal replays the same raw journal through the board's Metal renderer.
/// Its coordinator retains geometry until the journal or projection changes.
struct PortalBoardInkView: UIViewRepresentable {
  let boardID: UUID
  let journal: SpatialInkJournal?
  let camera: SpatialCamera
  let viewport: SpatialPoint

  struct Signature: Equatable {
    let boardID: UUID
    let stamp: VersionStamp?
    let camera: SpatialCamera
    let viewport: SpatialPoint
  }

  final class Coordinator {
    var signature: Signature?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> InkCanvasView {
    let view = InkCanvasView(frame: .zero)
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: InkCanvasView, context: Context) {
    let signature = Signature(boardID: boardID, stamp: journal?.stamp,
      camera: camera, viewport: viewport)
    guard context.coordinator.signature != signature else { return }
    context.coordinator.signature = signature
    view.applySpatial(SpatialInkComposer.boardLayers(
      board: .board(boardID), journal: journal, camera: camera, viewport: viewport
    ))
  }
}
