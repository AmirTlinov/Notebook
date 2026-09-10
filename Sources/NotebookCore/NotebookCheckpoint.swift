import Foundation

/// A complete new-format archive, prepared outside the running applications.
/// It is not a scene projection and carries no claim about unsaved device input.
public struct NotebookCheckpoint: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let envelope: CollaborationEnvelope
  public let presence: SessionPresence

  public init(workspaceID: UUID, envelope: CollaborationEnvelope, presence: SessionPresence) {
    self.workspaceID = workspaceID
    self.envelope = .init(content: envelope.content,
      actions: envelope.actions.sorted { $0.id.uuidString < $1.id.uuidString },
      contexts: envelope.contexts.sorted { $0.id.uuidString < $1.id.uuidString },
      selection: envelope.selection,
      delivery: envelope.delivery.sorted { $0.id.uuidString < $1.id.uuidString })
    self.presence = presence
  }

  public func validate() throws {
    try envelope.validate()
    guard let content = envelope.content else {
      throw NotebookStorageError.invalidTransaction("checkpoint requires complete content")
    }
    try content.validateComplete()
    guard presence.isValid, content.hierarchy.board(presence.boardID) != nil,
      presence.selectedItemID.map({ content.workspace.item(id: $0) != nil }) ?? true,
      presence.focusedItemID.map({ content.hierarchy.ownerBoardID(of: $0) == presence.boardID }) ?? true,
      presence.notebookPageID.map({ page in
        presence.selectedItemID.flatMap { content.workspace.item(id: $0) }?.pageIDs.contains(page) == true
      }) ?? true else {
      throw NotebookStorageError.invalidTransaction("checkpoint dependencies or presence")
    }
    let contexts = Set(envelope.contexts.map(\.id))
    let actions = Set(envelope.actions.map(\.id))
    guard envelope.selection?.contextID.map({ contexts.contains($0) }) ?? true,
      envelope.actions.allSatisfy({ contexts.contains($0.action.resolvedContextID) }),
      envelope.delivery.allSatisfy({ actions.contains($0.id) }) else {
      throw NotebookStorageError.invalidTransaction("checkpoint history dependencies")
    }
    try CollaborationWorkspace(files: content.sourceFiles()).validate()
  }
}

public struct NotebookCheckpointReceipt: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let checkpointSHA256: String
  public let pageCount: Int
  public let documentCount: Int
  public let spatialActionCount: Int
}

extension NotebookStore {
  /// Bootstrap only: no live or previously edited archive may be replaced.
  /// All content, history, selection and provenance enter one ordinary WAL
  /// transaction. Failure leaves no accepted partial checkpoint or delivery.
  public func installCheckpoint(_ checkpoint: NotebookCheckpoint) throws -> NotebookCheckpointReceipt {
    try checkpoint.validate()
    let content = checkpoint.envelope.content!
    let receipt = try NotebookCheckpointReceipt(workspaceID: checkpoint.workspaceID,
      checkpointSHA256: collaborationHash(checkpoint), pageCount: content.pages.count,
      documentCount: content.documents.count, spatialActionCount: content.ink.actions.count)
    if !FileManager.default.fileExists(atPath: databaseURL.path) {
      try prepareEmptyWorkspace(workspaceID: checkpoint.workspaceID)
    }
    return try commandTransaction {
      guard let database = currentSQL,
        try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text
          == checkpoint.workspaceID.uuidString.lowercased(),
        try database.rows("SELECT 1 FROM records LIMIT 1").isEmpty,
        try database.rows("SELECT 1 FROM change_log LIMIT 1").isEmpty else {
        throw NotebookStorageError.invalidTransaction("checkpoint destination is not empty")
      }
      var writes = try content.sourceFiles()
      for context in checkpoint.envelope.contexts {
        writes[contextFile(context.id)] = try .encode(context)
      }
      if let selection = checkpoint.envelope.selection {
        writes["collaboration/selection.json"] = try .encode(selection)
      }
      for action in checkpoint.envelope.actions {
        writes["collaboration/actions/\(action.id.uuidString.lowercased()).json"] = try .encode(action)
      }
      for delivery in checkpoint.envelope.delivery {
        writes["collaboration/delivery/\(delivery.id.uuidString.lowercased()).json"] = try .encode(delivery)
      }
      writes["last-context.json"] = try .encode(checkpoint.presence)
      writes["local/checkpoint.json"] = try .encode(receipt)
      try publishRecords(writes: writes)
      return receipt
    }
  }
}
