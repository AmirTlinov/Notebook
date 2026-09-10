import SwiftUI
import WebKit
import NotebookCore

struct NotebookChatPanel: View {
  @Environment(NotebookAppModel.self) private var model
  @Bindable var chat: NotebookChatController
  let maximumHeight: CGFloat
  @State private var contentHeight: CGFloat = 520
  var body: some View {
    ScrollView {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button { chat.expanded.toggle() } label: {
          Label("Codex", systemImage: "bubble.left.and.text.bubble.right").font(.headline).frame(minHeight: 44)
        }.accessibilityIdentifier("notebook-chat-toggle")
        if chat.expanded {
          Spacer()
          Menu {
            ForEach(chat.tasks) { task in Button(task.title) { chat.select(task) } }
            Button("Обновить задачи") { chat.catalogue() }
            if chat.taskCursor != nil { Button("Следующие задачи") { chat.catalogue(next: true) } }
            Button("Новая задача") { Task { await chat.create() } }
          } label: { Label("Задача", systemImage: "list.bullet").frame(minHeight: 44) }
          .accessibilityIdentifier("notebook-chat-tasks")
        }
      }
      if chat.expanded {
        Text(chat.conversation?.title ?? chat.tasks.first(where: { $0.id == chat.threadID })?.title ?? "Выберите задачу Codex на Mac")
          .font(.subheadline.weight(.semibold)).lineLimit(2)
        if let id = chat.threadID { Text(id).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(1) }
        HStack {
          Text(status).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if let conversation = chat.conversation, let turnID = conversation.activeTurnID {
            Button("Стоп") { Task { await chat.stopTurn(threadID: conversation.threadID, turnID: turnID) } }.frame(minHeight: 44)
              .accessibilityIdentifier("notebook-chat-stop")
          }
        }
        if chat.threadID != nil {
          HStack {
            if showsHistory {
              if chat.historyCursor != nil { Button("Ранее") { chat.older() }.font(.caption).frame(minHeight: 36) }
              Button("К ответу") { showsHistory = false }.font(.caption)
            } else {
              Button("История") { showsHistory = true; chat.latestHistory() }.font(.caption).frame(minHeight: 36)
            }
          }
          NotebookChatTranscript(messages: showsHistory ? chat.history : (chat.conversation?.messages ?? chat.history))
            .frame(minHeight: 80, idealHeight: 230, maxHeight: 280)
            .onChange(of: chat.threadID) { showsHistory = false }
          if let conversation = chat.conversation, let request = conversation.requests.first {
            NotebookCodexRequestView(request: request, threadID: conversation.threadID, chat: chat).id(request.id)
          }
        }
        if let question = model.agentQuestion {
          Label(question.references.first?.label ?? "Закреплённый фрагмент", systemImage: "scope").font(.caption).lineLimit(1)
        }
        TextField("Сообщение Codex", text: $chat.draft, axis: .vertical)
          .lineLimit(2...4).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("notebook-chat-text")
        HStack {
          Button("Отправить") { model.sendChatMessage() }
            .buttonStyle(.borderedProminent).frame(minHeight: 44)
            .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.threadID == nil || chat.saving || model.isSavingAgentQuestion)
            .accessibilityIdentifier("notebook-chat-send")
          if chat.saving || model.isSavingAgentQuestion { ProgressView() }
        }
        if let job = chat.selectedJob, !job.isTerminal {
          Text(job.state == .saved ? "Сохранено на iPad · ожидает Codex" : job.state == .uncertain ? "Принятие проверяется · без повторной отправки" : "Передано Mac · ожидается подтверждение")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let error = chat.error ?? model.agentRequestError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
      }
    }
    .padding(14)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(width: chat.expanded ? 350 : 120, height: min(contentHeight, max(44, maximumHeight)))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .background(NotebookControlRegion(gate: model.inputGate))
    .accessibilityIdentifier("notebook-chat-panel")
  }
  @State private var showsHistory = false
  private var status: String {
    if !chat.connected { return "Mac недоступен" }
    if chat.conversation?.requests.isEmpty == false { return "Требуется ваше действие" }
    if chat.conversation?.busy == true { return "Агент отвечает" }
    if chat.selectedJob?.state == .accepted { return "Принято Codex" }
    return "Mac подключён"
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
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    context.coordinator.mount(container)
    return container
  }
  func updateUIView(_ container: UIView, context: Context) { context.coordinator.update(messages: messages) }
  static func dismantleUIView(_ container: UIView, coordinator: Coordinator) { coordinator.close() }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
    var ready = false, closed = false
    var json = "[]", sent: String?
    var web: WKWebView?
    var lease: WebSurfaceLease?
    var preparation: Task<Void, Never>?
    func mount(_ container: UIView) {
      preparation = Task { [weak self, weak container] in
        do {
          let lease = try await SceneRenderResources.shared.acquireWebSurface(priority: .input)
          guard let self, let container, !closed, !Task.isCancelled else { lease.release(); return }
          self.lease = lease
          let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
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
      web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
      lease?.release(); lease = nil
    }
    func update(messages: [CodexMessage]) {
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
      action.navigationType == .other && action.request.url?.isFileURL == true ? .allow : .cancel
    }
  }
}
