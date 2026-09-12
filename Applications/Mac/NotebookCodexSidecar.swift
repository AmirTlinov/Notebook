import Foundation
import NotebookCore
import NotebookCodex

protocol NotebookCodexConversationOwner: Sendable {
  func activities(threadIDs: [String]) async throws -> [CodexTaskActivity]
  func attach(threadID: String) async throws
  func detach(threadID: String) async
  func snapshot(threadID: String) async -> CodexConversation?
  func send(threadID: String, clientMessageID: UUID, text: String, context: String?, attachments: [CodexInputAttachment]) async throws -> String
  func steer(threadID: String, turnID: String, clientMessageID: UUID, text: String, context: String?, attachments: [CodexInputAttachment]) async throws -> String
  func interrupt(threadID: String, turnID: String) async throws
  func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) async throws
  func setAccess(threadID: String, mode: CodexAccessMode) async throws
  func setModel(threadID: String, selection: CodexModelSelection) async throws
  func compact(threadID: String) async throws
  func close() async
}
protocol NotebookCodexCatalogueOwner: Sendable {
  func models() async throws -> [CodexModelOption]
  func resources(threadID: String, kind: CodexResourceKind, cursor: String?) async throws -> CodexResourcePage
  func tasks(cursor: String?, project: CodexProject?) async throws -> CodexTaskPage
  func readProject(id: String) async throws -> CodexProject
  func updateProject(_ edit: CodexProjectEdit) async throws -> CodexProject
  func projects(cursor: String?) async throws -> CodexProjectPage
  func history(threadID: String, cursor: String?) async throws -> CodexHistoryPage
  func create(directory: URL, title: String, workspaceID: UUID, project: CodexProject?) async throws -> CodexTask
}
extension CodexAppServer: NotebookCodexConversationOwner { }
extension CodexAppServer: NotebookCodexCatalogueOwner { }

/// One persistent Codex App Server connection and the existing ordered SQLite writer.
/// Codex owns execution, account, inference settings and approval policy.
@MainActor
final class NotebookCodexSidecar {
  private let persistence: NotebookPersistenceQueue
  private let bridge: any NotebookCodexConversationOwner
  private let metadata: any NotebookCodexCatalogueOwner
  private let computerID: UUID
  private let workspaceID: UUID
  private let directory: URL
  private let voice: MacNotebookVoice?
  private let runs: MacNotebookProjectRuns?
  private let files: MacNotebookProjectFiles
  private var worker: Task<Void, Never>?
  private var observing: String?
  private var stopped = false
  private var bridgeEvents: AsyncStream<CodexBridgeEvent>?
  private var eventWorker: Task<Void, Never>?
  private var publishEvents: Task<Void, Never>?
  private var pendingEvents: [String: CodexConversation] = [:]
  private var subscriptions: [UUID: (id: UUID, thread: String)] = [:]
  private var publish: ((NotebookChatEnvelope, UUID) -> Void)?
  private var working = false
  private var requests: Set<UUID> = []
  private var historyCursors: [UUID: String] = [:]
  private var reconciliationAfter: [UUID: Date] = [:]

  init(persistence: NotebookPersistenceQueue, installation: CodexDesktopInstallation, workspaceID: UUID, computerID: UUID, directory: URL, publish: @escaping (NotebookChatEnvelope, UUID) -> Void) {
    self.publish = publish
    files = .init(persistence: persistence)
    self.persistence = persistence; self.workspaceID = workspaceID; self.computerID = computerID; self.directory = directory
    let server = CodexAppServer(installation: installation)
    bridge = server; metadata = server; bridgeEvents = server.events
    voice = .init(persistence: persistence, executor: server)
    runs = .init(persistence: persistence, executor: server, metadata: server, computer: computerID)
  }

