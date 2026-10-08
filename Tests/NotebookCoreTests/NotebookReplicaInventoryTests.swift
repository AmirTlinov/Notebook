import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Replica readiness metadata borrows the admitted reader")
struct NotebookReplicaInventoryTests {
  private struct Fixture {
    let store: NotebookStore
    let writer: NotebookSQLConnection
    let reader: NotebookReadSession
    let workspaceID: UUID
    let generation: UUID
    let head: UInt64

    func metadata(_ key: String, _ value: String) throws {
      try writer.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [.text(key), .text(value)])
    }
    func cursor(_ source: NotebookReplicationSource, direction: String = "incoming", sequence: Int64) throws {
      let key = direction == "outgoing" ? source.deviceID.uuidString.lowercased() : source.cursorKey
      try writer.run("INSERT INTO peer_cursors VALUES(?,?,?)", [.text(key), .text(direction), .integer(sequence)])
    }
  }

  private func fixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("replica-inventory-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let workspaceID = try store.storedWorkspaceID(), head = try store.currentChangeCursor(), generation = UUID()
    let writer = try NotebookSQLConnection(url: store.databaseURL, writable: true)
    try writer.run("PRAGMA journal_mode=WAL")
    try writer.run("INSERT INTO metadata(key,value) VALUES('journal_generation',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [.text(generation.uuidString.lowercased())])
    try body(.init(store: store, writer: writer, reader: .init(store: store),
      workspaceID: workspaceID, generation: generation, head: head))
  }

  private final class ScalarTrace {
    var largestText = 0
    var blobColumns = 0
  }
  private func trace(_ database: NotebookSQLConnection, _ trace: ScalarTrace) {
    sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
      let trace = Unmanaged<ScalarTrace>.fromOpaque(raw!).takeUnretainedValue()
      let statement = OpaquePointer(pointer!)
      for column in 0..<sqlite3_column_count(statement) {
        if sqlite3_column_type(statement, column) == SQLITE_TEXT {
          trace.largestText = max(trace.largestText, Int(sqlite3_column_bytes(statement, column)))
        } else if sqlite3_column_type(statement, column) == SQLITE_BLOB { trace.blobColumns += 1 }
      }
      return 0
    }, Unmanaged.passUnretained(trace).toOpaque())
  }

  @Test func missingAndInvalidGenerationNeverAdmitAJournalOrCloudSchema() throws {
    try fixture { f in
      try f.writer.run("DELETE FROM metadata WHERE key='journal_generation'")
      let writes = sqlite3_total_changes64(f.writer.handle)
      let expired = try f.reader.observe { query in
        let database = try #require(f.store.currentSQL)
        let cut = try query.replicaInventoryCut()
        #expect(cut.workspaceID == f.workspaceID && cut.borrowedSnapshotID == database.readSnapshotIdentity)
        #expect(cut.databaseVersion == 29 && cut.wireVersion == 44 && cut.manifestVersion == 26)
        #expect(cut.journalGenerationStatus == .missing && cut.journalGeneration == nil)
        #expect(cut.acceptedLocalPrefix?.sequence == f.head)
        #expect(cut.cloud.status == .unconfigured && cut.cloud.enabled == false)
        #expect(cut.controlObservation.scope == .reusedReaderConnection)
        let accounts = try query.replicaCloudAccountPage(in: cut), pending = try query.replicaCloudPendingPage(in: cut)
        #expect(accounts.complete && accounts.entries.isEmpty && pending.complete && pending.entries.isEmpty)
        #expect(!database.writable && sqlite3_db_readonly(database.handle, "main") == 1)
        #expect(sqlite3_total_changes64(database.handle) == 0 && database.decodedFragmentCount == 0)
        return query
      }
      do { _ = try expired.replicaInventoryCut(); Issue.record("An expired cut reopened the reader") }
      catch let error as CollaborationError { #expect(error.code == "read_cut_expired") }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
      #expect(try f.writer.rows("SELECT 1 FROM metadata WHERE key='journal_generation'").isEmpty)
      #expect(try f.writer.rows("SELECT 1 FROM sqlite_master WHERE name LIKE 'cloud_%'").isEmpty)
      try f.metadata("journal_generation", String(repeating: "x", count: 100_000))
      try f.reader.observe { query in
        let database = try #require(f.store.currentSQL), observed = ScalarTrace()
        self.trace(database, observed)
        defer { _ = withExtendedLifetime(observed) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
        let cut = try query.replicaInventoryCut()
        #expect(cut.journalGenerationStatus == .invalid && cut.journalGeneration == nil)
        #expect(observed.largestText <= 64 && observed.blobColumns == 0)
      }
    }
  }

  @Test func everyHistoricalEndpointAndGenerationSurvivesWithoutActiveMembershipInference() throws {
    try fixture { f in
      let device = UUID(), old = NotebookReplicationSource(deviceID: device, generation: UUID())
      let current = NotebookReplicationSource(deviceID: device, generation: UUID())
      let receiptOnly = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let receivedTransaction = UUID(), receivedHash = String(repeating: "a", count: 64)
      let outgoingOnly = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let admittedOnly = UUID(), retired = UUID()
      try f.cursor(old, sequence: 71); try f.cursor(current, sequence: 9)
      try f.cursor(outgoingOnly, direction: "outgoing", sequence: 0)
      try f.writer.run("INSERT INTO received_transactions VALUES(?,?,?,?)", [.text(receivedTransaction.uuidString.lowercased()),
        .text(receivedHash), .text(receiptOnly.cursorKey), .integer(301)])
      try f.metadata("peer_generation:" + device.uuidString.lowercased(), current.generation.uuidString.lowercased())
      try f.metadata("peer_generation:" + admittedOnly.uuidString.lowercased(), UUID().uuidString.lowercased())
      try f.metadata("replication_snapshot:" + old.cursorKey, "70")
      let retirement = NotebookPeerRetirement(peerID: retired, workspaceID: f.workspaceID, sourceCursor: f.head,
        acknowledgedCursor: 0, date: Date(timeIntervalSinceReferenceDate: 1234))
      try f.metadata("retired_peer:" + retired.uuidString.lowercased(),
        String(decoding: try NotebookStore.storageEncoder.encode(retirement), as: UTF8.self))
      try f.reader.observe { query in
        let cut = try query.replicaInventoryCut(), page = try query.replicaEndpointPage(in: cut)
        #expect(page.complete && page.entries.count == 8)
        #expect(page.entries.contains(.incoming(source: old, acceptedThrough: 71)))
        #expect(page.entries.contains(.incoming(source: current, acceptedThrough: 9)))
        #expect(page.entries.contains(.outgoing(deviceID: outgoingOnly.deviceID, acknowledgedThrough: 0)))
        #expect(page.entries.contains(.firstReceived(transactionID: receivedTransaction, source: receiptOnly,
          senderSequence: 301, manifestHash: receivedHash)))
        #expect(page.entries.contains(.admittedGeneration(deviceID: device, generation: current.generation)))
        #expect(page.entries.contains(.snapshotCoverage(source: old, coveredThrough: 70)))
        #expect(page.entries.contains(.retirement(retirement)))
        #expect(NotebookTransportFraming.isSHA256(page.scalarWitnessHash))
      }
    }
  }

  @Test func largeDirectoryKeepsOneSnapshotAndMetadataOnlyCommitInvalidatesItsNextCutCursor() throws {
    try fixture { f in
      for index in 1...130 {
        let device = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index)))
        try f.cursor(.init(deviceID: device, generation: device), sequence: Int64(index))
      }
      let extra = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      var priorCursor: NotebookReplicaInventoryCursor?, priorCut: NotebookReplicaInventoryCut?
      var connectionID: ObjectIdentifier?
      try f.reader.observe { query in
        let database = try #require(f.store.currentSQL), cut = try query.replicaInventoryCut()
        connectionID = ObjectIdentifier(database); priorCut = cut
        var page = try query.replicaEndpointPage(in: cut), entries = page.entries
        priorCursor = page.next
        #expect(!page.complete && page.entries.count == 64)
        // This durable ACK/source metadata change deliberately leaves read_revision.
        // The borrowed WAL cut must finish its 130 old rows, never mix in row 131.
        try f.cursor(extra, sequence: 5)
        while let next = page.next {
          page = try query.replicaEndpointPage(in: cut, after: next)
          #expect(page.entries.count <= 64 && page.cut == cut)
          entries.append(contentsOf: page.entries)
        }
        #expect(entries.count == 130 && !entries.contains(.incoming(source: extra, acceptedThrough: 5)))
      }
      try f.reader.observe { query in
        let database = try #require(f.store.currentSQL), cut = try query.replicaInventoryCut()
        let prior = try #require(priorCut)
        #expect(ObjectIdentifier(database) == connectionID && cut.borrowedSnapshotID != prior.borrowedSnapshotID)
        #expect(cut.readRevision == prior.readRevision)
        #expect(cut.controlObservation.fixedScalarHash == prior.controlObservation.fixedScalarHash)
        #expect(cut.controlObservation.sqliteDataVersion != prior.controlObservation.sqliteDataVersion)
        #expect(throws: NotebookStorageError.invalidTransaction("replica inventory cursor changed")) {
          _ = try query.replicaEndpointPage(in: cut, after: priorCursor)
        }
        #expect(throws: NotebookStorageError.invalidTransaction("replica inventory read cut changed")) {
          _ = try query.replicaEndpointPage(in: prior)
        }
        var page = try query.replicaEndpointPage(in: cut), count = page.entries.count
        while let next = page.next { page = try query.replicaEndpointPage(in: cut, after: next); count += page.entries.count }
        #expect(count == 131)
      }
    }
  }

  @Test func hundredThousandAcceptedMarkersSeekOneBoundedTailWithoutRehashingHistory() throws {
    try fixture { f in
      let source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let hash = String(repeating: "a", count: 64)
      // Real DB29 accepted-marker rows, not a second in-memory history owner.
      try f.writer.run("""
        WITH RECURSIVE positions(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM positions WHERE n<100000)
        INSERT INTO received_transactions(transaction_id,manifest_hash,peer_id,sequence)
        SELECT printf('00000000-0000-0000-0000-%012x',n),?,?,n FROM positions
        """, [.text(hash), .text(source.cursorKey)])
      #expect(try f.writer.rows("SELECT count(*) FROM received_transactions").first?[0].integer == 100_000)
      try f.reader.observe { query in
        let database = try #require(f.store.currentSQL), cut = try query.replicaInventoryCut()
        // An aggregate GROUP BY/full-history scan cannot fit this remaining
        // SQL lease. The existing transaction PK seek can read the exact tail.
        try database.limitReads(.init(rows: 128, bytes: 262_144, valueBytes: 512,
          reason: "replica_tail", sqlSteps: 100_000))
        let key = String(format: "00000000-0000-0000-0000-%012x", 99_968)
        let position = NotebookReplicaInventoryPosition(workspaceID: f.workspaceID, section: .endpoints,
          kind: 3, key: key, subkey: "", offset: 0)
        let page = try query.replicaEndpointPage(in: cut, resuming: position,
          expectedControlObservation: cut.controlObservation)
        #expect(page.complete && page.entries.count == 32 && page.next == nil)
        let first = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 99_969))!
        let last = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", 100_000))!
        #expect(page.entries.first == .firstReceived(transactionID: first, source: source, senderSequence: 99_969, manifestHash: hash))
        #expect(page.entries.last == .firstReceived(transactionID: last, source: source, senderSequence: 100_000, manifestHash: hash))
        #expect(database.decodedFragmentCount == 0 && sqlite3_total_changes64(database.handle) == 0)
      }
    }
  }

  @Test func uploadedPrefixAndHistoricalAccountsDoNotHidePendingIncomingOrPartialChunks() throws {
    try fixture { f in
      try f.store.prepareCloudStorage()
      let local = NotebookReplicationSource(deviceID: UUID(), generation: f.generation)
      try f.store.enableCloud(account: "active", source: local)
      try f.writer.run("UPDATE cloud_accounts SET cursor=?,engine=zeroblob(1048576) WHERE account='active'", [.integer(Int64(f.head))])
      try f.writer.run("INSERT INTO cloud_accounts(account,generation) VALUES('historical',?)", [.text(UUID().uuidString.lowercased())])
      let accountKeys = ["active", "historical", "e\u{301}", "\u{e9}"]
      for account in accountKeys.dropFirst(2) {
        try f.writer.run("INSERT INTO cloud_accounts(account,generation) VALUES(?,?)",
          [.text(account), .text(UUID().uuidString.lowercased())])
      }
      let hash = String(repeating: "b", count: 64), deliveryID = "d." + String(repeating: "c", count: 64)
      let planID = UUID()
      let source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      try f.writer.run("INSERT INTO cloud_inbox VALUES('active',?,?,41,0,zeroblob(512))", [.text(deliveryID), .text(source.cursorKey)])
      try f.writer.run("INSERT INTO cloud_chunks VALUES('active',?,0,2097152,zeroblob(1048576))", [.text(hash)])
      try f.writer.run("INSERT INTO cloud_exports(account,delivery,plan,ready,blob_cursor,record_cursor) VALUES('historical',zeroblob(0),?,0,7,9)", [.text(planID.uuidString.lowercased())])
      let descriptor = try NotebookCloudRecord.chunk(hash: hash, offset: 0, totalBytes: 2_097_152)
      try f.writer.run("INSERT INTO cloud_outbox VALUES('historical',?,NULL,?,0,2097152)", [.text(descriptor.id), .text(hash)])
      let oldDeliveryID = "d." + String(repeating: "d", count: 64)
      let uploadedChunk = try NotebookCloudRecord.chunk(hash: hash, offset: 1_048_576, totalBytes: 2_097_152)
      try f.writer.run("INSERT INTO cloud_uploaded VALUES('active',?)", [.text(oldDeliveryID)])
      try f.writer.run("INSERT INTO cloud_uploaded VALUES('historical',?)", [.text(uploadedChunk.id)])
      let writes = sqlite3_total_changes64(f.writer.handle)
      try f.reader.observe { query in
        let database = try #require(f.store.currentSQL), observed = ScalarTrace()
        self.trace(database, observed)
        defer { _ = withExtendedLifetime(observed) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
        let cut = try query.replicaInventoryCut()
        #expect(cut.cloud.status == .ready && cut.cloud.enabled == true && cut.cloud.account == "active")
        var accountPage = try query.replicaCloudAccountPage(in: cut, limit: 1), accounts = accountPage.entries
        while let next = accountPage.next {
          accountPage = try query.replicaCloudAccountPage(in: cut, after: next, limit: 1)
          accounts.append(contentsOf: accountPage.entries)
        }
        #expect(accounts.map { Array($0.account.utf8) } == accountKeys.map { Array($0.utf8) }.sorted {
          $0.lexicographicallyPrecedes($1)
        })
        let active = try #require(accounts.first { $0.account == "active" })
        #expect(active.uploadedThrough == f.head && active.engineByteCount == 1_048_576)
        var page = try query.replicaCloudPendingPage(in: cut, limit: 2), pending = page.entries
        #expect(!page.complete && page.entries.count == 2)
        while let next = page.next { page = try query.replicaCloudPendingPage(in: cut, after: next, limit: 2); pending += page.entries }
        #expect(pending.count == 4)
        #expect(pending.contains(.incoming(account: "active", recordID: deliveryID, source: source,
          senderSequence: 41, snapshot: false, deliveryByteCount: 512)))
        #expect(pending.contains(.chunk(account: "active", blobHash: hash, offset: 0,
          totalBytes: 2_097_152, receivedByteCount: 1_048_576)))
        #expect(pending.contains(.export(account: "historical", ready: false, deliveryByteCount: 0,
          planID: planID, planByteCount: 36, blobCursor: 7, recordCursor: 9)))
        #expect(pending.contains(.outbox(account: "historical", recordID: descriptor.id, blobHash: hash,
          offset: 0, totalBytes: 2_097_152, deliveryByteCount: nil)))
        var receiptPage = try query.replicaCloudReceiptCachePage(in: cut, limit: 1), receipts = receiptPage.entries
        #expect(!receiptPage.complete && receiptPage.receiptCount == 1)
        while let next = receiptPage.next {
          receiptPage = try query.replicaCloudReceiptCachePage(in: cut, after: next, limit: 1)
          #expect(receiptPage.receiptCount == receiptPage.entries.count)
          receipts.append(contentsOf: receiptPage.entries)
        }
        #expect(receipts == [.init(account: "active", recordID: oldDeliveryID), .init(account: "historical", recordID: uploadedChunk.id)])
        #expect(pending.count == 4)
        #expect(observed.blobColumns == 0 && observed.largestText <= 512 && database.decodedFragmentCount == 0)
        #expect(sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test func semanticPositionCanResumeAnUnchangedReaderButMetadataOnlyAckRefusesItsOldFence() throws {
    try fixture { f in
      #expect(f.head > 0)
      let source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      try f.cursor(source, sequence: 11); try f.cursor(source, direction: "outgoing", sequence: 0)
      let original = try f.reader.observe { query -> (NotebookReplicaInventoryCut, NotebookReplicaInventoryCursor) in
        let cut = try query.replicaInventoryCut(), page = try query.replicaEndpointPage(in: cut, limit: 1)
        #expect(!page.complete)
        // Completeness is an explicit wire scalar, not a computed field lost
        // when the native report encodes its bounded page.
        #expect(try JSONValue.encode(page)["complete"] == .bool(false))
        return (cut, try #require(page.next))
      }
      let resumed = try f.reader.observe { query -> NotebookReplicaInventoryCut in
        let cut = try query.replicaInventoryCut()
        #expect(cut.borrowedSnapshotID != original.0.borrowedSnapshotID)
        #expect(cut.controlObservation == original.0.controlObservation)
        #expect(throws: NotebookStorageError.invalidTransaction("replica inventory cursor changed")) {
          _ = try query.replicaEndpointPage(in: cut, after: original.1)
        }
        let page = try query.replicaEndpointPage(in: cut, resuming: original.1.position,
          expectedControlObservation: original.0.controlObservation, limit: 1)
        #expect(page.entries == [.outgoing(deviceID: source.deviceID, acknowledgedThrough: 0)])
        #expect(page.cut.borrowedSnapshotID == cut.borrowedSnapshotID)
        #expect(page.next?.borrowedSnapshotID == cut.borrowedSnapshotID)
        return cut
      }
      // This is the production ACK owner's metadata relation, with no authored
      // occurrence or material revision. The old local fence must now refuse.
      try f.writer.run("UPDATE peer_cursors SET sequence=? WHERE peer_id=? AND direction='outgoing'",
        [.integer(Int64(f.head)), .text(source.deviceID.uuidString.lowercased())])
      try f.reader.observe { query in
        let cut = try query.replicaInventoryCut()
        #expect(cut.readRevision == original.0.readRevision && cut.readRevision == resumed.readRevision)
        #expect(cut.controlObservation.fixedScalarHash == resumed.controlObservation.fixedScalarHash)
        #expect(cut.controlObservation.sqliteDataVersion != resumed.controlObservation.sqliteDataVersion)
        #expect(throws: NotebookStorageError.invalidTransaction("replica inventory control changed")) {
          _ = try query.replicaEndpointPage(in: cut, resuming: original.1.position,
            expectedControlObservation: resumed.controlObservation)
        }
        let fresh = try query.replicaEndpointPage(in: cut)
        #expect(fresh.entries.contains(.outgoing(deviceID: source.deviceID, acknowledgedThrough: f.head)))
      }
    }
  }

  @Test func partialCloudSchemaAndOversizedEndpointRefuseWithoutCopyingBodiesOrInventingCompleteness() throws {
    try fixture { f in
      try f.writer.run("CREATE TABLE cloud_control(id INTEGER PRIMARY KEY,account TEXT,enabled INTEGER NOT NULL)")
      try f.writer.run("INSERT INTO cloud_control VALUES(1,NULL,0)")
      try f.reader.observe { query in
        let cut = try query.replicaInventoryCut()
        #expect(cut.cloud.status == .invalid && cut.cloud.issue == .incompleteSchema && cut.cloud.enabled == nil)
        #expect(throws: NotebookStorageError.corruptRecord("replica inventory cloud schema/control")) {
          _ = try query.replicaCloudPendingPage(in: cut)
        }
      }
      try f.writer.run("INSERT INTO peer_cursors VALUES(?,'incoming',1)", [.text(String(repeating: "x", count: 100_000))])
      try f.reader.observe { query in
        let database = try #require(f.store.currentSQL), observed = ScalarTrace()
        self.trace(database, observed)
        defer { _ = withExtendedLifetime(observed) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
        let cut = try query.replicaInventoryCut()
        #expect(throws: NotebookStorageError.corruptRecord("replica inventory endpoint key")) {
          _ = try query.replicaEndpointPage(in: cut)
        }
        #expect(observed.largestText <= 64 && observed.blobColumns == 0)
      }
    }
  }

  @Test func existingReadAllowanceAndCancellationCannotBeRenewedByAPage() throws {
    try fixture { f in
      let refusal = NotebookStorageError.limitExceeded(NotebookSQLReadAllowance.agentCommand.reason)
      let exhaustedRead = {
        try f.reader.observe { query in
          let cut = try query.replicaInventoryCut(), database = try #require(f.store.currentSQL)
          try database.limitReads(.init(rows: 0, bytes: 1024, valueBytes: 1024, reason: "replica_test_lease"))
          #expect(throws: refusal) { _ = try query.replicaEndpointPage(in: cut) }
          #expect(throws: refusal) { _ = try query.replicaCloudAccountPage(in: cut) }
        }
      }
      #expect(throws: refusal) { try exhaustedRead() }
    }
    try fixture { f in
      do {
        try f.reader.observe { query in
          let cut = try query.replicaInventoryCut()
          f.reader.cancellation.cancel()
          _ = try query.replicaEndpointPage(in: cut)
        }
        Issue.record("A cancelled reader completed an inventory page")
      } catch is CancellationError { }
    }
  }
}
