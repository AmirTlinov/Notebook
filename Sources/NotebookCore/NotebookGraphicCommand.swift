import Foundation

extension CollaborationWorkspace {
  /// Only newly authored bindings are validated against this transaction's
  /// complete after-state. Delivery preserves a formerly valid intent whose
  /// endpoint was concurrently hidden; the projection, not a repair, hides it.
  func validateGraphicBindings(action: CollaborationAction, scope: NotebookStore) throws {
    for (index, operation) in action.operations.enumerated() {
      guard let id = operation.id,
        [.insertElement, .convertInkToElement, .updateElement].contains(operation.kind),
        operation.values["graphic"]?["connection"] != nil else { continue }
      do {
        let target = operation.target
        let elements: [JSONValue]
        if target.kind == .page { elements = files["pages/\(target.id.uuidString.lowercased()).json"]?["elements"]?.array ?? [] }
        else {
          elements = files["board.json"]?["boards"]?.array.first { $0["id"]?.string.flatMap(UUID.init(uuidString:)) == (target.boardID ?? target.id) }?["board"]?["elements"]?.array ?? []
        }
        guard let value = elements.first(where: { $0["id"]?.string == id }),
          let connection = try value["graphic"]?.decode(NotebookGraphic.self).connection else { continue }
        let authored = operation.values["graphic"]?["connection"]
        for terminal in NotebookGraphicConnection.Terminal.allCases {
          // A label, head or bend change must not reject a retained hidden
          // endpoint. Only the endpoint authored by this operation is checked.
          guard operation.kind != .updateElement || authored?[terminal.rawValue] != nil,
            let binding = (terminal == .start ? connection.start : connection.end).binding else { continue }
          let found: JSONValue?
          if let local = elements.first(where: { $0["id"]?.string.map(collaborationIdentity) == collaborationIdentity(binding.elementID) }) {
            found = local
          } else if target.kind == .page {
            found = try scope.readPageElement(pageID: target.id, elementID: binding.elementID).map(JSONValue.encode)
          } else {
            found = try scope.readSpatialElement(boardID: target.boardID ?? target.id, elementID: binding.elementID).map(JSONValue.encode)
          }
          guard let found, let node = try found["graphic"]?.decode(NotebookGraphic.self),
            node.showsGeometry, node.shape != .connector, binding.elementID != id else {
            throw CollaborationError("invalid_binding", "Привязка \(id) → \(binding.elementID) требует видимый нативный узел этого владельца.", target: target)
          }
          if target.kind != .page {
            let expected: SurfaceID = target.kind == .cover ? .cover(target.id) : .board(target.id)
            guard try found["surface"]?.decode(SurfaceID.self) == expected else {
              throw CollaborationError("invalid_binding", "Концы связи принадлежат одной физической поверхности.", target: target)
            }
          }
        }
      } catch let error as CollaborationError { throw error.atOperation(index, operation) }
    }
  }

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
