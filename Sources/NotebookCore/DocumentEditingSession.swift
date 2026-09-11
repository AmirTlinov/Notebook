import Foundation

/// An edit keeps the exact field the person started from, independently of
/// later document pagination, state commits and the current selection.
public struct DocumentSourceEdit: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let documentID: UUID
  public let blockID: String
  public let baseSource: String
  public let baseVersion: ContentFieldVersion
  public let source: String
  public let sequence: UInt64

  public init(sessionID: UUID, documentID: UUID, blockID: String, baseSource: String,
    baseVersion: ContentFieldVersion, source: String, sequence: UInt64) {
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
  public let phase: Phase

  public var isUnfinished: Bool { ![Phase.committed, .discarded].contains(phase) }

  public init(edit: DocumentSourceEdit, selectionStart: Int = 0, selectionEnd: Int = 0,
    isComposing: Bool = false, phase: Phase = .editing) {
    self.edit = edit; self.selectionStart = selectionStart; self.selectionEnd = selectionEnd
    self.isComposing = isComposing; self.phase = phase
  }

  fileprivate func replacingPhase(_ phase: Phase) -> Self {
    .init(edit: edit, selectionStart: selectionStart, selectionEnd: selectionEnd, isComposing: false, phase: phase)
  }

  fileprivate func validate() throws {
    guard !edit.blockID.isEmpty, edit.blockID.utf16.count <= 120,
      edit.source.utf16.count <= DocumentBlock.maximumSourceLength,
      edit.baseSource.utf16.count <= DocumentBlock.maximumSourceLength,
      edit.sequence <= VersionStamp.maximumCounter,
      edit.baseVersion.stamp.counter <= VersionStamp.maximumCounter,
      edit.baseVersion.observed.count <= 256,
      edit.baseVersion.observed.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value <= VersionStamp.maximumCounter }),
      selectionStart >= 0, selectionEnd >= selectionStart, selectionEnd <= edit.source.utf16.count else {
      throw CollaborationError("invalid_draft", "Черновик называет исходный блок, его версию и допустимое выделение текста.")
    }
  }
}

public struct DocumentSourceCommitResult: Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case committed, conflict, targetMissing }
  public let status: Status
  public let publication: DocumentBlockSourcePublication?
}

extension DocumentDocument {
  public func sourceVersion(blockID: String) -> ContentFieldVersion {
    collaboration?.fields[fieldKey(["blocks", collaborationIdentity(blockID), "content"])]
      ?? .init(stamp: contentStamp, human: true)
  }
}

extension NotebookStore {
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
          return .init(status: .committed, publication: try documentSourceForEdit(edit).flatMap {
            DocumentBlockSourcePublication(document: $0, blockID: edit.blockID)
          })
        }
        guard previous.phase != .discarded, edit.sequence >= previous.edit.sequence else {
          throw CollaborationError("stale_draft", "Этот вариант черновика уже завершён или продолжен.")
        }
      }
      let before = try documentSourceForEdit(edit)
      var document = before
      let block = document?.blocks.first
      let status: DocumentSourceCommitResult.Status
      if block == nil { status = .targetMissing }
      else if block?.source != edit.baseSource || document?.sourceVersion(blockID: edit.blockID) != edit.baseVersion {
        status = .conflict
      } else { status = .committed }
      if status == .committed, block?.source != edit.source, let before {
        guard document?.replaceBlockSource(id: block!.id, source: edit.source, actor: actor) == true else {
          throw CollaborationError("invalid_draft", "Не удалось применить исходник черновика.")
        }
        let file = documentFile(edit.documentID), old = try JSONValue.encode(before), next = try JSONValue.encode(document!)
        try admitContentCausalFields(file: file, before: old, after: next)
        try publishProjectionEdits(file: file, before: old, after: next)
      }
      let phase: DocumentEditingSession.Phase = status == .committed ? .committed : status == .conflict ? .conflict : .targetMissing
      let draft = DocumentEditingSession(edit: edit,
        selectionStart: min(previous?.selectionStart ?? 0, edit.source.utf16.count),
        selectionEnd: min(previous?.selectionEnd ?? 0, edit.source.utf16.count), phase: phase)
      try publishCollaboration(writes: [documentDraftPath(edit.sessionID): try .encode(draft)])
      return .init(status: status, publication: document.flatMap {
        DocumentBlockSourcePublication(document: $0, blockID: edit.blockID)
      })
    }
  }

  /// Only this editor's source and causal owners are admitted before decoding.
  /// A partial document remains private to the command; callers receive one
  /// named publication, never an archive with silently missing neighbours.
  private func documentSourceForEdit(_ edit: DocumentSourceEdit) throws -> DocumentDocument? {
    guard try readItemHeader(edit.documentID)?.kind == .document else { return nil }
    let file = documentFile(edit.documentID), root = file + "#"
    let id = collaborationIdentity(edit.blockID), address = root + "/blocks/@" + fieldKey([id])
    let fields = ["preamble", "blocks/order"] + DocumentBlock.causalFieldKeys(id: id)
    let addresses = [(root, false), (address, true)] + fields.map {
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
      next.blockID == previous.blockID, next.baseSource == previous.baseSource, next.baseVersion == previous.baseVersion else {
      throw CollaborationError("draft_owner_mismatch", "Сеанс редактирования не меняет исходного владельца и его версию.")
    }
  }
}
