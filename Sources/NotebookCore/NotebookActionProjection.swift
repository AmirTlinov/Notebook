import Foundation

/// A command envelope, not a page or a render source. Ink and computations are
/// deliberately absent; only the named elements may be validated and edited.
struct NotebookPageElementProjection: Codable {
  let format: Int
  let id: UUID
  let size: PageSize
  let drawingStamp: VersionStamp
  let agentStamp: VersionStamp
  let elements: [AgentElement]
  let collaboration: CollaborativeContent

  var isValid: Bool {
    format == PageDocument.formatVersion && size.isValid
      && drawingStamp.counter <= VersionStamp.maximumCounter
      && agentStamp.counter <= VersionStamp.maximumCounter
      && collaboration.isValid && collaboration.fields["computations"] == nil
      && collaboration.fields["elements/order"] != nil
      && elements.allSatisfy { element in
        AgentElement.causalFieldKeys(id: element.id, graphic: element.graphic, textStyle: element.textStyle,
          parentID: element.parentID, basis: element.basis).allSatisfy { collaboration.fields[$0] != nil }
      }
      && PageDocument.elementsAreValid(elements, in: size)
  }
}

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
    references: [CollaborationReference] = []) throws -> CollaborationWorkspace {
    let receiptOperations = receipt?.action.operations
    let receiptFields = receipt?.changes.map { ($0.file, $0.path) } ?? []
    let header = try workspaceHeader()
    var itemIDs = Set<UUID>(), boardIDs: Set<UUID> = [header.rootBoardID]
    var pageIDs = Set<UUID>(), documentIDs = Set<UUID>(), codeIDs = Set<UUID>()
    var elementIDs: [UUID: Set<String>] = [:], placementIDs: [UUID: Set<UUID>] = [:]
    var creationInkSurfaces = Set<SurfaceID>()
    var spatialActionIDs = Set<UUID>()
    var stateBlockIDs: [UUID: Set<String>] = [:], sourceBlockIDs: [UUID: Set<String>] = [:]
    var sourceDocumentIDs = Set<UUID>(), fullDocumentIDs = Set<UUID>()
    var pageElementIDs: [UUID: Set<String>] = [:], fullPageIDs = Set<UUID>()
    var pageGraphicSources: [UUID: [PageInkAction]] = [:]
    func include(_ target: CollaborationTarget) throws {
      switch target.kind {
      case .workspace: break
      case .codeFragment: codeIDs.insert(target.id)
      case .page:
        pageIDs.insert(target.id)
        if let owner = try ownerItemID(ofPage: target.id) { itemIDs.insert(owner) }
      case .document: itemIDs.insert(target.id); documentIDs.insert(target.id)
      case .board:
        if try isLiveBoard(target.id) { boardIDs.insert(target.id) }
      case .cover:
        itemIDs.insert(target.id)
        if let board = target.boardID, try isLiveBoard(board) { boardIDs.insert(board) }
      }
    }
    for target in action.operations.map(\.target) + action.expected.map(\.target)
      + action.references.map(\.target) + references.map(\.target) + (action.additionalOwners ?? []) { try include(target) }
    for (index, operation) in action.operations.enumerated() {
      do {
        if operation.target.kind == .page {
          let graphicRemoval = try operation.kind == .removeElement && operation.id != nil
            && (readPageElement(pageID: operation.target.id, elementID: operation.id!))?.graphic != nil
          if operation.kind == .convertInkToElement {
            let page = operation.target.id, file = pageFile(page)
            pageElementIDs[page, default: []].formUnion(operation.id.map { [collaborationIdentity($0)] } ?? [])
            guard let graphic = try operation.values["graphic"]?.decode(NotebookGraphic.self), graphic.isValid else {
              throw CollaborationError("invalid_operation", "Недопустимая геометрия преобразования.")
            }
            // The graphic owns its source budget: a retained freehand selection
            // is not limited to a quick-shape recognizer's sixteen strokes.
            let ids = graphic.sourceInkIDs
            let claimants = try graphicClaimants(on: .page(page), sourceInkIDs: Set(ids))
            pageElementIDs[page, default: []].formUnion(claimants.map { collaborationIdentity($0.candidate.id) })
            for id in ids {
              if let stroke = try storedMember(file: file, collection: "drawingData/actions", id: id.uuidString)?.decode(PageInkAction.self) {
                pageGraphicSources[page, default: []].append(stroke)
              }
            }
          } else if [.updateElement, .setElementState].contains(operation.kind) || graphicRemoval {
            guard let id = operation.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf16.count <= 120 else {
              throw CollaborationError("invalid_operation", "Изменение элемента называет допустимый ID длиной до 120 знаков UTF-16.")
            }
            pageElementIDs[operation.target.id, default: []].insert(collaborationIdentity(id))
          } else { fullPageIDs.insert(operation.target.id) }
        }
        if operation.target.kind == .document {
          if [.setBlockState, .updateBlock].contains(operation.kind) {
            guard let id = operation.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf16.count <= 120 else {
              throw CollaborationError("invalid_operation", "Изменение блока называет допустимый ID длиной до 120 знаков UTF-16.")
            }
          }
          switch operation.kind {
          case .setBlockState:
            if let id = operation.id { stateBlockIDs[operation.target.id, default: []].insert(collaborationIdentity(id)) }
          case .updateBlock:
            sourceDocumentIDs.insert(operation.target.id)
            if let id = operation.id { sourceBlockIDs[operation.target.id, default: []].insert(collaborationIdentity(id)) }
          case .setPreamble: sourceDocumentIDs.insert(operation.target.id)
          default: fullDocumentIDs.insert(operation.target.id)
          }
        }
        if [.createNotebook, .createDocument, .createBoard, .renameItem, .moveItem].contains(operation.kind),
          let id = operation.id.flatMap(UUID.init(uuidString:)) { itemIDs.insert(id) }
        if operation.kind == .createNotebook, let page = operation.values["pageID"]?.string.flatMap(UUID.init(uuidString:)) {
          pageIDs.insert(page); fullPageIDs.insert(page)
        }
        if operation.kind == .appendPage, let page = operation.id.flatMap(UUID.init(uuidString:)) {
          pageIDs.insert(page); fullPageIDs.insert(page)
        }
        if operation.kind == .createDocument, let id = operation.id.flatMap(UUID.init(uuidString:)) { documentIDs.insert(id) }
        if operation.kind == .createBoard, let id = operation.id.flatMap(UUID.init(uuidString:)) { boardIDs.insert(id) }
        if operation.kind == .stackItems { itemIDs.formUnion(try operation.values["itemIDs"]?.decode([UUID].self) ?? []) }
        if [.insertElement, .convertInkToElement, .updateElement, .setElementState, .removeElement, .reorderElements].contains(operation.kind), operation.target.kind != .page {
          let board = operation.target.kind == .board ? operation.target.id : operation.target.boardID
          if let board {
            if let id = operation.id { elementIDs[board, default: []].insert(id) }
            if operation.kind == .reorderElements {
              let ids = try operation.values["ids"]?.decode([String].self) ?? []
              elementIDs[board, default: []].formUnion(ids)
            }
          }
        }
        if operation.kind == .appendInkStroke, operation.target.kind != .page {
          if let id = operation.id.flatMap(UUID.init(uuidString:)) { spatialActionIDs.insert(id) }
        }
        if operation.kind == .convertInkToElement, operation.target.kind != .page {
          let ids = try operation.values["graphic"]?["sourceInkIDs"]?.decode([UUID].self) ?? []
          spatialActionIDs.formUnion(ids)
          let board = operation.target.kind == .board ? operation.target.id : operation.target.boardID
          if let board {
            let surface: SurfaceID = operation.target.kind == .board ? .board(board) : .cover(operation.target.id)
            let claimants = try graphicClaimants(on: surface, sourceInkIDs: Set(ids))
            elementIDs[board, default: []].formUnion(claimants.map { collaborationIdentity($0.candidate.id) })
          }
        }
      } catch let error as CollaborationError {
        throw error.atOperation(index, operation)
      }
    }
    // Undo also considers fields created by the original operation and any
    // human adoption inside a newly created board, without scanning its tree.
    if let receiptOperations {
      for (file, path) in receiptFields {
        if file == "board.json", path.count >= 2, case .member(let id) = path[1], let board = UUID(uuidString: id) {
          boardIDs.insert(board)
          if path.count >= 5, case .member(let member) = path[4] {
            if path[3] == .field("elements") { elementIDs[board, default: []].insert(member) }
            if path[3] == .field("placements"), let id = UUID(uuidString: member) {
              placementIDs[board, default: []].insert(id); itemIDs.insert(id)
            }
          }
        }
      }
      for operation in receiptOperations where [.createNotebook, .createDocument, .createBoard].contains(operation.kind) {
        guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { continue }
        creationInkSurfaces.insert(.cover(id))
        if operation.kind == .createBoard { creationInkSurfaces.insert(.board(id)) }
        if operation.kind == .createDocument { fullDocumentIDs.insert(id) }
      }
    }
    var boardRows: [String: NotebookStoredFragment] = [:]
    func insert(_ rows: [NotebookStoredFragment]) { for row in rows { boardRows[row.address] = row } }
    // A bounded item read includes the members needed to derive its current
    // stack. Each member remains a separate canonical placement row.
    func insertPlacement(_ id: UUID) throws {
      guard let node = try readBoardItem(id) else { return }
      let address = "board.json#/boards/@" + node.id.uuidString.lowercased()
      insert(try storedFragments(address: address, descendants: false))
      for placement in node.board.placements {
        insert(try storedFragments(address: address + "/board/placements/@" + placement.id.uuidString.lowercased()))
      }
      itemIDs.formUnion(node.board.itemIDs); boardIDs.insert(node.id)
    }
    for id in Array(itemIDs) { try insertPlacement(id) }
    // A deleted placement no longer has a live item_owners entry, but its
    // causal tombstone still determines whether an old action owns undo.
    for (board, ids) in placementIDs {
      guard try isLiveBoard(board) else { continue }
      for id in ids {
        insert(try storedFragments(address: "board.json#/boards/@" + board.uuidString.lowercased()
          + "/board/placements/@" + id.uuidString.lowercased()))
      }
    }
    var pending = Array(boardIDs), visited = Set<UUID>()
    while let id = pending.popLast(), visited.insert(id).inserted {
      guard try isLiveBoard(id) else { continue }
      let address = "board.json#/boards/@" + id.uuidString.lowercased()
      insert(try storedFragments(address: address, descendants: false))
      if let owner = try ownerBoardID(of: id) {
        itemIDs.insert(id); boardIDs.insert(owner); pending.append(owner)
        try insertPlacement(id)
      }
    }
    for (board, ids) in elementIDs {
      guard try isLiveBoard(board) else { continue }
      let address = "board.json#/boards/@" + board.uuidString.lowercased()
      for id in ids {
        let rows = try storedFragments(address: address + "/board/elements/@" + fieldKey([collaborationIdentity(id)]))
        insert(rows)
        if let surface = try rows.first?.value["surface"]?.decode(SurfaceID.self), surface.kind == .cover, let id = surface.ownerID {
          itemIDs.insert(id)
          try insertPlacement(id)
        }
      }
    }
    if let receiptOperations {
      for operation in receiptOperations where operation.kind == .createBoard {
        guard let id = operation.id.flatMap(UUID.init(uuidString:)), try isLiveBoard(id) else { continue }
        let address = "board.json#/boards/@" + id.uuidString.lowercased()
        if let child = try currentSQL!.rows("SELECT item_id FROM item_owners WHERE board_id=? ORDER BY item_id LIMIT 1",
          [.text(id.uuidString.lowercased())]).first?[0].text.flatMap(UUID.init(uuidString:)) {
          try insertPlacement(child)
        }
        for row in try currentSQL!.rows("SELECT address FROM records WHERE parent=? AND collection='board/elements' LIMIT 1", [.text(address)]) {
          insert(try storedFragments(address: row[0].text!))
        }
      }
    }
    var items: [WorkspaceItem] = []
    for id in itemIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let item = try readItemHeader(id) else { continue }
      var pages: [(position: Int64, id: UUID)] = item.firstPageID.map { [(Int64(0), $0)] } ?? []
      for page in pageIDs where page != item.firstPageID {
        let address = "workspace.json#/items/@" + id.uuidString.lowercased() + "/pageIDs/@" + page.uuidString.lowercased()
        if let position = try currentSQL!.rows("SELECT position FROM records WHERE address=?", [.text(address)]).first?[0].integer {
          pages.append((position, page))
        }
      }
      // Set iteration is not the notebook's order. A reopened action must see
      // the same bounded authored subset as its original receipt.
      items.append(.init(id: id, kind: item.kind, title: item.title, pageIDs: pages.sorted { $0.position < $1.position }.map(\.id)))
    }
    if let first = try currentSQL!.rows("SELECT member FROM records WHERE parent='workspace.json#' AND collection='items' ORDER BY position LIMIT 1").first?[0].text.flatMap(UUID.init(uuidString:)),
      !items.contains(where: { $0.id == first }), let item = try readItemHeader(first) { items.insert(item.item, at: 0) }
    guard let first = items.first else { throw NotebookStorageError.corruptRecord("empty workspace") }
    let workspace = try workspaceProjection(items: items, selectedItemID: first.id, selectedPageID: first.pageIDs.first)
    var rows = Array(boardRows.values)
    for id in boardIDs where try isLiveBoard(id) {
      try appendBoardCausalFragments(to: &rows, address: "board.json#/boards/@" + id.uuidString.lowercased(),
        additionalElementIDs: elementIDs[id] ?? [])
    }
    rows += try storedFragments(address: "board.json#", descendants: false)
    var files = ["workspace.json": try JSONValue.encode(workspace), "board.json": try NotebookRecordCodec.decode(rows, root: "board.json#")]
    for id in codeIDs { files[codeFragmentFile(id)] = try storedValue(codeFragmentFile(id)) }
    // Retired PAGE rows are a replication baseline, not a public command
    // target. Undo first restores permitted owners; a preserved deletion must
    // never let an ordinary inverse edit its invisible source indirectly.
    pageIDs = try Set(pageIDs.filter { try ownerItemID(ofPage: $0) != nil })
    let projectedPageIDs = pageIDs.subtracting(fullPageIDs)
    let pageAddresses = projectedPageIDs.sorted().flatMap { id -> [(String, Bool)] in
      let root = pageFile(id) + "#", ids = (pageElementIDs[id] ?? []).sorted()
      return [(root, false)]
        + ids.map { (root + "/elements/@" + fieldKey([$0]), true) }
        + (["elements/order"] + ids.flatMap { AgentElement.causalFieldKeys(id: $0, allGraphicFields: true) }).map {
          (root + "/collaboration/fields/@" + fieldKey([$0]), false)
        }
    }
    let pageRows = Dictionary(grouping: try boundedStoredFragments(pageAddresses,
      maximumCount: 4_096, maximumBytes: 4 * 1_024 * 1_024, budget: "page_element_command"), by: \.file)
    for id in pageIDs {
      let file = pageFile(id)
      if fullPageIDs.contains(id) {
        files[file] = try storedValue(file)
      } else if let stored = pageRows[file], !stored.isEmpty {
        let rows = stored.map { row in
          row.parent == nil ? row.replacing(value: row.value,
            collections: row.collections.filter { ![["drawingData"], ["computations"]].contains($0.path) }) : row
        }
        let value = try NotebookRecordCodec.decode(rows, root: file + "#")
        let projection = try value.decode(NotebookPageElementProjection.self)
        guard projection.id == id, projection.isValid,
          value["drawingData"] == nil, value["computations"] == nil else {
          throw NotebookStorageError.corruptRecord(file)
        }
        let addressed = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
        let canonical = try NotebookRecordCodec.encode(.encode(projection), file: file)
        guard canonical.count == addressed.count, canonical.allSatisfy({ row in
          guard let prior = addressed[row.address] else { return false }
          return row.replacing(value: row.value, position: prior.position) == prior
        }) else { throw NotebookStorageError.corruptRecord(file) }
        files[file] = value
      }
    }
    let sourceAddresses = items.filter { $0.kind == .document && !fullDocumentIDs.contains($0.id) }.flatMap { item -> [(String, Bool)] in
      let file = documentFile(item.id)
      let ids = (stateBlockIDs[item.id] ?? []).union(sourceBlockIDs[item.id] ?? [])
      var addresses = [(file + "#", false)] + ids.sorted().map { (file + "#/blocks/@" + fieldKey([$0]), true) }
      if sourceDocumentIDs.contains(item.id) {
        // Editing an existing program cannot create a new source field or
        // reorder its neighbours. Read exactly its causal owners, including
        // adoption of existence, not every retired field of this document.
        let keys = ["preamble", "blocks/order"] + ids.sorted().flatMap { DocumentBlock.causalFieldKeys(id: $0) }
        addresses += keys.map { (file + "#/collaboration/fields/@" + fieldKey([$0]), false) }
      }
      return addresses
    }
    // A batch shares one source admission, not four MiB per addressed document.
    let sourceRows = Dictionary(grouping: try boundedStoredFragments(sourceAddresses,
      maximumCount: 4_096, maximumBytes: 4 * 1_024 * 1_024, budget: "document_source_command"), by: \.file)
    for item in items where item.kind == .document {
      let file = documentFile(item.id)
      if fullDocumentIDs.contains(item.id) {
        files[file] = try storedValue(file)
      } else {
        let rows = sourceRows[file] ?? []
        if !rows.isEmpty {
          let value = try NotebookRecordCodec.decode(rows, root: file + "#")
          let stored = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
          let canonical = try NotebookRecordCodec.encode(value, file: file)
          guard canonical.count == stored.count, canonical.allSatisfy({ row in
            guard let prior = stored[row.address] else { return false }
            return row.replacing(value: row.value, position: prior.position) == prior
          }) else { throw NotebookStorageError.corruptRecord(file) }
          files[file] = value
        }
      }
      if documentIDs.contains(item.id) {
        let file = stateFile(item.id)
        if receiptOperations?.contains(where: { $0.kind == .createDocument && $0.id.flatMap(UUID.init(uuidString:)) == item.id }) == true {
          // Whole-owner undo still checks every later human adoption.
          files[file] = try storedValue(file)
        } else {
          var rows = try storedFragments(address: file + "#", descendants: false)
          for id in (stateBlockIDs[item.id] ?? []).sorted() {
            rows += try storedFragments(address: file + "#/records/@" + fieldKey([id]))
          }
          if !rows.isEmpty { files[file] = try NotebookRecordCodec.decode(rows, root: file + "#") }
        }
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
    return CollaborationWorkspace(files: files, projectedPageIDs: projectedPageIDs, pageGraphicSources: pageGraphicSources)
  }
}
