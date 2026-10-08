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
}
