import CSQLite
import CryptoKit
import Foundation

extension NotebookStore {
  public func stageBlob(file: URL, expectedHash: String, byteCount: Int64) throws {
    guard (0...268_435_456).contains(byteCount), expectedHash.count == 64,
      expectedHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw NotebookStorageError.limitExceeded("blob_too_large") }
    try commandTransaction {
      let database = currentSQL!
      if let size = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(expectedHash)]).first?[0].integer {
        guard size == byteCount else { throw NotebookStorageError.blobHashMismatch }; return
      }
      let input = try FileHandle(forReadingFrom: file)
      defer { try? input.close() }
      try database.run("INSERT INTO blobs(hash,data) VALUES(?,zeroblob(?))", [.text(expectedHash), .integer(byteCount)])
      let rowID = try database.rows("SELECT rowid FROM blobs WHERE hash=?", [.text(expectedHash)]).first![0].integer!
      var blob: OpaquePointer?
      guard sqlite3_blob_open(database.handle, "main", "blobs", "data", rowID, 1, &blob) == SQLITE_OK, let blob else {
        throw NotebookStorageError.invalidTransaction("blob stream")
      }
      defer { sqlite3_blob_close(blob) }
      var hasher = SHA256(), offset: Int64 = 0
      while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
        try Task.checkCancellation()
        guard Int64(chunk.count) <= byteCount - offset else { throw NotebookStorageError.blobHashMismatch }
        let result = chunk.withUnsafeBytes { sqlite3_blob_write(blob, $0.baseAddress, Int32(chunk.count), Int32(offset)) }
        guard result == SQLITE_OK else { throw NotebookStorageError.invalidTransaction("blob stream write") }
        hasher.update(data: chunk); offset += Int64(chunk.count)
      }
      guard offset == byteCount,
        hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else { throw NotebookStorageError.blobHashMismatch }
    }
  }

  private func validatedManifest(_ change: NotebookDurableChange, partHash: String? = nil) throws -> NotebookChangeManifest {
    guard change.sequence > 0, change.sequence <= UInt64(Int64.max),
      (1...67_108_864).contains(change.byteCount) else { throw NotebookStorageError.limitExceeded("change_manifest") }
    let data = try currentSQL!.blob(partHash ?? change.manifestHash)
    guard partHash != nil || data.count == change.byteCount else { throw NotebookStorageError.blobHashMismatch }
    guard data.count <= 67_108_864 else { throw NotebookStorageError.limitExceeded("change_manifest_part") }
    let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: data)
    let workspaceID = try currentSQL!.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:))
    guard manifest.format == 2, manifest.transactionID == change.transactionID, manifest.workspaceID == workspaceID,
      manifest.records.count <= 16_384, manifest.parts.count <= 512,
      !manifest.records.isEmpty || !manifest.parts.isEmpty,
      manifest.records.isEmpty || manifest.parts.isEmpty,
      partHash == nil || manifest.parts.isEmpty,
      Set(manifest.parts).count == manifest.parts.count,
      Set(manifest.records.map(\.address)).count == manifest.records.count else { throw NotebookStorageError.invalidTransaction("manifest identity or duplicate addresses") }
    func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }
    guard manifest.parts.allSatisfy(validHash), manifest.pageOrderRoots.count <= 131_072,
      Set(manifest.pageOrderRoots).count == manifest.pageOrderRoots.count,
      manifest.pageOrderRoots.allSatisfy(validHash), partHash == nil || manifest.pageOrderRoots.isEmpty else { throw NotebookStorageError.invalidTransaction("manifest part hash") }
    for record in manifest.records {
      let parts = record.address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, parts[0].hasSuffix(".json"), !record.address.contains(".."),
        !record.address.hasPrefix("/"), !Self.localRecord(String(parts[0])),
        record.blobHash.map(validHash) ?? true else { throw NotebookStorageError.invalidTransaction("replicated record address") }
    }
    return manifest
  }

  /// A large atomic change is described by bounded immutable manifest parts.
  /// Their SQL index is filled once, then dependency requests are indexed pages.
  public func missingBlobHashes(for change: NotebookDurableChange, limit: Int = 16, after: String? = nil) throws -> [String] {
    guard (1...16).contains(limit) else { throw NotebookStorageError.limitExceeded("blob_dependencies") }
    return try commandTransaction {
      let database = currentSQL!
      guard try !database.rows("SELECT 1 FROM blobs WHERE hash=?", [.text(change.manifestHash)]).isEmpty else { return [change.manifestHash] }
      if try database.rows("SELECT 1 FROM manifests WHERE hash=?", [.text(change.manifestHash)]).isEmpty {
        let manifest = try validatedManifest(change)
        try database.run("INSERT INTO manifests(hash,transaction_id) VALUES(?,?)", [.text(change.manifestHash), .text(change.transactionID.uuidString.lowercased())])
        for hash in manifest.pageOrderRoots { try database.run("INSERT INTO manifest_order_nodes(manifest_hash,hash) VALUES(?,?)", [.text(change.manifestHash), .text(hash)]) }
        try database.run("UPDATE manifests SET order_node_count=? WHERE hash=?", [.integer(Int64(manifest.pageOrderRoots.count)), .text(change.manifestHash)])
        for hash in manifest.parts { try database.run("INSERT INTO manifest_parts(manifest_hash,part_hash) VALUES(?,?)", [.text(change.manifestHash), .text(hash)]) }
        for record in manifest.records {
          try database.run("INSERT INTO manifest_records(manifest_hash,address,blob_hash) VALUES(?,?,?)", [.text(change.manifestHash), .text(record.address), record.blobHash.map(NotebookSQLValue.text) ?? .null])
        }
      } else {
        let transaction = try database.rows("SELECT transaction_id FROM manifests WHERE hash=?", [.text(change.manifestHash)]).first?[0].text
        guard transaction == change.transactionID.uuidString.lowercased() else { throw NotebookStorageError.transactionConflict }
      }
      let missingParts = try database.rows("SELECT p.part_hash FROM manifest_parts p LEFT JOIN blobs b ON b.hash=p.part_hash WHERE p.manifest_hash=? AND b.hash IS NULL ORDER BY p.part_hash LIMIT ?", [.text(change.manifestHash), .integer(Int64(limit))]).compactMap { $0[0].text }
      if !missingParts.isEmpty { return missingParts }
      let unloaded = try database.rows("SELECT part_hash FROM manifest_parts WHERE manifest_hash=? AND loaded=0 ORDER BY part_hash", [.text(change.manifestHash)]).compactMap { $0[0].text }
      for hash in unloaded {
        let part = try validatedManifest(change, partHash: hash)
        for record in part.records {
          try database.run("INSERT INTO manifest_records(manifest_hash,address,blob_hash) VALUES(?,?,?)", [.text(change.manifestHash), .text(record.address), record.blobHash.map(NotebookSQLValue.text) ?? .null])
        }
        try database.run("UPDATE manifest_parts SET loaded=1 WHERE manifest_hash=? AND part_hash=?", [.text(change.manifestHash), .text(hash)])
      }
      let missing = try database.rows("SELECT DISTINCT m.blob_hash FROM manifest_records m LEFT JOIN blobs b ON b.hash=m.blob_hash WHERE m.manifest_hash=? AND m.blob_hash>? AND b.hash IS NULL ORDER BY m.blob_hash LIMIT ?", [.text(change.manifestHash), .text(after ?? ""), .integer(Int64(limit))]).compactMap { $0[0].text }
      if !missing.isEmpty { return missing }
      return try missingPageOrderBlobs(manifestHash: change.manifestHash, limit: limit)
    }
  }

  /// The envelope has no authority until every blob is present and its typed
  /// owners merge successfully. Content, receipt, dedupe and incoming cursor
  /// commit together; retransmission never repeats a contribution.
  @discardableResult
  public func applyRemoteChange(_ change: NotebookDurableChange, peerID: UUID) throws -> UInt64 {
    try commandTransaction {
      let database = currentSQL!, peer = peerID.uuidString.lowercased(), transaction = change.transactionID.uuidString.lowercased()
      let cursor = try peerCursor(peerID: peerID, direction: .incoming)
      if let old = try database.rows("SELECT manifest_hash FROM received_transactions WHERE transaction_id=?", [.text(transaction)]).first?[0].text {
        guard old == change.manifestHash else { throw NotebookStorageError.transactionConflict }
        if change.sequence > cursor {
          guard change.sequence == cursor + 1 else { throw NotebookStorageError.invalidTransaction("noncontiguous incoming cursor") }
          try database.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',?) ON CONFLICT(peer_id,direction) DO UPDATE SET sequence=excluded.sequence", [.text(peer), .integer(Int64(change.sequence))])
        }
        return
      }
      guard change.sequence == cursor + 1 else { throw NotebookStorageError.invalidTransaction("noncontiguous incoming cursor") }
      let manifest = try validatedManifest(change)
      guard try missingBlobHashes(for: change, limit: 1).isEmpty else { throw NotebookStorageError.blobMissing(change.manifestHash) }
      try validateIncomingPageOrderValues(manifest.pageOrderRoots)
      try installPageOrderDependencies(manifestHash: change.manifestHash)
      for root in manifest.pageOrderRoots { try database.noteOwner(.orderRoot, root) }
      var incoming: [String: [NotebookStoredFragment]] = [:], removals: [String: Set<String>] = [:]
      for recordRow in try database.rows("SELECT address,blob_hash FROM manifest_records WHERE manifest_hash=? ORDER BY address", [.text(change.manifestHash)]) {
        let record = NotebookRecordMutation(address: recordRow[0].text!, blobHash: recordRow[1].text)
        let file = String(record.address.split(separator: "#", maxSplits: 1)[0])
        if let hash = record.blobHash {
          let row = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(hash))
          guard row.address == record.address, row.file == file,
            row.position >= 0, row.value.isValid else { throw NotebookStorageError.invalidTransaction("fragment identity") }
          if file == "workspace.json", row.collection == "pageOrders" {
            let order = try row.value.decode(NotebookPageOrderRegister.self)
            try order.validate()
            guard Set(order.heads.map(\.valueRoot) + [order.visibleRoot]).isSubset(of: Set(manifest.pageOrderRoots)) else {
              throw NotebookStorageError.invalidTransaction("undeclared page order dependencies")
            }
          }
          if file == "workspace.json", row.collection == "pageOrderNodes" {
            guard row.parent == "workspace.json#", row.position == 0, row.collections.isEmpty,
              row.address == "workspace.json#/pageOrderNodes/@" + row.member,
              try row.value.decode(NotebookPageOrderNode.self).hash == row.member else { throw NotebookStorageError.blobHashMismatch }
          }
          incoming[file, default: []].append(row)
        } else {
          guard !file.hasPrefix("agent/"), !file.hasPrefix("collaboration/attention/"), !record.address.hasPrefix("workspace.json#/pageOrderNodes/@") else { throw NotebookStorageError.invalidTransaction("agent history is immutable") }
          removals[file, default: []].insert(record.address)
        }
      }
      var before: [String: JSONValue] = [:], candidate: [String: JSONValue] = [:]
      for file in Set(incoming.keys).union(removals.keys) {
        let oldRows = try storedFragments(address: file + "#")
        if !oldRows.isEmpty { before[file] = try NotebookRecordCodec.decode(oldRows, root: file + "#") }
        var rows = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.address, $0) })
        for address in removals[file] ?? [] { rows[address] = nil }
        for row in incoming[file] ?? [] { rows[row.address] = row }
        if rows[file + "#"] != nil {
          var value = try NotebookRecordCodec.decode(Array(rows.values), root: file + "#")
          if file == "board.json", let previous = try before[file]?["stamp"]?.decode(VersionStamp.self),
            let incoming = try value["stamp"]?.decode(VersionStamp.self) {
            // A manifest is a delta over retained local nodes, not a complete
            // old tree. Its aggregate clock cannot move those retained portal
            // versions back in time before the causal node merge validates it.
            value = value.setting("stamp", try .encode(max(previous, incoming)))
          }
          candidate[file] = value
        }
      }
      var writes: [String: JSONValue] = [:]
      if let next = candidate["workspace.json"] {
        let index = try next.decode(WorkspaceIndex.self)
        writes["workspace.json"] = try .encode(before["workspace.json"].map { try $0.decode(WorkspaceIndex.self).merging(index) } ?? index)
      }
      if let next = candidate["board.json"] {
        let hierarchy = try next.decode(BoardHierarchy.self)
        let index = try (writes["workspace.json"] ?? storedValue("workspace.json"))?.decode(WorkspaceIndex.self)
        guard let index else { throw NotebookStorageError.corruptRecord("workspace") }
        writes["board.json"] = try .encode(before["board.json"].map { try $0.decode(BoardHierarchy.self).merging(hierarchy, items: index.items) } ?? hierarchy)
      }
      for (file, value) in candidate where !["workspace.json", "board.json"].contains(file) {
        let old = before[file]
        if file.hasPrefix("pages/") {
          var resolved = try value.decode(PageDocument.self)
          if let old { let previous = try old.decode(PageDocument.self); guard previous.size == resolved.size else { throw NotebookStorageError.transactionConflict }; _ = try resolved.joinedComputations(previous.computations ?? []); _ = resolved.merge(previous) }
          guard resolved.isValid else { throw NotebookStorageError.corruptRecord(file) }; writes[file] = try .encode(resolved)
        } else if file.hasPrefix("documents/") {
          var resolved = try value.decode(DocumentDocument.self)
          if let old { let previous = try old.decode(DocumentDocument.self); guard previous.paperSize == resolved.paperSize else { throw NotebookStorageError.transactionConflict }; _ = resolved.merge(previous) }
          guard resolved.isValid else { throw NotebookStorageError.corruptRecord(file) }; writes[file] = try .encode(resolved)
        } else if file.hasPrefix("document-states/") {
          var resolved = try value.decode(DocumentStateJournal.self)
          if let old { _ = try resolved.merge(old.decode(DocumentStateJournal.self)) }
          guard resolved.isValid else { throw NotebookStorageError.corruptRecord(file) }; writes[file] = try .encode(resolved)
        } else if file == "spatial-ink.json" {
          var resolved = try value.decode(SpatialInkJournal.self)
          if let old { _ = try resolved.merge(old.decode(SpatialInkJournal.self)) }
          guard resolved.isValid else { throw NotebookStorageError.corruptRecord(file) }; writes[file] = try .encode(resolved)
        } else if file.hasPrefix("collaboration/contexts/") {
          var resolved = try old?.decode(SharedContext.self) ?? value.decode(SharedContext.self)
          try resolved.merge(value.decode(SharedContext.self)); writes[file] = try .encode(resolved)
        } else if file.hasPrefix("collaboration/actions/") {
          let receipt = try value.decode(CollaborationReceipt.self)
          guard receipt.id == receipt.action.id else { throw NotebookStorageError.invalidTransaction("receipt identity") }
          if let old {
            let previous = try old.decode(CollaborationReceipt.self)
            guard previous.action == receipt.action else { throw NotebookStorageError.transactionConflict }
            writes[file] = try .encode(previous.undo == nil ? receipt : previous)
          } else { writes[file] = value }
        } else if file.hasPrefix("collaboration/delivery/") {
          let receipt = try value.decode(DeviceActionReceipt.self)
          writes[file] = try .encode(old?.decode(DeviceActionReceipt.self).merging(receipt) ?? receipt)
        } else if file.hasPrefix("collaboration/attention/") {
          guard old == nil || old == value else { throw NotebookStorageError.transactionConflict }
          try value.decode(AgentPinnedSource.self).validate()
          writes[file] = value
        } else if file.hasPrefix("agent/") {
          writes[file] = try mergeAgentRecord(file: file, value: value, previous: old)
        } else if file == "collaboration/selection.json" {
          let next = try value.decode(SharedContextSelection.self)
          let previous = try old?.decode(SharedContextSelection.self)
          writes[file] = try .encode(previous.map { $0.stamp < next.stamp ? next : $0 } ?? next)
        } else { throw NotebookStorageError.invalidTransaction("unsupported replicated owner") }
      }
      // A heavy owner only disappears when its canonical catalog tombstone
      // wins. A delayed page packet cannot recreate a deleted page.
      let index = try writes["workspace.json"]?.decode(WorkspaceIndex.self)
      guard try index != nil || hasStoredValue("workspace.json") else { throw NotebookStorageError.corruptRecord("workspace") }
      let livePages = index.map { Set($0.items.flatMap(\.pageIDs)) }
      let liveDocuments = index.map { Set($0.items.filter { $0.kind == .document }.map(\.id)) }
      var removedFiles: [String] = []
      for file in Set(before.keys).union(writes.keys) {
        let id = UUID(uuidString: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
        guard let id else { continue }
        let belongs: Bool
        if file.hasPrefix("pages/") { belongs = try livePages?.contains(id) ?? (ownerItemID(ofPage: id) != nil) }
        else if file.hasPrefix("documents/") || file.hasPrefix("document-states/") { belongs = try liveDocuments?.contains(id) ?? (readItemHeader(id)?.kind == .document) }
        else { continue }
        if !belongs {
          writes[file] = nil; removedFiles.append(file)
        }
      }
      // Catalog edits register their changed members with the SQL ownership
      // validator. A page, response chunk or receipt does not scan all catalog
      // members merely to prove an unchanged archive's dependencies again.
      try publishRecords(writes: writes, removals: removedFiles)
      for (file, value) in writes where file.hasPrefix("collaboration/attention/") {
        try validateAttentionEvidence(file: file, value: value, previous: before[file])
      }
      try validateReplicatedAgentDependencies(writes: writes, previous: before)
      try database.run("INSERT INTO received_transactions(transaction_id,manifest_hash,peer_id,sequence) VALUES(?,?,?,?)", [.text(transaction), .text(change.manifestHash), .text(peer), .integer(Int64(change.sequence))])
      try database.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',?) ON CONFLICT(peer_id,direction) DO UPDATE SET sequence=excluded.sequence", [.text(peer), .integer(Int64(change.sequence))])
    }
    return try peerCursor(peerID: peerID, direction: .incoming)
  }

}
