import Foundation

extension NotebookStore {
  static func createContextOrderIndex(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE context_entry_order(address TEXT PRIMARY KEY REFERENCES records(address) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,context TEXT NOT NULL,counter INTEGER NOT NULL CHECK(counter>=0 AND counter<=9007199254740991),actor TEXT NOT NULL)")
    try database.run("CREATE INDEX context_causal_order ON context_entry_order(context,counter,actor,address)")
  }

  func requireContextOrderIndex() throws {
    guard try currentSQL!.rows("SELECT name FROM sqlite_master WHERE (type='table' AND name='context_entry_order') OR (type='index' AND name='context_causal_order' AND tbl_name='context_entry_order')").count == 2 else {
      throw NotebookStorageError.unsupportedFormat
    }
  }

  func indexContextEntry(_ fragment: NotebookStoredFragment, entry: SharedContextEntry,
    database: NotebookSQLConnection) throws {
    guard entry.stamp.counter <= VersionStamp.maximumCounter else {
      throw CollaborationError("invalid_context_clock", "Версия указания выходит за предел точного причинного счётчика.")
    }
    try database.run("INSERT INTO context_entry_order(address,context,counter,actor) VALUES(?,?,?,?) ON CONFLICT(address) DO UPDATE SET context=excluded.context,counter=excluded.counter,actor=excluded.actor",
      [.text(fragment.address), .text(fragment.file + "#"), .integer(Int64(entry.stamp.counter)), .text(entry.stamp.actor.uuidString.lowercased())])
  }

  func validateContextOrderIndex() throws {
    try requireContextOrderIndex()
    let database = currentSQL!
    guard try database.rows("PRAGMA index_info(context_causal_order)").compactMap({ $0[2].text }) == ["context", "counter", "actor", "address"] else {
      throw NotebookStorageError.corruptRecord("context causal index definition")
    }
    var after = "collaboration/contexts/", count: Int64 = 0
    while true {
      let rows = try database.rows("SELECT r.address,o.context,o.counter,o.actor FROM records r LEFT JOIN context_entry_order o ON o.address=r.address WHERE r.address>? AND r.address<'collaboration/contexts0' AND r.collection='entries' ORDER BY r.address LIMIT 64", [.text(after)])
      if rows.isEmpty { break }
      for row in rows {
        after = row[0].text!; count += 1
        guard let entry = try storedEntry(at: after),
          row[1].text == String(after.split(separator: "#", maxSplits: 1)[0]) + "#",
          row[2].integer == Int64(exactly: entry.stamp.counter), row[3].text == entry.stamp.actor.uuidString.lowercased() else {
          throw NotebookStorageError.corruptRecord("context causal index: " + after)
        }
      }
    }
    guard try database.rows("SELECT count(*) FROM context_entry_order").first?[0].integer == count else {
      throw NotebookStorageError.corruptRecord("context causal index contains foreign addresses")
    }
  }

  /// External transfer calls this only on its private, fingerprint-checked copy.
  /// This derives a current-format index; it never changes a canonical record,
  /// journal, device identity, or historical ordinal. Live opens do not rebuild.
  public func prepareContextOrderIndexForTransfer() throws {
    try commandTransaction {
      let database = currentSQL!
      try database.run("DROP TABLE IF EXISTS context_entry_order")
      try Self.createContextOrderIndex(database)
      var after = "collaboration/contexts/"
      while true {
        let rows = try database.rows("SELECT address,hash FROM records WHERE address>? AND address<'collaboration/contexts0' AND collection='entries' ORDER BY address LIMIT 64", [.text(after)])
        if rows.isEmpty { break }
        for row in rows {
          after = row[0].text!
          guard let entry = try storedEntry(at: after) else { throw NotebookStorageError.corruptRecord(after) }
          let fragment = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(row[1].text!))
          let source = try entry.replyTo.flatMap { try storedEntry(at: fragment.file + "#/entries/@" + $0.uuidString.lowercased()) }
          try entry.validate(sourceCounter: source?.stamp.counter)
          try indexContextEntry(fragment, entry: entry, database: database)
        }
      }
    }
  }
}
