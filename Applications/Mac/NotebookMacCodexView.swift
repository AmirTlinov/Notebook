import SwiftUI
import NotebookCore

/// Presentation only. Native history and the Mac's existing durable command
/// journal remain authoritative; closing this view never cancels accepted work.
@MainActor @Observable
final class NotebookMacCodexPresentation {
  let model: NotebookAppModel
  var tasks: [CodexTask] = []
  var projects: [CodexProject] = []
  var projectID: String?
  var taskCursor: String?
  var projectCursor: String?
  var threadID: String?
  var draft = "" { didSet { savePanel() } }
  var conversation: CodexConversation?
  var messages: [CodexMessage] = []
  var historyCursor: String?
  var jobs: [NotebookChatJob] = []
  var failure: String?
  var submitting = false
  private var restored = false
  private var generation = UUID()
  private var historyLoaded = false
  private var createdInput: UUID?
  private var projectInput: UUID?
  private var submission: NotebookChatInput?

  init(model: NotebookAppModel) { self.model = model }

  func run() async {
    do {
      let panel = try await model.localCodexPanel()
      threadID = panel.threadID; draft = panel.draft; restored = true
    } catch { failure = error.localizedDescription; return }
    var refresh = 0
    while !Task.isCancelled {
      do {
        jobs = try await model.localCodexJobs()
        if let createdInput, let job = jobs.first(where: { $0.id == createdInput }), job.isTerminal {
          self.createdInput = nil
          if case .created(let task) = job.result { try await catalogue(); await select(task.id) }
          else { failure = job.error }
        }
        if let projectInput, let job = jobs.first(where: { $0.id == projectInput }), job.isTerminal {
          self.projectInput = nil
          if case .project(let project) = job.result { try await loadProjects(); projectID = project.id; try await catalogue() }
          else { failure = job.error }
        }
        if refresh % 10 == 0 {
          try await loadProjects(); try await catalogue()
          if threadID != nil { try await refreshConversation(); if !historyLoaded { try await history(more: false) } }
        }
      } catch is CancellationError { break } catch { failure = error.localizedDescription }
      refresh += 1
      do { try await Task.sleep(for: .seconds(1)) } catch { break }
    }
    _ = try? await model.localCodexQuery(.activity(threadIDs: []))
  }

  func catalogue(more: Bool = false) async throws {
    let selected = projects.first { $0.id == projectID }
    if case .catalogue(let page) = try await model.localCodexQuery(.catalogue(cursor: more ? taskCursor : nil, project: selected)) {
      tasks = more ? tasks + page.tasks.filter { item in !tasks.contains { $0.id == item.id } } : page.tasks
      taskCursor = page.nextCursor
    }
  }
  func loadProjects(more: Bool = false) async throws {
    if case .projects(let page) = try await model.localCodexQuery(.projects(cursor: more ? projectCursor : nil)) {
      projects = more ? projects + page.projects.filter { item in !projects.contains { $0.id == item.id } } : page.projects
      projectCursor = page.nextCursor
    }
  }
  func select(_ id: String) async {
    generation = UUID(); threadID = id; conversation = nil; messages = []; historyCursor = nil; historyLoaded = false; savePanel()
    do { try await refreshConversation(); try await history(more: false) }
    catch { failure = error.localizedDescription }
  }
  private func refreshConversation() async throws {
    guard let threadID else { return }
    let epoch = generation
    let reply = try await model.localCodexQuery(.conversation(threadID: threadID))
    guard generation == epoch else { return }
    switch reply {
    case .conversation(let value): accept(value); failure = nil
    case .conversationUnavailable(_, let reason): conversation = nil; failure = reason
    default: break
    }
  }
  func history(more: Bool) async throws {
    guard let threadID else { return }
    let epoch = generation
    if case .history(let page) = try await model.localCodexQuery(.history(threadID: threadID, cursor: more ? historyCursor : nil)), epoch == generation {
      let existing = Set(messages.map(\.id))
      messages = page.messages.filter { !existing.contains($0.id) } + messages
      historyCursor = page.nextCursor; historyLoaded = true
    }
  }
  func receive(_ envelope: NotebookChatEnvelope?) {
    if case .event(_, let value) = envelope?.body, value.threadID == threadID { accept(value) }
  }
  private func accept(_ value: CodexConversation) {
    guard value.threadID == threadID, conversation == nil || value.revision >= conversation!.revision else { return }
    conversation = value
    for item in value.messages {
      if let index = messages.firstIndex(where: { $0.id == item.id }) { messages[index] = item }
      else { messages.append(item) }
    }
  }
  func savePanel() {
    guard restored else { return }
    model.saveLocalCodexPanel(.init(threadID: threadID, draft: draft, sidecarID: model.actorID))
  }
  func submit(_ action: NotebookChatAction) async {
    // Multiple independent task owners may run; this prevents a double click in
    // this composer, not global execution or human controls on another device.
    guard !submitting else { return }
    submitting = true; defer { submitting = false }
    if let submission, submission.action != action { failure = "Сначала повторите сохранение предыдущего действия — его исход ещё не подтверждён."; return }
    do {
      if let job = try await model.localCodexControl(action) {
        jobs.removeAll { $0.id == job.id }; jobs.insert(job, at: 0); failure = job.error; return
      }
    } catch { failure = error.localizedDescription; return }
    let input = submission ?? NotebookChatInput(id: action.controlID(author: model.actorID) ?? UUID(), author: model.actorID, action: action)
    guard input.isValid else { failure = "Сообщение слишком большое или параметры неполны"; return }
    submission = input
    do {
      if case .job(let job) = try await model.localCodexQuery(.job(input)) {
        submission = nil
        jobs.removeAll { $0.id == job.id }; jobs.insert(job, at: 0)
        if case .create = action { createdInput = input.id }
        if case .createProject = action { projectInput = input.id }
        if let message = action.message, draft == message.text { draft = "" }
        failure = job.error
      }
    } catch { failure = error.localizedDescription }
  }
  func stopWaiting(_ id: UUID) async {
    do {
      if case .job(let job) = try await model.localCodexQuery(.stopWaiting(id)) {
        jobs.removeAll { $0.id == id }; jobs.insert(job, at: 0); failure = job.error
      }
    } catch { failure = error.localizedDescription }
  }
  func decision(_ request: CodexUserRequest) -> NotebookChatJob? {
    guard let threadID else { return nil }
    let id = NotebookChatAction.respond(threadID: threadID, request: request, decision: .decline).controlID(author: model.actorID)
    return jobs.first { $0.id == id }
  }
}

