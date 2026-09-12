import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookBoardRevisionTests: XCTestCase {
  func testLowerClockPlacementChangesTheAcceptedFullRevisionAtTheSameBoardStamp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let workspace = try XCTUnwrap(model.workspace)
    let boardID = workspace.rootBoardID, itemID = try XCTUnwrap(workspace.selectedItemID)
    let initial = try model.store.loadBoard(items: workspace.items)
    var concurrent = initial, high = initial
    let destination = WorldPoint(x: 120, y: 140)
    XCTAssertTrue(concurrent.moveItem(itemID, in: boardID, to: destination, actor: UUID()))
    for index in 0..<3 {
      let element = SpatialElement(id: "outside-window-\(index)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 100, height: 40), worldOrigin: .init(x: 100_000, y: 100_000),
        source: "Unrelated edit \(index)", stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(high.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    }
    _ = try model.store.saveBoardEdits(before: initial, after: high)
    await model.reloadExternalChanges()?.value
    let before = try XCTUnwrap(model.boardContentRevisions[boardID])
    let stamp = try XCTUnwrap(model.boardHierarchy?.board(boardID)?.stamp)
    let camera = model.presence?.camera
    XCTAssertEqual(before, try model.store.boardContentRevision(boardID))
    XCTAssertTrue(try XCTUnwrap(model.boardHierarchy?.board(boardID)).elements.isEmpty,
      "The accepted scene stays bounded; its complete edit precondition does not hash only visible elements")
    XCTAssertGreaterThan(stamp.counter, try XCTUnwrap(concurrent.board(boardID)?.stamp.counter))

    _ = try model.store.saveMergedBoard(concurrent, items: workspace.items)
    let after = try XCTUnwrap(model.store.boardContentRevision(boardID))
    XCTAssertEqual(try model.store.readBoardNode(boardID)?.board.stamp, stamp)
    XCTAssertNotEqual(after, before)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.boardContentRevisions[boardID], after,
      "Delivery must observe the complete new SQL cut even when the largest causal clock did not advance")
    XCTAssertEqual(model.boardHierarchy?.board(boardID)?.placement(of: itemID)?.center, destination)
    XCTAssertEqual(model.presence?.camera, camera)
  }

  func testOptimisticLocalPlacementCannotReuseThePreviousCompleteRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let workspace = try XCTUnwrap(model.workspace)
    let boardID = workspace.rootBoardID, itemID = try XCTUnwrap(workspace.selectedItemID)
    let before = try XCTUnwrap(model.boardContentRevisions[boardID])
    let destination = WorldPoint(x: 300, y: 400)
    model.moveItem(itemID, to: destination)
    XCTAssertEqual(model.boardHierarchy?.board(boardID)?.placement(of: itemID)?.center, destination)
    XCTAssertNil(model.boardContentRevisions[boardID],
      "An optimistic placement must not present an old full-content token as its accepted revision")
    let committed = await model.finishPendingPersistence(); XCTAssertTrue(committed)
    await model.reloadExternalChanges()?.value
    let after = try XCTUnwrap(model.boardContentRevisions[boardID])
    XCTAssertNotEqual(after, before)
    XCTAssertEqual(after, try model.store.boardContentRevision(boardID))
    XCTAssertEqual(model.boardHierarchy?.board(boardID)?.placement(of: itemID)?.center, destination)
  }
}
