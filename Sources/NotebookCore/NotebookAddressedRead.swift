import Foundation

extension NotebookStore {
  /// Admit indexed fragment lengths before decoding any value. The caller
  /// names disjoint points/subtrees, never a partial archive to be replaced.
  func boundedStoredFragments(_ roots: [(String, Bool)], maximumCount: Int,
    maximumBytes: Int64, budget: String) throws -> [NotebookStoredFragment] {
    guard maximumCount > 0, maximumBytes >= 0, roots.count <= maximumCount else {
      throw NotebookStorageError.limitExceeded(budget)
    }
    return try sqlRead { database in
      var metadata: [(address: String, hash: String)] = [], remainingBytes = maximumBytes
      for (address, descendants) in roots {
        let point = try database.rows("SELECT r.address,r.hash,length(b.data) FROM records r LEFT JOIN blobs b ON b.hash=r.hash WHERE r.address=?", [.text(address)])
        let children = try descendants ? database.rows("""
          SELECT r.address,r.hash,length(b.data) FROM records r LEFT JOIN blobs b ON b.hash=r.hash
          WHERE r.address>=? AND r.address<? ORDER BY r.address LIMIT ?
          """, [.text(address + "/"), .text(address + "0"), .integer(Int64(maximumCount - metadata.count + 1))]) : []
        for row in point + children {
          guard let bytes = row[2].integer, bytes >= 0 else { throw NotebookStorageError.corruptRecord(row[0].text!) }
          guard metadata.count < maximumCount, bytes <= remainingBytes else {
            throw NotebookStorageError.limitExceeded(budget)
          }
          remainingBytes -= bytes
          metadata.append((row[0].text!, row[1].text!))
        }
      }
      guard Set(metadata.map(\.address)).count == metadata.count else {
        throw NotebookStorageError.invalidTransaction("overlapping fragment read")
      }
      return try metadata.map { row in
        let value = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(row.hash))
        guard value.address == row.address, value.position >= 0, value.value.isValid else {
          throw NotebookStorageError.corruptRecord(row.address)
        }
        return value
      }
    }
  }

  func storedFragments(address: String, descendants: Bool = true) throws -> [NotebookStoredFragment] {
    try sqlRead { database in
      // The addressed subtree drives both joins. Without CROSS JOIN, SQLite
      // can scan every record before filtering this one owner's descendants.
      let query = descendants
        ? "WITH RECURSIVE subtree(address) AS (SELECT address FROM records WHERE address=? UNION ALL SELECT r.address FROM subtree s CROSS JOIN records r ON r.parent=s.address) SELECT b.data FROM subtree s CROSS JOIN records r ON r.address=s.address CROSS JOIN blobs b ON b.hash=r.hash"
        : "SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?"
      return try database.rows(query, [.text(address)]).map { try JSONDecoder().decode(NotebookStoredFragment.self, from: $0[0].blob!) }
    }
  }

  func storedMember(file: String, collection: String, id: String) throws -> JSONValue? {
    let address = file + "#/" + collection + "/@" + fieldKey([collaborationIdentity(id)])
    let rows = try storedFragments(address: address)
    return rows.isEmpty ? nil : try NotebookRecordCodec.decode(rows, root: address)
  }

  public func workspaceHeader() throws -> NotebookWorkspaceHeader {
    try readTransaction { _ in
      guard let root = try storedFragments(address: "workspace.json#", descendants: false).first,
        let id = root.value["rootBoardID"]?.string.flatMap(UUID.init(uuidString:)),
        let stamp = try root.value["stamp"]?.decode(VersionStamp.self) else { throw CocoaError(.fileNoSuchFile) }
      let count = Int64(try currentSQL!.rows("SELECT value FROM metadata WHERE key='item_count'").first?[0].text ?? "0") ?? 0
      let workspaceID = try currentSQL!.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:))
      guard let workspaceID else { throw NotebookStorageError.corruptRecord("workspace identity") }
      let presence = try? loadPresence()
      let boardRevision = try currentSQL!.rows("SELECT value FROM metadata WHERE key='board_revision'").first?[0].text
      let inkStamp = try storedFragments(address: "spatial-ink.json#", descendants: false).first?.value["stamp"]?.decode(VersionStamp.self)
      return .init(workspaceID: workspaceID, rootBoardID: id, stamp: stamp, itemCount: Int(count), selectedItemID: presence?.selectedItemID,
        selectedPageID: presence?.notebookPageID, boardRevision: boardRevision, boardStamp: try storedFragments(address: "board.json#", descendants: false).first?.value["stamp"]?.decode(VersionStamp.self), spatialInkStamp: inkStamp, cursor: try currentChangeCursor())
    }
  }

  public func initializeWorkspace(actor: UUID, pageSize: PageSize, initialNotebookID: UUID = UUID(), initialPageID: UUID = UUID()) throws -> NotebookWorkspaceHeader {
    try commandTransaction {
      if try !hasStoredValue("workspace.json") {
        let initial = WorkspaceIndex.initial(actor: actor, pageSize: pageSize, itemID: initialNotebookID, pageID: initialPageID)
        let hierarchy = BoardHierarchy.initial(rootBoardID: initial.index.rootBoardID, itemIDs: [initialNotebookID], actor: actor)
        try saveWorkspaceBundle(index: initial.index, page: initial.page, board: hierarchy)
        try saveSpatialInk(.init(stamp: .init(counter: 0, actor: actor)))
      }
    }
    return try workspaceHeader()
  }

  public func pageID(at index: Int, in itemID: UUID) throws -> UUID? {
    guard index >= 0 else { throw NotebookStorageError.invalidTransaction("negative page index") }
    return try sqlRead { database in
      try database.rows("SELECT member FROM records WHERE parent=? AND collection='pageIDs' AND position=? ORDER BY member LIMIT 1", [.text("workspace.json#/items/@" + itemID.uuidString.lowercased()), .integer(Int64(index))]).first?[0].text.flatMap(UUID.init(uuidString:))
    }
  }

  public func pageCount(in itemID: UUID) throws -> Int {
    try sqlRead { Int(try $0.rows("SELECT count FROM item_page_counts WHERE address=?", [.text("workspace.json#/items/@" + itemID.uuidString.lowercased())]).first?[0].integer ?? 0) }
  }

  public func ownerBoardID(of itemID: UUID) throws -> UUID? {
    try sqlRead { try $0.rows("SELECT board_id FROM item_owners WHERE item_id=?", [.text(itemID.uuidString.lowercased())]).first?[0].text.flatMap(UUID.init(uuidString:)) }
  }

  public func readBoardNode(_ id: UUID) throws -> BoardNode? {
    try storedMember(file: "board.json", collection: "boards", id: id.uuidString)?.decode(BoardNode.self)
  }

  public func readSpatialInk(surfaces: [SurfaceID]) throws -> SpatialInkJournal {
    guard surfaces.count <= 8, Set(surfaces).count == surfaces.count else { throw NotebookStorageError.limitExceeded("ink_surfaces") }
    return try readTransaction { _ in
      let metadata = try storedFragments(address: "spatial-ink.json#", descendants: false).first
      let stamp = try metadata?.value["stamp"]?.decode(VersionStamp.self) ?? .init(counter: 0, actor: WorkspaceRoot.boardID)
      var addresses = Set<String>()
      for surface in surfaces {
        guard let id = surface.ownerID else { throw NotebookStorageError.invalidTransaction("surface owner") }
        addresses.formUnion(try currentSQL!.rows("SELECT address FROM ink_surfaces WHERE kind=? AND owner_id=?", [.text(surface.kind.rawValue), .text(id.uuidString.lowercased())]).compactMap { $0[0].text })
      }
      let actions = try addresses.sorted().map { address in try NotebookRecordCodec.decode(storedFragments(address: address), root: address).decode(SpatialInkAction.self) }
      return .init(actions: actions.sorted { $0.stamp < $1.stamp }, stamp: stamp)
    }
  }

  public func readWorkingSet(itemIDs: [UUID], pageIDs: [UUID], boardIDs: [UUID], surfaces: [SurfaceID]) throws -> NotebookWorkingSet {
    guard itemIDs.count + boardIDs.count <= 8, pageIDs.count <= 4,
      Set(itemIDs).count == itemIDs.count, Set(pageIDs).count == pageIDs.count, Set(boardIDs).count == boardIDs.count else { throw NotebookStorageError.limitExceeded("working_set") }
    return try readTransaction { _ in
      let items = try itemIDs.compactMap { try readItemHeader($0) }
      var pages: [UUID: PageDocument] = [:], documents: [UUID: DocumentDocument] = [:], states: [UUID: DocumentStateJournal] = [:]
      for id in pageIDs where try hasStoredValue(pageFile(id)) { pages[id] = try loadPage(id) }
      for item in items where item.kind == .document {
        if try hasStoredValue(documentFile(item.id)) { documents[item.id] = try loadDocument(item.id) }
        if try hasStoredValue(stateFile(item.id)) { states[item.id] = try loadDocumentState(item.id) }
      }
      // A working set never expands the active board into all its placements.
      // The scene-window query supplies its bounded board projection separately.
      let boards = try boardIDs.compactMap { id -> BoardNode? in
        let address = "board.json#/boards/@" + id.uuidString.lowercased()
        let rows = try storedFragments(address: address, descendants: false)
        return rows.isEmpty ? nil : try NotebookRecordCodec.decode(rows, root: address).decode(BoardNode.self)
      }
      return .init(header: try workspaceHeader(), items: items, boards: boards, pages: pages,
        documents: documents, states: states, ink: try readSpatialInk(surfaces: surfaces))
    }
  }

  func updateAddressIndexes(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    if fragment.parent == nil, fragment.file.hasPrefix("collaboration/render-requests/") {
      let request = try fragment.value.decode(TargetRenderRequest.self)
      try database.run("INSERT INTO metadata_index(address,kind,context_id,created_at,status) VALUES(?,'renderRequest',?,?,'pending') ON CONFLICT(address) DO UPDATE SET context_id=excluded.context_id,created_at=excluded.created_at", [.text(fragment.address), .text(Self.renderTargetKey(request.target)), .real(request.createdAt.timeIntervalSince1970)])
    }
    if fragment.parent == nil, fragment.file.hasPrefix("collaboration/actions/") {
      let receipt = try fragment.value.decode(CollaborationReceipt.self)
      try database.run("INSERT INTO metadata_index(address,kind,context_id,created_at) VALUES(?,'action',?,?) ON CONFLICT(address) DO UPDATE SET context_id=excluded.context_id,created_at=excluded.created_at", [.text(fragment.address), .text(receipt.action.resolvedContextID.uuidString.lowercased()), .real(receipt.createdAt.timeIntervalSince1970)])
    }
    if fragment.file.hasPrefix("collaboration/contexts/"), fragment.collection == "entries", let parent = fragment.parent {
      let entry = try fragment.value.decode(SharedContextEntry.self)
      try indexContextEntry(fragment, entry: entry, database: database)
      try database.run("INSERT INTO metadata_index(address,kind,context_id,created_at) VALUES(?,'context',NULL,?) ON CONFLICT(address) DO UPDATE SET created_at=MAX(created_at,excluded.created_at)", [.text(parent), .real(entry.createdAt.timeIntervalSince1970)])
    }
    if fragment.file == "spatial-ink.json", fragment.collection == "actions" {
      if try !database.rows("SELECT 1 FROM ink_surfaces WHERE address=? LIMIT 1", [.text(fragment.address)]).isEmpty { return }
      let action = try NotebookRecordCodec.decode(storedFragments(address: fragment.address), root: fragment.address).decode(SpatialInkAction.self)
      try database.run("DELETE FROM ink_surfaces WHERE address=?", [.text(fragment.address)])
      for surface in Set(action.spans.map(\.surface)) {
        guard let id = surface.ownerID else { throw NotebookStorageError.corruptRecord(fragment.address) }
        try database.run("INSERT INTO ink_surfaces(address,kind,owner_id) VALUES(?,?,?)", [.text(fragment.address), .text(surface.kind.rawValue), .text(id.uuidString.lowercased())])
      }
      return
    }
    guard fragment.file == "board.json", let parent = fragment.parent,
      let boardString = parent.components(separatedBy: "@").last, let boardID = UUID(uuidString: boardString),
      ["board/freeItems", "board/stacks", "board/elements"].contains(fragment.collection) else { return }
    let previousOwners = try database.rows("SELECT item_id FROM item_owners WHERE address=?", [.text(fragment.address)]).compactMap { $0[0].text.flatMap(UUID.init(uuidString:)) }
    for id in previousOwners { try database.noteOwner(.item, id.uuidString.lowercased()) }
    try database.run("DELETE FROM spatial_entries WHERE address=?", [.text(fragment.address)])
    try database.run("DELETE FROM item_owners WHERE address=?", [.text(fragment.address)])
    func geometry(_ id: UUID) throws -> WorkspaceItemGeometry {
      let header = try readItemHeader(id)
      if header?.kind == .document {
        guard let paper = try storedFragments(address: documentFile(id) + "#", descendants: false).first?.value["paperSize"]?.decode(DocumentPaperSize.self) else {
          throw NotebookStorageError.corruptRecord(documentFile(id))
        }
        return .document(paper)
      }
      return .notebook
    }
    func insert(id: String, kind: String, key: String, origin: WorldPoint, width: Double, height: Double, z: Double, owner: UUID? = nil) throws {
      let maximum = origin.offsetBy(x: width, y: height), layer = kind == "item" ? 1 : 0
      try database.run("INSERT INTO spatial_entries(entry_id,address,board_id,owner_id,kind,layer,z_index,paint_key,min_tx,min_ty,min_x,min_y,max_tx,max_ty,max_x,max_y) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
        .text(fragment.address + ":" + id), .text(fragment.address), .text(boardID.uuidString.lowercased()), .text(id), .text(kind), .integer(Int64(layer)), .real(z), .text(key),
        .integer(origin.tileX), .integer(origin.tileY), .real(origin.localX), .real(origin.localY), .integer(maximum.tileX), .integer(maximum.tileY), .real(maximum.localX), .real(maximum.localY)])
      if kind == "coverElement" { try database.noteOwner(.cover, fragment.address) }
      if let owner {
        try database.noteOwner(.item, owner.uuidString.lowercased())
        try database.run("INSERT INTO item_owners(item_id,board_id,address) VALUES(?,?,?) ON CONFLICT(item_id) DO UPDATE SET board_id=excluded.board_id,address=excluded.address", [.text(owner.uuidString.lowercased()), .text(boardID.uuidString.lowercased()), .text(fragment.address)])
      }
    }
    switch fragment.collection {
    case "board/freeItems":
      let item = try fragment.value.decode(FreeItemPlacement.self), size = try geometry(item.itemID)
      try insert(id: item.itemID.uuidString.lowercased(), kind: "item", key: item.itemID.uuidString, origin: item.center.offsetBy(x: -size.width / 2, y: -size.height / 2), width: size.width, height: size.height, z: Double(item.zIndex), owner: item.itemID)
    case "board/stacks":
      let stack = try fragment.value.decode(WorkspaceItemStack.self)
      for (position, id) in stack.itemIDs.enumerated() {
        let size = try geometry(id)
        let collapsed = WorkspaceItemStackPresentation.boardCenter(of: id, in: stack, cameraScale: SpatialCamera.minimumScale, viewport: .init(x: 834, y: 1194)) ?? stack.center
        let fanned = WorkspaceItemStackPresentation.focusedCenter(of: id, in: stack) ?? stack.center
        let a = stack.center.delta(to: collapsed), b = stack.center.delta(to: fanned)
        let left = min(0, a.x, b.x) - size.width / 2, top = min(0, a.y, b.y) - size.height / 2
        try insert(id: id.uuidString.lowercased(), kind: "item", key: id.uuidString, origin: stack.center.offsetBy(x: left, y: top), width: max(0, a.x, b.x) + size.width / 2 - left,
          height: max(0, a.y, b.y) + size.height / 2 - top, z: Double(stack.zIndex) + Double(position) / 100, owner: id)
      }
    case "board/elements":
      let element = try fragment.value.decode(SpatialElement.self)
      let id = element.surface.kind == .cover ? (element.surface.ownerID?.uuidString.lowercased() ?? "") : element.id
      try insert(id: id, kind: element.surface.kind == .cover ? "coverElement" : "element", key: element.id,
        origin: (element.worldOrigin ?? .zero).offsetBy(x: element.frame.x, y: element.frame.y), width: element.frame.width, height: element.frame.height, z: Double(fragment.position))
    default: break
    }
  }

  func spatialRows(boardID: UUID, coverID: UUID? = nil, bounds: WorkspaceSpatialBounds, limit: Int, after: NotebookScenePaintCursor? = nil, elementsOnly: Bool = false) throws -> [[NotebookSQLValue]] {
    guard (1...257).contains(limit) else { throw NotebookStorageError.limitExceeded("scene_window") }
    let origin = bounds.origin, maximum = bounds.maximum
    return try currentSQL!.rows("""
      SELECT paint_key,address,owner_id,kind,layer,z_index,min_tx,min_ty,min_x,min_y,max_tx,max_ty,max_x,max_y
      FROM spatial_entries WHERE board_id=? AND (?=0 OR kind<>'item') AND ((? IS NULL AND kind<>'coverElement') OR (? IS NOT NULL AND kind='coverElement' AND owner_id=?))
      AND (min_tx<? OR (min_tx=? AND min_x<=?)) AND (max_tx>? OR (max_tx=? AND max_x>=?))
      AND (min_ty<? OR (min_ty=? AND min_y<=?)) AND (max_ty>? OR (max_ty=? AND max_y>=?))
      AND (layer>? OR (layer=? AND (z_index>? OR (z_index=? AND paint_key>?))))
      ORDER BY layer,z_index,paint_key LIMIT ?
      """, [.text(boardID.uuidString.lowercased()), .integer(elementsOnly ? 1 : 0), coverID.map { .text($0.uuidString.lowercased()) } ?? .null, coverID.map { .text($0.uuidString.lowercased()) } ?? .null, coverID.map { .text($0.uuidString.lowercased()) } ?? .null,
      .integer(maximum.tileX), .integer(maximum.tileX), .real(maximum.localX), .integer(origin.tileX), .integer(origin.tileX), .real(origin.localX),
      .integer(maximum.tileY), .integer(maximum.tileY), .real(maximum.localY), .integer(origin.tileY), .integer(origin.tileY), .real(origin.localY),
      .integer(Int64(after?.layer ?? -1)), .integer(Int64(after?.layer ?? -1)), .real(after?.zIndex ?? 0), .real(after?.zIndex ?? 0), .text(after?.address ?? ""), .integer(Int64(limit))])
  }

  public func readSceneWindow(boardID: UUID, bounds: WorkspaceSpatialBounds, limit: Int = 256,
    pinnedIDs: [UUID] = [], pinnedElementIDs: [String] = []) throws -> NotebookSceneWindow {
    guard (1...256).contains(limit), pinnedIDs.count <= 8, pinnedElementIDs.count <= 7,
      Set(pinnedIDs).count == pinnedIDs.count, Set(pinnedElementIDs).count == pinnedElementIDs.count,
      pinnedElementIDs.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 120 }) else { throw NotebookStorageError.limitExceeded("scene_window") }
    return try readTransaction { _ in
      let matches = try spatialRows(boardID: boardID, bounds: bounds, limit: limit + 1)
      let address = "board.json#/boards/@" + boardID.uuidString.lowercased()
      var rows = try storedFragments(address: address, descendants: false)
      guard !rows.isEmpty else { throw CocoaError(.fileNoSuchFile) }
      var selected = Set<String>(), mandatory: [String] = []
      func placement(_ id: UUID) throws -> String {
        guard let value = try currentSQL!.rows("SELECT address FROM item_owners WHERE board_id=? AND item_id=?", [.text(boardID.uuidString.lowercased()), .text(id.uuidString.lowercased())]).first?[0].text else { throw CocoaError(.fileNoSuchFile) }
        return value
      }
      for id in pinnedIDs { mandatory.append(try placement(id)) }
      for id in pinnedElementIDs {
        let elementAddress = address + "/board/elements/@" + fieldKey([collaborationIdentity(id)])
        guard let fragment = try storedFragments(address: elementAddress, descendants: false).first,
          let surface = try fragment.value["surface"]?.decode(SurfaceID.self) else { throw CocoaError(.fileNoSuchFile) }
        if surface.kind == .cover, let owner = surface.ownerID { mandatory.append(try placement(owner)) }
        mandatory.append(elementAddress)
      }
      var cost = 0, truncated = matches.count > limit
      func include(_ candidate: String, required: Bool) throws {
        guard !selected.contains(candidate) else { return }
        let content = try storedFragments(address: candidate)
        let primitiveCount = content.first(where: { $0.address == candidate })?.value["itemIDs"]?.array.count ?? 1
        guard cost + primitiveCount <= limit else {
          if required { throw NotebookStorageError.limitExceeded("scene_pins") }
          truncated = true; return
        }
        selected.insert(candidate); cost += primitiveCount; rows += content
      }
      for candidate in mandatory { try include(candidate, required: true) }
      for candidate in matches.compactMap({ $0[1].text }) { try include(candidate, required: false) }
      for id in pinnedIDs {
        let remaining = limit - cost
        let content = try currentSQL!.rows("SELECT address FROM spatial_entries WHERE board_id=? AND kind='coverElement' AND owner_id=? ORDER BY z_index,entry_id LIMIT ?", [.text(boardID.uuidString.lowercased()), .text(id.uuidString.lowercased()), .integer(Int64(remaining + 1))])
        if content.count > remaining { truncated = true }
        for row in content.prefix(remaining) { try include(row[0].text!, required: false) }
      }
      try appendBoardCausalFragments(to: &rows, address: address)
      let board = try NotebookRecordCodec.decode(rows, root: address).decode(BoardNode.self)
      var items: [WorkspaceItem] = [], paper: [UUID: DocumentPaperSize] = [:], counts: [UUID: Int] = [:]
      for id in board.board.itemIDs {
        guard let header = try readItemHeader(id) else { throw NotebookStorageError.corruptRecord(id.uuidString) }
        items.append(header.item); counts[id] = header.pageCount
        if header.kind == .document { paper[id] = try storedFragments(address: documentFile(id) + "#", descendants: false).first?.value["paperSize"]?.decode(DocumentPaperSize.self) }
      }
      let targets = [CollaborationTarget(kind: .board, id: boardID)] + items.map { CollaborationTarget(kind: .cover, id: $0.id, boardID: boardID) }
      return .init(header: try workspaceHeader(), boardID: boardID, items: items, boards: [board], documentPaper: paper, pageCounts: counts,
        referenceIdentities: try referenceIdentities(targets: targets), totalMatches: cost, truncated: truncated)
    }
  }

  public func readScenePaintOrder(boardID: UUID, coverID: UUID? = nil, bounds: WorkspaceSpatialBounds, after: NotebookScenePaintCursor? = nil, limit: Int = 32) throws -> NotebookScenePaintPage {
    guard (1...32).contains(limit) else { throw NotebookStorageError.limitExceeded("paint_page") }
    return try readTransaction { _ in
      let revision = try currentChangeCursor(), hash = try collaborationHash(["bounds": try JSONValue.encode(bounds), "coverID": coverID.map { .string($0.uuidString.lowercased()) } ?? .null])
      if let after, after.revision != revision || after.boardID != boardID || after.boundsHash != hash { throw NotebookStorageError.transactionConflict }
      let rows = try spatialRows(boardID: boardID, coverID: coverID, bounds: bounds, limit: limit + 1, after: after), included = Array(rows.prefix(limit))
      func number(_ value: NotebookSQLValue) -> Double { if case .real(let number) = value { return number }; return Double(value.integer ?? 0) }
      let entries = try included.map { row -> WorkspaceSpatialEntry in
        let id: WorkspaceSpatialID
        if row[3].text != "item" { id = .element(row[0].text!) }
        else if let uuid = UUID(uuidString: row[2].text!) { id = .item(uuid) }
        else { throw NotebookStorageError.corruptRecord(row[1].text!) }
        return .init(id: id, bounds: .init(origin: .init(tileX: row[6].integer!, tileY: row[7].integer!, localX: number(row[8]), localY: number(row[9])), maximum: .init(tileX: row[10].integer!, tileY: row[11].integer!, localX: number(row[12]), localY: number(row[13]))), zIndex: number(row[5]))
      }
      let next = rows.count > limit ? included.last.map { NotebookScenePaintCursor(revision: revision, boardID: boardID, boundsHash: hash, layer: Int($0[4].integer!), zIndex: number($0[5]), address: $0[0].text!) } : nil
      return .init(revision: revision, entries: entries, positions: included.map { .init(layer: Int($0[4].integer!), zIndex: number($0[5]), key: $0[0].text!) }, next: next)
    }
  }
}

