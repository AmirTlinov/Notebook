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

  func validatedManifest(_ change: NotebookDurableChange, partHash: String? = nil) throws -> NotebookChangeManifest {
    guard change.sequence > 0, change.sequence <= UInt64(Int64.max),
      (1...67_108_864).contains(change.byteCount) else { throw NotebookStorageError.limitExceeded("change_manifest") }
    let data = try currentSQL!.blob(partHash ?? change.manifestHash)
    guard partHash != nil || data.count == change.byteCount else { throw NotebookStorageError.blobHashMismatch }
    guard data.count <= 67_108_864 else { throw NotebookStorageError.limitExceeded("change_manifest_part") }
    let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: data)
    let workspaceID = try currentSQL!.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:))
    guard manifest.format == 3, manifest.transactionID == change.transactionID, manifest.workspaceID == workspaceID,
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
      try applyReplicatedContextEntries(manifestHash: change.manifestHash)
      // These are transaction-local dependency checks, not another archive.
      // Even one manifest spanning many requests keeps only an indexed row per
      // request and the prior execution required by its causal validator.
      try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_agent_checks(request_id TEXT PRIMARY KEY, execution_before BLOB)")
      try database.run("PRAGMA temp.cache_size=-2048")
      try database.run("DELETE FROM replication_agent_checks")
      let declaredOrderRoots = Set(manifest.pageOrderRoots)
      func applyFile(_ file: String) throws {
        if file.hasPrefix("document-states/") {
          try applyReplicatedDocumentState(file: file, manifestHash: change.manifestHash)
          return
        }
        if file.hasPrefix("documents/") {
          try applyReplicatedDocumentSource(file: file, manifestHash: change.manifestHash)
          return
        }
        // A typed merger still owns this complete logical file. Releasing it
        // before advancing keeps independent owners out of one giant packet
        // dictionary; partial heavy-owner merging remains a separate contract.
        let root = file + "#", oldRows = try storedFragments(address: file + "#")
        let before = oldRows.isEmpty ? nil : try NotebookRecordCodec.decode(oldRows, root: root)
        var rows = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.address, $0) })
        var afterAddress = file
        while true {
          let records = try database.rows("SELECT address,blob_hash FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? ORDER BY address LIMIT 64",
            [.text(change.manifestHash), .text(afterAddress), .text(file + "$")])
          if records.isEmpty { break }
          for record in records {
            let address = record[0].text!; afterAddress = address
            if let hash = record[1].text {
              let row = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(hash))
              guard row.address == address, row.file == file,
                row.position >= 0, row.value.isValid else { throw NotebookStorageError.invalidTransaction("fragment identity") }
              if file == "workspace.json", row.collection == "pageOrders" {
                let order = try row.value.decode(NotebookPageOrderRegister.self)
                try order.validate()
                guard Set(order.heads.map(\.valueRoot) + [order.visibleRoot]).isSubset(of: declaredOrderRoots) else {
                  throw NotebookStorageError.invalidTransaction("undeclared page order dependencies")
                }
              }
              if file == "workspace.json", row.collection == "pageOrderNodes" {
                guard row.parent == root, row.position == 0, row.collections.isEmpty,
                  row.address == "workspace.json#/pageOrderNodes/@" + row.member,
                  try row.value.decode(NotebookPageOrderNode.self).hash == row.member else { throw NotebookStorageError.blobHashMismatch }
              }
              rows[address] = row
            } else {
              guard !file.hasPrefix("agent/"), !file.hasPrefix("collaboration/attention/"),
                !address.hasPrefix("workspace.json#/pageOrderNodes/@") else { throw NotebookStorageError.invalidTransaction("agent history is immutable") }
              rows[address] = nil
            }
          }
        }
        var resolved: JSONValue?
        if rows[root] != nil {
          var value = try NotebookRecordCodec.decode(Array(rows.values), root: root)
          if file == "workspace.json" {
            let index = try value.decode(WorkspaceIndex.self)
            resolved = try .encode(before.map { try $0.decode(WorkspaceIndex.self).merging(index) } ?? index)
          } else if file == "board.json" {
            if let previous = try before?["stamp"]?.decode(VersionStamp.self),
              let incoming = try value["stamp"]?.decode(VersionStamp.self) {
              // Retained local nodes cannot be assigned an older aggregate
              // clock while the incoming delta's typed tree is reconstructed.
              value = value.setting("stamp", try .encode(max(previous, incoming)))
            }
            let hierarchy = try value.decode(BoardHierarchy.self)
            guard let index = try storedValue("workspace.json")?.decode(WorkspaceIndex.self) else { throw NotebookStorageError.corruptRecord("workspace") }
            resolved = try .encode(before.map { try $0.decode(BoardHierarchy.self).merging(hierarchy, items: index.items) } ?? hierarchy)
          } else if file.hasPrefix("pages/") {
            var page = try value.decode(PageDocument.self)
            if let before {
              let previous = try before.decode(PageDocument.self)
              guard previous.size == page.size else { throw NotebookStorageError.transactionConflict }
              _ = try page.joinedComputations(previous.computations ?? []); _ = page.merge(previous)
            }
            guard page.isValid else { throw NotebookStorageError.corruptRecord(file) }; resolved = try .encode(page)
          } else if file.hasPrefix("collaboration/actions/") {
            let receipt = try value.decode(CollaborationReceipt.self)
            guard receipt.id == receipt.action.id else { throw NotebookStorageError.invalidTransaction("receipt identity") }
            if let before {
              let previous = try before.decode(CollaborationReceipt.self)
              guard previous.action == receipt.action else { throw NotebookStorageError.transactionConflict }
              resolved = try .encode(previous.undo == nil ? receipt : previous)
            } else { resolved = value }
          } else if file.hasPrefix("collaboration/delivery/") {
            let receipt = try value.decode(DeviceActionReceipt.self)
            resolved = try .encode(before?.decode(DeviceActionReceipt.self).merging(receipt) ?? receipt)
          } else if file.hasPrefix("collaboration/attention/") {
            guard before == nil || before == value else { throw NotebookStorageError.transactionConflict }
            try value.decode(AgentPinnedSource.self).validate(); resolved = value
          } else if file.hasPrefix("agent/") {
            resolved = try mergeAgentRecord(file: file, value: value, previous: before)
          } else if file == "collaboration/selection.json" {
            let next = try value.decode(SharedContextSelection.self)
            let previous = try before?.decode(SharedContextSelection.self)
            resolved = try .encode(previous.map { $0.stamp < next.stamp ? next : $0 } ?? next)
          } else { throw NotebookStorageError.invalidTransaction("unsupported replicated owner") }
        }
        // Read canonical membership after the catalog merge. A delayed heavy
        // packet cannot resurrect an owner whose deletion has already won.
        if before != nil || resolved != nil,
          let id = UUID(uuidString: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent) {
          let belongs: Bool
          if file.hasPrefix("pages/") { belongs = try ownerItemID(ofPage: id) != nil }
          else { belongs = true }
          if !belongs { try publishRecords(writes: [:], removals: [file]); return }
        }
        guard let resolved else { return }
        try publishRecords(writes: [file: resolved])
        if file.hasPrefix("agent/"),
          let id = file.split(separator: "/").dropFirst(2).first.flatMap({ UUID(uuidString: String($0.prefix(36))) }) {
          try database.run("INSERT OR IGNORE INTO replication_agent_checks(request_id) VALUES(?)", [.text(id.uuidString.lowercased())])
          if file == agentExecutionFile(id), let before {
            try database.run("UPDATE replication_agent_checks SET execution_before=? WHERE request_id=?",
              [.blob(try Self.storageEncoder.encode(before)), .text(id.uuidString.lowercased())])
          }
        }
      }
      func hasIncoming(_ file: String) throws -> Bool {
        try !database.rows("SELECT 1 FROM manifest_records WHERE manifest_hash=? AND address>=? AND address<? LIMIT 1",
          [.text(change.manifestHash), .text(file + "#"), .text(file + "$")]).isEmpty
      }
      // Preserve publishRecords' dependency order: catalog, document paper,
      // other content, then placements. A new document's spatial index needs
      // its paper header; intermediate owner mismatches cannot escape commit.
      if try hasIncoming("workspace.json") { try applyFile("workspace.json") }
      guard try hasStoredValue("workspace.json") else { throw NotebookStorageError.corruptRecord("workspace") }
      var afterFile = "documents/"
      while let address = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<'documents0' ORDER BY address LIMIT 1",
        [.text(change.manifestHash), .text(afterFile)]).first?[0].text {
        let file = String(address.split(separator: "#", maxSplits: 1)[0])
        try applyFile(file); afterFile = file + "$"
      }
      afterFile = ""
      while let address = try database.rows("""
        SELECT address FROM manifest_records WHERE manifest_hash=? AND address>?
        AND (address<'workspace.json#' OR address>='workspace.json$')
        AND (address<'board.json#' OR address>='board.json$')
        AND (address<'documents/' OR address>='documents0')
        AND (address<'collaboration/contexts/' OR address>='collaboration/contexts0')
        AND (address<'spatial-ink.json#' OR address>='spatial-ink.json$')
        ORDER BY address LIMIT 1
        """, [.text(change.manifestHash), .text(afterFile)]).first?[0].text {
        let file = String(address.split(separator: "#", maxSplits: 1)[0])
        try applyFile(file)
        afterFile = file + "$"
      }
      if try hasIncoming("board.json") { try applyFile("board.json") }
      try applyReplicatedSpatialInk(manifestHash: change.manifestHash)
      // Immutable attention sources were compared with their previous value by
      // applyFile. Resolve their dependencies only after every owner is present.
      afterFile = "collaboration/attention/"
      while let address = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<'collaboration/attention0' ORDER BY address LIMIT 1",
        [.text(change.manifestHash), .text(afterFile)]).first?[0].text {
        let file = String(address.split(separator: "#", maxSplits: 1)[0])
        if let value = try storedValue(file) { try validateAttentionEvidence(file: file, value: value, previous: nil) }
        afterFile = file + "$"
      }
      var afterRequest = ""
      while true {
        let requests = try database.rows("SELECT request_id,execution_before FROM replication_agent_checks WHERE request_id>? ORDER BY request_id LIMIT 64", [.text(afterRequest)])
        if requests.isEmpty { break }
        for request in requests {
          let id = request[0].text!; afterRequest = id
          try validateReplicatedAgentDependencies(requestID: UUID(uuidString: id)!,
            previousExecution: request[1].blob.map { try JSONDecoder().decode(AgentExecution.self, from: $0) })
        }
      }
      try database.run("DELETE FROM replication_agent_checks")
      try database.run("INSERT INTO received_transactions(transaction_id,manifest_hash,peer_id,sequence) VALUES(?,?,?,?)", [.text(transaction), .text(change.manifestHash), .text(peer), .integer(Int64(change.sequence))])
      try database.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'incoming',?) ON CONFLICT(peer_id,direction) DO UPDATE SET sequence=excluded.sequence", [.text(peer), .integer(Int64(change.sequence))])
    }
    return try peerCursor(peerID: peerID, direction: .incoming)
  }

}
