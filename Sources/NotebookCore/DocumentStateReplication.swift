import Foundation

extension NotebookStore {
  /// One incoming state merges only the addressed block subtrees. The ordinary
  /// record publisher, causal value merger and outer transaction remain owners.
  func applyReplicatedDocumentState(file: String, manifestHash: String) throws {
    let database = currentSQL!, rootAddress = file + "#"
    let identifier = String(file.dropFirst("document-states/".count).dropLast(5))
    guard let id = UUID(uuidString: identifier), stateFile(id) == file else {
      throw NotebookStorageError.invalidTransaction("document state owner")
    }
    // A catalog tombstone owns deletion. Retired state packets cannot recreate
    // either the document or its journal, regardless of their delivery order.
    guard try readItemHeader(id)?.kind == .document else {
      try publishRecords(writes: [:], removals: [file]); return
    }
    func fragment(_ address: String, _ hash: String) throws -> NotebookStoredFragment {
      let value = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(hash))
      guard value.address == address, value.file == file, value.position >= 0, value.value.isValid else {
        throw NotebookStorageError.invalidTransaction("document state fragment identity")
      }
      return value
    }
    let previousRoot = try storedFragments(address: rootAddress, descendants: false).first
    let rootMutation = try database.rows("SELECT blob_hash FROM manifest_records WHERE manifest_hash=? AND address=?",
      [.text(manifestHash), .text(rootAddress)]).first
    if let rootMutation, rootMutation[0].text == nil {
      throw NotebookStorageError.invalidTransaction("a live document retains its state journal")
    }
    let deliveredRoot = try rootMutation?[0].text.map { try fragment(rootAddress, $0) }
    guard let candidateRoot = deliveredRoot ?? previousRoot else { throw NotebookStorageError.corruptRecord(rootAddress) }
    func header(_ root: NotebookStoredFragment) throws -> DocumentStateJournal {
      let journal = try NotebookRecordCodec.decode([root], root: rootAddress).decode(DocumentStateJournal.self)
      guard journal.id == id, journal.isValid,
        try NotebookRecordCodec.encode(.encode(journal), file: file) == [root] else {
        throw NotebookStorageError.corruptRecord(rootAddress)
      }
      return journal
    }
    let candidate = try header(candidateRoot), previous = try previousRoot.map(header)
    let frontier = max(previous?.stamp ?? candidate.stamp, candidate.stamp)
    let root = candidateRoot.replacing(value: candidateRoot.value.setting("stamp", try .encode(frontier)))
    if previousRoot != root { try writeFragment(root, database: database) }

    // The indexed set is local to this connection. One huge manifest cannot
    // accumulate all changed block IDs or their values in an application array.
    try database.run("CREATE TEMP TABLE IF NOT EXISTS replication_state_blocks(address TEXT PRIMARY KEY)")
    try database.run("DELETE FROM replication_state_blocks")
    let prefix = rootAddress + "/records/@"
    var after = rootAddress
    while true {
      let rows = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? ORDER BY address LIMIT 64",
        [.text(manifestHash), .text(after), .text(file + "$")])
      if rows.isEmpty { break }
      for row in rows {
        let address = row[0].text!; after = address
        guard address.hasPrefix(prefix), let member = address.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).first,
          !member.isEmpty else { throw NotebookStorageError.invalidTransaction("document state block address") }
        try database.run("INSERT OR IGNORE INTO replication_state_blocks(address) VALUES(?)", [.text(prefix + member)])
      }
    }
    var differsFromNewestValues = false
    after = ""
    while true {
      let blocks = try database.rows("SELECT address FROM replication_state_blocks WHERE address>? ORDER BY address LIMIT 64", [.text(after)])
      if blocks.isEmpty { break }
      for block in blocks {
        let address = block[0].text!; after = address
        let oldRows = try storedFragments(address: address)
        var changedRows = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.address, $0) })
        if let mutation = try database.rows("SELECT blob_hash FROM manifest_records WHERE manifest_hash=? AND address=?",
          [.text(manifestHash), .text(address)]).first {
          changedRows[address] = try mutation[0].text.map { try fragment(address, $0) }
        }
        var afterFragment = address
        while true {
          // Separate indexed point/subtree reads avoid an OR predicate which
          // could walk the whole packet per block. Prefix-like siblings (a!, a0)
          // never enter this value or disappear from the block continuation.
          let rows = try database.rows("""
            SELECT address,blob_hash FROM manifest_records WHERE manifest_hash=? AND address>?
            AND address>=? AND address<? ORDER BY address LIMIT 64
            """, [.text(manifestHash), .text(afterFragment), .text(address + "/"), .text(address + "0")])
          if rows.isEmpty { break }
          for row in rows {
            let changed = row[0].text!; afterFragment = changed
            if let hash = row[1].text { changedRows[changed] = try fragment(changed, hash) }
            else { changedRows[changed] = nil }
          }
        }
        guard let blockRoot = changedRows[address], blockRoot.parent == rootAddress,
          blockRoot.collection == "records", address == prefix + fieldKey([blockRoot.member]) else {
          throw NotebookStorageError.corruptRecord(address)
        }
        let value = try NotebookRecordCodec.decode(Array(changedRows.values), root: address)
        var resolved = try value.decode(DocumentStateRecord.self)
        guard blockRoot.member == collaborationIdentity(resolved.id), resolved.isValid(in: frontier),
          try JSONValue.encode(resolved) == value else { throw NotebookStorageError.corruptRecord(address) }
        let canonical = try NotebookRecordCodec.encode(root.value.setting("records", .array([JSONValue.encode(resolved)])), file: file)
          .filter { $0.address != rootAddress }
        guard canonical.count == changedRows.count, canonical.allSatisfy({ row in
          guard let actual = changedRows[row.address] else { return false }
          return row.replacing(value: row.value, position: actual.position) == actual
        }) else { throw NotebookStorageError.corruptRecord(address) }
        let old = try oldRows.isEmpty ? nil : NotebookRecordCodec.decode(oldRows, root: address).decode(DocumentStateRecord.self)
        if let old {
          guard let previous, old.id == resolved.id, old.isValid(in: previous.stamp) else { throw NotebookStorageError.corruptRecord(address) }
          // This is exactly candidate.merge(previous), not a second field-clock
          // policy. Keeping that direction also preserves the existing tie rule.
          _ = resolved.replace(old.value, version: old.fieldVersion ?? .init(stamp: old.stamp, human: true))
        }
        let newestValue: JSONValue?
        if let previous, candidate.stamp <= previous.stamp { newestValue = old?.value }
        else { newestValue = value["value"] }
        differsFromNewestValues = differsFromNewestValues || resolved.value != newestValue
        let baseline = root.value.setting("records", .array(try old.map { [try JSONValue.encode($0)] } ?? []))
        let updated = root.value.setting("records", .array([try JSONValue.encode(resolved)]))
        try publishProjectionEdits(file: file, before: baseline, after: updated)
      }
    }
    let stamp = differsFromNewestValues ? frontier.advanced(by: frontier.actor) ?? frontier : frontier
    if stamp != frontier { try writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(stamp))), database: database) }
    try database.run("DELETE FROM replication_state_blocks")
  }
}