  init(persistence: NotebookPersistenceQueue, bridge: any NotebookCodexConversationOwner,
    metadata: any NotebookCodexCatalogueOwner, workspaceID: UUID, computerID: UUID = UUID(), directory: URL) {
    files = .init(persistence: persistence)
    self.persistence = persistence; self.bridge = bridge; self.metadata = metadata
    self.workspaceID = workspaceID; self.computerID = computerID; self.directory = directory
    voice = (bridge as? any NotebookCodexVoiceOwner).map { .init(persistence: persistence, executor: $0) }
    runs = (bridge as? any NotebookCodexProcessOwner).map { .init(persistence: persistence, executor: $0, metadata: metadata, computer: computerID) }
  }

  func start() {
    guard worker == nil else { return }
    if let bridgeEvents {
      eventWorker = Task { [weak self] in
        for await event in bridgeEvents {
          guard let self, !Task.isCancelled else { break }
          if case .conversation(let state) = event {
            pendingEvents[state.threadID] = state
            if publishEvents == nil {
              publishEvents = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                for (peer, subscription) in subscriptions {
                  if let state = pendingEvents[subscription.thread] {
                    let envelope = NotebookChatEnvelope(body: .event(subscriptionID: subscription.id, conversation: Self.transport(state)))
                    if envelope.isValid(from: peer) { publish?(envelope, peer) }
                  }
                }
                pendingEvents.removeAll(); publishEvents = nil
              }
            }
          }
        }
      }
    }
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
                if job.input.action.isRunCommand || job.input.action.isVoiceCommand { continue }
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
    stopped = true; files.stop(); worker?.cancel(); eventWorker?.cancel(); publishEvents?.cancel()
    subscriptions.removeAll(); pendingEvents.removeAll()
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
      case .voice(let id):
        guard let voice else { throw CodexBridgeError.unavailable }; reply = .voice(try await voice.state(id, peer: peerID))
      case .run(let query):
        guard let runs else { throw CodexBridgeError.unavailable }; reply = .run(try await runs.read(query))
      case .resizeRun(let id, let columns, let rows):
        guard let runs else { throw CodexBridgeError.unavailable }; try await runs.resize(id, columns: columns, rows: rows); reply = .acknowledged
      case .file(let query):
        if let address = query.address {
          guard address.computer == computerID else { throw CodexBridgeError.invalidInput }
          let project = try await metadata.readProject(id: address.project)
          switch query {
          case .directory(let address, let after): reply = .file(.directory(try await files.list(address, project: project, after: after)))
          case .read(let address, let version, let offset): reply = .file(.part(try await files.part(address, project: project, version: version, offset: offset)))
          case .upload: throw CodexBridgeError.invalidInput
          }
        } else if case .upload(let chunk) = query {
          reply = .file(.uploaded(try await persistence.submit { try $0.stageFileUpload(chunk, author: peerID) }))
        } else { throw CodexBridgeError.invalidInput }

