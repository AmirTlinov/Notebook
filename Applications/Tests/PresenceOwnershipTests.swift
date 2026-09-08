import NotebookCore
import XCTest
@testable import Notebook

final class PresenceOwnershipTests: XCTestCase {
  @MainActor
  func testPortalExitAndReentryKeepTheExactChildCamera() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    let viewport = SpatialPoint(x: 1_366, y: 1_024)
    model.start(pageSize: PageSize(width: viewport.x, height: viewport.y))
    let boardID = try XCTUnwrap(model.createBoard(at: .zero))
    model.enterBoard(boardID)
    let inspected = SessionPresence(
      boardID: boardID,
      mode: .board,
      camera: SpatialCamera(
        center: WorldPoint(x: 370, y: -240),
        scale: 0.51
      ),
      viewport: viewport
    )
    model.updatePresence(inspected, settled: true)

    XCTAssertTrue(model.leaveBoard())
    XCTAssertEqual(model.presence?.mode, .cover)
    XCTAssertEqual(model.presence?.focusedItemID, boardID)
    XCTAssertEqual(
      try XCTUnwrap(model.presence?.camera.scale),
      BoardPortalProjection.fillScale(viewport: viewport),
      accuracy: 0.000_001
    )

    model.enterBoard(boardID)

    XCTAssertEqual(model.presence?.boardID, boardID)
    XCTAssertEqual(model.presence?.mode, .board)
    XCTAssertEqual(model.presence?.camera.center, inspected.camera.center)
    XCTAssertEqual(
      try XCTUnwrap(model.presence?.camera.scale),
      inspected.camera.scale,
      accuracy: 0.000_001
    )
    await model.finishPendingPersistence()
    let persisted = try store.loadBoard(
      items: try store.loadIndex().items
    )
    XCTAssertEqual(
      persisted.portalCamera(boardID),
      BoardPortalProjection.portalCamera(
        from: inspected.camera,
        viewport: viewport
      )
    )
  }

  @MainActor
  func testActiveCameraFrameDoesNotReplaceTheDurableContext() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let stable = try store.loadPresence()
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let active = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(center: stable.camera.center, scale: 0.84),
      viewport: stable.viewport,
      focusedItemID: itemID,
      openProgress: 0.5
    )

    model.updatePresence(active, settled: false)

    XCTAssertEqual(model.presence, active)
    XCTAssertEqual(model.presencePhase, .active)
    await model.finishPendingPersistence()
    XCTAssertEqual(try store.loadPresence(), stable)
  }

  @MainActor
  func testSettledPageCannotPersistAtATransitionalScale() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let center = try XCTUnwrap(model.board?.placement(of: itemID)?.center)
    let broken = SessionPresence(
      mode: .page,
      camera: SpatialCamera(center: center, scale: 0.487_891_719_906_063),
      viewport: SpatialPoint(x: 834, y: 1_194),
      focusedItemID: itemID,
      openProgress: 1
    )

    model.updatePresence(broken, settled: true)

    XCTAssertEqual(model.presence?.camera.scale, 1)
    XCTAssertEqual(model.presence?.camera.center, center)
    await model.finishPendingPersistence()
    XCTAssertEqual(try store.loadPresence().camera.scale, 1)
  }

  @MainActor
  func testSettledBoardKeepsTheScaleChosenForInspection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let viewport = SpatialPoint(x: 834, y: 1_194)
    let inspected = SessionPresence(
      mode: .board,
      camera: SpatialCamera(center: WorldPoint(x: 90, y: -40), scale: 0.68),
      viewport: viewport
    )

    model.updatePresence(inspected, settled: true)

    XCTAssertEqual(model.presence, inspected)
    await model.finishPendingPersistence()
    XCTAssertEqual(try store.loadPresence(), inspected)
  }

  @MainActor
  func testSettledPartialCoverKeepsTheExactCamera() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let partial = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(
        center: WorldPoint(x: 37, y: -22),
        scale: 0.86
      ),
      viewport: SpatialPoint(x: 834, y: 1_194),
      focusedItemID: itemID,
      openProgress: 0.55
    )

    model.updatePresence(partial, settled: true)

    XCTAssertEqual(model.presence, partial)
    await model.finishPendingPersistence()
    XCTAssertEqual(try store.loadPresence(), partial)
  }

  @MainActor
  func testSettledStackedPageCentersTheSelectedNotebook() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let actor = UUID()
    let lowerID = UUID()
    let lowerPageID = UUID()
    let upperID = UUID()
    let upperPageID = UUID()
    let size = PageSize(width: 834, height: 1_194)
    var initial = WorkspaceIndex.initial(
      actor: actor,
      pageSize: size,
      itemID: lowerID,
      pageID: lowerPageID
    )
    let upper = try XCTUnwrap(initial.index.createNotebook(
      title: "Upper",
      actor: actor,
      pageSize: size,
      itemID: upperID,
      pageID: upperPageID
    ))
    var board = BoardDocument.initial(
      itemIDs: [lowerID, upperID],
      actor: actor
    )
    XCTAssertNotNil(board.createStack(
      moving: upperID,
      onto: lowerID,
      actor: actor
    ))
    let stackCenter = try XCTUnwrap(board.stack(containing: upperID)?.center)
    let expectedCenter = try XCTUnwrap(board.focusedCenter(of: upperID))
    try store.savePage(initial.page)
    try store.savePage(upper.page)
    try store.saveBoard(
      BoardHierarchy(
        rootBoardID: initial.index.rootBoardID,
        boards: [
          BoardNode(id: initial.index.rootBoardID, board: board)
        ],
        stamp: board.stamp
      ),
      items: initial.index.items
    )
    try store.saveWorkspaceBundle(index: initial.index, page: initial.page,
      board: store.loadBoard(items: initial.index.items))
    try store.savePresence(
      SessionPresence(
        boardID: initial.index.rootBoardID,
        mode: .page,
        camera: SpatialCamera(center: stackCenter, scale: 1),
        viewport: SpatialPoint(x: size.width, y: size.height),
        focusedItemID: upperID,
        openProgress: 1
      )
    )

    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: size)

    XCTAssertEqual(model.presence?.camera.center, expectedCenter)
    XCTAssertNotEqual(expectedCenter, stackCenter)
  }

  @MainActor
  func testExternalCatalogAndBoardChangeKeepTheHumanCamera() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    let size = PageSize(width: 834, height: 1_194)
    model.start(pageSize: size)
    let originalPresence = try XCTUnwrap(model.presence)
    let originalItemID = try XCTUnwrap(model.workspace?.selectedItemID)
    var workspace = try XCTUnwrap(model.workspace)
    var board = try XCTUnwrap(model.boardHierarchy)
    let created = try XCTUnwrap(workspace.createNotebook(
      title: "Новая",
      actor: UUID(),
      pageSize: size
    ))
    let expectedCenter = WorldPoint(x: 2_400, y: -1_200)
    XCTAssertTrue(board.addItem(
      created.item.id,
      to: workspace.rootBoardID,
      near: expectedCenter,
      actor: UUID()
    ))
    try store.saveWorkspaceBundle(
      index: workspace,
      page: created.page,
      board: board
    )

    await model.reloadExternalChanges()?.value

    XCTAssertEqual(model.workspace?.selectedItemID, originalItemID)
    XCTAssertEqual(model.presence,originalPresence)
    XCTAssertEqual(model.board?.placement(of:created.item.id)?.center,expectedCenter)
    XCTAssertNotNil(model.pages[created.page.id])
  }

  @MainActor
  func testItemSelectionChangesMemoryBeforeItsDurableWrite() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    let size = PageSize(width: 834, height: 1_194)
    model.start(pageSize: size)
    let originalID = try XCTUnwrap(model.workspace?.selectedItemID)
    let createdID = try XCTUnwrap(
      model.createNotebook(at: WorldPoint(x: 1_200, y: 0))
    )
    let creationSaved = await model.finishPendingPersistence()
    XCTAssertTrue(creationSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(try store.loadIndex().selectedItemID, createdID)

    model.selectItem(originalID)

    XCTAssertEqual(model.workspace?.selectedItemID, originalID)
    for _ in 0..<100 {
      if try store.loadIndex().selectedItemID == originalID { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The deferred selection was not written")
  }
}
