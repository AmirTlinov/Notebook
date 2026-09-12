import SwiftUI
import NotebookCore

/// A bounded part of the floating window. It reads the same conversation and
/// draft as the expanded panel; only its launcher accepts a window drag.
struct NotebookCollapsedChat: View {
  @Environment(NotebookAppModel.self) private var model
  @Bindable var chat: NotebookChatController
  let size: CGSize
  let move: (CGSize, Bool) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false
  @State private var voiceSettings = false

  static func preferredSize(chat: NotebookChatController, available: CGSize) -> CGSize {
    let hasBody = chat.replyCloud != nil || chat.conversation?.requests.isEmpty == false || chat.compactDraftExpanded || chat.voice.error != nil
    let hasVoice = chat.voice.capturing
    let messageHeight = chat.replyCloud.map { min(158, 54 + CGFloat(($0.text.count + 39) / 40) * 19) } ?? 0
    let body: CGFloat = chat.conversation?.requests.isEmpty == false ? 210 : chat.compactDraftExpanded ? 160 : messageHeight
    let height: CGFloat = 48 + (hasVoice ? 70 : 0) + (!chat.draft.isEmpty && !chat.compactDraftExpanded ? 36 : 0)
      + body + (chat.voice.error != nil ? 95 : 0)
    return .init(width: min(available.width, hasBody || hasVoice ? 340 : (chat.runs.record?.isActive == true ? 288 : 244)),
      height: min(available.height, max(hasVoice ? 118 : 48, min(height, available.height * 0.42))))
  }
  var body: some View {
    VStack(spacing: 0) {
      if chat.conversation?.requests.isEmpty == false || chat.replyCloud != nil || chat.compactDraftExpanded || chat.voice.error != nil {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if let conversation = chat.conversation, let request = conversation.requests.first {
              NotebookCodexRequestView(request: request, threadID: conversation.threadID, chat: chat, maximumHeight: max(100, size.height - 72))
                .id(request.id)
            } else if chat.compactDraftExpanded {
              draft
            } else if let message = chat.replyCloud {
              cloud(message)
            }
            if let error = chat.voice.error {
              HStack(alignment: .top, spacing: 0) {
                Text(error).font(.caption).foregroundStyle(.secondary)
                  .accessibilityIdentifier("notebook-compact-voice-error")
                Button { chat.voice.dismissError() } label: { Image(systemName: "xmark").frame(width: 36, height: 36).contentShape(Rectangle()) }
                  .accessibilityLabel("Убрать уведомление о голосе")
              }
            }
          }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        }.scrollBounceBehavior(.basedOnSize)
      }
      if chat.voice.capturing {
        VStack(spacing: 0) {
          Text(chat.voice.taskTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
          NotebookVoiceControls(voice: chat.voice)
        }.accessibilityIdentifier("notebook-compact-voice")
      }
      if !chat.draft.isEmpty, !chat.compactDraftExpanded {
        Button { chat.compactDraftExpanded = true } label: {
          Label("Черновик · " + String(chat.draft.prefix(60)), systemImage: "pencil")
            .font(.caption).lineLimit(1).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }.padding(.horizontal, 14).accessibilityIdentifier("notebook-compact-draft-preview")
      }
      HStack(spacing: 0) {
        Button { chat.revealReply() } label: {
          HStack(spacing: 5) {
            Image(systemName: chat.conversation?.requests.isEmpty == false ? "questionmark.bubble" : "bubble.left.and.bubble.right")
            Text("Чат")
            if !chat.unreadReplies.isEmpty {
              Text("\(chat.unreadReplies.count)").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
            } else if chat.conversation?.busy == true { ProgressView().controlSize(.mini) }
          }.font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(chat.unreadReplies.isEmpty ? "Открыть чат" : "Открыть чат, непрочитанных ответов: \(chat.unreadReplies.count)")
        .accessibilityIdentifier("notebook-chat-toggle")
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("notebook-window"))
          .updating($moving) { _, state, _ in state = true }
          .onChanged { move($0.translation, false) }.onEnded { move($0.translation, true) })
        Button { chat.compactDraftExpanded.toggle() } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 48).contentShape(Rectangle()) }
          .accessibilityLabel(chat.compactDraftExpanded ? "Свернуть черновик" : "Написать без раскрытия чата")
          .accessibilityIdentifier("notebook-compact-edit")
          .disabled(chat.threadID == nil || chat.browsesChats)
        Button { chat.voice.explainDictation(); chat.compactDraftExpanded = !chat.draft.isEmpty } label: {
          Image(systemName: "mic").frame(width: 44, height: 48).contentShape(Rectangle())
        }.accessibilityLabel("Голосовой ввод Codex").accessibilityIdentifier("notebook-compact-dictation")
          .disabled(chat.voice.capturing)
        Button { voiceSettings = true } label: {
          Image(systemName: chat.voice.phase == .waiting ? "ear.badge.waveform" : "waveform")
            .foregroundStyle(chat.voice.capturing && !chat.voice.muted ? Color.green : Color.primary).frame(width: 44, height: 48).contentShape(Rectangle())
        }.accessibilityLabel("Голос над доской").accessibilityIdentifier("notebook-compact-voice-settings")
        if chat.runs.record?.isActive == true {
          Button { chat.expanded = true; chat.files.showTerminal(true) } label: {
            Image(systemName: "terminal").overlay(alignment: .topTrailing) { Circle().fill(.green).frame(width: 5, height: 5).offset(x: 4, y: -3) }
              .frame(width: 44, height: 48).contentShape(Rectangle())
          }.accessibilityLabel("Открыть работающий терминал").accessibilityIdentifier("notebook-compact-terminal")
        }
      }.padding(.horizontal, 4)
    }
    .popover(isPresented: $voiceSettings) {
      NotebookVoiceSettings(voice: chat.voice, task: chat.taskTitle, canStart: chat.connected && chat.threadID != nil && !chat.browsesChats) { voiceSettings = false }
        .presentationCompactAdaptation(.popover)
    }
    .onChange(of: moving) { if !moving { endInteraction() } }
  }
  private func cloud(_ message: CodexMessage) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(chat.taskTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 0)
        Button { chat.hideReplyCloud() } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 36).contentShape(Rectangle()) }
          .accessibilityLabel("Убрать тучку, сохранив ответ").accessibilityIdentifier("notebook-reply-dismiss")
      }
      Button { chat.revealReply(message.id) } label: {
        Text(String(message.text.prefix(1000))).font(.system(size: 15)).lineLimit(5)
          .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
      }.accessibilityLabel("Открыть полный ответ: " + String(message.text.prefix(240)))
        .accessibilityIdentifier("notebook-reply-cloud")
    }
  }
  private var draft: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(chat.taskTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      TextField("Сообщение GPT", text: $chat.draft, axis: .vertical)
        .lineLimit(2...4).font(.system(size: 15)).accessibilityIdentifier("notebook-compact-draft")
      HStack {
        Button { chat.draft = ""; chat.compactDraftExpanded = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Отменить черновик")
        Spacer(minLength: 0)
        if chat.saving || model.isSavingAgentQuestion { ProgressView().controlSize(.small) }
        if let turn = chat.conversation?.activeTurnID, let thread = chat.threadID {
          Button { Task { await chat.stopTurn(threadID: thread, turnID: turn) } } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("Остановить ответ")
        } else {
          Button { model.sendChatMessage() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 27)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.saving || model.isSavingAgentQuestion || chat.continuationUnavailable || chat.threadID == nil)
            .accessibilityLabel("Отправить черновик").accessibilityIdentifier("notebook-compact-send")
        }
      }
      if !chat.pendingMessages.isEmpty {
        Text("Сохранено на iPad · ожидается подтверждение Codex").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}

private struct NotebookVoiceSettings: View {
  @Bindable var voice: NotebookVoiceController
  let task: String
  let canStart: Bool
  let close: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("GPT над доской").font(.headline)
        Spacer()
        Button("Готово", action: close)
      }
      Text(voice.capturing ? voice.taskTitle : task).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Picker("Способ общения", selection: $voice.method) {
        ForEach(NotebookVoiceController.Method.allCases, id: \.rawValue) { Text($0.label).tag($0) }
      }.pickerStyle(.menu).disabled(voice.capturing).accessibilityIdentifier("notebook-voice-method")
      if !canStart && !voice.capturing { Text("Выберите разговор и подключите Mac.").font(.caption).foregroundStyle(.secondary) }
      if voice.method == .dictation {
        Text(NotebookVoiceController.dictationUnavailable).font(.callout).foregroundStyle(.secondary)
      } else {
        Picker("Язык обращения", selection: $voice.language) {
          ForEach(NotebookWakeRecognizer.languages, id: \.self) { language in
            Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(language)
          }
        }.disabled(voice.capturing)
        TextField("Местное обращение перед GPT", text: $voice.address).textFieldStyle(.roundedBorder).disabled(voice.capturing)
        Text("\(voice.address.isEmpty ? "GPT" : voice.address + ", GPT") · или просто GPT. Просьбу можно произнести сразу после имени.")
          .font(.caption).foregroundStyle(.secondary)
        if voice.capturing { NotebookVoiceControls(voice: voice) }
        else {
          Button("Ожидать обращения", systemImage: "ear.badge.waveform") { close(); Task { await voice.arm() } }
            .frame(minHeight: 44).disabled(!canStart).accessibilityIdentifier("notebook-voice-arm")
          Button("Начать разговор сейчас", systemImage: "waveform") { close(); Task { await voice.begin() } }
            .frame(minHeight: 44).disabled(!canStart)
        }
        Text("До обращения звук остаётся на iPad. Ожидание выключается вместе с микрофоном или при уходе из Notebook.")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }.padding(20).frame(width: 330)
  }
}
