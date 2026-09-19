import SwiftUI
import NotebookCore

/// One full, generation-bound question at a time. Other questions stay with
/// Codex and are fetched by native ID, never stored as a second approval queue.
struct NotebookCodexRequestsView: View {
  let conversation: CodexConversation
  let job: (CodexUserRequest) -> NotebookChatJob?
  let query: (NotebookChatQuery) async throws -> NotebookChatReply
  let respond: (CodexUserRequest, CodexUserDecision) async -> Void
  let maximumHeight: CGFloat
  @State private var selectedID: String?
  @State private var detail: CodexUserRequest?
  @State private var failure: String?
  @State private var retry = UUID()
  private var requestID: String? {
    selectedID.flatMap { conversation.requestIDs.contains($0) ? $0 : nil } ?? conversation.requestIDs.first
  }
  private var request: CodexUserRequest? {
    let value = conversation.requests.first { $0.id == requestID } ?? detail
    return value?.id == requestID && value?.generation == conversation.generation ? value : nil
  }
  var body: some View {
    if let requestID {
      VStack(spacing: 4) {
        if conversation.requestIDs.count > 1 {
          Picker("Ожидают решения", selection: Binding(get: { requestID }, set: { selectedID = $0 })) {
            ForEach(Array(conversation.requestIDs.enumerated()), id: \.element) { index, id in
              Text("Запрос \(index + 1) из \(conversation.requestIDs.count)").tag(id)
            }
          }.accessibilityIdentifier("notebook-codex-requests")
        }
        if let request {
          NotebookCodexRequestView(request: request, job: job(request), respond: { await respond(request, $0) }, maximumHeight: maximumHeight)
            .id(conversation.generation.uuidString + request.id)
        } else if let failure {
          Text(failure).font(.caption)
          Button("Повторить чтение запроса") { retry = UUID() }
        } else { ProgressView("Читаю полный запрос…") }
      }
      .task(id: conversation.generation.uuidString + requestID + retry.uuidString) {
        failure = nil
        guard request == nil else { return }
        do {
          guard case .requestDetails(let value) = try await query(.requestDetails(threadID: conversation.threadID, generation: conversation.generation, requestID: requestID)),
            value.id == requestID, value.generation == conversation.generation else { throw NotebookTransportError.invalidAcknowledgement }
          guard !Task.isCancelled else { return }; detail = value
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
      }
    }
  }
}

struct NotebookCodexRequestView: View {
  struct Questions: Decodable { let questions: [Question] }
  struct Question: Decodable, Identifiable {
    struct Option: Decodable { let label: String; let description: String? }
    let id: String; let question: String; let options: [Option]?
  }
  let request: CodexUserRequest
  let job: NotebookChatJob?
  let respond: (CodexUserDecision) async -> Void
  let maximumHeight: CGFloat
  @State private var answers: [String: String] = [:]
  @State private var submitted = false
  @State private var contentHeight: CGFloat?
  @State private var showsDetails = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if request.method == "item/tool/requestUserInput", let questions {
          Text(title).font(.system(size: 13, weight: .medium))
          ForEach(questions.questions) { question in
            Text(question.question).font(.system(size: 14))
            if let options = question.options {
              ForEach(options, id: \.label) { option in
                Button { answers[question.id] = option.label } label: {
                  Label(option.label, systemImage: answers[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).frame(minHeight: 36, alignment: .leading)
                }
                if answers[question.id] == option.label, let description = option.description {
                  Text(description).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            TextField("Ваш ответ", text: Binding(get: { answers[question.id, default: ""] }, set: { answers[question.id] = $0 }), axis: .vertical)
              .textFieldStyle(.roundedBorder)
          }
          Button("Ответить") { decide(.answers(answers.mapValues { [$0] })) }
            .buttonStyle(.borderedProminent)
            .disabled(questions.questions.contains { answers[$0.id, default: ""].isEmpty })
        } else {
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
              Text(title).font(.system(size: 13, weight: .medium))
              if let summary { Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { showsDetails.toggle() } label: {
              Image(systemName: showsDetails ? "chevron.up" : "ellipsis")
                .font(.system(size: 13)).frame(width: 32, height: 32).contentShape(Rectangle())
            }.accessibilityLabel(showsDetails ? "Скрыть подробности запроса" : "Подробности запроса")
          }
          if let command = string(request.parameters["command"]) {
            Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(2)
          }
          if !request.approvalDecisions.isEmpty {
            HStack(spacing: 6) {
              if request.approvalDecisions.contains(.allowOnce) {
                Button("Разрешить") { decide(.allowOnce) }.buttonStyle(.borderedProminent)
                  .accessibilityIdentifier("notebook-approval-once")
              }
              if request.approvalDecisions.contains(.allowSession) || request.approvalDecisions.contains(.allowAlways) {
                Menu {
                  if request.approvalDecisions.contains(.allowSession) {
                    Button("Разрешить на весь чат") { decide(.allowSession) }
                  }
                  if request.approvalDecisions.contains(.allowAlways) {
                    Button("Всегда разрешать этот инструмент") { decide(.allowAlways) }
                  }
                } label: {
                  Image(systemName: "chevron.down").font(.system(size: 11)).frame(width: 32, height: 32).contentShape(Rectangle())
                }.accessibilityLabel("Запомнить доступ").accessibilityIdentifier("notebook-approval-remember")
              }
              Spacer(minLength: 8)
              if request.approvalDecisions.contains(.decline) {
                Button("Отказать") { decide(.decline) }.frame(minHeight: 32)
                  .accessibilityIdentifier("notebook-approval-decline")
              }
            }.font(.system(size: 13)).controlSize(.small)
          } else if request.method == "mcpServer/elicitation/request" {
            Text("Эта форма требует дополнительных данных. Форма этого инструмента пока не поддерживается. Можно отказать или остановить задачу.")
              .font(.caption).foregroundStyle(.secondary)
            Button("Отказать") { decide(.elicitation(.object(["action": .string("decline")]))) }
          } else { Text("Этот тип запроса пока не поддерживается. Можно остановить задачу.").font(.caption).foregroundStyle(.secondary) }
          if showsDetails {
            Text(parameters).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if let job {
          Text(job.error ?? (job.state == .accepted ? "Решение принято Codex" : "Решение сохранено · ожидается Codex"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .disabled(submitted || job != nil)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
      .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
    }
    .frame(height: min(maximumHeight, contentHeight ?? maximumHeight))
    .scrollBounceBehavior(.basedOnSize)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-codex-request")
  }
  private var title: String {
    switch request.method {
    case "item/tool/requestUserInput": "Нужен ваш ответ"
    case "item/commandExecution/requestApproval": "Запустить команду?"
    case "item/fileChange/requestApproval": "Разрешить изменение файлов?"
    case "item/permissions/requestApproval": "Расширить доступ?"
    default: "Доступ к " + (string(request.parameters["serverName"]) ?? "инструменту")
    }
  }
  private var summary: String? {
    string(request.parameters["reason"]) ?? string(request.parameters["_meta"]?["tool_title"]) ?? string(request.parameters["message"])
  }
  private func string(_ value: JSONValue?) -> String? { if case .string(let text) = value { return text }; return nil }
  private var questions: Questions? { try? JSONDecoder().decode(Questions.self, from: JSONEncoder().encode(request.parameters)) }
  private var parameters: String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? String(decoding: encoder.encode(request.parameters), as: UTF8.self)) ?? request.method
  }
  private func decide(_ decision: CodexUserDecision) {
    submitted = true
    Task { await respond(decision); submitted = false }
  }
}

/// Ending observation is not cancellation or proof that the native action failed.
struct NotebookCodexUncertainJobsView: View {
  let jobs: [NotebookChatJob]
  let finish: (UUID) async -> Void
  @State private var selected: NotebookChatJob?
  var body: some View {
    let uncertain = jobs.filter { $0.state == .uncertain }
    if !uncertain.isEmpty {
      Menu("Неизвестный исход · \(uncertain.count)") {
        ForEach(uncertain) { job in
          Button(label(job)) { selected = job }
        }
      }
      .font(.caption).accessibilityIdentifier("notebook-codex-uncertain")
      .confirmationDialog("Завершить ожидание?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
        if let selected { Button("Завершить ожидание") { Task { await finish(selected.id) }; self.selected = nil } }
        Button("Продолжить ждать", role: .cancel) { selected = nil }
      } message: {
        Text("Это не остановит действие и не означает, что оно не выполнилось. Исход останется неизвестным; автоматического повтора не будет.")
      }
    }
  }
  private func label(_ job: NotebookChatJob) -> String {
    let name: String
    switch job.input.action {
    case .send(_, let text, _), .steer(_, _, let text, _): name = String(text.prefix(60))
    case .create: name = "Создание задачи"
    case .setAccess: name = "Изменение доступа"
    case .setModel: name = "Изменение модели"
    case .stop, .stopRun, .stopVoice: name = "Остановка"
    case .respond: name = "Ответ на разрешение"
    default: name = "Действие Codex"
    }
    return job.input.createdAt.formatted(date: .omitted, time: .shortened) + " · " + name
  }
}
