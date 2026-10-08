import Foundation
import Testing
@testable import NotebookCore

@Suite("Current-fleet history preflight uses the existing readonly command cut")
struct NotebookActionHistoryPreflightTests {
  private func fixture(_ body: (NotebookStore, UUID, [NotebookDurableChange]) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-preflight-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), workspaceID = UUID()
    try store.prepareEmptyWorkspace(workspaceID: workspaceID)
    // No workspace/board/ink content roots exist. Metadata observations must
    // create and resolve their continuation without loading those domains.
    for index in 0..<3 {
      try store.publishRecords(writes: ["diagnostic-history-\(index).json":
        .object(["privateSource": .string("authored fixture sentinel \(index)")])])
    }
    try body(store, workspaceID, store.changeJournal(after: 0))
  }

  private func request(_ query: NotebookReadQuery) -> NotebookCommand {
    var command = NotebookCommand(command: .read)
    command.queries = [query]; command.readSnapshots = true
    return command
  }

  private func read(_ reader: NotebookReadSession, _ query: NotebookReadQuery) throws -> JSONValue {
    try reader.observe { cut in
      let result = try cut.handle(NotebookReadCommand(request(query)))
      return try #require(result.arrayValues.first)
    }
  }

  @Test func metadataDirectoryContinuesWithoutCurrentContentOrBlobDecoding() throws {
    try fixture { (store, workspaceID, changes) throws -> Void in
      let reader = NotebookReadSession(store: store), original = try store.currentReadCursor()
      var query = NotebookReadQuery(kind: .actionHistoryPreflight, limit: 2)
      var collected: [UUID] = [], snapshotIDs: [UUID] = []
      for _ in 0..<3 {
        let snapshot = try reader.observe { cut in
          let result = try cut.handle(NotebookReadCommand(request(query)))
          #expect(store.currentSQL?.decodedFragmentCount == 0)
          return try #require(result.arrayValues.first)
        }
        let data = try #require(snapshot["data"])
        #expect(data["mode"] == .string("inventory"))
        #expect(data["cut"]?["readCursor"] == .string(String(original)))
        #expect(snapshot["basis"]?["owners"] == .array([]))
        #expect(try snapshot["basis"]?["workspaceID"]?.decode(UUID.self) == workspaceID)
        snapshotIDs.append(try #require(data["cut"]?["snapshotID"]).decode(UUID.self))
        for value in try #require(data["transactions"]).arrayValues {
          collected.append(try #require(value["transactionID"]).decode(UUID.self))
          #expect(value["localJournal"]?["sequence"]?.stringValue != nil)
          #expect(value["manifestHash"]?.stringValue?.utf8.count == 64)
        }
        guard let next = snapshot["coverage"]?["next"]?.stringValue else {
          #expect(snapshot["coverage"]?["complete"] == .bool(true)); break
        }
        #expect(snapshot["coverage"]?["complete"] == .bool(false))
        query = .init(kind: .actionHistoryPreflight); query.next = next
      }
      #expect(collected == changes.map(\.transactionID).sorted { $0.uuidString < $1.uuidString })
      #expect(Set(snapshotIDs).count == snapshotIDs.count, "The continuation binds the durable cut, not an expired SQLite snapshot")
      #expect(try store.currentReadCursor() == original)
    }
  }

  @Test func newAcceptedJournalWriteInvalidatesTheDirectoryContinuation() throws {
    try fixture { (store, _, _) throws -> Void in
      let reader = NotebookReadSession(store: store)
      let first = try read(reader, .init(kind: .actionHistoryPreflight, limit: 1))
      var resumed = NotebookReadQuery(kind: .actionHistoryPreflight)
      resumed.next = try #require(first["coverage"]?["next"]?.stringValue)
      _ = try read(reader, resumed)
      try store.publishRecords(writes: ["later-history.json": .object(["known": .bool(true)])])
      do { _ = try read(reader, resumed); Issue.record("An old directory cut must be refused") }
      catch let error as CollaborationError { #expect(error.code == "read_cursor_stale") }
    }
  }

  @Test func exactAcceptedTransactionReportsMissingSelectedReceiptWithoutAuthorContent() throws {
    try fixture { (store, workspaceID, changes) throws -> Void in
      let reader = NotebookReadSession(store: store), change = try #require(changes.first), receiptID = UUID()
      var query = NotebookReadQuery(kind: .actionHistoryPreflight, id: change.transactionID, revision: change.manifestHash)
      query.referenceID = receiptID
      let snapshot = try read(reader, query), data = try #require(snapshot["data"])
      #expect(data["mode"] == .string("transaction"))
      #expect(try data["cut"]?["workspaceID"]?.decode(UUID.self) == workspaceID)
      #expect(data["manifestHash"] == .string(change.manifestHash))
      #expect(snapshot["basis"]?["owners"] == .array([]))
      #expect(snapshot["coverage"]?["complete"] == .bool(false))
      #expect(snapshot["coverage"]?["next"] == nil)
      let receipt = try #require(data["receipts"]?.arrayValues.first)
      #expect(try receipt["id"]?.decode(UUID.self) == receiptID)
      #expect(receipt["closure"] == .string("unprovenClosure"))
      #expect(receipt["reason"] == .string("originalRootAbsent"))
      let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
      #expect(!encoded.contains("authored fixture sentinel") && !encoded.contains("rawPayload"))
      #expect(try store.currentChangeCursor() == changes.last?.sequence)
    }
  }

  @Test func pointHashMismatchAndUnboundDirectorySeekRefuseBeforeReturningEvidence() throws {
    try fixture { (store, _, changes) throws -> Void in
      let reader = NotebookReadSession(store: store), change = try #require(changes.first)
      let cursor = try store.currentReadCursor()
      let wrong = NotebookReadQuery(kind: .actionHistoryPreflight, id: change.transactionID,
        revision: String(repeating: "0", count: 64))
      do { _ = try read(reader, wrong); Issue.record("Wrong accepted manifest must refuse") }
      catch let error as CollaborationError { #expect(error.code == "read_conflict") }
      var seek = NotebookReadQuery(kind: .actionHistoryPreflight); seek.after = change.transactionID
      do { _ = try read(reader, seek); Issue.record("A semantic seek needs its durable read cursor") }
      catch let error as CollaborationError { #expect(error.code == "read_cursor_stale") }
      #expect(try store.currentReadCursor() == cursor)
    }
  }

  @Test func preflightCannotRenewTheEnclosingReadAllowanceOrEnterTheWriter() throws {
    try fixture { (store, _, _) throws -> Void in
      let reader = NotebookReadSession(store: store), cursor = try store.currentReadCursor()
      // The command reader's first lease owns the refusal reason. Tightening
      // its capacity to zero cannot replace that lease or renew its allowance.
      #expect(throws: NotebookStorageError.limitExceeded("agent_command_read")) {
        try reader.observe { cut in
          let database = try #require(store.currentSQL)
          try database.limitReads(.init(rows: 0, bytes: 0, valueBytes: 0, reason: "preflight_outer_read"))
          _ = try? cut.handle(NotebookReadCommand(request(.init(kind: .actionHistoryPreflight))))
        }
      }
      #expect(try store.currentReadCursor() == cursor)
      let format = try reader.observe { _ in
        try #require(store.currentSQL).rows("PRAGMA user_version").first?[0].integer
      }
      #expect(format == 29)
    }
  }
}
