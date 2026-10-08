import SwiftUI
import WebKit
import CryptoKit
import NotebookCore

/// The panel has one fixed composer and one scrolling reading surface. Keyboard
/// insets change this panel's available height, never the paper's geometry.
struct NotebookChatPanel: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(NotebookAppModel.self) private var model
  @Bindable var chat: NotebookChatController
  let size: CGSize
  let companion: NotebookCompanionPlacement
  let move: (CGSize, Bool) -> Void
  let resize: (CGSize, Bool, NotebookChatResizeCorner) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false
  @GestureState private var resizing = false
  @State private var showsCodexAccount = false
  @State private var editingProject: CodexProject?
  @State private var terminalDrag: NotebookTerminalSplit?
  @State private var terminalFraction: Double?
  @FocusState private var draftFocused: Bool
  @GestureState private var draggingTerminal = false

  var body: some View {
    Group {
      if chat.expanded {
        VStack(spacing: 0) {
          header
          Rectangle().fill(NotebookChrome.border).frame(height: 0.5)
          GeometryReader { geometry in
            let split = NotebookTerminalSplit(height: geometry.size.height, fraction: terminalFraction ?? chat.files.window.terminalFraction)
            let height = chat.files.window.terminal == true ? split.conversation : geometry.size.height
            VStack(spacing: 0) {
              VStack(spacing: 0) {
                HStack(spacing: 0) {
                  VStack(spacing: 0) {
                    if chat.browsesChats {
                      browserToolbar
                      NotebookChatBrowser(chat: chat,
                        editProject: { editingProject = $0 }, createChat: { project in
                          if chat.beginDraft(project: project) { draftFocused = true }
                        })
                    } else { conversation(height: height) }
                  }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  if chat.files.window.sidebar {
                    Rectangle().fill(NotebookChrome.border).frame(width: 0.5)
                    NotebookProjectFilesView(files: chat.files, computer: chat.computerID)
                      .frame(width: filesWidth)
                  }
                }
                .frame(maxHeight: .infinity)
                Rectangle().fill(NotebookChrome.border).frame(height: 0.5)
                composer
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
        .background(NotebookChrome.surface)
        .notebookPanel()
      } else {
        NotebookCompanion(chat: chat, placement: companion,
          move: move, endInteraction: endInteraction)
      }
    }
    .disabled(chat.switchingComputer)
    .onChange(of: chat.expanded) { draftFocused = false }
    .onChange(of: chat.pointingScope) { model.laserContext.clear() }
    .onChange(of: chat.dictation.showsInput) { if chat.dictation.showsInput { draftFocused = false } }
    .task(id: chat.dictation.reviewRequest) {
      guard chat.dictation.reviewRequest != nil else { return }
      await Task.yield()
      if chat.expanded && !chat.dictation.showsInput { draftFocused = true }
    }
    .buttonStyle(.plain)
    .tint(Color.primary)
    .frame(width: size.width, height: size.height)
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
    .sheet(isPresented: $showsCodexAccount) {
      let computer = chat.computerID
      NotebookCodexAccountView { query in
        guard chat.computerID == computer, case .account(let state) = try await chat.directQuery(.account(query)) else {
          throw NotebookTransportError.disconnected
        }
        return state
      }.id(computer)
    }
    .sheet(item: $editingProject) { NotebookProjectSettings(project: $0, chat: chat) }
    .onChange(of: scenePhase) {
      if scenePhase == .background { chat.voice.connectionLost() }
      else if scenePhase == .active { chat.synchronizeVisible() }
    }
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
      Button("Аккаунт Codex", systemImage: "person.crop.circle") { showsCodexAccount = true }
        .labelStyle(.iconOnly).frame(width: 44, height: 44)
        .accessibilityIdentifier("codex-account-open")
      Button {
        chat.browsesChats.toggle()
      } label: {
        HStack(spacing: 6) {
          Text(chat.browsesChats ? "Codex" : title).lineLimit(1)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }
        .font(.system(size: 14)).foregroundStyle(.secondary)
        .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
      }
      .accessibilityLabel("Выбрать чат")
      .accessibilityIdentifier("notebook-chat-tasks")
      .highPriorityGesture(windowDrag(move, activity: $moving))
      Color.clear.frame(minWidth: 24, maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .contentShape(Rectangle()).accessibilityLabel("Переместить чат")
        .accessibilityIdentifier("notebook-chat-move")
        .gesture(windowDrag(move, activity: $moving))
      Button {
        let visible = chat.files.window.terminal != true
        withAnimation(.easeInOut(duration: 0.18)) { chat.files.showTerminal(visible) }
        if visible { Task { await chat.runs.openTerminal() } }
      } label: {
        Image(systemName: "terminal")
          .overlay(alignment: .topTrailing) {
            if chat.runs.record?.isActive == true { Circle().fill(.green).frame(width: 5, height: 5).offset(x: 4, y: -3) }
          }.frame(width: 44, height: 44).contentShape(Rectangle())
          .foregroundStyle(chat.files.window.terminal == true ? Color.primary : .secondary)
      }.accessibilityLabel(chat.files.window.terminal == true ? "Свернуть терминал" : "Терминал проекта")
        .accessibilityIdentifier("notebook-terminal-toggle")
      Button { chat.files.toggleSidebar() } label: {
        Image(systemName: "sidebar.right").frame(width: 44, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("Файлы проекта").accessibilityIdentifier("notebook-files-toggle")
      Button { draftFocused = false; chat.expanded = false } label: {
        Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
      }
        .accessibilityLabel("Свернуть чат").accessibilityIdentifier("notebook-chat-toggle")
    }
    .font(NotebookChrome.iconFont).foregroundStyle(.secondary)
    // The resize rim and each complete 44-point button are disjoint owners.
    .padding(.leading, 22).padding(.trailing, NotebookChatCornerHitShape.rim)
    .padding(.top, NotebookChatCornerHitShape.rim)
  }

  private func windowDrag(_ action: @escaping (CGSize, Bool) -> Void, activity: GestureState<Bool>) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .named("notebook-window"))
      .updating(activity) { _, active, _ in active = true }
      .onChanged { action($0.translation, false) }
      .onEnded { action($0.translation, true) }
  }

  private var browserToolbar: some View {
    Picker("Показать", selection: Binding(get: { chat.browserMode }, set: chat.browse)) {
      ForEach(NotebookChatController.BrowserMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    .pickerStyle(.segmented).accessibilityIdentifier("notebook-chat-browser-mode")
    .padding(.horizontal, 14).padding(.vertical, 8)
  }

  private func conversation(height: CGFloat) -> some View {
    VStack(spacing: 0) {
      if chat.threadID == nil, let project = chat.selectedProject {
        Label(project.name, systemImage: "folder").font(.caption).foregroundStyle(.secondary).padding(12)
      }
      if let id = chat.creationID, let first = chat.firstMessages[id] {
        VStack(alignment: .leading, spacing: 8) {
          Text(first.text).textSelection(.enabled)
          Text(chat.jobs.first(where: { $0.id == id })?.error ?? "Создание чата не подтверждено")
            .font(.caption).foregroundStyle(.secondary)
          if let job = chat.jobs.first(where: { $0.id == id }), job.isTerminal, job.state != .accepted {
            Button("Вернуть в черновик") { chat.restoreFailedCreation(); draftFocused = true }
              .disabled(!chat.draft.isEmpty || !chat.attachments.isEmpty)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
          .accessibilityIdentifier("notebook-chat-first-message")
      }
      if chat.canLoadNewer {
        Button("Новые сообщения", action: chat.loadNewer)
          .font(.caption).accessibilityIdentifier("notebook-chat-newer-messages")
      }
      NotebookChatTranscript(messages: chat.presentationMessages, bodyCredits: chat.presentationBodyCredits, work: chat.workStatus, turnStatuses: chat.conversation?.turnStatuses ?? [:], conversationID: chat.threadID, revealMessageID: chat.revealedMessageID,
        canLoadEarlier: chat.canLoadEarlier && !chat.loadingHistory, loadEarlier: chat.loadEarlier, loadMessage: chat.retryMessageContent,
        openLink: model.openNotebookLink, saveExplanation: { [thread = chat.threadID, computer = chat.computerID] message in
          if let thread, let computer { model.saveChatExplanation(message, thread: thread, computer: computer) }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notebook-chat-transcript")
      if let conversation = chat.conversation {
        NotebookCodexRequestsView(conversation: conversation,
          job: { chat.decisionJob($0, threadID: conversation.threadID) }, query: { try await chat.directQuery($0) },
          respond: { await chat.respond($0, decision: $1, threadID: conversation.threadID) },
          maximumHeight: min(300, height * 0.45))
          .padding(.horizontal, 12).padding(.bottom, 8)
      }
      if !chat.pendingMessages.isEmpty { outbox }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("notebook-chat-conversation-" + (chat.threadID ?? "none"))
  }

  private var outbox: some View {
    ScrollView {
      VStack(alignment: .trailing, spacing: 8) {
        Text("Без подтверждения · \(chat.pendingMessages.count)").font(.caption2).foregroundStyle(.secondary)
        ForEach(chat.pendingMessages.suffix(4)) { job in
          if let (_, text, _) = job.input.action.message {
            VStack(alignment: .trailing, spacing: 4) {
              Text(text).font(.system(size: 15)).lineLimit(3).textSelection(.enabled)
              Text(job.state == .uncertain ? "Приём не подтверждён · повторной отправки нет" : "Приём Codex не подтверждён")
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12).background(NotebookChrome.insetSurface, in: RoundedRectangle(cornerRadius: NotebookChrome.cardRadius))
            .accessibilityIdentifier("notebook-chat-outgoing-" + job.id.uuidString)
          }
        }
        if chat.pendingMessages.count > 4 { Text("Показаны последние четыре сообщения.").font(.caption2).foregroundStyle(.secondary) }
      }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 20)
    }
    .scrollBounceBehavior(.basedOnSize).frame(maxHeight: 105).padding(.vertical, 8)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      NotebookCodexUncertainJobsView(jobs: chat.jobs, finish: chat.stopWaiting)
      NotebookVoiceControls(voice: chat.voice)
      if case let count = model.laserContext.count(scope:chat.pointingScope), count > 0 {
        HStack {
          Label("Указка · \(count)",systemImage:"cursorarrow.rays").font(.caption)
          Spacer()
          Button { model.laserContext.clear() } label: { Image(systemName:"xmark").frame(width:32,height:32) }
            .accessibilityLabel("Не прикреплять показанное указкой").accessibilityIdentifier("laser-context-clear")
        }.padding(.horizontal,12).accessibilityIdentifier("laser-context-pending")
      }
      if let notice {
        Text(notice).font(.caption).foregroundStyle(chat.error != nil || model.agentRequestError != nil ? .red : .secondary)
          .lineLimit(3).padding(.horizontal, 12).accessibilityIdentifier("notebook-chat-notice")
      }
      NotebookChatComposer(chat: chat, draftFocused: $draftFocused, width: size.width - 16,
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
    chat.canSendDraft && !model.isSavingAgentQuestion && !model.selectionSession.isResolvingContext
  }
  private var notice: String? {
    if let error = chat.voice.error { return error }
    if let error = chat.error ?? model.agentRequestError { return error }
    if let notice = chat.projectUpdateNotice { return notice }
    if chat.defaultProviderNeedsSignIn { return "Для нового чата войдите в Codex на Mac." }
    if !chat.connected, chat.threadID != nil, !chat.browsesChats { return "Mac недоступен · сообщения сохраняются на iPad" }
    return nil
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
  var bodyCredits: [NotebookChatBodyWindow.Credit] = []
  var work: NotebookChatWorkStatus? = nil
  var turnStatuses: [String: String] = [:]
  var conversationID: String? = nil
  var revealMessageID: String? = nil
  var canLoadEarlier = false
  var loadEarlier: () -> Void = { }
  var loadMessage: (String) -> Void = { _ in }
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
    context.coordinator.loadEarlier = loadEarlier; context.coordinator.loadMessage = loadMessage; context.coordinator.canLoadEarlier = canLoadEarlier
    context.coordinator.update(messages: messages, bodyCredits: bodyCredits, work: work, turnStatuses: turnStatuses, conversationID: conversationID, revealMessageID: revealMessageID)
  }
  static func dismantleUIView(_ container: UIView, coordinator: Coordinator) { coordinator.close() }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
    var ready = false, closed = false
    private struct MessageBasis: Equatable {
      let header: CodexMessage
      let textBytes: Int, detailBytes: Int
      let hasExpandedAttachments: Bool
      init(_ value: CodexMessage) {
        // Native body revision owns exact full bytes. Small display excerpts
        // also participate; ACK state never retains the former full body.
        let excerpt = value.isTruncated ? value.preview() : value
        let revision = value.contentRevision ?? Self.digest(value)
        textBytes = value.text.utf8.count; detailBytes = value.activity?.detail?.utf8.count ?? 0
        hasExpandedAttachments = value.attachments != excerpt.attachments
        header = .init(id: value.id, turnID: value.turnID, clientID: value.clientID, role: value.role,
          text: value.isTruncated ? excerpt.text : "", isTruncated: value.isTruncated, contentRevision: revision,
          activity: value.activity.map { .init(kind: $0.kind, status: $0.status,
            detail: value.isTruncated ? excerpt.activity?.detail : nil) },
          attachments: value.isTruncated ? excerpt.attachments : nil, phase: value.phase)
      }
      private static func digest(_ value: CodexMessage) -> String {
        var hash = SHA256()
        func field(_ text: String?) {
          guard let text else { hash.update(data: Data([0])); return }
          hash.update(data: Data([1])); var count = UInt64(text.utf8.count).bigEndian
          withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
          var bytes = text.utf8[...]
          while !bytes.isEmpty {
            let chunk = Data(bytes.prefix(64 * 1024)); hash.update(data: chunk); bytes = bytes.dropFirst(chunk.count)
          }
        }
        field(value.text); field(value.activity?.detail)
        for name in value.attachments ?? [] { field(name) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
      }
    }
    private struct Acknowledgement: Equatable {
      let messages: [String: MessageBasis], order: [String]
      let work: NotebookChatWorkStatus?, turnStatuses: [String: String], conversation: String, focus: String?
    }
    private struct Presentation {
      let messages: [CodexMessage], credits: [NotebookChatBodyWindow.Credit]
      let basis: Acknowledgement
      init(messages: [CodexMessage], credits: [NotebookChatBodyWindow.Credit] = [], work: NotebookChatWorkStatus?,
        turnStatuses: [String: String], conversation: String, focus: String?) {
        self.messages = messages; self.credits = credits
        basis = .init(messages: Dictionary(messages.map { ($0.id, MessageBasis($0)) }, uniquingKeysWith: { _, last in last }),
          order: messages.map(\.id), work: work, turnStatuses: turnStatuses, conversation: conversation, focus: focus)
      }
    }
    private struct Update: Encodable {
      let reset: Bool, conversation: String, order: [String], upserts: [CodexMessage], removed: [String]
      let work: NotebookChatWorkStatus?, turnStatuses: [String: String], focus: String?
    }
    private var desired = Presentation(messages: [], work: nil, turnStatuses: [:], conversation: "", focus: nil)
    private var sent: Acknowledgement?
    private var publishedCredits: [NotebookChatBodyWindow.Credit] = []
    private var needsFullPublication = false
    private var publication: Task<Void, Never>?
    private var publicationID: UUID?
    private(set) var navigation: WKNavigation?
    var publicationIsPending: Bool { publicationID != nil }
    private enum RetryKind { case publication, document }
    private var retryKind: RetryKind?
    private var automaticRecoveryUsed = false
    private var recoveringProcess = false
    private weak var container: UIView?
    private var retryBanner: UIStackView?
    private var sizeObservation: NSKeyValueObservation?
    private struct ReadingPosition {
      let basis: Acknowledgement, width: CGFloat, offset: CGFloat, followsTail: Bool
    }
    private struct ReadingLayout {
      let basis: Acknowledgement, height: CGFloat, restoring: ReadingPosition?
    }
    private var reading: ReadingPosition?
    private var readingLayout: ReadingLayout?
    var settledReadingOffset: CGFloat? {
      guard let reading, let sent, reading.basis == sent, sent == desired.basis, readingLayout == nil else { return nil }
      return reading.offset
    }
    var web: WKWebView?
    var lease: WebSurfaceLease?
    var preparation: Task<Void, Never>?
    var canLoadEarlier = false
    var loadEarlier: () -> Void = { }
    var loadMessage: (String) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var saveExplanation: (CodexMessage) -> Void = { _ in }
    func mount(_ container: UIView) {
      self.container = container
      container.backgroundColor = UIColor(NotebookChrome.surface)
      preparation = Task { [weak self, weak container] in
        do {
          let lease = try await SceneRenderResources.shared.acquireWebSurface(priority: .input, constructsView: true)
          guard let self, let container, !closed, !Task.isCancelled else { lease.release(); return }
          self.lease = lease
          let constructionBegan = ContinuousClock.now
          let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
          configuration.userContentController.add(self, name: "notebookChat")
          let web = WKWebView(frame: container.bounds, configuration: configuration)
          lease.finishConstruction(elapsed: constructionBegan.duration(to: .now))
          web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
          web.isOpaque = true; web.backgroundColor = UIColor(NotebookChrome.surface); web.scrollView.backgroundColor = UIColor(NotebookChrome.surface)
          web.navigationDelegate = self; web.scrollView.delegate = self; self.web = web; container.addSubview(web)
          sizeObservation = web.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak web] _, _ in
            MainActor.assumeIsolated {
              guard let self, let web else { return }
              self.finishReadingLayout(in: web)
            }
          }
          loadDocument(in: web)
        } catch {
          guard let self, !closed, !Task.isCancelled else { return }
          showRetry(.document)
        }
      }
    }
    func close() {
      closed = true; ready = false; preparation?.cancel(); preparation = nil; retirePublication(); navigation = nil
      desired = .init(messages: [], work: nil, turnStatuses: [:], conversation: "", focus: nil); sent = nil; publishedCredits = []; needsFullPublication = false
      reading = nil; readingLayout = nil; sizeObservation?.invalidate(); sizeObservation = nil; removeRetry()
      web?.configuration.userContentController.removeScriptMessageHandler(forName: "notebookChat")
      web?.stopLoading(); web?.navigationDelegate = nil; web?.scrollView.delegate = nil; web?.removeFromSuperview(); web = nil
      lease?.release(); lease = nil; container = nil
    }
    func update(messages: [CodexMessage], bodyCredits: [NotebookChatBodyWindow.Credit] = [], work: NotebookChatWorkStatus? = nil, turnStatuses: [String: String] = [:], conversationID: String? = nil, revealMessageID: String? = nil) {
      if desired.basis.conversation != (conversationID ?? "") { automaticRecoveryUsed = false }
      desired = .init(messages: messages, credits: bodyCredits, work: work, turnStatuses: turnStatuses,
        conversation: conversationID ?? "", focus: revealMessageID)
      if let web { publish(web) }
    }
    private func retirePublication() {
      publicationID = nil; publication?.cancel(); publication = nil
    }
    private func loadDocument(in web: WKWebView) {
      guard !closed, self.web === web else { return }
      ready = false; navigation = nil; retirePublication(); sent = nil; readingLayout = nil; needsFullPublication = false
      removeRetry(); web.stopLoading()
      guard let root = Bundle.main.url(forResource: "WebResources", withExtension: nil),
        let next = web.loadFileURL(root.appendingPathComponent("chat-shell.html"), allowingReadAccessTo: root) else {
        showRetry(.document); return
      }
      navigation = next
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard !closed, self.web === webView, let navigation, self.navigation === navigation, !ready else { return }
      ready = true; recoveringProcess = false; removeRetry(); publish(webView)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      guard !closed, self.web === webView, let navigation, self.navigation === navigation else { return }
      publishedCredits = []
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      navigationFailed(in: webView, navigation: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      navigationFailed(in: webView, navigation: navigation)
    }
    private func navigationFailed(in web: WKWebView, navigation: WKNavigation?) {
      guard !closed, self.web === web, let navigation, self.navigation === navigation, !ready else { return }
      recoveringProcess = false; showRetry(.document)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      recoverUnavailableProcess(in: webView)
    }
    private func recoverUnavailableProcess(in web: WKWebView) {
      guard !closed, self.web === web, !recoveringProcess else { return }
      ready = false; retirePublication(); sent = nil; readingLayout = nil; publishedCredits = []; needsFullPublication = false
      if automaticRecoveryUsed { showRetry(.document); return }
      automaticRecoveryUsed = true; recoveringProcess = true; loadDocument(in: web)
    }
    private func showRetry(_ kind: RetryKind) {
      retryKind = kind
      guard retryBanner == nil, let container else { return }
      let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
      label.font = .preferredFont(forTextStyle: .caption1); label.adjustsFontForContentSizeCategory = true
      label.text = "Не удалось отобразить беседу."
      let button = UIButton(configuration: .bordered(), primaryAction: UIAction(title: "Повторить") { [weak self] _ in self?.retry() })
      button.accessibilityIdentifier = "notebook-chat-retry"
      let banner = UIStackView(arrangedSubviews: [label, button]); banner.axis = .vertical; banner.spacing = 8
      banner.isLayoutMarginsRelativeArrangement = true; banner.layoutMargins = .init(top: 12, left: 12, bottom: 12, right: 12)
      banner.backgroundColor = .secondarySystemBackground; banner.layer.cornerRadius = 12
      banner.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(banner); retryBanner = banner
      NSLayoutConstraint.activate([banner.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 12),
        banner.centerXAnchor.constraint(equalTo: container.centerXAnchor), banner.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        banner.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24)])
    }
    private func removeRetry() { retryKind = nil; retryBanner?.removeFromSuperview(); retryBanner = nil }
    private func retry() {
      guard !closed, let kind = retryKind else { return }
      automaticRecoveryUsed = false; removeRetry()
      guard let web else {
        if let container { preparation?.cancel(); mount(container) }
        return
      }
      if kind == .publication, ready { publish(web) }
      else { recoveringProcess = false; loadDocument(in: web) }
    }
    func publish(_ web: WKWebView) {
      guard ready, !closed, self.web === web, retryKind == nil, publicationID == nil,
        let navigation, desired.basis != sent || needsFullPublication else { return }
      let attempt = UUID(); publicationID = attempt
      publication = Task { [weak self, weak web] in
        guard let self, let web else { return }
        defer {
          if publicationID == attempt { publicationID = nil; publication = nil }
        }
        while publicationIsCurrent(attempt, navigation: navigation, in: web), !Task.isCancelled,
          desired.basis != sent || needsFullPublication {
          let previousPublishedCredits = publishedCredits
          let next = desired, reset = sent?.conversation != desired.basis.conversation
          let previous = reset ? [:] : sent?.messages ?? [:]
          let ids = Set(next.basis.order)
          let update = Update(reset: reset, conversation: next.basis.conversation, order: next.basis.order,
            upserts: needsFullPublication ? next.messages : next.messages.filter { previous[$0.id] != next.basis.messages[$0.id] },
            removed: previous.keys.filter { !ids.contains($0) },
            work: next.basis.work, turnStatuses: next.basis.turnStatuses,
            focus: reset || sent?.focus != next.basis.focus ? next.basis.focus : nil)
          do {
            guard let lease else { return }
            let borrow = try lease.borrow()
            let json = String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
            let height: Double = try await withCheckedThrowingContinuation { continuation in
              web.callAsyncJavaScript("await window.updateMessages(JSON.parse(json)); return document.documentElement.scrollHeight;",
                arguments: ["json": json], in: nil, in: .page) { [next, previousPublishedCredits, borrow] result in
                  // Cancellation retires the logical attempt. The real WebKit
                  // callback alone returns its body credits and physical borrow.
                  defer {
                    borrow.release(); withExtendedLifetime(next.credits) {}; withExtendedLifetime(previousPublishedCredits) {}
                  }
                  continuation.resume(with: result.map { ($0 as? Double) ?? 0 })
                }
            }
            guard publicationIsCurrent(attempt, navigation: navigation, in: web), !Task.isCancelled else { return }
            sent = next.basis; publishedCredits = next.credits; needsFullPublication = false
            if height.isFinite, height > 0 {
              readingLayout = .init(basis: next.basis, height: CGFloat(height), restoring: reset ? reading : nil)
              finishReadingLayout(in: web)
            }
          } catch {
            guard publicationIsCurrent(attempt, navigation: navigation, in: web), !Task.isCancelled else { return }
            let failure = error as NSError
            if failure.domain == WKError.errorDomain, failure.code == WKError.Code.webContentProcessTerminated.rawValue {
              recoverUnavailableProcess(in: web)
            } else {
              // A script can throw after changing some articles. Until a
              // successful delta or realm retirement, either body may be live.
              var held = Set(publishedCredits.map(ObjectIdentifier.init))
              publishedCredits.append(contentsOf: next.credits.filter { held.insert(ObjectIdentifier($0)).inserted })
              needsFullPublication = true
              showRetry(.publication)
            }
            return
          }
        }
      }
    }
    private func publicationIsCurrent(_ attempt: UUID, navigation: WKNavigation, in web: WKWebView) -> Bool {
      !closed && ready && self.web === web && self.navigation === navigation && publicationID == attempt
    }
    private func finishReadingLayout(in web: WKWebView) {
      guard !closed, ready, self.web === web, let layout = readingLayout,
        sent == layout.basis, desired.basis == layout.basis else { return }
      let scroll = web.scrollView, tolerance = 1 / (web.window?.screen.scale ?? 1)
      guard scroll.contentSize.height + tolerance >= layout.height else { return }
      readingLayout = nil
      if let saved = layout.restoring, saved.basis == layout.basis,
        abs(saved.width - web.bounds.width) <= tolerance {
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let offset = saved.followsTail ? bottom : min(bottom, max(-scroll.adjustedContentInset.top, saved.offset))
        scroll.setContentOffset(.init(x: scroll.contentOffset.x, y: offset), animated: false)
      }
      rememberReading(in: scroll)
    }
    private func rememberReading(in scroll: UIScrollView) {
      guard !closed, ready, let web, web.scrollView === scroll, let sent, sent == desired.basis,
        readingLayout == nil, scroll.contentSize.height > 0 else { return }
      let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      reading = .init(basis: sent, width: web.bounds.width, offset: scroll.contentOffset.y,
        followsTail: bottom - scroll.contentOffset.y <= 60)
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { rememberReading(in: scrollView) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      if scrollView.isDragging || scrollView.isDecelerating { rememberReading(in: scrollView) }
      guard !closed, canLoadEarlier, scrollView.isDragging || scrollView.isDecelerating,
        scrollView.contentOffset.y <= 120 else { return }
      canLoadEarlier = false; loadEarlier()
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
      guard !closed, web === webView else { return .cancel }
      if action.navigationType == .linkActivated, let url = action.request.url, NotebookCodeLink(url: url) != nil {
        openLink(url); return .cancel
      }
      return action.navigationType == .other && action.request.url?.isFileURL == true ? .allow : .cancel
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard !closed, message.webView === web, message.frameInfo.isMainFrame,
        let body = message.body as? [String: String],
        let value = desired.messages.first(where: { $0.id == body["id"] }) else { return }
      if body["action"] == "load", value.isTruncated { loadMessage(value.id); return }
      guard body["action"] == "save", value.role == .assistant, value.activity == nil, !value.isTruncated else { return }
      saveExplanation(value)
    }
  }
}
