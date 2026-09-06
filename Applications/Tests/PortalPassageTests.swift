import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PortalPassageTests: XCTestCase {
  func testPinchCrossesThePortalBeforeReleaseAndKeepsTheSameVisiblePoint() async throws {
    try await assertPassage()
  }

  func testLandscapePassagePreservesTheSameVisiblePoint() async throws {
    try await assertPassage(viewport: .init(x: 1194, y: 834))
  }

  private func assertPassage(viewport: SpatialPoint? = nil) async throws {
    let scene = try await makeScene(viewport: viewport)
    defer { scene.close() }
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    let portal = try XCTUnwrap(scene.model.boardHierarchy?.portalCamera(scene.childID))
    let childStart = SpatialCamera(scale: 0.35 * portal.scale)
    try scene.send(.began(centroid: center, isOpeningApproach: true))
    let fill = BoardPortalProjection.fillScale(viewport: scene.viewport)
    let crossing = fill / 0.35
    for progress in [0.45, 0.7, 1.2, 1.4, 0.85, 1.3] {
      let scale = progress * crossing
      let centroid = CGPoint(x: center.x + (scale - 1) * 13, y: center.y - (scale - 1) * 9)
      try scene.send(.changed(scale: scale, velocity: progress == 0.85 ? -1 : 1, elapsed: 0.2, centroid: centroid))
      try await Task.sleep(for: .milliseconds(40))
      let camera = childStart.pinched(by: scale, from: .init(x: center.x, y: center.y),
        to: .init(x: centroid.x, y: centroid.y), viewport: scene.viewport)
      let expected = camera.worldToScreen(.init(x: 200, y: 150), viewport: scene.viewport)
      let point = try redPoint(in: scene.host.view)
      XCTAssertEqual(point.x, expected.x, accuracy: 2, "Смена доски сохраняет точку под продолжающими движение пальцами")
      XCTAssertEqual(point.y, expected.y, accuracy: 2)
      if progress >= 1.2 {
        XCTAssertEqual(scene.model.presence?.boardID, scene.childID, "Вход принадлежит геометрической границе, а не отпусканию")
      } else if progress == 0.85 {
        XCTAssertNotEqual(scene.model.presence?.boardID, scene.childID, "Обратный путь проходит ту же границу в том же жесте")
      }
    }
    let last = try XCTUnwrap(scene.model.presence)
    let scale = 1.3 * crossing
    let centroid = CGPoint(x: center.x + (scale - 1) * 13, y: center.y - (scale - 1) * 9)
    try scene.send(.ended(scale: scale, velocity: 1, elapsed: 0.3, centroid: centroid))
    try await Task.sleep(for: .milliseconds(450))
    let settled = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(settled.boardID, last.boardID)
    XCTAssertEqual(settled.mode, last.mode)
    XCTAssertEqual(settled.focusedItemID, last.focusedItemID)
    XCTAssertEqual(settled.camera.scale, last.camera.scale, accuracy: 1e-12,
      "Отпускание не добавляет автоматический скачок масштаба")
    let drift = last.camera.center.delta(to: settled.camera.center)
    XCTAssertEqual(drift.x, 0, accuracy: 1e-8)
    XCTAssertEqual(drift.y, 0, accuracy: 1e-8)
    await scene.model.finishPendingPersistence()
  }

  func testHandoffDoesNotStartColdWebContentUnderTheFingers() async throws {
    let scene = try await makeScene(elementCount: 10)
    defer { scene.close() }
    let input = UUID()
    scene.model.inputGate.beginContact(source: input)
    defer { scene.model.inputGate.endContact(source: input) }
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    let crossing = BoardPortalProjection.fillScale(viewport: scene.viewport) / 0.35
    try scene.send(.began(centroid: center, isOpeningApproach: true))
    try scene.send(.changed(scale: crossing * 1.1, velocity: 1, elapsed: 0.2, centroid: center))
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(scene.model.presence?.boardID, scene.childID)
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Готовый вид портала передаётся без создания WebKit и повторного запуска JavaScript под пальцами")
    _ = try redPoint(in: scene.host.view)
    try scene.send(.changed(scale: crossing * 0.9, velocity: -1, elapsed: 0.3, centroid: center))
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertNotEqual(scene.model.presence?.boardID, scene.childID)
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Обратный переход также использует уже подготовленное содержание")
    _ = try redPoint(in: scene.host.view)
    try scene.send(.ended(scale: crossing * 0.9, velocity: -1, elapsed: 0.4, centroid: center))
    scene.model.inputGate.endContact(source: input)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Пассивный портал не перезапускает десять готовых элементов после отпускания")
    _ = try redPoint(in: scene.host.view)

    scene.model.enterBoard(scene.childID)
    try await Task.sleep(for: .milliseconds(40))
    let deadline = ContinuousClock.now + .seconds(5)
    while agentWebViews(in: scene.host.view).count < 10, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(agentWebViews(in: scene.host.view).count, 10,
      "После контакта тот же элемент снова получает живой ввод")
    let mounted = Set(agentWebViews(in: scene.host.view).map(ObjectIdentifier.init))
    scene.model.inputGate.beginContact(source: input)
    try scene.send(.began(centroid: center, isOpeningApproach: true))
    try scene.send(.changed(scale: 1.04, velocity: 1, elapsed: 0.2, centroid: center))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(Set(agentWebViews(in: scene.host.view).map(ObjectIdentifier.init)), mounted,
      "Следующий щипок не размонтирует уже живые интерактивные элементы")
    try scene.send(.ended(scale: 1.04, velocity: 1, elapsed: 0.3, centroid: center))
    scene.model.inputGate.endContact(source: input)
    await scene.model.finishPendingPersistence()
  }

  func testPortalExitDoesNotMountDistantPaperSurfaces() async throws {
    let scene = try await makeScene()
    defer { scene.close() }
    let workspace = try XCTUnwrap(scene.model.workspace)
    let hierarchy = try XCTUnwrap(scene.model.boardHierarchy)
    let start = try XCTUnwrap(scene.model.presence)
    let distant = try XCTUnwrap(WorkspaceSceneProjection.items(workspace: workspace,
      board: XCTUnwrap(hierarchy.board(start.boardID)), presence: start, documents: scene.model.documents)
      .first(where: { $0.item.kind == .notebook }))
    XCTAssertFalse(WorkspaceSceneProjection.snapshotLayers(workspace: workspace, hierarchy: hierarchy,
      presence: start, documents: scene.model.documents).ink.contains { $0.surface == .cover(distant.id) },
      "Снимок агента перечисляет то же дерево отображения, сохраняя полный каталог для адресации")
    let focused = SessionPresence(boardID: start.boardID, mode: .cover, camera: start.camera,
      viewport: start.viewport, focusedItemID: distant.id, openProgress: 0)
    XCTAssertTrue(WorkspaceSceneProjection.mountsContent(of: distant, in: focused),
      "Сфокусированный предмет удерживает своего владельца ввода даже за краем кадра")
    func inkSurfaces(in view: UIView) -> Int {
      (view is InkCanvasView ? 1 : 0) + view.subviews.reduce(0) { $0 + inkSurfaces(in: $1) }
    }
    XCTAssertEqual(inkSurfaces(in: scene.host.view), 3,
      "Смонтированы только доска, чернила портала и его обложки; не далёкая тетрадь")
    scene.model.enterBoard(scene.childID)
    try await Task.sleep(for: .milliseconds(40))
    scene.model.leaveBoard()
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(inkSurfaces(in: scene.host.view), 3,
      "Выход из портала не монтирует невидимые предметы родительской доски")
    let presence = try XCTUnwrap(scene.model.presence)
    scene.model.updatePresence(.init(boardID: presence.boardID, mode: .board,
      camera: .init(center: .init(x: -30_000, y: -30_000), scale: 0.35),
      viewport: scene.viewport), settled: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(inkSurfaces(in: scene.host.view), 2,
      "Камера открывает обложку той же тетради; прежний портал теперь за пределами кадра")
    await scene.model.finishPendingPersistence()
  }

  private func agentWebViews(in view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { $0.navigationDelegate is AgentWebCoordinator ? [$0] : [] }
      ?? view.subviews.flatMap { agentWebViews(in: $0) }
  }

  func testMinimumZoomCanLeaveAndCancellationKeepsTheVisibleFrame() async throws {
    let scene = try await makeScene()
    defer { scene.close() }
    scene.model.enterBoard(scene.childID)
    scene.model.updatePresence(.init(boardID: scene.childID, mode: .board,
      camera: .init(scale: SpatialCamera.minimumScale), viewport: scene.viewport), settled: true)
    try await Task.sleep(for: .milliseconds(40))
    let center = CGPoint(x: scene.viewport.x * 0.6, y: scene.viewport.y * 0.4)
    try scene.send(.began(centroid: center, isOpeningApproach: false))
    try scene.send(.changed(scale: 0.8, velocity: -1, elapsed: 0.2, centroid: center))
    XCTAssertNotEqual(scene.model.presence?.boardID, scene.childID)
    let visible = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(visible.camera.scale, BoardPortalProjection.fillScale(viewport: scene.viewport) * 0.8, accuracy: 1e-10)
    try scene.send(.cancelled)
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(scene.model.presence, visible)
    await scene.model.finishPendingPersistence()
  }

  func testOrdinaryOverviewZoomDoesNotExitAtAnArbitraryGestureRatio() async throws {
    let scene = try await makeScene()
    defer { scene.close() }
    scene.model.enterBoard(scene.childID)
    scene.model.updatePresence(.init(boardID: scene.childID, mode: .board,
      camera: .init(scale: 1), viewport: scene.viewport), settled: true)
    try await Task.sleep(for: .milliseconds(40))
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    try scene.send(.began(centroid: center, isOpeningApproach: false))
    try scene.send(.changed(scale: 0.7, velocity: -1, elapsed: 0.2, centroid: center))
    try scene.send(.ended(scale: 0.7, velocity: -1, elapsed: 0.3, centroid: center))
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(scene.model.presence?.boardID, scene.childID)
    XCTAssertEqual(try XCTUnwrap(scene.model.presence?.camera.scale), 0.7, accuracy: 1e-10)
    await scene.model.finishPendingPersistence()
  }

  @MainActor private struct Scene {
    let root: URL
    let model: NotebookAppModel
    let childID: UUID
    let viewport: SpatialPoint
    let window: UIWindow
    let host: UIViewController

    func send(_ phase: WorkspaceMagnificationPhase) throws {
      let coordinator = try XCTUnwrap(window.gestureRecognizers?.compactMap {
        $0.delegate as? WorkspaceGestureLayer.Coordinator
      }.first)
      coordinator.onCamera(phase)
    }

    func close() {
      window.isHidden = true
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeScene(viewport requestedViewport: SpatialPoint? = nil, elementCount: Int = 1) async throws -> Scene {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: -30_000, y: -30_000))
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    await model.finishPendingPersistence()
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let elements = (0..<elementCount).map { index in
      SpatialElement(id: UUID().uuidString, surface: .board(childID), kind: .web,
        frame: .init(x: 0, y: 0, width: 400, height: 300),
        worldOrigin: .init(x: Double(index % 3) * 500, y: Double(index / 3) * 400), source: "Portal marker",
        html: "<svg width='100%' height='100%' viewBox='0 0 400 300'><circle cx='200' cy='150' r='65' fill='#ed2020'/></svg>",
        stamp: .init(counter: 0, actor: model.actorID))
    }
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: childID, expected: nil, actor: model.actorID))
    }
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    model.reloadExternalChanges()
    await model.finishPendingPersistence()
    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: windowScene)
    if let size = requestedViewport { window.frame = CGRect(x: 0, y: 0, width: size.x, height: size.y) }
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    model.updatePresence(.init(boardID: try XCTUnwrap(model.workspace?.rootBoardID), mode: .board,
      camera: .init(scale: 0.35), viewport: viewport), settled: false)
    window.makeKeyAndVisible()
    let deadline = ContinuousClock.now + .seconds(6)
    while elements.contains(where: { AgentElementSnapshotCache.shared.image(for: agentElementSnapshotSource($0)) == nil }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertTrue(elements.allSatisfy { AgentElementSnapshotCache.shared.image(for: agentElementSnapshotSource($0)) != nil })
    try await Task.sleep(for: .milliseconds(40))
    return Scene(root: root, model: model, childID: childID, viewport: viewport, window: window, host: host)
  }

  private func redPoint(in view: UIView) throws -> CGPoint {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    try bytes.withUnsafeMutableBytes { pixels in
      let context = try XCTUnwrap(CGContext(data: pixels.baseAddress, width: cg.width, height: cg.height,
        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    var sumX = 0.0, sumY = 0.0, count = 0.0
    for y in 0..<cg.height { for x in 0..<cg.width {
      let p = (y * cg.width + x) * 4
      if bytes[p] > 180, bytes[p + 1] < 80, bytes[p + 2] < 80, bytes[p + 3] > 180 {
        count += 1; sumX += Double(x) + 0.5; sumY += Double(y) + 0.5
      }
    }}
    let attachment = XCTAttachment(image: image); attachment.name = "portal-camera-frame"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertGreaterThan(count, 10, "При передаче владельца видимый предмет не исчезает")
    return CGPoint(x: sumX / max(1, count), y: sumY / max(1, count))
  }
}
