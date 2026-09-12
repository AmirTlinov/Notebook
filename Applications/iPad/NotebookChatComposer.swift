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
  private var hasThread: Bool { chat.threadID != nil && !chat.browsesChats }
  var body: some View {
    VStack(spacing: 0) {
      NotebookChatAttachmentChips(chat: chat)
      TextField("Сообщение Codex", text: $chat.draft, axis: .vertical)
        .font(.system(size: 15)).lineLimit(1...5).textFieldStyle(.plain)
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
        .accessibilityIdentifier("notebook-chat-text")
      if width < 300 {
        HStack(spacing: 0) {
          additions
          NotebookContextCounter()
          NotebookChatAccessView(chat: chat)
          Spacer(minLength: 0)
          if hasThread { NotebookChatModelControl(chat: chat, compact: true) }
        }
        HStack(spacing: 0) { Spacer(minLength: 0); savingIndicator; voiceAndSend }
      } else {
        HStack(spacing: 0) {
          additions
          NotebookContextCounter()
          NotebookChatAccessView(chat: chat)
          Spacer(minLength: 0)
          savingIndicator
          if hasThread { NotebookChatModelControl(chat: chat, compact: width < 450) }
          voiceAndSend
        }
      }
    }
    .padding(3)
    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 22))
    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5).allowsHitTesting(false) }
    .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
    .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-chat-composer")
  }
  private var additions: some View {
    NotebookChatAdditions(chat: chat, canSend: canSend, send: send, steer: steer)
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
        .disabled(chat.voice.capturing || !chat.connected || !hasThread)
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