extension NotebookStore {
  public func collaborationActions(afterID: UUID?, contextID: UUID? = nil, limit: Int = 64) throws -> [CollaborationReceipt] {
    guard (1...128).contains(limit) else { throw NotebookStorageError.limitExceeded("action_page") }
    return try readTransaction { _ in
      let afterFile = afterID.map { "collaboration/actions/" + $0.uuidString.lowercased() + ".json#" }
      let afterTime = try afterFile.flatMap { try currentSQL!.rows("SELECT created_at FROM metadata_index WHERE address=?", [.text($0)]).first?[0] }
      let rows = try currentSQL!.rows("SELECT address FROM metadata_index WHERE kind='action' AND (? IS NULL OR context_id=?) AND (? IS NULL OR created_at<? OR (created_at=? AND address<?)) ORDER BY created_at DESC,address DESC LIMIT ?", [
        contextID.map { .text($0.uuidString.lowercased()) } ?? .null, contextID.map { .text($0.uuidString.lowercased()) } ?? .null,
        afterTime ?? .null, afterTime ?? .null, afterTime ?? .null, afterFile.map(NotebookSQLValue.text) ?? .null, .integer(Int64(limit))])
      return try rows.compactMap { try storedValue(String($0[0].text!.dropLast()))?.decode(CollaborationReceipt.self) }

    }
  }

