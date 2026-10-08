import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Accepted legacy receipts preserve original fragments in one bounded read cut")
struct NotebookActionHistoryFactResolverTests {
  private struct Manifest {
    let hash: String
    let bytes: Int
  }

  private struct Fixture {
    let store: NotebookStore
    let writer: NotebookSQLConnection
    let workspaceID: UUID

    func file(_ id: UUID) -> String { "collaboration/actions/" + id.uuidString.lowercased() + ".json" }
    func value(_ id: UUID) -> JSONValue {
      .object(["id": .string(id.uuidString), "action": .object(["id": .string(id.uuidString)]),
        "futureReceipt": .object(["unknownActor": .null, "text": .string("исходный 🖋️"),
          "nested": .array([.number(7), .bool(true)])])])
    }

    func records(_ fragments: [NotebookStoredFragment], unknownEnvelope: Bool = false) throws
      -> (records: [NotebookRecordMutation], payloads: [String: Data]) {
      var records: [NotebookRecordMutation] = [], payloads: [String: Data] = [:]
      for fragment in fragments {
        var data = try writer.encodedStoredFragment(fragment)
        if unknownEnvelope {
          let envelope = try JSONDecoder().decode(JSONValue.self, from: data)
          data = try NotebookStore.storageEncoder.encode(envelope.setting("futureEnvelope", .object(["retained": .bool(true)])))
        }
        records.append(.init(address: fragment.address, blobHash: try writer.putBlob(data)))
        payloads[fragment.address] = data
      }
      return (records, payloads)
    }

    func manifest(_ transactionID: UUID, records: [NotebookRecordMutation], parts: [String] = [],
      format: Int = NotebookChangeManifest.currentFormat) throws -> Manifest {
      let typed = NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID, records: records, parts: parts)
      let json = try JSONValue.encode(typed).setting("format", .number(Double(format)))
      let data = try NotebookStore.storageEncoder.encode(json)
      return .init(hash: try writer.putBlob(data), bytes: data.count)
    }

    func journal(_ id: UUID, _ manifest: Manifest, sequence: Int64) throws {
      try writer.run("INSERT INTO change_log(sequence,transaction_id,manifest_hash,byte_count) VALUES(?,?,?,?)",
        [.integer(sequence), .text(id.uuidString.lowercased()), .text(manifest.hash), .integer(Int64(manifest.bytes))])
    }
    func received(_ id: UUID, _ manifest: Manifest, source: NotebookReplicationSource, sequence: Int64) throws {
      try writer.run("INSERT INTO received_transactions VALUES(?,?,?,?)",
        [.text(id.uuidString.lowercased()), .text(manifest.hash), .text(source.cursorKey), .integer(sequence)])
    }
    func current(_ records: [NotebookRecordMutation], file: String) throws {
      for record in records {
        try writer.run("INSERT OR REPLACE INTO records(address,file,parent,collection,member,position,hash) VALUES(?,?,NULL,'','',0,?)",
          [.text(record.address), .text(file), record.blobHash.map(NotebookSQLValue.text) ?? .null])
      }
    }
    func originalAnchor(_ id: UUID, body: JSONValue, original: JSONValue? = nil,
      model: JSONValue? = nil, result: JSONValue? = nil) throws -> NotebookActionHistoryObservation.OriginalAnchor {
      let version = try notebookActionDeliveryVersion(body)
      let prefix = "local/action-results/" + id.uuidString.lowercased() + "/"
      let roots: [(String, JSONValue)] = [
        (prefix + "original.json", original ?? .string(version)),
        (prefix + version + "/model.json", model ?? .object(["id": .string(id.uuidString), "actionVersion": .string(version)])),
        (prefix + version + "/result.json", result ?? .object(["actionID": .string(id.uuidString),
          "actionVersion": .string(version), "basis": .object(["workspaceID": .string(workspaceID.uuidString)])]))]
      var hashes: [String] = []
      for (file, value) in roots {
        let payload = try records(NotebookRecordCodec.encode(value, file: file))
        try current(payload.records, file: file)
        let root = try #require(payload.records.first { $0.address == file + "#" })
        hashes.append(try #require(root.blobHash))
      }
      return .init(originalVersion: version, originalRootHash: hashes[0], modelRootHash: hashes[1], resultRootHash: hashes[2])
    }
    func read<T>(cancellation: NotebookReadCancellation? = nil, _ body: (NotebookSQLConnection) throws -> T) throws -> T {
      let reader = try NotebookSQLConnection(url: store.databaseURL, writable: false)
      return try store.readTransaction(using: reader, cancellation: cancellation) { _ in try body(reader) }
    }
  }

