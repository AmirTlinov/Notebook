import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Panel replay uses the saved command identity and original result")
struct NotebookPanelReplayTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-replay-" + UUID().uuidString)
    let actor = UUID()
    let store: NotebookStore
    let workspaceID: UUID
    let target: CollaborationTarget

    init() throws {
      store = NotebookStore(root: root)
      let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      workspaceID = try store.storedWorkspaceID()
      target = .init(kind: .page, id: workspace.selectedPageID!)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
    func request(pointCount: Int) -> NotebookPanelEditRequest {
      let points: [JSONValue] = (0..<pointCount).map { index in
        .object(["x": .number(100 + Double(index) / 1024), "y": .number(200 + sin(Double(index))),
          "width": .number(3.123456789012345), "opacity": .number(0.834567890123456),
          "timeOffset": .number(Double(index) / 120), "force": .number(0.123456789012345),
          "azimuth": .number(0.987654321098765), "altitude": .number(1.123456789012345)])
      }
      let operation = CollaborationOperation(kind: .appendInkStroke, target: target,
        id: UUID().uuidString, values: ["points": .array(points)])
      return .init(workspaceID: workspaceID, actionID: UUID(), target: target,
        summary: "Exact authored contact", operations: [operation], sources: [])
    }
    func receiptAddress(_ id: UUID) -> String { "collaboration/actions/" + id.uuidString.lowercased() + ".json#" }
    func records(_ store: NotebookStore) throws -> [[String]] {
      try store.sqlRead { try $0.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] } }
    }
    func receiptBytes(_ store: NotebookStore, id: UUID) throws -> Data {
      try store.sqlRead { database in
        let row = try #require(database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?",
          [.text(receiptAddress(id))]).first)
        return try #require(row[0].blob)
      }
    }
  }

  private final class Probe {
    let address: String
    var receiptBodyReads = 0
    var modelBodyCopies = 0
    init(address: String) { self.address = address }
  }

  private func probe<T>(_ store: NotebookStore, actionID: UUID,
    allowance: NotebookSQLReadAllowance = .nativeCommand,
    _ operation: (NotebookSQLConnection) throws -> T) throws -> T {
    let address = "collaboration/actions/" + actionID.uuidString.lowercased() + ".json#"
    let trace = Probe(address: address)
    return try store.commandTransaction(readAllowance: allowance) {
      let database = try #require(store.currentSQL)
      let changes = sqlite3_total_changes64(database.handle)
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
        let trace = Unmanaged<Probe>.fromOpaque(raw!).takeUnretainedValue(), statement = OpaquePointer(pointer!)
        guard let sql = sqlite3_sql(statement) else { return 0 }
        let query = String(cString: sql)
        let hasBody = (0..<sqlite3_column_count(statement)).contains { sqlite3_column_type(statement, $0) == SQLITE_BLOB }
        guard hasBody else { return 0 }
        if query.hasPrefix("SELECT value FROM action_read_models") { trace.modelBodyCopies += 1 }
        if query.contains("blobs"), let expanded = sqlite3_expanded_sql(statement) {
          defer { sqlite3_free(expanded) }
          let bound = String(cString: expanded)
          if bound.contains(trace.address) || bound.contains(String(trace.address.dropLast())) {
            trace.receiptBodyReads += 1
          }
        }
        return 0
      }, Unmanaged.passUnretained(trace).toOpaque())
      defer {
        _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) }
        #expect(trace.receiptBodyReads == 0, "Replay must not copy the raw authored receipt")
        #expect(trace.modelBodyCopies <= 1)
        #expect(sqlite3_total_changes64(database.handle) == changes, "Replay/refusal must not mutate logical or bookkeeping rows")
      }
      return try operation(database)
    }
  }

  @Test func aFullMeasuredContactReplaysAfterReopenWithoutReadingOrRewritingItsReceipt() throws {
    let f = try Fixture(); defer { f.clean() }
    let request = f.request(pointCount: 65_536)
    #expect(try JSONEncoder().encode(request).count > 8 * 1_024 * 1_024)
    let original = try f.store.editPanel(request, actor: f.actor)
    let bytes = try f.receiptBytes(f.store, id: request.actionID), records = try f.records(f.store)
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let cold = NotebookStore(root: f.root)
    let replayed = try probe(cold, actionID: request.actionID) { _ in try cold.editPanel(request, actor: f.actor) }
    #expect(replayed == original)
    #expect(try f.records(cold) == records && f.receiptBytes(cold, id: request.actionID) == bytes)
    #expect(try cold.currentChangeCursor() == cursor && cold.currentReadCursor() == readCursor)
    let altered = NotebookPanelEditRequest(workspaceID: request.workspaceID, actionID: request.actionID,
      target: request.target, summary: request.summary + " changed", operations: request.operations, sources: request.sources)
    for (candidate, actor) in [(altered, f.actor), (request, UUID())] {
      do {
        _ = try probe(cold, actionID: request.actionID) { _ in try cold.editPanel(candidate, actor: actor) }
        Issue.record("A changed raw payload or actor cannot reuse the original command ID")
      } catch let error as CollaborationError { #expect(error.code == "action_id_conflict") }
    }
    #expect(try f.records(cold) == records && f.receiptBytes(cold, id: request.actionID) == bytes)
    #expect(try cold.nativeHistory(domain: .init(f.target), actor: f.actor) == [.command(request.actionID)])
  }

  @Test func replayAfterAnOrdinaryUndoReturnsTheOriginalResultAndKeepsTheUndoneReceipt() throws {
    let f = try Fixture(); defer { f.clean() }
    let request = f.request(pointCount: 2), original = try f.store.editPanel(request, actor: f.actor)
    _ = try f.store.undoPanel(.init(workspaceID: f.workspaceID, target: f.target, actionID: request.actionID), actor: f.actor)
    let bytes = try f.receiptBytes(f.store, id: request.actionID), records = try f.records(f.store)
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let cold = NotebookStore(root: f.root)
    let replayed = try probe(cold, actionID: request.actionID) { _ in try cold.editPanel(request, actor: f.actor) }
    #expect(replayed == original)
    #expect(try f.records(cold) == records && f.receiptBytes(cold, id: request.actionID) == bytes)
    #expect(try cold.currentChangeCursor() == cursor && cold.currentReadCursor() == readCursor)
    #expect(try cold.nativeHistory(domain: .init(f.target), actor: f.actor).isEmpty)
    let strokeID = try #require(request.operations.first?.id.flatMap(UUID.init(uuidString:)))
    #expect(try cold.readPageInkAction(pageID: f.target.id, actionID: strokeID)?.action.isActive == false)
  }

  @Test(arguments: ["missing", "stale", "wrongID", "oversized", "malformedJSON", "malformedHash"])
  func aMissingOrInvalidSavedModelRefusesInsteadOfReexecutingTheAcceptedID(_ kind: String) throws {
    let f = try Fixture(); defer { f.clean() }
    let request = f.request(pointCount: 2)
    _ = try f.store.editPanel(request, actor: f.actor)
    let address = f.receiptAddress(request.actionID)
    let model = try f.store.actionReadModel(request.actionID)
    try f.store.commandTransaction(advancesReadRevision: false) {
      let database = try #require(f.store.currentSQL)
      switch kind {
      case "missing": try database.run("DELETE FROM action_read_models WHERE address=?", [.text(address)])
      case "stale": try database.run("UPDATE action_read_models SET receipt_hash=? WHERE address=?",
        [.text(String(repeating: "0", count: 64)), .text(address)])
      case "wrongID":
        let body = try JSONValue.encode(model).setting("id", .string(UUID().uuidString))
        try database.run("UPDATE action_read_models SET value=? WHERE address=?",
          [.blob(NotebookStore.storageEncoder.encode(body)), .text(address)])
      case "oversized": try database.run("UPDATE action_read_models SET value=zeroblob(8388609) WHERE address=?", [.text(address)])
      case "malformedJSON": try database.run("UPDATE action_read_models SET value=? WHERE address=?", [.blob(Data("{".utf8)), .text(address)])
      default: try database.run("UPDATE action_read_models SET receipt_hash=? WHERE address=?",
        [.text(String(repeating: "x", count: 1_000_000)), .text(address)])
      }
    }
    let records = try f.records(f.store), bytes = try f.receiptBytes(f.store, id: request.actionID)
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let cold = NotebookStore(root: f.root)
    do {
      _ = try probe(cold, actionID: request.actionID) { _ in try cold.editPanel(request, actor: f.actor) }
      Issue.record("An unreadable/stale identity must not fall through to a new action")
    } catch let error as NotebookStorageError {
      let expected: NotebookStorageError = kind == "oversized" ? .limitExceeded("action_read_model")
        : .corruptRecord("action read model: " + address)
      #expect(error == expected)
    }
    #expect(try f.records(cold) == records && f.receiptBytes(cold, id: request.actionID) == bytes)
    #expect(try cold.currentChangeCursor() == cursor && cold.currentReadCursor() == readCursor)
  }

  @Test func aNestedReplayIdentityReadCannotRenewTheCallersExhaustedJSONCredit() throws {
    let f = try Fixture(); defer { f.clean() }
    let request = f.request(pointCount: 2)
    _ = try f.store.editPanel(request, actor: f.actor)
    let cursor = try f.store.currentChangeCursor(), records = try f.records(f.store)
    let allowance = NotebookSQLReadAllowance(rows: 4_096, bytes: 2_000_000, valueBytes: 1_000_000,
      reason: "panel_replay_json", jsonDecodeBytes: 0)
    let cold = NotebookStore(root: f.root)
    #expect(throws: NotebookStorageError.limitExceeded("json_decode_memory")) {
      _ = try probe(cold, actionID: request.actionID, allowance: allowance) { _ in
        try cold.actionReadModelIfPresent(request.actionID)
      }
    }
    #expect(try f.store.currentChangeCursor() == cursor && f.records(f.store) == records)
  }
}
