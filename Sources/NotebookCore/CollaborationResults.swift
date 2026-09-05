import Foundation

extension CollaborationReceipt {
  public func resultReferences(in content: CollaborationContent) -> [CollaborationReference] {
    let paths = content.referenceFilePaths(for: resultTargets(in: content))
    guard let files = try? content.sourceFiles(including: paths) else { return [] }
    return resultReferences(in: content, files: files)
  }

  func resultTargets(in content: CollaborationContent) -> [CollaborationTarget] {
    action.operations.flatMap { resultLocations($0, in: content).map(\.0) }
  }

  private func resultLocations(_ operation: CollaborationOperation, in content: CollaborationContent) -> [(CollaborationTarget, String?)] {
    switch operation.kind {
    case .appendInkStroke, .reorderElements, .reorderBlocks, .setPreamble, .replaceDocument:
      return [(operation.target, nil)]
    case .createNotebook, .createDocument, .createBoard, .renameItem, .moveItem:
      guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { return [] }
      let kind: CollaborationTarget.Kind = operation.kind == .createDocument ? .document : operation.kind == .createBoard ? .board : .cover
      return [(.init(kind: kind, id: id, boardID: kind == .cover ? content.hierarchy.ownerBoardID(of: id) : nil), nil)]
    case .stackItems:
      return (operation.values["itemIDs"]?.array ?? []).compactMap { value in
        guard let id = value.string.flatMap(UUID.init(uuidString:)), let boardID = content.hierarchy.ownerBoardID(of: id) else { return nil }
        return (.init(kind: .cover, id: id, boardID: boardID), nil)
      }
    default: return [(operation.target, operation.id)]
    }
  }

  func resultReferences(in content: CollaborationContent, files: [String: JSONValue]) -> [CollaborationReference] {
    var results: [CollaborationReference] = []
    var seen = Set<String>()
    for operation in action.operations {
      if Task.isCancelled { return [] }
      let targets = resultLocations(operation, in: content)
      let stroke = operation.kind == .appendInkStroke ? try? CollaborationInkStroke(operation) : nil
      for (target, elementID) in targets {
        let key = target.key + ":" + (stroke?.id.uuidString ?? elementID ?? "")
        guard seen.insert(key).inserted else { continue }
        var region: PageRect? = stroke?.region
        var origin: WorldPoint? = stroke?.worldOrigin
        if target.kind == .page, let element = content.pages.first(where: { $0.id == target.id })?.elements.first(where: { $0.id == elementID }) {
          region = element.frame
        }
        if target.kind == .board || target.kind == .cover,
          let element = content.hierarchy.board(target.boardID ?? target.id)?.elements.first(where: { $0.id == elementID }) {
          region = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
          origin = element.worldOrigin
        }
        let specificRevision = try? NotebookStore.referenceRevision(target:target,elementID:elementID,files:files)
        guard let revision = specificRevision ?? (try? NotebookStore.referenceRevision(target:target,files:files)) else { continue }
        let hash = (try? collaborationHash(id.uuidString + key)) ?? id.uuidString.replacingOccurrences(of:"-",with:"")
        let chars = Array(hash)
        let stableID = UUID(uuidString:String(chars[0..<8])+"-"+String(chars[8..<12])+"-4"+String(chars[13..<16])+"-8"+String(chars[17..<20])+"-"+String(chars[20..<32]))!
        results.append(.init(id:stableID,target:target,elementID:specificRevision != nil ? elementID : nil,
          region:region,worldOrigin:origin,revision:revision,label:action.summary))
      }
    }
    return results
  }
}
