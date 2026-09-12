import SwiftUI
import NotebookCore

struct NotebookChatModelControl: View {
  let chat: NotebookChatController
  var compact = false
  @State private var settings = false
  @State private var context = false
  private var selected: CodexModelOption? { chat.models.first { $0.id == chat.conversation?.model?.model } }
  var body: some View {
    HStack(spacing: 0) {
      Button { context = true } label: {
        ZStack {
          Circle().stroke(Color(.systemGray4), lineWidth: 2)
          if let fraction = chat.conversation?.contextUsage?.fraction {
            Circle().trim(from: 0, to: fraction).stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
          } else { Text("?").font(.system(size: 8)) }
        }.frame(width: 12, height: 12).frame(width: 32, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("Контекстное окно").accessibilityValue(usageText).accessibilityIdentifier("notebook-chat-context")
        .popover(isPresented: $context) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Контекстное окно").font(.headline)
            Text(usageText).font(.subheadline).textSelection(.enabled)
            if !chat.connected { Text("Последние данные Codex · Mac не в сети").font(.caption).foregroundStyle(.secondary) }
          }.padding(16).frame(width: 285).presentationCompactAdaptation(.popover)
        }
      Button { settings = true } label: {
        HStack(spacing: 4) {
          if compact {
            Image(systemName: "cpu").font(.system(size: 15))
          } else {
            Text((selected?.name ?? chat.conversation?.model?.model ?? "Модель") + " · " + effortTitle(chat.conversation?.model?.effort))
              .lineLimit(1)
          }
          if chat.modelChangePending { ProgressView().controlSize(.mini) }
          else { Image(systemName: "chevron.down").font(.system(size: 8)) }
        }.font(.system(size: 12)).frame(minWidth: compact ? 36 : 60, minHeight: 44, alignment: .trailing).contentShape(Rectangle())
      }.accessibilityLabel("Модель и мышление").accessibilityValue((selected?.name ?? chat.conversation?.model?.model ?? "Неизвестна") + " · " + effortTitle(chat.conversation?.model?.effort)).accessibilityIdentifier("notebook-chat-model")
        .popover(isPresented: $settings) {
          VStack(alignment: .leading, spacing: 12) {
            if let thread = chat.threadID {
              Menu {
                ForEach(chat.models) { option in
                  Button { Task { await chat.setModel(.init(model: option.id, effort: option.defaultEffort), thread: thread) } } label: {
                    Label(option.name + (option.isDefault ? " · по умолчанию" : ""), systemImage: option.id == chat.conversation?.model?.model ? "checkmark" : "cpu")
                  }
                }
              } label: {
                HStack { Text(selected?.name ?? "Выбрать модель"); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                  .frame(minHeight: 44)
              }.accessibilityIdentifier("notebook-chat-model-picker")
              if let selected {
                Menu {
                  ForEach(selected.efforts, id: \.self) { effort in
                    Button { Task { await chat.setModel(.init(model: selected.id, effort: effort), thread: thread) } } label: {
                      Label(effortTitle(effort), systemImage: effort == chat.conversation?.model?.effort ? "checkmark" : "brain")
                    }
                  }
                } label: {
                  HStack { Label("Мышление", systemImage: "brain"); Spacer(); Text(effortTitle(chat.conversation?.model?.effort)); Image(systemName: "chevron.up.chevron.down") }.frame(minHeight: 44)
                }.accessibilityIdentifier("notebook-chat-effort-picker")
              }
              Text(chat.modelChangePending ? "Ожидается подтверждение Codex…" : "Для следующих ходов этой задачи. Текущий ответ не прерывается.")
                .font(.caption).foregroundStyle(.secondary)
            }
            if chat.loadingModels { ProgressView() }
            if let error = chat.modelError { Text(error).font(.caption).foregroundStyle(.secondary) }
          }.padding(16).frame(width: 300).presentationCompactAdaptation(.popover)
            .disabled(!chat.connected || (chat.modelChangePending && !chat.modelChangeUncertain) || chat.continuationUnavailable)
            .task { await chat.readModels() }
        }
    }.fixedSize(horizontal: true, vertical: false)
    .task(id: "\(chat.computerID?.uuidString ?? "")/\(chat.connected)") { if chat.connected { await chat.readModels() } }
  }
  private var usageText: String {
    guard let usage = chat.conversation?.contextUsage else { return "Codex ещё не передал размер контекста." }
    let used = usage.used.formatted(.number.locale(Locale(identifier: "ru_RU")))
    guard let window = usage.window, let fraction = usage.fraction else { return "Использовано \(used) токенов · размер окна пока неизвестен" }
    return "\(Int((fraction * 100).rounded()))% заполнено\nИспользовано \(used) / \(window.formatted(.number.locale(Locale(identifier: "ru_RU")))) токенов"
  }
  private func effortTitle(_ value: String?) -> String {
    switch value {
    case "none": "Без рассуждений"; case "minimal": "Минимум"; case "low": "Низкое"; case "medium": "Среднее"
    case "high": "Высокое"; case "xhigh": "Очень высокое"; case "max": "Макс."; case "ultra": "Ультра"
    default: value ?? "По умолчанию"
    }
  }
}