  private func fixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-history-fact-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), workspaceID = UUID()
    let writer = try NotebookSQLConnection(url: store.databaseURL, writable: true, create: true)
    // Real DB29 acceptance/blob relations; no resolver initialization or index.
    try writer.run("PRAGMA journal_mode=WAL")
    try writer.run("PRAGMA user_version=29")
    try writer.run("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
    try writer.run("INSERT INTO metadata VALUES('workspace_id',?)", [.text(workspaceID.uuidString.lowercased())])
    try writer.run("CREATE TABLE blobs(hash TEXT PRIMARY KEY CHECK(length(hash)=64),data BLOB NOT NULL)")
    try writer.run("CREATE TABLE change_log(sequence INTEGER PRIMARY KEY AUTOINCREMENT,transaction_id TEXT NOT NULL UNIQUE,manifest_hash TEXT NOT NULL REFERENCES blobs(hash),byte_count INTEGER NOT NULL)")
    try writer.run("CREATE TABLE received_transactions(transaction_id TEXT PRIMARY KEY,manifest_hash TEXT NOT NULL,peer_id TEXT NOT NULL,sequence INTEGER NOT NULL)")
    try writer.run("CREATE TABLE manifests(hash TEXT PRIMARY KEY REFERENCES blobs(hash),transaction_id TEXT NOT NULL,order_node_count INTEGER NOT NULL DEFAULT 0,order_node_bytes INTEGER NOT NULL DEFAULT 0)")
    try writer.run("CREATE TABLE manifest_records(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),address TEXT NOT NULL,blob_hash TEXT,PRIMARY KEY(manifest_hash,address))")
    try writer.run("CREATE TABLE records(address TEXT PRIMARY KEY,file TEXT NOT NULL,parent TEXT,collection TEXT NOT NULL,member TEXT NOT NULL,position INTEGER NOT NULL,hash TEXT NOT NULL REFERENCES blobs(hash))")
    try body(.init(store: store, writer: writer, workspaceID: workspaceID))
  }

  @Test func localAndReceivedOnlyFactsKeepRawUnknownFieldsAndIgnoreCurrentAndStagingIndexes() throws {
    try fixture { f in
      let id = UUID(), localID = UUID(), incomingID = UUID()
      let original = f.value(id)
      let payload = try f.records(NotebookRecordCodec.encode(original, file: f.file(id)), unknownEnvelope: true)
      let local = try f.manifest(localID, records: payload.records, format: 25)
      let incoming = try f.manifest(incomingID, records: payload.records, format: 25)
      try f.journal(localID, local, sequence: 19)
      try f.received(incomingID, incoming, source: .init(deviceID: UUID(), generation: UUID()), sequence: 73)
      let other = try f.records(NotebookRecordCodec.encode(original.setting("futureReceipt", .string("later material")), file: f.file(id)))
      try f.current(other.records, file: f.file(id))
      // Staging discovery may be partial. Its rows cannot fill the original cut.
      try f.writer.run("INSERT INTO manifests(hash,transaction_id) VALUES(?,?)", [.text(local.hash), .text(localID.uuidString.lowercased())])
      try f.writer.run("INSERT INTO manifest_records VALUES(?,?,?)", [.text(local.hash), .text(f.file(id) + "#"), .text(other.records[0].blobHash!)])
      let changes = sqlite3_total_changes64(f.writer.handle)
      try f.read { database in
        let localFact = try f.store.actionHistoryFact(transactionID: localID, manifestHash: local.hash)
        let receivedFact = try f.store.actionHistoryFact(transactionID: incomingID, manifestHash: incoming.hash, receiptID: id)
        for fact in [localFact, receivedFact] {
          let receipt = try #require(fact.receipts.first)
          #expect(fact.workspaceID == f.workspaceID && fact.borrowedSnapshotID == database.readSnapshotIdentity)
          #expect(fact.manifestFormat == 25 && fact.receipts.count == 1 && receipt.id == id)
          #expect(receipt.disposition == .completeSelfContained(original))
          #expect(receipt.fragments == [.init(address: f.file(id) + "#", manifestPartHash: nil,
            blobHash: payload.records[0].blobHash, rawPayload: payload.payloads[f.file(id) + "#"])])
        }
        #expect(localFact.transactionID != receivedFact.transactionID && localFact.manifestHash != receivedFact.manifestHash)
        #expect(localFact.borrowedSnapshotID == receivedFact.borrowedSnapshotID && sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == changes)
      #expect(try f.writer.rows("PRAGMA user_version").first?[0].integer == 29)
      #expect(try f.writer.rows("SELECT count(*) FROM received_transactions").first?[0].integer == 1)
      #expect(try f.writer.rows("SELECT count(*) FROM change_log").first?[0].integer == 1)
    }
  }

  @Test func stagedOnlyAndAChangedAcceptedManifestHaveNoFactAuthority() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let payload = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.writer.run("INSERT INTO manifests(hash,transaction_id) VALUES(?,?)", [.text(manifest.hash), .text(transactionID.uuidString.lowercased())])
      try f.writer.run("INSERT INTO manifest_records VALUES(?,?,?)", [.text(manifest.hash), .text(payload.records[0].address), .text(payload.records[0].blobHash!)])
      let staged = try f.read { database in
        try NotebookActionHistoryInventory.occurrence(in: database, workspaceID: f.workspaceID, transactionID: transactionID)
      }
      #expect(staged == nil)
      #expect(throws: NotebookStorageError.invalidTransaction("unaccepted action history occurrence")) {
        _ = try f.read { _ in try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash) }
      }
      try f.journal(transactionID, manifest, sequence: 1)
      #expect(throws: NotebookStorageError.transactionConflict) {
        _ = try f.read { _ in try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: String(repeating: "f", count: 64)) }
      }
      #expect(throws: NotebookStorageError.readOnlyTransaction) {
        _ = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
      }
    }
  }

  @Test(arguments: [0, 1, 2])
  func emptyAndMissingLastCollectionMembersRemainUnprovenEvenWhenCodecRoundTrips(_ childCount: Int) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), a = UUID().uuidString, b = UUID().uuidString
      let value = f.value(id).setting("before", .object(["pageIDs": .array([.string(a), .string(b)])]))
      let full = try NotebookRecordCodec.encode(value, file: f.file(id))
      let root = try #require(full.first { $0.parent == nil })
      let children = full.filter { $0.parent != nil }.sorted { $0.position < $1.position }
      let empty = try NotebookRecordCodec.encode(f.value(id).setting("before", .object(["pageIDs": .array([])])), file: f.file(id))
      let emptyRoot = try #require(empty.first)
      #expect(root == emptyRoot, "An originally empty array and omitted children share the exact physical root")
      let declared = [root] + Array(children.prefix(childCount))
      let reconstructed = try NotebookRecordCodec.decode(declared, root: f.file(id) + "#")
      #expect(reconstructed["before"]?["pageIDs"]?.arrayValues.count == childCount)
      let roundTrip = try NotebookRecordCodec.encode(reconstructed, file: f.file(id))
      #expect(Set(roundTrip.map(\.address)) == Set(declared.map(\.address)), "Codec roundtrip cannot prove missing membership")
      let payload = try f.records(declared), current = try f.records(full)
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      try f.current(current.records, file: f.file(id))
      try f.read { _ in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .unprovenClosure(.externalizedMembership))
        #expect(receipt.fragments.count == childCount + 1)
        for fragment in receipt.fragments { #expect(fragment.rawPayload == payload.payloads[fragment.address]) }
      }
    }
  }

  @Test(arguments: ["originalRootAbsent", "rootRemoved", "unreferencedFragments"])
  func missingRemovedAndUnreferencedRootsPreserveDeclarations(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let root = try #require(NotebookRecordCodec.encode(f.value(id), file: file).first)
      let child = NotebookStoredFragment(address: file + "#/before/pageIDs/@old", file: file,
        parent: file + "#", collection: "before/pageIDs", member: "old", position: 0, value: .string("old"), collections: [])
      let payload = try f.records(kind == "unreferencedFragments" ? [root, child] : [child])
      var records = payload.records
      if kind == "rootRemoved" { records.append(.init(address: file + "#", blobHash: nil)) }
      let manifest = try f.manifest(transactionID, records: records)
      try f.journal(transactionID, manifest, sequence: 1)
      let current = try f.records([root])
      try f.current(current.records, file: file)
      try f.read { _ in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        let reason = try #require(NotebookActionHistoryObservation.Reason(rawValue: kind))
        #expect(receipt.disposition == .unprovenClosure(reason) && receipt.fragments.count == records.count)
        if kind == "rootRemoved" {
          let tombstone = try #require(receipt.fragments.first { $0.address == file + "#" })
          #expect(tombstone.blobHash == nil && tombstone.rawPayload == nil)
        }
      }
    }
  }
  @Test func originalManifestPartsSupplySelfContainedReceipts() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let payload = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      let part = try f.manifest(transactionID, records: payload.records)
      let manifest = try f.manifest(transactionID, records: [], parts: [part.hash])
      try f.received(transactionID, manifest, source: .init(deviceID: UUID(), generation: UUID()), sequence: 4)
      try f.read { _ in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .completeSelfContained(f.value(id)))
        #expect(receipt.fragments.first?.manifestPartHash == part.hash)
        #expect(receipt.fragments.first?.rawPayload == payload.payloads[f.file(id) + "#"])
      }
    }
  }

  @Test(arguments: ["full", "originalEmpty", "missingLast", "missingAll"])
  func sourceOriginalDigestDistinguishesCompleteEmptyAndOmittedMembership(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let pages: [JSONValue] = kind == "originalEmpty" ? [] : [.string(UUID().uuidString), .string(UUID().uuidString)]
      let body = f.value(id).setting("before", .object(["pageIDs": .array(pages)]))
      let full = try NotebookRecordCodec.encode(body, file: file)
      let rootCandidate = full.first { $0.parent == nil }
      let root = try #require(rootCandidate)
      let children = full.filter { $0.parent != nil }.sorted { $0.position < $1.position }
      let count = kind == "missingAll" ? 0 : kind == "missingLast" ? 1 : children.count
      let payload = try f.records([root] + Array(children.prefix(count)), unknownEnvelope: true)
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let anchor = try f.originalAnchor(id, body: body)
      // Today's complete receipt must not fill an omitted original member.
      let current = try f.records(full)
      try f.current(current.records, file: file)
      try f.read { database in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(fact.borrowedSnapshotID == database.readSnapshotIdentity && fact.transactionID == transactionID)
        if kind == "full" || kind == "originalEmpty" {
          #expect(receipt.disposition == .completeOriginalBody(body, anchor))
        } else {
          #expect(receipt.disposition == .unprovenClosure(.originalAnchorMismatch))
        }
        #expect(receipt.fragments.count == count + 1)
        for fragment in receipt.fragments { #expect(fragment.rawPayload == payload.payloads[fragment.address]) }
        #expect(sqlite3_total_changes64(database.handle) == 0)
      }
    }
  }

  @Test func originalPartsAndSourceWitnessPreserveUnknownJSONAndDistinctAcceptedOccurrences() throws {
    try fixture { f in
      let id = UUID(), localID = UUID(), incomingID = UUID(), file = f.file(id)
      let body = f.value(id).setting("future", .object(["records": .array([
        .object(["id": .string("one"), "unknown": .object(["nullable": .null, "unicode": .string("🖋️/ё")])]),
        .object(["id": .string("two"), "unknown": .array([.number(7), .bool(true)])])])]))
      let rows = try NotebookRecordCodec.encode(body, file: file), payload = try f.records(rows, unknownEnvelope: true)
      let anchor = try f.originalAnchor(id, body: body)
      func accepted(_ transactionID: UUID) throws -> Manifest {
        let parts = try payload.records.map { try f.manifest(transactionID, records: [$0]).hash }
        return try f.manifest(transactionID, records: [], parts: parts)
      }
      let local = try accepted(localID), incoming = try accepted(incomingID)
      try f.journal(localID, local, sequence: 71)
      try f.received(incomingID, incoming, source: .init(deviceID: UUID(), generation: UUID()), sequence: 13)
      try f.read { database in
        let a = try f.store.actionHistoryFact(transactionID: localID, manifestHash: local.hash)
        let b = try f.store.actionHistoryFact(transactionID: incomingID, manifestHash: incoming.hash)
        #expect(a.transactionID != b.transactionID && a.manifestHash != b.manifestHash)
        #expect(a.borrowedSnapshotID == b.borrowedSnapshotID && a.borrowedSnapshotID == database.readSnapshotIdentity)
        for fact in [a, b] {
          let receipt = try #require(fact.receipts.first)
          #expect(receipt.disposition == .completeOriginalBody(body, anchor))
          #expect(receipt.fragments.count == rows.count && receipt.fragments.allSatisfy { $0.manifestPartHash != nil })
          for fragment in receipt.fragments { #expect(fragment.rawPayload == payload.payloads[fragment.address]) }
        }
      }
    }
  }

  @Test(arguments: ["missingUnknownChild", "sourceDigestDroppedUnknownField", "undoVariant"])
  func typedOrCurrentProjectionAndOriginalDigestCannotCertifyDifferentRawBodies(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let original = f.value(id).setting("future", .object(["records": .array([
        .object(["id": .string("known"), "unexpected": .string("author's future bytes")])])]))
      let observed = kind == "undoVariant" ? original.setting("undo", .object(["restored": .number(0),
        "preserved": .array([]), "completedAt": .number(123)])) : original
      var rows = try NotebookRecordCodec.encode(observed, file: file)
      if kind == "missingUnknownChild" { rows.removeAll { $0.collection == "future/records" } }
      let payload = try f.records(rows), manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let sourceBody = kind == "sourceDigestDroppedUnknownField" ? original.setting("future", nil) : original
      _ = try f.originalAnchor(id, body: sourceBody)
      let current = try f.records(NotebookRecordCodec.encode(original, file: file))
      try f.current(current.records, file: file)
      try f.read { _ in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .unprovenClosure(.originalAnchorMismatch))
        #expect(receipt.fragments.count == rows.count)
      }
    }
  }

  @Test(arguments: ["missingOriginal", "missingModel", "missingResult", "pointerVersion", "pointerType",
    "modelID", "modelVersion", "modelUndo", "resultID", "resultVersion", "workspace", "resultUndo"])
  func unavailableAndAlteredSourceAnchorsStayExplicitlyUnproven(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let body = f.value(id).setting("before", .object(["pageIDs": .array([.string(UUID().uuidString)])]))
      let payload = try f.records(NotebookRecordCodec.encode(body, file: file)), manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let version = try notebookActionDeliveryVersion(body), other = String(repeating: "a", count: 64)
      var original: JSONValue = .string(version)
      var model: JSONValue = .object(["id": .string(id.uuidString), "actionVersion": .string(version)])
      var result: JSONValue = .object(["actionID": .string(id.uuidString), "actionVersion": .string(version),
        "basis": .object(["workspaceID": .string(f.workspaceID.uuidString)])])
      switch kind {
      case "pointerVersion": original = .string(other)
      case "pointerType": original = .object(["version": .string(version)])
      case "modelID": model = model.setting("id", .string(UUID().uuidString))
      case "modelVersion": model = model.setting("actionVersion", .string(other))
      case "modelUndo": model = model.setting("undo", .object(["restored": .number(0)]))
      case "resultID": result = result.setting("actionID", .string(UUID().uuidString))
      case "resultVersion": result = result.setting("actionVersion", .string(other))
      case "workspace": result = result.setting("basis", .object(["workspaceID": .string(UUID().uuidString)]))
      case "resultUndo": result = result.setting("undo", .object(["restored": .number(0)]))
      default: break
      }
      _ = try f.originalAnchor(id, body: body, original: original, model: model, result: result)
      if kind.hasPrefix("missing") {
        let prefix = "local/action-results/" + id.uuidString.lowercased() + "/"
        let missing = kind == "missingOriginal" ? prefix + "original.json"
          : prefix + version + (kind == "missingModel" ? "/model.json" : "/result.json")
        try f.writer.run("DELETE FROM records WHERE address=?", [.text(missing + "#")])
      }
      // A fully current receipt and a saved model/result without original.json
      // cannot invoke actionVersionModel's mutable projection fallback.
      try f.current(payload.records, file: file)
      let reason: NotebookActionHistoryObservation.Reason = kind == "missingOriginal" ? .externalizedMembership
        : ["missingModel", "missingResult", "pointerVersion"].contains(kind) ? .originalAnchorUnavailable : .originalAnchorMismatch
      try f.read { _ in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .unprovenClosure(reason))
      }
    }
  }

  @Test(arguments: ["orphan", "ignored", "duplicateMember", "duplicateCollection", "removed"])
  func anOriginalDigestCannotBlessExtraOrAmbiguousFragmentMembership(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let body = f.value(id).setting("before", .object(["pageIDs": .array([.string("a"), .string("b")])]))
      var rows = try NotebookRecordCodec.encode(body, file: file)
      if kind == "orphan" || kind == "ignored" {
        let parent = kind == "orphan" ? file + "#/unlisted" : file + "#"
        rows.append(.init(address: parent + "/other/@extra", file: file, parent: parent,
          collection: "other", member: "extra", position: 0, value: .string("extra"), collections: []))
      } else if kind == "duplicateMember" {
        let candidate = rows.firstIndex { $0.member == "b" }
        let index = try #require(candidate), row = rows[index]
        rows[index] = .init(address: row.address, file: row.file, parent: row.parent, collection: row.collection,
          member: "a", position: row.position, value: row.value, collections: row.collections)
      } else if kind == "duplicateCollection" {
        let candidate = rows.firstIndex { $0.parent == nil }
        let index = try #require(candidate), row = rows[index]
        rows[index] = row.replacing(value: row.value, collections: row.collections + row.collections)
      }
      let payload = try f.records(rows)
      var records = payload.records
      if kind == "removed" { records.append(.init(address: file + "#/other/@removed", blobHash: nil)) }
      let manifest = try f.manifest(transactionID, records: records)
      try f.journal(transactionID, manifest, sequence: 1)
      _ = try f.originalAnchor(id, body: body)
      try f.read { _ in
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .unprovenClosure(.unreferencedFragments))
        #expect(receipt.fragments.count == records.count)
      }
    }
  }

  @Test func shortAliasesRefuseBeforeLongCanonicalAddressesOrBodyCopiesConsumeCredit() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      var nested: JSONValue = .object(["records": .array([.object(["id": .string("leaf"),
        "authored": .string(String(repeating: "x", count: 100 * 1_024))])])])
      for index in (0..<9).reversed() {
        nested = .object(["wrapper-\(index)-~/" + String(repeating: "w", count: 500): nested])
      }
      let body = f.value(id).setting("future", nested)
      let canonical = try NotebookRecordCodec.encode(body, file: file)
      let aliases = canonical.map { row -> NotebookStoredFragment in
        guard row.parent != nil else { return row }
        return .init(address: file + "#/alias/@" + row.member, file: file, parent: row.parent,
          collection: row.collection, member: row.member, position: row.position, value: row.value, collections: row.collections)
      }
      #expect(canonical.contains { $0.address.utf8.count > 4_096 })
      #expect(aliases.allSatisfy { $0.address.utf8.count <= 4_096 })
      let decodedAlias = try NotebookRecordCodec.decode(aliases, root: file + "#")
      #expect(decodedAlias == body, "Codec accepts these aliases and only its later re-encoding exposes the larger addresses")
      let payload = try f.records(aliases), manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let anchor = try f.originalAnchor(id, body: body)
      try f.read { database in
        try database.limitReads(.agentCommand)
        // Warm the existing envelope cache under the same finite owner/cut.
        // Tighten what remains; neither the resolver nor its nested helpers
        // may renew it. Inputs fit, while body+hash copies would exhaust it.
        let hashes = payload.records.compactMap(\.blobHash)
          + [anchor.originalRootHash, anchor.modelRootHash, anchor.resultRootHash]
        for hash in hashes { _ = try database.decodeFragmentEnvelope(database.blob(hash)) }
        #expect(database.decodedFragmentCount == hashes.count)
        try database.limitReads(.init(rows: 65_536, bytes: 32 * 1_024 * 1_024, valueBytes: 8 * 1_024 * 1_024,
          reason: "alias_assembly_credit", jsonDecodeBytes: 3 * 1_024 * 1_024))
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .unprovenClosure(.unreferencedFragments))
        #expect(receipt.fragments.count == aliases.count && fact.borrowedSnapshotID == database.readSnapshotIdentity)
        #expect(sqlite3_total_changes64(database.handle) == 0)
      }
    }
  }

  @Test func anEmptyCollectionCannotAssemblePastTheLogicalDepthAllowance() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let path = ["future"] + Array(repeating: "", count: NotebookJSONAdmission.maximumDepth - 1) + ["records"]
      #expect(path.count == NotebookJSONAdmission.maximumDepth + 1 && fieldKey(path).utf8.count < 4_096)
      // The physical envelope stays shallow. Codec would invent the omitted
      // object wrappers while restoring this empty collection, despite having
      // no children on which the member-depth guard could run.
      let header = NotebookStoredFragment(address: file + "#", file: file, parent: nil,
        collection: "", member: "", position: 0, value: f.value(id), collections: [.init(path: path, kind: .array)])
      // A malformed accepted header must refuse before reconstructing a body;
      // its valid source witness stays within the authored JSON contract.
      _ = try f.originalAnchor(id, body: f.value(id))
      let payload = try f.records([header]), manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let writerChanges = sqlite3_total_changes64(f.writer.handle)
      #expect(throws: NotebookStorageError.limitExceeded("json_decode_depth")) {
        _ = try f.read { database in
          defer { #expect(sqlite3_total_changes64(database.handle) == 0) }
          return try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writerChanges)
    }
  }

  @Test func unlistedInlineMembersStopBeforeAmplifiedOutputOrALaterMalformedSubtree() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let leaves: [JSONValue] = (0..<512).map { .object(["id": .string("leaf-\($0)"), "kept": .bool(true)]) }
      var nested: JSONValue = .object(["items": .array(leaves)])
      for index in (0..<60).reversed() {
        nested = .object(["wrapper-\(index)-~/" + String(repeating: "w", count: 500): nested])
      }
      let duplicate: JSONValue = .object(["records": .array([
        .object(["id": .string("duplicate")]), .object(["id": .string("duplicate")])])])
      let body = f.value(id).setting("before", .object(["pageIDs": .array([])]))
        .setting("future", nested).setting("zLate", duplicate)
      // All inline data is authenticated by the source digest, but no member
      // of future.items occurs in the accepted manifest. A full collector
      // would first retain 512 addresses of about 30 KiB each, then reach the
      // later duplicate subtree. Neither step proves the original closure.
      let header = NotebookStoredFragment(address: file + "#", file: file, parent: nil,
        collection: "", member: "", position: 0, value: body.setting("before", .object([:])),
        collections: [.init(path: ["before", "pageIDs"], kind: .array)])
      let payload = try f.records([header]), manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let anchor = try f.originalAnchor(id, body: body)
      let changes = sqlite3_total_changes64(f.writer.handle)
      try f.read { database in
        try database.limitReads(.agentCommand)
        for hash in payload.records.compactMap(\.blobHash)
          + [anchor.originalRootHash, anchor.modelRootHash, anchor.resultRootHash] {
          _ = try database.decodeFragmentEnvelope(database.blob(hash))
        }
        try database.limitReads(.init(rows: 65_536, bytes: 32 * 1_024 * 1_024, valueBytes: 8 * 1_024 * 1_024,
          reason: "inline_closure_credit", jsonDecodeBytes: 24 * 1_024 * 1_024))
        let fact = try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(fact.receipts.first)
        #expect(receipt.disposition == .unprovenClosure(.unreferencedFragments))
        #expect(receipt.fragments.count == 1 && receipt.fragments.first?.rawPayload == payload.payloads[file + "#"])
        #expect(fact.borrowedSnapshotID == database.readSnapshotIdentity && sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == changes)
    }
  }

  @Test func theCodecCollectorKeepsItsOrderedFragmentsAndVisitorStopsAtTheFirstThrow() throws {
    let file = "example.json", root = file + "#"
    let first: JSONValue = .object(["id": .string("a"), "value": .number(1)])
    let second: JSONValue = .object(["id": .string("b"), "value": .number(2)])
    let body: JSONValue = .object(["records": .array([first, second]), "title": .string("kept")])
    let expected: [NotebookStoredFragment] = [
      .init(address: root + "/records/@a", file: file, parent: root, collection: "records",
        member: "a", position: 0, value: first, collections: []),
      .init(address: root + "/records/@b", file: file, parent: root, collection: "records",
        member: "b", position: 1, value: second, collections: []),
      .init(address: root, file: file, parent: nil, collection: "", member: "", position: 0,
        value: .object(["title": .string("kept")]), collections: [.init(path: ["records"], kind: .array)])]
    let collected = try NotebookRecordCodec.encode(body, file: file)
    var visited: [NotebookStoredFragment] = []
    try NotebookRecordCodec.visitEncodedFragments(body, file: file) { visited.append($0) }
    #expect(collected == expected && visited == expected)
    enum Stop: Error, Equatable { case expected }
    let laterMalformed = body.setting("zLate", .object(["records": .array([first, first])]))
    var emissions = 0
    #expect(throws: Stop.expected) {
      try NotebookRecordCodec.visitEncodedFragments(laterMalformed, file: file) { fragment in
        emissions += 1
        #expect(fragment == expected[0])
        throw Stop.expected
      }
    }
    #expect(emissions == 1, "The visitor's refusal must precede the later duplicate-ID error")
  }

  @Test(arguments: ["differentAcceptedHash", "missingPart", "wrongPartTransaction", "duplicateFragment", "missingFragment", "corruptFragment", "corruptManifest"])
  func conflictingAndUnavailableOriginalProofRefuses(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let payload = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      var manifest = try f.manifest(transactionID, records: payload.records)
      let expected: NotebookStorageError
      switch kind {
      case "differentAcceptedHash":
        let other = try f.manifest(transactionID, records: [.init(address: f.file(id) + "#", blobHash: String(repeating: "a", count: 64))])
        try f.received(transactionID, other, source: .init(deviceID: UUID(), generation: UUID()), sequence: 1)
        expected = .transactionConflict
      case "missingPart":
        let hash = String(repeating: "b", count: 64)
        manifest = try f.manifest(transactionID, records: [], parts: [hash]); expected = .blobMissing(hash)
      case "wrongPartTransaction":
        let part = try f.manifest(UUID(), records: payload.records)
        manifest = try f.manifest(transactionID, records: [], parts: [part.hash])
        expected = .invalidTransaction("manifest identity or duplicate addresses")
      case "duplicateFragment":
        let first = try f.manifest(transactionID, records: payload.records)
        let secondData = try JSONValue.encode(NotebookChangeManifest(transactionID: transactionID,
          workspaceID: f.workspaceID, records: payload.records)).setting("extra", .bool(true))
        let secondHash = try f.writer.putBlob(NotebookStore.storageEncoder.encode(secondData))
        #expect(first.hash != secondHash)
        manifest = try f.manifest(transactionID, records: [], parts: [first.hash, secondHash]); expected = .transactionConflict
      case "missingFragment":
        let hash = String(repeating: "c", count: 64)
        manifest = try f.manifest(transactionID, records: [.init(address: f.file(id) + "#", blobHash: hash)])
        expected = .blobMissing(hash)
      case "corruptFragment":
        try f.writer.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data("substituted original fragment".utf8)), .text(payload.records[0].blobHash!)])
        expected = .blobHashMismatch
      default:
        try f.writer.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data(repeating: 32, count: manifest.bytes)), .text(manifest.hash)])
        expected = .blobHashMismatch
      }
      try f.journal(transactionID, manifest, sequence: 1)
      #expect(throws: expected) {
        _ = try f.read { _ in try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash) }
      }
    }
  }

  @Test func pointAndSemanticSeekShareAcceptanceMarkersAndTheBorrowedCut() throws {
    try fixture { f in
      let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
      let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
      let thirdID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
      let id = UUID(), source = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let payload = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      let first = try f.manifest(firstID, records: payload.records), second = try f.manifest(secondID, records: payload.records)
      try f.journal(firstID, first, sequence: 42)
      try f.received(firstID, first, source: source, sequence: 7)
      try f.received(secondID, second, source: source, sequence: 99)
      let oldCursor = try f.read { database in
        let occurrence = try NotebookActionHistoryInventory.occurrence(in: database, workspaceID: f.workspaceID, transactionID: firstID)
        let firstPage = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, afterTransactionID: nil, limit: 1)
        #expect(occurrence == firstPage.occurrences.first)
        #expect(occurrence?.localJournal == .init(sequence: 42, manifestByteCount: first.bytes))
        #expect(occurrence?.firstReceived == .init(source: source, senderSequence: 7))
        try f.journal(thirdID, f.manifest(thirdID, records: payload.records), sequence: 43)
        let seek = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, afterTransactionID: firstID)
        #expect(seek.occurrences.map(\.transactionID) == [secondID])
        #expect(seek.occurrences.first?.localJournal == nil && seek.occurrences.first?.firstReceived?.senderSequence == 99)
        #expect(seek.borrowedSnapshotID == firstPage.borrowedSnapshotID)
        return try #require(firstPage.next)
      }
      try f.read { database in
        #expect(throws: NotebookStorageError.invalidTransaction("action history inventory read cut changed")) {
          _ = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, after: oldCursor)
        }
        let seek = try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, afterTransactionID: firstID)
        #expect(seek.occurrences.map(\.transactionID) == [secondID, thirdID])
        #expect(seek.borrowedSnapshotID == database.readSnapshotIdentity)
      }
    }
  }

  @Test(arguments: ["empty", "null", "malformedHash"])
  func exactAndSeekAdmissionDoNotHideMalformedAcceptedMarkers(_ kind: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let payload = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      let manifest = try f.manifest(transactionID, records: payload.records)
      if kind == "malformedHash" {
        try f.writer.run("INSERT INTO received_transactions VALUES(?,?,?,1)", [.text(transactionID.uuidString.lowercased()),
          .text(String(repeating: "x", count: 1_000_000)), .text(UUID().uuidString.lowercased())])
      } else {
        try f.journal(transactionID, manifest, sequence: 1)
        try f.writer.run("INSERT INTO received_transactions VALUES(?,?,?,1)", [kind == "empty" ? .text("") : .null,
          .text(manifest.hash), .text(UUID().uuidString.lowercased())])
      }
      #expect(throws: NotebookStorageError.corruptRecord("action history inventory marker")) {
        _ = try f.read { database in
          try NotebookActionHistoryInventory.occurrence(in: database, workspaceID: f.workspaceID, transactionID: transactionID)
        }
      }
      #expect(throws: NotebookStorageError.corruptRecord("action history inventory marker")) {
        _ = try f.read { database in
          try NotebookActionHistoryInventory.page(in: database, workspaceID: f.workspaceID, afterTransactionID: nil)
        }
      }
    }
  }

  @Test func enclosingCancellationAndJSONAndSQLBudgetsCannotBeRenewed() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let payload = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      #expect(throws: NotebookStorageError.limitExceeded("read_sql_work")) {
        _ = try f.read { database in
          try database.limitReads(.init(rows: 100, bytes: 1_048_576, valueBytes: 1_048_576,
            reason: "outer_sql", sqlSteps: 0))
          return try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        }
      }
      #expect(throws: NotebookStorageError.limitExceeded("json_decode_memory")) {
        _ = try f.read { database in
          try database.limitReads(.init(rows: 100, bytes: 1_048_576, valueBytes: 1_048_576,
            reason: "outer_json", jsonDecodeBytes: 0))
          return try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        }
      }
      let cancellation = NotebookReadCancellation()
      #expect(throws: CancellationError.self) {
        _ = try f.read(cancellation: cancellation) { _ in
          cancellation.cancel()
          return try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: manifest.hash)
        }
      }
    }
  }

  @Test(arguments: [false, true])
  func aTightenedJSONLeaseRefusesBeforeColdPortableInkValidationOrExpansion(_ expanding: Bool) throws {
    try fixture { f in
      let samples: [SpatialInkSample] = (0..<64).map { (index: Int) -> SpatialInkSample in
        let x = Double(index * index % 197), y = Double(index * 37 % 113)
        let timeOffset = Double(index) / 128, force = Double(index * 17 % 67) / 67
        return SpatialInkSample(point: .init(x: x, y: y), timeOffset: timeOffset,
          width: 4, opacity: 0.5, force: force, azimuth: 0, altitude: 1)
      }
      let portable = try InkMeasurements(samples, revision: UUID()).encodedRelations()
      let id = UUID(), file = f.file(id)
      let body = f.value(id).setting("before", .object(["pageIDs": .array([]),
        "measurements": .string(portable.base64EncodedString())]))
      let payload = try f.records(NotebookRecordCodec.encode(body, file: file))
      let rootData = try #require(payload.payloads[file + "#"])
      let raw = try JSONDecoder().decode(NotebookStoredFragment.self, from: rootData)
      let inkHash = try #require(raw.inkBodyHashes.first), stored = try f.writer.blob(inkHash)
      #expect(stored.starts(with: Data("NIB1".utf8)) && stored.count > 1_024)
      #expect(rootData.count + portable.count * 4 / 3 + 4 < 8 * 1_024 * 1_024,
        "The SQL value ceiling must allow this body, isolating JSON admission")
      let envelopeCost = try NotebookJSONAdmission.allocationCost(rootData, maximumBytes: Int.max)
      final class Trace { var bodyCopies = 0 }
      let trace = Trace()
      #expect(throws: NotebookStorageError.limitExceeded("ink_json_before_copy")) {
        try f.read { database in
          try database.limitReads(.init(rows: 100, bytes: 1_048_576, valueBytes: 8 * 1_024 * 1_024,
            reason: "ink_json_before_copy", jsonDecodeBytes: envelopeCost))
          let decoding = database.inkDecoding
          sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
            let trace = Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue(), statement = OpaquePointer(pointer!)
            if sqlite3_column_count(statement) == 1, sqlite3_column_type(statement, 0) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, 0) > 1_024 { trace.bodyCopies += 1 }
            return 0
          }, Unmanaged.passUnretained(trace).toOpaque())
          defer {
            _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) }
            #expect(decoding.entryCount == 0 && decoding.retainedBytes == 0)
            #expect(decoding.storedOutputBody(inkHash) == nil && decoding.storedBody(inkHash) == nil)
          }
          var remaining: Int64 = 32 * 1_024 * 1_024
          _ = try database.decodedStoredFragment(from: rootData, remainingBytes: &remaining,
            budget: "history_ink_expansion", expandingInk: expanding)
        }
      }
      #expect(trace.bodyCopies == 0)
    }
  }

  @Test func oversizedOriginalBlobRefusesBeforeAnyBodyColumnIsCopied() throws {
    try fixture { f in
      let transactionID = UUID(), hash = String(repeating: "d", count: 64)
      try f.writer.run("INSERT INTO blobs(hash,data) VALUES(?,zeroblob(9437184))", [.text(hash)])
      try f.received(transactionID, .init(hash: hash, bytes: 9_437_184), source: .init(deviceID: UUID(), generation: UUID()), sequence: 1)
      final class Trace { var blobColumns = 0 }
      let trace = Trace()
      #expect(throws: NotebookStorageError.limitExceeded("action_history_fact_blob")) {
        _ = try f.read { database in
          sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
            let trace = Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue(), statement = OpaquePointer(pointer!)
            for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_BLOB {
              trace.blobColumns += 1
            }
            return 0
          }, Unmanaged.passUnretained(trace).toOpaque())
          defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
          return try f.store.actionHistoryFact(transactionID: transactionID, manifestHash: hash)
        }
      }
      #expect(trace.blobColumns == 0)
    }
  }

  @Test func rawChunksAuthenticateLargeReceiptsWithoutAFullValueOrInkDecode() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let body = f.value(id).setting("futureReceipt", .object(["unknownActor": .null,
        "large": .string(String(repeating: "quoted \" } ] \\ 🖋️", count: 500_000))]))
      let payload = try f.records(NotebookRecordCodec.encode(body, file: f.file(id)), unknownEnvelope: true)
      let raw = try #require(payload.payloads[f.file(id) + "#"])
      #expect(raw.count > 8 * 1_024 * 1_024)
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.received(transactionID, manifest, source: .init(deviceID: UUID(), generation: UUID()), sequence: 73)
      let otherTransaction = UUID()
      let secondManifest = try f.manifest(otherTransaction, records: payload.records)
      try f.journal(otherTransaction, secondManifest, sequence: 19)
      let anchor = try f.originalAnchor(id, body: body)
      let later = try f.records(NotebookRecordCodec.encode(f.value(id), file: f.file(id)))
      try f.current(later.records, file: f.file(id))
      let writes = sqlite3_total_changes64(f.writer.handle)
      final class Trace { var largestBlob = 0, chunks = 0 }
      let trace = Trace()
      try f.read { database in
        try database.limitReads(.init(rows: 256, bytes: 32 * 1_024 * 1_024,
          valueBytes: 1_024 * 1_024, reason: "raw_chunk_credit", jsonDecodeBytes: 2 * 1_024 * 1_024))
        sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
          let trace = Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue(), statement = OpaquePointer(pointer!)
          for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_BLOB {
            let count = Int(sqlite3_column_bytes(statement, column))
            trace.largestBlob = max(trace.largestBlob, count)
            if count == 1_024 * 1_024 { trace.chunks += 1 }
          }
          return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
        let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash, receiptID: id)
        let receipt = try #require(proof.receipts.first)
        #expect(proof.borrowedSnapshotID == database.readSnapshotIdentity && proof.transactionID == transactionID)
        #expect(receipt.status == .authenticatedDeclaredClosure && receipt.logicalBinding == .notEvaluated)
        #expect(receipt.fragmentCount == 1 && receipt.fragmentBytes == Int64(raw.count) && receipt.fragmentSetHash != nil)
        #expect(receipt.sourceOriginal.status == .authenticatedSourceLocalRoots)
        #expect(receipt.sourceOriginal.originalVersion == anchor.originalVersion)
        #expect(receipt.sourceOriginal.original?.hash == anchor.originalRootHash)
        #expect(receipt.sourceOriginal.model?.hash == anchor.modelRootHash && receipt.sourceOriginal.result?.hash == anchor.resultRootHash)
        #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0)
        let second = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: otherTransaction, manifestHash: secondManifest.hash, receiptID: id)
        #expect(second.transactionID != proof.transactionID && second.borrowedSnapshotID == proof.borrowedSnapshotID)
        #expect(second.receipts.first?.fragmentBytes == receipt.fragmentBytes
          && second.receipts.first?.fragmentSetHash != receipt.fragmentSetHash,
          "Equal raw bodies do not collapse different accepted occurrences")
        let metadata = try NotebookStore.storageEncoder.encode(proof)
        #expect(metadata.count < 16_384 && !String(decoding: metadata, as: UTF8.self).contains("unknownActor"))
        #expect(sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(trace.chunks >= 8 && trace.largestBlob == 1_024 * 1_024)
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: [0, 1, 2])
  func rawManifestMembershipNeverPromotesEmptyOrMissingLastToLogicalProof(_ childCount: Int) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let body = f.value(id).setting("before", .object(["pageIDs": .array([
        .string(UUID().uuidString), .string(UUID().uuidString)])]))
      let full = try NotebookRecordCodec.encode(body, file: f.file(id))
      let root = try #require(full.first { $0.parent == nil })
      var children: [NotebookStoredFragment] = []
      for fragment in full {
        if fragment.parent != nil { children.append(fragment) }
      }
      let declared: [NotebookStoredFragment] = [root] + Array(children.sorted { $0.position < $1.position }.prefix(childCount))
      let payload = try f.records(declared)
      let part = try f.manifest(transactionID, records: payload.records, format: 25)
      let manifest = try f.manifest(transactionID, records: [], parts: [part.hash], format: 25)
      try f.journal(transactionID, manifest, sequence: 19)
      try f.received(transactionID, manifest, source: .init(deviceID: UUID(), generation: UUID()), sequence: 73)
      _ = try f.originalAnchor(id, body: body)
      try f.read { database in
        let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(proof.receipts.first)
        #expect(proof.manifestFormat == 25 && proof.manifestParts == [.init(hash: part.hash, byteCount: Int64(part.bytes))])
        #expect(proof.receipts.count == 1 && receipt.fragmentCount == childCount + 1)
        #expect(receipt.status == .authenticatedDeclaredClosure && receipt.fragmentSetHash != nil)
        #expect(receipt.logicalBinding == .externalizedMembership,
          "The exact declared set does not prove the original logical collection's missing last member")
        #expect(receipt.sourceOriginal.status == .authenticatedSourceLocalRoots)
        #expect(database.decodedFragmentCount == 0 && sqlite3_total_changes64(database.handle) == 0)
      }
    }
  }

  @Test(arguments: ["present", "missing", "tampered", "foreign"])
  func rawInversePartsAndInkKeepTypedScopeWithoutPortableExpansion(_ condition: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), page = UUID(), file = pageFile(page)
      let samples: [SpatialInkSample] = (0..<64).map { (index: Int) -> SpatialInkSample in
        let x: Double = Double(index * index % 197)
        let y: Double = Double(index * 37 % 113)
        let timeOffset: Double = Double(index) / 128
        let force: Double = Double(index * 17 % 67) / 67
        return SpatialInkSample(point: .init(x: x, y: y), timeOffset: timeOffset,
          width: 4, opacity: 0.5, force: force, azimuth: 0, altitude: 1)
      }
      let portable = try InkMeasurements(samples, revision: UUID()).encodedRelations()
      let stroke = UUID().uuidString.lowercased(), address = file + "#/strokes/@" + stroke
      let material = NotebookStoredFragment(address: address, file: file, parent: file + "#",
        collection: "strokes", member: stroke, position: 0,
        value: .object(["measurements": .string(portable.base64EncodedString())]), collections: [])
      let materialRecords = try f.records([material])
      let materialRaw = try #require(materialRecords.payloads[address])
      let physical = try JSONDecoder().decode(NotebookStoredFragment.self, from: materialRaw)
      let inkHash = try #require(physical.inkBodyHashes.first)
      let part = NotebookLifecycleInversePart(format: 1,
        workspaceID: condition == "foreign" ? UUID() : f.workspaceID, actionID: id, ordinal: 0,
        records: [.init(address: address, beforeHash: materialRecords.records[0].blobHash, afterHash: nil)])
      let partHash = try f.writer.putBlob(NotebookStore.storageEncoder.encode(part))
      let inverse = NotebookLifecycleInverseRoot(format: 1, workspaceID: f.workspaceID,
        actionID: id, recordCount: 1, parts: [partHash])
      let inverseHash = try f.writer.putBlob(NotebookStore.storageEncoder.encode(inverse))
      let body = f.value(id).setting("lifecycleInverse", try .encode(
        NotebookLifecycleInverseReference(rootHash: inverseHash, recordCount: 1)))
      let payload = try f.records(NotebookRecordCodec.encode(body, file: f.file(id)))
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      if condition == "missing" { try f.writer.run("DELETE FROM blobs WHERE hash=?", [.text(inkHash)]) }
      if condition == "tampered" { try f.writer.run("UPDATE blobs SET data=x'0001' WHERE hash=?", [.text(inkHash)]) }
      let writes = sqlite3_total_changes64(f.writer.handle)
      if condition == "tampered" || condition == "foreign" {
        let expected: NotebookStorageError = condition == "tampered" ? .blobHashMismatch : .invalidTransaction("lifecycle inverse part identity")
        #expect(throws: expected) {
          _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash) }
        }
      } else {
        try f.read { database in
          let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash)
          let receipt = try #require(proof.receipts.first)
          if condition == "missing" {
            #expect(receipt.status == .unproven(.missingBlob) && receipt.fragmentSetHash == nil && receipt.dependencySetHash == nil)
          } else {
            #expect(receipt.status == .authenticatedDeclaredClosure && receipt.dependencyCount == 4)
            #expect(receipt.dependencyBytes > Int64(portable.count) && receipt.dependencySetHash != nil)
          }
          #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0)
          #expect(database.inkDecoding.storedBody(inkHash) == nil && sqlite3_total_changes64(database.handle) == 0)
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["absent", "foreignID", "foreignWorkspace", "mixedVersion", "undo", "orphan"])
  func rawSourceAnchorsKeepUnknownUnavailableAndForeignFactsExplicit(_ condition: String) throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), body = f.value(id)
      let payload = try f.records(NotebookRecordCodec.encode(body, file: f.file(id)))
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.received(transactionID, manifest, source: .init(deviceID: UUID(), generation: UUID()), sequence: 42)
      // A valid current receipt is not a source-local immutable original root.
      try f.current(payload.records, file: f.file(id))
      let version = try notebookActionDeliveryVersion(body)
      if condition != "absent" {
        var model: JSONValue = .object(["id": .string(id.uuidString), "actionVersion": .string(version)])
        if condition == "foreignID" { model = model.setting("id", .string(UUID().uuidString)) }
        if condition == "mixedVersion" { model = model.setting("actionVersion", .string(String(repeating: "f", count: 64))) }
        if condition == "undo" { model = model.setting("undo", .object(["restored": .number(0)])) }
        let result: JSONValue = .object(["actionID": .string(id.uuidString), "actionVersion": .string(version),
          "basis": .object(["workspaceID": .string((condition == "foreignWorkspace" ? UUID() : f.workspaceID).uuidString)])])
        _ = try f.originalAnchor(id, body: body, model: model, result: result)
        if condition == "orphan" {
          let file = "local/action-results/" + id.uuidString.lowercased() + "/" + version + "/model.json"
          let child = NotebookStoredFragment(address: file + "#/future/items/@extra", file: file,
            parent: file + "#", collection: "future/items", member: "extra", position: 0, value: .null, collections: [])
          try f.current(f.records([child]).records, file: file)
        }
      }
      try f.read { database in
        let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash)
        let receipt = try #require(proof.receipts.first)
        let reason: NotebookHistoryPhysicalClosure.Reason = condition == "absent" ? .originalAnchorUnavailable
          : condition == "orphan" ? .orphanAnchor : .originalAnchorMismatch
        #expect(receipt.status == .authenticatedDeclaredClosure && receipt.sourceOriginal.status == .unproven(reason))
        #expect(receipt.logicalBinding == .notEvaluated && sqlite3_total_changes64(database.handle) == 0)
      }
    }
  }

  @Test func rawOccurrenceRefusalsBorrowTheCutAndCannotRenewItsCanceledOrExhaustedLease() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID()
      let body = f.value(id).setting("large", .string(String(repeating: "x", count: 2 * 1_024 * 1_024)))
      let payload = try f.records(NotebookRecordCodec.encode(body, file: f.file(id)))
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.writer.run("INSERT INTO manifests(hash,transaction_id) VALUES(?,?)", [.text(manifest.hash), .text(transactionID.uuidString.lowercased())])
      #expect(throws: NotebookStorageError.invalidTransaction("unaccepted action history occurrence")) {
        _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash) }
      }
      try f.journal(transactionID, manifest, sequence: 1)
      #expect(throws: NotebookStorageError.invalidTransaction("action history workspace changed")) {
        _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: UUID(),
          transactionID: transactionID, manifestHash: manifest.hash) }
      }
      let writes = sqlite3_total_changes64(f.writer.handle)
      #expect(throws: NotebookStorageError.limitExceeded("raw_chunk_credit")) {
        _ = try f.read { database in
          try database.limitReads(.init(rows: 256, bytes: 1_024 * 1_024,
            valueBytes: 1_024 * 1_024, reason: "raw_chunk_credit", jsonDecodeBytes: 2 * 1_024 * 1_024))
          do {
            _ = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
              transactionID: transactionID, manifestHash: manifest.hash)
            Issue.record("An oversized cut unexpectedly completed")
          } catch let error as NotebookStorageError { #expect(error == .limitExceeded("raw_chunk_credit")) }
          #expect(database.decodedFragmentCount == 0 && sqlite3_total_changes64(database.handle) == 0)
          try database.limitReads(.agentCommand)
        }
      }
      let cancellation = NotebookReadCancellation()
      final class Trace {
        let cancellation: NotebookReadCancellation
        init(_ cancellation: NotebookReadCancellation) { self.cancellation = cancellation }
      }
      let trace = Trace(cancellation)
      #expect(throws: CancellationError.self) {
        _ = try f.read(cancellation: cancellation) { database in
          sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
            let trace = Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue(), statement = OpaquePointer(pointer!)
            if sqlite3_column_count(statement) == 1, sqlite3_column_type(statement, 0) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, 0) == 1_024 * 1_024 { trace.cancellation.cancel() }
            return 0
          }, Unmanaged.passUnretained(trace).toOpaque())
          defer { _ = withExtendedLifetime(trace) { sqlite3_trace_v2(database.handle, 0, nil, nil) } }
          return try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash)
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test func rawReceiptHeadersBindTheExactAcceptedAddressBytes() throws {
    try fixture { f in
      let id = UUID(), transactionID = UUID(), file = f.file(id)
      let composed = "\u{e9}", decomposed = "e\u{301}"
      #expect(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8))
      // Codec externalizes owned records arrays by actual member identity;
      // an arbitrary dictionary stays inline regardless of its authored size.
      let body = f.value(id).setting("future", .object(["records": .array([
        .object(["id": .string(composed), "value": .number(7)])])]))
      let fragments = try NotebookRecordCodec.encode(body, file: file)
      let root = try #require(fragments.first { $0.parent == nil })
      let child = try #require(fragments.first { $0.parent != nil })
      let foreign = NotebookStoredFragment(address: file + "#/future/records/@" + decomposed,
        file: child.file, parent: child.parent, collection: child.collection, member: decomposed,
        position: child.position, value: child.value, collections: child.collections)
      let payload = try f.records([root, foreign])
      let declared = [payload.records[0], NotebookRecordMutation(address: child.address, blobHash: payload.records[1].blobHash)]
      let manifest = try f.manifest(transactionID, records: declared)
      try f.journal(transactionID, manifest, sequence: 1)
      let writes = sqlite3_total_changes64(f.writer.handle)
      #expect(throws: NotebookStorageError.invalidTransaction("history physical fragment identity")) {
        _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash) }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["present", "missingResource", "tamperedResource"])
  func rawDeclaredRecordsIncludeNonReceiptPayloadsRemovalsAndResourceClosure(_ condition: String) throws {
    try fixture { f in
      let transactionID = UUID(), page = UUID(), document = UUID()
      let resourceBytes = Data("offline resource исходный 🖋️".utf8)
      let resourceHash = try f.writer.putBlob(resourceBytes)
      let resource = NotebookProgramPackage.File(path: "original.txt",
        mimeType: NotebookProgramPackage.mimeType(for: "original.txt"), byteCount: Int64(resourceBytes.count),
        parts: [.init(sha256: resourceHash, byteCount: resourceBytes.count)])
      let pageRecords = try f.records(NotebookRecordCodec.encode(
        .object(["source": .string("private unchanged <literal> 🖋️")]), file: pageFile(page)))
      let file = "documents/" + document.uuidString.lowercased() + ".json"
      let addressed = NotebookStoredFragment(address: file + "#/files/@original.txt", file: file,
        parent: file + "#", collection: "files", member: "original.txt", position: 0,
        value: .object(["resource": try .encode(resource)]), collections: [])
      let fileRecords = try f.records([addressed])
      let removal = NotebookRecordMutation(address: "obsolete-note.json#", blobHash: nil)
      let firstPart = try f.manifest(transactionID, records: pageRecords.records)
      let secondPart = try f.manifest(transactionID, records: fileRecords.records + [removal])
      let manifest = try f.manifest(transactionID, records: [], parts: [firstPart.hash, secondPart.hash])
      try f.journal(transactionID, manifest, sequence: 1)
      if condition == "missingResource" { try f.writer.run("DELETE FROM blobs WHERE hash=?", [.text(resourceHash)]) }
      if condition == "tamperedResource" { try f.writer.run("UPDATE blobs SET data=x'0001' WHERE hash=?", [.text(resourceHash)]) }
      let writes = sqlite3_total_changes64(f.writer.handle)
      if condition == "tamperedResource" {
        #expect(throws: NotebookStorageError.blobHashMismatch) {
          _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash) }
        }
      } else {
        try f.read { database in
          let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash)
          #expect(proof.receipts.isEmpty && proof.declaredRecords.recordCount == 3
            && proof.declaredRecords.removalCount == 1)
          let bytes = pageRecords.payloads.values.reduce(Int64(0)) { $0 + Int64($1.count) }
            + fileRecords.payloads.values.reduce(Int64(0)) { $0 + Int64($1.count) }
          #expect(proof.declaredRecords.payloadBytes == bytes)
          if condition == "present" {
            #expect(proof.declaredRecords.status == .authenticatedDeclaredClosure
              && proof.declaredRecords.recordSetHash != nil && proof.declaredRecords.dependencySetHash != nil)
            #expect(proof.declaredRecords.dependencyCount == 1
              && proof.declaredRecords.dependencyBytes == Int64(resourceBytes.count))
          } else {
            #expect(proof.declaredRecords.status == .unproven(.missingBlob)
              && proof.declaredRecords.recordSetHash == nil && proof.declaredRecords.dependencySetHash == nil)
          }
          let metadata = try NotebookStore.storageEncoder.encode(proof)
          #expect(!String(decoding: metadata, as: UTF8.self).contains("private unchanged"))
          #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0
            && sqlite3_total_changes64(database.handle) == 0)
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["present", "missing", "tampered"])
  func rawNonReceiptInkDependenciesCannotBeSkipped(_ condition: String) throws {
    try fixture { f in
      let transactionID = UUID(), page = UUID(), file = pageFile(page), stroke = UUID().uuidString.lowercased()
      let samples: [SpatialInkSample] = (0..<64).map { (index: Int) -> SpatialInkSample in
        let x: Double = Double(index * index % 197)
        let y: Double = Double(index * 37 % 113)
        let timeOffset: Double = Double(index) / 128
        let force: Double = Double(index * 17 % 67) / 67
        return SpatialInkSample(point: .init(x: x, y: y), timeOffset: timeOffset,
          width: 4, opacity: 0.5, force: force, azimuth: 0, altitude: 1)
      }
      let portable = try InkMeasurements(samples, revision: UUID()).encodedRelations()
      let material = NotebookStoredFragment(address: file + "#/strokes/@" + stroke, file: file, parent: file + "#",
        collection: "strokes", member: stroke, position: 0,
        value: .object(["measurements": .string(portable.base64EncodedString())]), collections: [])
      let payload = try f.records([material])
      let raw = try #require(payload.payloads[material.address])
      let stored = try JSONDecoder().decode(NotebookStoredFragment.self, from: raw)
      let inkHash = try #require(stored.inkBodyHashes.first)
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      if condition == "missing" { try f.writer.run("DELETE FROM blobs WHERE hash=?", [.text(inkHash)]) }
      if condition == "tampered" { try f.writer.run("UPDATE blobs SET data=x'0001' WHERE hash=?", [.text(inkHash)]) }
      let writes = sqlite3_total_changes64(f.writer.handle)
      if condition == "tampered" {
        #expect(throws: NotebookStorageError.blobHashMismatch) {
          _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash) }
        }
      } else {
        try f.read { database in
          let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash)
          let status: NotebookHistoryPhysicalClosure.Status = condition == "present" ? .authenticatedDeclaredClosure
            : .unproven(.missingBlob)
          #expect(proof.receipts.isEmpty && proof.declaredRecords.status == status)
          if condition == "present" {
            #expect(proof.declaredRecords.dependencyCount == 1 && proof.declaredRecords.dependencyBytes > 0)
          } else { #expect(proof.declaredRecords.recordSetHash == nil && proof.declaredRecords.dependencySetHash == nil) }
          #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0
            && sqlite3_total_changes64(database.handle) == 0)
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test func rawNonReceiptChunkRefusalLatchesTheSameCutAndAFreshCutRecovers() throws {
    try fixture { f in
      let transactionID = UUID(), file = pageFile(UUID())
      let payload = try f.records(NotebookRecordCodec.encode(
        .object(["source": .string(String(repeating: "raw", count: 700_000))]), file: file))
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let writes = sqlite3_total_changes64(f.writer.handle)
      #expect(throws: NotebookStorageError.limitExceeded("declared_chunk_credit")) {
        _ = try f.read { database in
          try database.limitReads(.init(rows: 256, bytes: 128 * 1_024,
            valueBytes: 1_024 * 1_024, reason: "declared_chunk_credit", jsonDecodeBytes: 2 * 1_024 * 1_024))
          do {
            _ = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
              transactionID: transactionID, manifestHash: manifest.hash)
            Issue.record("An uncharged non-receipt payload completed")
          } catch let error as NotebookStorageError { #expect(error == .limitExceeded("declared_chunk_credit")) }
          try database.limitReads(.agentCommand)
        }
      }
      try f.read { database in
        let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash)
        #expect(proof.declaredRecords.status == .authenticatedDeclaredClosure && proof.receipts.isEmpty)
        #expect(database.decodedFragmentCount == 0 && sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["programs", "missingProgram", "resources", "missingResource", "plain", "noHeads", "nullHeads"])
  func rawCausalProjectionChecksLosingAssetsAndSkipsTheLargeWinningAuthoredValue(_ condition: String) throws {
    try fixture { f in
      let transactionID = UUID(), isDocument = condition == "resources" || condition == "missingResource"
      let file = isDocument ? "documents/" + UUID().uuidString.lowercased() + ".json" : pageFile(UUID())
      let key = (isDocument ? "files" : "elements") + "/retained/content"
      var values: [JSONValue] = [], assetHashes: [String] = []
      for label in ["losing-a", "losing-b"] {
        let bytes = Data(("<p>" + label + " исходный</p>").utf8)
        let hash = try f.writer.putBlob(bytes); assetHashes.append(hash)
        let resource = NotebookProgramPackage.File(path: "index.html", mimeType: "text/html", byteCount: Int64(bytes.count),
          parts: [.init(sha256: hash, byteCount: bytes.count)])
        if isDocument { values.append(.object(["resource": try .encode(resource)])) }
        else {
          let package = NotebookProgramPackage(html: "index.html", files: [resource])
          let packageHash = try f.writer.putBlob(package.canonicalData())
          values.append(.object(["programPackage": .string(packageHash)]))
        }
      }
      let privateText = String(repeating: "private retained text 🖋️ ", count: 70_000)
      let textValue = JSONValue.object(["source": .string(privateText)])
      let firstValue = condition == "plain" ? textValue : values[0]
      let secondValue = condition == "plain" ? textValue : values[1]
      let first = ContentFieldVersion(stamp: .init(counter: 3, actor: UUID()), human: false).retainingValue(firstValue)
      let second = ContentFieldVersion(stamp: .init(counter: 3, actor: UUID()), human: false).retainingValue(secondValue)
      let winner = ContentFieldVersion(stamp: .init(counter: 3, actor: UUID()), human: true).retainingValue(textValue)
      let joined = try first.joining(second).joining(winner)
      var raw = try JSONValue.encode(joined)
      if condition == "noHeads" || condition == "nullHeads" {
        raw = try .encode(ContentFieldVersion(stamp: .init(counter: 4, actor: UUID()), human: true))
        raw = raw.setting("futureAuthoredText", .string(privateText))
        if condition == "nullHeads" { raw = raw.setting("heads", .null) }
      }
      let fragment = NotebookStoredFragment(address: file + "#/collaboration/fields/@" + fieldKey([key]),
        file: file, parent: file + "#", collection: "collaboration/fields", member: key,
        position: 0, value: raw, collections: [])
      let payload = try f.records([fragment])
      #expect(try #require(payload.payloads[fragment.address]).count > 1_024 * 1_024)
      let manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      if condition == "missingProgram" || condition == "missingResource" {
        try f.writer.run("DELETE FROM blobs WHERE hash=?", [.text(assetHashes[0])])
      }
      let writes = sqlite3_total_changes64(f.writer.handle)
      try f.read { database in
        try database.limitReads(.init(rows: 256, bytes: 16 * 1_024 * 1_024, valueBytes: 1_024 * 1_024,
          reason: "causal_metadata_credit", jsonDecodeBytes: 2 * 1_024 * 1_024))
        let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash)
        #expect(proof.receipts.isEmpty && proof.declaredRecords.recordCount == 1)
        if condition == "missingProgram" || condition == "missingResource" {
          #expect(proof.declaredRecords.status == .unproven(.missingBlob)
            && proof.declaredRecords.recordSetHash == nil && proof.declaredRecords.dependencySetHash == nil)
        } else {
          let expectedCount = condition == "programs" ? 4 : (condition == "resources" ? 2 : 0)
          #expect(proof.declaredRecords.status == .authenticatedDeclaredClosure
            && proof.declaredRecords.dependencyCount == expectedCount)
          #expect(proof.declaredRecords.recordSetHash != nil && proof.declaredRecords.dependencySetHash != nil)
        }
        let encoded = try NotebookStore.storageEncoder.encode(proof)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private retained text"))
        #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0
          && sqlite3_total_changes64(database.handle) == 0)
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["257", "object", "empty", "stamp", "human", "observed", "hasValue"])
  func rawCausalProjectionRefusesMalformedMetadataAndUnseenExtraHeads(_ condition: String) throws {
    try fixture { f in
      let transactionID = UUID(), file = pageFile(UUID()), key = "elements/retained/content"
      let version = ContentFieldVersion(stamp: .init(counter: 3, actor: UUID()), human: true)
        .retainingValue(.object(["source": .string("ordinary text without assets")]))
      var raw = try JSONValue.encode(version)
      let head = try #require(raw["heads"]?.array.first)
      switch condition {
      case "257": raw = raw.setting("heads", .array(Array(repeating: head, count: 257)))
      case "object": raw = raw.setting("heads", .object(["0": head, "unseen": head]))
      case "empty": raw = raw.setting("heads", .array([]))
      case "stamp": raw = raw.setting("stamp", .string("not a causal stamp"))
      case "human": raw = raw.setting("human", .string("true"))
      case "observed": raw = raw.setting("observed", .object(["foreign-actor": .number(3)]))
      default: raw = raw.setting("heads", .array([head.setting("hasValue", .string("true"))]))
      }
      let fragment = NotebookStoredFragment(address: file + "#/collaboration/fields/@" + fieldKey([key]),
        file: file, parent: file + "#", collection: "collaboration/fields", member: key,
        position: 0, value: raw, collections: [])
      let payload = try f.records([fragment]), manifest = try f.manifest(transactionID, records: payload.records)
      try f.journal(transactionID, manifest, sequence: 1)
      let writes = sqlite3_total_changes64(f.writer.handle)
      #expect(throws: (any Error).self) {
        _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
          transactionID: transactionID, manifestHash: manifest.hash) }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

  @Test(arguments: ["maximum", "integralClock", "adjacentOutside", "fractionalClock", "fractionalObserved", "fractionalStamp"])
  func rawCausalClocksReachTypedValidationWithoutDoubleRounding(_ condition: String) throws {
    try fixture { f in
      var values: [JSONValue] = []
      for label in ["low", "high"] {
        let bytes = Data(("<p>" + label + "</p>").utf8), hash = try f.writer.putBlob(bytes)
        let resource = NotebookProgramPackage.File(path: "index.html", mimeType: "text/html", byteCount: Int64(bytes.count),
          parts: [.init(sha256: hash, byteCount: bytes.count)])
        let package = NotebookProgramPackage(html: "index.html", files: [resource])
        values.append(.object(["programPackage": .string(try f.writer.putBlob(package.canonicalData()))]))
      }
      let maximum = VersionStamp.maximumCounter
      let lowCounter: UInt64 = condition == "integralClock" ? 3 : (condition == "fractionalStamp" ? maximum - 2 : maximum - 1)
      let highCounter: UInt64 = condition == "fractionalStamp" ? maximum - 1 : maximum
      let low = ContentFieldVersion(stamp: .init(counter: lowCounter, actor: UUID()), human: false).retainingValue(values[0])
      let high = ContentFieldVersion(stamp: .init(counter: highCounter, actor: UUID()), human: true).retainingValue(values[1])
      let joined = try low.joining(high)
      #expect(joined.isValid && joined.stamp.counter == highCounter)
      // This legacy fixture starts with the typed integer encoder. An authored
      // JSONValue fixture would erase the very fractional/high literals tested.
      let encoded = try NotebookStore.storageEncoder.encode(joined)
      var clock = String(decoding: encoded, as: UTF8.self)
      if condition == "adjacentOutside" {
        clock = clock.replacingOccurrences(of: String(maximum), with: "9007199254740993")
          .replacingOccurrences(of: String(maximum - 1), with: "9007199254740992")
      } else if condition == "integralClock" {
        clock = clock.replacingOccurrences(of: "\"counter\":3", with: "\"counter\":30e-1")
      } else if condition == "fractionalClock" {
        clock = clock.replacingOccurrences(of: "\"counter\":" + String(lowCounter),
          with: "\"counter\":9007199254740990.5")
      } else if condition == "fractionalObserved" {
        let key = "\"" + low.stamp.actor.uuidString.lowercased() + "\":"
        clock = clock.replacingOccurrences(of: key + String(lowCounter), with: key + "9007199254740990.5")
      } else if condition == "fractionalStamp" {
        // With sorted keys the root stamp follows the retained head stamps.
        let token = "\"counter\":" + String(highCounter)
        let range = try #require(clock.range(of: token, options: .backwards))
        clock.replaceSubrange(range, with: "\"counter\":9007199254740990.5")
      }
      let clockData = Data(clock.utf8)
      if condition == "maximum" || condition == "integralClock" {
        let exact = try JSONDecoder().decode(ContentFieldVersion.self, from: clockData)
        #expect(exact.isValid && exact.observed[low.stamp.actor.uuidString.lowercased()] == lowCounter)
      } else if condition == "adjacentOutside" {
        let exact = try JSONDecoder().decode(ContentFieldVersion.self, from: clockData)
        #expect(!exact.isValid && exact.stamp.counter == 9_007_199_254_740_993)
      } else {
        // Actual Foundation UInt64 decoding rounds these high fractions back
        // into the valid original frontier. The raw guard must catch them.
        let rounded = try JSONDecoder().decode(ContentFieldVersion.self, from: clockData)
        #expect(rounded.isValid && rounded == joined)
      }

      let file = pageFile(UUID()), key = "elements/high-clock/content", marker = UUID().uuidString
      let fragment = NotebookStoredFragment(address: file + "#/collaboration/fields/@" + fieldKey([key]),
        file: file, parent: file + "#", collection: "collaboration/fields", member: key,
        position: 0, value: .string(marker), collections: [])
      var raw = try f.writer.encodedStoredFragment(fragment)
      let markerData = try NotebookStore.storageEncoder.encode(marker)
      let range = try #require(raw.range(of: markerData))
      raw.replaceSubrange(range, with: clockData)
      let transactionID = UUID(), record = NotebookRecordMutation(address: fragment.address, blobHash: try f.writer.putBlob(raw))
      let manifest = try f.manifest(transactionID, records: [record])
      try f.journal(transactionID, manifest, sequence: 1)
      let writes = sqlite3_total_changes64(f.writer.handle)
      if condition == "maximum" || condition == "integralClock" {
        try f.read { database in
          let proof = try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash)
          #expect(proof.receipts.isEmpty && proof.declaredRecords.status == .authenticatedDeclaredClosure
            && proof.declaredRecords.dependencyCount == 4)
          #expect(database.decodedFragmentCount == 0 && database.inkDecoding.entryCount == 0
            && sqlite3_total_changes64(database.handle) == 0)
        }
      } else if condition == "adjacentOutside" {
        #expect(throws: (any Error).self) {
          _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash) }
        }
      } else {
        #expect(throws: NotebookStorageError.corruptRecord("JSON unsigned integer")) {
          _ = try f.read { _ in try f.store.actionHistoryPhysicalClosure(workspaceID: f.workspaceID,
            transactionID: transactionID, manifestHash: manifest.hash) }
        }
      }
      #expect(sqlite3_total_changes64(f.writer.handle) == writes)
    }
  }

}
