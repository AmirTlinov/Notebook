#if os(iOS)
import Foundation
import Observation
import NotebookCore

/// The panel owns only selection, draft and display. The sole outstanding query
/// can be replaced in the transient lane; mutations survive in SQLite by ID.
@MainActor @Observable
final class NotebookChatController {
  var expanded = false
  var draft: String = "" { didSet { persistPanel() } }
  private(set) var threadID: String?
  private(set) var tasks: [CodexTask] = []
  private(set) var taskCursor: String?
  private(set) var conversation: CodexConversation?
  private(set) var history: [CodexMessage] = []
  private(set) var historyCursor: String?
  private(set) var jobs: [NotebookChatJob] = []
  private(set) var connected = false
  private(set) var error: String?
  private(set) var saving = false
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let author: UUID
  @ObservationIgnored private let send: (NotebookChatEnvelope, UUID) -> Void
  @ObservationIgnored private var peer: UUID?
  @ObservationIgnored private var loaded = false
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var pending: (NotebookChatEnvelope, CheckedContinuation<NotebookChatReply, Error>)?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var queries: [NotebookChatQuery] = []
  @ObservationIgnored private var deliveryIndex = 0
  @ObservationIgnored private var offeredJobs = Set<UUID>()
  @ObservationIgnored private var savingInput: NotebookChatInput?

  init(persistence: NotebookPersistenceQueue, author: UUID, send: @escaping (NotebookChatEnvelope, UUID) -> Void) {
    self.persistence = persistence; self.author = author; self.send = send
  }