  public func readSpatialElement(boardID: UUID, elementID: String) throws -> SpatialElement? {
    let address = "board.json#/boards/@" + boardID.uuidString.lowercased() + "/board/elements/@" + fieldKey([collaborationIdentity(elementID)])
    let rows = try storedFragments(address: address)
    return rows.isEmpty ? nil : try NotebookRecordCodec.decode(rows, root: address).decode(SpatialElement.self)
  }
}

extension NotebookStore {
  public func readBoardItem(_ itemID: UUID) throws -> BoardNode? {
    try readTransaction { _ in
      guard let owner = try currentSQL!.rows("SELECT board_id,address FROM item_owners WHERE item_id=?", [.text(itemID.uuidString.lowercased())]).first,
        let boardID = owner[0].text, let placement = owner[1].text else { return nil }
      let address = "board.json#/boards/@" + boardID
      var rows = try storedFragments(address: address, descendants: false)
      rows += try storedFragments(address: placement)
      try appendBoardCausalFragments(to: &rows, address: address)
      return try NotebookRecordCodec.decode(rows, root: address).decode(BoardNode.self)
    }
  }
}

extension NotebookStore {
  public func readItemHeader(_ id: UUID) throws -> NotebookItemHeader? {
    try readTransaction { _ in
      guard let fragment = try storedFragments(address: "workspace.json#/items/@" + id.uuidString.lowercased(), descendants: false).first else { return nil }
      guard fragment.value["id"]?.string.flatMap(UUID.init(uuidString:)) == id,
        let kind = fragment.value["kind"]?.string.flatMap(WorkspaceItemKind.init(rawValue:)), let title = fragment.value["title"]?.string,
        title.utf16.count <= WorkspaceIndex.maximumTitleLength else { throw NotebookStorageError.corruptRecord("item header") }
      let first = try pageID(at: 0, in: id), count = try pageCount(in: id)
      guard kind == .notebook ? (first != nil && count > 0) : (first == nil && count == 0) else { throw NotebookStorageError.corruptRecord("notebook page header") }
      return .init(id: id, kind: kind, title: title, firstPageID: first, pageCount: count)
    }
  }

