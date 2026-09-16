import Foundation

extension CollaborationWorkspace {
  func validateGraphicSources(_ graphic: NotebookGraphic, target: CollaborationTarget,
    elements: [JSONValue]) throws {
    func invalid() -> CollaborationError {
      .init("invalid_operation", "Преобразование называет непогашенные штрихи ручки одного владельца без уже применённого преобразования.", target: target)
    }
    let ids = Set(graphic.sourceInkIDs)
    guard !ids.isEmpty, graphic.representation == .geometry, graphic.visible else { throw invalid() }
    let file = target.kind == .page ? "pages/\(target.id.uuidString.lowercased()).json" : "board.json"
    let prefix: [CollaborationPathComponent] = target.kind == .page ? [] : [
      .field("boards"), .member((target.boardID ?? target.id).uuidString.lowercased()), .field("board")]
    var candidates: [NotebookGraphicPresentation.Candidate] = []
    for element in elements {
      guard let prior = try element["graphic"]?.decode(NotebookGraphic.self), let id = element["id"]?.string else { continue }
      let path = prefix + [.field("elements"), .member(collaborationIdentity(id)), .field("graphic"), .field("sourceInkIDs")]
      if let version = collaborationFieldVersion(file: files[file], path: path) {
        candidates.append(.init(id: id, graphic: prior, version: version))
      } else if (!prior.visible || prior.representation == .geometry), !ids.isDisjoint(with: prior.sourceInkIDs) {
        // Two conversions in this still-uncommitted action cannot share ink.
        throw invalid()
      }
    }
    guard ids.isDisjoint(with: NotebookGraphicPresentation(candidates).suppressedInkIDs) else { throw invalid() }
    if target.kind == .page {
      let actions: [PageInkAction]
      if let data = files["pages/\(target.id.uuidString.lowercased()).json"]?["drawingData"] {
        actions = try PageInkDrawing.decode(data.decode(Data.self)).actions
      } else { actions = pageGraphicSources[target.id] ?? [] }
      let strokes = actions.filter { ids.contains($0.id) }
      guard strokes.count == ids.count, strokes.allSatisfy({ $0.isActive && $0.tool == .pen }) else { throw invalid() }
    } else {
      guard [.board, .cover].contains(target.kind) else { throw invalid() }
      let surface: SurfaceID = target.kind == .board ? .board(target.id) : .cover(target.id)
      let strokes = try ink.actions.filter { ids.contains($0.id) }
      guard strokes.count == ids.count, strokes.allSatisfy({
        $0.isActive && $0.tool == .pen && !$0.spans.isEmpty && $0.spans.allSatisfy { $0.surface == surface }
      }) else { throw invalid() }
    }
  }
}

/// Conversion creates a durable presentation identity. Its inverse restores
/// the representation, not the raw ink and not the existence of that identity.
func graphicConversionChanges(_ action: CollaborationAction, after: [String: JSONValue],
  changes: [CollaborationFieldChange]) throws -> [CollaborationFieldChange] {
  let conversions = action.operations.filter { $0.kind == .convertInkToElement }
  guard !conversions.isEmpty else { return changes }
  func elementPath(_ operation: CollaborationOperation) -> (String, [CollaborationPathComponent])? {
    guard let id = operation.id else { return nil }
    if operation.target.kind == .page {
      return ("pages/\(operation.target.id.uuidString.lowercased()).json", [.field("elements"), .member(collaborationIdentity(id))])
    }
    guard let boardID = operation.target.kind == .board ? operation.target.id : operation.target.boardID else { return nil }
    return ("board.json", [.field("boards"), .member(boardID.uuidString.lowercased()), .field("board"), .field("elements"), .member(collaborationIdentity(id))])
  }
  return changes.compactMap { change in
    // The durable presentation identity survives undo, including its ordinal.
    // Do not describe a nonexistent removal from the order as an inverse write.
    let retainedIDs = conversions.compactMap { operation -> String? in
      guard let (file, path) = elementPath(operation), file == change.file,
        Array(path.dropLast()) + [.order] == change.path else { return nil }
      return operation.id
    }
    if !retainedIDs.isEmpty {
      let inverse = CollaborationFieldChange(file: change.file, path: change.path,
        before: .array((change.before?.array ?? []) + retainedIDs.map(JSONValue.string)), after: change.after,
        beforeVersion: change.beforeVersion, afterVersion: change.afterVersion)
      return inverse.before == inverse.after ? nil : inverse
    }
    guard change.before == nil, let value = change.after, value["kind"] == .string("graphic"),
      conversions.contains(where: { operation in
        guard let (file, path) = elementPath(operation) else { return false }
        return file == change.file && path == change.path
      }) else { return change }
    let path = change.path + [.field("graphic"), .field("representation")]
    return .init(file: change.file, path: path, before: .string("ink"), after: .string("geometry"),
      afterVersion: collaborationFieldVersion(file: after[change.file], path: path))
  }
}
