import Foundation

extension NotebookStore {
  /// The completed source cut of one physical reference, without unrelated
  /// pages, document programs, action history or participant presence.
  public func referenceSourceFiles(target: CollaborationTarget) throws -> [String: JSONValue] {
    try prepare()
    return try withMutationLock { try readReferenceSourceFiles(target: target) }
  }

  /// The caller owns the mutation lock, including recovery of a prepared cut.
  func readReferenceSourceFiles(target: CollaborationTarget) throws -> [String: JSONValue] {
    try Task.checkCancellation()
    let suffix = target.id.uuidString.lowercased() + ".json"
    switch target.kind {
    case .page:
      guard FileManager.default.fileExists(atPath: pageURL(target.id).path) else {
        throw CollaborationError("target_missing", "Лист отсутствует.", target: target)
      }
      return ["pages/" + suffix: try .encode(loadPage(target.id))]
    case .document:
      guard FileManager.default.fileExists(atPath: documentURL(target.id).path) else {
        throw CollaborationError("target_missing", "Документ отсутствует.", target: target)
      }
      return ["documents/" + suffix: try .encode(loadDocument(target.id)),
        "document-states/" + suffix: try .encode(loadDocumentState(target.id))]
    case .workspace:
      return ["workspace.json": try .encode(loadIndex())]
    case .board, .cover:
      let workspace = try loadIndex()
      let hierarchy = try loadBoard(items: workspace.items)
      let boardID = target.kind == .board ? target.id : target.boardID
      guard let boardID, let board = hierarchy.board(boardID) else {
        throw CollaborationError("target_missing", "Доска отсутствует.", target: target)
      }
      var itemIDs: Set<UUID>
      if target.kind == .cover {
        guard board.itemIDs.contains(target.id), workspace.item(id: target.id) != nil else {
          throw CollaborationError("target_missing", "Предмет принадлежит другой доске либо отсутствует.", target: target)
        }
      }
      if target.kind == .cover, workspace.item(id: target.id)?.kind != .board {
        itemIDs = [target.id]
      } else {
        let root = target.kind == .cover ? target.id : boardID
        let descendants = hierarchy.descendantBoardIDs(including: root)
        itemIDs = Set(hierarchy.boards.filter { descendants.contains($0.id) }.flatMap { $0.board.itemIDs })
      }
      var files: [String: JSONValue] = ["workspace.json": try .encode(workspace),
        "board.json": try .encode(hierarchy), "spatial-ink.json": try .encode(loadSpatialInk())]
      // Only physical paper enters a cover proof. The document decoder still
      // validates the stored source; blocks and state do not enter this cut.
      for id in itemIDs where workspace.item(id: id)?.kind == .document {
        try Task.checkCancellation()
        let document = try loadDocument(id)
        files["documents/\(id.uuidString.lowercased()).json"] = .object(["paperSize": try .encode(document.paperSize)])
      }
      return files
    }
  }
}
