import Foundation

extension NotebookStore {
  public func ownerItemID(ofPage pageID: UUID) throws -> UUID? {
    try sqlRead { database in
      let parent = try database.rows("SELECT parent FROM records WHERE file='workspace.json' AND collection='pageIDs' AND member=? LIMIT 2", [.text(pageID.uuidString.lowercased())])
      guard parent.count <= 1 else { throw NotebookStorageError.corruptRecord("page has multiple owners") }
      return parent.first?[0].text?.components(separatedBy: "@").last.flatMap(UUID.init(uuidString:))
    }
  }

  /// A command reads addressed members and their causal metadata, not the
  /// archive. The resulting dictionaries are projections, so they must only
  /// be published through a baseline delta, never through whole-file replace.
  func actionSourceProjection(_ action: CollaborationAction, receipt: CollaborationReceipt? = nil,
    references: [CollaborationReference] = []) throws -> [String: JSONValue] {
    let header = try workspaceHeader()
    var itemIDs = Set<UUID>(), boardIDs: Set<UUID> = [header.rootBoardID]
    var pageIDs = Set<UUID>(), documentIDs = Set<UUID>()
    var elementIDs: [UUID: Set<String>] = [:], creationInkSurfaces = Set<SurfaceID>()
    var spatialActionIDs = Set<UUID>()
    func include(_ target: CollaborationTarget) throws {
      switch target.kind {
      case .workspace: break
      case .page:
        pageIDs.insert(target.id)
        if let owner = try ownerItemID(ofPage: target.id) { itemIDs.insert(owner) }
      case .document: itemIDs.insert(target.id); documentIDs.insert(target.id)
      case .board: boardIDs.insert(target.id)
      case .cover:
        itemIDs.insert(target.id)
        if let board = target.boardID { boardIDs.insert(board) }
      }
    }
    for target in action.operations.map(\.target) + action.expected.map(\.target)
      + action.references.map(\.target) + references.map(\.target) + (action.additionalOwners ?? []) { try include(target) }
    for operation in action.operations {
      if [.createNotebook, .createDocument, .createBoard, .renameItem, .moveItem].contains(operation.kind),
        let id = operation.id.flatMap(UUID.init(uuidString:)) { itemIDs.insert(id) }
      if operation.kind == .createNotebook, let page = operation.values["pageID"]?.string.flatMap(UUID.init(uuidString:)) { pageIDs.insert(page) }
      if operation.kind == .createDocument, let id = operation.id.flatMap(UUID.init(uuidString:)) { documentIDs.insert(id) }
      if operation.kind == .createBoard, let id = operation.id.flatMap(UUID.init(uuidString:)) { boardIDs.insert(id) }
      if operation.kind == .stackItems { itemIDs.formUnion(try operation.values["itemIDs"]?.decode([UUID].self) ?? []) }
      if [.insertElement, .updateElement, .setElementState, .removeElement, .reorderElements].contains(operation.kind), operation.target.kind != .page {
        let board = operation.target.kind == .board ? operation.target.id : operation.target.boardID
        if let board {
          if let id = operation.id { elementIDs[board, default: []].insert(id) }
          if operation.kind == .reorderElements {
            let ids = try operation.values["ids"]?.decode([String].self) ?? []
            elementIDs[board, default: []].formUnion(ids)
            let surface = operation.target.kind == .board ? "element" : "coverElement"
            let count = try currentSQL!.rows("SELECT count(*) FROM spatial_entries WHERE board_id=? AND kind=? AND (?='element' OR owner_id=?)", [.text(board.uuidString.lowercased()), .text(surface), .text(surface), .text(operation.target.id.uuidString.lowercased())]).first![0].integer!
            guard count == ids.count else { throw CollaborationError("invalid_operation", "Порядок перечисляет всю выбранную поверхность ровно один раз.") }
          }
        }
      }
      if operation.kind == .appendInkStroke, operation.target.kind != .page {
        if let id = operation.id.flatMap(UUID.init(uuidString:)) { spatialActionIDs.insert(id) }
      }
    }
    // Undo also considers fields created by the original operation and any
    // human adoption inside a newly created board, without scanning its tree.
    if let receipt {
      for change in receipt.changes {
        if change.file == "board.json", change.path.count >= 2, case .member(let id) = change.path[1], let board = UUID(uuidString: id) {
          boardIDs.insert(board)
          if change.path.count >= 5, change.path[3] == .field("elements"), case .member(let id) = change.path[4] { elementIDs[board, default: []].insert(id) }
        }
      }
      for operation in receipt.action.operations where [.createNotebook, .createDocument, .createBoard].contains(operation.kind) {
        guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { continue }
        creationInkSurfaces.insert(.cover(id))
        if operation.kind == .createBoard { creationInkSurfaces.insert(.board(id)) }
      }
    }
    var boardRows: [String: NotebookStoredFragment] = [:]
    func insert(_ rows: [NotebookStoredFragment]) { for row in rows { boardRows[row.address] = row } }
    for id in itemIDs {
      if let node = try readBoardItem(id) {
        let address = "board.json#/boards/@" + node.id.uuidString.lowercased()
        insert(try storedFragments(address: address, descendants: false))
        for placement in try currentSQL!.rows("SELECT address FROM item_owners WHERE item_id=?", [.text(id.uuidString.lowercased())]) { insert(try storedFragments(address: placement[0].text!)) }
        itemIDs.formUnion(node.board.itemIDs); boardIDs.insert(node.id)
      }
    }
    var pending = Array(boardIDs), visited = Set<UUID>()
    while let id = pending.popLast(), visited.insert(id).inserted {
      let address = "board.json#/boards/@" + id.uuidString.lowercased()
      insert(try storedFragments(address: address, descendants: false))
      if let owner = try ownerBoardID(of: id) {
        itemIDs.insert(id); boardIDs.insert(owner); pending.append(owner)
        for placement in try currentSQL!.rows("SELECT address FROM item_owners WHERE item_id=?", [.text(id.uuidString.lowercased())]) {
          let rows = try storedFragments(address: placement[0].text!); insert(rows)
          if let stack = rows.first?.value["itemIDs"] { itemIDs.formUnion(try stack.decode([UUID].self)) }
        }
      }
    }
    for (board, ids) in elementIDs {
      let address = "board.json#/boards/@" + board.uuidString.lowercased()
      for id in ids {
        let rows = try storedFragments(address: address + "/board/elements/@" + fieldKey([collaborationIdentity(id)]))
        insert(rows)
        if let surface = try rows.first?.value["surface"]?.decode(SurfaceID.self), surface.kind == .cover, let id = surface.ownerID {
          itemIDs.insert(id)
          for placement in try currentSQL!.rows("SELECT address FROM item_owners WHERE item_id=?", [.text(id.uuidString.lowercased())]) { insert(try storedFragments(address: placement[0].text!)) }
        }
      }
    }
    if let receipt {
      for operation in receipt.action.operations where operation.kind == .createBoard {
        guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { continue }
        let address = "board.json#/boards/@" + id.uuidString.lowercased()
        for row in try currentSQL!.rows("SELECT address FROM records WHERE parent=? AND collection IN ('board/freeItems','board/stacks','board/elements') LIMIT 1", [.text(address)]) {
          let rows = try storedFragments(address: row[0].text!); insert(rows)
          if let first = rows.first, first.collection == "board/freeItems", let id = first.value["itemID"]?.string.flatMap(UUID.init(uuidString:)) { itemIDs.insert(id) }
          if let stack = rows.first?.value["itemIDs"] { itemIDs.formUnion(try stack.decode([UUID].self)) }
        }
      }
    }
    var items: [WorkspaceItem] = []
    for id in itemIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let item = try readItemHeader(id) else { continue }
      var pages = item.firstPageID.map { [$0] } ?? []
      for page in pageIDs where try ownerItemID(ofPage: page) == id && !pages.contains(page) { pages.append(page) }
      items.append(.init(id: id, kind: item.kind, title: item.title, pageIDs: pages))
    }
    if let first = try currentSQL!.rows("SELECT member FROM records WHERE parent='workspace.json#' AND collection='items' ORDER BY position LIMIT 1").first?[0].text.flatMap(UUID.init(uuidString:)),
      !items.contains(where: { $0.id == first }), let item = try readItemHeader(first) { items.insert(item.item, at: 0) }
    guard let first = items.first else { throw NotebookStorageError.corruptRecord("empty workspace") }
    let workspace = try workspaceProjection(items: items, selectedItemID: first.id, selectedPageID: first.pageIDs.first)
    var rows = Array(boardRows.values)
    for id in boardIDs { try appendBoardCausalFragments(to: &rows, address: "board.json#/boards/@" + id.uuidString.lowercased()) }
    rows += try storedFragments(address: "board.json#", descendants: false)
    var files = ["workspace.json": try JSONValue.encode(workspace), "board.json": try NotebookRecordCodec.decode(rows, root: "board.json#")]
    for id in pageIDs where try hasStoredValue(pageFile(id)) { files[pageFile(id)] = try storedValue(pageFile(id)) }
    for item in items where item.kind == .document {
      let file = documentFile(item.id)
      if documentIDs.contains(item.id) {
        if try hasStoredValue(file) { files[file] = try storedValue(file); files[stateFile(item.id)] = try storedValue(stateFile(item.id)) }
      } else {
        let rows = try storedFragments(address: file + "#", descendants: false)
        if !rows.isEmpty { files[file] = try NotebookRecordCodec.decode(rows, root: file + "#") }
      }
    }
    var inkRows = try storedFragments(address: "spatial-ink.json#", descendants: false), seenInk = Set<String>()
    // Append checks its UUID globally, not just on the requested surface. Undo
    // reads that same immutable action. Neither operation needs the thousands
    // of other contacts which happen to share its board or cover.
    for id in spatialActionIDs.sorted() {
      let address = "spatial-ink.json#/actions/@" + id.uuidString.lowercased()
      seenInk.insert(address)
      inkRows += try storedFragments(address: address)
    }
    // Adoption of a created owner is a separate read contract: it must still
    // retain later contacts before removing that owner as a whole.
    for surface in creationInkSurfaces {
      guard let id = surface.ownerID else { continue }
      for row in try currentSQL!.rows("SELECT address FROM ink_surfaces WHERE kind=? AND owner_id=?", [.text(surface.kind.rawValue), .text(id.uuidString.lowercased())]) where seenInk.insert(row[0].text!).inserted {
        inkRows += try storedFragments(address: row[0].text!)
      }
    }
    files["spatial-ink.json"] = try NotebookRecordCodec.decode(inkRows, root: "spatial-ink.json#")
    return files
  }
}
