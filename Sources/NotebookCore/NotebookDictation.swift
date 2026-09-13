import Foundation

/// A recording belongs to one draft on one computer. Audio and credentials are
/// never part of the conversation or the replicated notebook contents.
public struct NotebookDictationRecording: Codable, Equatable, Sendable {
  public static let maximumBytes = 8 * 1024 * 1024
  public static let chunkBytes = 96 * 1024
  public static let maximumDuration: TimeInterval = 300
  public let id: UUID
  public let threadID: String
  public let computerID: UUID
  public let byteCount: Int
  public let sha256: String
  public init(id: UUID, threadID: String, computerID: UUID, byteCount: Int, sha256: String) {
    self.id = id; self.threadID = threadID; self.computerID = computerID
    self.byteCount = byteCount; self.sha256 = sha256
  }
  public var isValid: Bool {
    UUID(uuidString: threadID) != nil && (1...Self.maximumBytes).contains(byteCount)
      && sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

public enum NotebookDictationQuery: Codable, Equatable, Sendable {
  case prepare(NotebookDictationRecording)
  case append(id: UUID, offset: Int, bytes: Data)
  case finish(UUID), status(UUID), retry(UUID), cancel(UUID)
  public var id: UUID {
    switch self {
    case .prepare(let recording): recording.id
    case .append(let id, _, _), .finish(let id), .status(let id), .retry(let id), .cancel(let id): id
    }
  }
  public var isValid: Bool {
    switch self {
    case .prepare(let value): value.isValid
    case .append(_, let offset, let bytes):
      offset >= 0 && offset <= NotebookDictationRecording.maximumBytes
        && !bytes.isEmpty && bytes.count <= NotebookDictationRecording.chunkBytes
        && bytes.count <= NotebookDictationRecording.maximumBytes - offset
    case .finish, .status, .retry, .cancel: true
    }
  }
}

public struct NotebookDictationState: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable { case uploading, transcribing, completed, failed, cancelled }
  public let id: UUID
  public var phase: Phase
  public var receivedBytes: Int
  public var text: String?
  public var error: String?
  public init(id: UUID, phase: Phase = .uploading, receivedBytes: Int = 0, text: String? = nil, error: String? = nil) {
    self.id = id; self.phase = phase; self.receivedBytes = receivedBytes; self.text = text; self.error = error
  }
  public var isValid: Bool {
    (0...NotebookDictationRecording.maximumBytes).contains(receivedBytes)
      && (text?.utf8.count ?? 0) <= 32_768 && (error?.utf8.count ?? 0) <= 4096
      && (phase != .completed || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

extension NotebookStore {
  /// Insertion and its receipt share the panel's transaction. Recovery after a
  /// crash can remove the audio without appending the same words a second time.
  public func insertChatDictation(_ text: String, id: UUID, thread: String, computer: UUID, author: UUID) throws -> NotebookChatPanelState {
    try commandTransaction(advancesReadRevision: false) {
      var panel = try chatPanel(author: author, computer: computer)
      if panel.dictationReceipt == id { return panel }
      guard panel.threadID == thread, panel.sidecarID == computer else {
        throw NotebookStorageError.invalidTransaction("Диктовка относится к другому черновику.")
      }
      let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { throw NotebookStorageError.invalidTransaction("Речь не распознана. Запись сохранена.") }
      let separator = panel.draft.isEmpty || panel.draft.last?.isWhitespace == true ? "" : " "
      let draft = panel.draft + separator + words
      guard draft.utf8.count <= 32_768 else { throw NotebookStorageError.limitExceeded("Черновик слишком длинный. Сократите текст и повторите вставку; запись сохранена.") }
      panel.draft = draft; panel.dictationReceipt = id
      try saveChatPanel(panel, author: author)
      return panel
    }
  }
}
