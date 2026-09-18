import Foundation

extension PageDocument {
  public func elementIdentityStamp(_ id: String) -> VersionStamp? {
    guard elements.contains(where: { collaborationIdentity($0.id) == collaborationIdentity(id) }) else { return nil }
    return collaboration?.fields[fieldKey(["elements", collaborationIdentity(id), "id"])]?.stamp ?? agentStamp
  }
}

extension BoardDocument {
  public func elementIdentityStamp(_ id: String) -> VersionStamp? {
    guard elements.contains(where: { collaborationIdentity($0.id) == collaborationIdentity(id) }) else { return nil }
    return collaboration?.fields[fieldKey(["elements", collaborationIdentity(id), "id"])]?.stamp ?? stamp
  }
}

extension NotebookStore {
  /// One completed native contact updates only the live member it started on.
  /// The id field's authored version survives content edits but not recreation.
  @discardableResult
  public func commitPageElementFrame(pageID: UUID, elementID: String, identity: VersionStamp,
    original: PageRect, frame: PageRect, actor: UUID) throws -> (element: AgentElement, stamp: VersionStamp)? {
    try commandTransaction {
      guard try ownerItemID(ofPage: pageID) != nil else { return nil }
      let file = pageFile(pageID), id = collaborationIdentity(elementID)
      let before = try pageElementCommandProjection(pageID: pageID, elementID: elementID)
      let page = try before.decode(NotebookPageElementProjection.self)
      guard page.id == pageID, page.isValid, frame.isContained(in: page.size) else {
        throw NotebookStorageError.invalidTransaction("page element geometry")
      }
      guard let element = page.elements.first(where: { collaborationIdentity($0.id) == id }),
        page.collaboration.fields[fieldKey(["elements", id, "id"])]?.stamp == identity,
        element.frame == original else { return nil }
      guard let stamp = page.agentStamp.advanced(by: actor) else { throw NotebookStorageError.limitExceeded("page clock") }
      let moved = element.updating(frame: frame)
      var after = try before.setting("elements", .encode([moved])).setting("agentStamp", .encode(stamp))
      var metadata = page.collaboration
      metadata.record(before: before, after: after, beforeStamp: page.agentStamp, stamp: stamp, human: true)
      after = try after.setting("collaboration", .encode(metadata))
      try publishProjectionEdits(file: file, before: before, after: after)
      return (moved, stamp)
    }
  }

  private func pageElementCommandProjection(pageID: UUID, elementID: String) throws -> JSONValue {
    let file = pageFile(pageID), root = file + "#", id = collaborationIdentity(elementID)
    let addresses = [(root, false), (root + "/elements/@" + fieldKey([id]), true)]
      + (["elements/order"] + AgentElement.causalFieldKeys(id: id, allGraphicFields: true)).map {
        (root + "/collaboration/fields/@" + fieldKey([$0]), false)
      }
    let rows = try boundedStoredFragments(addresses, maximumCount: 4096, maximumBytes: 4 * 1024 * 1024,
      budget: "page_element_command").map { row in
        row.parent == nil ? row.replacing(value: row.value,
        collections: row.collections.filter { ![["drawingData"], ["computations"]].contains($0.path) }) : row
      }
    return try NotebookRecordCodec.decode(rows, root: root)
  }

  /// A stopped browser model may retire only after this source/state-guarded
  /// write commits. Geometry is read from storage, never rolled back by a frame.
  public func checkpointProgramState(target: CollaborationTarget, rendered: AgentElement,
    state: JSONValue, actor: UUID) throws -> Bool {
    guard state.isValid, rendered.kind == .web else { throw NotebookStorageError.invalidTransaction("program checkpoint") }
    return try commandTransaction {
      switch target.kind {
      case .page:
        guard try ownerItemID(ofPage: target.id) != nil else { return false }
        let before = try pageElementCommandProjection(pageID: target.id, elementID: rendered.id)
        let page = try before.decode(NotebookPageElementProjection.self)
        guard let element = page.elements.first(where: { $0.id == rendered.id }),
          element.kind == rendered.kind, element.source == rendered.source, element.html == rendered.html,
          element.css == rendered.css, element.javaScript == rendered.javaScript,
          element.state == rendered.state else { return false }
        if element.state == state { return true }
        guard let stamp = page.agentStamp.advanced(by: actor) else { throw NotebookStorageError.limitExceeded("page clock") }
        var after = try before.setting("elements", .encode([element.updating(state: state)])).setting("agentStamp", .encode(stamp))
        var metadata = page.collaboration
        metadata.record(before: before, after: after, beforeStamp: page.agentStamp, stamp: stamp, human: true)
        after = try after.setting("collaboration", .encode(metadata))
        try publishProjectionEdits(file: pageFile(target.id), before: before, after: after)
        return true
      case .board:
        guard let before = try spatialElementProjection(boardID: target.id, elementID: rendered.id),
          var element = before.board(target.id)?.elements.first,
          element.kind == .web, element.source == rendered.source, element.html == rendered.html,
          element.css == rendered.css, element.javaScript == rendered.javaScript,
          element.state == rendered.state else { return false }
        if element.state == state { return true }
        let expected = element.stamp
        var after = before
        guard element.update(state: state, actor: actor),
          after.upsertElement(element, in: target.id, expected: expected, actor: actor) else {
          throw NotebookStorageError.transactionConflict
        }
        _ = try saveBoardEdits(before: before, after: after)
        return true
      default: throw NotebookStorageError.invalidTransaction("program checkpoint target")
      }
    }
  }

