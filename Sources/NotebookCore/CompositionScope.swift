import Foundation

struct CompositionSubjectGeometry {
  let frame: PageRect
  let origin: WorldPoint?

  func intersects(_ reference: CollaborationReference) -> Bool {
    guard let region = reference.region else { return true }
    let delta = compositionDelta(from: reference.worldOrigin, to: origin)
    return frame.x + delta.x < region.x + region.width && frame.x + delta.x + frame.width > region.x
      && frame.y + delta.y < region.y + region.height && frame.y + delta.y + frame.height > region.y
  }
}

// Subtract tiles before converting nearby coordinates. A far, explicit anchor
// can cross the entire Int64 range; it must fail to intersect, not trap.
func compositionDelta(from origin: WorldPoint?, to other: WorldPoint?) -> SpatialPoint {
  guard let origin, let other else { return .zero }
  func distance(_ a: Int64, _ b: Int64, _ local: Double) -> Double {
    let delta = b.subtractingReportingOverflow(a)
    return (delta.overflow ? Double(b) - Double(a) : Double(delta.partialValue)) * WorldPoint.tileSize + local
  }
  return .init(x: distance(origin.tileX, other.tileX, other.localX - origin.localX),
    y: distance(origin.tileY, other.tileY, other.localY - origin.localY))
}

extension NotebookStore {
  /// Geometry edits declare the objects they may rearrange. Selecting another
  /// context cannot widen an already addressed action's scope.
  static func requireCompositionScope(_ subject: CollaborationSubject, references: [CollaborationReference],
    additionalOwners: [CollaborationTarget], files: [String: JSONValue]) throws {
    if additionalOwners.contains(subject.target) { return }
    var index: WorkspaceIndex?, tree: BoardHierarchy?
    var resolvedGeometry: CompositionSubjectGeometry?, loadedGeometry = false
    for reference in references {
      if try compositionScopeContains(subject, reference: reference,
        pageOwner: { id in
          if index == nil { index = try files["workspace.json"]?.decode(WorkspaceIndex.self) }
          return index?.items.first { $0.pageIDs.contains(id) }?.id
        }, boardOwner: { id in
          if tree == nil { tree = try files["board.json"]?.decode(BoardHierarchy.self) }
          return tree?.ownerBoardID(of: id)
        }, geometry: {
          if !loadedGeometry { resolvedGeometry = try subjectGeometry(subject, files: files); loadedGeometry = true }
          return resolvedGeometry
        }) { return }
    }
    throw compositionScopeError(subject)
  }

  /// The same predicate authorizes a proposal and its eventual command. Only
  /// the resolver differs: a WAL read for planning, the command's causal cut
  /// for apply/undo. No selection or current camera participates in this rule.
  static func compositionScopeContains(_ subject: CollaborationSubject, reference: CollaborationReference,
    pageOwner: (UUID) throws -> UUID?, boardOwner: (UUID) throws -> UUID?,
    geometry: () throws -> CompositionSubjectGeometry?) throws -> Bool {
    if subject.target.kind == .cover && subject.elementID == nil {
      let ownerID = reference.target.kind == .page ? try pageOwner(reference.target.id) : reference.target.id
      if ownerID == subject.target.id, try boardOwner(subject.target.id) == subject.target.boardID { return true }
    }
    guard reference.target == subject.target else { return false }
    if subject.elementID == nil { return true } // A region travels with its physical cover.
    if let id = reference.elementID {
      return collaborationIdentity(id) == subject.elementID.map(collaborationIdentity)
    }
    guard reference.region != nil else { return true }
    return try geometry()?.intersects(reference) ?? false
  }

  static func compositionScopeError(_ subject: CollaborationSubject) -> CollaborationError {
    .init("composition_scope", "Перемещение требует исходный фрагмент этого контекста либо явно перечисленного дополнительного владельца.", target: subject.target)
  }

  private static func subjectGeometry(_ subject: CollaborationSubject, files: [String: JSONValue]) throws -> CompositionSubjectGeometry? {
    guard let id = subject.elementID else { return nil }
    if subject.target.kind == .page {
      let page = try files["pages/\(subject.target.id.uuidString.lowercased()).json"]?.decode(PageDocument.self)
      return page?.elements.first(where: { collaborationIdentity($0.id) == collaborationIdentity(id) }).map { .init(frame: $0.frame, origin: nil) }
    }
    let tree = try files["board.json"]?.decode(BoardHierarchy.self)
    let surface: SurfaceID = subject.target.kind == .cover ? .cover(subject.target.id) : .board(subject.target.id)
    return tree?.board(subject.target.boardID ?? subject.target.id)?.elements.first(where: { collaborationIdentity($0.id) == collaborationIdentity(id) && $0.surface == surface }).map {
      .init(frame: .init(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height), origin: $0.worldOrigin)
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
