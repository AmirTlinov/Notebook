import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Legacy acceptance inventory borrows one bounded read cut")
struct NotebookActionHistoryInventoryTests {
  private struct Fixture {
    let store: NotebookStore
    let writer: NotebookSQLConnection
    let workspaceID: UUID
    let payloadHash: String

    func manifest(_ transactionID: UUID, payloadHash: String? = nil) throws -> (hash: String, bytes: Int) {
      let manifest = NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID,
        records: [.init(address: "collaboration/actions/receipt.json#", blobHash: payloadHash ?? self.payloadHash)])
      let data = try NotebookStore.storageEncoder.encode(manifest)
      return (try writer.putBlob(data), data.count)
    }

    func journal(_ transactionID: UUID, manifest: (hash: String, bytes: Int), sequence: Int64) throws {
      try writer.run("INSERT INTO change_log(sequence,transaction_id,manifest_hash,byte_count) VALUES(?,?,?,?)",
        [.integer(sequence), .text(transactionID.uuidString.lowercased()), .text(manifest.hash), .integer(Int64(manifest.bytes))])
    }

    func received(_ transactionID: UUID, hash: String, source: NotebookReplicationSource, sequence: Int64) throws {
      try writer.run("INSERT INTO received_transactions VALUES(?,?,?,?)", [.text(transactionID.uuidString.lowercased()),
        .text(hash), .text(source.cursorKey), .integer(sequence)])
    }

