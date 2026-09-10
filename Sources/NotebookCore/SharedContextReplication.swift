import Foundation

extension NotebookStore {
  /// Context history is an immutable set with causal order. A delivered entry
  /// touches its own address and direct reply parent, never all previous entries.
  /// The caller owns the transaction, durable receipt and incoming peer cursor.
  func applyReplicatedContextEntries(manifestHash: String) throws {
    let database = currentSQL!
    let prefix = "collaboration/contexts/", end = "collaboration/contexts0"
    var after = prefix
    while true {
      let rows = try database.rows("SELECT address,blob_hash FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? ORDER BY address LIMIT 64", [.text(manifestHash), .text(after), .text(end)])
      if rows.isEmpty { break }
      try requireContextOrderIndex()
      for row in rows {
        let address = row[0].text!
        after = address
        guard let hash = row[1].text else { throw NotebookStorageError.invalidTransaction("context history is immutable") }
        guard try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(hash)]).first?[0].integer ?? Int64.max <= 2_097_152 else {
          throw NotebookStorageError.limitExceeded("context_entry")
        }
        let fragment = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(hash))
        let file = String(address.split(separator: "#", maxSplits: 1)[0])
        let identifier = String(file.dropFirst(prefix.count).dropLast(5))
        guard let id = UUID(uuidString: identifier), contextFile(id) == file,
          fragment.address == address, fragment.file == file, fragment.position >= 0,
          fragment.value.isValid else { throw NotebookStorageError.invalidTransaction("context fragment identity") }
        if address == file + "#" {
          let expected = try NotebookRecordCodec.encode(.encode(SharedContext(id: id)), file: file).first!
          guard fragment == expected else { throw NotebookStorageError.corruptRecord(address) }
          let previous = try storedFragments(address: address, descendants: false)
          guard previous.isEmpty || previous == [expected] else { throw NotebookStorageError.transactionConflict }
          if previous.isEmpty { try writeFragment(expected, database: database) }
        } else {
          let entry = try contextEntry(from: fragment)
          guard try fragment.value == JSONValue.encode(entry) else { throw NotebookStorageError.corruptRecord(address) }
          if let previous = try storedEntry(at: address) {
            guard previous == entry else { throw CollaborationError("context_entry_conflict", "ID указания уже принадлежит другому содержанию.") }
          } else {
            try writeFragment(.init(address: address, file: file, parent: file + "#", collection: "entries",
              member: entry.id.uuidString.lowercased(), position: 0, value: fragment.value, collections: []), database: database)
          }
        }
      }
    }
    // Parents may sort after their replies by UUID, or arrive in another manifest
    // part. Validate after all addressed inserts, while rollback is still atomic.
    after = prefix
    while true {
      let rows = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? ORDER BY address LIMIT 64", [.text(manifestHash), .text(after), .text(end)])
      if rows.isEmpty { break }
      for row in rows {
        let address = row[0].text!
        after = address
        let file = String(address.split(separator: "#", maxSplits: 1)[0])
        guard try hasStoredValue(file) else { throw NotebookStorageError.corruptRecord(file) }
        if address == file + "#" { continue }
        guard let entry = try storedEntry(at: address) else { throw NotebookStorageError.corruptRecord(address) }
        let source = try entry.replyTo.flatMap { try storedEntry(at: file + "#/entries/@" + $0.uuidString.lowercased()) }
        try entry.validate(sourceCounter: source?.stamp.counter)
      }
    }
  }
}