  func start() async {
    guard !loaded else { return }
    do {
      let author = author
      let state = try await persistence.submit { try $0.chatPanel(author: author) }
      threadID = state.threadID; draft = state.draft; peer = state.sidecarID
      try await refreshJobs()
      loaded = true
      loop = Task { [weak self] in
        guard let self else { return }
        var pollConversation = true
        while !Task.isCancelled {
          if connected {
            let query: NotebookChatQuery?
            let outgoing = jobs.filter { !$0.isTerminal }.sorted { $0.input.createdAt < $1.input.createdAt }
            offeredJobs.formIntersection(outgoing.map(\.id))
            if !queries.isEmpty { query = queries.removeFirst() }
            else if !outgoing.isEmpty, !pollConversation || !expanded {
              // First admission follows the saved order even when earlier jobs
              // complete and disappear during delivery. Receipt polling is fair
              // only after every pending input has reached the Mac at least once.
              let next = outgoing.first { !offeredJobs.contains($0.id) } ?? outgoing[deliveryIndex % outgoing.count]
              query = .job(next.input); deliveryIndex &+= 1; pollConversation = true
            } else if expanded, let threadID { query = .conversation(threadID: threadID); pollConversation = false }
            else { query = outgoing.first.map { .job($0.input) } }
            if let query {
              do { try await accept(try await request(query), for: query) }
              catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
          }
          do { try await Task.sleep(for: .milliseconds(600)) } catch { break }
        }
      }
    } catch { self.error = error.localizedDescription }
  }

  func stop() async {
    loop?.cancel(); retry?.cancel()
    pending?.1.resume(throwing: NotebookTransportError.disconnected); pending = nil
    await loop?.value; loop = nil
  }

  func connect(_ id: UUID) {
    guard peer == nil || peer == id else { return }
    if !connected { offeredJobs.removeAll() }
    peer = id; connected = true; persistPanel()
    if tasks.isEmpty { catalogue() }
  }
  func disconnect(_ id: UUID) {
    guard peer == id else { return }
    connected = false; retry?.cancel()
    pending?.1.resume(throwing: NotebookTransportError.disconnected); pending = nil
  }
  func receive(_ envelope: NotebookChatEnvelope, peerID: UUID) {
    guard connected, peer == peerID, pending?.0.id == envelope.id, case .reply(let reply) = envelope.body else { return }
    let completion = pending?.1; pending = nil; retry?.cancel(); retry = nil
    completion?.resume(returning: reply)
  }

  func catalogue(next: Bool = false) { enqueue(.catalogue(cursor: next ? taskCursor : nil)) }
  func older() { guard let threadID else { return }; enqueue(.history(threadID: threadID, cursor: historyCursor)) }
  func select(_ task: CodexTask) {
    threadID = task.id; conversation = nil; history = []; historyCursor = nil
    persistPanel(); enqueue(.history(threadID: task.id, cursor: nil))
  }
  func create() async { _ = await submit(.create(title: "Занятие в Notebook")) }
  func sendMessage(threadID submittedThread: String, text: String, context: String, attentionContextID: UUID? = nil) async -> Bool {
    if await submit(.send(threadID: submittedThread, text: text, context: context), attentionContextID: attentionContextID) {
      if draft == text, threadID == submittedThread { draft = "" }; return true
    }
    return false
  }
  func stopTurn() async {
    guard let threadID, let turn = conversation?.activeTurnID else { return }
    _ = await submit(.stop(threadID: threadID, turnID: turn))
  }
  func respond(_ request: CodexUserRequest, decision: CodexUserDecision) async {
    guard let threadID else { return }
    _ = await submit(.respond(threadID: threadID, request: request, decision: decision))
  }

  private func submit(_ action: NotebookChatAction, attentionContextID: UUID? = nil) async -> Bool {
    guard loaded, !saving else { return false }
    saving = true; defer { saving = false }
    if let savingInput, savingInput.action != action || savingInput.attentionContextID != attentionContextID {
      error = "Сначала завершите сохранение предыдущего сообщения."; return false
    }
    let input = savingInput ?? NotebookChatInput(author: author, action: action, attentionContextID: attentionContextID)
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
      return (recent + pending.filter { job in !recent.contains { $0.id == job.id } }).sorted { $0.input.createdAt > $1.input.createdAt }
    }
  }
  private func persistPanel() {
    guard loaded else { return }
    let state = NotebookChatPanelState(threadID: threadID, draft: draft, sidecarID: peer), author = author
    persistence.enqueueCommand(publishesChanges: false, { try $0.saveChatPanel(state, author: author) }) { [weak self] result in
      if case .failure(let failure) = result { Task { @MainActor [weak self] in self?.error = failure.localizedDescription } }
    }
  }
  private func enqueue(_ query: NotebookChatQuery) {
    if !queries.contains(query), queries.count < 8 { queries.append(query) }
  }
  private func request(_ query: NotebookChatQuery) async throws -> NotebookChatReply {
    guard pending == nil, connected, let peer else { throw NotebookTransportError.disconnected }
    let envelope = NotebookChatEnvelope(body: .request(query))
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
  private func accept(_ reply: NotebookChatReply, for query: NotebookChatQuery) async throws {
    switch (query, reply) {
    case (.job(let input), .job(let job)):
      guard input == job.input else { throw NotebookTransportError.invalidAcknowledgement }
      let received = try await persistence.submit { try $0.receiveChatReceipt(job) }
      offeredJobs.insert(input.id)
      if case .created(let task) = received.result {
        // Bind once; later receipts cannot steal a deliberate task switch.
        if jobs.first(where: { $0.id == job.id })?.state != .accepted { select(task); catalogue() }
      }
      try await refreshJobs(); error = job.error
    case (.catalogue, .catalogue(let page)):
      tasks = page.tasks; taskCursor = page.nextCursor; error = nil
    case (.conversation(let id), .conversation(let value)):
      guard value.threadID == id else { throw NotebookTransportError.invalidAcknowledgement }
      if threadID == id { conversation = value; error = nil }
    case (.history(let id, _), .history(let page)):
      if threadID == id { history = page.messages; historyCursor = page.nextCursor; error = nil }
    case (_, .failure(let message)): error = message
    default: throw NotebookTransportError.invalidAcknowledgement
    }
  }
}
#endif
