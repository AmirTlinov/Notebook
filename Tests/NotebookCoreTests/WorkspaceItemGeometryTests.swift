import Foundation
import Testing
@testable import NotebookCore

@Test("Обложка и лист получают один физический размер A4 или Letter", arguments: [SpatialPoint(x: 420, y: 594), SpatialPoint(x: 1080, y: 300)])
func documentOwnsItsPhysicalRectangle(paper: SpatialPoint) {
  let geometry = WorkspaceItemGeometry.document(widthPoints: paper.x, heightPoints: paper.y)
  #expect(abs(geometry.width / geometry.height - paper.x / paper.y) < 1e-12)
  #expect(abs(geometry.width / paper.x - 132.0 / 72) < 1e-12)
  #expect(abs(geometry.height / paper.y - 132.0 / 72) < 1e-12)
}

@Test("Документ сохраняет края и обратимый масштаб при повороте", arguments: [SpatialPoint(x: 420, y: 594), SpatialPoint(x: 1080, y: 300)], [
  SpatialPoint(x: 834, y: 1_194), SpatialPoint(x: 1_366, y: 1_024),
  SpatialPoint(x: 744, y: 1_133), SpatialPoint(x: 1_512, y: 982),
])
func documentCameraUsesItsOwnGeometry(paper: SpatialPoint, viewport: SpatialPoint) {
  let geometry = WorkspaceItemGeometry.document(widthPoints: paper.x, heightPoints: paper.y)
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

}
