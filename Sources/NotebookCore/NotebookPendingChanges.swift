import CSQLite
import Foundation

extension NotebookSQLConnection {
  /// The current SQL transaction owns its pending delivery rows on disk. A
  /// deletion does not retain one Swift value for every removed record.
  func recordChange(_ change: NotebookRecordMutation) throws {
    guard writable else { throw NotebookStorageError.readOnlyTransaction }
    if pendingChangeCount == 0 {
      try run("CREATE TEMP TABLE notebook_pending_changes(address TEXT PRIMARY KEY,blob_hash TEXT) WITHOUT ROWID")
      try run("PRAGMA temp.cache_size=-2048")
    }
    let arguments: [NotebookSQLValue] = [.text(change.address), change.blobHash.map(NotebookSQLValue.text) ?? .null]
    try run("INSERT OR IGNORE INTO notebook_pending_changes(address,blob_hash) VALUES(?,?)", arguments)
    if sqlite3_changes64(handle) == 1 {
      pendingChangeCount += 1
      guard pendingChangeCount <= 8_388_608 else { throw NotebookStorageError.limitExceeded("change_manifest") }
    } else {
      try run("UPDATE notebook_pending_changes SET blob_hash=? WHERE address=?", [arguments[1], arguments[0]])
    }
  }

  func hasChange(_ address: String) throws -> Bool {
    guard pendingChangeCount > 0 else { return false }
    return try !rows("SELECT 1 FROM notebook_pending_changes WHERE address=?", [.text(address)]).isEmpty
  }

  func changePage(after address: String = "", limit: Int = 64) throws -> [NotebookRecordMutation] {
    guard (1...16_384).contains(limit) else { throw NotebookStorageError.limitExceeded("pending_change_page") }
    guard pendingChangeCount > 0 else { return [] }
    return try rows("SELECT address,blob_hash FROM notebook_pending_changes WHERE address>? ORDER BY address LIMIT ?",
      [.text(address), .integer(Int64(limit))]).map { .init(address: $0[0].text!, blobHash: $0[1].text) }
  }

  func visitChanges(_ visit: (NotebookRecordMutation) throws -> Void) throws {
    var after = ""
    while true {
      let page = try changePage(after: after)
      guard let last = page.last else { return }
      for change in page { try visit(change) }
      after = last.address
    }
  }
}

extension NotebookStore {
  /// One manifest and its ordered parts commit with the changed values. The
  /// largest in-memory record page is the existing 16,384-record wire part.
  func publishPendingChanges(database: NotebookSQLConnection) throws {
    guard database.pendingChangeCount > 0 else { return }
    guard database.pendingChangeCount <= 8_388_608 else { throw NotebookStorageError.limitExceeded("change_manifest") }
    guard let workspaceID = try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:)) else {
      throw NotebookStorageError.invalidTransaction("missing workspace identity")
    }
    let transactionID = UUID()
    var parts: [String] = []
    if database.pendingChangeCount > 16_384 {
      var after = ""
      while true {
        let page = try database.changePage(after: after, limit: 16_384)
        guard let last = page.last else { break }
        let part = NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID, records: page)
        let data = try Self.storageEncoder.encode(part)
        guard data.count <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("change_manifest_part") }
        parts.append(try database.putBlob(data)); after = last.address
      }
    }
    var roots: [String] = []
    try database.visitOwners(.orderRoot) { root in
      guard roots.count < 131_072 else { throw NotebookStorageError.limitExceeded("page_order_dependencies") }
      roots.append(root)
    }
    let manifest = try NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID,
      records: parts.isEmpty ? database.changePage(limit: 16_384) : [], parts: parts, pageOrderRoots: roots)
    let data = try Self.storageEncoder.encode(manifest)
    guard data.count <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("change_manifest") }
    let hash = try database.putBlob(data)
    try database.run("INSERT INTO change_log(transaction_id,manifest_hash,byte_count) VALUES(?,?,?)", [.text(transactionID.uuidString.lowercased()), .text(hash), .integer(Int64(data.count))])
    let sequence = try database.rows("SELECT last_insert_rowid()").first![0].integer!
    try database.run("INSERT INTO change_records(sequence,address,blob_hash) SELECT ?,address,blob_hash FROM notebook_pending_changes", [.integer(sequence)])
  }
}