  public func readItemHeaders(after id: UUID? = nil, limit: Int = 128) throws -> [NotebookItemHeader] {
    guard (1...256).contains(limit) else { throw NotebookStorageError.limitExceeded("catalog_headers") }
    return try readTransaction { _ in
      let ids = try currentSQL!.rows("SELECT member FROM records WHERE parent='workspace.json#' AND collection='items' AND member>? ORDER BY member LIMIT ?",
        [.text(id?.uuidString.lowercased() ?? ""), .integer(Int64(limit))])
      return try ids.map { row in
        guard let id = row[0].text.flatMap(UUID.init(uuidString:)), let header = try readItemHeader(id) else {
          throw NotebookStorageError.corruptRecord("item header")
        }
        return header
      }
    }
  }

  public func readBoardNodeHeader(_ id: UUID) throws -> BoardNode? {
    try readTransaction { _ in
      let address = "board.json#/boards/@" + id.uuidString.lowercased()
      let rows = try storedFragments(address: address, descendants: false)
      return rows.isEmpty ? nil : try NotebookRecordCodec.decode(rows, root: address).decode(BoardNode.self)
    }
  }

  func causalFragments(parent: String, collection: String, memberPrefixes: [String], includeKeys: [String]) throws -> [NotebookStoredFragment] {
    guard !memberPrefixes.isEmpty || !includeKeys.isEmpty else { return [] }
    var rows: [NotebookStoredFragment] = []
    let database = currentSQL!
    for prefix in Set(memberPrefixes) {
      rows += try database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent=? AND r.collection=? AND r.member>=? AND r.member<?", [.text(parent), .text(collection), .text(prefix), .text(prefix + "\u{10ffff}")]).map { try JSONDecoder().decode(NotebookStoredFragment.self, from: $0[0].blob!) }
    }
    for key in includeKeys {
      rows += try database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent=? AND r.collection=? AND r.member=?", [.text(parent), .text(collection), .text(key)]).map { try JSONDecoder().decode(NotebookStoredFragment.self, from: $0[0].blob!) }
    }
    return rows
  }

