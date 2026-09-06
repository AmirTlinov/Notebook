import Foundation
import Testing
@testable import NotebookCore

@Test("Вход сохраняет положение точки вне центра в обеих ориентациях", arguments: [
  SpatialPoint(x: 834, y: 1194), SpatialPoint(x: 1366, y: 1024)
])
func portalPassagePreservesOffCenterProjection(viewport: SpatialPoint) throws {
  let portalCenter = WorldPoint(x: -82_340, y: 19_910)
  let portal = BoardPortalCamera(center: .init(x: 38_911, y: -91_020), scale: 0.12)
  let parent = SpatialCamera(center: portalCenter.offsetBy(x: 40, y: -70),
    scale: BoardPortalProjection.fillScale(viewport: viewport) * 1.3)
  let child = try #require(BoardPortalProjection.enteringCamera(from: parent,
    portalCamera: portal, portalCenter: portalCenter, viewport: viewport))
  let point = portal.center.offsetBy(x: 600, y: -210)
  let inPortal = portalCenter.offsetBy(x: 600 * portal.scale, y: -210 * portal.scale)
  let before = parent.worldToScreen(inPortal, viewport: viewport)
  let after = child.worldToScreen(point, viewport: viewport)
  #expect(abs(before.x - after.x) < 1e-8)
  #expect(abs(before.y - after.y) < 1e-8)
  #expect(BoardPortalProjection.enteringCamera(from: .init(center: portalCenter, scale: parent.scale / 2),
    portalCamera: portal, portalCenter: portalCenter, viewport: viewport) == nil)
}

@Test("Выход продолжает щипок, включая нижнюю границу камеры", arguments: [
  SpatialPoint(x: 834, y: 1194), SpatialPoint(x: 1366, y: 1024)
], [SpatialCamera.minimumScale, 0.22, 0.71])
func portalExitCarriesRemainingFingerMovement(viewport: SpatialPoint, scale: Double) throws {
  let boundary = SpatialCamera(center: .init(x: 7500, y: -9000), scale: scale)
  let portalCenter = WorldPoint(x: -11_000, y: 34_000)
  let centroid = SpatialPoint(x: viewport.x * 0.7, y: viewport.y * 0.3)
  let ratio = 0.8
  let exit = BoardPortalProjection.exitingCamera(boundary: boundary, magnification: ratio,
    centroid: centroid, portalCenter: portalCenter, viewport: viewport)
  #expect(abs(exit.parentCamera.scale - BoardPortalProjection.fillScale(viewport: viewport) * ratio) < 1e-10)
  let point = boundary.center.offsetBy(x: 230, y: -170)
  let local = portalCenter.offsetBy(x: 230 * exit.portalCamera.scale, y: -170 * exit.portalCamera.scale)
  let before = boundary.worldToScreen(point, viewport: viewport)
  let after = exit.parentCamera.worldToScreen(local, viewport: viewport)
  #expect(abs(after.x - (centroid.x + (before.x - centroid.x) * ratio)) < 1e-8)
  #expect(abs(after.y - (centroid.y + (before.y - centroid.y) * ratio)) < 1e-8)
}

@Test("Передача не подменяет проекцию ограничением масштаба")
func portalPassageDoesNotClampAtHandoff() {
  let viewport = BoardPortalProjection.viewport
  #expect(BoardPortalProjection.enteringCamera(from: .init(scale: 2),
    portalCamera: .init(scale: 4), portalCenter: .zero, viewport: viewport) == nil)
}
