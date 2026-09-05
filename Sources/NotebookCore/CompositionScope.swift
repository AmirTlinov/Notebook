import Foundation

extension NotebookStore {
  /// Geometry edits declare the objects they may rearrange. Selecting another
  /// context cannot widen an already addressed action's scope.
  static func requireCompositionScope(_ subject: CollaborationSubject, references: [CollaborationReference],
    additionalOwners: [CollaborationTarget], files: [String: JSONValue]) throws {
    if additionalOwners.contains(subject.target) { return }
    if subject.target.kind == .cover && subject.elementID == nil {
      let index = try files["workspace.json"]?.decode(WorkspaceIndex.self)
      let tree = try files["board.json"]?.decode(BoardHierarchy.self)
      for reference in references {
        let ownerID = reference.target.kind == .page
          ? index?.items.first(where: { $0.pageIDs.contains(reference.target.id) })?.id : reference.target.id
        if ownerID == subject.target.id, tree?.ownerBoardID(of: subject.target.id) == subject.target.boardID { return }
      }
    }
    for reference in references where reference.target == subject.target {
      if subject.elementID == nil { return } // A region travels with its physical cover.
      if let id = reference.elementID { if id == subject.elementID { return }; continue }
      guard let region = reference.region else { return }
      guard let geometry = try subjectGeometry(subject, files: files) else { continue }
      let delta = reference.worldOrigin.flatMap { local in geometry.origin.map { local.delta(to: $0) } } ?? .zero
      let rect = geometry.frame
      if rect.x + delta.x < region.x + region.width && rect.x + delta.x + rect.width > region.x
        && rect.y + delta.y < region.y + region.height && rect.y + delta.y + rect.height > region.y { return }
    }
    throw CollaborationError("composition_scope", "Перемещение требует исходный фрагмент этого контекста либо явно перечисленного дополнительного владельца.", target: subject.target)
  }

  private static func subjectGeometry(_ subject: CollaborationSubject, files: [String: JSONValue]) throws -> (frame: PageRect, origin: WorldPoint?)? {
    guard let id = subject.elementID else { return nil }
    if subject.target.kind == .page {
      let page = try files["pages/\(subject.target.id.uuidString.lowercased()).json"]?.decode(PageDocument.self)
      return page?.elements.first(where: { $0.id == id }).map { ($0.frame, nil) }
    }
    let tree = try files["board.json"]?.decode(BoardHierarchy.self)
    let surface: SurfaceID = subject.target.kind == .cover ? .cover(subject.target.id) : .board(subject.target.id)
    return tree?.board(subject.target.boardID ?? subject.target.id)?.elements.first(where: { $0.id == id && $0.surface == surface }).map {
      (.init(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height), $0.worldOrigin)
    }
  }

  static func compositionSubjects(_ operation: CollaborationOperation, files: [String: JSONValue]) throws -> [CollaborationSubject] {
    switch operation.kind {
    case .moveItem:
      guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { return [] }
      return [.init(target: .init(kind: .cover, id: id, boardID: operation.target.id))]
    case .stackItems:
      return (try operation.values["itemIDs"]?.decode([UUID].self) ?? []).map { .init(target: .init(kind: .cover, id: $0, boardID: operation.target.id)) }
    case .updateElement:
      guard operation.values["frame"] != nil || operation.values["worldOrigin"] != nil, let id = operation.id else { return [] }
      let subject = CollaborationSubject(target: operation.target, elementID: id)
      return try subjectGeometry(subject, files: files) == nil ? [] : [subject]
    case .reorderElements:
      return try (operation.values["ids"]?.decode([String].self) ?? []).map { CollaborationSubject(target: operation.target, elementID: $0) }
        .filter { try subjectGeometry($0, files: files) != nil }
    default: return []
    }
  }
}
