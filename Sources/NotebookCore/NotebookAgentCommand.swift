import Foundation
import CryptoKit

/// The same Core dispatcher executes private Notebook tools with a captured
/// grant. Neither the model nor JSON arguments can select a new authority.
extension NotebookCommandDispatcher {
  public func handleAgent(tool: String, arguments: JSONValue, callID: String,
    authority: AgentActionAuthority) throws -> JSONValue {
    guard !callID.isEmpty, callID.utf8.count <= 512,
      try NotebookStore.storageEncoder.encode(arguments).count <= 262_144 else {
      throw CollaborationError("tool_limit", "Вызов превышает ограниченный размер инструмента.")
    }
    return try store.commandTransaction {
      let (request, _) = try store.requireAgentExecution(authority)
      switch tool {
      case "read":
        guard case .object(let values) = arguments else { throw agentCommandDenied() }
        if values.isEmpty { return .object(["request": try .encode(request)]) }
        guard Set(values.keys) == Set(["referenceID"]),
          let id = values["referenceID"]?.string.flatMap(UUID.init(uuidString:)) else { throw agentCommandDenied() }
        var source = try store.agentPinnedSource(authority, referenceID: id)
        let hasImage = source.image != nil
        source.image = nil
        return .object(["source": try .encode(source), "hasImage": .bool(hasImage)])
      case "apply":
        guard request.grant.mode == .change,
          case .object(let values) = arguments,
          Set(values.keys) == Set(["summary", "operations"]),
          let summary = values["summary"]?.string, !summary.isEmpty, summary.utf8.count <= 4_096,
          let raw = values["operations"] else { throw agentCommandDenied() }
        let operations = try raw.decode([CollaborationOperation].self)
        guard !operations.isEmpty, operations.count <= 64 else { throw agentCommandDenied() }
        let id = Self.agentActionID(requestID: request.id, callID: callID)
        // Re-delivery uses the server's stable call ID, not an agent-chosen UUID.
        // Validate the immutable original payload before returning its receipt;
        // a later human edit does not turn an acknowledged write into a retry.
        if try store.hasStoredValue("collaboration/actions/\(id.uuidString.lowercased()).json") {
          let receipt = try store.collaborationAction(id)
          guard receipt.action.requestID == request.id, receipt.action.summary == summary,
            receipt.action.operations == operations else { throw CollaborationError("call_id_conflict", "Вызов уже сохранил другой ход.") }
          return try .encode(receipt)
        }
        let uniqueTargets: Set<CollaborationTarget> = Set(operations.map(\.target))
        let targets = uniqueTargets.sorted { left, right in
          let a = left.kind.rawValue + left.id.uuidString
          let b = right.kind.rawValue + right.id.uuidString
          return a < b
        }
        let expected = try targets.map { target in
          // The grant gate independently checks the frozen source before this
          // fresh causal frontier can authorize an operation.
          try agentExpectation(target)
        }
        let action = CollaborationAction(id: id, contextID: request.contextID, requestID: request.id,
          summary: summary, references: request.grant.references, expected: expected, operations: operations)
        return try .encode(store.applyCollaborationAction(action, actor: store.collaborationActorID(),
          waitForInput: 0, agentAuthority: authority))
      default: throw agentCommandDenied()
      }
    }
  }

  public static func agentActionID(requestID: UUID, callID: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data((requestID.uuidString.lowercased() + "\u{0}" + callID).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  private func agentExpectation(_ target: CollaborationTarget) throws -> CollaborationExpectation {
    switch target.kind {
    case .page:
      let page = try store.loadPage(target.id)
      return .init(target: target, revision: page.agentStamp.revision, inkRevision: page.drawingStamp.revision)
    case .document:
      return try .init(target: target, revision: store.loadDocument(target.id).contentStamp.revision,
        stateRevision: store.loadDocumentState(target.id).stamp.revision)
    case .board, .cover:
      guard let id = target.kind == .board ? target.id : target.boardID,
        let node = try store.readBoardNodeHeader(id) else { throw agentCommandDenied() }
      return try .init(target: target, revision: node.board.stamp.revision,
        inkRevision: store.workspaceHeader().spatialInkStamp?.revision)
    case .workspace: throw agentCommandDenied()
    }
  }

  private func agentCommandDenied() -> CollaborationError {
    .init("grant_denied", "Инструмент читает только закреплённый фрагмент; расширение требует разрешения человека.")
  }
}
