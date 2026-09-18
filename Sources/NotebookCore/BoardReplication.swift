import Foundation

extension NotebookStore {
  /// Board headers, placements and elements are independent addressed owners.
  /// Ownership/cycles and stack anchors are checked by the shared SQL writer
  /// and its transaction-final dependency validation, not a second tree copy.
  func applyReplicatedBoard(manifestHash: String) throws {
    let file = "board.json", root = file + "#", prefix = root + "/boards/@"
    let incoming = NotebookIncomingRecords(store: self, manifestHash: manifestHash), database = currentSQL!
    let oldRoot = try incoming.previous(root)
    guard let nextRoot = try incoming.candidate(root) else { throw NotebookStorageError.invalidTransaction("live workspace retains boards") }
    let rootBoardID = try workspaceHeader().rootBoardID
    func header(_ row: NotebookStoredFragment) throws -> BoardHierarchy {
      let value = try NotebookRecordCodec.decode([row], root: root)
      let tree = try value.decode(BoardHierarchy.self)
      guard tree.format == BoardHierarchy.formatVersion, tree.rootBoardID == rootBoardID,
        tree.stamp.counter <= VersionStamp.maximumCounter,
        try NotebookRecordCodec.encode(.encode(tree), file: file) == [row] else { throw NotebookStorageError.corruptRecord(root) }
      return tree
    }
    let nextTree = try header(nextRoot), oldTree = try oldRoot.map(header)
    var frontier = max(nextTree.stamp, oldTree?.stamp ?? nextTree.stamp)
    var after = prefix, inclusive = true, membershipChanged = false
    while let row = try database.rows("SELECT address FROM manifest_records WHERE manifest_hash=? AND address\(inclusive ? ">=" : ">")? AND address<? ORDER BY address LIMIT 1",
      [.text(manifestHash), .text(after), .text(root + "/boards0")]).first {
      let address = row[0].text!
      let component = String(address.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)[0])
      guard let boardID = UUID(uuidString: component), boardID.uuidString.lowercased() == component else {
        throw NotebookStorageError.invalidTransaction("board address")
      }
      let nodeAddress = prefix + component
      after = nodeAddress + "0"; inclusive = true
      let old = try incoming.previous(nodeAddress)
      let live = try boardID == rootBoardID || readItemHeader(boardID)?.kind == .board
      // Snapshot closure also emits absent board roots for retired non-board
      // IDs. Such a tombstone allocates nothing and must carry no orphan body.
      if !live, old == nil, try incoming.candidate(nodeAddress) == nil {
        try incoming.visit(from: nodeAddress + "/", to: nodeAddress + "0") { address in
          guard try incoming.fragment(address) == nil else {
            throw NotebookStorageError.invalidTransaction("absent board has an orphan member")
          }
        }
        continue
      }
      if !live, try !admitsReplicatedRetiredBoard(itemID: boardID, records: incoming) {
        throw NotebookStorageError.invalidTransaction("board has no live or admitted retired owner")
      }
      guard let next = try incoming.candidate(nodeAddress) else { throw NotebookStorageError.invalidTransaction("catalog retains board") }
      func node(_ row: NotebookStoredFragment) throws -> BoardNode {
        guard row.value["board"]?["format"] == .number(Double(BoardDocument.formatVersion)) else {
          throw CollaborationError("placement_peer_upgrade_required", "Сопряжённое устройство передаёт прежний формат доски. Завершите его обновление; пакет не подтверждён.")
        }
        let value = try NotebookRecordCodec.decode([row], root: nodeAddress)
        let node = try value.decode(BoardNode.self)
        guard node.id == boardID, node.board.isValid(itemIDs: []), node.portalCamera.isValid,
          node.portalStamp <= nextTree.stamp || oldTree.map({ node.portalStamp <= $0.stamp }) == true,
          row.parent == root, row.collection == "boards", row.member == component else { throw NotebookStorageError.corruptRecord(nodeAddress) }
        let canonical = try NotebookRecordCodec.encode(.encode(node), file: file, address: nodeAddress,
          parent: root, collection: "boards", member: component, position: row.position).first { $0.address == nodeAddress }
        guard canonical == row else { throw NotebookStorageError.corruptRecord(nodeAddress) }
        return node
      }
      let candidate = try node(next), previous = try old.map(node)
      var stamp = max(candidate.board.stamp, previous?.board.stamp ?? candidate.board.stamp)
      var value = next.value
      if let previous, previous.portalStamp >= candidate.portalStamp {
        value = try value.setting("portalCamera", .encode(previous.portalCamera)).setting("portalStamp", .encode(previous.portalStamp))
      }
      value = try value.setting("board", value["board"]!.setting("stamp", .encode(stamp)))
      try writeFragment(next.replacing(value: value, position: old?.position ?? next.position), database: database)
      membershipChanged = membershipChanged || old == nil
      let placementPrefix = nodeAddress + "/board/placements/@"
      try incoming.visit(from: placementPrefix, to: nodeAddress + "/board/placements0") { address in
        let delivered = try incoming.fragment(address), stored = try incoming.previous(address)
        guard let row = delivered ?? stored else { return }
        let placement = try row.value.decode(WorkspacePlacement.self)
        try placement.validate()
        guard row.parent == nodeAddress, row.collection == "board/placements", row.member == placement.id.uuidString.lowercased(),
          row.address == placementPrefix + row.member, row.position == 0, row.collections.isEmpty,
          placement.heads.allSatisfy({ $0.version.stamp.counter <= stamp.counter }) else { throw NotebookStorageError.corruptRecord(address) }
        var resolved = try stored.map { try $0.value.decode(WorkspacePlacement.self).merging(placement) } ?? placement
        guard live || resolved.pose == nil else {
          throw NotebookStorageError.invalidTransaction("retired board cannot receive a live placement")
        }
        if try readItemHeader(placement.id) == nil, resolved.pose != nil {
          // Preserve the existing catalog-deletion policy using its typed owner.
          var board = BoardDocument(placements: [resolved], elements: [], stamp: stamp, collaboration: nil)
          _ = board.reconcileItems([], actor: frontier.actor)
          resolved = board.placements[0]; stamp = max(stamp, board.stamp)
        }
        try writeFragment(row.replacing(value: .encode(resolved)), database: database)
      }
      _ = try incoming.mergeElements(file: file, parent: nodeAddress, collection: "board/elements", fields: "board/collaboration/fields",
        localStamp: previous?.board.stamp, incomingStamp: candidate.board.stamp) { elementValue in
          let element = try elementValue.decode(SpatialElement.self)
          guard element.isValid, try JSONValue.encode(element) == elementValue,
            element.surface.kind == .board ? element.surface == .board(boardID) : element.surface.kind == .cover else {
            throw NotebookStorageError.corruptRecord("board element")
          }
        }
      try incoming.visit(from: nodeAddress + "/", to: nodeAddress + "0") { address in
        guard address.hasPrefix(placementPrefix) || address.hasPrefix(nodeAddress + "/board/elements/@")
          || address.hasPrefix(nodeAddress + "/board/collaboration/fields/@") else { throw NotebookStorageError.invalidTransaction("board member address") }
      }
      value = try value.setting("board", value["board"]!.setting("stamp", .encode(stamp)))
      try writeFragment(next.replacing(value: value, position: old?.position ?? next.position), database: database)
      frontier = max(frontier, stamp)
    }
    try incoming.visit(from: root + "/", to: file + "$") { address in
      guard address.hasPrefix(prefix) else { throw NotebookStorageError.invalidTransaction("board owner address") }
    }
    if membershipChanged {
      // Only membership changes affect the canonical flat-tree order. Normal
      // movement does not enumerate the tree, even its header metadata.
      let nodes = try database.rows("SELECT address,position FROM records WHERE parent=? AND collection='boards' ORDER BY member", [.text(root)])
      for (position, node) in nodes.enumerated() where node[1].integer != Int64(position) {
        let row = try incoming.previous(node[0].text!)!
        try writeFragment(row.replacing(value: row.value, position: position), database: database)
      }
    }
    try writeFragment(nextRoot.replacing(value: nextRoot.value.setting("stamp", .encode(frontier))), database: database)
  }
}
