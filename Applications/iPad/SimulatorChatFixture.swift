#if DEBUG && targetEnvironment(simulator)
import Foundation
import NotebookCore

/// A bounded remote transcript for actual scroll and stop gestures. The real
/// controller still admits stop through its SQLite outbox and native turn ID.
@MainActor enum SimulatorChatFixture {
  static func make(persistence: NotebookPersistenceQueue, author: UUID) async throws -> NotebookChatController? {
    guard ProcessInfo.processInfo.arguments.contains("--notebook-chat-sync-fixture") else { return nil }
    let peer = UUID(uuidString: "7E7A1000-0000-4000-8000-000000000099")!
    let turn = "7e7a1000-0000-4000-8000-000000000077"
    let task = CodexTask(id: "7e7a1000-0000-4000-8000-000000000088", title: "Непрерывный разговор", cwd: "/fixture")
    var running = true, subscription: UUID?
    let earlier = (0..<10).map { CodexMessage(id: "old-\($0)", turnID: "old", clientID: nil, role: .assistant,
      text: "Ранний ответ \($0).\n\nМатериал остаётся в этой же переписке при прокрутке вверх.") }
    let recent = (10..<20).map { CodexMessage(id: "recent-\($0)", turnID: turn, clientID: nil, role: .assistant,
      text: "Ответ \($0).\n\nПродолжение разговора с агентом.") }
    let user = CodexMessage(id: "user-file", turnID: turn, clientID: nil, role: .user,
      text: "Добавь диктовку рядом с разговором.", attachments: ["code_image.png"])
    func conversation() -> CodexConversation {
      .init(threadID: task.id, revision: running ? 1 : 2, title: task.title, ready: true, busy: running,
        activeTurnID: running ? turn : nil, messages: recent + [user] + (running ? [] : [.init(id: "stopped", turnID: turn, clientID: nil, role: .assistant, text: "Ответ остановлен.")]),
        requests: [], acceptedMessages: [:], turnStatuses: [turn: running ? "inProgress" : "interrupted"])
    }
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: persistence, author: author) { envelope, destination in
      guard destination == peer, case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .catalogue: reply = .catalogue(.init(tasks: [task], nextCursor: nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: running ? .running : .idle) })
      case .history(_, let cursor): reply = .history(.init(messages: cursor == nil ? recent + [user] : earlier, nextCursor: cursor == nil ? "earlier" : nil))
      case .conversation: subscription = envelope.id; reply = .conversation(conversation())
      case .job(let input):
        guard input.action == .stop(threadID: task.id, turnID: turn) else { return }
        running = false
        if let subscription { receiver?.receive(.init(body: .event(subscriptionID: subscription, conversation: conversation())), peerID: peer) }
        reply = .job(.init(input: input, state: .accepted, result: .acknowledged, revision: 2))
      default: reply = .failure("Outside chat gesture scenario")
      }
      receiver?.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    receiver = chat
    await chat.start(); await chat.connect(peer); chat.select(task); chat.expanded = true
    return chat
  }
}
#endif
