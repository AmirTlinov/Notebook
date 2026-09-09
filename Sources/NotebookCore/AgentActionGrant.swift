import Foundation

extension NotebookStore {
  /// Called inside the same command transaction as causal validation and the
  /// content write. JSON can name a request, but cannot mint its executor lease.
  func validateAgentAction(_ action: CollaborationAction, authority: AgentActionAuthority?) throws {
    guard let authority else {
      guard action.requestID == nil else { throw denied() }
      return
    }
    let (request, execution) = try requireAgentExecution(authority)
    guard action.requestID == request.id, action.contextID == request.contextID,
      request.grant.mode == .change, (action.additionalOwners ?? []).isEmpty,
      action.references.allSatisfy({ request.grant.references.contains($0) }),
      action.expected.allSatisfy({ !request.grant.references(to: $0.target).isEmpty }) else { throw denied() }
    let targets = Set(action.operations.map(\.target))
    for reference in request.grant.references where targets.contains(reference.target) {
      let considered = execution.observedReferences[reference.id] ?? reference.revision
      guard try referenceRevision(target: reference.target, elementID: reference.elementID) == considered else {
        throw CollaborationError("request_source_changed", "Человек изменил закреплённый фрагмент. Нужно рассмотреть новую версию.")
      }
    }
    for operation in action.operations {
      let references = request.grant.references(to: operation.target)
      guard !references.isEmpty else { throw denied() }
      switch operation.kind {
      case .appendInkStroke:
        let stroke = try CollaborationInkStroke(operation)
        guard request.grant.permits(target: operation.target, elementID: nil, region: stroke.region,
          worldOrigin: stroke.worldOrigin) else { throw denied() }
      case .insertElement, .updateElement, .setElementState, .removeElement:
        let previous = try agentElement(operation)
        if operation.kind != .insertElement {
          guard let previous, try permitsElement(previous, operation: operation, grant: request.grant) else { throw denied() }
        }
        if operation.kind == .insertElement || operation.kind == .updateElement {
          var next = previous?.object ?? [:]
          next["id"] = operation.id.map(JSONValue.string)
          for (key, value) in operation.values { next[key] = value }
          guard try permitsElement(.object(next), operation: operation, grant: request.grant) else { throw denied() }
        }
      case .updateBlock, .setBlockState, .removeBlock:
        guard operation.target.kind == .document, references.contains(where: {
          ($0.elementID != nil && $0.elementID == operation.id) || ($0.elementID == nil && $0.region == nil)
        }) else { throw denied() }
      case .insertBlock, .reorderBlocks, .setPreamble, .replaceDocument, .reorderElements:
        guard references.contains(where: { $0.elementID == nil && $0.region == nil }) else { throw denied() }
      case .renameItem, .moveItem, .stackItems, .createNotebook, .createDocument, .createBoard:
        // These actions mutate catalog/placement owners beyond a physical
        // fragment. They require a separately approved expanded grant.
        throw denied()
      }
    }
  }

  /// This write is nested in the content transaction, not a later callback.
  /// A completed mutation can never be delivered without its request receipt.
  func attachAgentReceipt(_ receipt: CollaborationReceipt, authority: AgentActionAuthority?) throws {
    guard let authority else { return }
    let (request, current) = try requireAgentExecution(authority)
    guard receipt.action.requestID == authority.requestID else { throw denied() }
    if current.receiptIDs.contains(receipt.id) { return }
    guard current.receiptIDs.count < 128 else { throw CollaborationError("request_action_limit", "Один запрос содержит до 128 сохранённых ходов.") }
    var next = current
    next.receiptIDs.append(receipt.id); next.stamp = try nextAgentStamp(current.stamp)
    let targets = Set(receipt.action.operations.map(\.target))
    for reference in request.grant.references where targets.contains(reference.target) {
      // Removal has no new source; its tombstone cannot authorize resurrection.
      next.observedReferences[reference.id] = (try? referenceRevision(target: reference.target,
        elementID: reference.elementID)) ?? "removed"
    }
    try publishRecords(writes: [agentExecutionFile(authority.requestID): .encode(next)])
  }

  private func agentElement(_ operation: CollaborationOperation) throws -> JSONValue? {
    guard let id = operation.id else { return nil }
    switch operation.target.kind {
    case .page:
      let address = pageFile(operation.target.id) + "#/elements/@" + fieldKey([collaborationIdentity(id)])
      let fragments = try storedFragments(address: address)
      return fragments.isEmpty ? nil : try NotebookRecordCodec.decode(fragments, root: address)
    case .board, .cover:
      let boardID = operation.target.kind == .board ? operation.target.id : operation.target.boardID!
      return try readSpatialElement(boardID: boardID, elementID: id).map(JSONValue.encode)
    default: throw denied()
    }
  }

  private func permitsElement(_ value: JSONValue, operation: CollaborationOperation, grant: RequestGrant) throws -> Bool {
    guard let frame = value["frame"], let id = value["id"]?.string else { return false }
    if operation.target.kind != .page, let surface = value["surface"] {
      guard try surface.decode(SurfaceID.self) == (operation.target.kind == .cover ? .cover(operation.target.id) : .board(operation.target.id)) else { return false }
    }
    return try grant.permits(target: operation.target, elementID: id, region: frame.decode(PageRect.self),
      worldOrigin: value["worldOrigin"]?.decode(WorldPoint.self))
  }
  private func denied() -> CollaborationError {
    .init("grant_denied", "Ход выходит за разрешённые владельцы или границы выделения. Нужно отдельное разрешение человека.")
  }
}
