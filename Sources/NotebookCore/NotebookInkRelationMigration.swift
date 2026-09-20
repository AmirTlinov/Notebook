import Foundation

extension NotebookStoredFragment {
  /// One-time current-store admission only. Runtime readers accept relations,
  /// never an array fallback. The original content-addressed blob is retained.
  func migratingStoredInkMeasurements() throws -> Self {
    func body(_ value: JSONValue) throws -> JSONValue {
      if case .string = value { _ = try value.decode(InkMeasurements.self); return value }
      guard case .array = value else { throw NotebookStorageError.corruptRecord(address) }
      let samples = try value.decode([SpatialInkSample].self)
      guard (1...1_000_000).contains(samples.count), samples.allSatisfy(\.isValid),
        try JSONValue.encode(samples) == value else { throw NotebookStorageError.corruptRecord(address) }
      return try .encode(InkMeasurements(samples))
    }
    if isInkMeasurementBody {
      if collection == "samples" { return try replacing(value: body(value)) }
      guard case .array(let spans) = value, !spans.isEmpty else { throw NotebookStorageError.corruptRecord(address) }
      let migrated = try spans.map { span -> JSONValue in
        guard let samples = span["samples"] else { throw NotebookStorageError.corruptRecord(address) }
        let result = try span.setting("samples", body(samples)), typed = try result.decode(SpatialInkSpan.self)
        guard typed.isValid, try JSONValue.encode(typed) == result else { throw NotebookStorageError.corruptRecord(address) }
        return result
      }
      return replacing(value: .array(migrated))
    }
    if address == "spatial-ink.json#" {
      guard value["format"] == .number(1) || value["format"] == .number(Double(SpatialInkJournal.formatVersion)) else {
        throw NotebookStorageError.unsupportedFormat
      }
      return replacing(value: value.setting("format", .number(Double(SpatialInkJournal.formatVersion))))
    }
    return self
  }
}