  @discardableResult
  public func commitSpatialElementFrame(boardID: UUID, elementID: String, identity: VersionStamp,
    original: SpatialRect, frame: SpatialRect, origin: WorldPoint?, actor: UUID) throws -> (element: SpatialElement, stamp: VersionStamp)? {
    guard frame.isValid else { throw NotebookStorageError.invalidTransaction("element geometry") }
    return try commandTransaction {
      guard let before = try spatialElementProjection(boardID: boardID, elementID: elementID),
        let board = before.board(boardID), board.elementIdentityStamp(elementID) == identity,
        var element = board.elements.first, element.frame == original, element.worldOrigin == origin else { return nil }
      let expected = element.stamp
      var after = before
      guard element.update(frame: frame, actor: actor), after.upsertElement(element, in: boardID, expected: expected, actor: actor) else {
        throw NotebookStorageError.transactionConflict
      }
      _ = try saveBoardEdits(before: before, after: after)
      return (element, after.stamp)
    }
  }

  @discardableResult
  public func moveWorkspaceItem(itemID: UUID, in boardID: UUID, to center: WorldPoint, actor: UUID) throws -> Bool {
    guard center.isValid else { throw NotebookStorageError.invalidTransaction("item center") }
    return try commandTransaction {
      guard let node = try readBoardItem(itemID), node.id == boardID else { return false }
      let header = try workspaceHeader()
      let before = BoardHierarchy(rootBoardID: header.rootBoardID, boards: [node], stamp: header.boardStamp ?? node.board.stamp)
      var after = before
      guard after.moveItem(itemID, in: boardID, to: center, actor: actor) else { return false }
      _ = try saveBoardEdits(before: before, after: after)
      return true
    }
  }

  private func spatialElementProjection(boardID: UUID, elementID: String) throws -> BoardHierarchy? {
    guard try isLiveBoard(boardID) else { return nil }
    let node = "board.json#/boards/@" + boardID.uuidString.lowercased()
    guard try !storedFragments(address: node, descendants: false).isEmpty else { return nil }
    let elementRows = try storedFragments(address: node + "/board/elements/@" + fieldKey([collaborationIdentity(elementID)]))
    guard !elementRows.isEmpty else { return nil }
    if let surface = try elementRows.first?.value["surface"]?.decode(SurfaceID.self), surface.kind == .cover {
      guard let item = surface.ownerID, try ownerBoardID(of: item) == boardID else { return nil }
    }
    var rows = try storedFragments(address: "board.json#", descendants: false)
    rows += try storedFragments(address: node, descendants: false)
    rows += elementRows
    try appendBoardCausalFragments(to: &rows, address: node)
    return try NotebookRecordCodec.decode(rows, root: "board.json#").decode(BoardHierarchy.self)
  }

  /// Editor completion retains its durable target after navigation evicts it
  /// from the UI working set. A deleted owner is never recreated by a late edit.
  @discardableResult
  public func updateNativeSpatialText(boardID: UUID, elementID: String, text: String,
    finish: Bool, actor: UUID) throws -> SpatialElement? {
    try commandTransaction {
      guard let before = try spatialElementProjection(boardID: boardID, elementID: elementID),
        var element = before.board(boardID)?.elements.first, element.kind == .nativeText else { return nil }
      var after = before
      if finish && text.isEmpty {
        guard after.removeElements(ids: [element.id], from: boardID, actor: actor) == 1 else { throw NotebookStorageError.transactionConflict }
        _ = try saveBoardEdits(before: before, after: after)
        return nil
      }
      guard element.source != text else { return element }
      let expected = element.stamp
      guard element.update(source: text, actor: actor), after.upsertElement(element, in: boardID, expected: expected, actor: actor) else {
        throw NotebookStorageError.transactionConflict
      }
      _ = try saveBoardEdits(before: before, after: after)
      return element
    }
  }

  /// The rendered program, not its former frame or state, authorizes an input
  /// message. Geometry and independent state already on disk are read here.
  @discardableResult
  public func commitSpatialElementState(boardID: UUID, rendered: SpatialElement,
    state: JSONValue, actor: UUID) throws -> SpatialElement? {
    guard state.isValid else { throw NotebookStorageError.invalidTransaction("element state") }
    return try commandTransaction {
      guard let before = try spatialElementProjection(boardID: boardID, elementID: rendered.id),
        var element = before.board(boardID)?.elements.first else { return nil }
      guard element.surface == rendered.surface, element.kind == rendered.kind,
        element.source == rendered.source, element.html == rendered.html,
        element.css == rendered.css, element.javaScript == rendered.javaScript else {
        throw CollaborationError("source_conflict", "Сообщение принадлежит прежней программе элемента.")
      }
      guard element.state != state else { return element }
      let expected = element.stamp
      var after = before
      guard element.update(state: state, actor: actor), after.upsertElement(element, in: boardID, expected: expected, actor: actor) else {
        throw NotebookStorageError.transactionConflict
      }
      _ = try saveBoardEdits(before: before, after: after)
      return element
    }
  }
}
