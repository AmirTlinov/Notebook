import Foundation

extension NotebookStore {
  static let documentFileReplicationBytes: Int64 = 16_777_216

  /// Dependency discovery and the source merger admit the same incoming file
  /// subtree before either decodes its first body. Lengths never materialize blobs.
  func incomingDocumentFileRecords(_ address: String, manifestHash: String) throws -> [[NotebookSQLValue]] {
    let database = currentSQL!
    let point = try database.rows("""
      SELECT r.address,r.blob_hash,length(b.data) FROM manifest_records r LEFT JOIN blobs b ON b.hash=r.blob_hash
      WHERE r.manifest_hash=? AND r.address=?
      """, [.text(manifestHash), .text(address)])
    let children = try database.rows("""
      SELECT r.address,r.blob_hash,length(b.data) FROM manifest_records r LEFT JOIN blobs b ON b.hash=r.blob_hash
      WHERE r.manifest_hash=? AND r.address>=? AND r.address<? ORDER BY r.address LIMIT 4097
      """, [.text(manifestHash), .text(address + "/"), .text(address + "0")])
    let rows = point + children
    guard rows.count <= 4096 else { throw NotebookStorageError.limitExceeded("document_replication_file") }
    var remaining = Self.documentFileReplicationBytes
    for row in rows where row[1].text != nil {
      guard let bytes = row[2].integer else { throw NotebookStorageError.blobMissing(row[1].text!) }
      guard bytes <= remaining else { throw NotebookStorageError.limitExceeded("document_replication_file") }
      remaining -= bytes
    }
    return rows
  }

