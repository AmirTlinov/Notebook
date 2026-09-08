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
  public let document: DocumentDocument?
}

extension DocumentDocument {
  public func sourceVersion(blockID: String) -> ContentFieldVersion {
    collaboration?.fields[fieldKey(["blocks", blockID, "content"])]
      ?? .init(stamp: contentStamp, human: true)
  }
}

extension NotebookStore {
  private func documentDraftPath(_ id: UUID) -> String { "document-drafts/\(id.uuidString.lowercased()).json" }

  private func readDocumentEditingSession(_ id: UUID) throws -> DocumentEditingSession? {
    let url = root.appendingPathComponent(documentDraftPath(id))
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try JSONDecoder().decode(DocumentEditingSession.self, from: Data(contentsOf: url))
    try value.validate()
    return value
  }

  public func documentEditingSessions(documentID: UUID? = nil) throws -> [DocumentEditingSession] {
    try prepare()
    return try withMutationLock {
      let directory = root.appendingPathComponent("document-drafts", isDirectory: true)
      guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
      return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.compactMap { url in
          let value = try JSONDecoder().decode(DocumentEditingSession.self, from: Data(contentsOf: url))
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
    try candidate.validate(); try prepare()
    return try withMutationLock {
      let previous = try readDocumentEditingSession(edit.sessionID)
      if let previous {
        try validateDocumentSessionIdentity(edit, previous.edit)
        if previous.phase == .committed {
          guard previous.edit == edit else { throw CollaborationError("stale_draft", "Завершённый сеанс нельзя использовать для другого текста.") }
          return .init(status: .committed, document: FileManager.default.fileExists(atPath: documentURL(edit.documentID).path)
            ? try loadDocument(edit.documentID) : nil)
        }
        guard previous.phase != .discarded, edit.sequence >= previous.edit.sequence else {
          throw CollaborationError("stale_draft", "Этот вариант черновика уже завершён или продолжен.")
        }
      }
      let workspace = try loadIndex()
      let exists = workspace.items.contains { $0.id == edit.documentID && $0.kind == .document }
        && FileManager.default.fileExists(atPath: documentURL(edit.documentID).path)
      var document = exists ? try loadDocument(edit.documentID) : nil
      let block = document?.blocks.first { $0.id == edit.blockID }
      let status: DocumentSourceCommitResult.Status
      if block == nil { status = .targetMissing }
      else if block?.source != edit.baseSource || document?.sourceVersion(blockID: edit.blockID) != edit.baseVersion {
        status = .conflict
      } else { status = .committed }
      var writes: [String: JSONValue] = [:]
      if status == .committed, document?.blocks.first(where: { $0.id == edit.blockID })?.source != edit.source {
        guard document?.replaceBlockSource(id: edit.blockID, source: edit.source, actor: actor) == true else {
          throw CollaborationError("invalid_draft", "Не удалось применить исходник черновика.")
        }
        writes["documents/\(edit.documentID.uuidString.lowercased()).json"] = try .encode(document!)
      }
      let phase: DocumentEditingSession.Phase = status == .committed ? .committed : status == .conflict ? .conflict : .targetMissing
      let draft = DocumentEditingSession(edit: edit,
        selectionStart: min(previous?.selectionStart ?? 0, edit.source.utf16.count),
        selectionEnd: min(previous?.selectionEnd ?? 0, edit.source.utf16.count), phase: phase)
      writes[documentDraftPath(edit.sessionID)] = try .encode(draft)
      try publishCollaboration(writes: writes)
      return .init(status: status, document: document)
    }
  }

  private func validateDocumentSessionIdentity(_ next: DocumentSourceEdit, _ previous: DocumentSourceEdit) throws {
    guard next.sessionID == previous.sessionID, next.documentID == previous.documentID,
      next.blockID == previous.blockID, next.baseSource == previous.baseSource, next.baseVersion == previous.baseVersion else {
      throw CollaborationError("draft_owner_mismatch", "Сеанс редактирования не меняет исходного владельца и его версию.")
    }
  }
}
