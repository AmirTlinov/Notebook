import Foundation

extension NotebookStore {
  static func createContextOrderIndex(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE context_entry_order(address TEXT PRIMARY KEY REFERENCES records(address) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,context TEXT NOT NULL,counter INTEGER NOT NULL CHECK(counter>=0 AND counter<=9007199254740991),actor TEXT NOT NULL,author TEXT NOT NULL)")
    try database.run("CREATE INDEX context_causal_order ON context_entry_order(context,counter,actor,address)")
    try database.run("CREATE INDEX context_author_order ON context_entry_order(context,author,counter,actor,address)")
    try database.run("CREATE TABLE context_references(address TEXT NOT NULL REFERENCES context_entry_order(address) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,reference_id TEXT NOT NULL,context TEXT NOT NULL,hash TEXT NOT NULL,author TEXT NOT NULL,PRIMARY KEY(address,reference_id))")
    try database.run("CREATE INDEX context_reference_lookup ON context_references(context,hash,author,address,reference_id)")
  }

  func requireContextOrderIndex() throws {
    guard try currentSQL!.rows("SELECT name FROM sqlite_master WHERE (type='table' AND name IN ('context_entry_order','context_references')) OR (type='index' AND name IN ('context_causal_order','context_author_order','context_reference_lookup'))").count == 5 else {
      throw NotebookStorageError.unsupportedFormat
    }
  }

  func indexContextEntry(_ fragment: NotebookStoredFragment, entry: SharedContextEntry,
    database: NotebookSQLConnection) throws {
    guard entry.stamp.counter <= VersionStamp.maximumCounter else {
      throw CollaborationError("invalid_context_clock", "Версия указания выходит за предел точного причинного счётчика.")
    }
    try database.run("INSERT INTO context_entry_order(address,context,counter,actor,author) VALUES(?,?,?,?,?) ON CONFLICT(address) DO UPDATE SET context=excluded.context,counter=excluded.counter,actor=excluded.actor,author=excluded.author",
      [.text(fragment.address), .text(fragment.file + "#"), .integer(Int64(entry.stamp.counter)), .text(entry.stamp.actor.uuidString.lowercased()), .text(entry.author.rawValue)])
    guard entry.references.count <= 32, Set(entry.references.map(\.id)).count == entry.references.count else {
      throw NotebookStorageError.corruptRecord(fragment.address)
    }
    try database.run("DELETE FROM context_references WHERE address=?", [.text(fragment.address)])
    for reference in entry.references {
      try database.run("INSERT INTO context_references(address,reference_id,context,hash,author) VALUES(?,?,?,?,?)",
        [.text(fragment.address), .text(reference.id.uuidString.lowercased()), .text(fragment.file + "#"),
         .text(try collaborationHash(reference)), .text(entry.author.rawValue)])
    }
  }

  func validateContextOrderIndex() throws {
    try requireContextOrderIndex()
    let database = currentSQL!
    for (name, columns) in [
      ("context_causal_order", ["context", "counter", "actor", "address"]),
      ("context_author_order", ["context", "author", "counter", "actor", "address"]),
      ("context_reference_lookup", ["context", "hash", "author", "address", "reference_id"])
    ] {
      guard try database.rows("PRAGMA index_info(\(name))").compactMap({ $0[2].text }) == columns else {
        throw NotebookStorageError.corruptRecord("context index definition: " + name)
      }
    }
    var after = "collaboration/contexts/", count: Int64 = 0
    while true {
      let rows = try database.rows("SELECT r.address,o.context,o.counter,o.actor,o.author FROM records r LEFT JOIN context_entry_order o ON o.address=r.address WHERE r.address>? AND r.address<'collaboration/contexts0' AND r.collection='entries' ORDER BY r.address LIMIT 64", [.text(after)])
      if rows.isEmpty { break }
      for row in rows {
        after = row[0].text!; count += 1
        guard let entry = try storedEntry(at: after),
          row[1].text == String(after.split(separator: "#", maxSplits: 1)[0]) + "#",
          row[2].integer == Int64(exactly: entry.stamp.counter), row[3].text == entry.stamp.actor.uuidString.lowercased(), row[4].text == entry.author.rawValue else {
          throw NotebookStorageError.corruptRecord("context causal index: " + after)
        }
        let indexed = try database.rows("SELECT reference_id,hash,context,author FROM context_references WHERE address=?", [.text(after)])
        guard indexed.count == entry.references.count else { throw NotebookStorageError.corruptRecord("context reference count: " + after) }
        for reference in entry.references {
          let hash = try collaborationHash(reference)
          guard indexed.contains(where: { $0[0].text == reference.id.uuidString.lowercased() && $0[1].text == hash
            && $0[2].text == row[1].text && $0[3].text == entry.author.rawValue }) else {
            throw NotebookStorageError.corruptRecord("context reference index: " + after)
          }
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
      try database.run("DROP TABLE IF EXISTS context_references")
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
