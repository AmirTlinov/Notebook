import SwiftUI
import NotebookCore

struct NotebookCodexRequestView: View {
  struct Questions: Decodable { let questions: [Question] }
  struct Question: Decodable, Identifiable {
    struct Option: Decodable { let label: String; let description: String? }
    let id: String; let question: String; let options: [Option]?
  }
  let request: CodexUserRequest
  let threadID: String
  let chat: NotebookChatController
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
            Text("Эта форма требует дополнительных данных. Откройте её в Codex на Mac.")
              .font(.caption).foregroundStyle(.secondary)
            Button("Отказать") { decide(.elicitation(.object(["action": .string("decline")]))) }
          } else { Text("Этот запрос нужно обработать в Codex на Mac.").font(.caption).foregroundStyle(.secondary) }
          if showsDetails {
            Text(parameters).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if let job = chat.decisionJob(request, threadID: threadID) {
          Text(job.error ?? (job.state == .accepted ? "Решение принято Codex" : "Решение сохранено · ожидается Codex"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .disabled(submitted || chat.decisionJob(request, threadID: threadID) != nil)
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
    Task { await chat.respond(request, decision: decision, threadID: threadID); submitted = false }
  }
}
