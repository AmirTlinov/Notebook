import Foundation

extension NotebookNativeCommand where Source == NotebookItemLifecycle {
  public convenience init(deleting source: NotebookItemLifecycle, placement: WorkspacePlacement,
    actionID: UUID = UUID(), actor: UUID) {
    self.init { store, didPrepare in
      try store.commandTransaction(readAllowance: .agentCommand) {
        guard let boardID = source.target.boardID,
          let node = try store.readBoardItem(source.item.id), node.id == boardID,
          node.board.placements.first(where: { $0.id == source.item.id }) == placement,
          try store.readItemLifecycle(source.item.id) == source else {
          throw CollaborationError("revision_conflict", "Предмет изменился после принятого удаления.")
        }
        let operation = CollaborationOperation(kind: .deleteItem, target: source.target)
        let expected = try store.nativeDeletionExpectations(operation, lifecycleRevision: source.revision)
        let receipt = try store.applyNativeAction(.init(id: actionID, additionalOwners: [source.target],
          summary: "Удаление предмета", expected: expected, operations: [operation]), actor: actor)
        let output: Output = (receipt, [])
        didPrepare(output)
        return output
      }
    }
  }
}

extension NotebookStore {
  fileprivate func nativeDeletionExpectations(_ operation: CollaborationOperation, lifecycleRevision: String) throws
    -> [CollaborationExpectation] {
    let header = try workspaceHeader()
    guard header.itemCount > 1 else {
      throw CollaborationError("last_item", "Один рабочий элемент должен остаться.")
    }
    return try operation.requiredOwners(workspaceRootID: header.rootBoardID).map { target in
      .init(target: target, revision: try targetContentRevision(target: target),
        lifecycleRevision: target == operation.target ? lifecycleRevision : nil)
    }
  }

  func redoNativeItemDeletion(_ original: CollaborationReceipt, actionID: UUID, actor: UUID) throws -> CollaborationReceipt {
    let operation = original.action.operations[0], target = operation.target
    guard original.changes.isEmpty, let boardID = target.boardID,
      original.undo?.lifecycleChanges?.count == 1,
      let expectedExtent = original.revisions.first(where: { $0.target == target })?.lifecycleRevision,
      let extent = try readItemLifecycle(target.id), extent.target == target, extent.revision == expectedExtent,
      let basis = try nativeDeletedPlacementBasis(receipt: original, boardID: boardID, itemID: target.id),
      let current = try readBoardItem(target.id)?.board.placements.first(where: { $0.id == target.id }),
      current.heads.count == 1, current.pose == basis.before.pose else {
      throw CollaborationError("revision_conflict", "Предмет изменился после отмены удаления.")
    }
    if current != basis.written {
      let path: [CollaborationPathComponent] = [.field("boards"), .member(boardID.uuidString.lowercased()),
        .field("board"), .field("placements"), .member(target.id.uuidString.lowercased())]
      let change = try CollaborationFieldChange(file: "board.json", path: path, before: .encode(basis.before), after: nil)
      let predecessors = try nativeRepeatedPredecessors(domains: original.action.nativeHistoryDomains, actor: actor)
      guard try nativeRedoRestoresSource(change, receipt: original, version: current.winner.version, predecessors: predecessors) else {
        throw CollaborationError("revision_conflict", "Расположение предмета изменилось после отмены удаления.")
      }
    }
    let expected = try nativeDeletionExpectations(operation, lifecycleRevision: expectedExtent)
    let action = CollaborationAction(id: actionID, additionalOwners: [target], summary: "Повторить: " + original.summary,
      expected: expected, operations: [operation])
    return try applyCollaborationActionImmediately(action, actor: actor, requestFingerprint: nil,
      human: true, nativeInputOwner: actor, repeating: original.id)
  }
}
