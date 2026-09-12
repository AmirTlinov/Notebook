import SwiftUI
import WebKit
import NotebookCore

/// The panel has one fixed composer and one scrolling reading surface. Keyboard
/// insets change this panel's available height, never the paper's geometry.
struct NotebookChatPanel: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(NotebookAppModel.self) private var model
  @Bindable var chat: NotebookChatController
  let size: CGSize
  let openPairing: () -> Void
  let openHistory: () -> Void
  let move: (CGSize, Bool) -> Void
  let resize: (CGSize, Bool) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false
  @GestureState private var resizing = false
  @State private var showsHistory = false
  @State private var showsAllChats = false
  @State private var editingProject: CodexProject?

  var body: some View {
    Group {
      if chat.expanded {
        VStack(spacing: 0) {
          header
          projectTabs
          HStack(spacing: 0) {
            if chat.files.window.sidebar {
              NotebookProjectFilesView(files: chat.files, computer: chat.computerID)
                .frame(width: min(220, max(130, size.width * 0.34)))
              Divider()
            }
            if chat.files.window.terminal == true { NotebookRunPanel(runs: chat.runs, files: chat.files, connected: chat.connected) }
            else if chat.threadID == nil || chat.browsesChats { recentChats }
            else { conversation }
          }
          composer
        }
      } else {
        Button { chat.expanded = true } label: {
          Label("Чат", systemImage: "bubble.left")
            .font(.system(size: 15, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .accessibilityLabel("Открыть чат")
        .accessibilityIdentifier("notebook-chat-toggle")
        .highPriorityGesture(windowDrag(move, activity: $moving))
      }
    }
    .disabled(chat.switchingComputer)
    .buttonStyle(.plain)
    .tint(Color.primary)
    .frame(width: size.width, height: size.height)
    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: chat.expanded ? 28 : 24))
    .overlay {
      RoundedRectangle(cornerRadius: chat.expanded ? 28 : 24)
        .strokeBorder(Color(.separator).opacity(0.18), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.08), radius: 22, y: 7)
    .overlay(alignment: .bottomTrailing) {
      if chat.expanded {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
          .frame(width: 44, height: 44).contentShape(Rectangle())
          .gesture(windowDrag(resize, activity: $resizing))
          .accessibilityLabel("Изменить размер чата")
          .accessibilityIdentifier("notebook-chat-resize")
      }
    }
    .background(NotebookControlRegion(gate: model.inputGate))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notebook-chat-panel")
    .sheet(item: $editingProject) { NotebookProjectSettings(project: $0, chat: chat) }
    .onChange(of: scenePhase) { if scenePhase == .background { chat.voice.connectionLost() } }
    .onChange(of: chat.threadID) { showsHistory = false; chat.browsesChats = false }
    .onChange(of: moving) { if !moving { endInteraction() } }
    .onChange(of: resizing) { if !resizing { endInteraction() } }
  }

  private var header: some View {
    HStack(spacing: 0) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 11)).frame(width: 24, height: 44).accessibilityHidden(true)
      Button {
        chat.browsesChats.toggle(); showsAllChats = false
        if chat.browsesChats { chat.catalogue() }
      } label: {
        HStack(spacing: 6) {
          Text(chat.browsesChats ? (chat.selectedProject?.name ?? "Чаты") : title).lineLimit(1)
          if !chat.browsesChats, chat.conversation?.busy == true { ProgressView().controlSize(.mini) }
          if chat.threadID != nil { Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)) }
        }
        .font(.system(size: 14)).foregroundStyle(.secondary)
        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }
      .accessibilityLabel("Выбрать чат")
      .accessibilityIdentifier("notebook-chat-tasks")
      Color.clear.frame(minWidth: 24, maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .contentShape(Rectangle()).accessibilityLabel("Переместить чат")
        .accessibilityIdentifier("notebook-chat-move")
      if let conversation = chat.conversation, let turnID = conversation.activeTurnID {
        Button { Task { await chat.stopTurn(threadID: conversation.threadID, turnID: turnID) } } label: {
          Image(systemName: "stop.circle").font(.system(size: 19)).frame(width: 44, height: 44)
        }.accessibilityLabel("Остановить ответ").accessibilityIdentifier("notebook-chat-stop")
      }
      Button { chat.files.toggleSidebar() } label: {
        Image(systemName: "sidebar.left").frame(width: 44, height: 44)
      }.accessibilityLabel("Файлы проекта").accessibilityIdentifier("notebook-files-toggle")
      Button(action: createChat) {
        Image(systemName: "square.and.pencil").frame(width: 44, height: 44).contentShape(Rectangle())
      }
        .accessibilityLabel("Новый чат").accessibilityIdentifier("notebook-chat-new")
        .disabled(chat.saving)
      Button { chat.expanded = false } label: {
        Image(systemName: "minus").frame(width: 44, height: 44).contentShape(Rectangle())
      }
        .accessibilityLabel("Свернуть чат").accessibilityIdentifier("notebook-chat-toggle")
    }
    .font(.system(size: 14, weight: .regular)).foregroundStyle(.secondary)
    .padding(.leading, 22).padding(.trailing, 8).padding(.top, 5)
    .contentShape(Rectangle())
    .highPriorityGesture(windowDrag(move, activity: $moving))
  }

  private func windowDrag(_ action: @escaping (CGSize, Bool) -> Void, activity: GestureState<Bool>) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .named("notebook-window"))
      .updating(activity) { _, active, _ in active = true }
      .onChanged { action($0.translation, false) }
      .onEnded { action($0.translation, true) }
  }

  private var recentChats: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(showsAllChats ? (chat.selectedProject?.name ?? "Чаты Codex") : "Недавние чаты")
            .font(.system(size: 14)).foregroundStyle(.secondary).padding(.bottom, 12)
          if chat.tasks.isEmpty {
            Text(chat.connected ? (chat.taskCursor != nil ? "На этой странице нет других чатов. Перейдите к следующим." : "Здесь пока нет чатов.") : "Чаты появятся, когда Mac будет доступен.")
              .font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 12)
          }
          if !chat.connected {
            Button("Подключить Mac", systemImage: "link", action: openPairing)
              .font(.system(size: 14)).frame(minHeight: 44)
              .accessibilityIdentifier("notebook-chat-connect")
          }
          ForEach(showsAllChats ? orderedTasks : Array(orderedTasks.prefix(3))) { task in
            Button { chat.select(task); chat.browsesChats = false } label: {
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(task.title).font(.system(size: 15)).foregroundStyle(.primary.opacity(0.75)).lineLimit(1)
                  Text(taskContext(task)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                  if let activity = chat.activities[task.id], activity.status == .running || activity.status == .waitingForInput,
                    let summary = activity.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
                taskStatus(task)
              }.frame(minHeight: 44).padding(.vertical, 7).contentShape(Rectangle())
            }
            .accessibilityIdentifier("notebook-chat-task-" + task.id)
          }
          if !showsAllChats, !chat.tasks.isEmpty {
            Button("Показать все") { showsAllChats = true }
              .font(.system(size: 14)).foregroundStyle(.secondary).frame(minHeight: 44)
              .accessibilityIdentifier("notebook-chat-show-all")
          } else if showsAllChats {
            HStack {
              Button("Обновить") { chat.catalogue() }
              Spacer()
              if chat.taskCursor != nil { Button("Следующие чаты") { chat.catalogue(next: true) } }
            }.font(.system(size: 14)).foregroundStyle(.secondary).frame(minHeight: 44)
          }
        }
        .padding(.horizontal, 22).padding(.bottom, 24)
        .frame(minHeight: geometry.size.height, alignment: .bottom)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notebook-chat-recents")
  }

  private var projectTabs: some View {
    HStack(spacing: 2) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 7) {
          projectTab("Все проекты", selected: chat.selectedProject == nil) {
            chat.selectProject(nil); showsAllChats = false
          }.accessibilityIdentifier("notebook-chat-project-all")
          ForEach(chat.projects) { project in
            projectTab(project.name, selected: chat.selectedProject?.id == project.id, active: projectIsWorking(project)) {
              chat.selectProject(project); showsAllChats = true
            }
            .contextMenu { Button("Настроить проект", systemImage: "slider.horizontal.3") { editingProject = project } }
            .accessibilityIdentifier("notebook-chat-project-" + project.id)
          }
          if chat.projectCursor != nil {
            Button { chat.catalogueProjects(next: true) } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
              .accessibilityLabel("Ещё проекты")
          }
        }.padding(.horizontal, 18)
      }
      Button { chat.files.toggleTerminal() } label: {
        Image(systemName: chat.files.window.terminal == true ? "bubble.left" : "terminal").frame(width: 44, height: 44)
      }.accessibilityLabel(chat.files.window.terminal == true ? "Показать разговор" : "Терминал проекта")
        .accessibilityIdentifier("notebook-terminal-toggle")
      Menu {
        if !chat.computers.isEmpty {
          Section("Компьютер") {
            ForEach(chat.computers, id: \.deviceID) { computer in
              Button { model.chooseChatComputer(computer.deviceID) } label: {
                Label(computer.displayName + (chat.onlineComputers.contains(computer.deviceID) ? "" : " · не в сети"),
                  systemImage: chat.computerID == computer.deviceID ? "checkmark" : "laptopcomputer")
              }.disabled(chat.switchingComputer)
            }
          }
        }
        ForEach(chat.projects) { project in Button("Настроить «" + project.name + "»") { editingProject = project } }
        Button("Обновить проекты") { chat.catalogueProjects() }
      } label: {
        VStack(spacing: 2) {
          Image(systemName: "slider.horizontal.3").font(.system(size: 14))
          if chat.computers.count > 1 {
            Text(chat.computers.first(where: { $0.deviceID == chat.computerID })?.displayName ?? "Mac не подключён")
              .font(.system(size: 9)).lineLimit(1)
          }
        }.frame(width: chat.computers.count > 1 ? 84 : 44, height: 44)
      }
        .accessibilityLabel("Настроить проекты").accessibilityIdentifier("notebook-chat-projects")
    }.padding(.trailing, 7).padding(.bottom, 7)
  }
  private func projectTab(_ name: String, selected: Bool, active: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if active { ProgressView().controlSize(.mini) }
        Text(name).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
      }
      .foregroundStyle(selected ? Color.primary : Color.secondary)
      .padding(.horizontal, 15).frame(height: 34)
      .background(selected ? Color(.secondarySystemBackground) : Color.clear, in: Capsule())
      .overlay { Capsule().strokeBorder(Color(.separator).opacity(selected ? 0 : 0.25), lineWidth: 0.75) }
      .frame(minHeight: 44)
    }.accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func projectIsWorking(_ project: CodexProject) -> Bool {
    chat.tasks.contains { task in
      (task.projectID == project.id || (task.projectID == nil && project.roots.contains(task.cwd)))
        && chat.activities[task.id]?.status == .running
    }
  }
  private func project(for task: CodexTask) -> CodexProject? {
    chat.projects.first { $0.id == task.projectID } ?? chat.projects.first { $0.roots.contains(task.cwd) }
  }
  private var orderedTasks: [CodexTask] {
    let activities = chat.activities
    return chat.tasks.enumerated().sorted { left, right in
      func rank(_ task: CodexTask) -> Int {
        switch activities[task.id]?.status { case .waitingForInput: 0; case .running: 1; default: 2 }
      }
      return rank(left.element) == rank(right.element) ? left.offset < right.offset : rank(left.element) < rank(right.element)
    }.map(\.element)
  }
  private func taskContext(_ task: CodexTask) -> String {
    let location = project(for: task)?.name ?? URL(fileURLWithPath: task.cwd).lastPathComponent
    let status: String
    switch chat.activities[task.id]?.status {
    case .running: status = "В работе"
    case .waitingForInput: status = "Нужен ваш ответ"
    case .idle: status = "Можно продолжить"
    default: status = "История · статус недоступен"
    }
    return location + " · " + status
  }
  @ViewBuilder private func taskStatus(_ task: CodexTask) -> some View {
    switch chat.activities[task.id]?.status {
    case .running: ProgressView().controlSize(.small).accessibilityLabel("В работе")
    case .waitingForInput: Image(systemName: "bubble.left.and.exclamationmark.bubble.right").foregroundStyle(.secondary)
    default: EmptyView()
    }
  }

  private var conversation: some View {
    VStack(spacing: 0) {
      HStack {
        if showsHistory {
          if chat.historyCursor != nil { Button("Ранее") { chat.older() } }
          Spacer()
          Button("К ответу") { showsHistory = false }
        } else {
          Button("История") { showsHistory = true; chat.latestHistory() }
          Spacer()
        }
      }
      .font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 32).padding(.horizontal, 22)
      NotebookChatTranscript(messages: showsHistory ? chat.history : (chat.conversation?.messages ?? chat.history),
        openLink: model.openNotebookLink, saveExplanation: { [thread = chat.threadID, computer = chat.computerID] message in
          if let thread, let computer { model.saveChatExplanation(message, thread: thread, computer: computer) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notebook-chat-transcript")
      if let conversation = chat.conversation, let request = conversation.requests.first {
        NotebookCodexRequestView(request: request, threadID: conversation.threadID, chat: chat)
          .id(request.id).padding(14)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
          .padding(.horizontal, 14).padding(.bottom, 8)
          .frame(maxHeight: min(210, size.height * 0.4))
      }
      if !chat.pendingMessages.isEmpty { outbox }
    }
  }

  private var outbox: some View {
    ScrollView {
      VStack(alignment: .trailing, spacing: 8) {
        Text("Исходящие · \(chat.pendingMessages.count)").font(.caption2).foregroundStyle(.secondary)
        ForEach(chat.pendingMessages.suffix(4)) { job in
          if let (_, text, _) = job.input.action.message {
            VStack(alignment: .trailing, spacing: 4) {
              Text(text).font(.system(size: 15)).lineLimit(3).textSelection(.enabled)
              Text(job.state == .saved ? "Сохранено на iPad · ожидает Codex" : job.state == .uncertain ? "Принятие проверяется · без повторной отправки" : "Передано Mac · ожидается подтверждение")
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("notebook-chat-outgoing-" + job.id.uuidString)
          }
        }
        if chat.pendingMessages.count > 4 { Text("Ранние сообщения сохранены в очереди.").font(.caption2).foregroundStyle(.secondary) }
      }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 20)
    }
    .scrollBounceBehavior(.basedOnSize).frame(maxHeight: 105).padding(.vertical, 8)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      NotebookVoiceControls(voice: chat.voice)
      if let question = model.agentQuestion {
        HStack(spacing: 6) {
          Label(question.references.first?.label ?? "Закреплённый фрагмент", systemImage: "scope")
            .font(.caption).lineLimit(1)
          Spacer(minLength: 0)
          Button { model.dismissAgentQuestion() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
            .accessibilityLabel("Снять выделение фрагмента").accessibilityIdentifier("notebook-chat-dismiss-fragment")
        }
        .padding(.leading, 12).foregroundStyle(.secondary)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
      }
      if let notice {
        Text(notice).font(.caption).foregroundStyle(chat.error != nil || model.agentRequestError != nil ? .red : .secondary)
          .lineLimit(3).padding(.horizontal, 12).accessibilityIdentifier("notebook-chat-notice")
      }
      HStack(alignment: .bottom, spacing: 0) {
        Menu {
          Button("Новый чат", systemImage: "square.and.pencil", action: createChat)
          Button("Выбрать чат", systemImage: "clock") { chat.browsesChats = true; showsAllChats = true; chat.catalogue() }
          if chat.conversation?.activeTurnID != nil {
            Button("Уточнить текущий ход", systemImage: "arrow.turn.down.right") { model.sendChatMessage(steering: true) }
              .disabled(!canSend).accessibilityIdentifier("notebook-chat-steer")
          }
          Button("Диктовка в черновик") { chat.voice.explainDictation() }
          Divider()
          Button("Совместные ходы", systemImage: "clock.arrow.circlepath", action: openHistory)
            .accessibilityIdentifier("collaboration-history")
          Button("Подключение и устройства", systemImage: "link", action: openPairing)
            .accessibilityIdentifier("pairing-settings")
        } label: {
          Image(systemName: "plus").font(.system(size: 19, weight: .regular)).frame(width: 44, height: 44)
        }.accessibilityLabel("Действия чата").accessibilityIdentifier("notebook-chat-actions")
        TextField("Сообщение Codex", text: $chat.draft, axis: .vertical)
          .font(.system(size: 15)).lineLimit(1...5).textFieldStyle(.plain)
          .padding(.vertical, 12).padding(.trailing, 8)
          .accessibilityIdentifier("notebook-chat-text")
        if chat.saving || model.isSavingAgentQuestion {
          ProgressView().controlSize(.small).frame(width: 44, height: 44)
        }
        Button { Task { await chat.voice.begin() } } label: {
          Image(systemName: "waveform").font(.system(size: 16)).frame(width: 44, height: 44)
        }.accessibilityLabel("Голосовой разговор с Codex").accessibilityIdentifier("notebook-chat-voice")
          .disabled(chat.voice.activeID != nil || !chat.connected || chat.threadID == nil || chat.browsesChats)
        Button { model.sendChatMessage() } label: {
          Image(systemName: "arrow.up").font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white).frame(width: 30, height: 30)
            .background(canSend ? Color(.label) : Color(.systemGray), in: Circle())
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(!canSend).accessibilityLabel("Отправить сообщение").accessibilityIdentifier("notebook-chat-send")
      }
      .padding(3)
      .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26))
      .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5).allowsHitTesting(false) }
      .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("notebook-chat-composer")
    }
    .padding(.leading, 8).padding(.trailing, 44).padding(.bottom, 8).padding(.top, 8)
  }

  private var title: String {
    chat.conversation?.title ?? chat.tasks.first(where: { $0.id == chat.threadID })?.title ?? (chat.threadID == nil ? "Новый чат" : "Чат Codex")
  }
  private var canSend: Bool {
    !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.threadID != nil
      && !chat.saving && !chat.switchingComputer && !model.isSavingAgentQuestion && !chat.continuationUnavailable && !chat.browsesChats
  }
  private var notice: String? {
    if let error = chat.voice.error { return error }
    if let error = chat.error ?? model.agentRequestError { return error }
    if let notice = chat.projectUpdateNotice { return notice }
    if chat.defaultProviderNeedsSignIn { return "Для нового чата войдите в Codex на Mac." }
    if !chat.connected, chat.threadID != nil, !chat.browsesChats { return "Mac недоступен · сообщения сохраняются на iPad" }
    return nil
  }
  private func createChat() {
    showsHistory = false; chat.browsesChats = false
    Task { await chat.create() }
  }
}

