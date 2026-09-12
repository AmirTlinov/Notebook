import SwiftUI
import NotebookCore

/// Both composers attach to the same draft and resource selection on the paired Mac.
struct NotebookChatAdditions: View {
  @Bindable var chat: NotebookChatController
  let canSend: Bool
  let send: () -> Void
  let steer: () -> Void
  @State private var adding: Addition?
  private enum Addition: String, Identifiable { case files, plugins, skills, apps; var id: String { rawValue } }
  var body: some View {
    Menu {
      Section("Добавить к сообщению") {
        Button("Файлы и папки", systemImage: "paperclip") { adding = .files }
          .accessibilityIdentifier("notebook-chat-add-files")
        Button("Плагины", systemImage: "puzzlepiece.extension") { adding = .plugins }
        Button("Навыки", systemImage: "sparkles") { adding = .skills }
        Button("Приложения", systemImage: "square.stack.3d.up") { adding = .apps }
      }
      Section("Команды") {
        Button("Проверить изменения", systemImage: "doc.text.magnifyingglass") {
          chat.draft += (chat.draft.isEmpty ? "" : "\n") + "Проверь изменения в проекте: найди ошибки и объясни важные замечания."
        }
        Button("Сжать контекст", systemImage: "arrow.down.right.and.arrow.up.left") { Task { await chat.compactContext() } }
          .disabled(chat.conversation?.ready != true || chat.conversation?.busy != false || !chat.connected)
        if chat.conversation?.activeTurnID != nil {
          Button("Уточнить текущий ход", systemImage: "arrow.turn.down.right", action: steer)
            .disabled(!canSend).accessibilityIdentifier("notebook-chat-steer")
          Button("Отправить после ответа", systemImage: "text.badge.plus", action: send).disabled(!canSend)
        }
      }
    } label: { Image(systemName: "plus").font(.system(size: 19)).frame(width: 44, height: 44).contentShape(Rectangle()) }
      .accessibilityLabel("Добавить файлы, плагины, навыки или команду").accessibilityIdentifier("notebook-chat-actions")
    .onChange(of: chat.computerID) { adding = nil }
    .onChange(of: chat.threadID) { adding = nil }
    .popover(item: $adding) { selection in
      NavigationStack {
        Group {
          if selection == .files { NotebookChatFileAttachments(chat: chat) { adding = nil } }
          else if let kind = CodexResourceKind(rawValue: selection.rawValue) { NotebookChatResources(chat: chat, kind: kind) { adding = nil } }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { adding = nil } } }
      }.frame(width: 340, height: 420).presentationCompactAdaptation(.popover)
    }
  }
}

/// Native attachment names stay inspectable and removable in either composer.
struct NotebookChatAttachmentChips: View {
  let chat: NotebookChatController
  var body: some View {
      if !chat.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            ForEach(chat.attachments) { item in
              Button { chat.removeAttachment(item.id) } label: {
                HStack(spacing: 5) { Image(systemName: item.icon); Text(item.name).lineLimit(1); Image(systemName: "xmark").font(.system(size: 9)) }
                  .font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                  .background(Color(.secondarySystemBackground), in: Capsule())
              }.accessibilityLabel("Убрать «" + item.name + "»").accessibilityIdentifier("notebook-chat-attachment-" + item.name)
            }
          }.padding(.horizontal, 10).padding(.top, 6)
        }.scrollIndicators(.hidden)
      }
  }
}
