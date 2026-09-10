import CSQLite
import Foundation

enum NotebookPendingOwner: String {
  case board, referenceRoot, item, cover, page, pageOrder, pageMembership, capturedPageOrder, orderRoot
  case boardPrefix, referenceTouched, referencePending
}

extension NotebookSQLConnection {
  /// Transaction-local dependency work shares SQLite's bounded file-backed
  /// cache with pending delivery. No second in-memory archive index exists.
  @discardableResult
  func noteOwner(_ kind: NotebookPendingOwner, _ key: String, value: String? = nil) throws -> Bool {
    guard writable else { throw NotebookStorageError.readOnlyTransaction }
    if !pendingOwnersPrepared {
      try run("CREATE TEMP TABLE notebook_pending_owners(kind TEXT NOT NULL,key TEXT NOT NULL,value TEXT,PRIMARY KEY(kind,key)) WITHOUT ROWID")
      try run("PRAGMA temp.cache_size=-2048")
      pendingOwnersPrepared = true
    }
    try run("INSERT OR IGNORE INTO notebook_pending_owners(kind,key,value) VALUES(?,?,?)", [.text(kind.rawValue), .text(key), value.map(NotebookSQLValue.text) ?? .null])
    return sqlite3_changes64(handle) == 1
  }

  func hasOwner(_ kind: NotebookPendingOwner, _ key: String? = nil) throws -> Bool {
    guard pendingOwnersPrepared else { return false }
    if let key { return try !rows("SELECT 1 FROM notebook_pending_owners WHERE kind=? AND key=?", [.text(kind.rawValue), .text(key)]).isEmpty }
    return try !rows("SELECT 1 FROM notebook_pending_owners WHERE kind=? LIMIT 1", [.text(kind.rawValue)]).isEmpty
  }

  func ownerValue(_ kind: NotebookPendingOwner, _ key: String) throws -> String? {
    guard pendingOwnersPrepared else { return nil }
    return try rows("SELECT value FROM notebook_pending_owners WHERE kind=? AND key=?", [.text(kind.rawValue), .text(key)]).first?[0].text
  }

  func forgetOwner(_ kind: NotebookPendingOwner, _ key: String) throws {
    guard pendingOwnersPrepared else { return }
    try run("DELETE FROM notebook_pending_owners WHERE kind=? AND key=?", [.text(kind.rawValue), .text(key)])
  }

  func visitOwners(_ kind: NotebookPendingOwner, descending: Bool = false, _ visit: (String) throws -> Void) throws {
    guard pendingOwnersPrepared else { return }
    var after: String?
    while true {
      let cursor = after == nil ? "" : (descending ? " AND key<?" : " AND key>?")
      let arguments: [NotebookSQLValue] = [.text(kind.rawValue)] + (after.map { [.text($0)] } ?? [])
      let page = try rows("SELECT key FROM notebook_pending_owners WHERE kind=?" + cursor + (descending ? " ORDER BY key DESC LIMIT 64" : " ORDER BY key LIMIT 64"), arguments)
      guard let last = page.last?[0].text else { return }
      for row in page { try visit(row[0].text!) }
      after = last
    }
  }

  /// Requeued ancestors are processed until their causal digest is stable.
  func takeOwner(_ kind: NotebookPendingOwner) throws -> String? {
    guard pendingOwnersPrepared,
      let key = try rows("SELECT key FROM notebook_pending_owners WHERE kind=? ORDER BY key LIMIT 1", [.text(kind.rawValue)]).first?[0].text else { return nil }
    try forgetOwner(kind, key)
    return key
  }
}
