import Foundation
import Testing
@testable import NotebookCore

@Test("Обложка и лист получают один физический размер A4 или Letter", arguments: DocumentPaperSize.allCases)
func documentOwnsItsPhysicalRectangle(paper: DocumentPaperSize) {
  let geometry = WorkspaceItemGeometry.document(paper)
  #expect(abs(geometry.width / geometry.height - paper.widthPoints / paper.heightPoints) < 1e-12)
  #expect(abs(geometry.width / paper.widthPoints - 132.0 / 72) < 1e-12)
  #expect(abs(geometry.height / paper.heightPoints - 132.0 / 72) < 1e-12)
  #expect(geometry.width >= WorkspaceItemGeometry.notebook.width)
  #expect(geometry.height >= WorkspaceItemGeometry.notebook.height)
}

@Test("Документ сохраняет края и обратимый масштаб при повороте", arguments: DocumentPaperSize.allCases, [
  SpatialPoint(x: 834, y: 1_194), SpatialPoint(x: 1_366, y: 1_024),
  SpatialPoint(x: 744, y: 1_133), SpatialPoint(x: 1_512, y: 982),
])
func documentCameraUsesItsOwnGeometry(paper: DocumentPaperSize, viewport: SpatialPoint) {
  let geometry = WorkspaceItemGeometry.document(paper)
  let portrait = SpatialPoint(x: 834, y: 1_194)
  let center = WorldPoint(x: 8_400, y: -12_300)
  let original = SessionPresence(mode: .document,
    camera: SpatialCamera(center: center, scale: geometry.fitScale(viewport: portrait)),
    viewport: portrait, focusedItemID: UUID(), openProgress: 1)
  let rotated = original.adapted(to: viewport, geometry: geometry)
  let frame = geometry.screenFrame(center: center, camera: rotated.camera, viewport: viewport)
  #expect(frame.x >= -1e-9 && frame.y >= -1e-9)
  #expect(frame.x + frame.width <= viewport.x + 1e-9)
  #expect(frame.y + frame.height <= viewport.y + 1e-9)
  #expect(abs(frame.width - viewport.x) < 1e-9 || abs(frame.height - viewport.y) < 1e-9)
  #expect(rotated.adapted(to: portrait, geometry: geometry) == original)

  let free = SessionPresence(mode: .cover,
    camera: SpatialCamera(center: center, scale: geometry.coverScale(viewport: portrait)),
    viewport: portrait, focusedItemID: original.focusedItemID)
  let returned = free.adapted(to: viewport, geometry: geometry).adapted(to: portrait, geometry: geometry)
  #expect(abs(returned.camera.scale - free.camera.scale) < 1e-12)
  let attracted = NotebookDockingField.attractedCamera(free.camera,
    toward: center, viewport: portrait, geometry: geometry,
    correction: NotebookDockingCorrection(centerWeight: 1, scaleWeight: 1))
  #expect(abs(attracted.scale - original.camera.scale) < 1e-12)
}
