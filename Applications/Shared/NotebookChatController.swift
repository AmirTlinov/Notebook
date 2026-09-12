#if os(iOS)
import Foundation
import Observation
import NotebookCore

/// The panel owns only selection, draft and display. The sole outstanding query
/// can be replaced in the transient lane; mutations survive in SQLite by ID.
@MainActor @Observable
final class NotebookChatController {
  enum BrowserMode: String, CaseIterable { case chats = "Чаты", projects = "Проекты" }
  enum CatalogueScope: Hashable { case chats, project(String) }
  struct CatalogueWindow {
    var tasks: [CodexTask] = []
    var cursor: String?
    var pages = 1
    var loaded = false
    var loading = false
    var needsNext = false
    var error: String?
    var nextRead = ContinuousClock.now
  }
  let files: NotebookFileController
  let runs: NotebookRunController
  let voice: NotebookVoiceController
  var computerID: UUID? { peer }
  private(set) var computers: [NotebookTransportIdentity] = []
  private(set) var onlineComputers = Set<UUID>()
  private(set) var switchingComputer = false
  var expanded = false { didSet { if !expanded { suspendTranscript(); activities = [:]; conversationSubscription = nil; enqueue(.activity(threadIDs: [])) } else { synchronizeVisible() } } }
  var browsesChats = false { didSet { if browsesChats != oldValue { synchronizeVisible() } } }
  private(set) var browserMode = BrowserMode.chats
  private(set) var expandedProjects = Set<String>()
  private(set) var catalogues: [CatalogueScope: CatalogueWindow] = [:]
  private(set) var projects: [CodexProject] = []
  private(set) var projectCursor: String?
  var selectedProject: CodexProject? { files.window.project }
  private(set) var activities: [String: CodexTaskActivity] = [:]
  var draft: String = "" { didSet { persistPanel() } }
  private(set) var threadID: String?
  var tasks: [CodexTask] { catalogues[.chats]?.tasks ?? [] }
  private(set) var defaultProviderNeedsSignIn = false
  private(set) var conversation: CodexConversation?
  private(set) var messages: [CodexMessage] = []
  private(set) var historyCursor: String?
  private(set) var loadingHistory = false
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
  @ObservationIgnored private var directQueries: [(NotebookChatQuery, UUID, CheckedContinuation<NotebookChatReply, Error>)] = []
  @ObservationIgnored private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  @ObservationIgnored private var ticker: Task<Void, Never>?
  @ObservationIgnored private var queries: [NotebookChatQuery] = []
  @ObservationIgnored private var deliveryIndex = 0
  @ObservationIgnored private var activityOffset = 0
  @ObservationIgnored private var catalogueRead: Task<Void, Never>?
  @ObservationIgnored private var projectsRead: Task<Void, Never>?
  @ObservationIgnored private var catalogueGeneration = UUID()
  @ObservationIgnored private var projectPages = 1
  @ObservationIgnored private var nextProjectPage = false
  @ObservationIgnored private var selectedTask: CodexTask?
  @ObservationIgnored private var historyLoaded = false
  @ObservationIgnored private var historyBoundary: String?
  @ObservationIgnored private var transcriptGeneration = UUID()
  @ObservationIgnored private var catchUpBoundary: String?
  @ObservationIgnored private var catchUpRead: Task<Void, Never>?
  @ObservationIgnored private var nextCatchUp = ContinuousClock.now
  @ObservationIgnored private var nextProjects = ContinuousClock.now
  @ObservationIgnored private var conversationSubscription: UUID?
  @ObservationIgnored private var subscriptionRevision: Int?
  @ObservationIgnored private var nextConversation = ContinuousClock.now
  @ObservationIgnored private var offeredJobs = Set<UUID>()
  @ObservationIgnored private var savingInput: NotebookChatInput?

  init(persistence: NotebookPersistenceQueue, author: UUID, send: @escaping (NotebookChatEnvelope, UUID) -> Void) {
    self.persistence = persistence; self.author = author; self.send = send
    files = NotebookFileController(persistence: persistence, author: author)
    runs = NotebookRunController(persistence: persistence)
    voice = NotebookVoiceController()
    files.chat = self; runs.chat = self; voice.chat = self
  }

