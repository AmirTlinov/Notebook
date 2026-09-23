import Foundation

extension BoardHierarchy {
  /// The placement reducer is shared by command execution and a native draft.
  /// Only the store transaction authors durable heads; preview retains poses.
  public mutating func applyPlacementOperation(_ operation: CollaborationOperation,
    in boardID: UUID, actor: UUID, stackID: UUID) throws {
    switch operation.kind {
    case .moveItem:
      guard let id = operation.id.flatMap(UUID.init(uuidString:)), let center = operation.values["center"] else {
        throw CollaborationError("invalid_operation", "Нужны ID предмета и его центр.")
      }
      let destination = try center.decode(WorldPoint.self)
      let moved: Bool
      if board(boardID)?.stack(containing: id) != nil {
        moved = unstackItem(id, in: boardID, at: destination, actor: actor)
      } else {
        moved = moveItem(id, in: boardID, to: destination, actor: actor)
      }
      guard moved else {
        throw CollaborationError("invalid_operation", "Предмет должен принадлежать указанной доске; нужен допустимый центр.")
      }
    case .stackItems:
      guard let members = operation.values["itemIDs"] else { throw CollaborationError("invalid_operation", "Нужны участники стопки.") }
      let ids = try members.decode([UUID].self)
      guard (2...5).contains(ids.count), Set(ids).count == ids.count else { throw CollaborationError("invalid_operation", "В стопке от двух до пяти разных предметов.") }
      for moving in ids.dropLast() {
        guard createStack(moving: moving, onto: ids.last!, in: boardID, actor: actor, stackID: stackID) != nil else {
          throw CollaborationError("invalid_operation", "Участники должны принадлежать указанной доске.")
        }
      }

    default:
      throw CollaborationError("invalid_operation", "Ожидалось изменение расположения предмета.")
    }
  }
}

extension BoardDocument {
  /// Geometry-only native projection. These values carry no new causal identity
  /// and must be resolved to their retained command before capture or writing.
  public func projectingPlacementPoses(_ poses: [UUID: WorkspacePlacementPose]) -> Self {
    projecting(placements: placements.map { source in
      guard let pose = poses[source.id] else { return source }
      let winner = source.winner.version
      return .init(itemID: source.id, heads: source.heads.map { head in
        head.version == winner ? .init(pose: pose, version: head.version) : head
      })
    }, elements: elements)
  }
}
