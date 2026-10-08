import CSQLite
import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

@Suite("History readiness streams commit bounded transaction metadata")
struct NotebookHistoryReadinessMetadataTests {
  private typealias Proof = NotebookHistoryPhysicalClosure
  private let workspace = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private let transaction = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
  private let manifest = String(repeating: "a", count: 64)

  private struct Fixture {
    let store: NotebookStore
    let writer: NotebookSQLConnection
    let reader: NotebookReadSession
    let workspaceID: UUID

    func accept(_ ids: [UUID] = []) throws -> (UUID, String) {
      let transactionID = UUID()
      try writer.run("BEGIN IMMEDIATE")
      defer { try? writer.run("ROLLBACK") }
      let files: [(String, JSONValue)] = ids.isEmpty
        ? [("readiness-note.json", .string("accepted transaction with zero receipts"))]
        : ids.map { ("collaboration/actions/" + $0.uuidString.lowercased() + ".json",
          .object(["id": .string($0.uuidString), "action": .object(["id": .string($0.uuidString)]),
            "unknownAuthoredField": .string("private source 🖋️")])) }
      var records: [NotebookRecordMutation] = []
      for (file, value) in files {
        for fragment in try NotebookRecordCodec.encode(value, file: file) {
          records.append(.init(address: fragment.address,
            blobHash: try writer.putBlob(writer.encodedStoredFragment(fragment))))
        }
      }
      let bytes = try NotebookStore.storageEncoder.encode(NotebookChangeManifest(transactionID: transactionID,
        workspaceID: workspaceID, records: records))
      let hash = try writer.putBlob(bytes)
      try writer.run("INSERT INTO change_log(transaction_id,manifest_hash,byte_count) VALUES(?,?,?)",
        [.text(transactionID.uuidString.lowercased()), .text(hash), .integer(Int64(bytes.count))])
      try writer.run("COMMIT")
      return (transactionID, hash)
    }
  }

