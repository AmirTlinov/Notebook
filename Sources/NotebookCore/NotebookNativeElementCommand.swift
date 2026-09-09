import Foundation

extension NotebookStore {
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
    let node = "board.json#/boards/@" + boardID.uuidString.lowercased()
    guard try !storedFragments(address: node, descendants: false).isEmpty else { return nil }
    let elementRows = try storedFragments(address: node + "/board/elements/@" + fieldKey([collaborationIdentity(elementID)]))
    guard !elementRows.isEmpty else { return nil }
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
