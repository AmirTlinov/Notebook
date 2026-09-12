#if os(iOS)
import Foundation
import Observation
import NotebookCore

/// The panel owns only selection, draft and display. The sole outstanding query
/// can be replaced in the transient lane; mutations survive in SQLite by ID.
@MainActor @Observable
final class NotebookChatController {
  let files: NotebookFileController
  let runs: NotebookRunController
  var computerID: UUID? { peer }
  var expanded = false { didSet { if !expanded { stopDictation(); activities = [:]; conversationSubscription = nil; enqueue(.activity(threadIDs: [])) } else { nextConversation = .now } } }
  var browsesChats = false
  private(set) var projects: [CodexProject] = []
  private(set) var projectCursor: String?
  var selectedProject: CodexProject? { files.window.project }
  private(set) var activities: [String: CodexTaskActivity] = [:]
  var draft: String = "" { didSet {
    if !writesDictation && dictationStatus != nil { stopDictation() }
    persistPanel()
  } }
  enum DictationStatus { case preparing, listening, finishing }
  private(set) var dictationStatus: DictationStatus?
  private(set) var dictationError: String?
  var dictationLocale = "ru-RU"
  @ObservationIgnored private let dictationInput: any NotebookDictationInput
  @ObservationIgnored private var dictationTask: Task<Void, Never>?
  @ObservationIgnored private var dictationID: UUID?
  @ObservationIgnored private var dictationBase = ""
  @ObservationIgnored private var dictationWritten = ""
  @ObservationIgnored private var dictationThread: String?
  @ObservationIgnored private var writesDictation = false
  private(set) var threadID: String?
  private(set) var tasks: [CodexTask] = []
  private(set) var taskCursor: String?
  private(set) var defaultProviderNeedsSignIn = false
  private(set) var conversation: CodexConversation?
  private(set) var history: [CodexMessage] = []
  private(set) var historyCursor: String?
  private(set) var jobs: [NotebookChatJob] = []
  private(set) var connected = false
  private(set) var error: String?
  private(set) var saving = false
  private(set) var continuationUnavailable = false
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let author: UUID
  @ObservationIgnored private let send: (NotebookChatEnvelope, UUID) -> Void
  @ObservationIgnored private var peer: UUID?
  @ObservationIgnored private var loaded = false
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var pending: (NotebookChatEnvelope, CheckedContinuation<NotebookChatReply, Error>)?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var directQueries: [(NotebookChatQuery, CheckedContinuation<NotebookChatReply, Error>)] = []
  @ObservationIgnored private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var queries: [NotebookChatQuery] = []
  @ObservationIgnored private var deliveryIndex = 0
  @ObservationIgnored private var displayedCatalogueCursor: String?
  @ObservationIgnored private var conversationSubscription: UUID?
  @ObservationIgnored private var subscriptionRevision: Int?
  @ObservationIgnored private var nextConversation = ContinuousClock.now
  @ObservationIgnored private var offeredJobs = Set<UUID>()
  @ObservationIgnored private var savingInput: NotebookChatInput?

  init(persistence: NotebookPersistenceQueue, author: UUID, dictationInput: any NotebookDictationInput = NotebookMicrophoneDictation(), send: @escaping (NotebookChatEnvelope, UUID) -> Void) {
    self.persistence = persistence; self.author = author; self.send = send; self.dictationInput = dictationInput
    files = NotebookFileController(persistence: persistence, author: author)
    runs = NotebookRunController(persistence: persistence)
    files.chat = self; runs.chat = self
  }