  private func fixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-metadata-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let writer = try NotebookSQLConnection(url: store.databaseURL, writable: true)
    try body(.init(store: store, writer: writer, reader: .init(store: store), workspaceID: header.workspaceID))
  }

  private func occurrence(local: Bool = true) -> NotebookActionHistoryInventory.Occurrence {
    .init(workspaceID: workspace, transactionID: transaction, manifestHash: manifest,
      localJournal: local ? .init(sequence: 19, manifestByteCount: 123) : nil,
      firstReceived: local ? nil : .init(source: .init(deviceID: UUID(), generation: UUID()), senderSequence: 73))
  }
  private func source(_ resultHash: String = String(repeating: "4", count: 64)) -> Proof.SourceOriginal {
    .init(status: .authenticatedSourceLocalRoots, originalVersion: String(repeating: "1", count: 64),
      original: .init(hash: String(repeating: "2", count: 64), byteCount: 10),
      model: .init(hash: String(repeating: "3", count: 64), byteCount: 20),
      result: .init(hash: resultHash, byteCount: 30))
  }
  private func receipt(_ id: UUID, source: Proof.SourceOriginal, bytes: Int64 = 100) -> Proof.Receipt {
    .init(id: id, status: .authenticatedDeclaredClosure, logicalBinding: .externalizedMembership,
      fragmentCount: 2, fragmentBytes: bytes, fragmentSetHash: String(repeating: "5", count: 64),
      dependencyCount: 1, dependencyBytes: 200, dependencySetHash: String(repeating: "6", count: 64),
      sourceOriginal: source)
  }
  private func authenticatedDeclarations(_ count: Int) -> Proof.DeclaredRecords {
    .init(status: .authenticatedDeclaredClosure, recordCount: count, removalCount: 0, payloadBytes: 1_000,
      recordSetHash: String(repeating: "b", count: 64), dependencyCount: 0, dependencyBytes: 0,
      dependencySetHash: String(repeating: "c", count: 64))
  }
  private func proof(_ receipts: [Proof.Receipt], parts: [Proof.Blob] = [], declared: Proof.DeclaredRecords) -> Proof {
    .init(workspaceID: workspace, transactionID: transaction, manifestHash: manifest,
      borrowedSnapshotID: UUID(), manifestFormat: 26, manifest: .init(hash: manifest, byteCount: 123),
      manifestParts: parts, declaredRecords: declared, receipts: receipts)
  }

  @Test func acceptedIdentityHasIndependentFramingAndIgnoresDeliveryRoute() throws {
    let local = try occurrence().historyReadinessAcceptedMetadata()
    let received = try occurrence(local: false).historyReadinessAcceptedMetadata()
    #expect(local == received && local.count == 1)
    // Independent contiguous reference encoding for the normative accepted row.
    // Route, journal sequence, marker byte count and snapshot are absent.
    var expected = Data()
    for text in ["notebook.history-readiness.accepted.v1", workspace.uuidString.lowercased(),
      transaction.uuidString.lowercased(), manifest] {
      let bytes = Data(text.utf8), count = UInt64(bytes.count)
      for shift in stride(from: 56, through: 0, by: -8) { expected.append(UInt8(truncatingIfNeeded: count >> shift)) }
      expected.append(bytes)
    }
    #expect(local.hash == NotebookHexEncoding.encode(SHA256.hash(data: expected)))
    #expect(local.byteCount == Int64(expected.count))
    let other = NotebookActionHistoryInventory.Occurrence(workspaceID: workspace, transactionID: UUID(),
      manifestHash: manifest, localJournal: .init(sequence: 19, manifestByteCount: 123), firstReceived: nil)
    #expect(try other.historyReadinessAcceptedMetadata().hash != local.hash)
  }

  @Test func transactionStreamsSeparateOriginalsFromPhysicalMembershipAndKeepPartOrder() throws {
    let first = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    let second = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    let receipts = [receipt(first, source: source()), receipt(second, source: source())]
    let parts: [Proof.Blob] = [.init(hash: String(repeating: "7", count: 64), byteCount: 40),
      .init(hash: String(repeating: "8", count: 64), byteCount: 50)]
    let declared = authenticatedDeclarations(4)
    let baseline = try proof(receipts, parts: parts, declared: declared).historyReadinessMetadata(accepted: occurrence())
    let reordered = try proof(Array(receipts.reversed()), parts: parts, declared: declared).historyReadinessMetadata(accepted: occurrence(local: false))
    #expect(baseline == reordered, "Snapshot identity and arrival/receipt enumeration order cannot change transaction rows")
    let sourceChanged = try proof([receipt(first, source: source(String(repeating: "9", count: 64))), receipts[1]],
      parts: parts, declared: declared).historyReadinessMetadata(accepted: occurrence())
    #expect(sourceChanged.acceptedTransactions == baseline.acceptedTransactions
      && sourceChanged.physicalClosures == baseline.physicalClosures
      && sourceChanged.sourceOriginalRoots.hash != baseline.sourceOriginalRoots.hash)
    let physicalChanged = try proof([receipt(first, source: source(), bytes: 101), receipts[1]], parts: parts, declared: declared)
      .historyReadinessMetadata(accepted: occurrence())
    #expect(physicalChanged.physicalClosures.hash != baseline.physicalClosures.hash
      && physicalChanged.sourceOriginalRoots == baseline.sourceOriginalRoots)
    let partsChanged = try proof(receipts, parts: Array(parts.reversed()), declared: declared).historyReadinessMetadata(accepted: occurrence())
    #expect(partsChanged.physicalClosures.hash != baseline.physicalClosures.hash
      && partsChanged.sourceOriginalRoots == baseline.sourceOriginalRoots)
    #expect(baseline.receiptCount == 2 && baseline.physicalComplete && baseline.sourceOriginalComplete)
  }

  @Test func unknownAndPartialOriginalsRemainExplicitWithoutPromotingOrOmittingTheirReceipt() throws {
    let id = UUID()
    let missing = Proof.SourceOriginal(status: .unproven(.originalAnchorUnavailable),
      originalVersion: nil, original: nil, model: nil, result: nil)
    let baseline = try proof([receipt(id, source: missing)], declared: authenticatedDeclarations(2)).historyReadinessMetadata(accepted: occurrence())
    #expect(baseline.physicalComplete && !baseline.sourceOriginalComplete)
    #expect(baseline.unknownSourceOriginalCount == 1 && baseline.missingSourceOriginalRootCount == 3)
    #expect(baseline.blockers == [.init(receiptID: id, component: .sourceOriginal, reason: .originalAnchorUnavailable)])
    let partial = Proof.SourceOriginal(status: .unproven(.originalAnchorMismatch), originalVersion: "",
      original: .init(hash: String(repeating: "2", count: 64), byteCount: 10), model: nil, result: nil)
    let changed = try proof([receipt(id, source: partial)], declared: authenticatedDeclarations(2)).historyReadinessMetadata(accepted: occurrence())
    #expect(changed.physicalClosures == baseline.physicalClosures)
    #expect(changed.sourceOriginalRoots.hash != baseline.sourceOriginalRoots.hash
      && changed.unknownSourceOriginalCount == 1 && changed.missingSourceOriginalRootCount == 2)
    let absentPhysical = Proof.Receipt(id: id, status: .unproven(.rootRemoved), logicalBinding: .notEvaluated,
      fragmentCount: 1, fragmentBytes: 0, fragmentSetHash: nil, dependencyCount: 0, dependencyBytes: 0,
      dependencySetHash: nil, sourceOriginal: source())
    let incomplete = try proof([absentPhysical], declared: authenticatedDeclarations(1)).historyReadinessMetadata(accepted: occurrence())
    #expect(!incomplete.physicalComplete && incomplete.sourceOriginalComplete && incomplete.incompletePhysicalCount == 1)
    #expect(incomplete.blockers == [.init(receiptID: id, component: .physicalClosure, reason: .rootRemoved)])
    #expect(throws: NotebookStorageError.invalidTransaction("duplicate history readiness metadata")) {
      _ = try proof([receipt(id, source: missing), receipt(id, source: missing)], declared: authenticatedDeclarations(4)).historyReadinessMetadata(accepted: occurrence())
    }
    #expect(throws: NotebookStorageError.limitExceeded("history_readiness_metadata")) {
      _ = try proof((0..<65).map { _ in receipt(UUID(), source: missing) }, declared: authenticatedDeclarations(130)).historyReadinessMetadata(accepted: occurrence())
    }
  }

  @Test func actualReadonlyTransactionKeepsZeroReceiptsUnknownRootsAndOneExistingLease() throws {
    try fixture { f in
      let zero = try f.accept(), nonzero = try f.accept([UUID(), UUID()])
      let writes = sqlite3_total_changes64(f.writer.handle)
      var escaped: NotebookQueryCut?
      let first = try f.reader.observe { cut in
        escaped = cut
        let page = try cut.actionHistoryOccurrencePage(limit: 64)
        let accepted = try #require(page.occurrences.first { $0.transactionID == zero.0 })
        let metadata = try cut.actionHistoryReadinessMetadata(transactionID: zero.0, manifestHash: zero.1)
        #expect(try accepted.historyReadinessAcceptedMetadata() == metadata.acceptedTransactions)
        #expect(metadata.receiptCount == 0 && metadata.physicalComplete && metadata.sourceOriginalComplete)
        #expect(metadata.physicalClosures.count == 1 && metadata.sourceOriginalRoots.count == 1)
        let withReceipts = try cut.actionHistoryReadinessMetadata(transactionID: nonzero.0, manifestHash: nonzero.1)
        #expect(withReceipts.receiptCount == 2 && withReceipts.physicalComplete && !withReceipts.sourceOriginalComplete)
        #expect(withReceipts.unknownSourceOriginalCount == 2 && withReceipts.missingSourceOriginalRootCount == 6)
        let database = try #require(f.store.currentSQL)
        #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0)
        #expect(sqlite3_total_changes64(database.handle) == 0)
        let publicJSON = String(decoding: try NotebookStore.storageEncoder.encode(withReceipts), as: UTF8.self)
        #expect(!publicJSON.contains("private source") && !publicJSON.contains("borrowedSnapshotID")
          && !publicJSON.contains("originalVersion") && !publicJSON.contains("fragmentSetHash"))
        return metadata
      }
      let second = try f.reader.observe { try $0.actionHistoryReadinessMetadata(transactionID: zero.0, manifestHash: zero.1) }
      #expect(first == second, "A fresh ephemeral snapshot preserves canonical rows")
      do {
        _ = try #require(escaped).actionHistoryReadinessMetadata(transactionID: zero.0, manifestHash: zero.1)
        Issue.record("A finished borrowed cut projected history")
      } catch let error as CollaborationError { #expect(error.code == "read_cut_expired") }
      #expect(throws: NotebookStorageError.invalidTransaction("unaccepted history readiness metadata")) {
        _ = try f.reader.observe { try $0.actionHistoryReadinessMetadata(transactionID: UUID(), manifestHash: zero.1) }
      }
      #expect(throws: NotebookStorageError.transactionConflict) {
        _ = try f.reader.observe { try $0.actionHistoryReadinessMetadata(transactionID: zero.0, manifestHash: String(repeating: "f", count: 64)) }
      }
      #expect(throws: NotebookStorageError.limitExceeded(NotebookSQLReadAllowance.agentCommand.reason)) {
        try f.reader.observe { cut in
          let database = try #require(f.store.currentSQL)
          try database.limitReads(.init(rows: 0, bytes: 1_024, valueBytes: 1_024, reason: "metadata_existing_lease"))
          _ = try cut.actionHistoryReadinessMetadata(transactionID: zero.0, manifestHash: zero.1)
        }
      }
      do {
        try f.reader.observe { cut in
          f.reader.cancellation.cancel()
          _ = try cut.actionHistoryReadinessMetadata(transactionID: zero.0, manifestHash: zero.1)
        }
        Issue.record("A cancelled lease projected history")
      } catch is CancellationError { }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["missing", "corrupt"])
  func zeroReceiptTransactionCannotHideAnUnreadDeclaredPayload(_ condition: String) throws {
    try fixture { f in
      let accepted = try f.accept()
      let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: f.writer.blob(accepted.1))
      let hash = try #require(manifest.records.first?.blobHash)
      let raw = try f.writer.blob(hash)
      let cursor = try f.store.currentChangeCursor(), revision = try f.store.currentReadCursor()
      let baseline = try f.reader.observe {
        try $0.actionHistoryReadinessMetadata(transactionID: accepted.0, manifestHash: accepted.1)
      }
      #expect(baseline.physicalComplete && baseline.receiptCount == 0 && baseline.blockers.isEmpty)
      if condition == "missing" { try f.writer.run("DELETE FROM blobs WHERE hash=?", [.text(hash)]) }
      else {
        let tampered = String(decoding: raw, as: UTF8.self)
          .replacingOccurrences(of: "zero receipts", with: "lost receipts")
        #expect(tampered != String(decoding: raw, as: UTF8.self))
        try f.writer.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data(tampered.utf8)), .text(hash)])
      }
      let writes = sqlite3_total_changes64(f.writer.handle)
      if condition == "missing" {
        let result = try f.reader.observe {
          try $0.actionHistoryReadinessMetadata(transactionID: accepted.0, manifestHash: accepted.1)
        }
        #expect(result.acceptedTransactions == baseline.acceptedTransactions && result.receiptCount == 0)
        #expect(!result.physicalComplete && result.incompletePhysicalCount == 1
          && result.physicalClosures != baseline.physicalClosures)
        #expect(result.sourceOriginalRoots == baseline.sourceOriginalRoots && result.sourceOriginalComplete)
        #expect(result.blockers == [.init(receiptID: nil, component: .physicalClosure, reason: .missingBlob)])
      } else {
        #expect(throws: NotebookStorageError.blobHashMismatch) {
          _ = try f.reader.observe {
            try $0.actionHistoryReadinessMetadata(transactionID: accepted.0, manifestHash: accepted.1)
          }
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
      let afterCursor = try f.store.currentChangeCursor(), afterRevision = try f.store.currentReadCursor()
      #expect(afterCursor == cursor && afterRevision == revision)
      try f.writer.run("INSERT INTO blobs(hash,data) VALUES(?,?) ON CONFLICT(hash) DO UPDATE SET data=excluded.data",
        [.text(hash), .blob(raw)])
      let restored = try f.reader.observe {
        try $0.actionHistoryReadinessMetadata(transactionID: accepted.0, manifestHash: accepted.1)
      }
      #expect(restored == baseline, "Same manifest and restored actual bytes recover the same framed metadata")
    }
  }

  @Test func zeroReceiptMetadataRequiresExplicitAuthenticatedDeclaredFields() throws {
    let declared = authenticatedDeclarations(1)
    let complete = try proof([], declared: declared).historyReadinessMetadata(accepted: occurrence())
    let absent = Proof.DeclaredRecords(status: .unproven(.missingBlob), recordCount: 1, removalCount: 0,
      payloadBytes: 0, recordSetHash: nil, dependencyCount: 0, dependencyBytes: 0, dependencySetHash: nil)
    let incomplete = try proof([], declared: absent).historyReadinessMetadata(accepted: occurrence())
    #expect(complete.physicalComplete && !incomplete.physicalComplete && incomplete.incompletePhysicalCount == 1)
    #expect(complete.acceptedTransactions == incomplete.acceptedTransactions
      && complete.physicalClosures != incomplete.physicalClosures)
    let falselyAuthenticated = Proof.DeclaredRecords(status: .authenticatedDeclaredClosure,
      recordCount: 1, removalCount: 0, payloadBytes: 0, recordSetHash: nil,
      dependencyCount: 0, dependencyBytes: 0, dependencySetHash: nil)
    #expect(throws: NotebookStorageError.invalidTransaction("history readiness authenticated declared fields")) {
      _ = try proof([], declared: falselyAuthenticated).historyReadinessMetadata(accepted: occurrence())
    }
    let encoded = try JSONValue.encode(proof([], declared: declared))
    guard case .object(var fields) = encoded else { Issue.record("Fixture was not an object"); return }
    fields.removeValue(forKey: "declaredRecords")
    let omitted = try NotebookStore.storageEncoder.encode(JSONValue.object(fields))
    #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(Proof.self, from: omitted) }
  }
}