extension NotebookStore {
  /// A format transition cannot discard an unacknowledged delivery. Old
  /// manifests/receipts remain immutable historical evidence, not current wire.
  func migrateStoredInkRelations(database: NotebookSQLConnection) throws {
    guard currentSQL === database, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let oldRoot = try database.rows("SELECT 1 FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address='spatial-ink.json#' AND json_extract(CAST(b.data AS TEXT),'$.value.format')=1 LIMIT 1")
    let oldPaper = try database.rows("SELECT 1 FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file LIKE 'pages/%' AND r.collection='samples' AND json_type(CAST(b.data AS TEXT),'$.value')='array' LIMIT 1")
    guard !oldRoot.isEmpty || !oldPaper.isEmpty else { return }
    let cursor = try currentChangeCursor()
    for peer in try database.rows("SELECT DISTINCT peer_id FROM peer_cursors").compactMap({ $0[0].text }) {
      let acknowledged = try database.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='outgoing'", [.text(peer)]).first?[0].integer ?? 0
      guard try database.rows("SELECT 1 FROM change_log WHERE sequence>? AND sequence<=? LIMIT 1",
        [.integer(acknowledged), .integer(Int64(cursor))]).isEmpty else {
        throw CollaborationError("ink_migration_pending_peer", "Перед обновлением формата чернил нужно завершить передачу сопряжённому устройству. Неподтверждённые изменения и его курсор не будут сброшены.")
      }
    }
    // Disk-backed memoization also covers shared pre/postimages of undo. Do not
    // retain an archive-sized Swift dictionary or invent new authored events.
    try database.run("CREATE TEMP TABLE ink_relation_migration(source_hash TEXT PRIMARY KEY,result_hash TEXT NOT NULL) WITHOUT ROWID")
    defer { try? database.run("DROP TABLE ink_relation_migration") }
    var bodyCount = 0, receiptCount = 0
    func convert(_ fragment: NotebookStoredFragment, hash: String) throws -> (NotebookStoredFragment, String) {
      if let result = try database.rows("SELECT result_hash FROM ink_relation_migration WHERE source_hash=?", [.text(hash)]).first?[0].text {
        return (try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(result)), result)
      }
      let next = try fragment.migratingStoredInkMeasurements()
      let result = next == fragment ? hash : try database.putBlob(Self.storageEncoder.encode(next))
      try database.run("INSERT INTO ink_relation_migration VALUES(?,?)", [.text(hash), .text(result)])
      if result != hash { bodyCount += 1 }
      return (next, result)
    }
    func inverse(_ reference: NotebookLifecycleInverseReference, actionID: UUID) throws -> NotebookLifecycleInverseReference {
      let root = try readLifecycleInverseRoot(reference: reference, actionID: actionID)
      var parts: [String] = [], count = 0, previous = ""
      for (ordinal, hash) in root.parts.enumerated() {
        let part = try readLifecycleInversePart(hash: hash, actionID: actionID, ordinal: ordinal)
        let records = try part.records.map { record -> NotebookActionRecordChange in
          guard previous.utf8.lexicographicallyPrecedes(record.address.utf8), count < root.recordCount else {
            throw NotebookStorageError.invalidTransaction("ink migration inverse order")
          }
          previous = record.address; count += 1
          func converted(_ hash: String?) throws -> String? {
            guard let hash else { return nil }
            return try convert(readLifecycleInverseFragment(hash: hash, address: record.address), hash: hash).1
          }
          let next = try NotebookActionRecordChange(address: record.address,
            beforeHash: converted(record.beforeHash), afterHash: converted(record.afterHash))
          try validateLifecycleInverseRecord(next)
          return next
        }
        let migrated = NotebookLifecycleInversePart(format: part.format, workspaceID: part.workspaceID,
          actionID: part.actionID, ordinal: part.ordinal, records: records)
        parts.append(try database.putBlob(Self.storageEncoder.encode(migrated)))
      }
      guard count == root.recordCount else { throw NotebookStorageError.invalidTransaction("ink migration inverse count") }
      let migrated = NotebookLifecycleInverseRoot(format: root.format, workspaceID: root.workspaceID,
        actionID: root.actionID, recordCount: root.recordCount, parts: parts)
      return try .init(rootHash: database.putBlob(Self.storageEncoder.encode(migrated)), recordCount: count)
    }
    var after = ""
    while let row = try database.rows("""
      SELECT r.address,r.hash,b.data FROM records r JOIN blobs b ON b.hash=r.hash
      WHERE r.address>? AND ((r.file LIKE 'pages/%' AND r.collection='samples')
        OR r.file='spatial-ink.json' OR (r.file LIKE 'collaboration/actions/%' AND r.parent IS NULL))
      ORDER BY r.address LIMIT 1
      """, [.text(after)]).first {
      try Task.checkCancellation()
      after = row[0].text!
      let original = try JSONDecoder().decode(NotebookStoredFragment.self, from: row[2].blob!)
      var next = try convert(original, hash: row[1].text!).0
      if next.file.hasPrefix("collaboration/actions/"), next.parent == nil {
        // Only rewrite the serialization of the exact pre/postimages. The
        // action, original request, causal state, references and pinned moments
        // stay unchanged. Historical receipt blobs still name the old bytes.
        guard let id = next.value["id"]?.string.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord(after) }
        var value = next.value
        if let old = value["lifecycleInverse"] {
          value = try value.setting("lifecycleInverse", .encode(inverse(old.decode(NotebookLifecycleInverseReference.self), actionID: id)))
        }
        if let undo = value["undo"], let old = undo["restorationInverse"] {
          value = try value.setting("undo", undo.setting("restorationInverse", .encode(inverse(old.decode(NotebookLifecycleInverseReference.self), actionID: id))))
        }
        next = next.replacing(value: value)
        if next != original { receiptCount += 1 }
      }
      guard next != original else { continue }
      try writeFragment(next, database: database, migratingInk: true)
      if next.isInkMeasurementBody, let parent = next.parent {
        if next.collection == "spans" {
          _ = try readSpatialInkAction(parent)
          // The same replication owner requires an immutable header with spans.
          guard let hash = try database.rows("SELECT hash FROM records WHERE address=?", [.text(parent)]).first?[0].text else {
            throw NotebookStorageError.corruptRecord(parent)
          }
          try database.recordChange(.init(address: parent, blobHash: hash))
        } else {
          _ = try NotebookRecordCodec.decode(storedFragments(address: parent), root: parent).decode(PageInkAction.self)
        }
      }
    }
    let receipt: JSONValue = .object(["sourceCursor": .number(Double(cursor)),
      "convertedBodies": .number(Double(bodyCount)), "convertedReceipts": .number(Double(receiptCount))])
    try publishRecords(writes: ["local/migrations/ink-relations-v1.json": receipt])
    try database.run("INSERT INTO metadata(key,value) VALUES('ink_outgoing_floor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(cursor))])
  }

  func deliveryFormatFloor(database: NotebookSQLConnection) throws -> UInt64 {
    UInt64(try database.rows("SELECT COALESCE(MAX(CAST(value AS INTEGER)),0) FROM metadata WHERE key IN ('placement_outgoing_floor','ink_outgoing_floor')").first![0].integer!)
  }
}
