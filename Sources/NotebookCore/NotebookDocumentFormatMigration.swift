import Foundation

extension NotebookStore {
  /// The approved current-workspace cutover is deletion, not conversion. Old
  /// immutable blobs and archive manifests remain history, never recovery input.
  func retireStoredBlockDocuments(database: NotebookSQLConnection) throws {
    guard currentSQL === database, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let cursor = try currentChangeCursor()
    guard try !hasPendingPeerDelivery(through: cursor, database: database) else {
      throw CollaborationError("document_migration_pending_peer",
        "Перед обновлением формата документов завершите передачу сопряжённому устройству. Неподтверждённые изменения, пространство и ключи не будут сброшены.")
    }
    try database.run("CREATE TEMP TABLE retired_documents(id TEXT PRIMARY KEY) WITHOUT ROWID")
    try database.run("CREATE TEMP TABLE retired_document_actions(id TEXT PRIMARY KEY) WITHOUT ROWID")
    defer {
      try? database.run("DROP TABLE retired_documents")
      try? database.run("DROP TABLE retired_document_actions")
    }
    func contains(_ id: String?, in table: String = "retired_documents") throws -> Bool {
      guard let id else { return false }
      return try !database.rows("SELECT 1 FROM \(table) WHERE id=?", [.text(id.lowercased())]).isEmpty
    }
    // Bound decoding to one addressed record. In particular this never loads
    // all receipts, documents, notebook pages or historical snapshots at once.
    func visit(_ prefix: String, _ body: (NotebookStoredFragment) throws -> Void) throws {
      var after = prefix
      while let row = try database.rows("SELECT r.address,b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file>=? AND r.file<? AND r.parent IS NULL AND r.address>? ORDER BY r.address LIMIT 1",
        [.text(prefix), .text(prefix + "\u{10ffff}"), .text(after)]).first {
        try Task.checkCancellation()
        after = row[0].text!
        try body(database.decodedStoredFragment(from: row[1].blob!))
      }
    }
    try visit("documents/") { row in
      if row.value["format"] == .number(Double(DocumentDocument.formatVersion)) { return }
      guard [.number(1), .number(2)].contains(row.value["format"] ?? .null),
        let id = row.value["id"]?.string.flatMap(UUID.init(uuidString:)), row.file == documentFile(id) else {
        throw NotebookStorageError.corruptRecord(row.address)
      }
      try database.run("INSERT INTO retired_documents VALUES(?)", [.text(id.uuidString.lowercased())])
    }
    let legacyKinds: Set<String> = ["insertBlock", "updateBlock", "setBlockState", "removeBlock", "reorderBlocks", "setPreamble", "replaceDocument"]
    func oldTarget(_ value: JSONValue?) throws -> Bool {
      guard let value, ["document", "cover"].contains(value["kind"]?.string ?? "") else { return false }
      return try contains(value["id"]?.string)
    }
    func oldAction(_ action: JSONValue) throws -> Bool {
      for op in action["operations"]?.array ?? [] {
        if try legacyKinds.contains(op["kind"]?.string ?? "") || oldTarget(op["target"]) { return true }
        if op["kind"] == .string("createDocument"),
          try contains(op["id"]?.string) || op["values"]?["blocks"] != nil || op["values"]?["paperSize"] != nil || op["values"]?["preamble"] != nil { return true }
        if ["renameItem", "moveItem"].contains(op["kind"]?.string ?? ""), try contains(op["id"]?.string) { return true }
      }
      return false
    }
    // A mixed transaction is indivisible: its complete inverse and pinned
    // results are invalidated, while all surviving material stays untouched.
    for prefix in ["collaboration/actions/", "local/action-submissions/"] {
      try visit(prefix) { row in
        guard let action = row.value["action"], try oldAction(action),
          let id = action["id"]?.string.flatMap(UUID.init(uuidString:)) else { return }
        try database.run("INSERT OR IGNORE INTO retired_document_actions VALUES(?)", [.text(id.uuidString.lowercased())])
      }
    }
    let error: JSONValue = .object(["code": .string("document_format_retired"),
      "message": .string("Старый документ удалён при переходе на файловый формат. Сохранённый исходник этого действия больше не восстанавливается и не выполняется повторно.")])
    // Stop only executable recovery. Already terminal effects and chat/run
    // history are evidence and need not be rewritten to remove an Undo path.
    try visit("local/script-runs/") { row in
      guard row.file.contains("/effects/"),
        var effect = try? row.value.decode(NotebookScriptEffect.self),
        ![.saved, .notSaved].contains(effect.state) else { return }
      let args = effect.arguments
      let affected = try contains(effect.id.uuidString, in: "retired_document_actions")
        || contains(args["actionID"]?.string, in: "retired_document_actions")
        || contains(args["documentID"]?.string) || oldAction(args)
      guard affected, let runID = row.file.split(separator: "/").dropFirst(2).first.flatMap({ UUID(uuidString: String($0)) }) else { return }
      effect.state = .notSaved; effect.value = nil; effect.error = error
      try saveScriptEffect(runID, effect: effect)
      _ = try setScriptRunState(runID, state: .interrupted, error: error)
    }
    try visit("local/script-exports/") { row in
      guard try contains(row.value["documentID"]?.string),
        ["queued", "running"].contains(row.value["status"]?.string ?? ""),
        let id = row.value["jobID"]?.string.flatMap(UUID.init(uuidString:)) else { return }
      try saveScriptExportJob(id, value: row.value.setting("status", .string("interrupted")).setting("error", error))
    }
    try visit("local/action-results/") { row in
      let id = row.file.split(separator: "/").dropFirst(2).first.map(String.init)
      if try contains(id, in: "retired_document_actions") { try removeFragment(row.address, database: database) }
    }
    for prefix in ["collaboration/actions/", "local/action-submissions/"] {
      try visit(prefix) { row in
        if try contains(row.value["action"]?["id"]?.string, in: "retired_document_actions") {
          try removeFragment(row.address, database: database)
        }
      }
    }
    for prefix in ["document-drafts/", "collaboration/render-requests/"] {
      try visit(prefix) { row in
        if try contains(row.value["edit"]?["documentID"]?.string) || oldTarget(row.value["target"]) {
          try removeFragment(row.address, database: database)
        }
      }
    }
    // Local Undo directories may mix ink and command references. Preserve
    // every unrelated entry rather than clearing the user's whole history.
    for row in try database.rows("SELECT key,value FROM metadata WHERE key LIKE 'native_history:%' OR key LIKE 'native_redo:%'") {
      let entries = try JSONDecoder().decode([PencilUndoHistory.Entry].self, from: Data(row[1].text!.utf8))
      let retained = try entries.filter { entry in
        if case .command(let id) = entry { return try !contains(id.uuidString, in: "retired_document_actions") }
        return true
      }
      if entries != retained {
        try database.run("UPDATE metadata SET value=? WHERE key=?", [.text(String(decoding: try Self.storageEncoder.encode(retained), as: UTF8.self)), row[0]])
      }
    }
    let count = try database.rows("SELECT COUNT(*) FROM retired_documents").first![0].integer!
    if count > 0 {
      let header = try workspaceHeader(), actor = header.stamp.actor
      let live = try database.rows("SELECT d.id FROM retired_documents d JOIN records r ON r.parent='workspace.json#' AND r.collection='items' AND r.member=d.id ORDER BY d.id").compactMap { $0[0].text.flatMap(UUID.init(uuidString:)) }
      if live.count == header.itemCount {
        let before = try loadIndex(), boardBefore = try loadBoard(items: before.items)
        var after = before, boardAfter = boardBefore
        guard let created = after.createNotebook(title: "", actor: actor, pageSize: .init(width: 834, height: 1194)),
          boardAfter.addItem(created.item.id, to: header.rootBoardID, near: .zero, actor: actor) else {
          throw NotebookStorageError.invalidTransaction("document retirement replacement")
        }
        _ = try saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter, pages: [created.page])
      }
      for id in live { try deleteWorkspaceItemContent(itemID: id, actor: actor, human: true) }
      try visit("documents/") { row in
        guard try contains(row.value["id"]?.string), let id = row.value["id"]?.string.flatMap(UUID.init(uuidString:)) else { return }
        try removeFragment(row.address, database: database)
        try removeFragment(stateFile(id) + "#", database: database)
      }
      if let presence = try? loadPresence(),
        try contains(presence.focusedItemID?.uuidString) || contains(presence.selectedItemID?.uuidString) {
        let index = try loadIndex()
        try savePresence(.init(boardID: presence.boardID, mode: .board, camera: presence.camera, viewport: presence.viewport,
          selectedItemID: index.selectedItemID, notebookPageID: index.selectedPageID))
      }
      try publishRecords(writes: ["local/migrations/document-files-v3.json": .object([
        "sourceCursor": .number(Double(cursor)), "removedDocuments": .number(Double(count))])])
    }
    try database.run("INSERT INTO metadata(key,value) VALUES('document_outgoing_floor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(cursor))])
  }
}
