import Foundation

extension NotebookStore {
  /// Derived address indexes are part of the command transaction. Validation
  /// visits only changed owners; unrelated archive bodies are never decoded.
  func validateChangedOwnership(database: NotebookSQLConnection) throws {
    guard !database.touchedItemIDs.isEmpty || !database.dirtyBoardNodes.isEmpty || !database.touchedCoverAddresses.isEmpty else { return }
    guard try hasStoredValue("workspace.json") else { return }
    let count = Int(try database.rows("SELECT value FROM metadata WHERE key='item_count'").first?[0].text ?? "0") ?? 0
    guard count > 0 else { throw NotebookStorageError.invalidTransaction("workspace retains one item") }
    for itemID in database.touchedItemIDs {
      let id = itemID.uuidString.lowercased(), address = "workspace.json#/items/@" + id
      let item = try storedFragments(address: address, descendants: false).first
      let owners = try database.rows("SELECT board_id,address FROM spatial_entries WHERE owner_id=? AND kind='item' LIMIT 2", [.text(id)])
      if item == nil {
        guard owners.isEmpty else { throw NotebookStorageError.corruptRecord("deleted item remains placed: " + id) }
        continue
      }
      guard owners.count == 1, let boardID = owners[0][0].text,
        try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + boardID)]).isEmpty else {
        throw NotebookStorageError.corruptRecord("item requires exactly one live board: " + id)
      }
      let kind = item?.value["kind"]?.string
      if kind == WorkspaceItemKind.notebook.rawValue {
        let pages = try database.rows("SELECT r.member,p.address FROM records r LEFT JOIN records p ON p.address='pages/'||r.member||'.json#' WHERE r.parent=? AND r.collection='pageIDs' AND p.address IS NULL LIMIT 1", [.text(address)])
        guard pages.isEmpty, try !database.rows("SELECT 1 FROM records WHERE parent=? AND collection='pageIDs' LIMIT 1", [.text(address)]).isEmpty else {
          throw NotebookStorageError.corruptRecord("notebook page dependency: " + id)
        }
      } else if kind == WorkspaceItemKind.document.rawValue {
        guard try hasStoredValue(documentFile(itemID)), try hasStoredValue(stateFile(itemID)) else { throw NotebookStorageError.corruptRecord("document dependency: " + id) }
      } else if kind == WorkspaceItemKind.board.rawValue {
        guard try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + id)]).isEmpty else { throw NotebookStorageError.corruptRecord("portal board dependency: " + id) }
        var next: UUID? = itemID, visited = Set<UUID>()
        while let current = next {
          guard visited.insert(current).inserted else { throw NotebookStorageError.invalidTransaction("board cycle") }
          next = try ownerBoardID(of: current)
        }
      } else { throw NotebookStorageError.corruptRecord("item kind: " + id) }
    }
    for id in database.dirtyBoardNodes {
      let exists = try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + id)]).isEmpty
      if !exists, try !database.rows("SELECT 1 FROM item_owners WHERE board_id=? LIMIT 1", [.text(id)]).isEmpty {
        throw NotebookStorageError.corruptRecord("removed board still owns items: " + id)
      }
    }
    for address in database.touchedCoverAddresses {
      let rows = try database.rows("SELECT s.owner_id FROM spatial_entries s LEFT JOIN item_owners o ON o.item_id=s.owner_id AND o.board_id=s.board_id WHERE s.address=? AND s.kind='coverElement' AND o.item_id IS NULL LIMIT 1", [.text(address)])
      guard rows.isEmpty else { throw NotebookStorageError.corruptRecord("cover element belongs to another board") }
    }
  }
}
