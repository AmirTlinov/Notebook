import NotebookCore
import XCTest
@testable import Notebook

final class PresenceOwnershipTests: XCTestCase {
  @MainActor
  func testActiveCameraFrameDoesNotReplaceTheDurableContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let stable = try store.loadPresence()
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let active = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(center: stable.camera.center, scale: 0.84),
      viewport: stable.viewport,
      focusedNotebookID: notebookID,
      openProgress: 0.5
    )

    model.updatePresence(active, settled: false)

    XCTAssertEqual(model.presence, active)
    XCTAssertEqual(model.presencePhase, .active)
    XCTAssertEqual(try store.loadPresence(), stable)
  }

  @MainActor
  func testSettledPageCannotPersistAtATransitionalScale() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let center = try XCTUnwrap(model.board?.placement(of: notebookID)?.center)
    let broken = SessionPresence(
      mode: .page,
      camera: SpatialCamera(center: center, scale: 0.487_891_719_906_063),
      viewport: SpatialPoint(x: 834, y: 1_194),
      focusedNotebookID: notebookID,
      openProgress: 1
    )

    model.updatePresence(broken, settled: true)

    XCTAssertEqual(model.presence?.camera.scale, 1)
    XCTAssertEqual(model.presence?.camera.center, center)
    XCTAssertEqual(try store.loadPresence().camera.scale, 1)
  }

  @MainActor
  func testSettledBoardKeepsTheScaleChosenForInspection() throws {
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
    XCTAssertEqual(try store.loadPresence(), inspected)
  }

  @MainActor
  func testSettledPartialCoverKeepsTheExactCamera() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let partial = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(
        center: WorldPoint(x: 37, y: -22),
        scale: 0.86
      ),
      viewport: SpatialPoint(x: 834, y: 1_194),
      focusedNotebookID: notebookID,
      openProgress: 0.55
    )

    model.updatePresence(partial, settled: true)

    XCTAssertEqual(model.presence, partial)
    XCTAssertEqual(try store.loadPresence(), partial)
  }

  @MainActor
  func testSettledStackedPageCentersTheSelectedNotebook() throws {
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
      notebookID: lowerID,
      pageID: lowerPageID
    )
    let upper = try XCTUnwrap(initial.index.createNotebook(
      title: "Upper",
      actor: actor,
      pageSize: size,
      notebookID: upperID,
      pageID: upperPageID
    ))
    var board = BoardDocument.initial(
      notebookIDs: [lowerID, upperID],
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
    try store.saveBoard(board, notebookIDs: Set([lowerID, upperID]))
    try store.saveIndex(initial.index)
    try store.savePresence(
      SessionPresence(
        mode: .page,
        camera: SpatialCamera(center: stackCenter, scale: 1),
        viewport: SpatialPoint(x: size.width, y: size.height),
        focusedNotebookID: upperID,
        openProgress: 1
      )
    )

    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: size)

    XCTAssertEqual(model.presence?.camera.center, expectedCenter)
    XCTAssertNotEqual(expectedCenter, stackCenter)
  }
}