struct NotebookMacCodexView: View {
  @State private var chat: NotebookMacCodexPresentation
  init(model: NotebookAppModel) { _chat = State(initialValue: .init(model: model)) }

  var body: some View {
    HSplitView {
      VStack(alignment: .leading) {
        Picker("Проект", selection: $chat.projectID) {
          Text("Все задачи").tag(String?.none)
          ForEach(chat.projects) { Text($0.name).tag(Optional($0.id)) }
        }.onChange(of: chat.projectID) { _, _ in perform { try await chat.catalogue() } }
        if chat.projectCursor != nil { Button("Ещё проекты") { perform { try await chat.loadProjects(more: true) } } }
        List(selection: Binding(get: { chat.threadID }, set: { id in if let id { Task { await chat.select(id) } } })) {
          ForEach(chat.tasks) { task in
            VStack(alignment: .leading, spacing: 3) {
              Text(task.title.isEmpty ? "Задача Codex" : task.title).lineLimit(2)
              Text(task.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.tag(task.id)
          }
          if chat.taskCursor != nil { Button("Ещё задачи") { perform { try await chat.catalogue(more: true) } } }
        }.accessibilityIdentifier("codex-mac-tasks")
        Button("Добавить папку проекта…") {
          let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
          panel.allowsMultipleSelection = false; panel.prompt = "Добавить в Codex"
          panel.begin { response in
            guard response == .OK, let url = panel.url?.resolvingSymlinksInPath().standardizedFileURL else { return }
            Task { await chat.submit(.createProject(name: url.lastPathComponent, path: url.path)) }
          }
        }.disabled(chat.submitting).accessibilityIdentifier("codex-mac-add-project")
        Button("Новая задача") {
          Task { await chat.submit(.create(title: "Задача Notebook", project: chat.projects.first { $0.id == chat.projectID })) }
        }.disabled(chat.submitting).accessibilityIdentifier("codex-mac-create")
      }.padding().frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading) {
            Text(chat.conversation?.title ?? "Codex на этом Mac").font(.headline)
            if let id = chat.threadID { Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
          }
          Spacer()
          if let conversation = chat.conversation, let turn = conversation.activeTurnID {
            Button("Остановить", role: .destructive) { Task { await chat.submit(.stop(threadID: conversation.threadID, turnID: turn)) } }
          }
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if chat.historyCursor != nil { Button("Ранее") { perform { try await chat.history(more: true) } } }
            ForEach(chat.messages) { message in
              VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "Вы" : "Codex").font(.caption).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let detail = message.activity?.detail { Text(detail).font(.caption.monospaced()).textSelection(.enabled) }
                if message.isTruncated { Text("Фрагмент · полный вывод хранится у Codex").font(.caption).foregroundStyle(.secondary) }
              }
            }
          }.padding(.vertical, 8)
        }.accessibilityIdentifier("codex-mac-conversation")
        if let conversation = chat.conversation {
          ForEach(conversation.requests) { request in
            NotebookCodexRequestView(request: request, job: chat.decision(request), respond: { decision in
              await chat.submit(.respond(threadID: conversation.threadID, request: request, decision: decision))
            }, maximumHeight: 250)
          }
        }
        if let failure = chat.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
        if let job = chat.jobs.first, job.state == .uncertain || job.state == .rejected || !job.isTerminal {
          Text(job.error ?? (job.state == .uncertain ? "Исход команды неизвестен. Автоматического повтора не будет." : "Команда сохранена на Mac · ожидается Codex"))
            .font(.caption).foregroundStyle(.secondary)
        }
        NotebookCodexUncertainJobsView(jobs: chat.jobs, finish: chat.stopWaiting)
        TextEditor(text: $chat.draft).frame(minHeight: 70, maxHeight: 130)
          .accessibilityIdentifier("codex-mac-composer")
        HStack {
          Text(chat.conversation?.busy == true ? "Codex работает · можно направить текущий ответ" : "Один проект и задача для Mac и iPad")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(chat.conversation?.busy == true ? "Направить" : "Отправить") {
            guard let id = chat.threadID else { return }
            let action: NotebookChatAction
            if let turn = chat.conversation?.activeTurnID { action = .steer(threadID: id, turnID: turn, text: chat.draft, context: "") }
            else { action = .send(threadID: id, text: chat.draft, context: "") }
            Task { await chat.submit(action) }
          }.keyboardShortcut(.return, modifiers: .command)
            .disabled(chat.conversation?.ready != true || chat.submitting || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding().frame(minWidth: 420, maxWidth: .infinity)
    }
    .frame(minWidth: 720, minHeight: 520)
    .task { await chat.run() }
    .onChange(of: chat.model.localCodexEvent) { _, value in chat.receive(value) }
  }
  private func perform(_ operation: @escaping () async throws -> Void) {
    Task { do { try await operation(); chat.failure = nil } catch { chat.failure = error.localizedDescription } }
  }
}
