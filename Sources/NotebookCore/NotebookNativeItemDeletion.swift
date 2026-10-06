import Foundation

extension NotebookNativeCommand where Source == NotebookItemLifecycle {
  public convenience init(deleting source: NotebookItemLifecycle, placement: WorkspacePlacement,
    actionID: UUID = UUID(), actor: UUID, allowance: NotebookNativeWriteAllowance = .init()) {
    self.init(allowance: allowance) { store, didPrepare in
      guard let boardID = source.target.boardID,
        try store.nativeDeletionSource(itemID: source.item.id, boardID: boardID,
          placement: placement, kind: source.item.kind, title: source.item.title) == source else {
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

extension NotebookStore {
  /// A separate accepted read cut retains a compact header and extent digest.
  /// It never materializes the board, cover graphics or notebook page bodies.
  public func readNativeDeletionSource(itemID: UUID, boardID: UUID, placement: WorkspacePlacement,
    kind: WorkspaceItemKind, title: String) throws -> NotebookItemLifecycle {
    do {
      return try readTransaction { _ in
        try currentSQL!.limitReads(NotebookNativeWriteAllowance(
          executionBytes: NotebookNativeWriteAllowance.maximumSourceBytes).readAllowance())
        return try nativeDeletionSource(itemID: itemID, boardID: boardID, placement: placement,
          kind: kind, title: title)
      }
    } catch NotebookStorageError.limitExceeded { throw NotebookNativeWriteAllowance.refusal() }
  }

  fileprivate func nativeDeletionSource(itemID: UUID, boardID: UUID, placement: WorkspacePlacement,
    kind: WorkspaceItemKind, title: String) throws -> NotebookItemLifecycle {
    guard placement.retainedPayloadBytes <= NotebookNativeWriteAllowance.maximumSourceBytes,
      title.utf16.count <= WorkspaceIndex.maximumTitleLength else { throw NotebookNativeWriteAllowance.refusal() }
    try placement.validate()
    let address = "board.json#/boards/@" + boardID.uuidString.lowercased()
      + "/board/placements/@" + itemID.uuidString.lowercased()
    guard placement.itemID == itemID, try ownerBoardID(of: itemID) == boardID,
      let row = try currentSQL!.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?", [.text(address)]).first?[0].blob else {
      throw CollaborationError("revision_conflict", "Предмет изменился после принятого удаления.")
    }
    let fragment = try currentSQL!.decodedStoredFragment(from: row, expandingInk: false)
    try currentSQL!.admitNativeJSONPhase(fragment.value, copies: 2)
    let current = try fragment.value.decode(WorkspacePlacement.self)
    guard fragment.address == address, current == placement,
      let source = try readItemLifecycle(itemID), source.target.boardID == boardID,
      source.item.kind == kind, source.item.title == title else {
      throw CollaborationError("revision_conflict", "Предмет изменился после принятого удаления.")
    }
    return source
  }

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
