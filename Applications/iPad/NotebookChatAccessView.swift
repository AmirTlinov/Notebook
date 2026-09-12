import SwiftUI
import NotebookCore

struct NotebookChatAccessView: View {
  let chat: NotebookChatController
  @State private var fullAccessThread: String?
  var body: some View {
    if let thread = chat.threadID, !chat.browsesChats {
      Menu {
        Section("Доступ этой задачи") {
          ForEach(CodexAccessMode.allCases, id: \.rawValue) { mode in
            Button {
              if mode == .full { fullAccessThread = thread }
              else { Task { await chat.setAccess(mode, thread: thread) } }
            } label: {
              Label(mode.title, systemImage: chat.conversation?.access?.mode == mode ? "checkmark" : mode.icon)
            }.disabled(chat.conversation?.access?.available.contains(mode) != true)
          }
        }
      } label: {
        Group {
          if chat.accessChangePending { ProgressView().controlSize(.mini) }
          else { Image(systemName: chat.conversation?.access?.mode?.icon ?? "shield") }
        }
        .font(.system(size: 15)).frame(width: 32, height: 44).contentShape(Rectangle())
        .foregroundStyle(chat.conversation?.access?.mode == .full ? Color.orange : Color.secondary)
      }
      .disabled(!chat.connected || chat.continuationUnavailable || chat.saving)
      .accessibilityLabel("Уровень доступа Codex: " + (chat.conversation?.access?.mode?.title ?? "Свой профиль"))
      .accessibilityIdentifier("notebook-chat-access")
      .confirmationDialog("Полный доступ для этой задачи", isPresented: Binding(get: { fullAccessThread != nil }, set: { if !$0 { fullAccessThread = nil } }), presenting: fullAccessThread) { target in
        Button("Включить полный доступ", role: .destructive) {
          Task { await chat.setAccess(.full, thread: target) }
          fullAccessThread = nil
        }
        Button("Отмена", role: .cancel) { fullAccessThread = nil }
      } message: { _ in
        Text("Codex сможет изменять файлы за пределами проекта и обращаться к сети без подтверждения команд. Режим действует со следующего хода только в этой задаче; текущие запросы инструментов решаются отдельно.")
      }
    }
  }
}

private extension CodexAccessMode {
  var title: String { switch self { case .readOnly: "Только чтение"; case .workspace: "В пределах проекта"; case .full: "Полный доступ" } }
  var icon: String { switch self { case .readOnly: "shield"; case .workspace: "checkmark.shield"; case .full: "exclamationmark.shield" } }
}
