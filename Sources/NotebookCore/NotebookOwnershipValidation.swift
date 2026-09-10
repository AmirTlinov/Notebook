import Foundation

extension NotebookStore {
  /// Derived address indexes are part of the command transaction. Validation
  /// visits only changed owners and dependency edges. Previously committed
  /// page memberships remain valid until one of their two endpoints changes.
  func validateChangedOwnership(database: NotebookSQLConnection) throws {
    try database.visitChanges { change in
      let address = change.address
      if address.hasPrefix("workspace.json#/items/@"), address.contains("/pageIDs/@") {
        let parts = address.dropFirst("workspace.json#/items/@".count).components(separatedBy: "/pageIDs/@")
        guard parts.count == 2, let item = UUID(uuidString: parts[0]), let page = UUID(uuidString: parts[1]) else {
          throw NotebookStorageError.corruptRecord("page membership address")
        }
        try database.noteOwner(.item, item.uuidString.lowercased()); try database.noteOwner(.page, page.uuidString.lowercased())
      } else if address.hasPrefix("pages/"), address.hasSuffix(".json#"),
        let page = UUID(uuidString: String(address.dropFirst(6).dropLast(6))) {
        try database.noteOwner(.page, page.uuidString.lowercased())
      }
    }
    guard try database.hasOwner(.item) || database.hasOwner(.page) || database.hasOwner(.board) || database.hasOwner(.cover) else { return }
    guard try hasStoredValue("workspace.json") else { return }
    let count = Int(try database.rows("SELECT value FROM metadata WHERE key='item_count'").first?[0].text ?? "0") ?? 0
    guard count > 0 else { throw NotebookStorageError.invalidTransaction("workspace retains one item") }
    try database.visitOwners(.item) { id in
      guard let itemID = UUID(uuidString: id) else { throw NotebookStorageError.corruptRecord("item identity") }
      let address = "workspace.json#/items/@" + id
      let item = try storedFragments(address: address, descendants: false).first
      let owners = try database.rows("SELECT board_id,address FROM spatial_entries WHERE owner_id=? AND kind='item' LIMIT 2", [.text(id)])
      if item == nil {
        guard owners.isEmpty else { throw NotebookStorageError.corruptRecord("deleted item remains placed: " + id) }
        return
      }
      guard owners.count == 1, let boardID = owners[0][0].text,
        try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + boardID)]).isEmpty else {
        throw NotebookStorageError.corruptRecord("item requires exactly one live board: " + id)
      }
      let kind = item?.value["kind"]?.string
      if kind == WorkspaceItemKind.notebook.rawValue {
        guard item?.collections.contains(.init(path: ["pageIDs"], kind: .array)) == true,
          try pageCount(in: itemID) > 0 else {
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
    try database.visitOwners(.page) { pageID in
      // record_identity answers this one UUID even in a notebook with 100000
      // sheets. LIMIT 1 on a missing-dependency anti-join would still scan all.
      let owners = try database.rows("SELECT parent FROM records INDEXED BY record_identity WHERE file='workspace.json' AND collection='pageIDs' AND member=? LIMIT 2", [.text(pageID)])
      guard owners.count <= 1 else { throw NotebookStorageError.corruptRecord("page has multiple owners") }
      if let parent = owners.first?[0].text {
        let item = try storedFragments(address: parent, descendants: false).first
        guard item?.value["kind"]?.string == WorkspaceItemKind.notebook.rawValue,
          try hasStoredValue(pageFile(UUID(uuidString: pageID)!)) else { throw NotebookStorageError.corruptRecord("notebook page dependency: " + pageID) }
      }
    }
    try database.visitOwners(.board) { id in
      let exists = try !database.rows("SELECT 1 FROM records WHERE address=?", [.text("board.json#/boards/@" + id)]).isEmpty
      if !exists, try !database.rows("SELECT 1 FROM item_owners WHERE board_id=? LIMIT 1", [.text(id)]).isEmpty {
        throw NotebookStorageError.corruptRecord("removed board still owns items: " + id)
      }
    }
    try database.visitOwners(.cover) { address in
      let rows = try database.rows("SELECT s.owner_id FROM spatial_entries s LEFT JOIN item_owners o ON o.item_id=s.owner_id AND o.board_id=s.board_id WHERE s.address=? AND s.kind='coverElement' AND o.item_id IS NULL LIMIT 1", [.text(address)])
      guard rows.isEmpty else { throw NotebookStorageError.corruptRecord("cover element belongs to another board") }
    }
  }
}