private struct NotebookProjectSettings: View {
  @Environment(\.dismiss) private var dismiss
  let project: CodexProject
  let chat: NotebookChatController
  @State private var name: String
  @State private var roots: String
  @State private var error: String?
  init(project: CodexProject, chat: NotebookChatController) {
    self.project = project; self.chat = chat
    _name = State(initialValue: project.name); _roots = State(initialValue: project.roots.joined(separator: "\n"))
  }
  private var paths: [String] {
    roots.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL.path : $0 }
  }
  private var submittedRoots: [String] {
    roots == project.roots.joined(separator: "\n") ? project.roots : paths
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Проект Codex") { TextField("Название", text: $name).accessibilityIdentifier("notebook-project-name") }
        Section {
          TextField("/Users/…", text: $roots, axis: .vertical).lineLimit(2...6).autocorrectionDisabled().textInputAutocapitalization(.never)
            .accessibilityIdentifier("notebook-project-roots")
        } header: { Text("Папки проекта на Mac") } footer: {
          Text("Один полный путь на строку. Изменяются настройки настоящего проекта Codex, не копия в Notebook. Файлы не перемещаются.")
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("Настройки проекта").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Сохранить") {
            Task {
              if await chat.updateProject(project, name: name.trimmingCharacters(in: .whitespacesAndNewlines), roots: submittedRoots) { dismiss() }
              else { error = "Проверьте название и полные пути. Изменения не сохранены." }
            }
          }.disabled(chat.saving || chat.projectUpdatePending(project.id) || (name == project.name && submittedRoots == project.roots))
            .accessibilityIdentifier("notebook-project-save")
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private struct NotebookCodexRequestView: View {
  struct Questions: Decodable { let questions: [Question] }
  struct Question: Decodable, Identifiable {
    struct Option: Decodable { let label: String; let description: String? }
    let id: String; let question: String; let options: [Option]?
  }
  let request: CodexUserRequest
  let threadID: String
  let chat: NotebookChatController
  @State private var answers: [String: String] = [:]
  @State private var submitted = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text("Codex просит ваше решение").font(.caption.weight(.bold))
        if request.method == "item/tool/requestUserInput", let questions {
          ForEach(questions.questions) { question in
            Text(question.question).font(.callout)
            if let options = question.options {
              ForEach(options, id: \.label) { option in
                Button(option.label) { answers[question.id] = option.label }.font(.caption)
                if let description = option.description { Text(description).font(.caption2) }
              }
            }
            TextField("Ваш ответ", text: Binding(get: { answers[question.id, default: ""] }, set: { answers[question.id] = $0 }), axis: .vertical)
              .textFieldStyle(.roundedBorder)
          }
          Button("Ответить") { decide(.answers(answers.mapValues { [$0] })) }
            .disabled(questions.questions.contains { answers[$0.id, default: ""].isEmpty })
        } else {
          Text(parameters).font(.caption.monospaced()).textSelection(.enabled)
          if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].contains(request.method) {
            HStack {
              Button("Разрешить один раз") { decide(.allowOnce) }
              Button("Отказать", role: .destructive) { decide(.decline) }
            }
          } else if request.method == "mcpServer/elicitation/request" {
            Button("Отклонить") { decide(.elicitation(.object(["action": .string("decline")]))) }
            Text("Для заполнения этой формы откройте задачу в Codex.").font(.caption)
          } else { Text("Этот запрос нужно обработать в Codex на Mac.").font(.caption) }
        }
        if let job = chat.decisionJob(request, threadID: threadID) {
          Text(job.state == .uncertain ? "Принятие решения проверяется. Повтора нет." : "Решение сохранено и ожидает Codex.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.disabled(submitted || chat.decisionJob(request, threadID: threadID) != nil)
    }.frame(maxHeight: 200)
  }
  private var questions: Questions? { try? JSONDecoder().decode(Questions.self, from: JSONEncoder().encode(request.parameters)) }
  private var parameters: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? String(decoding: encoder.encode(request.parameters), as: UTF8.self)) ?? request.method
  }
  private func decide(_ decision: CodexUserDecision) {
    submitted = true
    Task { await chat.respond(request, decision: decision, threadID: threadID); submitted = false }
  }
}

