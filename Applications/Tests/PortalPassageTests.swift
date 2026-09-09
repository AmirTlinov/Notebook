import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PortalPassageTests: XCTestCase {
  func testSmallMeasuredApproachesKeepTheDistantNotebookOnTheBoardUntilOpening() async throws {
    let scene = try await makeScene()
    let rootID = try XCTUnwrap(scene.model.presence?.boardID)
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    scene.model.updatePresence(.init(boardID: rootID, mode: .board,
      camera: .init(center: .init(x: -30_000, y: -30_000), scale: 0.28),
      viewport: scene.viewport), settled: true)
    let deadline = ContinuousClock.now + .seconds(5)
    while scene.model.compositionTiles.published?.frame.workset(boardID: rootID)
      .items.contains(where: { $0.id == scene.distantID }) != true, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(scene.model.compositionTiles.published?.frame.workset(boardID: rootID)
      .items.contains { $0.id == scene.distantID } == true)

    for factor in [CGFloat(1.2), 1.4] {
      let before = try XCTUnwrap(scene.model.presence)
      try scene.send(.began(centroid: center, isOpeningApproach: true))
      try scene.send(.changed(scale: factor, velocity: 0.4, elapsed: 0.2, centroid: center))
      let measured = try XCTUnwrap(scene.model.presence)
      XCTAssertEqual(measured.camera.scale, before.camera.scale * Double(factor), accuracy: 1e-10)
      XCTAssertEqual(measured.mode, .board)
      XCTAssertEqual(measured.openProgress, 0)
      try scene.send(.ended(scale: factor, velocity: 0.4, elapsed: 0.3, centroid: center))
      try await Task.sleep(for: .milliseconds(350))
      let released = try XCTUnwrap(scene.model.presence)
      XCTAssertEqual(released.mode, .board, "A small real approach cannot silently dock after release")
      XCTAssertEqual(released.camera.scale, measured.camera.scale, accuracy: 1e-10)
    }
    try scene.send(.began(centroid: center, isOpeningApproach: true))
    for scale in [CGFloat(1.5), 2, 3, 4] {
      try scene.send(.changed(scale: scale, velocity: 2, elapsed: Double(scale) / 10, centroid: center))
    }
    try scene.send(.ended(scale: 4, velocity: 2, elapsed: 0.5, centroid: center))
    let openedDeadline = ContinuousClock.now + .seconds(3)
    while scene.model.presence?.mode != .page, ContinuousClock.now < openedDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let opened = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(opened.mode, .page)
    XCTAssertEqual(opened.focusedItemID, scene.distantID)
    XCTAssertEqual(opened.openProgress, 1)
    XCTAssertEqual(opened.camera.scale,
      scene.model.itemGeometry(scene.distantID).fitScale(viewport: scene.viewport), accuracy: 1e-10)
  }

  func testPinchCrossesThePortalBeforeReleaseAndKeepsTheSameVisiblePoint() async throws {
    try await assertPassage()
  }

  func testLandscapePassagePreservesTheSameVisiblePoint() async throws {
    try await assertPassage(viewport: .init(x: 1194, y: 834))
  }

  func testSeparatePinchesExitAtThePortalBoundaryNotAtTheGestureFraction() async throws {
    let scene = try await makeScene()
    let parentID = try XCTUnwrap(scene.model.presence?.boardID)
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    let portal = try XCTUnwrap(scene.model.boardHierarchy?.portalCamera(scene.childID))
    let boundary = BoardPortalProjection.entryCamera(portalCamera: portal, viewport: scene.viewport).scale
    let entryFactor = BoardPortalProjection.fillScale(viewport: scene.viewport) / 0.35 * 2.5
    try scene.send(.began(centroid: center, isOpeningApproach: true))
    try scene.send(.changed(scale: entryFactor, velocity: 1, elapsed: 0.2, centroid: center))
    try scene.send(.ended(scale: entryFactor, velocity: 1, elapsed: 0.3, centroid: center))
    let entered = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(entered.boardID, scene.childID)
    XCTAssertEqual(entered.camera.scale, boundary * 2.5, accuracy: 1e-10)

    try scene.send(.began(centroid: center, isOpeningApproach: false))
    try scene.send(.changed(scale: 0.55, velocity: -1, elapsed: 0.2, centroid: center))
    try scene.send(.ended(scale: 0.55, velocity: -1, elapsed: 0.3, centroid: center))
    let inside = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(inside.boardID, scene.childID)
    XCTAssertEqual(inside.camera.scale, entered.camera.scale * 0.55, accuracy: 1e-10)
    XCTAssertGreaterThan(inside.camera.scale, boundary)

    try scene.send(.began(centroid: center, isOpeningApproach: false))
    try scene.send(.changed(scale: 0.5, velocity: -1, elapsed: 0.2, centroid: center))
    let exiting = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(exiting.boardID, parentID)
    try scene.send(.ended(scale: 0.5, velocity: -1, elapsed: 0.3, centroid: center))
    try await Task.sleep(for: .milliseconds(350))
    let released = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(released.boardID, parentID)
    XCTAssertEqual(released.camera.scale, exiting.camera.scale, accuracy: 1e-10)
    XCTAssertEqual(released.camera.center, exiting.camera.center,
      "Release must preserve the last boundary projection, not add an overview jump")
  }

  func testSettledBoardExitKeepsContentVisibleBeforeRelease() async throws {
    try await assertSettledBoardExit(viewport: .init(x: 834, y: 1194))
  }

  func testLandscapeSettledBoardExitKeepsContentVisibleBeforeRelease() async throws {
    try await assertSettledBoardExit(viewport: .init(x: 1194, y: 834))
  }

  private func assertSettledBoardExit(viewport: SpatialPoint? = nil) async throws {
    let scene = try await makeScene(viewport: viewport)
    let parentID = try XCTUnwrap(scene.model.presence?.boardID)
    let original = try XCTUnwrap(scene.model.compositionTiles.published)
    scene.model.enterBoard(scene.childID)
    let deadline = ContinuousClock.now + .seconds(15)
    while (scene.model.compositionTiles.published?.plan.rootBoardID != scene.childID
      || scene.model.compositionTiles.published?.plan.revision != scene.model.workspaceHeader?.cursor
      || scene.model.scenePreparationPending || scene.model.compositionTiles.isPreparing),
      scene.model.compositionTiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let settled = try XCTUnwrap(scene.model.compositionTiles.published)
    XCTAssertEqual(settled.plan.rootBoardID, scene.childID,
      "Exit is tested after the child has replaced the entry cohort, not after a short timing guess")
    XCTAssertNotEqual(settled.id, original.id)
    XCTAssertNil(scene.model.compositionTiles.failure)
    let start = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(start.boardID, scene.childID)
    let before = try redPoint(in: scene.host.view)
    let marker = start.camera.worldToScreen(.init(x: 200, y: 150), viewport: scene.viewport)
    XCTAssertEqual(before.x, marker.x, accuracy: 2)
    XCTAssertEqual(before.y, marker.y, accuracy: 2)

    // Keep the preparation gate closed through the actual return contact. New
    // pixels after finger lift cannot retroactively satisfy the visible handoff.
    let input = UUID()
    scene.model.inputGate.beginContact(source: input)
    defer { scene.model.inputGate.endContact(source: input) }
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    try scene.send(.began(centroid: center, isOpeningApproach: false))
    try scene.send(.changed(scale: 0.75, velocity: -1, elapsed: 0.2, centroid: center))
    XCTAssertEqual(scene.model.presence?.boardID, parentID)
    XCTAssertFalse(scene.model.permitsBackgroundPreparation)
    scene.host.view.setNeedsLayout()
    scene.host.view.layoutIfNeeded()
    let after = try redPoint(in: scene.host.view)
    XCTAssertEqual(after.x, center.x + (before.x - center.x) * 0.75, accuracy: 2)
    XCTAssertEqual(after.y, center.y + (before.y - center.y) * 0.75, accuracy: 2)
    XCTAssertEqual(scene.model.compositionTiles.published?.id, settled.id,
      "The same complete cohort supplies both sides while preparation is forbidden")
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty)
    XCTAssertLessThanOrEqual(settled.plan.primitiveCount, 96)
    XCTAssertTrue(settled.rasters.values.allSatisfy { !$0.isReleased })
    try scene.send(.ended(scale: 0.75, velocity: -1, elapsed: 0.3, centroid: center))
    scene.model.inputGate.endContact(source: input)
    let saved = await scene.model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  private func assertPassage(viewport: SpatialPoint? = nil) async throws {
    let scene = try await makeScene(viewport: viewport)
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
      XCTAssertEqual(point.x, expected.x, accuracy: 2, "Смена доски сохраняет точку под продолжающими движение пальцами; progress=\(progress)")
      XCTAssertEqual(point.y, expected.y, accuracy: 2, "progress=\(progress)")
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
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Entering a board does not activate every prepared source")
    let interactive = try XCTUnwrap(scene.model.boardHierarchy?.board(scene.childID)?.elements.first { !$0.javaScript.isEmpty })
    scene.model.interactiveElementFocus = .board(boardID: scene.childID, elementID: interactive.id)
    let mounted: Set<ObjectIdentifier> = [try await interactiveIdentity(in: scene)]
    XCTAssertEqual(agentWebViews(in: scene.host.view).count, 1,
      "Явное обращение активирует одну схему, а не всю доску")
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

  private func interactiveIdentity(in scene: Scene) async throws -> ObjectIdentifier {
    // Return identity, not a second owner of WebKit in the XCTest async frame.
    // The mounted scene remains the runtime owner during the following gesture.
    let deadline = ContinuousClock.now + .seconds(5)
    var active: WKWebView?
    while active == nil, ContinuousClock.now < deadline {
      for web in agentWebViews(in: scene.host.view) {
        if (try? await web.evaluateJavaScript("document.body.dataset.interactive")) as? String == "ready" {
          active = web; break
        }
      }
      if active != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    return ObjectIdentifier(try XCTUnwrap(active,
      "The next contact belongs to the explicit interactive program, not a temporary preparatory WebKit"))
  }

  func testPortalExitDoesNotMountDistantPaperSurfaces() async throws {
    let scene = try await makeScene()
    let start = try XCTUnwrap(scene.model.presence)
    let header = try scene.model.store.workspaceHeader()
    let source = SceneCompositionSource(store: scene.model.store, revision: header.cursor, workspaceID: header.workspaceID)
    let addressedDistant = try await source.item(scene.distantID, presence: start)
    let distant = try XCTUnwrap(addressedDistant)
    XCTAssertFalse(scene.model.sceneWorkset(presence: start).items.contains { $0.id == distant.id },
      "Рабочий кадр не монтирует далёкую бумагу; адресный индекс продолжает знать её владельца")
    let focused = SessionPresence(boardID: start.boardID, mode: .cover, camera: start.camera,
      viewport: start.viewport, focusedItemID: distant.id, openProgress: 0)
    XCTAssertTrue(WorkspaceSceneProjection.mountsContent(of: distant, in: focused),
      "Сфокусированный предмет удерживает своего владельца ввода даже за краем кадра")
    func inkCanvases(in view: UIView) -> [InkCanvasView] {
      (view as? InkCanvasView).map { [$0] } ?? view.subviews.flatMap { inkCanvases(in: $0) }
    }
    func assertPhysicalSurfaces(_ expected: Set<SurfaceID>) throws {
      let mounted = inkCanvases(in: scene.host.view)
      let surfaces = try mounted.map { try XCTUnwrap($0.installedSpatialSource?.surface) }
      XCTAssertEqual(Set(surfaces), expected)
      XCTAssertEqual(mounted.count, expected.count, "Каждый физический адрес имеет ровно один Canvas")
      for canvas in mounted {
        let surface = try XCTUnwrap(canvas.installedSpatialSource?.surface)
        XCTAssertTrue(scene.model.compositionTiles.surfaceRegistry.canvas(for: surface) === canvas)
      }
    }
    let portalSurfaces: Set<SurfaceID> = [.board(start.boardID), .cover(scene.childID), .board(scene.childID)]
    try assertPhysicalSurfaces(portalSurfaces)
    XCTAssertNil(scene.model.compositionTiles.surfaceRegistry.canvas(for: .cover(scene.distantID)),
      "Подготовка портала не создаёт владельца далёкой тетради")
    scene.model.enterBoard(scene.childID)
    try await Task.sleep(for: .milliseconds(40))
    scene.model.leaveBoard()
    try await Task.sleep(for: .milliseconds(40))
    try assertPhysicalSurfaces(portalSurfaces)
    XCTAssertNil(scene.model.compositionTiles.surfaceRegistry.canvas(for: .cover(scene.distantID)),
      "Выход из портала не монтирует невидимые предметы родительской доски")
    let presence = try XCTUnwrap(scene.model.presence)
    scene.model.updatePresence(.init(boardID: presence.boardID, mode: .board,
      camera: .init(center: .init(x: -30_000, y: -30_000), scale: 0.35),
      viewport: scene.viewport), settled: true)
    let coverageDeadline = ContinuousClock.now + .seconds(5)
    while (scene.model.compositionTiles.published?.frame.workset(boardID: start.boardID).items.contains(where: { $0.id == distant.id }) != true
      || Set(inkCanvases(in: scene.host.view).compactMap { $0.installedSpatialSource?.surface }) != Set([.board(start.boardID), .cover(distant.id)])),
      scene.model.compositionTiles.failure == nil, ContinuousClock.now < coverageDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let reached = scene.model.compositionTiles.published
    let coverage = "failure=\(scene.model.compositionTiles.failure ?? "nil"); modelFrame=\(String(describing: scene.model.sceneIndex?.generationID)); shownFrame=\(String(describing: reached?.frame.index.generationID)); modelContainsOwner=\(scene.model.sceneIndex?.renderedItem(id: distant.id, presence: scene.model.presence ?? start) != nil); pending=\(scene.model.scenePreparationPending); preparing=\(scene.model.compositionTiles.isPreparing); permits=\(scene.model.permitsBackgroundPreparation); publication=\(scene.model.scenePublicationGeneration)"
    XCTAssertTrue(scene.model.compositionTiles.published?.frame.workset(boardID: start.boardID).items.contains { $0.id == distant.id } == true,
      "The new physical coverage must contain the reached notebook: " + coverage)
    try assertPhysicalSurfaces([.board(start.boardID), .cover(distant.id)])
    await scene.model.finishPendingPersistence()
  }

  func testTenDistantCameraRoundTripsReleaseSupersededNativeTilesBeforeShutdown() async throws {
    let scene = try await makeScene()
    let start = try XCTUnwrap(scene.model.presence)
    let resources = SceneRenderResources.shared
    func shownBytes() -> Int {
      guard let cohort = scene.model.compositionTiles.published else { return 0 }
      var entries: [UUID: Int] = [:]
      for raster in Array(cohort.rasters.values) + Array(cohort.liveRasters.values) {
        entries[raster.entryID] = raster.accountedByteCount
      }
      return entries.values.reduce(0, +)
    }
    for round in 0..<10 {
      for center in [WorldPoint(x: -30_000, y: -30_000), start.camera.center] {
        let presence = SessionPresence(boardID: start.boardID, mode: .board,
          camera: .init(center: center, scale: 0.35), viewport: scene.viewport)
        scene.model.updatePresence(presence, settled: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while scene.model.compositionTiles.published?.plan.presentations[.board(start.boardID)]?.camera.center != center,
          scene.model.compositionTiles.failure == nil, ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(scene.model.compositionTiles.failure)
        XCTAssertEqual(scene.model.compositionTiles.published?.plan.presentations[.board(start.boardID)]?.camera.center, center)
        scene.host.view.setNeedsLayout(); scene.host.view.layoutIfNeeded()
        let retirement = ContinuousClock.now + .seconds(3)
        while resources.rasterAdmission.pinnedBytes > shownBytes(), ContinuousClock.now < retirement {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(resources.rasterAdmission.pinnedBytes, shownBytes(),
          "Round \(round): a live scene must retire superseded tiles without waiting for model shutdown")
      }
    }
  }

  private func agentWebViews(in view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { $0.navigationDelegate is AgentWebCoordinator ? [$0] : [] }
      ?? view.subviews.flatMap { agentWebViews(in: $0) }
  }

  func testMinimumZoomCanLeaveAndCancellationKeepsTheVisibleFrame() async throws {
    let scene = try await makeScene()
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

  @MainActor private final class Scene {
    let model: NotebookAppModel
    let childID: UUID
    let distantID: UUID
    let viewport: SpatialPoint
    let window: UIWindow
    private var mountedHost: UIHostingController<AnyView>?
    var host: UIViewController {
      precondition(mountedHost != nil, "A closed portal fixture has no mounted content")
      return mountedHost!
    }

    init(model: NotebookAppModel, childID: UUID, distantID: UUID, viewport: SpatialPoint,
      window: UIWindow, host: UIHostingController<AnyView>) {
      self.model = model; self.childID = childID; self.distantID = distantID
      self.viewport = viewport; self.window = window; mountedHost = host
    }

    func close() {
      // UIKit can keep the detached hosting controller and its cached graph.
      // This fixture owns that root value, so close relinquishes its content
      // before removing the native host; it never revokes a borrowed raster.
      if let host = mountedHost {
        host.rootView = AnyView(EmptyView())
        // Process the actual conditional unmount while the host is still in
        // its window. Hiding first may leave SwiftUI's old graph deferred.
        host.viewIfLoaded?.setNeedsLayout()
        host.viewIfLoaded?.layoutIfNeeded()
      }
      window.isHidden = true
      window.rootViewController = nil
      // XCTest can retain the completed async test frame and its Scene. The
      // fixture, not model.shutdown, must relinquish this external UI borrower.
      mountedHost = nil
      model.compositionTiles.cancelPreparation()
    }

    func send(_ phase: WorkspaceMagnificationPhase) throws {
      let coordinator = try XCTUnwrap(window.gestureRecognizers?.compactMap {
        $0.delegate as? WorkspaceGestureLayer.Coordinator
      }.first)
      coordinator.onCamera(phase)
    }

  }

  private func makeScene(viewport requestedViewport: SpatialPoint? = nil, elementCount: Int = 1) async throws -> Scene {
    let resources = SceneRenderResources.shared
    let baseline = resources.rasterAdmission
    weak var retiredHost: UIViewController?
    weak var initialCohort: SceneCompositionCohort?
    addTeardownBlock { @MainActor in
      let deadline = ContinuousClock.now + .seconds(2)
      while resources.rasterAdmission.pinnedBytes > baseline.pinnedBytes, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      let receipt = "hostAlive=\(retiredHost != nil) initialCohortAlive=\(initialCohort != nil) before=\(baseline) after=\(resources.rasterAdmission)"
      XCTContext.runActivity(named: "Closed portal resource ownership") { activity in
        let attachment = XCTAttachment(string: receipt)
        attachment.name = "portal-retirement"; attachment.lifetime = .keepAlways
        activity.add(attachment)
      }
      XCTAssertNil(initialCohort, "A retired scene cannot retain its first composition indefinitely")
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, baseline.pinnedBytes,
        "Closing the scene and draining the model must release its raster pins")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let distantID = try XCTUnwrap(model.workspace?.selectedItemID)
    model.moveItem(distantID, to: .init(x: -30_000, y: -30_000))
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    await model.finishPendingPersistence()
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let elements = (0..<elementCount).map { index in
      SpatialElement(id: UUID().uuidString, surface: .board(childID), kind: .web,
        frame: .init(x: 0, y: 0, width: 400, height: 300),
        worldOrigin: .init(x: Double(index % 3) * 500, y: Double(index / 3) * 400), source: "Portal marker",
        html: "<svg width='100%' height='100%' viewBox='0 0 400 300'><circle cx='200' cy='150' r='65' fill='#ed2020'/></svg>",
        javaScript: index == 0 ? "document.body.dataset.interactive = 'ready';" : "",
        stamp: .init(counter: 0, actor: model.actorID))
    }
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: childID, expected: nil, actor: model.actorID))
    }
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: windowScene)
    if let size = requestedViewport { window.frame = CGRect(x: 0, y: 0, width: size.x, height: size.y) }
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    let host = UIHostingController(rootView: AnyView(SpatialWorkspaceView().environment(model).ignoresSafeArea()))
    let scene = Scene(model: model, childID: childID, distantID: distantID,
      viewport: viewport, window: window, host: host)
    addTeardownBlock { @MainActor in scene.close() }
    retiredHost = host
    window.rootViewController = host
    model.updatePresence(.init(boardID: try XCTUnwrap(model.workspace?.rootBoardID), mode: .board,
      camera: .init(scale: 0.35), viewport: viewport), settled: true)
    window.makeKeyAndVisible()
    let deadline = ContinuousClock.now + .seconds(15)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    let currentHeader = try model.store.workspaceHeader()
    let readiness = "failure=\(model.compositionTiles.failure ?? "nil"); header=\(String(describing: model.workspaceHeader?.cursor)); SQL=\(currentHeader.cursor); scenePending=\(model.scenePreparationPending); scene=\(String(describing: model.sceneIndex?.generationID)); tilesPreparing=\(model.compositionTiles.isPreparing); input=\(model.inputIsActive); pencil=\(model.inputGate.hasActivePencil); phase=\(model.presencePhase); permits=\(model.permitsBackgroundPreparation); WK=\(SceneRenderResources.shared.activeWebSurfaceCount); waitingWK=\(SceneRenderResources.shared.pendingWebRequestCount)"
    let cohort = try XCTUnwrap(model.compositionTiles.published, "Whole portal coverage must be ready: " + readiness)
    initialCohort = cohort
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertNotNil(cohort.plan.presentations[.board(childID)], "The continuing gesture transfers an already prepared physical plane")
    XCTAssertLessThanOrEqual(cohort.plan.liveOwners.count + 1, 8)
    XCTAssertLessThanOrEqual(cohort.plan.primitiveCount, 96)
    while !agentWebViews(in: host.view).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(agentWebViews(in: host.view).isEmpty, "Preparation completes before the fixed warm gesture route")
    return scene
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
