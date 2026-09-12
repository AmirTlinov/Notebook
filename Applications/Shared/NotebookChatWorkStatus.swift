#if os(iOS)
import Foundation
import NotebookCore

/// A presentation of the native active turn, shared by the transcript and
/// companion. It never synthesizes progress from an earlier turn or sends work.
struct NotebookChatWorkStatus: Codable, Equatable {
  let turnID: String
  let title: String
  let running: Bool

  init?(conversation: CodexConversation?, connected: Bool) {
    guard let conversation,
      conversation.busy || conversation.activeTurnID != nil || !conversation.requests.isEmpty else { return nil }
    let activeTurn = conversation.activeTurnID ?? conversation.requests.first?.turnID ?? ""
    turnID = activeTurn
    running = connected && conversation.requests.isEmpty
    if !connected { title = "Mac не в сети · задача сохранена"; return }
    if !conversation.requests.isEmpty { title = "Нужно ваше решение"; return }
    let items = conversation.messages.filter { $0.turnID == activeTurn && $0.role == .assistant }
    let current = items.last { $0.phase == "commentary" && $0.activity == nil }
      ?? items.last { $0.activity?.status == "inProgress" }
    let text = current?.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") ?? ""
    title = text.isEmpty ? "Работаю над задачей" : String(text.prefix(180))
  }
}
#endif