    func read<T>(_ body: (NotebookSQLConnection) throws -> T) throws -> T {
      let reader = try NotebookSQLConnection(url: store.databaseURL, writable: false)
      return try store.readTransaction(using: reader) { _ in try body(reader) }
    }
  }

  private func fixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-history-inventory-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), workspaceID = UUID()
    let writer = try NotebookSQLConnection(url: store.databaseURL, writable: true, create: true)
    // The isolated fixture uses DB29's actual acceptance/staging relations;
    // the inventory performs no schema admission or database initialization.
    try writer.run("PRAGMA journal_mode=WAL")
    try writer.run("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
    try writer.run("INSERT INTO metadata VALUES('workspace_id',?)", [.text(workspaceID.uuidString.lowercased())])
    try writer.run("CREATE TABLE blobs(hash TEXT PRIMARY KEY CHECK(length(hash)=64),data BLOB NOT NULL)")
    try writer.run("CREATE TABLE change_log(sequence INTEGER PRIMARY KEY AUTOINCREMENT,transaction_id TEXT NOT NULL UNIQUE,manifest_hash TEXT NOT NULL REFERENCES blobs(hash),byte_count INTEGER NOT NULL)")
    try writer.run("CREATE TABLE change_records(sequence INTEGER NOT NULL REFERENCES change_log(sequence),address TEXT NOT NULL,blob_hash TEXT,PRIMARY KEY(sequence,address))")
    try writer.run("CREATE TABLE received_transactions(transaction_id TEXT PRIMARY KEY,manifest_hash TEXT NOT NULL,peer_id TEXT NOT NULL,sequence INTEGER NOT NULL)")
    try writer.run("CREATE TABLE manifests(hash TEXT PRIMARY KEY REFERENCES blobs(hash),transaction_id TEXT NOT NULL,order_node_count INTEGER NOT NULL DEFAULT 0,order_node_bytes INTEGER NOT NULL DEFAULT 0)")
    try writer.run("CREATE TABLE manifest_records(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),address TEXT NOT NULL,blob_hash TEXT,PRIMARY KEY(manifest_hash,address))")
    try writer.run("CREATE TABLE peer_cursors(peer_id TEXT NOT NULL,direction TEXT NOT NULL,sequence INTEGER NOT NULL,PRIMARY KEY(peer_id,direction))")
    let payloadHash = try writer.putBlob(Data("same retained receipt fragment".utf8))
    try body(.init(store: store, writer: writer, workspaceID: workspaceID, payloadHash: payloadHash))
  }

  private final class HeaderTrace {
    var largestTextBytes = 0
    var blobColumns = 0
  }

  private func trace(_ database: NotebookSQLConnection, _ trace: HeaderTrace) {
    sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
      let trace = Unmanaged<HeaderTrace>.fromOpaque(raw!).takeUnretainedValue()
      let statement = OpaquePointer(pointer!)
      for column in 0..<sqlite3_column_count(statement) {
        if sqlite3_column_type(statement, column) == SQLITE_TEXT {
          trace.largestTextBytes = max(trace.largestTextBytes, Int(sqlite3_column_bytes(statement, column)))
        } else if sqlite3_column_type(statement, column) == SQLITE_BLOB { trace.blobColumns += 1 }
      }
      return 0
    }, Unmanaged.passUnretained(trace).toOpaque())
  }

  @Test func localAndMaterialNoOpIncomingAreEnumeratedWhileStagedManifestsAreExcluded() throws {
    try fixture { f in
      let localID = UUID(), receivedID = UUID(), stagedID = UUID()
      let source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let local = try f.manifest(localID), incoming = try f.manifest(receivedID), staged = try f.manifest(stagedID)
      try f.journal(localID, manifest: local, sequence: 11)
      // A first delivery with no material effect has no local journal or
      // change_records row, but its acceptance marker still commits.
      try f.received(receivedID, hash: incoming.hash, source: source, sequence: 77)
      try f.writer.run("INSERT INTO manifests(hash,transaction_id) VALUES(?,?)", [.text(staged.hash), .text(stagedID.uuidString.lowercased())])
      try f.writer.run("INSERT INTO manifest_records VALUES(?,?,?)", [.text(staged.hash), .text("collaboration/actions/receipt.json#"), .text(f.payloadHash)])
      let writes = sqlite3_total_changes64(f.writer.handle)
      try f.read { database in
        let trace = HeaderTrace()
        self.trace(database, trace)
        defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
        let page = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
        #expect(page.borrowedSnapshotID == database.readSnapshotIdentity && page.workspaceID == f.workspaceID)
        #expect(page.occurrences.count == 2 && page.next == nil)
        let authored = try #require(page.occurrences.first { $0.transactionID == localID })
        #expect(authored.workspaceID == f.workspaceID && authored.manifestHash == local.hash)
        #expect(authored.localJournal == .init(sequence: 11, manifestByteCount: local.bytes))
        #expect(authored.firstReceived == nil)
        let noOp = try #require(page.occurrences.first { $0.transactionID == receivedID })
        #expect(noOp.manifestHash == incoming.hash && noOp.localJournal == nil)
        #expect(noOp.firstReceived == .init(source: source, senderSequence: 77))
        #expect(!page.occurrences.contains { $0.transactionID == stagedID })
        #expect(trace.largestTextBytes <= 73 && trace.blobColumns == 0 && database.decodedFragmentCount == 0)
        #expect(sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
      #expect(try f.writer.rows("SELECT count(*) FROM manifests").first?[0].integer == 1)
      #expect(try f.writer.rows("SELECT count(*) FROM change_records").first?[0].integer == 0)
    }
  }

  @Test func relayedJournalAndFirstReceivedCoalesceWithoutInventingDuplicateSourceMappings() throws {
    try fixture { f in
      let transactionID = UUID(), firstSource = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let duplicateSource = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let manifest = try f.manifest(transactionID)
      try f.journal(transactionID, manifest: manifest, sequence: 19)
      try f.received(transactionID, hash: manifest.hash, source: firstSource, sequence: 7)
      // The existing duplicate-delivery branch advances only this cursor.
      try f.writer.run("INSERT INTO peer_cursors VALUES(?,'incoming',88)", [.text(duplicateSource.cursorKey)])
      try f.read { database in
        let page = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
        let occurrence = try #require(page.occurrences.first)
        #expect(page.occurrences.count == 1 && page.next == nil)
        #expect(occurrence.transactionID == transactionID && occurrence.manifestHash == manifest.hash)
        #expect(occurrence.localJournal == .init(sequence: 19, manifestByteCount: manifest.bytes))
        #expect(occurrence.firstReceived == .init(source: firstSource, senderSequence: 7))
      }
    }
  }

  @Test func differentAcceptedManifestHashesForOneTransactionRefuseBeforeReturningAPage() throws {
    try fixture { f in
      let transactionID = UUID(), source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let local = try f.manifest(transactionID)
      let otherPayload = try f.writer.putBlob(Data("conflicting receipt fragment".utf8))
      let incoming = try f.manifest(transactionID, payloadHash: otherPayload)
      #expect(local.hash != incoming.hash)
      try f.journal(transactionID, manifest: local, sequence: 1)
      try f.received(transactionID, hash: incoming.hash, source: source, sequence: 1)
      _ = try f.read { database in
        #expect(throws: NotebookStorageError.transactionConflict) {
          _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
        }
      }
    }
  }

  @Test func keysetPagesPreserveDistinctAcceptedTransactionsSharingTheSamePayload() throws {
    try fixture { f in
      var expected: [UUID] = []
      for index in 1...128 {
        let suffix = String(index, radix: 16)
        let transactionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - suffix.count) + suffix))
        expected.append(transactionID)
        try f.journal(transactionID, manifest: f.manifest(transactionID), sequence: Int64(index))
      }
      try f.read { database in
        let first = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
        let firstCursor = try #require(first.next)
        let second = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: firstCursor)
        let secondCursor = try #require(second.next)
        let final = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: secondCursor)
        #expect(first.occurrences.count == 64 && second.occurrences.count == 64)
        #expect(final.occurrences.isEmpty && final.next == nil)
        #expect(first.borrowedSnapshotID == second.borrowedSnapshotID && second.borrowedSnapshotID == final.borrowedSnapshotID)
        #expect((first.occurrences + second.occurrences).map(\.transactionID) == expected)
        #expect(first.occurrences[0].manifestHash != first.occurrences[1].manifestHash,
          "Transaction identity remains distinct even though the receipt payload is shared")
      }
    }
  }

  @Test func paginationKeepsItsSnapshotAcrossPeerCommitsAndRejectsAnotherReadCut() throws {
    try fixture { f in
      let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
      let middleID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
      let lastID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
      try f.journal(firstID, manifest: f.manifest(firstID), sequence: 1)
      try f.journal(lastID, manifest: f.manifest(lastID), sequence: 2)
      let cursor = try f.read { database in
        let first = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, limit: 1)
        let cursor = try #require(first.next)
        try f.journal(middleID, manifest: f.manifest(middleID), sequence: 3)
        let second = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: cursor)
        #expect(first.occurrences.map(\.transactionID) == [firstID])
        #expect(second.occurrences.map(\.transactionID) == [lastID])
        #expect(first.borrowedSnapshotID == second.borrowedSnapshotID)
        return cursor
      }
      try f.read { database in
        #expect(throws: NotebookStorageError.invalidTransaction("action history inventory read cut changed")) {
          _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: cursor)
        }
        let currentPage = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
        #expect(currentPage.occurrences.map(\.transactionID) == [firstID, middleID, lastID])
      }
    }
  }

  @Test func aHundredThousandMarkersKeepKeysetWorkInsideTheEnclosingSQLLease() throws {
    try fixture { f in
      // One fixture transaction avoids per-row fsync. Actual manifests retain
      // their distinct transaction IDs while sharing the same fragment payload.
      try f.writer.run("BEGIN IMMEDIATE")
      do {
        for index in 1...100_000 {
          let suffix = String(index, radix: 16)
          let transactionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - suffix.count) + suffix))
          let manifest = try f.manifest(transactionID)
          if index.isMultiple(of: 2) {
            try f.journal(transactionID, manifest: manifest, sequence: Int64(index))
          } else {
            let source = NotebookReplicationSource(deviceID: f.workspaceID, generation: f.workspaceID)
            try f.received(transactionID, hash: manifest.hash, source: source, sequence: Int64(index))
          }
        }
        try f.writer.run("COMMIT")
      } catch { try? f.writer.run("ROLLBACK"); throw error }
      var returnedMarkers = 0
      #expect(throws: NotebookStorageError.limitExceeded("read_sql_work")) {
        try f.read { database in
          // This instruction ceiling cannot enumerate/sort all 100k markers.
          // The inventory must seek each persistent index and merge one page.
          try database.limitReads(.init(rows: 256, bytes: 65_536, valueBytes: 256,
            reason: "inventory_keyset_headers", sqlSteps: 65_536))
          let first = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
          let firstCursor = try #require(first.next)
          let second = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: firstCursor)
          #expect(first.occurrences.count == 64 && second.occurrences.count == 64)
          #expect(first.occurrences[0].firstReceived?.senderSequence == 1)
          #expect(first.occurrences[1].localJournal?.sequence == 2)
          #expect(second.occurrences[0].firstReceived?.senderSequence == 65)
          #expect(second.occurrences.last?.localJournal?.sequence == 128)
          #expect(database.decodedFragmentCount == 0)
          returnedMarkers = first.occurrences.count + second.occurrences.count
          // A nested helper cannot replace an exhausted physical instruction
          // lease, even when the caller catches its original refusal.
          try database.limitReads(.init(rows: 256, bytes: 65_536, valueBytes: 256,
            reason: "inventory_keyset_headers", sqlSteps: 0))
          do {
            _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: second.next)
            Issue.record("Inventory must refuse the exhausted SQL lease")
          } catch {
            let refusal = error as? NotebookStorageError
            #expect(refusal == NotebookStorageError.limitExceeded("read_sql_work"))
          }
        }
      }
      #expect(returnedMarkers == 128, "The finite lease must first return both indexed pages")
    }
  }

  enum Corruption: CaseIterable, Sendable {
    case nullKey, emptyKey, oversizedKey, oversizedHash, invalidHash, oversizedSource, nonintegerSequence
  }

  @Test(arguments: Corruption.allCases)
  func malformedHeadersRefuseBeforeCopyingUnboundedScalars(corruption: Corruption) throws {
    try fixture { f in
      let transactionID = UUID(), source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      try f.received(transactionID, hash: f.manifest(transactionID).hash, source: source, sequence: 1)
      let column: String, value: NotebookSQLValue
      switch corruption {
      case .nullKey: column = "transaction_id"; value = .null
      case .emptyKey: column = "transaction_id"; value = .text("")
      case .oversizedKey: column = "transaction_id"; value = .text(String(repeating: "x", count: 1_048_576))
      case .oversizedHash: column = "manifest_hash"; value = .text(String(repeating: "a", count: 1_048_576))
      case .invalidHash: column = "manifest_hash"; value = .text(String(repeating: "g", count: 64))
      case .oversizedSource: column = "peer_id"; value = .text(String(repeating: "x", count: 1_048_576))
      case .nonintegerSequence: column = "sequence"; value = .text(String(repeating: "x", count: 1_048_576))
      }
      try f.writer.run("UPDATE received_transactions SET \(column)=?", [value])
      try f.read { database in
        let trace = HeaderTrace()
        self.trace(database, trace)
        defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
        #expect(throws: NotebookStorageError.corruptRecord("action history inventory marker")) {
          _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
        }
        #expect(trace.largestTextBytes <= 73 && trace.blobColumns == 0)
      }
    }
  }

  @Test func admissionRequiresTheCallerWorkspaceAndDoesNotRenewAnExhaustedBudget() throws {
    try fixture { f in
      let transactionID = UUID()
      try f.journal(transactionID, manifest: f.manifest(transactionID), sequence: 1)
      #expect(throws: NotebookStorageError.readOnlyTransaction) {
        _ = try NotebookActionHistoryInventory.page(in: f.writer, workspaceID: f.workspaceID)
      }
      try f.read { database in
        #expect(throws: NotebookStorageError.corruptRecord("action history inventory workspace")) {
          _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: UUID())
        }
        for limit in [0, 65] {
          #expect(throws: NotebookStorageError.limitExceeded("action_history_inventory_page")) {
            _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, limit: limit)
          }
        }
      }
      #expect(throws: NotebookStorageError.limitExceeded("inventory_outer_read")) {
        try f.read { database in
          try database.limitReads(.init(rows: 0, bytes: 0, valueBytes: 0, reason: "inventory_outer_read"))
          _ = try? database.rows("SELECT 1")
          do {
            _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID)
            Issue.record("Inventory must preserve the enclosing read refusal")
          } catch {
            let refusal = error as? NotebookStorageError
            #expect(refusal == NotebookStorageError.limitExceeded("inventory_outer_read"))
          }
        }
      }
      let resumedCount = try f.read { try NotebookActionHistoryInventory.page(in: $0, workspaceID: f.workspaceID).occurrences.count }
      #expect(resumedCount == 1)
    }
  }
}
