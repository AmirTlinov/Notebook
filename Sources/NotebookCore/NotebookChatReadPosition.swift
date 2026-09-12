import Foundation

/// Only presentation receipts are local. Text and ordering remain in the Codex transcript.
public struct NotebookChatReadPosition: Codable, Equatable, Sendable {
  public let threadID: String
  public var readThrough: String?
  public var hiddenThrough: String?
  public init(threadID: String, readThrough: String? = nil, hiddenThrough: String? = nil) {
    self.threadID = threadID; self.readThrough = readThrough; self.hiddenThrough = hiddenThrough
  }
  public func unread(in replies: [CodexMessage]) -> [CodexMessage] {
    guard let readThrough else { return replies }
    guard let index = replies.firstIndex(where: { $0.id == readThrough }) else { return replies }
    return Array(replies.suffix(from: index + 1))
  }
  /// A compact cloud contains the last useful answer of a completed turn, never tool progress.
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
