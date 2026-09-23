import Foundation

extension NotebookNativeCommand where Source == WorkspacePlacement {
  /// One drop may move out of a stack and into another. Both operations share
  /// one accepted source cut, action identity and mixed Undo/Redo entry.
  public convenience init(_ operations: [CollaborationOperation], summary: String,
    placements: [WorkspacePlacement], actionID: UUID = UUID(), actor: UUID) {
    self.init { store, didPrepare in
      try store.commitNativePlacements(operations, summary: summary, sources: placements,
        actionID: actionID, actor: actor, didPrepare: didPrepare)
    }
  }
}

extension NotebookStore {
  fileprivate func commitNativePlacements(_ operations: [CollaborationOperation], summary: String,
    sources: [WorkspacePlacement], actionID: UUID, actor: UUID,
    didPrepare: (NotebookNativeCommand<WorkspacePlacement>.Output) -> Void
  ) throws -> NotebookNativeCommand<WorkspacePlacement>.Output {
    try commandTransaction(readAllowance: .agentCommand) {
      guard let target = operations.first?.target, target.kind == .board,
        (1...2).contains(operations.count), (1...10).contains(sources.count),
        operations.allSatisfy({ $0.target == target && [.moveItem, .stackItems].contains($0.kind) }),
        Set(sources.map(\.id)).count == sources.count else {
        throw CollaborationError("invalid_operation", "Перенос меняет одну доску и не более двух стопок.")
      }
      var addressed = Set<UUID>()
      for operation in operations {
        if operation.kind == .moveItem {
          guard let id = operation.id.flatMap(UUID.init(uuidString:)) else {
            throw CollaborationError("invalid_operation", "Перенос называет предмет.")
          }
          addressed.insert(id)
        } else {
          guard let ids = try operation.values["itemIDs"]?.decode([UUID].self),
            (2...5).contains(ids.count), Set(ids).count == ids.count else {
            throw CollaborationError("invalid_operation", "Стопка называет от двух до пяти разных предметов.")
          }
          addressed.formUnion(ids)
        }
      }
      var current: [UUID: WorkspacePlacement] = [:]
      for id in addressed {
        guard let node = try readBoardItem(id), node.id == target.id else {
          throw CollaborationError("revision_conflict", "Предмет больше не принадлежит выбранной доске.")
        }
        for placement in node.board.placements { current[placement.id] = placement }
      }
      // Membership as well as every causal head is part of the contact. A peer
      // may edit an unrelated cover, but not silently add a sibling to this drop.
      guard current == Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) }) else {
        throw CollaborationError("revision_conflict", "Предмет или участники его стопки изменились во время переноса.")
      }
      let revision = try targetContentRevision(target: target)
      let receipt = try applyNativeAction(.init(id: actionID,
        additionalOwners: sources.map { .init(kind: .cover, id: $0.id, boardID: target.id) },
        summary: summary, expected: [.init(target: target, revision: revision)], operations: operations), actor: actor)
      let accepted = try sources.map { source in
        guard let node = try readBoardItem(source.id), node.id == target.id,
          let placement = node.board.placements.first(where: { $0.id == source.id }) else {
          throw CollaborationError("revision_conflict", "Не найден сохранённый результат переноса.")
        }
        return placement
      }
      let output = (receipt, accepted)
      didPrepare(output)
      return output
    }
  }
}
