import Foundation

/// An edit keeps the exact field the person started from, independently of
/// later document pagination, state commits and the current selection.
public struct DocumentSourceEdit: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let documentID: UUID
  public let fileID: String
  public let baseSource: String
  public let baseVersion: ContentFieldVersion
  public let source: String
  public let sequence: UInt64

  public init(sessionID: UUID, documentID: UUID, fileID: String, baseSource: String,
    baseVersion: ContentFieldVersion, source: String, sequence: UInt64) {
    self.sessionID = sessionID; self.documentID = documentID; self.fileID = fileID
    self.baseSource = baseSource; self.baseVersion = baseVersion; self.source = source; self.sequence = sequence
  }
}

public struct DocumentEditingSession: Codable, Equatable, Sendable, Identifiable {
  public enum Phase: String, Codable, Sendable { case editing, conflict, targetMissing, committed, discarded }
  public var id: UUID { edit.sessionID }
  public let edit: DocumentSourceEdit
  public let selectionStart: Int
  public let selectionEnd: Int
  public let isComposing: Bool
  public let scrollTop: Double?
  public let phase: Phase
  public let committedResult: DocumentSourceCommitResult?

  public var isUnfinished: Bool { ![Phase.committed, .discarded].contains(phase) }

  public init(edit: DocumentSourceEdit, selectionStart: Int = 0, selectionEnd: Int = 0,
    isComposing: Bool = false, scrollTop: Double? = nil, phase: Phase = .editing, committedResult: DocumentSourceCommitResult? = nil) {
    self.edit = edit; self.selectionStart = selectionStart; self.selectionEnd = selectionEnd
    self.isComposing = isComposing; self.scrollTop = scrollTop; self.phase = phase; self.committedResult = committedResult
  }

  fileprivate func replacingPhase(_ phase: Phase) -> Self {
    .init(edit: edit, selectionStart: selectionStart, selectionEnd: selectionEnd, isComposing: false, scrollTop: scrollTop, phase: phase)
  }

  fileprivate func validate() throws {
    guard !edit.fileID.isEmpty, edit.fileID.utf16.count <= 120,
      edit.source.utf8.count <= DocumentFile.maximumSourceLength,
      edit.baseSource.utf8.count <= DocumentFile.maximumSourceLength,
      edit.sequence <= VersionStamp.maximumCounter,
      edit.baseVersion.stamp.counter <= VersionStamp.maximumCounter,
      edit.baseVersion.observed.count <= 256,
      edit.baseVersion.observed.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value <= VersionStamp.maximumCounter }),
      selectionStart >= 0, selectionEnd >= selectionStart, selectionEnd <= edit.source.utf16.count,
      scrollTop.map({ $0.isFinite && $0 >= 0 }) ?? true else {
      throw CollaborationError("invalid_draft", "Черновик называет исходный блок, его версию и допустимое выделение текста.")
    }
  }
}

public struct DocumentSourceCommitResult: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case committed, conflict, targetMissing }
  public let status: Status
  public let publication: DocumentFileSourcePublication?
  public let actionID: UUID?
  public init(status: Status, publication: DocumentFileSourcePublication?, actionID: UUID? = nil) {
    self.status = status; self.publication = publication; self.actionID = actionID
  }
}

extension NotebookStore {
  /// Native insertion uses the same action executor and causal undo as agents.
  /// It appends at the current order inside the transaction, never replaces a
  /// stale copy of the whole document just to introduce one empty source block.
  public func insertDocumentFile(documentID: UUID, path: String, actor: UUID) throws -> (receipt: CollaborationReceipt, document: DocumentDocument, fileID: String) {
    return try commandTransaction(readAllowance: .agentCommand) {
      let target = CollaborationTarget(kind: .document, id: documentID), id = UUID().uuidString.lowercased()
      let action = CollaborationAction(summary: "Добавление файла документа",
        expected: [.init(target: target, revision: try targetContentRevision(target: target))],
        operations: [.init(kind: .putDocumentFile, target: target, id: id, values: ["path": .string(path), "source": .string(""), "expectedVersion": .null])])
      let receipt = try applyCollaborationActionImmediately(action, actor: actor, requestFingerprint: nil, human: true)
      return (receipt, try loadDocument(documentID), id)
    }
  }

  private func documentDraftPath(_ id: UUID) -> String { "document-drafts/\(id.uuidString.lowercased()).json" }

  private func readDocumentEditingSession(_ id: UUID) throws -> DocumentEditingSession? {
    guard let value = try storedValue(documentDraftPath(id))?.decode(DocumentEditingSession.self) else { return nil }
    try value.validate(); return value
  }