  /// The document's field merger works on one file at a time. SQL retains
  /// the incoming address set; retired field clocks and unrequested files
  /// never become a second, reconstructed DocumentDocument in memory.
  func applyReplicatedDocumentSource(file: String, manifestHash: String, manifestFormat: Int) throws {
    let database = currentSQL!, root = file + "#", blockPrefix = root + "/files/@"
    let fieldPrefix = root + "/collaboration/fields/@"
    let identifier = String(file.dropFirst("documents/".count).dropLast(5))
    guard let id = UUID(uuidString: identifier), documentFile(id) == file else {
      throw NotebookStorageError.invalidTransaction("document source owner")
    }
    let live = try readItemHeader(id)?.kind == .document
    let records = NotebookIncomingRecords(store: self, manifestHash: manifestHash)
    if !live {
      guard try admitsReplicatedRetiredDocumentPair(itemID: id, records: records) else {
        try publishRecords(writes: [:], removals: [file]); return
      }
      if let mutation = try records.mutation(root), mutation[0].text == nil { return }
    }

    func incoming(_ address: String) throws -> [[NotebookSQLValue]] {
      try database.rows("SELECT address,blob_hash FROM manifest_records WHERE manifest_hash=? AND address=?",
        [.text(manifestHash), .text(address)])
    }
    func fragments(_ mutations: [[NotebookSQLValue]], maximumBytes: Int64) throws -> [NotebookStoredFragment] {
      var remaining = maximumBytes
      for row in mutations {
        if let hash = row[1].text {
          guard let bytes = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(hash)]).first?[0].integer else {
            throw NotebookStorageError.blobMissing(hash)
          }
          guard bytes <= remaining else { throw NotebookStorageError.limitExceeded("document_replication_file") }
          remaining -= bytes
        }
      }
      return try mutations.compactMap { row in
        guard let hash = row[1].text else { return nil }
        let fragment = try database.decodedStoredFragment(from:database.blob(hash))
        guard fragment.address == row[0].text, fragment.file == file, fragment.position >= 0, fragment.value.isValid else {
          throw NotebookStorageError.invalidTransaction("document source fragment identity")
        }
        return fragment
      }
    }
    let previousRoot = try boundedStoredFragments([(root, false)], maximumCount: 1,
      maximumBytes: 1_048_576, budget: "document_replication_header").first
    let rootMutation = try incoming(root)
    if let mutation = rootMutation.first, mutation[1].text == nil { throw NotebookStorageError.invalidTransaction("a live document retains its source") }
    let candidateRoot = try fragments(rootMutation, maximumBytes: 1_048_576).first ?? previousRoot
    guard let candidateRoot else { throw NotebookStorageError.corruptRecord(root) }
    let candidate = try documentSourceHeader(candidateRoot, id: id)
    let previous = try previousRoot.map { try documentSourceHeader($0, id: id) }
    let frontier = max(previous?.contentStamp ?? candidate.contentStamp, candidate.contentStamp)
    var differsFromNewest = false, allocatedFields = false

    func field(_ key: String, delivered: Bool) throws -> NotebookStoredFragment? {
      let address = fieldPrefix + fieldKey([key])
      let changes = try delivered ? incoming(address) : []
      if let mutation = changes.first, mutation[1].text == nil { throw NotebookStorageError.invalidTransaction("causal document fields are retained") }
      // A causal frontier can retain actual conflicting source, not only a
      // small clock. It shares the addressed file's existing byte bound.
      let row = try fragments(changes, maximumBytes: Self.documentFileReplicationBytes).first
        ?? boundedStoredFragments([(address, false)], maximumCount: 1, maximumBytes: Self.documentFileReplicationBytes,
          budget: "document_replication_field").first
      if let row {
        let version = try row.value.decode(ContentFieldVersion.self)
        guard key.utf8.count <= 2048, version.isValid,
          row == NotebookStoredFragment(address: address, file: file, parent: root,
            collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(version), collections: []) else { throw NotebookStorageError.corruptRecord(address) }
      }
      return row
    }
    func versions(_ keys: [String], delivered: Bool) throws -> [String: JSONValue] {
      var result: [String: JSONValue] = [:]
      for key in keys { result[key] = try field(key, delivered: delivered)?.value }
      return result
    }
    func partial(_ header: DocumentDocument, block: DocumentFile?, fields: [String: JSONValue]) throws -> DocumentDocument {
      try JSONValue.encode(header).setting("files", .array(try block.map { [try JSONValue.encode($0)] } ?? []))
        .setting("collaboration", .object(["fields": .object(fields)])).decode(DocumentDocument.self)
    }
    func publishField(_ key: String, value: JSONValue) throws {
      let version = try value.decode(ContentFieldVersion.self)
      guard version.isValid else { throw NotebookStorageError.invalidTransaction("document causal version") }
      let address = fieldPrefix + fieldKey([key])
      if try database.rows("SELECT 1 FROM records WHERE address=?", [.text(address)]).isEmpty { allocatedFields = true }
      try writeFragment(.init(address: address, file: file, parent: root,
        collection: "collaboration/fields", member: key, position: 0, value: value, collections: []), database: database)
    }
    // Root content is merged by the same DocumentDocument owner as a full
    // archive. File order is not authored content.
    let priorHeaderFields = try versions(["entrypoint"], delivered: false)
    let nextHeaderFields = try versions(["entrypoint"], delivered: true)
    var resolvedHeader = try partial(candidate, block: nil, fields: nextHeaderFields)
    if let previous { try resolvedHeader.merge(partial(previous, block: nil, fields: priorHeaderFields)) }
    guard resolvedHeader.isValid else { throw NotebookStorageError.invalidTransaction("document source header merge") }
    let newestEntrypoint = previous.map { candidate.contentStamp <= $0.contentStamp ? $0.entrypoint : candidate.entrypoint } ?? candidate.entrypoint
    differsFromNewest = resolvedHeader.entrypoint != newestEntrypoint
    if let version = resolvedHeader.collaboration?.fields["entrypoint"] { try publishField("entrypoint", value: .encode(version)) }
    let publicationHeader = try JSONValue.encode(resolvedHeader).setting("contentStamp", .encode(frontier))
      .setting("collaboration", .object(["fields": .object([:])]))
    let publicationRoot = try NotebookRecordCodec.encode(publicationHeader, file: file).first { $0.address == root }!
    try writeFragment(publicationRoot, database: database)

    try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_document_files(address TEXT PRIMARY KEY)")
    try database.run("DELETE FROM replication_document_files")
    var after = root
    while true {
      let addresses = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? ORDER BY address LIMIT 64",
        [.text(manifestHash), .text(after), .text(file + "$")])
      if addresses.isEmpty { break }
      for row in addresses {
        let address = row[0].text!; after = address
        let memberAddress: String?
        if address.hasPrefix(blockPrefix), let member = address.dropFirst(blockPrefix.count).split(separator: "/", omittingEmptySubsequences: false).first, !member.isEmpty {
          memberAddress = blockPrefix + member
        } else if address.hasPrefix(fieldPrefix) {
          let encoded = String(address.dropFirst(fieldPrefix.count))
          let key = encoded.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
          guard fieldKey([key]) == encoded else { throw NotebookStorageError.invalidTransaction("document field address") }
          let parts = key.split(separator: "/", omittingEmptySubsequences: false)
          if parts.count == 3, parts[0] == "files", DocumentFile.causalFieldNames.contains(String(parts[2])) {
            memberAddress = blockPrefix + parts[1]
          } else { memberAddress = nil }
        } else { throw NotebookStorageError.invalidTransaction("document source address") }
        if let memberAddress { try database.run("INSERT OR IGNORE INTO replication_document_files(address) VALUES(?)", [.text(memberAddress)]) }
      }
    }
    after = ""
    while true {
      let members = try database.rows("SELECT address FROM replication_document_files WHERE address>? ORDER BY address LIMIT 64", [.text(after)])
      if members.isEmpty { break }
      for row in members {
        let address = row[0].text!; after = address
        let escapedID = String(address.dropFirst(blockPrefix.count))
        let member = escapedID.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        guard !member.isEmpty, member.utf16.count <= 120, collaborationIdentity(member) == member,
          fieldKey([member]) == escapedID else { throw NotebookStorageError.invalidTransaction("document block address") }
        let oldRows = try boundedStoredFragments([(address, true)], maximumCount: 4096,
          maximumBytes: Self.documentFileReplicationBytes, budget: "document_replication_file")
        let mutations = try incomingDocumentFileRecords(address, manifestHash: manifestHash)
        let received = try fragments(mutations, maximumBytes: Self.documentFileReplicationBytes)
        let declaresProgram = mutations.contains { $0[0].text == address }
        guard mutations.isEmpty || declaresProgram else { throw NotebookStorageError.invalidTransaction("document program declaration missing") }
        let changed = Dictionary(uniqueKeysWithValues: (declaresProgram ? received : oldRows).map { ($0.address, $0) })
        func block(_ rows: [NotebookStoredFragment]) throws -> DocumentFile? {
          guard !rows.isEmpty else { return nil }
          guard rows.count <= 4096 else { throw NotebookStorageError.limitExceeded("document_replication_file") }
          var remainingBytes = 16_777_216
          for row in rows {
            remainingBytes -= try Self.storageEncoder.encode(row).count
            guard remainingBytes >= 0 else { throw NotebookStorageError.limitExceeded("document_replication_file") }
          }
          let value = try NotebookRecordCodec.decode(rows, root: address)
          let block = try value.decode(DocumentFile.self)
          guard block.isValid, collaborationIdentity(block.id) == member, try JSONValue.encode(block) == value else {
            throw NotebookStorageError.corruptRecord(address)
          }
          let canonical = try NotebookRecordCodec.encode(publicationHeader.setting("files", .array([value])), file: file)
            .filter { $0.address != root }
          let stored = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
          guard canonical.count == rows.count, canonical.allSatisfy({ fragment in
            guard let actual = stored[fragment.address] else { return false }
            return fragment.replacing(value: fragment.value, position: actual.position) == actual
          }) else { throw NotebookStorageError.corruptRecord(address) }
          return block
        }
        let oldBlock = try block(oldRows), incomingBlock = try block(Array(changed.values))
        let keys = DocumentFile.causalFieldKeys(id: member)
        let beforeFields = try versions(keys, delivered: false), afterFields = try versions(keys, delivered: true)
        var resolved = try partial(candidate, block: incomingBlock, fields: afterFields)
        if let previous { try resolved.merge(partial(previous, block: oldBlock, fields: beforeFields)) }
        guard resolved.isValid else { throw NotebookStorageError.invalidTransaction("document block merge") }
        let newestBlock = previous.map { candidate.contentStamp <= $0.contentStamp ? oldBlock : incomingBlock } ?? incomingBlock
        differsFromNewest = differsFromNewest || resolved.files.first != newestBlock
        let mergedFields = try resolved.collaboration?.fields.filter { keys.contains($0.key) }.mapValues { try JSONValue.encode($0) } ?? [:]
        if !Set(mergedFields.keys).subtracting(beforeFields.keys).isEmpty { allocatedFields = true }
        let baseline = publicationHeader.setting("files", .array(try oldBlock.map { [try JSONValue.encode($0)] } ?? []))
          .setting("collaboration", .object(["fields": .object(beforeFields)]))
        let updated = publicationHeader.setting("files", .array(try resolved.files.map { try JSONValue.encode($0) }))
          .setting("collaboration", .object(["fields": .object(mergedFields)]))
        try publishProjectionEdits(file: file, before: baseline, after: updated)
      }
    }

    // Historical clocks which do not address a live source field still join
    // by their own key. Their count never creates an in-memory document map.
    after = root
    while true {
      let rows = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address>=? AND address<? ORDER BY address LIMIT 64",
        [.text(manifestHash), .text(after), .text(fieldPrefix), .text(root + "/collaboration/fields0")])
      if rows.isEmpty { break }
      for row in rows {
        let address = row[0].text!; after = address
        let key = String(address.dropFirst(fieldPrefix.count)).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        if key == "entrypoint"
          || (parts.count == 3 && parts[0] == "files" && DocumentFile.causalFieldNames.contains(String(parts[2]))) {
          continue // This field already joined with its value in the addressed owner above.
        }
        let old = try field(key, delivered: false)?.value.decode(ContentFieldVersion.self)
        guard let next = try field(key, delivered: true)?.value.decode(ContentFieldVersion.self) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        try publishField(key, value: .encode(old.map {
          try next.joining($0, valuesAreEqual: { DocumentFile.sourceValuesAreEqual($0, $1) })
        } ?? next))
      }
    }
    try validateDocumentFileNamespace(file: file)
    if allocatedFields {
      let count = try database.rows("SELECT count(*) FROM records WHERE parent=? AND collection='collaboration/fields'", [.text(root)]).first![0].integer!
      guard count <= Int64(CollaborativeContent.maximumFieldCount) else { throw NotebookStorageError.limitExceeded("document_causal_fields") }
    }
    let stamp = differsFromNewest ? frontier.advanced(by: frontier.actor) ?? frontier : frontier
    if stamp != frontier { try writeFragment(publicationRoot.replacing(value: publicationRoot.value.setting("contentStamp", .encode(stamp))), database: database) }
    try database.run("DELETE FROM replication_document_files")
  }
}
