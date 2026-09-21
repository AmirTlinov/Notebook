import Foundation

extension NotebookStore {
  /// A single WAL cut, with bounded manifest pages. This publishes no local
  /// edits and does not reset the archive, device identity, or direct journal.
  func cloudSnapshot(source: NotebookReplicationSource) throws -> NotebookReplicationDelivery {
    let database = currentSQL!, workspace = try workspaceHeader()
    let through = try currentChangeCursor()
    guard through > 0 else { throw NotebookStorageError.invalidTransaction("snapshot requires a saved workspace") }
    try database.run("CREATE TEMP TABLE cloud_snapshot(address TEXT PRIMARY KEY,blob_hash TEXT)")
    var after = "", roots: Set<String> = []
    func absent(_ address: String) throws {
      try database.run("INSERT OR IGNORE INTO cloud_snapshot(address) SELECT ? WHERE NOT EXISTS(SELECT 1 FROM records WHERE address=?)", [.text(address), .text(address)])
    }
    while true {
      let rows = try database.rows("SELECT address,file,hash,parent,collection,member FROM records WHERE address>? ORDER BY address LIMIT 64", [.text(after)])
      guard !rows.isEmpty else { break }
      for row in rows {
        let address = row[0].text!, file = row[1].text!; after = address
        guard !Self.localRecord(file) else { continue }
        try database.run("INSERT OR REPLACE INTO cloud_snapshot VALUES(?,?)", [.text(address), .text(row[2].text!)])
        if row[4].text == "pageOrders" {
          let order = try database.decodedStoredFragment(from:database.blob(row[2].text!)).value.decode(NotebookPageOrderRegister.self)
          roots.insert(order.visibleRoot); roots.formUnion(order.heads.map(\.valueRoot))
          guard roots.count <= 131_072 else { throw NotebookStorageError.limitExceeded("page_order_dependencies") }
        }
        guard row[4].text?.hasSuffix("collaboration/fields") == true, let parent = row[3].text, let member = row[5].text else { continue }
        let key = member.components(separatedBy: "/")
        if key.count == 3, key[0] == "items", key[2] == "exists" {
          let item = "workspace.json#/items/@" + key[1]
          if try database.rows("SELECT 1 FROM records WHERE address=?", [.text(item)]).isEmpty {
            try absent(item)
            try absent("board.json#/boards/@" + key[1])
            try absent("documents/" + key[1] + ".json#")
            try absent("document-states/" + key[1] + ".json#")
          }
        } else if key.count == 4, key[0] == "items", key[2] == "pageIDs" {
          let address = "workspace.json#/items/@" + key[1] + "/pageIDs/@" + key[3]
          if try database.rows("SELECT 1 FROM records WHERE address=?", [.text(address)]).isEmpty {
            try absent(address); try absent("pages/" + key[3] + ".json#")
          }
        } else if key.count == 3, key[0] == "elements", key[2] == "exists" {
          // Keys already carry JSON-pointer escaping; parent defines the owner.
          let collection = file == "board.json" ? "board/elements" : "elements"
          try absent(parent + "/" + collection + "/@" + key[1])
        }
      }
    }
    // Retain explicit removals not represented by an existence clock (for
    // example an empty computation member). History is never pruned here.
    after = ""
    while true {
      let rows = try database.rows("SELECT DISTINCT c.address FROM change_records c LEFT JOIN records r ON r.address=c.address WHERE r.address IS NULL AND c.address>? ORDER BY c.address LIMIT 64", [.text(after)])
      guard !rows.isEmpty else { break }
      for row in rows {
        let address = row[0].text!; after = address
        let file = String(address.split(separator: "#", maxSplits: 1)[0])
        guard !Self.localRecord(file), !address.contains("/collaboration/fields/") else { continue }
        try absent(address)
      }
    }
    let count = try database.rows("SELECT count(*) FROM cloud_snapshot").first![0].integer!
    guard count <= 8_388_608 else { throw NotebookStorageError.limitExceeded("snapshot_records") }
    let transaction = UUID(); var parts: [String] = []; after = ""
    while true {
      let rows = try database.rows("SELECT address,blob_hash FROM cloud_snapshot WHERE address>? ORDER BY address LIMIT 16384", [.text(after)])
      guard let last = rows.last else { break }
      let manifest = NotebookChangeManifest(transactionID: transaction, workspaceID: workspace.workspaceID,
        records: rows.map { .init(address: $0[0].text!, blobHash: $0[1].text) })
      parts.append(try database.putBlob(Self.storageEncoder.encode(manifest))); after = last[0].text!
    }
    let data = try Self.storageEncoder.encode(NotebookChangeManifest(transactionID: transaction, workspaceID: workspace.workspaceID, records: [], parts: parts, pageOrderRoots: roots.sorted()))
    let change = try NotebookDurableChange(sequence: through, transactionID: transaction, manifestHash: database.putBlob(data), byteCount: data.count)
    try database.run("DROP TABLE cloud_snapshot")
    return .init(source: source, change: change, isSnapshot: true)
  }
}
