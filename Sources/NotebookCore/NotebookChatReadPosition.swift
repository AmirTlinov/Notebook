import Foundation

/// Only presentation receipts are local. Text and ordering remain in the Codex transcript.
public struct NotebookChatReadPosition: Codable, Equatable, Sendable {
  public let threadID: String
  public var readThrough: String?
  public var previewEndsAt: [String: Date]
  public init(threadID: String, readThrough: String? = nil, previewEndsAt: [String: Date] = [:]) {
    self.threadID = threadID; self.readThrough = readThrough; self.previewEndsAt = previewEndsAt
  }
  private enum CodingKeys: String, CodingKey { case threadID, readThrough, previewEndsAt, dismissedThrough }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    threadID = try values.decode(String.self, forKey: .threadID)
    readThrough = try values.decodeIfPresent(String.self, forKey: .readThrough)
    previewEndsAt = try values.decodeIfPresent([String: Date].self, forKey: .previewEndsAt) ?? [:]
    // Migrate the previously saved single close receipt once; never encode it.
    if let dismissed = try values.decodeIfPresent(String.self, forKey: .dismissedThrough) { previewEndsAt[dismissed] = .distantPast }
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(threadID, forKey: .threadID); try values.encodeIfPresent(readThrough, forKey: .readThrough)
    try values.encode(previewEndsAt, forKey: .previewEndsAt)
  }
  public func unread(in replies: [CodexMessage]) -> [CodexMessage] {
    guard let readThrough else { return replies }
    guard let index = replies.firstIndex(where: { $0.id == readThrough }) else { return replies }
    return Array(replies.suffix(from: index + 1))
  }
  /// Presentation deadlines belong to the task, not the lifetime of a SwiftUI
  /// card. Resizing, reconnecting and dismissing do not create unread messages.
  public mutating func present(in replies: [CodexMessage], at now: Date) {
    for reply in unread(in: replies) where previewEndsAt[reply.id] == nil {
      let seconds = min(25.0, max(12.0, Double(reply.text.count) / 18))
      previewEndsAt[reply.id] = now.addingTimeInterval(seconds)
    }
    // Overflow remains unread, but cannot pop back after a newer card is closed.
    let visible = unread(in: replies).filter { (previewEndsAt[$0.id] ?? .distantPast) > now }
    for reply in visible.dropLast(2) { previewEndsAt[reply.id] = now }
  }
  public func previews(in replies: [CodexMessage], at now: Date) -> [CodexMessage] {
    Array(unread(in: replies).filter { (previewEndsAt[$0.id] ?? .distantPast) > now }.suffix(2))
  }
  public mutating func dismiss(_ messageID: String, at now: Date) {
    guard let end = previewEndsAt[messageID], end > now else { return }
    previewEndsAt[messageID] = now
  }
  /// Unread receipts count useful completed answers, never tool progress.
  public static func replies(in messages: [CodexMessage], conversation: CodexConversation?) -> [CodexMessage] {
    var last: [String: String] = [:]
    for message in messages where message.role == .assistant && message.activity == nil && message.phase != "commentary"
      && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if (message.phase == "final_answer" && conversation?.activeTurnID != message.turnID) || conversation?.turnStatuses[message.turnID] == "completed" {
        last[message.turnID] = message.id
      }
    }
    return messages.filter { last[$0.turnID] == $0.id }
  }
}
