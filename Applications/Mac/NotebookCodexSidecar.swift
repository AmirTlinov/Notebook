import Foundation
import NotebookCore
import NotebookCodex

protocol NotebookCodexConversationOwner: Sendable {
  func attach(threadID: String) async throws
  func detach(threadID: String) async
  func snapshot(threadID: String) async -> CodexConversation?
  func send(threadID: String, clientMessageID: UUID, text: String, context: String?) async throws -> String
  func interrupt(threadID: String, turnID: String) async throws
  func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) async throws
  func close() async
}
protocol NotebookCodexCatalogueOwner: Sendable {
  func tasks(cursor: String?) async throws -> CodexTaskPage
  func history(threadID: String, cursor: String?) async throws -> CodexHistoryPage
  func create(directory: URL, title: String, workspaceID: UUID) async throws -> CodexTask
}
extension CodexDesktopBridge: NotebookCodexConversationOwner { }
extension CodexMetadata: NotebookCodexCatalogueOwner { }

/// One native desktop follower and the existing ordered SQLite writer. No model
/// process, account, inference settings or approval policy belongs to Notebook.
@MainActor
final class NotebookCodexSidecar {
  private let persistence: NotebookPersistenceQueue
  private let bridge: any NotebookCodexConversationOwner
  private let metadata: any NotebookCodexCatalogueOwner
  private let workspaceID: UUID
  private let directory: URL
  private var worker: Task<Void, Never>?
  private var observing: String?
  private var stopped = false
  private var working = false
  private var requests: Set<UUID> = []
  private var historyCursors: [UUID: String] = [:]
  private var reconciliationAfter: [UUID: Date] = [:]

  init(persistence: NotebookPersistenceQueue, installation: CodexDesktopInstallation, workspaceID: UUID, directory: URL) {
    self.persistence = persistence; self.workspaceID = workspaceID; self.directory = directory
    bridge = CodexDesktopBridge(installation: installation)
    metadata = CodexMetadata(installation: installation)
  }

  init(persistence: NotebookPersistenceQueue, bridge: any NotebookCodexConversationOwner,
    metadata: any NotebookCodexCatalogueOwner, workspaceID: UUID, directory: URL) {
    self.persistence = persistence; self.bridge = bridge; self.metadata = metadata
    self.workspaceID = workspaceID; self.directory = directory
  }

