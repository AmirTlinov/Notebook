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
  func createProject(name: String, path: String, idempotencyKey: UUID) async throws -> CodexProject
  func updateProject(_ edit: CodexProjectEdit) async throws -> CodexProject
  func projects(cursor: String?) async throws -> CodexProjectPage
  func history(threadID: String, cursor: String?) async throws -> CodexHistoryPage
  func create(directory: URL, title: String, workspaceID: UUID, project: CodexProject?, onCreated: @escaping @Sendable (CodexTask) async throws -> Void) async throws -> CodexTask
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
  private let dictation: MacNotebookDictation?
  private let runs: MacNotebookProjectRuns?
  private let files: MacNotebookProjectFiles
  private var worker: Task<Void, Never>?
  private var stopped = false
  private var publishEvents: Task<Void, Never>?
  private var pendingEvents: [String: CodexConversation] = [:]
  private var subscriptions: [UUID: (id: UUID, thread: String)] = [:]
  private var publish: ((NotebookChatEnvelope, UUID) -> Void)?
  var authorizePeer: (UUID) -> Bool = { _ in true }
  var prepareThread: ((String) async throws -> Void)?
  var accountIdentity: (() async throws -> String?)?
  var accountAdmission: (() -> UUID?)?
  private var peerGenerations: [UUID: UInt64] = [:]
  private struct Admission { let peer: UUID; let generation: UInt64; let account: UUID? }
  var accountRequest: ((CodexAccountQuery) async throws -> CodexAccountState)?
  private var executing: [String: Task<Void, Never>] = [:]
  private var reconciling: [UUID: Task<Void, Never>] = [:]
  private var revokedPeers: Set<UUID> = []
  private var requests: Set<UUID> = []
  private var historyCursors: [UUID: String] = [:]
  private var reconciliationAfter: [UUID: Date] = [:]

  convenience init(persistence: NotebookPersistenceQueue, server: CodexAppServer, workspaceID: UUID,
    computerID: UUID, directory: URL, publish: @escaping (NotebookChatEnvelope, UUID) -> Void) {
    self.init(persistence: persistence, bridge: server, metadata: server,
      workspaceID: workspaceID, computerID: computerID, directory: directory)
    self.publish = publish
  }

  func attachView(publish: @escaping (NotebookChatEnvelope, UUID) -> Void) { self.publish = publish }

  /// A workspace/window detaches its presentation, not accepted native work.
  func detachView() {
    publish = nil; subscriptions.removeAll(); pendingEvents.removeAll()
    publishEvents?.cancel(); publishEvents = nil
  }

  func receiveEvent(_ event: CodexBridgeEvent) {
    guard !stopped else { return }
    if case .unavailable(let error) = event {
      publishEvents?.cancel(); publishEvents = nil; pendingEvents.removeAll()
      for (peer, subscription) in subscriptions {
        publish?(.init(body: .unavailable(subscriptionID: subscription.id, threadID: subscription.thread, reason: Self.message(error))), peer)
      }
      return
    }
    guard case .conversation(let state) = event,
      subscriptions.values.contains(where: { $0.thread == state.threadID }) else { return }
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

  init(persistence: NotebookPersistenceQueue, bridge: any NotebookCodexConversationOwner,
    metadata: any NotebookCodexCatalogueOwner, workspaceID: UUID, computerID: UUID = UUID(), directory: URL) {
    files = .init(persistence: persistence)
    self.persistence = persistence; self.bridge = bridge; self.metadata = metadata
    self.workspaceID = workspaceID; self.computerID = computerID; self.directory = directory
    voice = (bridge as? any NotebookCodexVoiceOwner).map { .init(persistence: persistence, executor: $0) }
    dictation = (bridge as? any NotebookCodexDictationOwner).map { .init(executor: $0, computer: computerID) }
    runs = (bridge as? any NotebookCodexProcessOwner).map { .init(persistence: persistence, executor: $0, metadata: metadata, computer: computerID) }
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
          do {
            let jobs = try await persistence.submit { try $0.pendingChatJobs() }
            let pending = Set(jobs.map(\.id))
            reconciliationAfter = reconciliationAfter.filter { pending.contains($0.key) }
            historyCursors = historyCursors.filter { pending.contains($0.key) }
            // Explicit control of the current turn bypasses queued next-turn text.
            // Preserve journal order within each class and independent thread.
            let ordered = jobs.enumerated().sorted { left, right in
              func priority(_ job: NotebookChatJob) -> Int { if case .send = job.input.action { return 1 }; return 0 }
              let a = priority(left.element), b = priority(right.element)
              return a == b ? left.offset < right.offset : a < b
            }.map(\.element)
            for job in ordered where !Task.isCancelled {
              if job.input.action.isRunCommand || job.input.action.isVoiceCommand { continue }
              if job.state == .uncertain || job.state == .attempting {
                guard reconciling[job.id] == nil, reconciling.count < 2,
                  reconciliationAfter[job.id, default: .distantPast] <= Date() else { continue }
                reconciliationAfter[job.id] = Date().addingTimeInterval(15)
                reconciling[job.id] = Task { [weak self] in
                  guard let self else { return }
                  try? await reconcile(job)
                  reconciling.removeValue(forKey: job.id)
                }
                continue
              }
              let control = job.input.action.isInteractiveControl
              let key = (job.input.action.threadID ?? job.id.uuidString) + (control ? "/control" : "")
              guard executing[key] == nil, executing.count < (control ? 10 : 8) else { continue }
              executing[key] = Task { [weak self] in
                guard let self else { return }
                do { try await execute(job) } catch { /* The durable receipt remains authoritative. */ }
                if let thread = job.input.action.threadID, !subscriptions.values.contains(where: { $0.thread == thread }) {
                  await bridge.detach(threadID: thread)
                }
                executing.removeValue(forKey: key)
              }
            }
          } catch { /* A subsequent read exposes persistent storage failure. */ }
          try await Task.sleep(for: .seconds(1))
        }
      } catch { }
    }
  }

  func stop() async {
    dictation?.stop()
    stopped = true; files.stop(); worker?.cancel(); publishEvents?.cancel()
    subscriptions.removeAll(); pendingEvents.removeAll()
    // Do not cancel a native turn. An in-flight mutation retains its durable attempt.
    await worker?.value; worker = nil
    let tasks = Array(executing.values) + Array(reconciling.values)
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    executing.removeAll(); reconciling.removeAll()
  }

  func revokeDevice(_ peer: UUID) {
    revokedPeers.insert(peer); peerGenerations[peer, default: 0] += 1
    subscriptions.removeValue(forKey: peer)
    // Register this fence synchronously: earlier attempts keep their right to
    // finish, but a later admission cannot overtake revocation.
    persistence.enqueueCommand({ try $0.rejectSavedChatInputs(from: peer) }, completion: { _ in })
  }
  func allowDevice(_ peer: UUID) { revokedPeers.remove(peer); peerGenerations[peer, default: 0] += 1 }

  private func authorization(_ peer: UUID) throws -> Admission {
    guard !stopped, !revokedPeers.contains(peer), authorizePeer(peer) else { throw CodexBridgeError.unavailable }
    let account = accountAdmission?()
    guard accountAdmission == nil || account != nil else { throw CodexBridgeError.busy }
    return .init(peer: peer, generation: peerGenerations[peer, default: 0], account: account)
  }

  /// One admission cut for chat, processes and voice. Validation and enqueueing
  /// the durable attempt cannot interleave with MainActor revoke/account change.
  private func admit(_ input: NotebookChatInput, authorized: Admission, attempt: Bool) async throws -> NotebookChatJob {
    try await withCheckedThrowingContinuation { continuation in
      do {
        let current = try authorization(input.author)
        guard current.peer == authorized.peer, current.generation == authorized.generation,
          current.account == authorized.account else { throw CodexBridgeError.unavailable }
        let computer = computerID
        persistence.enqueueCommand({ store in
          let job = try store.saveChatSubmission(input, to: computer)
          guard attempt, job.state == .saved else { return job }
          return try store.advanceChatJob(input.id, from: .saved, to: .attempting)
        }, completion: { continuation.resume(with: $0) })
      } catch { continuation.resume(throwing: error) }
    }
  }
  private func admitAccount() async throws {
    let identity: String
    if let accountIdentity { identity = try await accountIdentity() ?? "signed-out" }
    else if let accountRequest { identity = try await accountRequest(.read).account?.identity ?? "signed-out" }
    else { return } // injected contract owner in native tests
    _ = try await persistence.submit { try $0.admitCodexAccount(identity) }
  }

  func receive(_ envelope: NotebookChatEnvelope, peerID: UUID) async -> NotebookChatEnvelope? {
    guard !stopped, !revokedPeers.contains(peerID), authorizePeer(peerID), envelope.isValid(from: peerID), case .request(let query) = envelope.body,
      requests.count < 8, requests.insert(envelope.id).inserted else { return nil }
    defer { requests.remove(envelope.id) }
    let reply: NotebookChatReply
    do {
      switch query {
      case .account(let query):
        guard let accountRequest else { throw CodexBridgeError.unavailable }
        reply = .account(try await accountRequest(query))
      case .requestDetails(let thread, let generation, let id):
        guard let state = await bridge.snapshot(threadID: thread), state.generation == generation,
          let request = state.requests.first(where: { $0.id == id }) else { throw CodexBridgeError.staleRequest }
        reply = .requestDetails(request)
      case .stopWaiting(let id):
        reply = .job(try await persistence.submit { try $0.stopWaitingForChatJob(id, author: peerID) })
      case .dictation(let query):
        guard let dictation else { throw CodexBridgeError.unavailable }
        reply = .dictation(try dictation.receive(query, peer: peerID))
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
        let admission = try authorization(peerID)
        let job: NotebookChatJob
        if let existing = try await persistence.submit({ try $0.chatJob(input.id) }) {
          guard existing.input == input else { throw CodexBridgeError.invalidInput }
          job = existing // Polling a receipt does not refresh or mutate the account.
        } else {
          try await admitAccount()
          job = try await admit(input, authorized: admission, attempt: false)
        }
        let begin: @MainActor () async throws -> NotebookChatJob = { [self] in
          try await admitAccount()
          return try await admit(input, authorized: admission, attempt: true)
        }
        if input.action.isVoiceCommand {
          guard let voice else { throw CodexBridgeError.unavailable }
          reply = .job(try await voice.receive(job, admit: begin))
        } else if input.action.isRunCommand {
          guard let runs else { throw CodexBridgeError.unavailable }
          reply = .job(try await runs.receive(job, admit: begin))
        } else { reply = .job(job) }
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
        try await observe(thread)
        guard let state = await bridge.snapshot(threadID: thread) else { throw CodexBridgeError.unavailable }
        let previous = subscriptions.updateValue((envelope.id, thread), forKey: peerID)
        if let previous, previous.thread != thread, executing[previous.thread] == nil,
          !subscriptions.values.contains(where: { $0.thread == previous.thread }) { await bridge.detach(threadID: previous.thread) }
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
    try await prepareThread?(thread)
    try await bridge.attach(threadID: thread)
  }

  private func execute(_ job: NotebookChatJob) async throws {
    guard !stopped else { return }
    guard job.state == .saved else { return }
    guard !revokedPeers.contains(job.input.author), authorizePeer(job.input.author) else {
      try await persistence.submit { try $0.rejectSavedChatInputs(from: job.input.author) }; return
    }
    let admission = try authorization(job.input.author)
    guard try await persistence.submit({ try $0.chatJob(job.id)?.state }) == .saved else { return }
    if case .renameFile(let request) = job.input.action {
      guard request.address.computer == computerID else { throw CodexBridgeError.invalidInput }
      let author = job.input.author
      guard try await persistence.submit({ try $0.peerCursor(peerID: author, direction: .incoming) >= UInt64(request.after)! }) else { return }
    }
    if let contextID = job.input.attentionContextID {
      guard try await persistence.submit({ try $0.hasAttentionEvidence(contextID: contextID) }) else { return }
    }
    guard let attachments = try await persistence.submit({ try $0.resolvedChatImageAttachments(job.input.attachments ?? []) }) else { return }
    do {
      if let thread = job.input.action.threadID {
        try await observe(thread)
        guard let snapshot = await bridge.snapshot(threadID: thread), snapshot.ready else { return }
        if case .send = job.input.action, snapshot.busy || !snapshot.requests.isEmpty { return }
      }
    } catch { return } // No native mutation attempted; saved really means queued.
    try await admitAccount()
    guard try await admit(job.input, authorized: admission, attempt: true).state == .attempting else { return }
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
      case .createProject(let name, let path): result = .project(try await metadata.createProject(name: name, path: path, idempotencyKey: job.id))
      case .updateProject(let edit): result = .project(try await metadata.updateProject(edit))
      case .create(let title, let selectedProject):
        let project: CodexProject?
        if let selectedProject { project = try await metadata.readProject(id: selectedProject.id) } else { project = nil }
        let target = project?.roots.first.map { URL(fileURLWithPath: $0) } ?? directory
        if project == nil { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
        result = .created(try await metadata.create(directory: target, title: title, workspaceID: workspaceID, project: project) { [persistence] task in
          try await persistence.submit { try $0.recordCreatedChatTask(job.id, task: task) }
        })
      case .send(let thread, let text, let context):
        result = .turn(try await bridge.send(threadID: thread, clientMessageID: job.id, text: text, context: context, attachments: attachments))
      case .steer(let thread, let turn, let text, let context):
        result = .turn(try await bridge.steer(threadID: thread, turnID: turn, clientMessageID: job.id, text: text, context: context, attachments: attachments))
      case .stop(let thread, let turn):
        try await bridge.interrupt(threadID: thread, turnID: turn); result = .acknowledged
      case .respond(let thread, let request, let decision):
        try await bridge.respond(threadID: thread, request: request, decision: decision); result = .acknowledged
      }
    } catch {
      // These local checks fail before native dispatch. A turn that finished on
      // the Mac is a definite stale Stop, not an indefinitely unknown acceptance.
      if case .create = job.input.action,
        let task = try await persistence.submit({ try $0.chatJob(job.id)?.createdTask }) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: .attempting, to: .accepted,
          result: .created(task), error: "Задача создана. Дополнительная настройка не завершена: " + Self.message(error)) }
        return
      }
      let code = error as? CodexBridgeError
      let fileRejected: Bool
      if case .saveFile = job.input.action { fileRejected = try await persistence.submit { try $0.fileCommit(job.id) == nil } }
      else if case .renameFile = job.input.action {
        let unprepared = try await persistence.submit { try $0.fileRename(job.id) == nil }
        fileRejected = error is MacNotebookProjectFiles.RenameRejected || unprepared
      } else { fileRejected = false }
      let rejected = error is CodexRequestRejection || fileRejected || code == .externalOwnerUnavailable || code == .staleTurn || code == .staleRequest || code == .unsupportedRequest || code == .invalidInput || code == .signInRequired
      // busy/unavailable are guaranteed pre-dispatch by send(). Other failures
      // remain uncertain, including success whose native reply was lost.
      let retryable: Bool
      if job.input.action.message != nil {
        retryable = code == .busy || code == .unavailable
      } else if case .respond = job.input.action { retryable = code == .busy }
      else { retryable = false }
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
    guard try await persistence.submit({ try $0.chatJob(job.id)?.state }) == job.state else { return }
    if let task = job.createdTask {
      _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted,
        result: .created(task), error: "Задача создана до обрыва. Дополнительная настройка не подтверждена; состояние проверяется при открытии.") }
      return
    }
    if case .createProject(let name, let path) = job.input.action {
      // Only this public API explicitly guarantees idempotent creation by key.
      let project = try await metadata.createProject(name: name, path: path, idempotencyKey: job.id)
      _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .project(project)) }
      return
    }
    if case .setModel(let thread, let selection) = job.input.action {
      try await observe(thread)
      if await bridge.snapshot(threadID: thread)?.model == selection {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .acknowledged) }
      }
      return // Never repeat a settings write after an unknown response.
    }
    if case .setAccess(let thread, let mode) = job.input.action {
      try await observe(thread)
      if await bridge.snapshot(threadID: thread)?.access?.mode == mode {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .acknowledged) }
      }
      return
    }
    if case .renameFile(let request) = job.input.action {
      guard request.address.computer == computerID else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(5)
      let project = try await metadata.readProject(id: request.address.project)
      if let result = try await files.reconcileRename(job.id, project: project) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .renamed(result)) }
      }
      return
    }
    if case .saveFile(let address) = job.input.action {
      guard address.computer == computerID else { return }
      reconciliationAfter[job.id] = Date().addingTimeInterval(5)
      let project = try await metadata.readProject(id: address.project)
      if let result = try await files.reconcile(job.id, project: project) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .file(result)) }
      }
      return
    }
    if case .updateProject(let edit) = job.input.action {
      let project = try await metadata.readProject(id: edit.id)
      if edit.matches(project) {
        _ = try await persistence.submit { try $0.advanceChatJob(job.id, from: job.state, to: .accepted, result: .project(project)) }
        reconciliationAfter.removeValue(forKey: job.id)
      }
      return // Observation can confirm the requested state; it never repeats an edit over newer work.
    }
    guard let (thread, _, _) = job.input.action.message else { return }
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
    // One complete question is immediately actionable; the remaining native
    // IDs are addressable without packing all permissions into one envelope.
    var budget = 72 * 1024
    while true {
      let messages = CodexMessage.transportPage(Array(state.messages.suffix(32)), byteBudget: budget)
      let ids = Set(messages.compactMap(\.clientID)), turns = Set(messages.map(\.turnID))
      let value = CodexConversation(threadID: state.threadID, generation: state.generation, revision: state.revision, title: state.title,
        ready: state.ready, busy: state.busy, activeTurnID: state.activeTurnID, messages: messages,
        requests: Array(state.requests.prefix(1)), requestIDs: state.requests.map(\.id),
        acceptedMessages: state.acceptedMessages.filter { ids.contains($0.key) },
        turnStatuses: state.turnStatuses.filter { turns.contains($0.key) || $0.key == state.activeTurnID },
        access: state.access, model: state.model, contextUsage: state.contextUsage)
      // Count encoded bytes (escaping included), reserving envelope overhead.
      if ((try? JSONEncoder().encode(value).count) ?? Int.max) <= 180 * 1024 || budget <= 2048 { return value }
      budget /= 2
    }
  }

  nonisolated static func message(_ error: Error) -> String {
    if let startup = error as? CodexStartupFailure {
      let status = startup.exitCode.map { "; код выхода \($0)" } ?? ""
      return "Codex не завершил запуск (\(startup.stage)\(status)). Проверьте Codex на Mac."
    }
    guard let bridge = error as? CodexBridgeError else { return String(error.localizedDescription.prefix(2048)) }
    switch bridge {
    case .signInRequired: return "Войдите в Codex через настройки аккаунта Notebook."
    case .notInstalled: return "Официальный runtime Codex отсутствует. Переустановите актуальный Notebook на Mac."
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
