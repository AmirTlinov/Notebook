import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Scene source admission ignores only proven delivery receipts")
struct NotebookSceneSourceTests {
  private struct Fixture {
    let store: NotebookStore
    let actor = UUID()
    let board: UUID
    let action: CollaborationReceipt
    let bounds = WorkspaceSpatialBounds(origin: .init(x: -1_000, y: -1_000), width: 2_000, height: 2_000)
    init() throws {
      store = .init(root: FileManager.default.temporaryDirectory.appendingPathComponent("scene-source-\(UUID())"))
      board = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)).rootBoardID
      let target = CollaborationTarget(kind: .board, id: board)
      action = try store.applyCollaborationAction(.init(summary: "Paint sources", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: try ["a", "b"].map {
          .init(kind: .insertElement, target: target, id: $0, values: ["kind": .string("graphic"),
            "source": .string(""), "worldOrigin": try .encode(WorldPoint.zero),
            "frame": try .encode(PageRect(x: 20, y: 20, width: 40, height: 40)),
            "graphic": try .encode(NotebookGraphic(shape: .rectangle))])
        }), actor: actor)
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
  }

  @Test func arrivalAndShownReceiptsPreservePaintPaginationButMaterialAndBoundsDoNot() throws {
    let f = try Fixture(); defer { f.clean() }
    let expected = try f.store.readScenePaintOrder(boardID: f.board, bounds: f.bounds).entries
    let first = try f.store.readScenePaintOrder(boardID: f.board, bounds: f.bounds, limit: 1)
    let cursor = try #require(first.next)
    try f.store.acknowledgeReceivedActions(deviceID: UUID())
    let arrived = try f.store.currentChangeCursor()
    #expect(arrived > first.revision)
    #expect(try f.store.sceneSourceIsUnchanged(from: first.revision, through: arrived))
    var receipt = try #require(try f.store.deviceActionReceipts(actionIDs: [f.action.id]).first)
    // Synthetic receipt mutation tests source admission, not physical display.
    receipt.shown = receipt.revisions
    _ = try f.store.saveDeviceActionReceipt(receipt)
    let shown = try f.store.currentChangeCursor()
    #expect(shown > arrived)
    let rest = try f.store.readScenePaintOrder(boardID: f.board, bounds: f.bounds, after: cursor)
    #expect(first.entries + rest.entries == expected)
    #expect(try f.store.sceneSourceIsUnchanged(from: first.revision, through: shown))
    #expect(throws: NotebookStorageError.transactionConflict) {
      try f.store.readScenePaintOrder(boardID: f.board,
        bounds: .init(origin: .zero, width: 10, height: 10), after: cursor)
    }
    let workspace = try f.store.loadIndex(), before = try f.store.loadBoard(items: workspace.items)
    var moved = before
    let didMove = moved.moveItem(workspace.selectedItemID, in: f.board, to: .init(x: 800, y: 0), actor: f.actor)
    #expect(didMove)
    _ = try f.store.saveBoardEdits(before: before, after: moved)
    receipt.displayComplete = true
    _ = try f.store.saveDeviceActionReceipt(receipt)
    let edited = try f.store.currentChangeCursor()
    #expect(try !f.store.sceneSourceIsUnchanged(from: first.revision, through: edited),
      "The latest harmless receipt cannot hide an earlier material edit in the interval")
    #expect(throws: NotebookStorageError.transactionConflict) {
      try f.store.readScenePaintOrder(boardID: f.board, bounds: f.bounds, after: cursor)
    }
    #expect(try !f.store.sceneSourceIsUnchanged(from: edited + 1, through: edited))
    #expect(try !f.store.sceneSourceIsUnchanged(from: edited + 1, through: edited + 1))
  }

  @Test func aHundredThousandJournalRowsCannotExpandSourceAdmission() throws {
    let f = try Fixture(); defer { f.clean() }
    let before = try f.store.currentChangeCursor()
    // Seed the exact addressed index queried by this proof, not 100000 UI
    // objects. Old tombstones must not turn a recent receipt into a history scan.
    try f.store.commandTransaction(advancesReadRevision: false) {
      try f.store.currentSQL!.run("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
        INSERT INTO change_records(sequence,address,blob_hash)
        SELECT 1,'collaboration/delivery/old-'||x||'.json#',NULL FROM n
        """)
    }
    try f.store.acknowledgeReceivedActions(deviceID: UUID())
    let after = try f.store.currentChangeCursor()
    func measured() throws -> (Bool, Int64) {
      try f.store.readTransaction { store in
        let database = store.currentSQL!
        func steps(reset: Int32) -> Int64 {
          var count: Int64 = 0, statement = sqlite3_next_stmt(database.handle, nil)
          while let value = statement {
            count += Int64(sqlite3_stmt_status(value, SQLITE_STMTSTATUS_VM_STEP, reset))
            statement = sqlite3_next_stmt(database.handle, value)
          }
          return count
        }
        _ = steps(reset: 1)
        let unchanged = try store.sceneSourceIsUnchanged(from: before, through: after)
        return (unchanged, steps(reset: 0))
      }
    }
    let recent = try measured()
    #expect(recent.0)
    #expect(recent.1 < 2_000)
    try f.store.commandTransaction(advancesReadRevision: false) {
      try f.store.currentSQL!.run("""
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
        INSERT INTO change_records(sequence,address,blob_hash)
        SELECT ?,'collaboration/delivery/new-'||x||'.json#',NULL FROM n
        """, [.integer(Int64(after))])
    }
    let oversized = try measured()
    #expect(!oversized.0, "Unknown remainder requires a fresh source, even if the first receipts are harmless")
    #expect(oversized.1 < 2_000, "LIMIT must bound SQL work, not merely the Swift result")
    print("Scene receipt proof: 100000 old rows=\(recent.1) steps; 100000 intervening rows=\(oversized.1) steps")
  }
}