  func start() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      // Crash recovery never changes attempting back to saved.
      do {
        _ = try await persistence.submit { store in
          for job in try store.pendingChatJobs() where job.state == .attempting {
            _ = try store.advanceChatJob(job.id, from: .attempting, to: .uncertain, error: "Проверяется принятие после перезапуска Mac")
          }
        }
        while !Task.isCancelled {
          if !working {
            working = true
            do {
              let jobs = try await persistence.submit { try $0.pendingChatJobs() }
              var waitingThreads = Set<String>()
              for job in jobs where !Task.isCancelled {
                if case .send(let thread, _, _) = job.input.action, waitingThreads.contains(thread) { continue }
                try await execute(job)
                if case .send(let thread, _, _) = job.input.action,
                  try await persistence.submit({ try $0.chatJob(job.id)?.isTerminal }) != true {
                  waitingThreads.insert(thread)
                }
              }
            } catch { /* The durable queue remains intact; a query reports its state. */ }
            working = false
          }
          try await Task.sleep(for: .seconds(1))
        }
      } catch { }
    }
  }

  func stop() async {
    stopped = true; worker?.cancel()
    // Do not cancel a native turn. An in-flight mutation retains its durable attempt.
    await bridge.close()
    await worker?.value; worker = nil
  }

  func receive(_ envelope: NotebookChatEnvelope, peerID: UUID) async -> NotebookChatEnvelope? {
    guard !stopped, envelope.isValid(from: peerID), case .request(let query) = envelope.body,
      requests.count < 8, requests.insert(envelope.id).inserted else { return nil }
    defer { requests.remove(envelope.id) }
    let reply: NotebookChatReply
    do {
      switch query {
      case .job(let input):
        reply = .job(try await persistence.submit { try $0.saveChatInput(input) })
      case .catalogue(let cursor): reply = .catalogue(try await metadata.tasks(cursor: cursor))
      case .history(let thread, let cursor): reply = .history(try await metadata.history(threadID: thread, cursor: cursor))
      case .conversation(let thread):
        // Queue execution and a view change may not detach one another mid-send.
        guard !working else { throw CodexBridgeError.busy }
        working = true; defer { working = false }
        try await observe(thread)
        guard let state = await bridge.snapshot(threadID: thread) else { throw CodexBridgeError.unavailable }
        let messages = state.messages.suffix(6).map { message in
          CodexMessage(id: message.id, turnID: message.turnID, clientID: message.clientID, role: message.role,
            text: String(message.text.prefix(4000)), isTruncated: message.isTruncated || message.text.count > 4000)
        }
        let ids = Set(messages.compactMap(\.clientID)), turns = Set(messages.map(\.turnID))
        reply = .conversation(.init(threadID: state.threadID, revision: state.revision, title: state.title,
          ready: state.ready, busy: state.busy, activeTurnID: state.activeTurnID, messages: messages,
          requests: state.requests, acceptedMessages: state.acceptedMessages.filter { ids.contains($0.key) },
          turnStatuses: state.turnStatuses.filter { turns.contains($0.key) || $0.key == state.activeTurnID }))
      }
    } catch { reply = .failure(Self.message(error)) }
    let response = NotebookChatEnvelope(id: envelope.id, body: .reply(reply))
    guard response.isValid(from: peerID) else {
      return .init(id: envelope.id, body: .reply(.failure("Ответ превышает размер кадра. Откройте историю порциями в Codex.")))
    }
    return response
  }

  private func observe(_ thread: String) async throws {
    if let observing, observing != thread { await bridge.detach(threadID: observing) }
    observing = thread
    try await bridge.attach(threadID: thread)
  }

  private func execute(_ job: NotebookChatJob) async throws {
    guard !stopped else { return }
    if job.state == .uncertain || job.state == .attempting {
      try await reconcile(job); return
    }
    guard job.state == .saved else { return }
    if let contextID = job.input.attentionContextID {
      guard try await persistence.submit({ try $0.hasAttentionEvidence(contextID: contextID) }) else { return }
    }
    do {
      if let thread = job.input.action.threadID {
        try await observe(thread)
        guard let snapshot = await bridge.snapshot(threadID: thread), snapshot.ready else { return }
        if case .send = job.input.action, snapshot.busy || !snapshot.requests.isEmpty { return }
      }
    } catch { return } // No native mutation attempted; saved really means queued.
    guard !stopped else { return }
    _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: .saved, to: .attempting) }
    guard !stopped else { return }
    let result: NotebookChatResult
    do {
      switch job.input.action {
      case .create(let title):
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        result = .created(try await metadata.create(directory: directory, title: title, workspaceID: workspaceID))
      case .send(let thread, let text, let context):
        result = .turn(try await bridge.send(threadID: thread, clientMessageID: job.id, text: text, context: context))
      case .stop(let thread, let turn):
        try await bridge.interrupt(threadID: thread, turnID: turn); result = .acknowledged
      case .respond(let thread, let request, let decision):
        try await bridge.respond(threadID: thread, request: request, decision: decision); result = .acknowledged
      }
    } catch {
      // These local checks fail before native dispatch. A turn that finished on
      // the Mac is a definite stale Stop, not an indefinitely unknown acceptance.
      let code = error as? CodexBridgeError
      let rejected = code == .staleTurn || code == .staleRequest || code == .unsupportedRequest || code == .invalidInput
      // busy/unavailable are guaranteed pre-dispatch by send(). Other failures
      // remain uncertain, including success whose native reply was lost.
      let retryable: Bool
      if case .send = job.input.action {
        retryable = (error as? CodexBridgeError) == .busy || (error as? CodexBridgeError) == .unavailable
      } else { retryable = false }
      _ = try await persistence.submit {
        try $0.advanceChatJob(job.id, from: .attempting, to: rejected ? .rejected : (retryable ? .saved : .uncertain), error: Self.message(error))
      }
      return
    }
    // A post-commit storage failure is reconciled from the existing row next time,
    // never by executing this input again.
    _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: .attempting, to: .accepted, result: result) }
  }

  private func reconcile(_ job: NotebookChatJob) async throws {
    guard case .send(let thread, _, _) = job.input.action,
      reconciliationAfter[job.id, default: .distantPast] <= Date() else { return }
    reconciliationAfter[job.id] = Date().addingTimeInterval(15)
    do {
      let page = try await metadata.history(threadID: thread, cursor: historyCursors[job.id])
      if let message = page.messages.first(where: { $0.clientID == job.id.uuidString.lowercased() }) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .turn(message.turnID)) }
        historyCursors.removeValue(forKey: job.id); reconciliationAfter.removeValue(forKey: job.id)
      } else {
        historyCursors[job.id] = page.nextCursor
        // End of current history is not proof of non-acceptance. Remain uncertain.
      }
    } catch { }
  }

  nonisolated static func message(_ error: Error) -> String {
    guard let bridge = error as? CodexBridgeError else { return String(error.localizedDescription.prefix(2048)) }
    switch bridge {
    case .signInRequired: return "Войдите в Codex на Mac. Отдельного входа Notebook нет."
    case .notInstalled: return "Установите Codex на сопряжённом Mac."
    case .incompatibleVersion: return "Версия Codex несовместима с проверенным протоколом Notebook."
    case .busy: return "Задача занята; сообщение остаётся в очереди."
    case .acceptanceUnknown: return "Принятие сообщения проверяется. Повторно оно не отправляется."
    case .staleTurn: return "Этот ход уже завершён или сменился на Mac. Другой ход не остановлен."
    case .staleRequest: return "Этот запрос уже обработан или сменился в Codex. Решение не отправлено."
    case .unsupportedRequest: return "Этот запрос нужно обработать в Codex на Mac."
    default: return "Codex: \(bridge.rawValue)"
    }
  }
}