/// A single offline WebKit renders the transcript; streamed text does not create
/// one browser per message, reload the document, or touch the canvas hierarchy.
struct NotebookChatTranscript: UIViewRepresentable {
  let messages: [CodexMessage]
  var openLink: (URL) -> Void = { _ in }
  var saveExplanation: (CodexMessage) -> Void = { _ in }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    context.coordinator.mount(container)
    return container
  }
  func updateUIView(_ container: UIView, context: Context) {
    context.coordinator.openLink = openLink; context.coordinator.saveExplanation = saveExplanation
    context.coordinator.update(messages: messages)
  }
  static func dismantleUIView(_ container: UIView, coordinator: Coordinator) { coordinator.close() }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var ready = false, closed = false
    var json = "[]", sent: String?
    var web: WKWebView?
    var lease: WebSurfaceLease?
    var preparation: Task<Void, Never>?
    var messages: [CodexMessage] = []
    var openLink: (URL) -> Void = { _ in }
    var saveExplanation: (CodexMessage) -> Void = { _ in }
    func mount(_ container: UIView) {
      preparation = Task { [weak self, weak container] in
        do {
          let lease = try await SceneRenderResources.shared.acquireWebSurface(priority: .input)
          guard let self, let container, !closed, !Task.isCancelled else { lease.release(); return }
          self.lease = lease
          let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
          configuration.userContentController.add(self, name: "notebookChat")
          let web = WKWebView(frame: container.bounds, configuration: configuration)
          web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
          web.navigationDelegate = self; self.web = web; container.addSubview(web)
          if let root = Bundle.main.url(forResource: "WebResources", withExtension: nil) {
            web.loadFileURL(root.appendingPathComponent("chat-shell.html"), allowingReadAccessTo: root)
          }
        } catch { }
      }
    }
    func close() {
      closed = true; preparation?.cancel(); preparation = nil
      web?.configuration.userContentController.removeScriptMessageHandler(forName: "notebookChat")
      web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
      lease?.release(); lease = nil
    }
    func update(messages: [CodexMessage]) {
      self.messages = messages
      json = (try? String(decoding: JSONEncoder().encode(messages), as: UTF8.self)) ?? "[]"
      if let web { publish(web) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; publish(webView) }
    func publish(_ web: WKWebView) {
      guard ready, !closed, sent != json else { return }
      sent = json
      let value = json
      Task { _ = try? await web.callAsyncJavaScript("await window.showMessages(json)", arguments: ["json": value], in: nil, contentWorld: .page) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      if action.navigationType == .linkActivated, let url = action.request.url, NotebookCodeLink(url: url) != nil {
        openLink(url); return .cancel
      }
      return action.navigationType == .other && action.request.url?.isFileURL == true ? .allow : .cancel
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard !closed, message.webView === web, message.frameInfo.isMainFrame,
        let body = message.body as? [String: String], body["action"] == "save",
        let value = messages.first(where: { $0.id == body["id"] }), value.role == .assistant, value.activity == nil else { return }
      saveExplanation(value)
    }
  }
}
