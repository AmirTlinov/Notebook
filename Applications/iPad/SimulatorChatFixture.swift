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
    let task = CodexTask(id: "7e7a1000-0000-4000-8000-000000000088", title: "Непрерывный разговор", cwd: "/fixture", projectID: "fixture")
    var running = true, subscription: UUID?
    var selection = CodexModelSelection(model: "fixture-a", effort: "low"), revision = 1
    let earlier = (0..<10).map { CodexMessage(id: "old-\($0)", turnID: "old", clientID: nil, role: .assistant,
      text: "Ранний ответ \($0).\n\nМатериал остаётся в этой же переписке при прокрутке вверх.") }
    let recent = (10..<20).map { CodexMessage(id: "recent-\($0)", turnID: turn, clientID: nil, role: .assistant,
      text: "Ответ \($0).\n\nПродолжение разговора с агентом.") }
    let user = CodexMessage(id: "user-file", turnID: turn, clientID: nil, role: .user,
      text: "Добавь диктовку рядом с разговором.", attachments: ["code_image.png"])
    func conversation() -> CodexConversation {
      .init(threadID: task.id, revision: revision, title: task.title, ready: true, busy: running,
        activeTurnID: running ? turn : nil, messages: recent + [user] + (running ? [] : [.init(id: "stopped", turnID: turn, clientID: nil, role: .assistant, text: "Ответ остановлен.")]),
        requests: [], acceptedMessages: [:], turnStatuses: [turn: running ? "inProgress" : "interrupted"], model: selection, contextUsage: .init(used: 193000, window: 258000))
    }
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: persistence, author: author) { envelope, destination in
      guard destination == peer, case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .models: reply = .models([
        .init(id: "fixture-a", name: "Fixture A", efforts: ["low", "high"], defaultEffort: "low", isDefault: true),
        .init(id: "fixture-b", name: "Fixture B", efforts: ["medium", "max"], defaultEffort: "medium")])
      case .resources(_, let kind, _): reply = .resources(.init(resources: [.init(
        attachment: .init(kind: kind == .skills ? .skill : kind == .plugins ? .plugin : .app,
          name: "fixture-resource", path: kind == .skills ? "/fixture/SKILL.md" : kind == .plugins ? "plugin://fixture@market" : "app://fixture"),
        title: "Fixture Resource", detail: "Доступный элемент настоящего протокола", enabled: true)]))
      case .projects: reply = .projects(.init(projects: [.init(id: "fixture", name: "Fixture", roots: ["/fixture"])], nextCursor: nil))
      case .file(.directory): reply = .file(.directory(.init(entries: [.init(name: "example.swift", kind: .file)], next: nil)))
      case .catalogue: reply = .catalogue(.init(tasks: [task], nextCursor: nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: running ? .running : .idle) })
      case .history(_, let cursor): reply = .history(.init(messages: cursor == nil ? recent + [user] : earlier, nextCursor: cursor == nil ? "earlier" : nil))
      case .conversation: subscription = envelope.id; reply = .conversation(conversation())
      case .job(let input):
        if case .setModel(_, let value) = input.action { selection = value }
        else if input.action == .stop(threadID: task.id, turnID: turn) { running = false }
        else { return }
        revision += 1
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