  public func workspaceProjection(items: [WorkspaceItem], selectedItemID: UUID, selectedPageID: UUID?) throws -> WorkspaceIndex {
    guard !items.isEmpty, items.count <= 4096, Set(items.map(\.id)).count == items.count else { throw NotebookStorageError.limitExceeded("workspace_projection") }
    return try readTransaction { _ in
      guard let root = try storedFragments(address: "workspace.json#", descendants: false).first else { throw CocoaError(.fileNoSuchFile) }
      // The projection carries only the fields of the represented members.
      // A prefix read would silently decode every page's birth version.
      let keys = ["items/order"] + items.flatMap { item in
        let prefix = "items/" + item.id.uuidString.lowercased() + "/"
        return ["exists", "kind", "title", "pageIDs"].map { prefix + $0 }
          + item.pageIDs.map { prefix + "pageIDs/" + $0.uuidString.lowercased() }
      }
      let fields = try causalFragments(parent: root.address, collection: "collaboration/fields",
        memberPrefixes: [], includeKeys: keys)
      var value = try NotebookRecordCodec.decode([root] + fields, root: root.address)
      var orders: [String: NotebookPageOrderRegister] = [:], nodes: [String: NotebookPageOrderNode] = [:]
      for item in items where item.kind == .notebook {
        let order = try readPageOrder(item.id)
        orders[item.id.uuidString.lowercased()] = order
        for (hash, node) in try NotebookPageOrderVector.rightSpine(order.visibleRoot, read: { try readPageOrderNode($0) }) { nodes[hash] = node }
      }
      value = try value.setting("items", .encode(items)).setting("pageOrders", .encode(orders))
        .setting("pageOrderNodes", .encode(nodes)).setting("isProjection", .bool(true))
      var projection = try value.decode(WorkspaceIndex.self)
      _ = projection.selectItem(selectedItemID, pageID: selectedPageID, actor: projection.stamp.actor)
      return projection
    }
  }

