import SwiftUI
import NotebookCore

/// Text and tools have separate rows. Narrow windows reflow controls instead of hiding voice input.
struct NotebookChatComposer: View {
  @Bindable var chat: NotebookChatController
  let width: CGFloat
  let canSend: Bool
  let saving: Bool
  let send: () -> Void
  let steer: () -> Void
  @State private var adding: Addition?
  private enum Addition: String, Identifiable { case files, plugins, skills, apps; var id: String { rawValue } }
  private var hasThread: Bool { chat.threadID != nil && !chat.browsesChats }
  var body: some View {
    VStack(spacing: 0) {
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
      TextField("Сообщение Codex", text: $chat.draft, axis: .vertical)
        .font(.system(size: 15)).lineLimit(1...5).textFieldStyle(.plain)
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
        .accessibilityIdentifier("notebook-chat-text")
      if width < 320, hasThread {
        HStack(spacing: 0) {
          additions
          NotebookChatAccessView(chat: chat)
          NotebookChatModelControl(chat: chat)
          Spacer(minLength: 0)
        }
        HStack(spacing: 0) { savingIndicator; Spacer(minLength: 0); voiceAndSend }
      } else {
        HStack(spacing: 0) {
          additions
          NotebookChatAccessView(chat: chat)
          if hasThread { NotebookChatModelControl(chat: chat) }
          Spacer(minLength: 0)
          savingIndicator
          voiceAndSend
        }
      }
    }
    .padding(3)
    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22))
    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5).allowsHitTesting(false) }
    .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
    .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-chat-composer")
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
  private var additions: some View {
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
  }
  @ViewBuilder private var savingIndicator: some View {
    if saving { ProgressView().controlSize(.mini).frame(width: 20, height: 44) }
  }
  private var voiceAndSend: some View {
    HStack(spacing: 0) {
      Button { chat.voice.explainDictation() } label: {
        Image(systemName: "mic").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("Голосовой ввод Codex").accessibilityValue("Пока недоступен")
        .accessibilityHint("Показать причину недоступности диктовки в черновик").accessibilityIdentifier("notebook-chat-dictation")
      Button { Task { await chat.voice.begin() } } label: {
        Image(systemName: "waveform").font(.system(size: 16)).frame(width: 44, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("Голосовой разговор с Codex").accessibilityIdentifier("notebook-chat-voice")
        .disabled(chat.voice.activeID != nil || !chat.connected || !hasThread)
      if hasThread, let conversation = chat.conversation, conversation.busy || conversation.activeTurnID != nil {
        Button {
          if let turn = conversation.activeTurnID { Task { await chat.stopTurn(threadID: conversation.threadID, turnID: turn) } }
        } label: { action("stop.fill", enabled: true) }
          .disabled(conversation.activeTurnID == nil || chat.saving)
          .accessibilityLabel("Остановить ответ").accessibilityIdentifier("notebook-chat-stop")
      } else {
        Button(action: send) { action("arrow.up", enabled: canSend) }
          .disabled(!canSend).accessibilityLabel("Отправить сообщение").accessibilityIdentifier("notebook-chat-send")
      }
    }.fixedSize(horizontal: true, vertical: false)
  }
  private func action(_ symbol: String, enabled: Bool) -> some View {
    Image(systemName: symbol).font(.system(size: symbol == "stop.fill" ? 11 : 15, weight: .medium))
      .foregroundStyle(.white).frame(width: 30, height: 30)
      .background(enabled ? Color(.label) : Color(.systemGray), in: Circle())
      .frame(width: 44, height: 44).contentShape(Rectangle())
  }
}

extension CodexInputAttachment {
  var icon: String { switch kind { case .file: "doc.text"; case .folder: "folder"; case .skill: "sparkles"; case .plugin: "puzzlepiece.extension"; case .app: "square.stack.3d.up" } }
}
