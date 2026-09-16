import CryptoKit
import Foundation

/// The raw action is retained before observing the current element kind or
/// generating Markdown. This local admission record is not replicated content.
public struct NotebookActionSubmission: Codable, Equatable, Sendable {
  public let action: CollaborationAction
  public let fingerprint: String
  public let admittedAt: Date
}

public struct NotebookActionAdmission: Codable, Sendable {
  public enum State: String, Codable, Sendable { case reserved, saved }
  public let state: State
  public let fingerprint: String
  public let receipt: CollaborationReceipt?
}

public struct NotebookActionPreparation: Codable, Sendable {
  public let action: CollaborationAction
  public let markdownOperations: [Int]
}

extension NotebookStore {
  private func submissionFile(_ id: UUID) -> String {
    "local/action-submissions/\(id.uuidString.lowercased()).json"
  }

  public func admitCollaborationSubmission(_ action: CollaborationAction) throws -> NotebookActionAdmission {
    let fingerprint = try collaborationHash(JSONValue.object([
      "domain": .string("notebook.action-request.v1"), "action": try .encode(action)]))
    return try commandTransaction {
      let saved = try storedValue("collaboration/actions/\(action.id.uuidString.lowercased()).json")?.decode(CollaborationReceipt.self)
      if let saved {
        guard let previous = saved.requestFingerprint else {
          throw CollaborationError("request_identity_unavailable", "Ход сохранён прежней версией. Исходная идентичность запроса неизвестна; прочитайте существующую квитанцию.")
        }
        guard previous == fingerprint else { throw submissionConflict() }
        return .init(state: .saved, fingerprint: fingerprint, receipt: saved)
      }
      guard action.requestID == nil, !action.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        action.summary.count <= 1000, (1...512).contains(action.operations.count),
        action.references.count <= 32, (1...1024).contains(action.expected.count),
        (action.additionalOwners?.count ?? 0) <= 32 else {
        throw CollaborationError("invalid_action", "Нужен ограниченный ход с описанием, версиями и операциями.")
      }
      if let previous = try storedValue(submissionFile(action.id))?.decode(NotebookActionSubmission.self) {
        guard previous.fingerprint == fingerprint, previous.action == action else { throw submissionConflict() }
      } else {
        try publishRecords(writes: [submissionFile(action.id): try .encode(NotebookActionSubmission(
          action: action, fingerprint: fingerprint, admittedAt: Date()))])
      }
      return .init(state: .reserved, fingerprint: fingerprint, receipt: nil)
    }
  }

  /// A bounded snapshot after admission supplies only the derived work required
  /// by the trusted parser. It holds no transaction while parsing takes place.
  public func prepareCollaborationSubmission(_ id: UUID, fingerprint: String) throws -> NotebookActionPreparation {
    try readTransaction { _ in
      let submission = try requireSubmission(id, fingerprint: fingerprint)
      var kinds: [String: String] = [:], markdown: [Int] = []
      let operations = try submission.action.operations.enumerated().map { index, original in
        var identifier = original.id, values = original.values
        if [.createNotebook, .createDocument, .createBoard].contains(original.kind) {
          identifier = identifier ?? Self.submissionID(id, suffix: "item:\(index)").uuidString.lowercased()
          if original.kind == .createNotebook, values["pageID"] == nil {
            values["pageID"] = .string(Self.submissionID(id, suffix: "page:\(index)").uuidString.lowercased())
          }
        } else if original.kind == .appendInkStroke {
          identifier = identifier ?? Self.submissionID(id, suffix: "stroke:\(index)").uuidString.lowercased()
        }
        let key = "\(original.target.kind):\(original.target.id):\(identifier ?? "")"
        if [.insertElement, .convertInkToElement].contains(original.kind) { kinds[key] = values["kind"]?.string }
        if original.kind == .updateElement, values["source"]?.string != nil, kinds[key] == nil {
          if original.target.kind == .page {
            kinds[key] = try loadPage(original.target.id).elements.first { $0.id == identifier }?.kind.rawValue
          } else {
            kinds[key] = try readSpatialElement(boardID: original.target.boardID ?? original.target.id,
              elementID: identifier ?? "")?.kind.rawValue
          }
        }
        if kinds[key] == "markdown", values["source"]?.string != nil { markdown.append(index) }
        return CollaborationOperation(kind: original.kind, target: original.target, id: identifier, values: values)
      }
      let raw = submission.action
      return .init(action: .init(id: raw.id, contextID: raw.contextID, additionalOwners: raw.additionalOwners,
        summary: raw.summary, references: raw.references, expected: raw.expected, operations: operations), markdownOperations: markdown)
    }
  }

  /// Identity, current revisions, content, undo receipt and raw fingerprint all
  /// meet inside the existing writer transaction. A late retry never reparses.
  public func commitCollaborationSubmission(_ normalized: CollaborationAction, fingerprint: String, actor: UUID) throws -> CollaborationReceipt {
    try commandTransaction(readAllowance: .agentCommand) {
      let submission = try requireSubmission(normalized.id, fingerprint: fingerprint)
      if let saved = try storedValue("collaboration/actions/\(normalized.id.uuidString.lowercased()).json")?.decode(CollaborationReceipt.self) {
        guard saved.requestFingerprint == fingerprint else { throw submissionConflict() }
        return saved
      }
      try validateCollaborationExpectations(submission.action)
      let plan = try prepareCollaborationSubmission(normalized.id, fingerprint: fingerprint)
      var values = normalized.operations
      guard values.count == plan.action.operations.count else { throw submissionConflict() }
      for index in plan.markdownOperations {
        let operation = values[index]
        guard operation.values["html"]?.string != nil else {
          throw CollaborationError("normalization_required", "Markdown должен пройти общий доверенный нормализатор.")
        }
        var fields = operation.values
        fields["html"] = plan.action.operations[index].values["html"]
        values[index] = .init(kind: operation.kind, target: operation.target, id: operation.id, values: fields)
      }
      let stripped = CollaborationAction(id: normalized.id, contextID: normalized.contextID,
        requestID: normalized.requestID, additionalOwners: normalized.additionalOwners, summary: normalized.summary,
        references: normalized.references, expected: normalized.expected, operations: values)
      guard stripped == plan.action else { throw submissionConflict() }
      return try applyCollaborationAction(normalized, actor: actor, requestFingerprint: fingerprint)
    }
  }

  private func requireSubmission(_ id: UUID, fingerprint: String) throws -> NotebookActionSubmission {
    guard let value = try storedValue(submissionFile(id))?.decode(NotebookActionSubmission.self),
      value.fingerprint == fingerprint else { throw submissionConflict() }
    return value
  }

  private func submissionConflict() -> CollaborationError {
    .init("action_id_conflict", "Этот ID уже принадлежит другому исходному ходу.")
  }

  public static func submissionID(_ actionID: UUID, suffix: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data("\(actionID.uuidString.lowercased()):\(suffix)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x0f) | 0x80
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
      bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
  }
}
