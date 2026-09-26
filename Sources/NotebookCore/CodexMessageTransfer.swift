import Foundation
import CryptoKit

/// A read of one native item, not another editable or persisted transcript.
public struct CodexMessageRead: Codable, Equatable, Sendable {
  public let threadID: String, turnID: String, messageID: String
  public let cursor: String?
  public let transferID: UUID?
  public let offset: Int
  public init(threadID: String, turnID: String, messageID: String, cursor: String? = nil, transferID: UUID? = nil, offset: Int = 0) {
    self.threadID = threadID; self.turnID = turnID; self.messageID = messageID
    self.cursor = cursor; self.transferID = transferID; self.offset = offset
  }
  public var isValid: Bool {
    [threadID, turnID, messageID].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
      && (cursor?.utf8.count ?? 0) <= 4096 && (0...CodexMessageTransfer.maximumBytes).contains(offset)
      && (transferID != nil || offset == 0)
  }
}
public enum CodexMessageReadReply: Codable, Equatable, Sendable {
  case searching(nextCursor: String)
  case part(CodexMessagePart)
}
public struct CodexMessagePart: Codable, Equatable, Sendable {
  public let transferID: UUID
  public let digest: String
  public let contentRevision: String
  public let totalBytes: Int, offset: Int
  public let data: Data
}

/// One in-flight immutable item per reading peer. Repeated parts never borrow
/// a newer native body; the consumer joins only this exact digest and offset.
public struct CodexMessageTransfer: Sendable {
  /// Same admission bound as the existing native App Server frame reader.
  public static let maximumBytes = 8 * 1_048_576
  public static let partBytes = 48 * 1024
  public let id = UUID()
  public let threadID: String, turnID: String, messageID: String, digest: String, contentRevision: String
  private let data: Data
  public init(threadID: String, message: CodexMessage) throws {
    self.threadID = threadID; turnID = message.turnID; messageID = message.id
    data = try Self.encode(message)
    guard data.count <= Self.maximumBytes, !message.isTruncated else { throw CollaborationError("native_message_limit", "Полное сообщение превышает предел кадра Codex (8 МиБ). Оригинал не изменён; Notebook не может загрузить его этим протоколом.") }
    digest = Self.digest(data); contentRevision = message.contentRevision ?? digest
  }
  public func part(offset: Int) throws -> CodexMessagePart {
    guard offset >= 0, offset < data.count else { throw NotebookTransportError.invalidAcknowledgement }
    return .init(transferID:id,digest:digest,contentRevision:contentRevision,totalBytes:data.count,offset:offset,
      data:data.subdata(in:offset..<min(data.count,offset+Self.partBytes)))
  }
  public static func encode(_ message: CodexMessage) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(CodexMessage(id:message.id,turnID:message.turnID,clientID:message.clientID,role:message.role,
      text:message.text,isTruncated:message.isTruncated,activity:message.activity,attachments:message.attachments,phase:message.phase))
  }
  public static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}

public struct CodexMessageAssembly: Sendable {
  public private(set) var offset = 0
  public private(set) var transferID: UUID?
  public private(set) var digest: String?
  public private(set) var contentRevision: String?
  private var totalBytes: Int?
  private var data = Data()
  public init() { }
  public mutating func append(_ part: CodexMessagePart) throws -> Bool {
    guard part.offset == offset, (1...CodexMessageTransfer.maximumBytes).contains(part.totalBytes),
      !part.data.isEmpty, part.data.count <= CodexMessageTransfer.partBytes,
      part.data.count <= part.totalBytes-offset,
      transferID == nil || transferID == part.transferID,
      digest == nil || digest == part.digest,
      contentRevision == nil || contentRevision == part.contentRevision,
      totalBytes == nil || totalBytes == part.totalBytes else { throw NotebookTransportError.invalidAcknowledgement }
    transferID = part.transferID; digest = part.digest; contentRevision = part.contentRevision; totalBytes = part.totalBytes
    data.append(part.data); offset += part.data.count
    return offset == part.totalBytes
  }
  /// Decode one completed immutable value on the caller's preparation worker,
  /// not on the main actor receiving bounded transport chunks.
  public func decode() throws -> CodexMessage {
    try Task.checkCancellation()
    guard offset == totalBytes, let digest, CodexMessageTransfer.digest(data) == digest else {
      throw NotebookTransportError.invalidAcknowledgement
    }
    let message = try JSONDecoder().decode(CodexMessage.self,from:data)
    try Task.checkCancellation()
    guard !message.isTruncated, message.contentRevision == nil else { throw NotebookTransportError.invalidAcknowledgement }
    return message
  }
}

extension CodexMessage {
  /// Canonical native items get one stable revision on read/completion.
  /// Streaming deltas use their event revision instead of rehashing a growing body.
  public func identifyingContent() -> Self {
    guard contentRevision == nil, !isTruncated, let data = try? CodexMessageTransfer.encode(self) else { return self }
    return .init(id:id,turnID:turnID,clientID:clientID,role:role,text:text,
      contentRevision:CodexMessageTransfer.digest(data),activity:activity,attachments:attachments,phase:phase)
  }
}
