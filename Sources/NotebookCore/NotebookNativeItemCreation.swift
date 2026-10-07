import Foundation

/// A native birth retains only its immutable intent. Source, placement and
/// receipt allocation happen under the ordinary accepted writer's allowance.
public struct NotebookNativeItemCreation: Sendable {
  public enum Kind: Sendable {
    case notebook(PageSize), document(DocumentTemplate), board
    public var itemKind: WorkspaceItemKind {
      switch self { case .notebook: .notebook; case .document: .document; case .board: .board }
    }
  }

  public struct Cost: Sendable {
    public let payloadBytes: Int
    public let completionBytes: Int
    let sourceConstructionBytes: Int
  }

  /// These are admitted phase ceilings, not a copied workspace's size. The
  /// SQL and JSON shares are enforced again by the same connection latch.
  public static func cost(for kind: Kind) -> Cost {
    let returnedSourceBytes: Int, newOwnerBytes: Int, receiptJSONBytes: Int
    switch kind {
    case .board: (returnedSourceBytes, newOwnerBytes, receiptJSONBytes) = (256 * 1_024, 32 * 1_024, 1_024 * 1_024)
    case .notebook: (returnedSourceBytes, newOwnerBytes, receiptJSONBytes) = (384 * 1_024, 64 * 1_024, 2 * 1_024 * 1_024)
    case .document: (returnedSourceBytes, newOwnerBytes, receiptJSONBytes) = (512 * 1_024, 96 * 1_024, 3 * 1_024 * 1_024)
    }
    let transactionWorkspace = 1_024 * 1_024
    let sqlShare = returnedSourceBytes * 10
    let recoveryJSONShare = receiptJSONBytes / 4 * 5
    let codecWorkspace = newOwnerBytes * 8 + receiptJSONBytes
    return .init(payloadBytes: MemoryLayout<Self>.stride + 16 * 1_024,
      completionBytes: transactionWorkspace + max(sqlShare, recoveryJSONShare, codecWorkspace),
      sourceConstructionBytes: newOwnerBytes)
  }

  public let actionID: UUID
  public let itemID: UUID
  public let pageID: UUID?
  public let workspaceID: UUID
  public let boardID: UUID
  public let center: WorldPoint
  public let actor: UUID
  public let kind: Kind
  public var cost: Cost { Self.cost(for: kind) }

  public init(kind: Kind, workspaceID: UUID, boardID: UUID, center: WorldPoint,
    actor: UUID, actionID: UUID = UUID()) throws {
    guard center.isValid else { throw CollaborationError("invalid_operation", "Нужно допустимое место создания.") }
    if case .notebook(let size) = kind, !size.isValid { throw CollaborationError("invalid_operation", "Нужен допустимый размер листа.") }
    self.kind = kind; self.workspaceID = workspaceID; self.boardID = boardID; self.center = center
    self.actor = actor; self.actionID = actionID
    itemID = NotebookStore.submissionID(actionID, suffix: "native-item")
    pageID = kind.itemKind == .notebook ? NotebookStore.submissionID(actionID, suffix: "native-page") : nil
  }

  public struct Source: Sendable, Equatable {
    public let workspaceID: UUID
    public let boardID: UUID
    public let itemID: UUID
    public let kind: WorkspaceItemKind
    public let firstPageID: UUID?
    public let selectedPresence: SessionPresence?
  }

