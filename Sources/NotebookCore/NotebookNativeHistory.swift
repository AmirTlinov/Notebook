import Foundation

/// Device-local history is an ordered directory of native action identities.
/// The same transaction writes material and its history; replicas never invent
/// local Undo entries from a peer's receipt or a wall-clock timestamp.
extension NotebookStore {
  public func nativeHistory(domain: PencilUndoHistory.Domain, actor: UUID) throws -> [PencilUndoHistory.Entry] {
    try readTransaction { _ in
      let key = Self.nativeHistoryKey(domain: domain, actor: actor)
      guard let value = try currentSQL!.rows("SELECT value FROM metadata WHERE key=?", [.text(key)]).first?[0].text else { return [] }
      guard value.utf8.count <= 65_536 else { throw NotebookStorageError.corruptRecord("native history") }
      let entries = try JSONDecoder().decode([PencilUndoHistory.Entry].self, from: Data(value.utf8))
      guard entries.count <= 32, entries.allSatisfy({ entry in
        if case .ink(let ids) = entry { return !ids.isEmpty && ids.count <= 32 }; return true
      }) else { throw NotebookStorageError.corruptRecord("native history") }
      // The local directory does not overrule material or a peer's inverse.
      // Check bounded headers only; never decode ink measurements to find Undo.
      return try entries.filter { entry in
        switch entry {
        case .command(let id):
          // Only the native writer puts commands in this actor/domain's
          // directory. Checking their saved phase must not decode every
          // changed field of a potentially large previous command.
          let address = "collaboration/actions/" + id.uuidString.lowercased() + ".json#"
          guard let row = try currentSQL!.rows("SELECT status FROM metadata_index WHERE address=? AND kind='action'", [.text(address)]).first else { return false }
          guard let status = row[0].text, ["active", "undone"].contains(status) else {
            throw NotebookStorageError.corruptRecord("native history phase: " + address)
          }
          return status == "active"
        case .ink(let ids):
          return try ids.contains { id in
            let address = domain.kind == .page
              ? pageFile(domain.id) + "#/drawingData/actions/@" + id.uuidString.lowercased()
              : "spatial-ink.json#/actions/@" + id.uuidString.lowercased()
            guard let row = try storedFragments(address: address, descendants: false).first,
              row.value["isActive"] == .bool(true) else { return false }
            if domain.kind == .page { return true }
            return try !currentSQL!.rows("SELECT 1 FROM ink_surfaces WHERE address=? AND kind=? AND owner_id=?",
              [.text(address), .text(domain.kind.rawValue), .text(domain.id.uuidString.lowercased())]).isEmpty
          }
        }
      }
    }
  }

  func recordNativeHistory(_ entry: PencilUndoHistory.Entry, domain: PencilUndoHistory.Domain, actor: UUID, removing: Bool = false) throws {
    var history = PencilUndoHistory()
    history.restore(try nativeHistory(domain: domain, actor: actor), for: domain)
    switch entry {
    case .command(let id):
      if removing { history.didUndoCommand(domain: domain, actionID: id) }
      else { history.recordCommand(domain: domain, actionID: id) }
    case .ink(let ids):
      if removing { history.didRemoveContribution(ids, for: domain) }
      else {
        guard ids.count == 1, let id = ids.first else { throw NotebookStorageError.invalidTransaction("native contact history") }
        history.recordAction(domain: domain, actionID: id)
      }
    }
    let value = String(decoding: try Self.storageEncoder.encode(history.entries(for: domain)), as: UTF8.self)
    try currentSQL!.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value",
      [.text(Self.nativeHistoryKey(domain: domain, actor: actor)), .text(value)])
  }

  private static func nativeHistoryKey(domain: PencilUndoHistory.Domain, actor: UUID) -> String {
    "native_history:" + actor.uuidString.lowercased() + ":" + domain.key
  }
}
