import Foundation

extension NotebookStore {
  /// Incoming spatial history uses the same UUID/state publisher as a native
  /// contact. Manifest pages never reconstruct or renumber another action.
  /// The caller owns rollback, acknowledgement and the incoming peer cursor.
  func applyReplicatedSpatialInk(manifestHash: String) throws {
    let database = currentSQL!, rootAddress = "spatial-ink.json#", file = "spatial-ink.json"
    guard try !database.rows("SELECT 1 FROM manifest_records WHERE manifest_hash=? AND address>=? AND address<? LIMIT 1",
      [.text(manifestHash), .text(rootAddress), .text("spatial-ink.json$")]).isEmpty else { return }
    func incoming(_ address: String) throws -> NotebookStoredFragment? {
      guard let record = try database.rows("SELECT blob_hash FROM manifest_records WHERE manifest_hash=? AND address=?",
        [.text(manifestHash), .text(address)]).first else { return nil }
      guard let hash = record[0].text else { throw NotebookStorageError.invalidTransaction("spatial ink history is immutable") }
      let fragment = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(hash))
      guard fragment.address == address, fragment.file == file, fragment.position >= 0,
        fragment.value.isValid else { throw NotebookStorageError.invalidTransaction("spatial ink fragment identity") }
      return fragment
    }
    let deliveredRoot = try incoming(rootAddress)
    let storedRoot = try storedFragments(address: rootAddress, descendants: false).first
    var after = rootAddress
    guard let root = deliveredRoot ?? storedRoot else {
      guard try database.rows("SELECT 1 FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? LIMIT 1",
        [.text(manifestHash), .text(rootAddress), .text("spatial-ink.json$")]).isEmpty else {
        throw NotebookStorageError.corruptRecord(rootAddress)
      }
      return
    }
    guard let clock = try root.value["stamp"]?.decode(VersionStamp.self), clock.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.corruptRecord(rootAddress)
    }
    let canonicalRoot = try NotebookRecordCodec.encode(.encode(SpatialInkJournal(stamp: clock)), file: file).first!
    guard root == canonicalRoot else { throw NotebookStorageError.corruptRecord(rootAddress) }
    while true {
      let rows = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address>? AND address<? ORDER BY address LIMIT 64",
        [.text(manifestHash), .text(after), .text("spatial-ink.json$")])
      if rows.isEmpty { break }
      for row in rows {
        let address = row[0].text!; after = address
        let prefix = rootAddress + "/actions/@"
        guard address.hasPrefix(prefix) else { throw NotebookStorageError.invalidTransaction("spatial ink address") }
        let parts = address.dropFirst(prefix.count).components(separatedBy: "/")
        guard let id = UUID(uuidString: parts[0]), parts[0] == id.uuidString.lowercased(),
          parts.count == 1 || (parts.count == 2 && parts[1] == "spans") else {
          throw NotebookStorageError.invalidTransaction("spatial ink action address")
        }
        let actionAddress = prefix + id.uuidString.lowercased()
        guard let delivered = try incoming(actionAddress) else {
          throw NotebookStorageError.invalidTransaction("spans require their immutable action header")
        }
        // The action's header sorts before its spans. It validates both once.
        if parts.count == 2 { continue }
        let header = try delivered.value.decode(SpatialInkActionHeader.self)
        guard header.isValid, header.id == id, clock >= header.stateStamp,
          delivered.parent == rootAddress, delivered.collection == "actions", delivered.member == parts[0],
          delivered.collections == [.init(path: ["spans"], kind: .value)],
          delivered.value == (try JSONValue.encode(header)) else { throw NotebookStorageError.corruptRecord(actionAddress) }
        let spansAddress = actionAddress + "/spans", spans = try incoming(spansAddress)
        if let old = try storedFragments(address: actionAddress, descendants: false).first {
          let previous = try old.value.decode(SpatialInkActionHeader.self)
          guard previous.isValid, previous.id == id, previous.stamp == header.stamp,
            previous.tool == header.tool, previous.color == header.color else { throw NotebookStorageError.transactionConflict }
          if let spans {
            // Compare exact addressed immutable bytes, without decoding samples.
            let canonical = NotebookStoredFragment(address: spansAddress, file: file, parent: actionAddress,
              collection: "spans", member: "", position: 0, value: spans.value, collections: [])
            guard spans == canonical,
              try storedFragments(address: spansAddress, descendants: false) == [spans] else { throw NotebookStorageError.transactionConflict }
          }
          _ = try publishSpatialInk(.state(actionID: id, creationStamp: header.stamp,
            isActive: header.isActive, stateStamp: header.stateStamp, journalStamp: clock), origin: .replication)
        } else {
          guard let spans, spans.address == spansAddress, spans.parent == actionAddress,
            spans.collection == "spans", spans.member.isEmpty, spans.position == 0, spans.collections.isEmpty else {
            throw NotebookStorageError.corruptRecord(spansAddress)
          }
          let value = delivered.value.setting("spans", spans.value)
          let action = try value.decode(SpatialInkAction.self)
          guard action.isValid, try JSONValue.encode(action) == value else { throw NotebookStorageError.corruptRecord(actionAddress) }
          _ = try publishSpatialInk(.append(action, journalStamp: clock), origin: .replication)
        }
      }
    }
    if let deliveredRoot {
      let old = try storedFragments(address: rootAddress, descendants: false).first
      let previousClock = try old?.value["stamp"]?.decode(VersionStamp.self)
      if old == nil || previousClock.map({ $0 < clock }) == true { try writeFragment(deliveredRoot, database: database) }
    }
  }
}