  public func command() -> NotebookNativeCommand<Source> {
    let cost = cost
    return .init(allowance: .init(executionBytes: cost.completionBytes), workspaceID: workspaceID) { store, didPrepare in
      try store.commandTransaction {
        guard try store.isLiveBoard(boardID) else {
          throw CollaborationError("target_missing", "Доска создания уже недоступна.", target: .init(kind: .board, id: boardID))
        }
        try store.currentSQL!.admitJSONAllocation(bytes: cost.sourceConstructionBytes)
        let target = CollaborationTarget(kind: .board, id: boardID)
        var values: [String: JSONValue] = ["title": .string(""), "center": try .encode(center)]
        let operationKind: CollaborationOperation.Kind
        switch kind {
        case .notebook(let size):
          operationKind = .createNotebook
          values["pageID"] = .string(pageID!.uuidString.lowercased()); values["pageSize"] = try .encode(size)
        case .document(let template):
          operationKind = .createDocument; values["template"] = .string(template.rawValue)
        case .board: operationKind = .createBoard
        }
        let operation = CollaborationOperation(kind: operationKind, target: target,
          id: itemID.uuidString.lowercased(), values: values)
        let fingerprint = try collaborationHash(JSONValue.object(["domain": .string("NotebookNativeItemCreation/1"),
          "workspaceID": .string(workspaceID.uuidString.lowercased()), "operation": try .encode(operation)]))
        let receipt: CollaborationReceipt
        var selected: SessionPresence?
        if let existing = try store.collaborationActionIfPresent(actionID) {
          guard existing.requestFingerprint == fingerprint, existing.author == .human else {
            throw CollaborationError("action_id_conflict", "Этот ID уже принадлежит другому ходу.")
          }
          receipt = existing
        } else {
          let header = try store.workspaceHeader()
          let expected = try store.readBasis(targets: [target, .init(kind: .workspace, id: header.rootBoardID)]).owners
          receipt = try store.applyNativeAction(.init(id: actionID, summary: "Создание предмета",
            expected: expected, operations: [operation]), actor: actor, requestFingerprint: fingerprint)
          let presence = try store.loadPresence()
          if presence.boardID == boardID {
            selected = presence.selecting(itemID: itemID, pageID: pageID)
            try store.savePresence(selected!)
          }
        }
        let source = Source(workspaceID: workspaceID, boardID: boardID, itemID: itemID,
          kind: kind.itemKind, firstPageID: pageID, selectedPresence: selected)
        let output = (receipt: receipt, sources: [source])
        didPrepare(output)
        return output
      }
    }
  }
}

extension NotebookStore {
  /// A removed page/document/child-board root has no live field clock. Its catalogue
  /// existence gate authenticates that absence; Redo restores the captured
  /// root and stable IDs through the ordinary field publication path.
  func admitsNativeItemCreationRootRedo(_ change: CollaborationFieldChange, receipt: CollaborationReceipt,
    projection: CollaborationWorkspace) throws -> Bool {
    guard change.before == nil,
      let operation = receipt.action.operations.first(where: { operation in
        switch operation.kind {
        case .createNotebook:
          return change.path.isEmpty && operation.values["pageID"]?.string.flatMap(UUID.init(uuidString:)).map { pageFile($0) == change.file } == true
        case .createDocument:
          return change.path.isEmpty && operation.id.flatMap(UUID.init(uuidString:)).map {
            documentFile($0) == change.file || stateFile($0) == change.file
          } == true
        case .createBoard:
          return change.file == "board.json" && operation.id.flatMap(UUID.init(uuidString:)).map {
            change.path == [.field("boards"), .member($0.uuidString.lowercased())]
          } == true
        default: return false
        }
      }), let itemID = operation.id.flatMap(UUID.init(uuidString:)) else { return false }
    let path: [CollaborationPathComponent] = [.field("items"), .member(itemID.uuidString.lowercased())]
    guard let gate = receipt.undo?.redoGates?.first(where: { $0.file == "workspace.json" && $0.path == path }),
      collaborationFieldVersion(file: projection.files["workspace.json"], path: path) == gate.writtenVersion,
      try readItemHeader(itemID) == nil else {
      throw CollaborationError("revision_conflict", "Владелец созданного материала изменился после отмены.")
    }
    let remainsAbsent = operation.kind == .createBoard
      ? try readBoardNodeHeader(itemID) == nil : try !hasStoredValue(change.file)
    guard remainsAbsent else { throw CollaborationError("revision_conflict", "Созданный материал уже восстановлен другим ходом.") }
    if operation.kind == .createNotebook,
      let pageID = operation.values["pageID"]?.string.flatMap(UUID.init(uuidString:)),
      try ownerItemID(ofPage: pageID) != nil {
      throw CollaborationError("revision_conflict", "Лист уже принадлежит другой тетради.")
    }
    return true
  }

}
