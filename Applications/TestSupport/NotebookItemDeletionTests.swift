@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookItemDeletionTests: XCTestCase {
  private enum Failure: Error { case disk }

  func testDeleteAfterPendingMoveCanUndoImmediatelyAndRepeatAfterReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try await makeModel(root: root)
    let id = try XCTUnwrap(model.workspace?.selectedItemID), board = try XCTUnwrap(model.presence?.boardID)
    let initial = try XCTUnwrap(model.board?.placement(of: id)?.center)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let move = try XCTUnwrap(model.moveItem(id, to: .init(x: 730, y: 40)))
    let deletion = Task { await model.deleteItem(id) }
    try await waitForDeletionAdmission(model, id: id)
    model.undoLastSurfaceAction()
    try lock.release()
    let deleted = await deletion.value; XCTAssertTrue(deleted)
    await save(model)
    XCTAssertNotNil(model.workspace?.item(id: id))
    XCTAssertEqual(model.board?.placement(of: id)?.center, WorldPoint(x: 730, y: 40))
    XCTAssertEqual(try model.store.nativeHistory(domain: .board(board), actor: model.actorID), [.command(move.id)])
    model.undoLastSurfaceAction(); await save(model)
    XCTAssertEqual(model.board?.placement(of: id)?.center, initial)
    let closed = await model.shutdown(); XCTAssertTrue(closed)

    let cold = try await makeModel(root: root, createNeighbor: false)
    cold.redoLastSurfaceAction(); await save(cold)
    cold.redoLastSurfaceAction(); await save(cold)
    XCTAssertNil(cold.workspace?.item(id: id))
    cold.undoLastSurfaceAction(); await save(cold)
    XCTAssertNotNil(cold.workspace?.item(id: id))
    XCTAssertEqual(cold.board?.placement(of: id)?.center, WorldPoint(x: 730, y: 40))
  }

  func testStorageFailureRetainsDeletionAndItsQueuedUndoWithoutRepeatingDestruction() async throws {
    for committed in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let blocked = root.appendingPathComponent("block-deletion")
      let store = NotebookStore(root: root) { point in
        if point == (committed ? .afterCommit : .beforeCommit), FileManager.default.fileExists(atPath: blocked.path) {
          throw Failure.disk
        }
      }
      let model = try await makeModel(root: root, store: store)
      let id = try XCTUnwrap(model.workspace?.selectedItemID), board = try XCTUnwrap(model.presence?.boardID)
      try Data().write(to: blocked)
      defer { try? FileManager.default.removeItem(at: blocked); model.retryPendingPersistence() }
      let deletion = Task { await model.deleteItem(id) }
      try await waitForDeletionAdmission(model, id: id)
      let failed = await model.finishPendingPersistence()
      XCTAssertFalse(failed); XCTAssertNotNil(model.persistenceFailure)
      XCTAssertTrue(model.isItemBeingDeleted(id), "A storage failure retains the accepted deletion")
      model.undoLastSurfaceAction()
      try FileManager.default.removeItem(at: blocked); model.retryPendingPersistence()
      let deleted = await deletion.value; XCTAssertTrue(deleted)
      await save(model)
      XCTAssertNotNil(model.workspace?.item(id: id))
      XCTAssertFalse(model.isItemBeingDeleted(id))
      XCTAssertTrue(try store.nativeHistory(domain: .board(board), actor: model.actorID).isEmpty)
      XCTAssertEqual(try store.nativeRedoHistory(domain: .board(board), actor: model.actorID).count, 1)
      model.redoLastSurfaceAction(); await save(model)
      XCTAssertNil(model.workspace?.item(id: id))
      XCTAssertEqual(try store.nativeHistory(domain: .board(board), actor: model.actorID).count, 1)
    }
  }

  func testStaleVisiblePlacementRejectsDeletionAndDoesNotBlockTheNextItem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = try await makeModel(root: root)
    let id = try XCTUnwrap(model.workspace?.selectedItemID), board = try XCTUnwrap(model.presence?.boardID)
    let source = try XCTUnwrap(model.itemMoveSource(id, boardID: board))
    _ = try NotebookNativeCommand([.init(kind: .moveItem, target: .init(kind: .board, id: board),
      id: id.uuidString, values: ["center": .encode(WorldPoint(x: -320, y: 0))])], summary: "Peer move",
      placements: Array(source.placements.values), actor: UUID()).apply(to: model.store)
    let deleted = await model.deleteItem(id)
    XCTAssertFalse(deleted); await save(model)
    XCTAssertNotNil(model.workspace?.item(id: id))
    XCTAssertTrue(try model.store.nativeHistory(domain: .board(board), actor: model.actorID).isEmpty)
    XCTAssertFalse(model.isItemBeingDeleted(id))
    XCTAssertNotNil(model.moveItem(id, to: .init(x: 450, y: 0)))
    await save(model)
    XCTAssertEqual(model.board?.placement(of: id)?.center, WorldPoint(x: 450, y: 0))
  }

  private func makeModel(root: URL, store: NotebookStore? = nil, createNeighbor: Bool = true) async throws -> NotebookAppModel {
    let model = NotebookAppModel(store: store ?? .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    model.updatePresence(.init(boardID: board, mode: .board, camera: .init(), viewport: .init(x: 1194, y: 834)), settled: true)
    if createNeighbor { XCTAssertNotNil(model.createNotebook(at: .init(x: 1500, y: 0))) }
    await save(model)
    return model
  }
  private func waitForDeletionAdmission(_ model: NotebookAppModel, id: UUID) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(2))
    while !model.isItemBeingDeleted(id), .now < until { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(model.isItemBeingDeleted(id))
  }
  private func save(_ model: NotebookAppModel) async {
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved, model.persistenceFailure ?? "Save failed")
    await model.reloadExternalChanges()?.value
  }
}