  func start() async {
    guard !loaded else { return }
    do {
      let author = author
      let state = try await persistence.submit { store in try store.prepareChatComputers(author: author); return try store.chatPanel(author: author) }
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
        var nextActivity = ContinuousClock.now
        while !Task.isCancelled, await iterator.next() != nil {
          if connected {
            synchronizeVisibleIfDue()
            if !directQueries.isEmpty, deliverJobs {
              let (query, computer, completion) = directQueries.removeFirst()
              do {
                guard peer == computer else { throw NotebookTransportError.disconnected }
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
            } else if expanded, .now >= nextActivity, !visibleTasks.isEmpty {
              let visible = visibleTasks
              let start = activityOffset % visible.count, ids = Array(visible.dropFirst(start).prefix(8).map(\.id))
              query = .activity(threadIDs: ids); activityOffset = start + ids.count; nextActivity = .now + .seconds(2)
            } else if expanded, !browsesChats, let threadID, .now >= nextConversation {
              query = .conversation(threadID: threadID); nextConversation = .now + .seconds(10)
            }
            else { query = outgoing.first.map { .job($0.input) } }
            if let query {
              let computer = peer
              defer { if case .history(let id, _) = query, id == threadID, !queries.contains(where: { if case .history(let thread, _) = $0 { return thread == id }; return false }) { loadingHistory = false } }
              do { try await accept(try await request(query), for: query, computer: computer) }
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
    await voice.end()
    await runs.stop()
    stopped = true; ticker?.cancel(); wake.continuation.finish()
    cancelQueries()
    loop?.cancel(); retry?.cancel()
    pending?.1.resume(throwing: NotebookTransportError.disconnected); pending = nil
    await files.stop()
    await loop?.value; loop = nil
  }

  func updateComputers(_ peers: [NotebookTransportIdentity]) {
    computers = peers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    onlineComputers.formIntersection(peers.map(\.deviceID))
    if let peer, !peers.contains(where: { $0.deviceID == peer }) { disconnect(peer) }
  }
  func connect(_ id: UUID) async {
    onlineComputers.insert(id)
    if peer == nil { await chooseComputer(id, firstConnection: true); return }
    guard peer == id else { return }
    if !connected { offeredJobs.removeAll(); conversationSubscription = nil; nextConversation = .now }
    connected = true
    catalogue(); catalogueProjects()
    if !historyLoaded { loadEarlier() }
    catchUpTranscript()
    if files.window.sidebar { Task { await files.roots() } }
  }
  func disconnect(_ id: UUID) {
    onlineComputers.remove(id)
    guard peer == id else { return }
    suspendTranscript(); connected = false; voice.connectionLost(); activities = [:]; conversationSubscription = nil
    cancelQueries()
  }
  private func cancelQueries() {
    catalogueGeneration = UUID(); catalogueRead?.cancel(); projectsRead?.cancel()
    catalogueRead = nil; projectsRead = nil; loadingHistory = false
    for scope in catalogues.keys { catalogues[scope]?.loading = false }
    catchUpRead?.cancel(); catchUpRead = nil
    for (_, _, continuation) in directQueries { continuation.resume(throwing: NotebookTransportError.disconnected) }
    directQueries.removeAll(); queries.removeAll(); retry?.cancel()
    pending?.1.resume(throwing: NotebookTransportError.disconnected); pending = nil
  }
  func chooseComputer(_ id: UUID, firstConnection: Bool = false) async {
    guard loaded, !stopped, !switchingComputer, !saving, savingInput == nil, !files.notes.contactActive,
      firstConnection || computers.contains(where: { $0.deviceID == id }) else { return }
    if peer == id { return }
    switchingComputer = true; files.notes.acceptsNewContacts = false
    defer { switchingComputer = false; files.notes.acceptsNewContacts = true }
    await voice.end()
    connected = false; cancelQueries(); await files.suspendForComputerSwitch()
    do {
      let author = author
      let restored = try await persistence.submit { store in
        do { return try store.selectChatComputer(id, author: author) }
        catch {
          guard try store.activeChatComputer(author: author) == id else { throw error }
          return try store.chatComputerWindow(author: author, computer: id)
        }
      }
      runs.detach(); queries.removeAll()
      loaded = false; peer = id; threadID = restored.panel.threadID; draft = restored.panel.draft; loaded = true
      transcriptGeneration = UUID(); catchUpBoundary = nil
      conversation = nil; messages = []; historyCursor = nil; historyLoaded = false; historyBoundary = nil; projects = []; catalogues = [:]; activities = [:]
      projectCursor = nil; projectPages = 1; nextProjectPage = false; offeredJobs.removeAll(); selectedTask = nil; expandedProjects = []; browserMode = .chats
      conversationSubscription = nil; subscriptionRevision = nil; nextConversation = .now; continuationUnavailable = false
      browsesChats = threadID == nil
      jobs = restored.jobs
      await files.installWindow(restored.window, document: restored.document)
      connected = onlineComputers.contains(id); error = nil
      catalogueProjects(); catalogue(); wake.continuation.yield(())
    } catch { self.error = error.localizedDescription; connected = peer.map { onlineComputers.contains($0) } ?? false }
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

  /// Refresh only the loaded catalogue window. Publish a complete read so a
  /// recency change cannot drop the older rows the person is currently reading.
  func catalogue(next: Bool = false, project: CodexProject? = nil) {
    let scope = project.map { CatalogueScope.project($0.id) } ?? .chats
    if next, catalogues[scope]?.cursor != nil { catalogues[scope]?.needsNext = true }
    guard connected, !stopped, catalogueRead == nil, !next || catalogues[scope]?.cursor != nil else { return }
    let window = catalogues[scope] ?? CatalogueWindow(), generation = catalogueGeneration
    let next = window.needsNext, cursor = next ? window.cursor : nil
    catalogues[scope] = window; catalogues[scope]?.loading = true; catalogues[scope]?.needsNext = false
    catalogueRead = Task { [weak self] in
      guard let self else { return }
      defer {
        if catalogueGeneration == generation {
          catalogueRead = nil; catalogues[scope]?.loading = false
          catalogues[scope]?.nextRead = .now + .seconds(10)
          wake.continuation.yield(())
        }
      }
      do {
        var cursor = cursor, result: [CodexTask] = [], pages = 0, needsSignIn = false, seen = Set<String>()
        repeat {
          guard case .catalogue(let page) = try await directQuery(.catalogue(cursor: cursor, project: project)), page.nextCursor == nil || page.nextCursor != cursor else { throw NotebookTransportError.invalidAcknowledgement }
          guard !Task.isCancelled, catalogueGeneration == generation, catalogues[scope] != nil,
            project == nil || projects.first(where: { $0.id == project?.id })?.roots == project?.roots else { return }
          result += page.tasks.filter { task in !result.contains { $0.id == task.id } }
          cursor = page.nextCursor; pages += 1; needsSignIn = page.defaultProviderNeedsSignIn
          if let cursor, !seen.insert(cursor).inserted { throw NotebookTransportError.invalidAcknowledgement }
        } while cursor != nil && (result.isEmpty || (!next && pages < window.pages))
        if next {
          let known = Set(window.tasks.map(\.id))
          catalogues[scope]?.tasks = window.tasks + result.filter { !known.contains($0.id) }; catalogues[scope]?.pages = window.pages + pages
        } else { catalogues[scope]?.tasks = result; catalogues[scope]?.pages = pages }
        catalogues[scope]?.cursor = cursor; catalogues[scope]?.loaded = true; catalogues[scope]?.error = nil
        defaultProviderNeedsSignIn = needsSignIn; error = nil
        let known = Set(catalogues.values.flatMap { $0.tasks.map(\.id) })
        activities = activities.filter { known.contains($0.key) }
      } catch {
        if !Task.isCancelled, catalogueGeneration == generation { catalogues[scope]?.error = error.localizedDescription }
      }
    }
  }
  func catalogueProjects(next: Bool = false) {
    if next, projectCursor != nil { nextProjectPage = true }
    guard connected, !stopped, projectsRead == nil, !next || projectCursor != nil else { return }
    let next = nextProjectPage
    nextProjectPage = false
    let generation = catalogueGeneration, cursor = next ? projectCursor : nil
    projectsRead = Task { [weak self] in
      guard let self else { return }
      defer {
        if catalogueGeneration == generation {
          projectsRead = nil; nextProjects = .now + .seconds(15); wake.continuation.yield(())
        }
      }
      do {
        var cursor = cursor, result: [CodexProject] = [], pages = 0
        repeat {
          guard case .projects(let page) = try await directQuery(.projects(cursor: cursor)), page.nextCursor == nil || page.nextCursor != cursor else { throw NotebookTransportError.invalidAcknowledgement }
          guard !Task.isCancelled, catalogueGeneration == generation else { return }
          result += page.projects.filter { project in !result.contains { $0.id == project.id } }
          cursor = page.nextCursor; pages += 1
        } while !next && pages < projectPages && cursor != nil
        for project in result {
          if let previous = projects.first(where: { $0.id == project.id }), previous.roots != project.roots {
            catalogues.removeValue(forKey: .project(project.id))
          }
        }
        if next { projects += result.filter { project in !projects.contains { $0.id == project.id } }; projectPages += pages }
        else { projects = result; projectPages = pages }
        projectCursor = cursor; error = nil
        let retained = Set(projects.map(\.id))
        expandedProjects.formIntersection(retained)
        for scope in catalogues.keys {
          if case .project(let id) = scope, !retained.contains(id) { catalogues.removeValue(forKey: scope) }
        }
        if let selectedTask, selectedTask.id == threadID, let project = project(for: selectedTask) {
          files.chooseProject(project)
        } else if let selectedProject, let current = projects.first(where: { $0.id == selectedProject.id }), current != selectedProject {
          files.chooseProject(current)
        }
        if let selectedTask, selectedTask.projectID != nil, project(for: selectedTask) == nil, cursor != nil { nextProjectPage = true }
      } catch { if !Task.isCancelled, projects.isEmpty { self.error = error.localizedDescription } }
    }
  }
  func synchronizeVisible() {
    nextConversation = .now; nextProjects = .now
    for scope in catalogues.keys { catalogues[scope]?.nextRead = .now }
    synchronizeVisibleIfDue(); catchUpTranscript(); wake.continuation.yield(())
  }
  func synchronizeVisibleIfDue(now: ContinuousClock.Instant = .now) {
    guard expanded, connected, !stopped else { return }
    if nextProjectPage || now >= nextProjects { catalogueProjects() }
    if threadID == nil || browsesChats {
      if browserMode == .chats {
        let window = catalogues[.chats]
        if window == nil || window?.needsNext == true || now >= window!.nextRead { catalogue() }
      } else {
        for project in projects where expandedProjects.contains(project.id) {
          if let window = catalogues[.project(project.id)], !window.needsNext, now < window.nextRead { continue }
          catalogue(project: project); break
        }
      }
    }
    if !browsesChats, !historyLoaded { loadEarlier() }
    if now >= nextCatchUp { catchUpTranscript() }
  }
  func selectProject(_ project: CodexProject?) {
    selectedTask = nil; files.chooseProject(project)
    if let project { expandedProjects.insert(project.id); browse(.projects); catalogue(project: project) }
    else { browse(.chats) }
  }
  func browse(_ mode: BrowserMode) {
    browserMode = mode; browsesChats = true; synchronizeVisible()
  }
  func toggleProject(_ project: CodexProject) {
    if expandedProjects.remove(project.id) == nil { expandedProjects.insert(project.id); catalogue(project: project) }
  }
  func project(for task: CodexTask) -> CodexProject? {
    if let id = task.projectID { return projects.first { $0.id == id } ?? (selectedProject?.id == id ? selectedProject : nil) }
    // The native folder stream matches exact roots, never similarly prefixed paths.
    return projects.first { $0.roots.contains(task.cwd) } ?? (selectedProject?.roots.contains(task.cwd) == true ? selectedProject : nil)
  }
  var visibleTasks: [CodexTask] {
    guard threadID == nil || browsesChats else { return selectedTask.map { [$0] } ?? tasks.filter { $0.id == threadID } }
    guard browserMode == .projects else { return tasks }
    var seen = Set<String>()
    return projects.filter { expandedProjects.contains($0.id) }.flatMap { catalogues[.project($0.id)]?.tasks ?? [] }.filter { seen.insert($0.id).inserted }
  }
  var canLoadEarlier: Bool { !historyLoaded || historyCursor != nil }
  func loadEarlier() {
    guard !stopped, let threadID, !loadingHistory, canLoadEarlier else { return }
    loadingHistory = enqueue(.history(threadID: threadID, cursor: historyLoaded ? historyCursor : nil))
  }
  func select(_ task: CodexTask) {
    transcriptGeneration = UUID(); catchUpRead?.cancel(); catchUpRead = nil; catchUpBoundary = nil
    nextConversation = .now; conversationSubscription = nil
    selectedTask = task; files.chooseProject(project(for: task))
    threadID = task.id; continuationUnavailable = false; conversation = nil; messages = []; historyCursor = nil; historyLoaded = false; historyBoundary = nil; loadingHistory = false
    browsesChats = false; persistPanel(); loadEarlier()
    if task.projectID != nil, project(for: task) == nil { catalogueProjects() }
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
  func create() async {
    if await submit(.create(title: "Занятие в Notebook", project: selectedProject)) { browsesChats = true; catalogue() }
  }
  func setAccess(_ mode: CodexAccessMode, thread: String) async {
    guard threadID == thread, !browsesChats, connected, !continuationUnavailable, conversation?.access?.available.contains(mode) == true,
      !(latestAccessChange.map { $0.input.action == .setAccess(threadID: thread, mode: mode) && !$0.isTerminal } ?? false) else { return }
    _ = await submit(.setAccess(threadID: thread, mode: mode))
  }
  private var latestAccessChange: NotebookChatJob? {
    // routedChatJobs is ordered by durable admission, newest first.
    jobs.first { job in
      if case .setAccess(let thread, _) = job.input.action { return thread == threadID }
      return false
    }
  }
  var accessChangePending: Bool { latestAccessChange.map { !$0.isTerminal } ?? false }

  var pendingCreations: [NotebookChatJob] {
    jobs.filter { job in
      guard !job.isTerminal, case .create(_, let project) = job.input.action else { return false }
      return browserMode == .chats || selectedProject == nil || project?.id == selectedProject?.id
    }
  }

  func sendMessage(threadID submittedThread: String, text: String, context: String, attentionContextID: UUID? = nil, steeringTurnID: String? = nil) async -> Bool {
    guard submittedThread != threadID || (!continuationUnavailable && !browsesChats) else { return false }
    let computer = peer
    let action: NotebookChatAction = steeringTurnID.map { .steer(threadID: submittedThread, turnID: $0, text: text, context: context) } ?? .send(threadID: submittedThread, text: text, context: context)
    if await submit(action, attentionContextID: attentionContextID) {
      if peer == computer, draft == text, threadID == submittedThread { draft = "" }; return true
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
    guard loaded, !stopped, !saving, !switchingComputer else { return false }
    saving = true; defer { saving = false }
    let computer = peer
    let controlID = action.controlID(author: author)
    if savingInput == nil, let controlID {
      do {
        if let previous = try await persistence.submit({ try $0.chatJob(controlID) }) {
          let destination = try await persistence.submit { try $0.chatDestination(controlID) }
          guard destination == computer, previous.input.action == action else {
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
      _ = try await persistence.submit { try $0.saveChatSubmission(input, to: computer) }
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
    let author = author, computer = peer
    let values = try await persistence.submit { try $0.routedChatJobs(author: author, computer: computer) }
    guard peer == computer else { return }; jobs = values
  }
  private func persistPanel() {
    guard loaded else { return }
    let state = NotebookChatPanelState(threadID: threadID, draft: draft, sidecarID: peer), author = author
    persistence.enqueue(owner: .chatPanel(peer), publishesChanges: false) { try $0.saveChatPanel(state, author: author); return false }
  }
  func refreshFileJobs() async { try? await refreshJobs(); wake.continuation.yield(()) }
  func fileQuery(_ query: NotebookFileQuery) async throws -> NotebookFileReply {
    guard query.isValid, case .file(let reply) = try await directQuery(.file(query)) else { throw NotebookTransportError.invalidAcknowledgement }
    return reply
  }
  func directQuery(_ query: NotebookChatQuery) async throws -> NotebookChatReply {
    let endsVoice: Bool
    if case .job(let input) = query, case .stopVoice = input.action { endsVoice = true } else { endsVoice = false }
    guard connected, !stopped, (!switchingComputer || endsVoice), let computer = peer, directQueries.count < 8 else { throw NotebookTransportError.disconnected }
    return try await withCheckedThrowingContinuation { continuation in
      directQueries.append((query, computer, continuation)); wake.continuation.yield(())
    }
  }
  func sessionCommand(_ action: NotebookChatAction, id suppliedID: UUID? = nil, computer destination: UUID? = nil) async throws -> NotebookChatJob {
    guard loaded, !stopped, action.isRunCommand || action.isVoiceCommand else { throw NotebookTransportError.disconnected }
    guard let computer = destination ?? peer else { throw NotebookTransportError.disconnected }
    let id = action.controlID(author: author) ?? suppliedID ?? UUID()
    let existing = try await persistence.submit { try $0.chatJob(id) }
    if let existing, existing.input.action != action { throw NotebookTransportError.invalidAcknowledgement }
    let input = existing?.input ?? NotebookChatInput(id: id, author: author, action: action)
    do { _ = try await persistence.submit { try $0.saveChatInput(input, to: computer) } }
    catch {
      guard try await persistence.submit({ try $0.chatJob(input.id)?.input == input && $0.chatDestination(input.id) == computer }) else { throw error }
    }
    try await refreshJobs()
    if !connected || computer != peer { return try await persistence.submit { try $0.chatJob(input.id)! } }
    let query = NotebookChatQuery.job(input), reply = try await directQuery(query)
    try await accept(reply, for: query, computer: computer)
    guard case .job(let job) = reply else { throw NotebookTransportError.invalidAcknowledgement }
    return job
  }
  @discardableResult private func enqueue(_ query: NotebookChatQuery) -> Bool {
    if queries.contains(query) { return true }
    guard queries.count < 8 else { return false }
    queries.append(query); wake.continuation.yield(()); return true
  }
  private func request(_ query: NotebookChatQuery) async throws -> NotebookChatReply {
    guard pending == nil, connected, let peer else { throw NotebookTransportError.disconnected }
    let envelope = NotebookChatEnvelope(body: .request(query))
    if case .conversation = query { conversationSubscription = envelope.id; subscriptionRevision = nil }
    let reply: NotebookChatReply = try await withCheckedThrowingContinuation { continuation in
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
    guard self.peer == peer else { throw NotebookTransportError.disconnected }
    return reply
  }
  private func acceptConversation(_ value: CodexConversation) {
    guard subscriptionRevision == nil || value.revision >= subscriptionRevision! else { return }
    subscriptionRevision = value.revision; conversation = value; continuationUnavailable = false; error = nil
    mergeMessages(value.messages, preferIncoming: true)
  }

  private func suspendTranscript() {
    if catchUpBoundary == nil { catchUpBoundary = messages.last?.id }
    catchUpRead?.cancel(); catchUpRead = nil; nextCatchUp = .now
  }
  /// A reconnect can miss more than the 64-item live window. Fill that gap up
  /// to the last shown native ID without replacing the older reading window.
  private func catchUpTranscript() {
    guard expanded, connected, !stopped, !browsesChats, catchUpRead == nil, let threadID, let boundary = catchUpBoundary else { return }
    let generation = transcriptGeneration
    catchUpRead = Task { [weak self] in
      guard let self else { return }
      defer { if transcriptGeneration == generation, !Task.isCancelled { catchUpRead = nil; nextCatchUp = .now + .seconds(10) } }
      do {
        var cursor: String?, before: String?, seen = Set<String>()
        repeat {
          guard case .history(let page) = try await directQuery(.history(threadID: threadID, cursor: cursor)) else { throw NotebookTransportError.invalidAcknowledgement }
          guard !Task.isCancelled, transcriptGeneration == generation else { return }
          mergeMessages(page.messages, preferIncoming: false, before: before)
          if page.messages.contains(where: { $0.id == boundary }) || page.nextCursor == nil { catchUpBoundary = nil; return }
          before = page.messages.first?.id ?? before; cursor = page.nextCursor
          if let cursor, !seen.insert(cursor).inserted { throw NotebookTransportError.invalidAcknowledgement }
        } while cursor != nil
      } catch { /* Keep the reading window; the visible-read schedule retries without resending work. */ }
    }
  }

  /// Both sources are chronological native windows. Insert missing runs beside
  /// their shared IDs; an older prefix in a live window must not become a tail.
  private func mergeMessages(_ incoming: [CodexMessage], preferIncoming: Bool, before boundary: String? = nil) {
    let known = Set(messages.map(\.id)), updates = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var before: [String: [CodexMessage]] = [:], pending: [CodexMessage] = [], lastShared: String?, seen = Set<String>()
    for item in incoming where seen.insert(item.id).inserted {
      if known.contains(item.id) { before[item.id] = pending; pending = []; lastShared = item.id }
      else { pending.append(item) }
    }
    var result: [CodexMessage] = []
    for item in messages {
      if lastShared == nil, item.id == boundary { result += pending; pending = [] }
      result += before[item.id] ?? []
      result.append(preferIncoming ? updates[item.id] ?? item : item)
      if item.id == lastShared { result += pending; pending = [] }
    }
    messages = result + pending
  }

  private func accept(_ reply: NotebookChatReply, for query: NotebookChatQuery, computer: UUID?) async throws {
    guard computer == peer else { return }
    switch (query, reply) {
    case (.job(let input), .job(let job)):
      guard input == job.input else { throw NotebookTransportError.invalidAcknowledgement }
      let previousRevision = jobs.first(where: { $0.id == input.id })?.revision ?? -1
      let received = try await persistence.submit { try $0.receiveChatReceipt(job) }
      let destination = try await persistence.submit { try $0.chatDestination(input.id) }
      guard destination == peer else { return }
      offeredJobs.insert(input.id)
      files.receive(received)
      if case .created(let task) = received.result {
        // Bind once; later receipts cannot steal a deliberate task switch.
        if jobs.first(where: { $0.id == job.id })?.state != .accepted { select(task); catalogue() }
      }
      if case .project(let project) = received.result {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
        if selectedProject?.id == project.id {
          files.chooseProject(project); catalogue()
        }
      }
      try await refreshJobs()
      // Receipt polling is not a failure of the selected conversation. In
      // particular, an uncertain creation must not poison every later read.
      if received.revision > previousRevision, let message = received.error, received.input.action.threadID == threadID,
        received.input.action.threadID != nil { error = message }
    case (.activity(let ids), .activity(let values)):
      guard values.count == ids.count, Set(values.map(\.id)) == Set(ids) else { throw NotebookTransportError.invalidAcknowledgement }
      if expanded {
        let shown = Set(visibleTasks.map(\.id))
        for value in values where shown.contains(value.id) { activities[value.id] = value }
      }
    case (.conversation(let id), .conversation(let value)):
      guard value.threadID == id else { throw NotebookTransportError.invalidAcknowledgement }
      if threadID == id { acceptConversation(value) }
    case (.conversation(let id), .conversationUnavailable(let thread, let reason)):
      guard id == thread else { throw NotebookTransportError.invalidAcknowledgement }
      if threadID == id { continuationUnavailable = true; error = reason }
    case (.history(let id, let cursor), .history(let page)):
      guard page.nextCursor == nil || page.nextCursor != cursor else { throw NotebookTransportError.invalidAcknowledgement }
      if threadID == id {
        mergeMessages(page.messages, preferIncoming: false, before: cursor == nil ? nil : historyBoundary ?? messages.first?.id)
        historyBoundary = page.messages.first?.id ?? historyBoundary
        historyLoaded = true; historyCursor = page.nextCursor; loadingHistory = false; error = nil
        if page.messages.isEmpty, page.nextCursor != nil { loadEarlier() }
      }
    case (_, .failure(let message)): error = message
    default: throw NotebookTransportError.invalidAcknowledgement
    }
  }
}
#endif
