#if DEBUG && targetEnvironment(simulator)
import Foundation
import NotebookCore

/// UI gestures use the real controller, transport envelopes and xterm input.
/// Only the remote PTY is replaced by a bounded echo peer in this isolated app.
@MainActor enum SimulatorTerminalFixture {
  static func make(persistence: NotebookPersistenceQueue, author: UUID, directory: URL) async throws -> NotebookChatController? {
    guard ProcessInfo.processInfo.arguments.contains("--notebook-terminal-fixture") else { return nil }
    let peer = UUID(uuidString: "7E7A1000-0000-4000-8000-000000000099")!
    let project = CodexProject(id: "terminal-fixture", name: "Notebook", roots: ["/tmp/terminal-fixture"])
    let task = CodexTask(id: "7e7a1000-0000-4000-8000-000000000088", title: "Работа с терминалом", cwd: project.roots[0], projectID: project.id)
    let research = CodexProject(id: "research-fixture", name: "Исследование", roots: ["/tmp/research-fixture"])
    let empty = CodexProject(id: "empty-fixture", name: "Пустой проект", roots: ["/tmp/empty-fixture"])
    let other = CodexTask(id: "7e7a1000-0000-4000-8000-000000000089", title: "Другой разговор", cwd: research.roots[0], projectID: research.id)
    let mac = NotebookStore(root: directory.appendingPathComponent("terminal-peer"))
    _ = try mac.initializeWorkspace(actor: peer, pageSize: .init(width: 834, height: 1194))
    let messages = [CodexMessage(id: "answer", turnID: "turn", clientID: nil, role: .assistant,
      text: "Терминал открыт под разговором. Команды вводятся прямо в его строку.")]
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: persistence, author: author) { envelope, destination in
      guard destination == peer, case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      do {
        switch query {
      case .models: reply = .models([])
        case .projects: reply = .projects(.init(projects: [project, research, empty], nextCursor: nil))
        case .catalogue(_, let selected): reply = .catalogue(.init(tasks: [task, other].filter { selected == nil || $0.projectID == selected?.id }, nextCursor: nil))
        case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .idle) })
        case .history: reply = .history(.init(messages: messages, nextCursor: nil))
        case .conversation(let id):
          reply = .conversation(.init(threadID: id, revision: 1, title: id == task.id ? task.title : other.title, ready: true, busy: false,
            activeTurnID: nil, messages: messages, requests: [], acceptedMessages: [:], turnStatuses: [:]))
        case .run(let read): reply = .run(try mac.readRun(read))
        case .resizeRun: reply = .acknowledged
        case .job(let input):
          var job = try mac.saveChatInput(input)
          if job.state == .saved {
            _ = try mac.advanceChatJob(input.id, from: .saved, to: .attempting)
            let result: NotebookChatResult
            switch input.action {
            case .startRun(let request):
              if let previous = request.replacing { try mac.receiveRunEvent(previous, .exited(0)) }
              try mac.admitRun(.init(id: input.id, author: input.author, request: request))
              try mac.receiveRunEvent(input.id, .output(Data("SESSION:\(input.id.uuidString)\r\nNotebook % ".utf8)))
              result = .run(input.id)
            case .writeRun(let id, let bytes):
              try mac.receiveRunEvent(id, .output(bytes)); result = .acknowledged
            case .stopRun(let id): try mac.receiveRunEvent(id, .exited(0)); result = .acknowledged
            default: throw NotebookTransportError.invalidAcknowledgement
            }
            job = try mac.advanceChatJob(input.id, from: .attempting, to: .accepted, result: result)
          }
          reply = .job(job)
        default: reply = .failure("Outside terminal UI scenario")
        }
      } catch { reply = .failure(error.localizedDescription) }
      receiver?.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    receiver = chat
    await chat.start(); await chat.connect(peer)
    chat.selectProject(project); chat.select(task); chat.expanded = true
    return chat
  }
}
#endif
