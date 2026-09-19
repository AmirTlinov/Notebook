#if DEBUG && targetEnvironment(simulator)
import Foundation
import NotebookCore

/// A bounded remote transcript for actual scroll and stop gestures. The real
/// controller still admits stop through its SQLite outbox and native turn ID.
@MainActor enum SimulatorChatFixture {
  static func make(persistence: NotebookPersistenceQueue, author: UUID) async throws -> NotebookChatController? {
    let dictation = ProcessInfo.processInfo.arguments.contains("--notebook-dictation-fixture")
    let compact = dictation || ProcessInfo.processInfo.arguments.contains("--notebook-compact-chat-fixture")
    guard compact || ProcessInfo.processInfo.arguments.contains("--notebook-chat-sync-fixture") else { return nil }
    let peer = UUID(uuidString: "7E7A1000-0000-4000-8000-000000000099")!
    let turn = "7e7a1000-0000-4000-8000-000000000077"
    let task = CodexTask(id: "7e7a1000-0000-4000-8000-000000000088", title: "Непрерывный разговор", cwd: "/fixture", projectID: "fixture")
    var accountLogin: CodexAccountState.Login?
    let accountRevision = UUID()
    var running = !dictation, subscription: UUID?
    var recordingID = UUID(), receivedAudio = 0
    var deliveredReply = false, admissions = Set<UUID>(), submittedMessages: [CodexMessage] = []
    var selection = CodexModelSelection(model: "fixture-a", effort: "low"), revision = 1
    let earlier = (0..<10).map { CodexMessage(id: "old-\($0)", turnID: "old", clientID: nil, role: .assistant,
      text: "Ранний ответ \($0).\n\nМатериал остаётся в этой же переписке при прокрутке вверх.") }
    let recent = (10..<20).map { CodexMessage(id: "recent-\($0)", turnID: turn, clientID: nil, role: .assistant,
      text: "Ответ \($0).\n\nПродолжение разговора с агентом.") }
    let user = CodexMessage(id: "user-file", turnID: turn, clientID: nil, role: .user,
      text: "Добавь диктовку рядом с разговором.", attachments: ["code_image.png"])
    let fullReply = (1...16).map { "Объяснение формулы, часть \($0). Материал остаётся в этой же переписке." }.joined(separator: "\n\n")
    func conversation() -> CodexConversation {
      .init(threadID: task.id, revision: revision, title: task.title, ready: true, busy: running,
        activeTurnID: running ? turn : nil, messages: recent + [user] + (deliveredReply ? [.init(id: "compact-reply", turnID: turn, clientID: nil, role: .assistant, text: fullReply, phase: "final_answer")] : running ? [] : [.init(id: "stopped", turnID: turn, clientID: nil, role: .assistant, text: "Ответ остановлен.")]) + submittedMessages,
        requests: [], acceptedMessages: [:], turnStatuses: [turn: running ? "inProgress" : deliveredReply ? "completed" : "interrupted"], model: selection, contextUsage: .init(used: 193000, window: 258000))
    }
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: persistence, author: author,
      dictationCapture: SimulatorDictationCapture(), preferences: UserDefaults(suiteName: "simulator-dictation-" + UUID().uuidString)!) { envelope, destination in
      guard destination == peer, case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .account(let action):
        switch action {
        case .beginLogin: accountLogin = .init(id: UUID().uuidString, verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: "TEST-183")
        case .cancelLogin: accountLogin = nil
        default: break
        }
        reply = .account(.init(revision: accountRevision, account: nil, requiresSignIn: true, login: accountLogin))
      case .dictation(let action):
        guard dictation else { reply = .failure("Outside dictation gesture scenario"); break }
        let state: NotebookDictationState
        switch action {
        case .prepare(let recording):
          if recordingID != recording.id { receivedAudio = 0 }; recordingID = recording.id
          state = .init(id: recordingID, receivedBytes: receivedAudio)
        case .append(_, let offset, let bytes):
          receivedAudio = offset + bytes.count; state = .init(id: recordingID, receivedBytes: receivedAudio)
        case .finish, .retry: state = .init(id: recordingID, phase: .transcribing, receivedBytes: receivedAudio)
        case .status: state = .init(id: recordingID, phase: .completed, receivedBytes: receivedAudio, text: "В Notebook работает диктовка Codex")
        case .cancel(let id): state = .init(id: id, phase: .cancelled)
        }
        reply = .dictation(state)
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
      case .conversation:
        if compact, receiver?.expanded == false, !deliveredReply { deliveredReply = true; running = false; revision += 1 }
        subscription = envelope.id; reply = .conversation(conversation())
      case .job(let input):
        if compact, case .send(let thread, let text, _) = input.action, thread == task.id {
          if admissions.insert(input.id).inserted {
            submittedMessages += [.init(id: input.id.uuidString, turnID: input.id.uuidString, clientID: input.id.uuidString, role: .user, text: text),
              .init(id: "receipt-" + input.id.uuidString, turnID: input.id.uuidString, clientID: nil, role: .assistant, text: "Принято поручений: \(admissions.count)", phase: "final_answer")]
            revision += 1
          }
          if let subscription { receiver?.receive(.init(body: .event(subscriptionID: subscription, conversation: conversation())), peerID: peer) }
          reply = .job(.init(input: input, state: .accepted, result: .turn(input.id.uuidString), revision: 2)); break
        }
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
    chat.dictation.authorizeAddress = { true }
    chat.dictation.addressAuthorized = { dictation }
    chat.dictation.makeAddressRecognizer = { _, _, activate, _ in SimulatorAddressRecognizer(activate: activate) }
    await chat.start(); await chat.connect(peer); chat.select(task); chat.expanded = !dictation
    return chat
  }
}

