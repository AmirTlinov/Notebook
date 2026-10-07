import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Storage diagnostics borrow a committed metadata cut")
struct NotebookStorageUsageTests {
  private func fixture(_ body: (NotebookStore, [NotebookDurableChange]) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepareEmptyWorkspace(workspaceID: UUID())
    // Returning to the original value reuses its blob in current content and
    // two immutable history entries; history must charge that payload once.
    for value in ["first", "second", "first"] {
      try store.publishRecords(writes: ["diagnostic.json": .object(["body": .string(value)])])
    }
    let changes = try store.changeJournal(after: 0)
    #expect(changes.count == 3)
    for change in changes { #expect(try store.missingBlobHashes(for: change).isEmpty) }
    try body(store, changes)
  }

  private final class Trace {
    var blobColumns = 0
    var onStatement: ((String) -> Void)?
    var error: (any Error)?
  }

  private func trace(_ connection: NotebookSQLConnection, _ trace: Trace) {
    sqlite3_trace_v2(connection.handle, UInt32(SQLITE_TRACE_ROW | SQLITE_TRACE_STMT), { kind, raw, pointer, _ in
      let trace = Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue()
      let statement = OpaquePointer(pointer!)
      if kind == UInt32(SQLITE_TRACE_ROW) {
        for index in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, index) == SQLITE_BLOB {
          trace.blobColumns += 1
        }
      } else if let sql = sqlite3_sql(statement) { trace.onStatement?(String(cString: sql)) }
      return 0
    }, Unmanaged.passUnretained(trace).toOpaque())
  }