  public func deviceActionReceipts(actionIDs: [UUID]) throws -> [DeviceActionReceipt] {
    guard actionIDs.count <= 128 else { throw NotebookStorageError.limitExceeded("delivery_page") }
    return try readTransaction { _ in
      try actionIDs.compactMap { try storedValue("collaboration/delivery/" + $0.uuidString.lowercased() + ".json")?.decode(DeviceActionReceipt.self) }
    }
  }

  func appendBoardCausalFragments(to rows: inout [NotebookStoredFragment], address: String) throws {
    let members = rows.filter { $0.parent == address && ["board/freeItems", "board/stacks", "board/elements"].contains($0.collection) }
    rows += try causalFragments(parent: address, collection: "board/collaboration/fields",
      memberPrefixes: members.map { fieldKey([$0.collection.replacingOccurrences(of: "board/", with: ""), $0.member]) + "/" },
      includeKeys: ["freeItems/order", "stacks/order", "elements/order"])
  }
}

extension NotebookStore {
  public func readDocumentPaperSize(_ id: UUID) throws -> DocumentPaperSize? {
    try storedFragments(address: documentFile(id) + "#", descendants: false).first?.value["paperSize"]?.decode(DocumentPaperSize.self)
  }
}

extension NotebookStore {
  public func readScenePaintPosition(boardID: UUID, coverID: UUID? = nil, id: WorkspaceSpatialID) throws -> NotebookScenePaintPosition? {
    let key: String, kind: String
    switch id {
    case .item(let id): key = id.uuidString; kind = "item"
    case .element(let id): key = id; kind = coverID == nil ? "element" : "coverElement"
    }
    return try sqlRead { database in
      let rows = try database.rows("SELECT layer,z_index,paint_key FROM spatial_entries WHERE board_id=? AND paint_key=? AND kind=? AND (? IS NULL OR owner_id=?) LIMIT 1", [
        .text(boardID.uuidString.lowercased()), .text(key), .text(kind), coverID.map { .text($0.uuidString.lowercased()) } ?? .null, coverID.map { .text($0.uuidString.lowercased()) } ?? .null])
      guard let row = rows.first else { return nil }
      let z: Double
      if case .real(let value) = row[1] { z = value } else { z = Double(row[1].integer ?? 0) }
      return .init(layer: Int(row[0].integer!), zIndex: z, key: row[2].text!)
    }
  }
}

extension NotebookStore {
  /// Internal owners use a sanctioned prefix; external command JSON never
  /// supplies a record path. Results form a bounded lexicographic SQL page.
  func addressedValues(prefix: String, after: String? = nil, limit: Int = 128) throws -> [(String, JSONValue)] {
    guard (1...128).contains(limit), !prefix.contains(".."), !prefix.hasPrefix("/") else { throw NotebookStorageError.limitExceeded("record_page") }
    return try readTransaction { _ in
      let rows = try currentSQL!.rows("SELECT file FROM records WHERE parent IS NULL AND file>=? AND file<? AND file>? ORDER BY file LIMIT ?", [.text(prefix), .text(prefix + "\u{10ffff}"), .text(after ?? ""), .integer(Int64(limit))])
      return try rows.compactMap { row in
        guard let file = row[0].text, let value = try storedValue(file) else { return nil }
        return (file, value)
      }
    }
  }
}