      case .job(let input):
        if input.action.isVoiceCommand {
          guard let voice else { throw CodexBridgeError.unavailable }
          reply = .job(try await voice.receive(input))
        } else if input.action.isRunCommand {
          guard let runs else { throw CodexBridgeError.unavailable }
          reply = .job(try await runs.receive(input))
        } else { reply = .job(try await persistence.submit { try $0.saveChatInput(input) }) }
      case .catalogue(let cursor, let project): reply = .catalogue(try await metadata.tasks(cursor: cursor, project: project))
      case .models: reply = .models(try await metadata.models())
      case .resources(let thread, let kind, let cursor): reply = .resources(try await metadata.resources(threadID: thread, kind: kind, cursor: cursor))
      case .projects(let cursor): reply = .projects(try await metadata.projects(cursor: cursor))
      case .activity(let ids):
        if ids.isEmpty { subscriptions.removeValue(forKey: peerID) }
        reply = .activity(try await bridge.activities(threadIDs: ids))
      case .history(let thread, let cursor):
        let page = try await metadata.history(threadID: thread, cursor: cursor)
        reply = .history(.init(messages: CodexMessage.transportPage(page.messages), nextCursor: page.nextCursor))
      case .conversation(let thread):
        // Queue execution and a view change may not detach one another mid-send.
        guard !working else { throw CodexBridgeError.busy }
        working = true; defer { working = false }
        try await observe(thread)
        guard let state = await bridge.snapshot(threadID: thread) else { throw CodexBridgeError.unavailable }
        subscriptions[peerID] = (envelope.id, thread)
        reply = .conversation(Self.transport(state))
      }
    } catch {
      if error as? CodexBridgeError == .externalOwnerUnavailable, case .conversation(let thread) = query {
        reply = .conversationUnavailable(threadID: thread, reason: Self.message(error))
      } else { reply = .failure(Self.message(error)) }
    }
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
    if case .renameFile(let request) = job.input.action {
      guard request.address.computer == computerID else { throw CodexBridgeError.invalidInput }
      let author = job.input.author
      guard try await persistence.submit({ try $0.peerCursor(peerID: author, direction: .incoming) >= UInt64(request.after)! }) else { return }
    }
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
      case .setModel(let thread, let selection):
        try await bridge.setModel(threadID: thread, selection: selection); result = .acknowledged
      case .compact(let thread):
        try await bridge.compact(threadID: thread); result = .acknowledged
      case .setAccess(let thread, let mode):
        try await bridge.setAccess(threadID: thread, mode: mode); result = .acknowledged
      case .startRun, .writeRun, .stopRun, .startVoice, .stopVoice: throw CodexBridgeError.invalidInput
      case .renameFile(let request):
        guard request.address.computer == computerID else { throw CodexBridgeError.invalidInput }
        let project = try await metadata.readProject(id: request.address.project)
        result = .renamed(try await files.rename(job.id, request: request, project: project))
      case .saveFile(let address):
        guard address.computer == computerID else { throw CodexBridgeError.invalidInput }
        let project = try await metadata.readProject(id: address.project)
        result = .file(try await files.commit(job.id, author: job.input.author, address: address, project: project))
      case .updateProject(let edit): result = .project(try await metadata.updateProject(edit))
      case .create(let title, let selectedProject):
        let project: CodexProject?
        if let selectedProject { project = try await metadata.readProject(id: selectedProject.id) } else { project = nil }
        let target = project?.roots.first.map { URL(fileURLWithPath: $0) } ?? directory
        if project == nil { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
        result = .created(try await metadata.create(directory: target, title: title, workspaceID: workspaceID, project: project))
      case .send(let thread, let text, let context):
        result = .turn(try await bridge.send(threadID: thread, clientMessageID: job.id, text: text, context: context, attachments: job.input.attachments ?? []))
      case .steer(let thread, let turn, let text, let context):
        result = .turn(try await bridge.steer(threadID: thread, turnID: turn, clientMessageID: job.id, text: text, context: context, attachments: job.input.attachments ?? []))
      case .stop(let thread, let turn):
        try await bridge.interrupt(threadID: thread, turnID: turn); result = .acknowledged
      case .respond(let thread, let request, let decision):
        try await bridge.respond(threadID: thread, request: request, decision: decision); result = .acknowledged
      }
    } catch {
      // These local checks fail before native dispatch. A turn that finished on
      // the Mac is a definite stale Stop, not an indefinitely unknown acceptance.
      let code = error as? CodexBridgeError
      let fileRejected: Bool
      if case .saveFile = job.input.action { fileRejected = try await persistence.submit { try $0.fileCommit(job.id) == nil } }
      else if case .renameFile = job.input.action {
        let unprepared = try await persistence.submit { try $0.fileRename(job.id) == nil }
        fileRejected = error is MacNotebookProjectFiles.RenameRejected || unprepared
      } else { fileRejected = false }
      let accessRejected: Bool
      switch job.input.action {
      case .setAccess, .setModel, .compact: accessRejected = code == .requestRejected
      default: accessRejected = false
      }
      let rejected = accessRejected || fileRejected || code == .staleTurn || code == .staleRequest || code == .unsupportedRequest || code == .invalidInput || code == .signInRequired
      // busy/unavailable are guaranteed pre-dispatch by send(). Other failures
      // remain uncertain, including success whose native reply was lost.
      let retryable: Bool
      if job.input.action.message != nil {
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
    if case .setModel(let thread, let selection) = job.input.action {
      guard reconciliationAfter[job.id, default: .distantPast] <= Date() else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(15)
      try await observe(thread)
      if await bridge.snapshot(threadID: thread)?.model == selection {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .acknowledged) }
      }
      return // Never repeat a settings write after an unknown response.
    }
    if case .setAccess(let thread, let mode) = job.input.action {
      guard reconciliationAfter[job.id, default: .distantPast] <= Date() else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(15)
      try await observe(thread)
      if await bridge.snapshot(threadID: thread)?.access?.mode == mode {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .acknowledged) }
      }
      return
    }
    if case .renameFile(let request) = job.input.action {
      guard request.address.computer == computerID, reconciliationAfter[job.id, default: .distantPast] <= Date() else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(5)
      let project = try await metadata.readProject(id: request.address.project)
      if let result = try await files.reconcileRename(job.id, project: project) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .renamed(result)) }
      }
      return
    }
    if case .saveFile(let address) = job.input.action {
      guard address.computer == computerID, reconciliationAfter[job.id, default: .distantPast] <= Date() else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(5)
      let project = try await metadata.readProject(id: address.project)
      if let result = try await files.reconcile(job.id, project: project) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .file(result)) }
      }
      return
    }
    if case .updateProject(let edit) = job.input.action {
      guard reconciliationAfter[job.id, default: .distantPast] <= Date() else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(15)
      let project = try await metadata.readProject(id: edit.id)
      if edit.matches(project) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .project(project)) }
        reconciliationAfter.removeValue(forKey: job.id)
      }
      return // Observation can confirm the requested state; it never repeats an edit over newer work.
    }
    guard let (thread, _, _) = job.input.action.message,
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

  private static func transport(_ state: CodexConversation) -> CodexConversation {
    let messages = CodexMessage.transportPage(Array(state.messages.suffix(32)))
    let ids = Set(messages.compactMap(\.clientID)), turns = Set(messages.map(\.turnID))
    return .init(threadID: state.threadID, revision: state.revision, title: state.title,
      ready: state.ready, busy: state.busy, activeTurnID: state.activeTurnID, messages: messages,
      requests: state.requests, acceptedMessages: state.acceptedMessages.filter { ids.contains($0.key) },
      turnStatuses: state.turnStatuses.filter { turns.contains($0.key) || $0.key == state.activeTurnID }, access: state.access, model: state.model, contextUsage: state.contextUsage)
  }

  nonisolated static func message(_ error: Error) -> String {
    guard let bridge = error as? CodexBridgeError else { return String(error.localizedDescription.prefix(2048)) }
    switch bridge {
    case .requestRejected: return "Codex отклонил запрос. Проверьте доступные настройки этой задачи на Mac."
    case .signInRequired: return "Войдите в Codex на Mac. Отдельного входа Notebook нет."
    case .notInstalled: return "Установите Codex на сопряжённом Mac."
    case .incompatibleVersion: return "Версия Codex несовместима с проверенным протоколом Notebook."
    case .busy: return "Задача занята; сообщение остаётся в очереди."
    case .acceptanceUnknown: return "Принятие сообщения проверяется. Повторно оно не отправляется."
    case .staleTurn: return "Этот ход уже завершён или сменился на Mac. Другой ход не остановлен."
    case .staleRequest: return "Этот запрос уже обработан или сменился в Codex. Решение не отправлено."
    case .externalOwnerUnavailable: return "Эту задачу уже ведёт другой исполнитель Codex. Историю можно читать; Notebook не перехватывает задачу."
    case .unsupportedRequest: return "Этот запрос нужно обработать в Codex на Mac."
    default: return "Codex: \(bridge.rawValue)"
    }
  }
}
