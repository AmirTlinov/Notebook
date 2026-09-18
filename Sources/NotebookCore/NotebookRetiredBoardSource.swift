import Foundation

extension NotebookStore {
  /// Physical board source can outlive its catalogue membership. Only this
  /// live boundary authorizes a new local command or a public board read.
  static let liveBoardPredicate = """
    (EXISTS(SELECT 1 FROM records wr JOIN blobs wb ON wb.hash=wr.hash
      WHERE wr.address='workspace.json#' AND lower(json_extract(CAST(wb.data AS TEXT),'$.value.rootBoardID'))=r.member)
     OR EXISTS(SELECT 1 FROM records wi JOIN blobs ib ON ib.hash=wi.hash
       JOIN item_owners io ON io.item_id=wi.member
       WHERE wi.address='workspace.json#/items/@'||r.member AND json_extract(CAST(ib.data AS TEXT),'$.value.kind')='board'))
    """

  func isLiveBoard(_ id: UUID) throws -> Bool {
    try sqlRead { database in
      try !database.rows("SELECT 1 FROM records r WHERE r.address=? AND " + Self.liveBoardPredicate,
        [.text("board.json#/boards/@" + id.uuidString.lowercased())]).isEmpty
    }
  }

  func requireLiveBoard(_ id: UUID) throws {
    guard try isLiveBoard(id) else {
      throw CollaborationError("target_missing", "Доска больше не принадлежит живому каталогу.", target: .init(kind: .board, id: id))
    }
  }

  /// A retained typed node is the kind discriminator. A catalogue clock by
  /// itself cannot allocate a board, nor can a notebook/document reuse its ID.
  private func hasRetiredBoardKind(_ id: UUID) throws -> Bool {
    let item = id.uuidString.lowercased()
    guard try id != workspaceHeader().rootBoardID, try readItemHeader(id) == nil,
      try storedFragments(address: "workspace.json#/pageOrders/@" + item, descendants: false).isEmpty,
      try !hasStoredValue(documentFile(id)), try !hasStoredValue(stateFile(id)) else { return false }
    for field in ["exists", "kind"] {
      let key = fieldKey(["items", item, field]), address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
      guard let row = try storedFragments(address: address, descendants: false).first else { return false }
      let version = try row.value.decode(ContentFieldVersion.self)
      guard version.isValid, row == NotebookStoredFragment(address: address, file: "workspace.json", parent: "workspace.json#",
        collection: "collaboration/fields", member: key, position: 0, value: try .encode(version), collections: []) else {
        throw NotebookStorageError.corruptRecord("retired board kind")
      }
    }
    return true
  }

  func boardSourceHeader(_ row: NotebookStoredFragment, id: UUID) throws -> BoardNode {
    let address = "board.json#/boards/@" + id.uuidString.lowercased()
    let node = try NotebookRecordCodec.decode([row], root: address).decode(BoardNode.self)
    guard node.id == id, node.board.isValid(itemIDs: []), node.portalCamera.isValid,
      row.address == address, row.file == "board.json", row.parent == "board.json#",
      row.collection == "boards", row.member == id.uuidString.lowercased(), row.position >= 0,
      let root = try storedFragments(address: "board.json#", descendants: false).first,
      let treeStamp = try root.value["stamp"]?.decode(VersionStamp.self), node.portalStamp <= treeStamp,
      try NotebookRecordCodec.encode(.encode(node), file: "board.json", address: address,
        parent: "board.json#", collection: "boards", member: row.member, position: row.position).first(where: { $0.address == address }) == row else {
      throw NotebookStorageError.corruptRecord("retired board header")
    }
    return node
  }

  /// Undo restores only catalogue/placement. This bounded check names the
  /// currently admitted source; it never hydrates an old node from an inverse.
  @discardableResult
  func requireRetiredBoardBaseline(itemID: UUID) throws -> NotebookStoredFragment {
    try readTransaction { _ in
      guard try hasRetiredBoardKind(itemID), try ownerBoardID(of: itemID) == nil,
        let row = try boundedStoredFragments([("board.json#/boards/@" + itemID.uuidString.lowercased(), false)],
          maximumCount: 1, maximumBytes: 1_048_576, budget: "retired_board_header").first else {
        throw NotebookStorageError.invalidTransaction("retired board baseline is not admitted")
      }
      _ = try boardSourceHeader(row, id: itemID)
      guard try currentSQL!.rows("SELECT 1 FROM item_owners WHERE board_id=? LIMIT 1", [.text(itemID.uuidString.lowercased())]).isEmpty else {
        throw NotebookStorageError.invalidTransaction("retired board cannot own live items")
      }
      return row
    }
  }

  /// A first snapshot or atomic birth+retirement carries its typed header and
  /// both catalogue clocks together. Metadata delivered earlier is not a grant
  /// for a later orphan node. Existing nodes continue through the same merger.
  func admitsReplicatedRetiredBoard(itemID: UUID, records: NotebookIncomingRecords) throws -> Bool {
    guard try hasRetiredBoardKind(itemID) else { return false }
    let node = "board.json#/boards/@" + itemID.uuidString.lowercased()
    if let previous = try records.previous(node) {
      // The catalogue is already merged, but this node or its parent may
      // still carry old placements until their later UUID turn. Validate the
      // admitted immutable kind/header now; final ownership checks both the
      // retired item's parent and its children after the complete manifest.
      _ = try boardSourceHeader(previous, id: itemID)
      return true
    }
    guard try records.fragment(node) != nil else { return false }
    for field in ["exists", "kind"] {
      let key = fieldKey(["items", itemID.uuidString.lowercased(), field])
      guard try records.fragment("workspace.json#/collaboration/fields/@" + fieldKey([key])) != nil,
        try records.field(parent: "workspace.json#", collection: "collaboration/fields", key: key, delivered: true) != nil else { return false }
    }
    return true
  }

  /// Full native tree publication is still an addressed delta over its live
  /// projection. Omitted retired nodes are not replacement-file deletions.
  func publishLiveBoard(_ board: BoardHierarchy, items: [WorkspaceItem]) throws {
    guard board.isValid(items: items) else { throw NotebookStorageError.corruptRecord("live board tree") }
    guard currentSQL?.writable == true else { throw NotebookStorageError.readOnlyTransaction }
    if try hasStoredValue("board.json") {
      let before = try liveBoardSource(items: items)
      try publishProjectionEdits(file: "board.json", before: .encode(before), after: .encode(board))
    } else {
      try publishRecords(writes: ["board.json": try .encode(board)])
    }
  }

  /// Callers may hold a pre-retirement native list. A standalone board has no
  /// workspace catalogue; otherwise that current catalogue owns visibility.
  func liveBoardItems(_ items: [WorkspaceItem]) throws -> [WorkspaceItem] {
    guard try hasStoredValue("workspace.json") else { return items }
    return try items.filter { try readItemHeader($0.id)?.kind == $0.kind }
  }

  func liveBoardSource(items: [WorkspaceItem]) throws -> BoardHierarchy {
    try readTransaction { _ in
      var rows = try storedFragments(address: "board.json#", descendants: false)
      guard let rootID = try rows.first?.value["rootBoardID"]?.decode(UUID.self) else {
        throw NotebookStorageError.corruptRecord("board.json")
      }
      for id in Set(items.filter { $0.kind == .board }.map(\.id)).union([rootID]).sorted() {
        rows += try storedFragments(address: "board.json#/boards/@" + id.uuidString.lowercased())
      }
      return try NotebookRecordCodec.decode(rows, root: "board.json#").decode(BoardHierarchy.self)
    }
  }
}
