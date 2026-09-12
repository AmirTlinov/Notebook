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
  let resize: (CGSize, Bool, NotebookChatResizeCorner) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false
  @GestureState private var resizing = false
  @State private var editingProject: CodexProject?
  @State private var terminalDrag: NotebookTerminalSplit?
  @State private var terminalFraction: Double?
  @GestureState private var draggingTerminal = false

  var body: some View {
    Group {
      if chat.expanded {
        VStack(spacing: 0) {
          header
          if chat.threadID == nil || chat.browsesChats { browserToolbar }
          GeometryReader { geometry in
            let split = NotebookTerminalSplit(height: geometry.size.height, fraction: terminalFraction ?? chat.files.window.terminalFraction)
            let height = chat.files.window.terminal == true ? split.conversation : geometry.size.height
            VStack(spacing: 0) {
              HStack(spacing: 0) {
                VStack(spacing: 0) {
                  if chat.threadID == nil || chat.browsesChats {
                    NotebookChatBrowser(chat: chat, openPairing: openPairing,
                      editProject: { editingProject = $0 }, createInProject: { project in
                        chat.selectProject(project); createChat()
                      })
                  }
                  else { conversation(height: height) }
                  composer
                }
                .frame(maxWidth: .infinity)
                if chat.files.window.sidebar {
                  Divider()
                  NotebookProjectFilesView(files: chat.files, computer: chat.computerID)
                    .frame(width: filesWidth)
                }
              }.frame(height: height)
              if chat.files.window.terminal == true {
                terminalDivider(split)
                NotebookRunPanel(runs: chat.runs, files: chat.files, connected: chat.connected)
                  .frame(height: split.terminal)
                  .transition(.move(edge: .bottom).combined(with: .opacity))
              }
            }
          }
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
    .clipShape(RoundedRectangle(cornerRadius: chat.expanded ? 28 : 24))
    .overlay {
      RoundedRectangle(cornerRadius: chat.expanded ? 28 : 24)
        .strokeBorder(Color(.separator).opacity(0.18), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.08), radius: 22, y: 7)
    .overlay {
      if chat.expanded {
        ForEach(NotebookChatResizeCorner.allCases, id: \.rawValue) { corner in
          Color.clear.frame(width: 36, height: 36)
            .contentShape(NotebookChatCornerHitShape(corner: corner))
            .gesture(windowDrag({ resize($0, $1, corner) }, activity: $resizing))
            .accessibilityLabel("Изменить размер за " + corner.label + " угол")
            .accessibilityIdentifier("notebook-chat-corner-" + corner.rawValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
        }
      }
    }
    .background(NotebookControlRegion(gate: model.inputGate))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notebook-chat-panel")
    .sheet(item: $editingProject) { NotebookProjectSettings(project: $0, chat: chat) }
    .onChange(of: scenePhase) {
      if scenePhase == .background { chat.voice.connectionLost() }
      else if scenePhase == .active { chat.synchronizeVisible() }
    }
    .onChange(of: chat.threadID) { chat.browsesChats = false }
    .onChange(of: moving) { if !moving { endInteraction() } }
    .onChange(of: resizing) { if !resizing { endInteraction() } }
    .onChange(of: draggingTerminal) { if !draggingTerminal { finishTerminalResize() } }
    .onChange(of: chat.computerID) { terminalDrag = nil; terminalFraction = nil }
  }

  private func terminalDivider(_ split: NotebookTerminalSplit) -> some View {
    Rectangle().fill(Color(.separator).opacity(0.35)).frame(height: 1)
      .frame(maxWidth: .infinity, minHeight: NotebookTerminalSplit.divider, maxHeight: NotebookTerminalSplit.divider)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("notebook-window"))
        .updating($draggingTerminal) { _, value, _ in value = true }
        .onChanged { value in
          if terminalDrag == nil { terminalDrag = split }
          terminalFraction = terminalDrag?.fraction(after: value.translation.height)
        }
        .onEnded { _ in finishTerminalResize() })
      .accessibilityLabel("Высота терминала")
      .accessibilityValue("\(Int(100 * split.terminal / max(1, split.available))) процентов")
      .accessibilityAdjustableAction { direction in
        let delta: CGFloat = direction == .increment ? -40 : 40
        chat.files.resizeTerminal(fraction: split.fraction(after: delta))
      }
      .accessibilityIdentifier("notebook-terminal-divider")
  }
  private func finishTerminalResize() {
    if let terminalFraction { chat.files.resizeTerminal(fraction: terminalFraction) }
    terminalDrag = nil; terminalFraction = nil
  }

  private var header: some View {
    HStack(spacing: 0) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 11)).frame(width: 24, height: 44).accessibilityHidden(true)
      Button {
        chat.browsesChats.toggle()
      } label: {
        HStack(spacing: 6) {
          Text(chat.browsesChats || chat.threadID == nil ? "Codex" : title).lineLimit(1)
          if !chat.browsesChats, chat.conversation?.busy == true { ProgressView().controlSize(.mini) }
          if chat.threadID != nil { Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)) }
        }
        .font(.system(size: 14)).foregroundStyle(.secondary)
        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }
      .accessibilityLabel("Выбрать чат")
      .accessibilityIdentifier("notebook-chat-tasks")
      .contextMenu {
        Button("Совместные ходы", systemImage: "clock.arrow.circlepath", action: openHistory).accessibilityIdentifier("collaboration-history")
        Button("Подключение и устройства", systemImage: "link", action: openPairing).accessibilityIdentifier("pairing-settings")
      }
      Color.clear.frame(minWidth: 24, maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .contentShape(Rectangle()).accessibilityLabel("Переместить чат")
        .accessibilityIdentifier("notebook-chat-move")
      Button {
        let visible = chat.files.window.terminal != true
        withAnimation(.easeInOut(duration: 0.18)) { chat.files.showTerminal(visible) }
        if visible { Task { await chat.runs.openTerminal() } }
      } label: {
        Image(systemName: "terminal").frame(width: 44, height: 44).contentShape(Rectangle())
          .foregroundStyle(chat.files.window.terminal == true ? Color.primary : .secondary)
      }.accessibilityLabel(chat.files.window.terminal == true ? "Свернуть терминал" : "Терминал проекта")
        .accessibilityIdentifier("notebook-terminal-toggle")
      Button { chat.files.toggleSidebar() } label: {
        Image(systemName: "sidebar.right").frame(width: 44, height: 44).contentShape(Rectangle())
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

  private var browserToolbar: some View {
    HStack(spacing: 12) {
      Picker("Показать", selection: Binding(get: { chat.browserMode }, set: chat.browse)) {
        ForEach(NotebookChatController.BrowserMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).accessibilityIdentifier("notebook-chat-browser-mode")
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
        Button("Подключение и устройства", systemImage: "link", action: openPairing)
        Button("Совместные ходы", systemImage: "clock.arrow.circlepath", action: openHistory)
        ForEach(chat.projects) { project in Button("Настроить «" + project.name + "»") { editingProject = project } }
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
    }.padding(.leading, 22).padding(.trailing, 8).padding(.bottom, 8)
  }

  private func conversation(height: CGFloat) -> some View {
    VStack(spacing: 0) {
      NotebookChatTranscript(messages: chat.messages, conversationID: chat.threadID,
        canLoadEarlier: chat.canLoadEarlier && !chat.loadingHistory, loadEarlier: chat.loadEarlier,
        openLink: model.openNotebookLink, saveExplanation: { [thread = chat.threadID, computer = chat.computerID] message in
          if let thread, let computer { model.saveChatExplanation(message, thread: thread, computer: computer) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notebook-chat-transcript")
      if let conversation = chat.conversation, let request = conversation.requests.first {
        NotebookCodexRequestView(request: request, threadID: conversation.threadID, chat: chat, maximumHeight: min(300, height * 0.45))
          .id(request.id).padding(.horizontal, 12).padding(.bottom, 8)
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
      NotebookChatComposer(chat: chat, width: size.width - (chat.files.window.sidebar ? filesWidth + 1 : 0) - 16,
        canSend: canSend, saving: chat.saving || model.isSavingAgentQuestion,
        send: { model.sendChatMessage() }, steer: { model.sendChatMessage(steering: true) })
    }
    .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 8)
  }

  private var filesWidth: CGFloat { min(220, max(120, size.width * 0.32)) }
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
    chat.browsesChats = false
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

/// A single offline WebKit renders the transcript; streamed text does not create
/// one browser per message, reload the document, or touch the canvas hierarchy.
struct NotebookChatTranscript: UIViewRepresentable {
  let messages: [CodexMessage]
  var conversationID: String? = nil
  var canLoadEarlier = false
  var loadEarlier: () -> Void = { }
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
    context.coordinator.loadEarlier = loadEarlier; context.coordinator.canLoadEarlier = canLoadEarlier
    context.coordinator.update(messages: messages, conversationID: conversationID)
  }
  static func dismantleUIView(_ container: UIView, coordinator: Coordinator) { coordinator.close() }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
    var ready = false, closed = false
    var json = "[]", sent: String?
    var web: WKWebView?
    var lease: WebSurfaceLease?
    var preparation: Task<Void, Never>?
    var messages: [CodexMessage] = []
    var conversationID: String?
    var canLoadEarlier = false
    var loadEarlier: () -> Void = { }
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
          web.navigationDelegate = self; web.scrollView.delegate = self; self.web = web; container.addSubview(web)
          if let root = Bundle.main.url(forResource: "WebResources", withExtension: nil) {
            web.loadFileURL(root.appendingPathComponent("chat-shell.html"), allowingReadAccessTo: root)
          }
        } catch { }
      }
    }
    func close() {
      closed = true; preparation?.cancel(); preparation = nil
      web?.configuration.userContentController.removeScriptMessageHandler(forName: "notebookChat")
      web?.stopLoading(); web?.navigationDelegate = nil; web?.scrollView.delegate = nil; web?.removeFromSuperview(); web = nil
      lease?.release(); lease = nil
    }
    func update(messages: [CodexMessage], conversationID: String? = nil) {
      if self.conversationID != conversationID { self.conversationID = conversationID; sent = nil }
      self.messages = messages
      json = (try? String(decoding: JSONEncoder().encode(messages), as: UTF8.self)) ?? "[]"
      if let web { publish(web) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; publish(webView) }
    func publish(_ web: WKWebView) {
      guard ready, !closed, sent != json else { return }
      sent = json
      let value = json
      let conversation = conversationID ?? ""
      Task { _ = try? await web.callAsyncJavaScript("await window.showMessages(json, conversation)", arguments: ["json": value, "conversation": conversation], in: nil, contentWorld: .page) }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !closed, canLoadEarlier, scrollView.isDragging || scrollView.isDecelerating,
        scrollView.contentOffset.y <= 120 else { return }
      canLoadEarlier = false; loadEarlier()
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
