@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookItemPlacementTests: XCTestCase {
  private enum Failure: Error { case unavailable }

  func testDropChainsUseOneSavedSourceAndColdUndoRedoPerLift() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try await makeModel(root: root)
    let boardID = try XCTUnwrap(model.presence?.boardID), a = try XCTUnwrap(model.workspace?.selectedItemID)
    let b = try XCTUnwrap(model.createNotebook(at: .init(x: 1500, y: 0)))
    await save(model)
    let before = try XCTUnwrap(model.boardHierarchy?.board(boardID))
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let first = try XCTUnwrap(model.moveItem(a, to: .init(x: 300, y: 100)))
    let second = try XCTUnwrap(model.moveItem(a, to: .init(x: 1400, y: 0), onto: b))
    let stack = try XCTUnwrap(model.board?.stack(containing: a))
    XCTAssertEqual(stack.id, NotebookStore.submissionID(second.id, suffix: "stack:1"))
    XCTAssertEqual(model.boardHierarchy?.board(boardID), before,
      "A visible draft cannot manufacture canonical movement heads")
    XCTAssertNil(second.accepted)
    model.undoLastSurfaceAction() // Reserve the inverse before the writer is free.
    try lock.release()
    await save(model)
    XCTAssertEqual(try model.store.nativeHistory(domain: .board(boardID), actor: model.actorID), [.command(first.id)])
    XCTAssertEqual(model.board?.placement(of: a)?.center, WorldPoint(x: 300, y: 100))
    XCTAssertNil(model.board?.stack(containing: a))
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)

    let cold = try await makeModel(root: root)
    cold.redoLastSurfaceAction(); await save(cold)
    XCTAssertEqual(cold.board?.stack(containing: a)?.id, stack.id)
    cold.undoLastSurfaceAction(); await save(cold)
    cold.undoLastSurfaceAction(); await save(cold)
    XCTAssertEqual(cold.board?.placements.map(\.pose), before.placements.map(\.pose))
    cold.redoLastSurfaceAction(); await save(cold)
    cold.redoLastSurfaceAction(); await save(cold)
    XCTAssertEqual(cold.board?.stack(containing: a)?.itemIDs, stack.itemIDs)
    XCTAssertEqual(try cold.store.nativeHistory(domain: .board(boardID), actor: cold.actorID).count, 2,
      "Move plus stack is one action, not two independently undoable writes")
  }

  func testRejectedOldContactRetractsOnlyItsDraftAndDoesNotStopAnotherItem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try await makeModel(root: root)
    let boardID = try XCTUnwrap(model.presence?.boardID), a = try XCTUnwrap(model.workspace?.selectedItemID)
    let b = try XCTUnwrap(model.createNotebook(at: .init(x: 1500, y: 0)))
    await save(model)
    let contact = try XCTUnwrap(model.itemMoveSource(a, boardID: boardID))
    let peerCenter = WorldPoint(x: -400, y: 200)
    let peer = try NotebookNativeCommand([.init(kind: .moveItem, target: .init(kind: .board, id: boardID),
      id: a.uuidString, values: ["center": .encode(peerCenter)])], summary: "Другой автор",
      placements: Array(contact.placements.values), actor: UUID()).apply(to: model.store)
    let stale = try XCTUnwrap(model.moveItem(a, to: .init(x: 200, y: 100), source: contact))
    let next = try XCTUnwrap(model.moveItem(b, to: .init(x: 1800, y: 100)))
    await save(model)
    XCTAssertTrue(stale.rejected); XCTAssertNotNil(next.accepted)
    XCTAssertEqual(model.board?.placement(of: a)?.center, peerCenter)
    XCTAssertEqual(try model.store.readBoardItem(a)?.board.placements.first { $0.id == a }, peer.sources.first)
    XCTAssertEqual(model.board?.placement(of: b)?.center, WorldPoint(x: 1800, y: 100))
    XCTAssertEqual(try model.store.nativeHistory(domain: .board(boardID), actor: model.actorID), [.command(next.id)])
    XCTAssertTrue(model.itemPlacementCommands.isEmpty)
  }

  func testStorageFailureRetainsThePoseAndItsDependentDropWithoutDuplicateHistory() async throws {
    for committed in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let blocked = root.appendingPathComponent("block-placement")
      let store = NotebookStore(root: root) { point in
        let matches: Bool
        switch point {
        case .beforeCommit: matches = !committed
        case .afterCommit: matches = committed
        default: matches = false
        }
        if matches, FileManager.default.fileExists(atPath: blocked.path) { throw Failure.unavailable }
      }
      let model = try await makeModel(root: root, store: store)
      let id = try XCTUnwrap(model.workspace?.selectedItemID), boardID = try XCTUnwrap(model.presence?.boardID)
      try Data().write(to: blocked)
      defer { try? FileManager.default.removeItem(at: blocked); model.retryPendingPersistence() }
      let first = try XCTUnwrap(model.moveItem(id, to: .init(x: 200, y: 100)))
      var saved: Bool?
      let released = expectation(description: "Failed placement releases Save, not the accepted drop")
      let waiting = Task { saved = await model.finishPendingPersistence(); released.fulfill() }
      await fulfillment(of: [released], timeout: 2)
      XCTAssertEqual(saved, false); XCTAssertNotNil(model.persistenceFailure)
      XCTAssertNil(first.accepted); XCTAssertFalse(first.rejected)
      XCTAssertEqual(model.board?.placement(of: id)?.center, WorldPoint(x: 200, y: 100))
      let second = try XCTUnwrap(model.moveItem(id, to: .init(x: 450, y: 250)))
      XCTAssertEqual(model.board?.placement(of: id)?.center, WorldPoint(x: 450, y: 250))
      try FileManager.default.removeItem(at: blocked)
      model.retryPendingPersistence(); await waiting.value
      await save(model)
      XCTAssertEqual(model.board?.placement(of: id)?.center, WorldPoint(x: 450, y: 250))
      XCTAssertEqual(try store.nativeHistory(domain: .board(boardID), actor: model.actorID),
        [.command(first.id), .command(second.id)])
      XCTAssertNil(model.persistenceFailure); XCTAssertTrue(model.itemPlacementCommands.isEmpty)
      XCTAssertEqual(first.accepted?.placements[id]?.pose?.center, WorldPoint(x: 200, y: 100),
        "The retained predecessor remains its own committed source, not the dependent move")
    }
  }

  private func makeModel(root: URL, store: NotebookStore? = nil) async throws -> NotebookAppModel {
    let model = NotebookAppModel(store: store ?? .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    model.updatePresence(.init(boardID: boardID, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    await save(model)
    return model
  }

  private func save(_ model: NotebookAppModel) async {
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved, model.persistenceFailure ?? "Save failed")
    await model.reloadExternalChanges()?.value
  }
}