/// Synthetic device input and transcript, isolated to this Simulator fixture.
/// UI gestures still exercise the production capture lifecycle and send owner.
@MainActor private final class SimulatorDictationCapture: NotebookDictationCapture {
  private var pump: Task<Void, Never>?
  private var storage: NotebookDictationAudioStorage?
  private var events: (@MainActor (NotebookDictationAudioEvent) -> Void)?
  private var generation = UUID()
  private var recording = false
  private var addressedOnce = false
  func listen(pcm: @escaping @Sendable (Data, NotebookAcousticUtterance.Sample) async -> Void,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws {
    cancel(); self.events = events; run(pcm: pcm)
  }
  private func run(pcm: @escaping @Sendable (Data, NotebookAcousticUtterance.Sample) async -> Void) {
    let storage = NotebookDictationAudioStorage(); self.storage = storage
    let epoch = generation
    let addressed = ProcessInfo.processInfo.arguments.contains("--notebook-addressed-dictation-fixture") && !addressedOnce
    if addressed { addressedOnce = true }
    pump = Task { [weak self] in
      var frame = 0
      while !Task.isCancelled {
        guard let self, generation == epoch else { return }
        let time = Double(frame) / 24000
        let amplitude: Float = (addressed ? time >= 3 && time < 7 : recording) ? Float(0.025 + 0.015 * sin(time * 8)) : 0.0045
        let values = (0..<1200).map { amplitude * sin(Float($0) * 2 * .pi / 60) }
        let data = values.withUnsafeBytes { Data($0) }
        do {
          let update = try await storage.append(.init(data: data, frame: frame, rate: 24000)); frame += 1200
          guard generation == epoch else { return }
          events?(.reading(update.reading))
          if update.waiting { await pcm(data, update.reading.audio) }
          if let reason = update.end { await complete(reason); return }
          try await Task.sleep(for: .milliseconds(50))
        } catch { return }
      }
    }
  }
  func start(at url: URL, id: UUID, from frame: Int?, hasRequest: Bool?,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws {
    self.events = events
    if storage == nil { run(pcm: { _, _ in }) }
    try await storage?.begin(at: url, id: id, from: frame, hasRequest: hasRequest); recording = true
  }
  private func complete(_ reason: NotebookDictationEnd) async {
    guard let storage else { return }
    let completion = await storage.close(reason: reason)
    events?(.finished(completion))
  }
  func stop() { pump?.cancel(); Task { await complete(.stopped) } }
  func cancel() {
    generation = UUID(); pump?.cancel(); pump = nil; recording = false; events = nil
    if let storage { Task { _ = await storage.close() } }; storage = nil
  }
}
private actor SimulatorAddressRecognizer: NotebookAddressRecognition {
  let activate: @Sendable (NotebookWakeActivation) -> Void
  private var stopped = true
  init(activate: @escaping @Sendable (NotebookWakeActivation) -> Void) { self.activate = activate }
  func start() { stopped = false }
  func stop() { stopped = true }
  func append(data: Data, audio: NotebookAcousticUtterance.Sample) {
    guard !stopped, case .began(let start) = audio.boundary else { return }
    stopped = true; activate(.init(frame: start, hasRequest: true))
  }
}
#endif
