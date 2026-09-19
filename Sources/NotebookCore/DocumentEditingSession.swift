import Foundation

/// An edit keeps the exact field the person started from, independently of
/// later document pagination, state commits and the current selection.
public struct DocumentSourceEdit: Codable, Equatable, Sendable {
  public enum Field: String, Codable, Sendable { case content, preamble }
  public let field: Field?
  public var isPreamble: Bool { field == .preamble }
  public let sessionID: UUID
  public let documentID: UUID
  public let blockID: String
  public let baseSource: String
  public let baseVersion: ContentFieldVersion
  public let source: String
  public let sequence: UInt64

  public init(sessionID: UUID, documentID: UUID, blockID: String, baseSource: String,
    baseVersion: ContentFieldVersion, source: String, sequence: UInt64, field: Field = .content) {
    self.field = field == .content ? nil : field
    self.sessionID = sessionID; self.documentID = documentID; self.blockID = blockID
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
    guard !edit.blockID.isEmpty, edit.blockID.utf16.count <= 120,
      edit.source.utf16.count <= (edit.isPreamble ? DocumentDocument.maximumPreambleLength : DocumentBlock.maximumSourceLength),
      edit.baseSource.utf16.count <= DocumentBlock.maximumSourceLength,
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
  public let publication: DocumentBlockSourcePublication?
  public let actionID: UUID?
  public let preamblePublication: DocumentPreamblePublication?
  public init(status: Status, publication: DocumentBlockSourcePublication?, actionID: UUID? = nil, preamblePublication: DocumentPreamblePublication? = nil) {
    self.status = status; self.publication = publication; self.actionID = actionID; self.preamblePublication = preamblePublication
  }
}

extension DocumentDocument {
  public func sourceVersion(blockID: String) -> ContentFieldVersion {
    collaboration?.fields[fieldKey(["blocks", collaborationIdentity(blockID), "content"])]
      ?? .init(stamp: contentStamp, human: true)
  }
}

extension NotebookStore {
  /// Native insertion uses the same action executor and causal undo as agents.
  /// It appends at the current order inside the transaction, never replaces a
  /// stale copy of the whole document just to introduce one empty source block.
  public func insertDocumentSource(documentID: UUID, kind: DocumentBlockKind, actor: UUID) throws -> (receipt: CollaborationReceipt, document: DocumentDocument, blockID: String) {
    guard kind != .interactive else { throw CollaborationError("invalid_source_kind", "Живая программа сохраняет своего владельца.") }
    return try commandTransaction(readAllowance: .agentCommand) {
      let target = CollaborationTarget(kind: .document, id: documentID), id = UUID().uuidString.lowercased()
      let action = CollaborationAction(summary: "Добавление исходника документа",
        expected: [.init(target: target, revision: try targetContentRevision(target: target))],
        operations: [.init(kind: .insertBlock, target: target, id: id, values: ["kind": .string(kind.rawValue), "source": .string("")])])
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
      let block = document?.blocks.first
      let currentSource = edit.isPreamble ? document?.preamble : block?.source
      let currentVersion = edit.isPreamble ? document?.preambleVersion : document?.sourceVersion(blockID: edit.blockID)
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
          operations: [edit.isPreamble ? .init(kind: .setPreamble, target: target, values: ["preamble": .string(edit.source)]) : .init(kind: .updateBlock, target: target, id: edit.blockID, values: ["source": .string(edit.source)])])
        actionID = try applyCollaborationActionImmediately(action, actor: actor, requestFingerprint: nil, human: true).id
        document = try documentSourceForEdit(edit)
      }
      let phase: DocumentEditingSession.Phase = status == .committed ? .committed : status == .conflict ? .conflict : .targetMissing
      let result = DocumentSourceCommitResult(status: status, publication: edit.isPreamble ? nil : document.flatMap {
        DocumentBlockSourcePublication(document: $0, blockID: edit.blockID)
      }, actionID: actionID, preamblePublication: edit.isPreamble ? document.map(DocumentPreamblePublication.init) : nil)
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
    guard try readItemHeader(edit.documentID)?.kind == .document else { return nil }
    let file = documentFile(edit.documentID), root = file + "#"
    let id = collaborationIdentity(edit.blockID), address = root + "/blocks/@" + fieldKey([id])
    let fields = ["preamble", "blocks/order"] + (edit.isPreamble ? [] : DocumentBlock.causalFieldKeys(id: id))
    let addresses = [(root, false)] + (edit.isPreamble ? [] : [(address, true)]) + fields.map {
      (root + "/collaboration/fields/@" + fieldKey([$0]), false)
    }
    let rows = try boundedStoredFragments(addresses, maximumCount: 4_096,
      maximumBytes: 4 * 1_024 * 1_024, budget: "document_source_edit")
    guard !rows.isEmpty else { return nil }
    let value = try NotebookRecordCodec.decode(rows, root: root), document = try value.decode(DocumentDocument.self)
    let canonical = try NotebookRecordCodec.encode(.encode(document), file: file)
    let actual = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
    guard document.id == edit.documentID, document.blocks.count <= 1,
      document.blocks.first.map({ collaborationIdentity($0.id) == id }) ?? true,
      canonical.count == actual.count, canonical.allSatisfy({ row in
        guard let stored = actual[row.address] else { return false }
        return row.replacing(value: row.value, position: stored.position) == stored
      }) else { throw NotebookStorageError.corruptRecord(root) }
    return document
  }

  private func validateDocumentSessionIdentity(_ next: DocumentSourceEdit, _ previous: DocumentSourceEdit) throws {
    guard next.sessionID == previous.sessionID, next.documentID == previous.documentID,
      next.blockID == previous.blockID, next.field == previous.field, next.baseSource == previous.baseSource, next.baseVersion == previous.baseVersion else {
      throw CollaborationError("draft_owner_mismatch", "Сеанс редактирования не меняет исходного владельца и его версию.")
    }
  }
}