  @Test(arguments: [false, true])
  func inventoryDeduplicatesCurrentAndHistoryWithoutReadingBodiesOrWriting(changePhysicalSample: Bool) throws {
    try fixture { store, changes in
      let opaque = Data(repeating: 0xff, count: 4_096)
      try store.commandTransaction(advancesReadRevision: false) { _ = try store.currentSQL!.putBlob(opaque) }
      let source = try store.replicationSource(deviceID: UUID())
      let revision = try store.currentReadCursor(), cursor = try store.currentChangeCursor()
      let usage = try store.readTransaction { store in
        let connection = try #require(store.currentSQL), trace = Trace()
        let writes = sqlite3_total_changes64(connection.handle)
        if changePhysicalSample {
          trace.onStatement = { sql in
            guard sql.hasPrefix("WITH current_hashes") else { return }
            trace.onStatement = nil
            do {
              // Deterministically change only a sampled physical attribute
              // after its first sample, while the logical WAL cut stays fixed.
              try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: store.databaseURL.path)
            } catch { trace.error = error }
          }
        }
        self.trace(connection, trace)
        defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(connection.handle, 0, nil, nil) } }
        let first = try store.storageUsage()
        if let error = trace.error { throw error }
        #expect(first.cut.snapshotID == connection.readSnapshotIdentity)
        #expect(first.cut.journalGeneration == source.generation)
        #expect(try first.cut.workspaceID == store.storedWorkspaceID())
        #expect(first.cut.readRevision == revision && first.cut.changeSequence == cursor)
        #expect(first.logicalStatus == .snapshot && first.reachability == .partial)
        #expect(first.blobs.count == 6)
        #expect(first.currentRecords.recordCount == 1 && first.currentRecords.payload.count == 1)
        #expect(first.retainedHistory.changeCount == 3 && first.retainedHistory.changeRecordCount == 3)
        #expect(first.retainedHistory.manifestCount == 3 && first.retainedHistory.manifestRecordCount == 3)
        #expect(first.retainedHistory.payload.count == 5, "Three manifests and two shared record bodies")
        #expect(first.retainedHistory.changeManifestBytes == Int64(changes.reduce(0) { $0 + $1.byteCount }))
        #expect(first.indexedReferences.count == 5)
        #expect(first.unclassifiedBlobs.count == 1 && first.unclassifiedBlobs.bytes == Int64(opaque.count))
        #expect(first.blobs.bytes == first.indexedReferences.bytes + first.unclassifiedBlobs.bytes)
        #expect(first.currentRecords.payload.bytes < first.retainedHistory.payload.bytes,
          "Current payload already belongs to history; categories must not be added")
        #expect((first.physical.database.bytes ?? 0) > 0)
        #expect(first.physical.database.status == (changePhysicalSample ? .changed : .unchanged))
        if changePhysicalSample { #expect(first.physical.sampleStatus == .changed) }
        #expect(first.physical.pageSize > 0 && first.physical.freelistPages <= first.physical.pageCount)
        #expect(trace.blobColumns == 0 && connection.decodedFragmentCount == 0)
        #expect(sqlite3_total_changes64(connection.handle) == writes)
        let second = try store.storageUsage()
        #expect(second.cut == first.cut && second.blobs == first.blobs)
        #expect(second.currentRecords == first.currentRecords && second.retainedHistory == first.retainedHistory)
        return first
      }
      #expect(try usage.cut.readRevision == store.currentReadCursor())
      #expect(try usage.cut.changeSequence == store.currentChangeCursor())
      #expect(try store.changeJournal(after: 0) == changes)
      let encoded = try JSONEncoder().encode(usage)
      #expect(try JSONDecoder().decode(NotebookStorageUsage.self, from: encoded) == usage)
      #expect(!String(decoding: encoded, as: UTF8.self).contains(store.root.path))
    }
  }

  @Test func pendingIncomingReferencesDistinguishPresentAndMissingWithoutClaimingOrphans() throws {
    try fixture { store, changes in
      let present = Data([0xff, 0x01, 0x02]), unknown = Data([0xfe])
      try store.commandTransaction(advancesReadRevision: false) {
        let connection = store.currentSQL!, manifest = changes[0].manifestHash
        let hash = try connection.putBlob(present)
        _ = try connection.putBlob(unknown)
        try connection.run("INSERT INTO manifest_parts(manifest_hash,part_hash) VALUES(?,?)", [.text(manifest), .text(hash)])
        try connection.run("INSERT INTO manifest_order_nodes(manifest_hash,hash) VALUES(?,?),(?,?)",
          [.text(manifest), .text(hash), .text(manifest), .text(String(repeating: "f", count: 64))])
      }
      let usage = try store.readTransaction { try $0.storageUsage() }
      #expect(usage.incoming.pendingPartCount == 1 && usage.incoming.pendingOrderNodeCount == 2)
      #expect(usage.incoming.presentPayload.count == 1 && usage.incoming.presentPayload.bytes == Int64(present.count))
      #expect(usage.incoming.missingBlobCount == 1)
      #expect(usage.unclassifiedBlobs.count == 1 && usage.unclassifiedBlobs.bytes == Int64(unknown.count))
      #expect(usage.reachability == .partial)
    }
  }

  @Test func knownPeerPendingDeliveryDeduplicatesGenerationsAndBoundsItsOutput() throws {
    try fixture { store, changes in
      let acknowledged = UUID(), pending = UUID(), retired = UUID()
      try store.acknowledgePeer(peerID: acknowledged, through: changes[0].sequence)
      try store.commandTransaction(advancesReadRevision: false) {
        for peer in [pending, pending, retired] {
          let source = NotebookReplicationSource(deviceID: peer, generation: UUID())
          try store.currentSQL!.run("INSERT INTO peer_cursors VALUES(?,'incoming',0)", [.text(source.cursorKey)])
        }
      }
      _ = try store.retireReplicationPeer(retired, workspaceID: store.storedWorkspaceID(), expectedCursor: changes.last!.sequence)
      let usage = try store.readTransaction { try $0.storageUsage() }
      #expect(usage.outgoing.knownPeerCount == 3 && usage.outgoing.peers.count == 3 && !usage.outgoing.truncated)
      let first = try #require(usage.outgoing.peers.first { $0.peerID == acknowledged })
      #expect(first.acknowledgedSequence == changes[0].sequence && first.pendingChangeCount == 2)
      #expect(first.pendingManifestBytes == Int64(changes.dropFirst().reduce(0) { $0 + $1.byteCount }))
      let second = try #require(usage.outgoing.peers.first { $0.peerID == pending })
      #expect(second.acknowledgedSequence == 0 && second.pendingChangeCount == 3)
      let finished = try #require(usage.outgoing.peers.first { $0.peerID == retired })
      #expect(finished.retired && finished.pendingChangeCount == 0 && finished.pendingManifestBytes == 0)
      #expect(usage.retainedHistory.changeCount == 3, "Retirement preserves authored history")

      try store.commandTransaction(advancesReadRevision: false) {
        for _ in 0..<67 {
          try store.currentSQL!.run("INSERT INTO peer_cursors VALUES(?,'incoming',0)", [.text(UUID().uuidString.lowercased())])
        }
      }
      let bounded = try store.readTransaction { try $0.storageUsage() }
      #expect(bounded.outgoing.knownPeerCount == 70 && bounded.outgoing.peers.count == 64 && bounded.outgoing.truncated)
      let keys = bounded.outgoing.peers.map { $0.peerID.uuidString.lowercased() }
      #expect(keys == keys.sorted())
    }
  }

  @Test func anExhaustedEnclosingReadCannotBeRenewedByInventory() throws {
    try fixture { store, _ in
      #expect(throws: NotebookStorageError.limitExceeded("outer_usage_read")) {
        try store.readTransaction { store in
          let connection = store.currentSQL!
          try connection.limitReads(.init(rows: 0, bytes: 0, valueBytes: 0, reason: "outer_usage_read"))
          _ = try? connection.rows("SELECT 1")
          _ = try store.storageUsage()
        }
      }
      let resumed = try store.readTransaction { try $0.storageUsage() }
      #expect(resumed.retainedHistory.changeCount == 3)
    }
  }

  @Test func aHundredThousandHistoryRowsShareTheSQLBudgetAndCancellation() throws {
    try fixture { store, changes in
      try store.commandTransaction(advancesReadRevision: false) {
        // Disk-backed historical tombstones force metadata work; no giant Swift
        // record array or payload body is part of this bounded reader fixture.
        try store.currentSQL!.run("""
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<100000)
          INSERT INTO change_records(sequence,address,blob_hash)
          SELECT ?, 'diagnostic-history/' || i, NULL FROM n
          """, [.integer(Int64(changes[0].sequence))])
      }
      // Tightening consumes the enclosing SQL owner's original work lease.
      #expect(throws: NotebookStorageError.limitExceeded("read_sql_work")) {
        try store.readTransaction { store in
          try store.currentSQL!.limitReads(.init(rows: 4_096, bytes: 1_048_576, valueBytes: 256,
            reason: "finite_usage_sql", sqlSteps: 1_000))
          _ = try store.storageUsage()
        }
      }
      let cancellation = NotebookReadCancellation(), reader = NotebookReadSession(store: store, cancellation: cancellation)
      #expect(throws: CancellationError.self) {
        try reader.read { store in
          let connection = try #require(store.currentSQL), trace = Trace()
          trace.onStatement = { sql in
            if sql.hasPrefix("WITH current_hashes") { cancellation.cancel() }
          }
          self.trace(connection, trace)
          defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(connection.handle, 0, nil, nil) } }
          _ = try store.storageUsage()
        }
      }
      #expect(try store.currentChangeCursor() == changes.last!.sequence)
    }
  }

  @Test func diagnosticsRequireCurrentReadAdmissionAndNeverInitializeOrMigrate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-admission-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = NotebookStore(root: root.appendingPathComponent("missing"))
    #expect(throws: NotebookStorageError.readOnlyTransaction) { _ = try missing.storageUsage() }
    do {
      _ = try NotebookReadSession(store: missing).read { try $0.storageUsage() }
      Issue.record("A missing diagnostic must refuse before creating a root")
    } catch { }
    #expect(!FileManager.default.fileExists(atPath: missing.root.path))

    // Root's typed route and current-only read admission are integrated with
    // this slice; rawValue keeps this test source independent of enum spelling.
    let kind = try #require(NotebookReadQuery.Kind(rawValue: "storageUsage"))
    var request = NotebookCommand(command: .read)
    request.queries = [.init(kind: kind)]
    do {
      _ = try NotebookCommandDispatcher(store: missing).handle(request)
      Issue.record("A missing dispatcher diagnostic must refuse before bootstrap")
    } catch { }
    #expect(!FileManager.default.fileExists(atPath: missing.root.path))

    let store = NotebookStore(root: root.appendingPathComponent("noncurrent"))
    try store.prepareEmptyWorkspace(workspaceID: UUID())
    #expect(throws: NotebookStorageError.readOnlyTransaction) {
      try store.commandTransaction { _ = try store.storageUsage() }
    }
    let connection = try store.prepareDatabase(), oldVersion = NotebookStore.currentDatabaseVersion - 1
    try connection.run("PRAGMA user_version=\(oldVersion)")
    let before = try connection.rows("SELECT key,value FROM metadata ORDER BY key").map { [$0[0].text!, $0[1].text!] }
    #expect(throws: NotebookStorageError.unsupportedFormat) {
      _ = try NotebookReadSession(store: store).read { try $0.storageUsage() }
    }
    do {
      _ = try NotebookCommandDispatcher(store: store).handle(request)
      Issue.record("The dispatcher diagnostic must not migrate an old format")
    } catch let error as CollaborationError { #expect(error.code == "unsupported_format") }
    #expect(try connection.rows("PRAGMA user_version").first?[0].integer == oldVersion)
    #expect(try connection.rows("SELECT key,value FROM metadata ORDER BY key").map { [$0[0].text!, $0[1].text!] } == before)
  }
}
