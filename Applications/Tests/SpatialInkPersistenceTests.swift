import NotebookCore
import XCTest
@testable import Notebook

final class SpatialInkPersistenceTests: XCTestCase {
  private func span(_ surface: SurfaceID, x: Double = 10) -> SpatialInkSpan {
    .init(surface: surface, samples: [.init(point: .init(x: x, y: 10),
      worldPoint: surface.kind == .board ? .init(x: x, y: 10) : nil,
      timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
  }

  @MainActor
  func testCreationAppendUndoCaptureFenceAndNextAppendKeepEveryAcceptedUUID() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), queue = NotebookPersistenceQueue(store: store)
    let board = SurfaceID.board(WorkspaceRoot.boardID)
    let first = SpatialInkAction(tool: .pen, spans: [span(board)], stamp: .init(counter: 1, actor: actor))
    let second = SpatialInkAction(tool: .eraser, spans: [span(board, x: 20)], stamp: .init(counter: 3, actor: actor))
    queue.enqueue {
      _ = try $0.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      return false
    }
    queue.enqueue(owner: .spatialInk(first.id)) { try $0.commitSpatialInk(.append(first, journalStamp: first.stamp)); return false }
    queue.enqueue(owner: .spatialInk(first.id)) {
      try $0.commitSpatialInk(.state(actionID: first.id, creationStamp: first.stamp, isActive: false,
        stateStamp: .init(counter: 2, actor: actor), journalStamp: .init(counter: 2, actor: actor)))
      return false
    }
    let reached = expectation(description: "The synchronous capture fence sees exactly the lifted and undone first contact")
    queue.enqueueCommand({ try $0.readSpatialInk(surfaces: [board]) }) { result in
      do {
        let value = try result.get()
        XCTAssertEqual(value.actions.map(\.id), [first.id])
        XCTAssertFalse(value.actions.first?.isActive ?? true)
        XCTAssertEqual(value.actions.first?.spans, first.spans)
      } catch { XCTFail("\(error)") }
      reached.fulfill()
    }
    queue.enqueue(owner: .spatialInk(second.id)) { try $0.commitSpatialInk(.append(second, journalStamp: second.stamp)); return false }
    XCTAssertEqual(queue.pendingCount, 5, "Delta writes are not replaceable complete-journal snapshots")
    let saved = await queue.flush()
    XCTAssertTrue(saved, queue.failure ?? "")
    await fulfillment(of: [reached], timeout: 2)
    let journal = try store.readSpatialInk(surfaces: [board])
    XCTAssertEqual(journal.actions.map(\.id), [first.id, second.id])
    XCTAssertEqual(journal.actions.map(\.isActive), [false, true])
  }

  @MainActor
  func testNativeFirstCoverInkAndUndoAreRetainedWhileCreationAndSQLiteArePending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    model.updatePresence(.init(boardID: boardID, mode: .board, camera: .init(scale: 1), viewport: .init(x: 512, y: 512)), settled: true)
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    let blocker = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? blocker.release() }
    let cover = try XCTUnwrap(model.createNotebook(at: .init(x: 1_000, y: 0)))
    let first = try XCTUnwrap(model.appendSpatialInk(tool: .pen, color: .black,
      spans: [span(.board(boardID)), span(.cover(cover))]))
    model.undoLastSurfaceAction()
    let second = try XCTUnwrap(model.appendSpatialInk(tool: .pen, color: .black, spans: [span(.board(boardID), x: 30)]))
    XCTAssertEqual(model.spatialInk?.actions.map(\.id), [first.id, second.id])
    XCTAssertEqual(model.spatialInk?.actions.map(\.isActive), [false, true])
    try blocker.release()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertNotNil(try model.store.readWorkspaceItem(cover))
    let journal = try model.store.readSpatialInk(surfaces: [.board(boardID), .cover(cover)])
    XCTAssertEqual(journal.actions.map(\.id), [first.id, second.id])
    XCTAssertEqual(journal.actions.map(\.isActive), [false, true])
    XCTAssertEqual(journal.actions[0].spans, first.spans)
  }
}
