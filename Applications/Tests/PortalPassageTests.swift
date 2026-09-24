import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PortalPassageTests: XCTestCase {
  func testZoomCannotEnterOrLeaveNestedBoard() async throws {
    let scene = try await makeScene()
    let parent = try XCTUnwrap(scene.model.presence)
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    try scene.send(.began(centroid: center))
    try scene.send(.changed(scale: 6, velocity: 2, elapsed: 0.2, centroid: center))
    XCTAssertEqual(scene.model.presence?.boardID, parent.boardID, "Zoom cannot acquire the board under the fingers")
    try scene.send(.ended(scale: 6, velocity: 2, elapsed: 0.3, centroid: center))
    XCTAssertEqual(scene.model.presence?.boardID, parent.boardID)
    XCTAssertTrue(scene.model.enterBoard(scene.childID))
    let inside = try XCTUnwrap(scene.model.presence)
    for ratio: CGFloat in [0.1, 0.01] {
      try scene.send(.began(centroid: center))
      try scene.send(.changed(scale: ratio, velocity: -2, elapsed: 0.2, centroid: center))
      XCTAssertEqual(scene.model.presence?.boardID, scene.childID, "Zoom cannot leave the current board at any scale")
      try scene.send(.ended(scale: ratio, velocity: -2, elapsed: 0.3, centroid: center))
      XCTAssertEqual(scene.model.presence?.boardID, scene.childID)
    }
    XCTAssertEqual(scene.model.presence?.mode, inside.mode)
    await scene.model.finishPendingPersistence()
  }

  func testAllMeasuredApproachesKeepTheDistantNotebookOnTheBoard() async throws {
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
      try scene.send(.began(centroid: center))
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
    try scene.send(.began(centroid: center))
    for scale in [CGFloat(1.5), 2, 3, 4] {
      try scene.send(.changed(scale: scale, velocity: 2, elapsed: Double(scale) / 10, centroid: center))
    }
    try scene.send(.ended(scale: 4, velocity: 2, elapsed: 0.5, centroid: center))
    try await Task.sleep(for: .milliseconds(400))
    let released = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(released.mode, .board)
    XCTAssertNil(released.focusedItemID)
    XCTAssertEqual(released.openProgress, 0)

  }

  func testExplicitBoardExitKeepsPreparedContentVisible() async throws {
    try await assertSettledBoardExit(viewport: .init(x: 834, y: 1194))
  }

  func testLandscapeExplicitBoardExitKeepsPreparedContentVisible() async throws {
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
      || !scene.hasInstalledMarker()
      || scene.model.scenePreparationPending || scene.model.compositionTiles.isPreparing),
      scene.model.compositionTiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let settled = try XCTUnwrap(scene.model.compositionTiles.published)
    XCTAssertEqual(settled.plan.rootBoardID, scene.childID,
      "Exit is tested after the child has replaced the entry cohort, not after a short timing guess")
    XCTAssertNotEqual(settled.id, original.id)
    XCTAssertNil(scene.model.compositionTiles.failure)
    XCTAssertTrue(scene.hasInstalledMarker(), "The settled child must actually install its marker before exit")
    let start = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(start.boardID, scene.childID)
    attachMarkerHistory(in: scene, name: "settled-child-before-exit")
    let before = try redPoint(in: scene.host.view)
    let marker = start.camera.worldToScreen(.init(x: 200, y: 150), viewport: scene.viewport)
    XCTAssertEqual(before.x, marker.x, accuracy: 2)
    XCTAssertEqual(before.y, marker.y, accuracy: 2)

    // Keep the preparation gate closed through the actual return contact. New
    // pixels after finger lift cannot retroactively satisfy the visible handoff.
    let input = UUID()
    scene.model.inputGate.beginContact(source: input)
    defer { scene.model.inputGate.endContact(source: input) }
    XCTAssertTrue(scene.model.leaveBoard())
    XCTAssertEqual(scene.model.presence?.boardID, parentID)
    XCTAssertFalse(scene.model.permitsBackgroundPreparation)
    scene.host.view.setNeedsLayout()
    scene.host.view.layoutIfNeeded()
    attachMarkerHistory(in: scene, name: "same-cohort-during-parent-return")
    let after = try redPoint(in: scene.host.view)
    XCTAssertEqual(after.x, before.x, accuracy: 2)
    XCTAssertEqual(after.y, before.y, accuracy: 2)
    XCTAssertEqual(scene.model.compositionTiles.published?.id, settled.id,
      "The same complete cohort supplies both sides while preparation is forbidden")
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty)
    XCTAssertLessThanOrEqual(settled.plan.primitiveCount, 96)
    XCTAssertTrue(settled.rasters.values.allSatisfy { !$0.isReleased })
    scene.model.inputGate.endContact(source: input)
    let saved = await scene.model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  func testZoomKeepsFolderClosedUntilExplicitEntry() async throws {
    let scene = try await makeScene()
    let parentID = try XCTUnwrap(scene.model.presence?.boardID)
    let input = UUID()
    scene.model.inputGate.beginContact(source: input)
    defer { scene.model.inputGate.endContact(source: input) }
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    let crossing = BoardPortalProjection.fillScale(viewport: scene.viewport) / 0.35
    try scene.send(.began(centroid: center))
    try scene.send(.changed(scale: crossing * 1.1, velocity: 1, elapsed: 0.2, centroid: center))
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(scene.model.presence?.boardID, parentID)
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Зум портала не входит в доску и не запускает её программы")
    _ = try redPoint(in: scene.host.view, expectMarker: false)
    try scene.send(.changed(scale: crossing * 0.9, velocity: -1, elapsed: 0.3, centroid: center))
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertNotEqual(scene.model.presence?.boardID, scene.childID)
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Отдаление портала также сохраняет пассивное содержание")
    _ = try redPoint(in: scene.host.view, expectMarker: false)
    try scene.send(.ended(scale: crossing * 0.9, velocity: -1, elapsed: 0.4, centroid: center))
    scene.model.inputGate.endContact(source: input)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(agentWebViews(in: scene.host.view).isEmpty,
      "Закрытая папка не запускает программу после отпускания")
    _ = try redPoint(in: scene.host.view, expectMarker: false)

    scene.model.enterBoard(scene.childID)
    let entryDeadline = ContinuousClock.now + .seconds(10)
    while (scene.model.compositionTiles.published?.plan.rootBoardID != scene.childID
      || !scene.hasInstalledMarker() || scene.model.compositionTiles.isPreparing),
      ContinuousClock.now < entryDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(scene.model.compositionTiles.published?.plan.rootBoardID, scene.childID)
    XCTAssertTrue(scene.hasInstalledMarker())
    _ = try redPoint(in: scene.host.view)
    await scene.model.finishPendingPersistence()
  }

  func testEnteredBoardKeepsInstalledChildProgramsDuringZoom() async throws {
    let scene = try await makeScene(elementCount: 10)
    scene.model.enterBoard(scene.childID)
    let entryDeadline = ContinuousClock.now + .seconds(10)
    while (scene.model.compositionTiles.published?.plan.rootBoardID != scene.childID
      || !scene.hasInstalledMarker() || scene.model.compositionTiles.isPreparing),
      ContinuousClock.now < entryDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(scene.model.compositionTiles.published?.plan.rootBoardID, scene.childID)
    XCTAssertTrue(scene.hasInstalledMarker())
    let input = UUID()
    defer { scene.model.inputGate.endContact(source: input) }
    let center = CGPoint(x: scene.viewport.x / 2, y: scene.viewport.y / 2)
    let interactive = try XCTUnwrap(scene.model.boardHierarchy?.board(scene.childID)?.elements.first { !$0.javaScript.isEmpty })
    scene.model.interactiveElementFocus = .board(boardID: scene.childID, elementID: interactive.id)
    let mounted = try await preparedRuntimeIdentities(in: scene, focused: interactive)
    XCTAssertGreaterThan(mounted.count, 0)
    XCTAssertLessThanOrEqual(mounted.count, SceneRenderResources.shared.maximumWebSurfaces - 1,
      "Visible input owners leave one transient executor for static neighbours")
    XCTAssertLessThanOrEqual(mounted.count, SceneRenderResources.maximumVisiblePrograms,
      "Only visible bounded owners run; visible controls cannot become permanently queued pictures")
    scene.model.inputGate.beginContact(source: input)
    try scene.send(.began(centroid: center))
    try scene.send(.changed(scale: 1.04, velocity: 1, elapsed: 0.2, centroid: center))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(Set(agentWebViews(in: scene.host.view).map(ObjectIdentifier.init)), mounted,
      "Следующий щипок не размонтирует уже живые интерактивные элементы")
    try scene.send(.ended(scale: 1.04, velocity: 1, elapsed: 0.3, centroid: center))
    scene.model.inputGate.endContact(source: input)
    await scene.model.finishPendingPersistence()
  }

  private func preparedRuntimeIdentities(in scene: Scene, focused: SpatialElement) async throws -> Set<ObjectIdentifier> {
    // Observe the real runtime owners. Returning identities avoids retaining
    // WebKit in the XCTest async frame through the later retirement check.
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if let cohort = scene.model.compositionTiles.published,
        cohort.plan.rootBoardID == scene.childID,
        cohort.plan.protectedOwners.contains(where: { $0.id == .element(focused.id) }),
        !scene.model.compositionTiles.isPreparing {
        let ids = Set(cohort.runtimeOwners.filter { $0.plane.boardID == scene.childID }.map(\.elementID))
          .union([focused.id])
        let sources = (scene.model.boardHierarchy?.board(scene.childID)?.elements ?? [])
          .filter { ids.contains($0.id) }.map(agentElementSnapshotSource)
        let views = agentWebViews(in: scene.host.view)
        let expected = min(ids.count, SceneRenderResources.shared.maximumWebSurfaces - 1)
        let ready = views.allSatisfy { web in
          sources.contains { (web.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource($0) == true }
        }
        let focusedReady = views.contains {
          ($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(agentElementSnapshotSource(focused)) == true
        }
        if sources.count == ids.count, ready, focusedReady, views.count == expected {
          return Set(views.map(ObjectIdentifier.init))
        }
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("All admitted visible programs and the focused source must be ready before the next warm contact")
    return []
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
    try assertPhysicalSurfaces([.board(start.boardID), .cover(scene.childID)])
    XCTAssertNil(scene.model.compositionTiles.surfaceRegistry.canvas(for: .cover(scene.distantID)),
      "Подготовка портала не создаёт владельца далёкой тетради")
    scene.model.enterBoard(scene.childID)
    try await Task.sleep(for: .milliseconds(40))
    scene.model.leaveBoard()
    // Parent preparation is asynchronous; immediate-return pixels have their
    // own regression above. This scenario checks the settled mounted owners.
    let returnDeadline = ContinuousClock.now + .seconds(5)
    while Set(inkCanvases(in: scene.host.view).compactMap { $0.installedSpatialSource?.surface }) != portalSurfaces,
      scene.model.compositionTiles.failure == nil, ContinuousClock.now < returnDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
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

  func testMinimumZoomCannotLeaveAndCancellationKeepsTheBoard() async throws {
    let scene = try await makeScene()
    scene.model.enterBoard(scene.childID)
    scene.model.updatePresence(.init(boardID: scene.childID, mode: .board,
      camera: .init(scale: SpatialCamera.minimumScale), viewport: scene.viewport), settled: true)
    try await Task.sleep(for: .milliseconds(40))
    let center = CGPoint(x: scene.viewport.x * 0.6, y: scene.viewport.y * 0.4)
    try scene.send(.began(centroid: center))
    try scene.send(.changed(scale: 0.8, velocity: -1, elapsed: 0.2, centroid: center))
    XCTAssertEqual(scene.model.presence?.boardID, scene.childID)
    let visible = try XCTUnwrap(scene.model.presence)
    XCTAssertEqual(visible.camera.scale, SpatialCamera.minimumScale, accuracy: 1e-10)
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
    try scene.send(.began(centroid: center))
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
    let markerID: String
    let viewport: SpatialPoint
    let window: UIWindow
    private var mountedHost: UIHostingController<AnyView>?
    var host: UIViewController {
      precondition(mountedHost != nil, "A closed portal fixture has no mounted content")
      return mountedHost!
    }

    init(model: NotebookAppModel, childID: UUID, distantID: UUID, markerID: String, viewport: SpatialPoint,
      window: UIWindow, host: UIHostingController<AnyView>) {
      self.model = model; self.childID = childID; self.distantID = distantID
      self.markerID = markerID
      self.viewport = viewport; self.window = window; mountedHost = host
    }

    func hasInstalledMarker() -> Bool {
      guard let cohort = model.compositionTiles.published,
        let address = cohort.sourceReceipts.keys.first(where: { $0.elementID == markerID }) else { return false }
      return cohort.hasInstalledPixels(for: address)
    }

    func close() async {
      // Stop admission and drain preparation while the mounted owners can
      // acknowledge retirement. Hiding a still-running scene first permits a
      // late source completion to repopulate a cached SwiftUI graph.
      let stopped = await model.shutdown()
      XCTAssertTrue(stopped)
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
      while (resources.rasterAdmission.pinnedBytes > baseline.pinnedBytes || initialCohort != nil),
        ContinuousClock.now < deadline {
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
        javaScript: index == 0 ? "document.body.dataset.interactive = 'ready';notebook.ready(Promise.resolve());" : "",
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
    let markerID = try XCTUnwrap(elements.first?.id)
    let scene = Scene(model: model, childID: childID, distantID: distantID, markerID: markerID,
      viewport: viewport, window: window, host: host)
    addTeardownBlock { @MainActor in await scene.close() }
    retiredHost = host
    window.rootViewController = host
    model.updatePresence(.init(boardID: try XCTUnwrap(model.workspace?.rootBoardID), mode: .board,
      camera: .init(scale: 0.35), viewport: viewport), settled: true)
    window.makeKeyAndVisible()
    let deadline = ContinuousClock.now + .seconds(15)
    // A closed folder installs its own material, not the hidden child marker.
    // Entry/exit tests separately wait for the child's actual installed pixels.
    func folderIsInstalled() -> Bool {
      guard let cohort = model.compositionTiles.published else { return false }
      return cohort.isPaintInstalled && cohort.liveData.nonemptyBoardIDs.contains(childID)
    }
    while (!folderIsInstalled() || model.compositionTiles.isPreparing || model.scenePreparationPending),
      model.compositionTiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
    }
    let currentHeader = try model.store.workspaceHeader()
    let readiness = "failure=\(model.compositionTiles.failure ?? "nil"); header=\(String(describing: model.workspaceHeader?.cursor)); SQL=\(currentHeader.cursor); scenePending=\(model.scenePreparationPending); scene=\(String(describing: model.sceneIndex?.generationID)); tilesPreparing=\(model.compositionTiles.isPreparing); input=\(model.inputIsActive); pencil=\(model.inputGate.hasActivePencil); phase=\(model.presencePhase); permits=\(model.permitsBackgroundPreparation); WK=\(SceneRenderResources.shared.activeWebSurfaceCount); waitingWK=\(SceneRenderResources.shared.pendingWebRequestCount)"
    let cohort = try XCTUnwrap(model.compositionTiles.published, "Whole portal coverage must be ready: " + readiness)
    let sourceEvidence = XCTAttachment(string: """
      \(readiness)
      marker=\(markerID) child=\(childID) paintInstalled=\(cohort.isPaintInstalled)
      childElements=\(cohort.frame.workset(boardID: childID).elements.map(\.id))
      owners=\(cohort.plan.liveOwners)
      runtimes=\(cohort.runtimeOwners)
      receipts=\(cohort.sourceReceipts)
      liveRasters=\(cohort.liveRasters.keys)
      tiles=\(cohort.tileSources)
      """)
    sourceEvidence.name = "portal-source-installation"; sourceEvidence.lifetime = .keepAlways; add(sourceEvidence)
    XCTAssertTrue(folderIsInstalled(), "The folder material must be installed before the gesture: " + readiness)
    XCTAssertTrue(cohort.liveData.nonemptyBoardIDs.contains(childID), "Любое содержимое включает лист на папке")
    initialCohort = cohort
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertNotNil(cohort.plan.presentations[.board(childID)], "The continuing gesture transfers an already prepared physical plane")
    XCTAssertLessThanOrEqual(cohort.plan.nativeOwnerCount, SceneCompositionPlan.maximumNativeOwners)
    XCTAssertLessThanOrEqual(cohort.plan.liveOwners.count + cohort.plan.inkBoardIDs.count, SceneCompositionPlan.maximumLiveOwners)
    XCTAssertLessThanOrEqual(cohort.plan.primitiveCount, 96)
    while !agentWebViews(in: host.view).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(agentWebViews(in: host.view).isEmpty, "Preparation completes before the fixed warm gesture route")
    return scene
  }

  private func attachMarkerHistory(in scene: Scene, name: String) {
    guard let cohort = scene.model.compositionTiles.published else { return }
    let addresses = cohort.sourceReceipts.keys.filter { $0.elementID == scene.markerID }
    let sources = addresses.map { address -> String in
      let raster = cohort.sourceRasters[address]
      return "address=\(address) receipt=\(String(describing: cohort.sourceReceipts[address])) retainedEntry=\(String(describing: raster?.entryID)) retainedSource=\(String(describing: raster?.source)) retainedScale=\(String(describing: raster?.pixelScale)) released=\(String(describing: raster?.isReleased)) currentPixelsInstalled=\(cohort.hasInstalledPixels(for: address))"
    }
    let attachment = XCTAttachment(string: "cohort=\(cohort.id) root=\(cohort.plan.rootBoardID) presence=\(String(describing: scene.model.presence))\n" + sources.joined(separator: "\n"))
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func redPoint(in view: UIView, expectMarker: Bool = true) throws -> CGPoint {
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
    var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1, count = 0
    for y in 0..<cg.height { for x in 0..<cg.width {
      let p = (y * cg.width + x) * 4
      if bytes[p] > 180, bytes[p + 1] < 80, bytes[p + 2] < 80, bytes[p + 3] > 180 {
        count += 1
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
      }
    }}
    let attachment = XCTAttachment(image: image); attachment.name = "portal-camera-frame"; attachment.lifetime = .keepAlways; add(attachment)
    if expectMarker {
      XCTAssertGreaterThan(count, 10, "При передаче владельца видимый предмет не исчезает")
    } else {
      XCTAssertEqual(count, 0, "Закрытая папка не показывает миниатюру содержимого")
    }
    // A loading/paused control can occlude the circle's interior. Its opposite
    // outer edges still name its geometric center; a red-pixel mean instead
    // moves when the UI overlay appears, even if the circle never moves.
    let bounds = XCTAttachment(string: "redPixels=\(count) bounds=[\(minX),\(minY),\(maxX),\(maxY)]")
    bounds.name = "portal-marker-outer-bounds"; bounds.lifetime = .keepAlways; add(bounds)
    guard count > 10 else { return .zero }
    return CGPoint(x: Double(minX + maxX + 1) / 2, y: Double(minY + maxY + 1) / 2)
  }
}
