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
public final class CodexMessageTransfer: Sendable {
  /// Full transfer value limit. A native RPC envelope has its own frame limit.
  public static let maximumBytes = 8 * 1_048_576
  public static let partBytes = 48 * 1024
  public let id = UUID()
  public let threadID: String, turnID: String, messageID: String, digest: String, contentRevision: String
  private let data: Data
  private let release: (@Sendable () -> Void)?
  private let requireOwner: (@Sendable () async throws -> Void)?
  public var byteCount: Int { data.count }
  public init(threadID: String, message: CodexMessage, release: (@Sendable () -> Void)? = nil,
    requireOwner: (@Sendable () async throws -> Void)? = nil) throws {
    self.threadID = threadID; turnID = message.turnID; messageID = message.id
    self.release = release
    self.requireOwner = requireOwner
    data = try Self.encode(message)
    guard data.count <= Self.maximumBytes, !message.isTruncated else { throw CollaborationError("native_message_limit", "Полное сообщение превышает предел кадра Codex (8 МиБ). Оригинал не изменён; Notebook не может загрузить его этим протоколом.") }
    digest = Self.digest(data); contentRevision = message.contentRevision ?? digest
  }
  deinit { release?() }
  public func requireCurrentOwner() async throws {
    try Task.checkCancellation()
    try await requireOwner?()
  }
  public func part(offset: Int) throws -> CodexMessagePart {
    guard offset >= 0, offset < data.count else { throw NotebookTransportError.invalidAcknowledgement }
    return .init(transferID:id,digest:digest,contentRevision:contentRevision,totalBytes:data.count,offset:offset,
      data:data.subdata(in:offset..<min(data.count,offset+Self.partBytes)))
  }
  public static func encode(_ message: CodexMessage) throws -> Data {
    guard encodedByteCount(message) != nil else {
      throw CollaborationError("native_message_limit", "Полное сообщение превышает предел значения Codex (8 МиБ).")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(CodexMessage(id:message.id,turnID:message.turnID,clientID:message.clientID,role:message.role,
      text:message.text,isTruncated:message.isTruncated,activity:message.activity,attachments:message.attachments,phase:message.phase))
  }
  /// Count the exact compact transfer encoding before allocating its Data.
  /// contentRevision is deliberately absent from that immutable encoding.
  public static func encodedByteCount(_ message: CodexMessage, maximumBytes: Int = maximumBytes) -> Int? {
    guard maximumBytes >= 2 else { return nil }
    var bytes = 2, fields = 0
    func add(_ count: Int) -> Bool {
      guard count >= 0, count <= maximumBytes - bytes else { return false }
      bytes += count; return true
    }
    func field(_ key: String, _ value: String?) -> Bool {
      guard let value else { return true }
      guard let count = encodedTextBytes(value, within: maximumBytes - bytes),
        add((fields == 0 ? 0 : 1) + key.utf8.count + 5), add(count) else { return false }
      fields += 1; return true
    }
    guard field("id", message.id), field("turnID", message.turnID), field("clientID", message.clientID),
      field("role", message.role.rawValue), field("text", message.text), field("phase", message.phase),
      add((fields == 0 ? 0 : 1) + 14 + (message.isTruncated ? 4 : 5)) else { return nil }
    fields += 1 // comma, quoted isTruncated key, colon, Boolean
    if let activity = message.activity {
      var inner = 2, count = 0
      for (key, value) in [("kind", Optional(activity.kind.rawValue)), ("status", activity.status), ("detail", activity.detail)] {
        guard let value else { continue }
        guard let size = encodedTextBytes(value, within: maximumBytes - bytes),
          size <= maximumBytes - bytes - inner - key.utf8.count - 5 - (count == 0 ? 0 : 1) else { return nil }
        inner += size + key.utf8.count + 5 + (count == 0 ? 0 : 1); count += 1
      }
      guard add(12 + inner) else { return nil }
    }
    if let attachments = message.attachments {
      guard add(17) else { return nil } // comma, key, colon, []
      for (index, value) in attachments.enumerated() {
        guard let size = encodedTextBytes(value, within: maximumBytes - bytes), add(size + 2 + (index == 0 ? 0 : 1)) else { return nil }
      }
    }
    return bytes
  }
  public static func encodedTextBytes(_ text: String, within limit: Int) -> Int? {
    guard limit >= 0 else { return nil }
    var bytes = 0
    for byte in text.utf8 {
      let count: Int
      switch byte {
      case 8, 9, 10, 12, 13, 34, 92: count = 2
      case 0..<32: count = 6
      default: count = 1
      }
      guard count <= limit - bytes else { return nil }; bytes += count
    }
    return bytes
  }
  public static func textPrefix(_ text: String, maximumBytes: Int) -> String {
    let bytes = Data(text.utf8.prefix(max(0, maximumBytes)))
    for removed in 0...min(3, bytes.count) {
      if let value = String(data: bytes.dropLast(removed), encoding: .utf8) { return value }
    }
    return ""
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
    _ = try NotebookJSONAdmission.allocationCost(data, maximumBytes: 128 * 1_048_576)
    let message = try JSONDecoder().decode(CodexMessage.self,from:data)
    try Task.checkCancellation()
    guard !message.isTruncated, message.contentRevision == nil else { throw NotebookTransportError.invalidAcknowledgement }
    return message
  }
}

extension CodexMessage {
  public func preview(maximumBytes: Int = 2048, evicted: Bool = false) -> Self {
    if !evicted, CodexMessageTransfer.encodedByteCount(self, maximumBytes: maximumBytes - 128) != nil { return self }
    func prefix(_ text: String, _ count: Int) -> String {
      CodexMessageTransfer.textPrefix(text, maximumBytes: count)
    }
    var budget = max(0, maximumBytes / 4)
    while true {
      let value = Self(id: id, turnID: turnID, clientID: clientID, role: role,
        text: prefix(text, budget), isTruncated: true, contentRevision: contentRevision,
        activity: activity.map { .init(kind: $0.kind, status: $0.status, detail: $0.detail.map { prefix($0, budget) }) },
        attachments: budget == 0 ? nil : attachments.map { $0.prefix(8).map { prefix($0, min(64, budget / 8)) } }, phase: phase)
      if CodexMessageTransfer.encodedByteCount(value, maximumBytes: maximumBytes - 128) != nil || budget == 0 { return value }
      budget /= 2
    }
  }
  /// Canonical native items get one stable revision on read/completion.
  /// Streaming deltas use their event revision instead of rehashing a growing body.
  public func identifyingContent() -> Self {
    guard contentRevision == nil, !isTruncated, let data = try? CodexMessageTransfer.encode(self) else { return self }
    return .init(id:id,turnID:turnID,clientID:clientID,role:role,text:text,
      contentRevision:CodexMessageTransfer.digest(data),activity:activity,attachments:attachments,phase:phase)
  }
}
