import Foundation
import NotebookCore

/// A composer keeps the physical address of its own question. Receiving an
/// answer changes neither first responder nor the current camera/selection.
struct NotebookAgentQuestion: Equatable, Sendable, Identifiable {
  let contextID: UUID
  let entryID: UUID
  let references: [CollaborationReference]
  var id: UUID { contextID }
}

import SwiftUI

struct NotebookAgentQuestionCard: View {
  @Environment(NotebookAppModel.self) private var model
  let question: NotebookAgentQuestion
  @State private var text = ""
  @FocusState private var isEditing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Закреплённый фрагмент").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Text(question.references.first?.label.isEmpty == false ? question.references[0].label : "Выделенная область")
            .font(.callout.weight(.medium)).lineLimit(2)
          if question.references.count > 1 {
            Text("Владельцев: \(question.references.count)").font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Button { model.dismissAgentQuestion() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
          .accessibilityLabel("Скрыть карточку вопроса").accessibilityIdentifier("agent-question-dismiss")
      }
      if let request = model.currentAgentRequest {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label(status(request), systemImage: statusIcon(request)).font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            if request.status == .queued || request.status == .running {
              Button("Остановить") { Task { await model.stopAgentRequest(request.id) } }
                .frame(minHeight: 44).accessibilityIdentifier("agent-question-stop")
            }
          }
          if !request.responseText.isEmpty {
            ScrollView { Text(request.responseText).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
              .frame(maxHeight: 180).accessibilityIdentifier("agent-question-response")
          }
          if let error = request.execution?.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
          }
          if let id = request.execution?.receiptIDs.last {
            Button("Отменить изменение") { model.undoCollaboration(id) }
              .frame(minHeight: 44).accessibilityIdentifier("agent-question-undo")
          }
        }
      }
      TextField("Вопрос или просьба об этом фрагменте", text: $text, axis: .vertical)
        .lineLimit(2...5).textFieldStyle(.roundedBorder).focused($isEditing)
        .accessibilityIdentifier("agent-question-text")
      HStack(spacing: 12) {
        Button("Спросить") { send(.question) }.accessibilityIdentifier("agent-question-ask")
        Button("Попросить сделать") { send(.change) }.accessibilityIdentifier("agent-question-change")
      }.buttonStyle(.bordered).controlSize(.large)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSavingAgentQuestion)
      if model.isSavingAgentQuestion {
        ProgressView("Подготовка и сохранение выделения").font(.caption)
      }
      Text("«Спросить» — без изменений. Просьба меняет только этот фрагмент, с отменой.")
        .font(.caption2).foregroundStyle(.secondary)
      if let error = model.agentRequestError { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent-question-card")
    .task(id: "\(model.workspaceHeader?.cursor ?? 0)|\(question.contextID)") { await model.refreshAgentRequests() }
  }

  private func send(_ mode: RequestGrant.Mode) {
    let submitted = text
    isEditing = false
    Task {
      if await model.sendAgentQuestion(submitted, mode: mode, question: question), text == submitted { text = "" }
    }
  }
  private func status(_ request: AgentRequestSnapshot) -> String {
    switch request.status {
    case .queued: model.isPeerConnected ? "Сохранено · ожидается агент на Mac" : "Сохранено на iPad · ждёт Mac"
    case .running: "Агент рассматривает фрагмент"
    case .stopping: "Остановка запрошена · ждём подтверждения"
    case .completed: request.execution?.receiptIDs.isEmpty == false ? "Изменение сохранено" : "Ответ получен"
    case .stopped: "Остановка подтверждена"
    case .failed: "Запрос не завершён"
    }
  }
  private func statusIcon(_ request: AgentRequestSnapshot) -> String {
    switch request.status {
    case .queued: "clock"
    case .running: "bubble.left"
    case .stopping: "hourglass"
    case .completed: "checkmark.circle"
    case .stopped: "stop.circle"
    case .failed: "exclamationmark.triangle"
    }
  }
}