  public func documentEditingSessions(documentID: UUID? = nil) throws -> [DocumentEditingSession] {
    try readTransaction { _ in
      try storedValues(prefix: "document-drafts/").compactMap {
        let value = try $0.decode(DocumentEditingSession.self)
        try value.validate()
        return value.isUnfinished && (documentID == nil || value.edit.documentID == documentID) ? value : nil
      }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
  }

  /// Terminal records fence late queued input after commit/discard. They are
  /// not shown as drafts and cannot be reopened by an older WebKit message.
  public func saveDocumentDraft(_ draft: DocumentEditingSession) throws {
    try draft.validate(); try prepare()
    try withMutationLock {
      guard draft.phase == .editing else { throw CollaborationError("invalid_draft", "Состояние сохранения принадлежит исполнителю записи.") }
      if let previous = try readDocumentEditingSession(draft.id) {
        try validateDocumentSessionIdentity(draft.edit, previous.edit)
        guard previous.isUnfinished, draft.edit.sequence > previous.edit.sequence else { return }
      }
      try publishCollaboration(writes: [documentDraftPath(draft.id): try .encode(draft)])
    }
  }

  public func discardDocumentDraft(_ sessionID: UUID) throws {
    try prepare()
    try withMutationLock {
      guard let draft = try readDocumentEditingSession(sessionID), draft.isUnfinished else { return }
      try publishCollaboration(writes: [documentDraftPath(sessionID): try .encode(draft.replacingPhase(.discarded))])
    }
  }

  /// Only this locked read/compare/publication accepts a text edit. Another
  /// block's update is retained; a changed/deleted source leaves the draft.
  public func commitDocumentSource(edit: DocumentSourceEdit, actor: UUID) throws -> DocumentSourceCommitResult {
    let candidate = DocumentEditingSession(edit: edit)
    try candidate.validate()
    return try commandTransaction {
      let previous = try readDocumentEditingSession(edit.sessionID)
      if let previous {
        try validateDocumentSessionIdentity(edit, previous.edit)
        if previous.phase == .committed {
          guard previous.edit == edit else { throw CollaborationError("stale_draft", "Завершённый сеанс нельзя использовать для другого текста.") }
          guard let accepted = previous.committedResult else {
            throw CollaborationError("edit_receipt_unavailable", "Сохранение уже выполнено. Прочитайте текущий исходник перед следующей правкой.")
          }
          return accepted
        }
        guard previous.phase != .discarded, edit.sequence >= previous.edit.sequence else {
          throw CollaborationError("stale_draft", "Этот вариант черновика уже завершён или продолжен.")
        }
      }
      let before = try documentSourceForEdit(edit)
      var document = before
      let file = document?.files.first
      let currentSource = file?.isText == true ? file?.source : nil
      let currentVersion = document?.fileVersion(fileID: edit.fileID)
      let status: DocumentSourceCommitResult.Status
      if currentSource == nil { status = .targetMissing }
      else if currentSource != edit.baseSource || currentVersion != edit.baseVersion {
        status = .conflict
      } else { status = .committed }
      var actionID: UUID?
      if status == .committed, currentSource != edit.source {
        let target = CollaborationTarget(kind: .document, id: edit.documentID)
        // The addressed field CAS above and this owner expectation are in the
        // same transaction. Changes in other blocks do not invalidate a draft.
        let action = CollaborationAction(id: edit.sessionID, summary: "Изменение текста документа",
          expected: [.init(target: target, revision: try targetContentRevision(target: target))],
          operations: [.init(kind: .patchDocumentFile, target: target, id: edit.fileID, values: ["expectedVersion": try .encode(edit.baseVersion), "range": .object(["location": .number(0), "length": .number(Double(edit.baseSource.utf16.count))]), "expectedText": .string(edit.baseSource), "source": .string(edit.source)])])
        actionID = try applyCollaborationActionImmediately(action, actor: actor, requestFingerprint: nil, human: true).id
        document = try documentSourceForEdit(edit)
      }
      let phase: DocumentEditingSession.Phase = status == .committed ? .committed : status == .conflict ? .conflict : .targetMissing
      let result = DocumentSourceCommitResult(status: status, publication: document.flatMap {
        DocumentFileSourcePublication(document: $0, fileID: edit.fileID)
      }, actionID: actionID)
      let draft = DocumentEditingSession(edit: edit,
        selectionStart: min(previous?.selectionStart ?? 0, edit.source.utf16.count),
        selectionEnd: min(previous?.selectionEnd ?? 0, edit.source.utf16.count), scrollTop: previous?.scrollTop,
        phase: phase, committedResult: status == .committed ? result : nil)
      try publishCollaboration(writes: [documentDraftPath(edit.sessionID): try .encode(draft)])
      return result
    }
  }

  /// Only this editor's source and causal owners are admitted before decoding.
  /// A partial document remains private to the command; callers receive one
  /// named publication, never an archive with silently missing neighbours.
  private func documentSourceForEdit(_ edit: DocumentSourceEdit) throws -> DocumentDocument? {
    try documentFileProjection(documentID: edit.documentID, fileID: edit.fileID)
  }

  private func validateDocumentSessionIdentity(_ next: DocumentSourceEdit, _ previous: DocumentSourceEdit) throws {
    guard next.sessionID == previous.sessionID, next.documentID == previous.documentID,
      next.fileID == previous.fileID, next.baseSource == previous.baseSource, next.baseVersion == previous.baseVersion else {
      throw CollaborationError("draft_owner_mismatch", "Сеанс редактирования не меняет исходного владельца и его версию.")
    }
  }
}

extension NotebookStore {
  public func renameDocumentFile(documentID: UUID, fileID: String, path: String, actor: UUID) throws -> (receipt: CollaborationReceipt, document: DocumentDocument, fileID: String) {
    try commandTransaction(readAllowance: .agentCommand) {
      guard let file = try readDocumentFile(documentID: documentID, fileID: fileID) else { throw CocoaError(.fileNoSuchFile) }
      let target = CollaborationTarget(kind: .document, id: documentID)
      let action = CollaborationAction(summary: "Переименование файла документа", expected: [.init(target: target, revision: try targetContentRevision(target: target))],
        operations: [.init(kind: .renameDocumentFile, target: target, id: fileID,
          values: ["path": .string(path), "expectedVersion": try .encode(file.sourceVersion)])])
      let receipt = try applyCollaborationActionImmediately(action, actor: actor, requestFingerprint: nil, human: true)
      return (receipt, try loadDocument(documentID), fileID)
    }
  }
}