  func start() async {
    guard !loaded else { return }
    do {
      let author = author
      let state = try await persistence.submit { try $0.chatPanel(author: author) }
      threadID = state.threadID; draft = state.draft; peer = state.sidecarID
      try await refreshJobs()
      try await files.start()
      loaded = true
      ticker = Task { [wake] in
        while !Task.isCancelled { wake.continuation.yield(()); do { try await Task.sleep(for: .milliseconds(600)) } catch { break } }
      }
      loop = Task { [weak self] in
        guard let self else { return }
        var iterator = wake.stream.makeAsyncIterator()
        var deliverJobs = true
        var nextActivity = ContinuousClock.now, nextCatalogue = ContinuousClock.now
        while !Task.isCancelled, await iterator.next() != nil {
          if connected {
            if !directQueries.isEmpty, deliverJobs {
              let (query, completion) = directQueries.removeFirst()
              do {
                let reply = try await request(query)
                if case .failure(let message) = reply { throw NotebookPersistenceQueue.Failure(message: message) }
                completion.resume(returning: reply)
              } catch { completion.resume(throwing: error) }
              deliverJobs = false; wake.continuation.yield(()); continue
            }
            let query: NotebookChatQuery?
            let outgoing = jobs.reversed().filter { !$0.isTerminal }
            offeredJobs.formIntersection(outgoing.map(\.id))
            if !queries.isEmpty { query = queries.removeFirst() }
            else if !outgoing.isEmpty, deliverJobs || !expanded {
              // First admission follows the saved order even when earlier jobs
              // complete and disappear during delivery. Receipt polling is fair
              // only after every pending input has reached the Mac at least once.
              let next = outgoing.first { !offeredJobs.contains($0.id) } ?? outgoing[deliveryIndex % outgoing.count]
              query = .job(next.input); deliveryIndex &+= 1
            } else if expanded, .now >= nextActivity, !tasks.isEmpty {
              query = .activity(threadIDs: tasks.map(\.id)); nextActivity = .now + .seconds(2)
            } else if expanded, (threadID == nil || browsesChats), .now >= nextCatalogue {
              query = .catalogue(cursor: displayedCatalogueCursor, project: selectedProject); nextCatalogue = .now + .seconds(10)
            } else if expanded, !browsesChats, let threadID, .now >= nextConversation {
              query = .conversation(threadID: threadID); nextConversation = .now + .seconds(10)
            }
            else { query = outgoing.first.map { .job($0.input) } }
            if let query {
              do { try await accept(try await request(query), for: query) }
              catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
          }
          deliverJobs.toggle()
          if !directQueries.isEmpty { wake.continuation.yield(()) }
        }
      }
    } catch { self.error = error.localizedDescription }
  }

  func stop() async {
    await runs.stop()
    stopped = true; files.stop(); ticker?.cancel(); wake.continuation.finish()
    for (_, continuation) in directQueries { continuation.resume(throwing: NotebookTransportError.disconnected) }
    directQueries.removeAll()
    stopDictation(); await dictationTask?.value
    loop?.cancel(); retry?.cancel()
    pending?.1.resume(throwing: NotebookTransportError.disconnected); pending = nil
    await loop?.value; loop = nil
  }

  func connect(_ id: UUID) {
    guard peer == nil || peer == id else { return }
    if !connected { offeredJobs.removeAll(); conversationSubscription = nil; nextConversation = .now }
    peer = id; connected = true; persistPanel()
    if tasks.isEmpty { catalogue(); catalogueProjects() }
    if files.window.sidebar { Task { await files.roots() } }
  }
  func disconnect(_ id: UUID) {
    guard peer == id else { return }
    for (_, continuation) in directQueries { continuation.resume(throwing: NotebookTransportError.disconnected) }
    directQueries.removeAll()
    connected = false; activities = [:]; retry?.cancel(); conversationSubscription = nil
    pending?.1.resume(throwing: NotebookTransportError.disconnected); pending = nil
  }
  func receive(_ envelope: NotebookChatEnvelope, peerID: UUID) {
    guard connected, peer == peerID, envelope.isValid(from: peerID) else { return }
    if case .event(let subscription, let value) = envelope.body {
      guard subscription == conversationSubscription, value.threadID == threadID else { return }
      acceptConversation(value); return
    }
    guard pending?.0.id == envelope.id, case .reply(let reply) = envelope.body else { return }
    let completion = pending?.1; pending = nil; retry?.cancel(); retry = nil
    completion?.resume(returning: reply)
  }

  func catalogue(next: Bool = false) { enqueue(.catalogue(cursor: next ? taskCursor : nil, project: selectedProject)) }
  func catalogueProjects(next: Bool = false) { enqueue(.projects(cursor: next ? projectCursor : nil)) }
  func selectProject(_ project: CodexProject?) {
    stopDictation()
    files.chooseProject(project); tasks = []; activities = [:]; taskCursor = nil; displayedCatalogueCursor = nil
    browsesChats = true; catalogue()
  }
  func latestHistory() { guard let threadID else { return }; enqueue(.history(threadID: threadID, cursor: nil)) }
  func older() { guard let threadID else { return }; enqueue(.history(threadID: threadID, cursor: historyCursor)) }
  func select(_ task: CodexTask) {
    stopDictation()
    nextConversation = .now; conversationSubscription = nil
    threadID = task.id; continuationUnavailable = false; browsesChats = false; conversation = nil; history = []; historyCursor = nil
    persistPanel(); enqueue(.history(threadID: task.id, cursor: nil))
  }
  func projectUpdatePending(_ id: String) -> Bool {
    jobs.contains { job in
      if case .updateProject(let edit) = job.input.action { return edit.id == id && !job.isTerminal }
      return false
    }
  }
  var projectUpdateNotice: String? {
    guard let job = jobs.first(where: { job in if case .updateProject = job.input.action { return !job.isTerminal }; return false }) else { return nil }
    return job.state == .uncertain ? "Проверяю подтверждение настроек проекта в Codex…" : "Настройки проекта сохранены на iPad · ожидается Codex"
  }
  func updateProject(_ original: CodexProject, name: String, roots: [String]) async -> Bool {
    guard !projectUpdatePending(original.id) else { return false }
    let edit = CodexProjectEdit(id: original.id, name: name == original.name ? nil : name, roots: roots == original.roots ? nil : roots)
    guard edit.isValid else { return false }
    return await submit(.updateProject(edit))
  }
  func create() async { stopDictation(); _ = await submit(.create(title: "Занятие в Notebook", project: selectedProject)) }

  func startDictation() {
    guard loaded, !stopped, dictationTask == nil, !saving else { return }
    let id = UUID(); dictationID = id; dictationError = nil; dictationStatus = .preparing
    dictationBase = draft; dictationWritten = draft; dictationThread = threadID
    dictationTask = Task { [weak self, dictationInput, dictationLocale] in
      do {
        try await dictationInput.run(locale: dictationLocale) { [weak self] update in
          await self?.receiveDictation(update, id: id)
        }
      } catch is CancellationError { }
      catch { if let self, self.dictationID == id { self.dictationError = error.localizedDescription } }
      guard let self, self.dictationID == id else { return }
      self.dictationStatus = nil; self.dictationTask = nil; self.dictationID = nil
    }
  }
  func stopDictation() {
    guard dictationTask != nil else { return }
    if dictationStatus == .preparing { dictationTask?.cancel() }
    dictationStatus = .finishing
    Task { await dictationInput.finish() }
  }
  private func receiveDictation(_ update: NotebookDictationUpdate, id: UUID) {
    guard dictationID == id else { return }
    switch update {
    case .preparing: if dictationStatus != .finishing { dictationStatus = .preparing }
    case .listening: if dictationStatus != .finishing { dictationStatus = .listening }
    case .text(let text):
      guard threadID == dictationThread, draft == dictationWritten else { return }
      let separator = dictationBase.isEmpty || dictationBase.last?.isWhitespace == true || text.isEmpty ? "" : " "
      let next = dictationBase + separator + text
      guard next.utf8.count <= 32_768 else { dictationError = "Черновик достиг предела сообщения. Диктовка остановлена."; stopDictation(); return }
      writesDictation = true; draft = next; writesDictation = false; dictationWritten = next
    }
  }
  func sendMessage(threadID submittedThread: String, text: String, context: String, attentionContextID: UUID? = nil, steeringTurnID: String? = nil) async -> Bool {
    guard submittedThread != threadID || (!continuationUnavailable && !browsesChats && dictationStatus == nil) else { return false }
    let action: NotebookChatAction = steeringTurnID.map { .steer(threadID: submittedThread, turnID: $0, text: text, context: context) } ?? .send(threadID: submittedThread, text: text, context: context)
    if await submit(action, attentionContextID: attentionContextID) {
      if draft == text, threadID == submittedThread { draft = "" }; return true
    }
    return false
  }
  func stopTurn(threadID: String, turnID: String) async {
    _ = await submit(.stop(threadID: threadID, turnID: turnID))
  }
  func respond(_ request: CodexUserRequest, decision: CodexUserDecision, threadID: String) async {
    _ = await submit(.respond(threadID: threadID, request: request, decision: decision))
  }
  func decisionJob(_ request: CodexUserRequest, threadID: String) -> NotebookChatJob? {
    let id = NotebookChatAction.respond(threadID: threadID, request: request, decision: .decline).controlID(author: author)
    return jobs.first { $0.id == id }
  }

  /// Outgoing text remains visible after its editor is cleared. This is the
  /// durable outbox, not a second conversation: a native client ID replaces it.
  var pendingMessages: [NotebookChatJob] {
    jobs.reversed().filter { job in
      guard !job.isTerminal, let (thread, _, _) = job.input.action.message, thread == threadID else { return false }
      return conversation?.acceptedMessages[job.id.uuidString.lowercased()] == nil
    }
  }

  private func submit(_ action: NotebookChatAction, attentionContextID: UUID? = nil) async -> Bool {
    guard loaded, !stopped, !saving else { return false }
    saving = true; defer { saving = false }
    let controlID = action.controlID(author: author)
    if savingInput == nil, let controlID {
      do {
        if let previous = try await persistence.submit({ try $0.chatJob(controlID) }) {
          guard previous.input.action == action else {
            error = "Для этого запроса уже сохранено другое решение. Повторно оно не отправляется."; return false
          }
          try await refreshJobs(); return true
        }
      } catch { self.error = error.localizedDescription; return false }
    }
    if let savingInput, savingInput.action != action || savingInput.attentionContextID != attentionContextID {
      error = "Сначала завершите сохранение предыдущего сообщения."; return false
    }
    let input = savingInput ?? NotebookChatInput(id: controlID ?? UUID(), author: author, action: action, attentionContextID: attentionContextID)
    savingInput = input
    do {
      _ = try await persistence.submit { try $0.saveChatSubmission(input) }
      try await refreshJobs(); savingInput = nil; error = nil; return true
    } catch {
      // A lost local commit acknowledgement also keeps the same message ID.
      if let recovered = try? await persistence.submit({ try $0.chatJob(input.id) }), recovered.input == input {
        try? await refreshJobs(); savingInput = nil; self.error = nil; return true
      }
      self.error = error.localizedDescription; return false
    }
  }
  private func refreshJobs() async throws {
    let author = author
    jobs = try await persistence.submit { store in
      let recent = try store.recentChatJobs(author: author)
      let pending = try store.pendingChatJobs().filter { $0.input.author == author }
      // SQL admission order, not wall time: changing the iPad clock may not
      // reorder offline messages. Extra pending rows all precede the recent page.
      return recent + pending.filter { job in !recent.contains { $0.id == job.id } }.reversed()
    }
  }
  private func persistPanel() {
    guard loaded else { return }
    let state = NotebookChatPanelState(threadID: threadID, draft: draft, sidecarID: peer), author = author
    persistence.enqueueCommand(publishesChanges: false, { try $0.saveChatPanel(state, author: author) }) { [weak self] result in
      if case .failure(let failure) = result { Task { @MainActor [weak self] in self?.error = failure.localizedDescription } }
    }
  }
  func refreshFileJobs() async { try? await refreshJobs(); wake.continuation.yield(()) }
  func fileQuery(_ query: NotebookFileQuery) async throws -> NotebookFileReply {
    guard query.isValid, case .file(let reply) = try await directQuery(.file(query)) else { throw NotebookTransportError.invalidAcknowledgement }
    return reply
  }
  func directQuery(_ query: NotebookChatQuery) async throws -> NotebookChatReply {
    guard connected, !stopped, directQueries.count < 8 else { throw NotebookTransportError.disconnected }
    return try await withCheckedThrowingContinuation { continuation in
      directQueries.append((query, continuation)); wake.continuation.yield(())
    }
  }
  func runCommand(_ action: NotebookChatAction) async throws -> NotebookChatJob {
    guard loaded, !stopped, connected, action.isRunCommand else { throw NotebookTransportError.disconnected }
    let id = action.controlID(author: author) ?? UUID()
    let existing = try await persistence.submit { try $0.chatJob(id) }
    if let existing, existing.input.action != action { throw NotebookTransportError.invalidAcknowledgement }
    let input = existing?.input ?? NotebookChatInput(id: id, author: author, action: action)
    do { _ = try await persistence.submit { try $0.saveChatInput(input) } }
    catch {
      guard try await persistence.submit({ try $0.chatJob(input.id)?.input == input }) else { throw error }
    }
    try await refreshJobs()
    let query = NotebookChatQuery.job(input), reply = try await directQuery(query)
    try await accept(reply, for: query)
    guard case .job(let job) = reply else { throw NotebookTransportError.invalidAcknowledgement }
    return job
  }
  private func enqueue(_ query: NotebookChatQuery) {
    if !queries.contains(query), queries.count < 8 { queries.append(query); wake.continuation.yield(()) }
  }
  private func request(_ query: NotebookChatQuery) async throws -> NotebookChatReply {
    guard pending == nil, connected, let peer else { throw NotebookTransportError.disconnected }
    let envelope = NotebookChatEnvelope(body: .request(query))
    if case .conversation = query { conversationSubscription = envelope.id; subscriptionRevision = nil }
    return try await withCheckedThrowingContinuation { continuation in
      pending = (envelope, continuation)
      retry = Task { [weak self] in
        for _ in 0..<8 {
          guard !Task.isCancelled, let self, self.pending?.0.id == envelope.id else { return }
          self.send(envelope, peer)
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        guard let self, self.pending?.0.id == envelope.id else { return }
        self.pending = nil; continuation.resume(throwing: NotebookTransportError.disconnected)
      }
    }
  }
  private func acceptConversation(_ value: CodexConversation) {
    guard subscriptionRevision == nil || value.revision >= subscriptionRevision! else { return }
    subscriptionRevision = value.revision; conversation = value; continuationUnavailable = false; error = nil
  }

  private func accept(_ reply: NotebookChatReply, for query: NotebookChatQuery) async throws {
    switch (query, reply) {
    case (.job(let input), .job(let job)):
      guard input == job.input else { throw NotebookTransportError.invalidAcknowledgement }
      let received = try await persistence.submit { try $0.receiveChatReceipt(job) }
      offeredJobs.insert(input.id)
      files.receive(received)
      if case .created(let task) = received.result {
        // Bind once; later receipts cannot steal a deliberate task switch.
        if jobs.first(where: { $0.id == job.id })?.state != .accepted { select(task); catalogue() }
      }
      if case .project(let project) = received.result {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        if selectedProject?.id == project.id {
          files.chooseProject(project); taskCursor = nil; displayedCatalogueCursor = nil; catalogue()
        }
      }
      try await refreshJobs(); error = job.error
    case (.projects(let cursor), .projects(let page)):
      if cursor == nil { projects = page.projects }
      else { projects += page.projects.filter { candidate in !projects.contains { $0.id == candidate.id } } }
      projectCursor = page.nextCursor; error = nil
    case (.activity(let ids), .activity(let values)):
      guard values.count == ids.count, Set(values.map(\.id)) == Set(ids) else { throw NotebookTransportError.invalidAcknowledgement }
      if expanded, tasks.map(\.id) == ids { activities = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) }) }
    case (.catalogue(let cursor, let project), .catalogue(let page)):
      guard project == selectedProject else { return }
      displayedCatalogueCursor = cursor
      activities = activities.filter { entry in page.tasks.contains { $0.id == entry.key } }
      tasks = page.tasks; taskCursor = page.nextCursor; defaultProviderNeedsSignIn = page.defaultProviderNeedsSignIn; error = nil
    case (.conversation(let id), .conversation(let value)):
      guard value.threadID == id else { throw NotebookTransportError.invalidAcknowledgement }
      if threadID == id { acceptConversation(value) }
    case (.conversation(let id), .conversationUnavailable(let thread, let reason)):
      guard id == thread else { throw NotebookTransportError.invalidAcknowledgement }
      if threadID == id { continuationUnavailable = true; error = reason }
    case (.history(let id, _), .history(let page)):
      if threadID == id { history = page.messages; historyCursor = page.nextCursor; error = nil }
    case (_, .failure(let message)): error = message
    default: throw NotebookTransportError.invalidAcknowledgement
    }
  }
}
#endif
