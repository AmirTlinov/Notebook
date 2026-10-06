import Foundation

extension CollaborationOperation {
  /// Only the native move/stack owner consumes this exact Codable footprint.
  public func nativePlacementWriteFootprint() throws -> ContentFieldVersion.WriteFootprint {
    guard [.moveItem, .stackItems].contains(kind) else {
      throw NotebookStorageError.invalidTransaction("native placement schema")
    }
    var owner = ContentFieldVersion.WriteFootprint.object
    try owner.field("kind", .string(target.kind.rawValue)); try owner.field("id", .uuid)
    if target.boardID != nil { try owner.field("boardID", .uuid) }
    var operation = ContentFieldVersion.WriteFootprint.object
    try operation.field("kind", .string(kind.rawValue)); try operation.field("target", owner)
    if let id { try operation.field("id", .string(id)) }
    try operation.field("values", .json(.object(values)))
    return operation
  }
}

extension NotebookNativeCommand where Source == WorkspacePlacement {
  /// One drop may move out of a stack and into another. Both operations share
  /// one accepted source cut, action identity and mixed Undo/Redo entry.
  public convenience init(_ operations: [CollaborationOperation], summary: String,
    placements: [WorkspacePlacement], actionID: UUID = UUID(), actor: UUID, requestFingerprint: String? = nil,
    maximumExecutionBytes: Int = NotebookNativeWriteAllowance.maximumExecutionBytes) {
    let allowance = NotebookNativeWriteAllowance(executionBytes: maximumExecutionBytes)
    self.init(allowance: allowance) { store, didPrepare in
      try store.commitNativePlacements(operations, summary: summary, sources: placements,
        actionID: actionID, actor: actor, requestFingerprint: requestFingerprint, didPrepare: didPrepare)
    }
  }
}

extension NotebookStore {
  public func applyNativePlacementEdits(_ operations: [CollaborationOperation], summary: String,
    sources: [WorkspacePlacement], actionID: UUID = UUID(), actor: UUID, requestFingerprint: String? = nil,
    maximumExecutionBytes: Int = NotebookNativeWriteAllowance.maximumExecutionBytes
  ) throws -> NotebookNativeCommand<WorkspacePlacement>.Output {
    try NotebookNativeCommand(operations, summary: summary, placements: sources,
      actionID: actionID, actor: actor, requestFingerprint: requestFingerprint,
      maximumExecutionBytes: maximumExecutionBytes).apply(to: self)
  }

  fileprivate func commitNativePlacements(_ operations: [CollaborationOperation], summary: String,
    sources: [WorkspacePlacement], actionID: UUID, actor: UUID, requestFingerprint: String?,
    didPrepare: (NotebookNativeCommand<WorkspacePlacement>.Output) -> Void
  ) throws -> NotebookNativeCommand<WorkspacePlacement>.Output {
    try commandTransaction(readAllowance: .agentCommand) {
      guard let target = operations.first?.target, target.kind == .board,
        (1...2).contains(operations.count), (1...10).contains(sources.count),
        operations.allSatisfy({ $0.target == target && [.moveItem, .stackItems].contains($0.kind) }),
        Set(sources.map(\.id)).count == sources.count else {
        throw CollaborationError("invalid_operation", "Перенос меняет одну доску и не более двух стопок.")
      }
      var addressed = Set<UUID>(), authored = Set<UUID>(), moving = Set<UUID>()
      var stackAuthorship: [(target: UUID, afterMoving: Set<UUID>)] = []
      for operation in operations {
        if operation.kind == .moveItem {
          guard let id = operation.id.flatMap(UUID.init(uuidString:)) else {
            throw CollaborationError("invalid_operation", "Перенос называет предмет.")
          }
          addressed.insert(id); authored.insert(id); moving.insert(id)
        } else {
          guard let ids = try operation.values["itemIDs"]?.decode([UUID].self),
            (2...5).contains(ids.count), Set(ids).count == ids.count else {
            throw CollaborationError("invalid_operation", "Стопка называет от двух до пяти разных предметов.")
          }
          addressed.formUnion(ids)
          authored.formUnion(ids.dropLast())
          stackAuthorship.append((ids.last!, moving))
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
      for stack in stackAuthorship where WorkspacePlacementDraft.requiresTargetAuthorship(stack.target,
        afterMoving: stack.afterMoving, sources: sources) { authored.insert(stack.target) }
      for id in authored { try current[id]?.requireAuthoredActorRoom(actor) }
      let revision = try targetContentRevision(target: target)
      let receipt = try applyNativeAction(.init(id: actionID,
        additionalOwners: sources.map { .init(kind: .cover, id: $0.id, boardID: target.id) },
        summary: summary, expected: [.init(target: target, revision: revision)], operations: operations),
        actor: actor, requestFingerprint: requestFingerprint)
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
