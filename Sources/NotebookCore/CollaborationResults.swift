import Foundation

extension CollaborationReceipt {
  public func resultReferences(in content: CollaborationContent) -> [CollaborationReference] {
    (try? NotebookActionReadModel(self).resultReferences(in: content)) ?? []
  }
}

extension NotebookActionReadModel {
  public func resultReferences(in content: CollaborationContent) -> [CollaborationReference] {
    let paths = content.referenceFilePaths(for: resultTargets(in: content))
    guard let files = try? content.sourceFiles(including: paths) else { return [] }
    var reader = NotebookReferenceReader(files: files)
    return (try? resultReferences(ownerBoardID: content.hierarchy.ownerBoardID,
      elementGeometry: { target, elementID in
        if target.kind == .page,
          let element = content.pages.first(where: { $0.id == target.id })?.elements.first(where: { $0.id == elementID }) {
          if element.graphic != nil {
            return content.pages.first(where: { $0.id == target.id })?.graphicGraph().resolve(elementID).layout.map { ($0.frame,nil) }
          }
          return (element.frame, nil)
        }
        if target.kind == .board || target.kind == .cover,
          let element = content.hierarchy.board(target.boardID ?? target.id)?.elements.first(where: { $0.id == elementID }) {
          if element.graphic != nil {
            return content.hierarchy.board(target.boardID ?? target.id)?.graphicGraph().resolve(elementID).layout.map { ($0.frame,element.worldOrigin) }
          }
          return (.init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height), element.worldOrigin)
        }
        return nil
      }, referenceRevision: { target, elementID in
        try reader.revision(target: target, elementID: elementID)
      })) ?? []
  }

  func resultTargets(in content: CollaborationContent) -> [CollaborationTarget] {
    action.operations.flatMap { resultLocations($0, ownerBoardID: content.hierarchy.ownerBoardID).map(\.0) }
  }

  private func resultLocations(_ operation: NotebookActionReadModel.Operation,
    ownerBoardID: (UUID) throws -> UUID?) rethrows -> [(CollaborationTarget, String?)] {
    switch operation.kind {
    case .appendInkStroke, .reorderElements, .reorderBlocks, .setPreamble, .replaceDocument:
      return [(operation.target, nil)]
    case .createNotebook, .createDocument, .createBoard, .renameItem, .moveItem:
      guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { return [] }
      let kind: CollaborationTarget.Kind = operation.kind == .createDocument ? .document : operation.kind == .createBoard ? .board : .cover
      return [(.init(kind: kind, id: id, boardID: kind == .cover ? try ownerBoardID(id) : nil), nil)]
    case .stackItems:
      return try operation.itemIDs.compactMap { id in
        guard let boardID = try ownerBoardID(id) else { return nil }
        return (.init(kind: .cover, id: id, boardID: boardID), nil)
      }
    default: return [(operation.target, operation.id)]
    }
  }

  func resultReferenceID(target: CollaborationTarget, elementID: String?, strokeID: UUID? = nil) -> UUID {
    let key = target.key + ":" + (strokeID?.uuidString ?? elementID ?? "")
    let hash = (try? collaborationHash(id.uuidString + key)) ?? id.uuidString.replacingOccurrences(of:"-",with:"")
    let chars = Array(hash)
    return UUID(uuidString:String(chars[0..<8])+"-"+String(chars[8..<12])+"-4"+String(chars[13..<16])+"-8"+String(chars[17..<20])+"-"+String(chars[20..<32]))!
  }

  func resultReferences(ownerBoardID: (UUID) throws -> UUID?,
    elementGeometry: (CollaborationTarget, String) throws -> (PageRect, WorldPoint?)?,
    referenceRevision: (CollaborationTarget, String?) throws -> String) throws -> [CollaborationReference] {
    func revisionIfPresent(_ target: CollaborationTarget, _ elementID: String?) throws -> String? {
      do { return try referenceRevision(target, elementID) }
      catch let error as CollaborationError where error.code == "target_missing" { return nil }
    }
    var results: [CollaborationReference] = []
    var seen = Set<String>()
    for operation in action.operations {
      try Task.checkCancellation()
      let targets = try resultLocations(operation, ownerBoardID: ownerBoardID)
      for (target, elementID) in targets {
        let key = target.key + ":" + (operation.strokeID?.uuidString ?? elementID ?? "")
        guard seen.insert(key).inserted else { continue }
        var region: PageRect? = operation.strokeRegion
        var origin: WorldPoint? = operation.strokeOrigin
        if let elementID, let geometry = try elementGeometry(target, elementID) {
          (region, origin) = geometry
        }
        let specificRevision = try revisionIfPresent(target, elementID)
        guard let revision = try specificRevision ?? revisionIfPresent(target, nil) else { continue }
        let stableID = resultReferenceID(target:target,elementID:elementID,strokeID:operation.strokeID)
        results.append(.init(id:stableID,target:target,elementID:specificRevision != nil ? elementID : nil,
          region:region,worldOrigin:origin,revision:revision,label:action.summary))
      }
    }
    return results
  }
}

// Both history and transient feedback use the same addressed geometry reader.
extension NotebookStore {
  public func actionResultReferences(_ action: NotebookActionReadModel) throws -> [CollaborationReference] {
    try action.resultReferences(ownerBoardID: ownerBoardID, elementGeometry: actionResultGeometry,
      referenceRevision: { try self.referenceRevision(target: $0, elementID: $1) })
  }

  func actionResultGeometry(_ target: CollaborationTarget, _ elementID: String) throws -> (PageRect, WorldPoint?)? {
    if target.kind == .page,
      let element = try storedMember(file: pageFile(target.id), collection: "elements", id: elementID) {
      if element["graphic"] != nil {
        return try readGraphicResolution(target:target,elementID:elementID).layout.map { ($0.frame,nil) }
      }
      return try element["frame"].map { (try $0.decode(PageRect.self), nil) }
    }
    if target.kind == .board || target.kind == .cover, let boardID = target.boardID ?? (target.kind == .board ? target.id : nil),
      let element = try readSpatialElement(boardID: boardID, elementID: elementID),
      element.surface == (target.kind == .board ? .board(target.id) : .cover(target.id)) {
      if element.graphic != nil {
        return try readGraphicResolution(target:target,elementID:elementID).layout.map { ($0.frame,element.worldOrigin) }
      }
      return (.init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height), element.worldOrigin)
    }
    return nil
  }
}
