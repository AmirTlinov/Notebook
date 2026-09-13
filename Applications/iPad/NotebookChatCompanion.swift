import SwiftUI
import UIKit
import NotebookCore

/// The small companion is another presentation of this task, not a voice bot
/// or another transcript. Its controls and card occupy only window space.
struct NotebookCompanion: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var chat: NotebookChatController
  let draftFocused: FocusState<Bool>.Binding
  let size: CGSize
  let move: (CGSize, Bool) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false
  @AppStorage("notebook.companion.show-task") private var showsTask = true

  static func preferredSize(chat: NotebookChatController, available: CGSize, showsTask: Bool, contextCount: Int = 0) -> CGSize {
    if chat.dictation.showsInput { return .init(width: min(available.width, 352), height: min(available.height, 48)) }
    let dictationNotice = chat.dictation.busy || chat.dictation.error != nil
    let hasCard = chat.companionExpanded || chat.conversation?.requests.isEmpty == false || chat.voice.error != nil || chat.voice.capturing
      || showsTask && (chat.workStatus != nil || !chat.unreadReplies.isEmpty || !chat.pendingMessages.isEmpty)
    let height: CGFloat = 48 + (hasCard ? 68 : 0) + (chat.companionExpanded ? 52 + (chat.attachments.isEmpty ? 0 : 38) : 0)
      + (chat.conversation?.requests.isEmpty == false ? 160 : 0) + (chat.voice.error != nil ? 90 : 0) + (dictationNotice ? 88 : 0)
      + (hasCard ? chat.companionReply.map { previewHeight($0, width: min(available.width, 352) - 28) + 8 } ?? 0 : 0)
    return .init(width: min(available.width, hasCard || dictationNotice ? 352 : (chat.voice.capturing ? 264 : 184) + (contextCount > 0 ? 28 : 0)),
      height: min(available.height, height))
  }
  private var needsDecision: Bool { chat.conversation?.requests.isEmpty == false }
  private var hasCard: Bool {
    chat.companionExpanded || needsDecision || chat.voice.error != nil || chat.voice.capturing
      || showsTask && (chat.workStatus != nil || !chat.unreadReplies.isEmpty || !chat.pendingMessages.isEmpty)
  }
  private var canSend: Bool {
    !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.saving && !chat.dictation.busy
      && !model.isSavingAgentQuestion && !model.selectionSession.isResolvingContext && !chat.continuationUnavailable && chat.threadID != nil && !chat.browsesChats
  }
  var body: some View {
    let reply = chat.companionReply
    VStack(alignment: .trailing, spacing: 8) {
      if chat.dictation.showsInput {
        NotebookDictationInput(chat: chat).background { surface(radius: 24) }
      } else {
      controls
      NotebookDictationStatus(dictation: chat.dictation)
        .frame(maxWidth: 320).background { surface(radius: 18) }
      if hasCard {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
            Button { chat.revealReply(reply?.id) } label: {
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(chat.voice.capturing ? chat.voice.taskTitle : chat.taskTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                  if reply == nil {
                    NotebookPearlText(text: status, active: chat.workStatus?.running == true && !chat.voice.capturing)
                      .font(.system(size: 13)).lineLimit(1)
                  } else if chat.unreadReplies.count > 1 {
                    Text("Ещё ответов: \(chat.unreadReplies.count - 1)").font(.system(size: 12)).foregroundStyle(.secondary)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)).foregroundStyle(.secondary)
              }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityLabel("Открыть переписку · " + chat.taskTitle + " · " + status)
              .accessibilityIdentifier("notebook-companion-task")
            if let reply = reply {
              Button { chat.dismissCompanionReply(reply.id) } label: {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(.secondary)
                  .frame(width: 36, height: 44).contentShape(Rectangle())
              }.accessibilityLabel("Убрать превью ответа").accessibilityIdentifier("notebook-companion-dismiss-reply")
            }
            }
            if let reply = reply {
              Button { chat.revealReply(reply.id) } label: {
                Text(Self.previewText(reply)).font(.system(size: 14)).foregroundStyle(.primary).lineLimit(6)
                  .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              }.accessibilityHint("Открыть полный ответ в этой переписке")
                .accessibilityIdentifier("notebook-companion-reply")
            }
            if let conversation = chat.conversation, let request = conversation.requests.first {
              NotebookCodexRequestView(request: request, threadID: conversation.threadID, chat: chat, maximumHeight: 160)
                .id(request.id)
            }
            if chat.companionExpanded { NotebookChatAttachmentChips(chat: chat); composer }
            if let error = chat.voice.error {
              HStack(alignment: .top) {
                Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("notebook-compact-voice-error")
                Button { chat.voice.dismissError() } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                  .accessibilityLabel("Убрать уведомление о голосе")
              }
            }
          }.padding(.horizontal, 14).padding(.vertical, 8)
        }.scrollBounceBehavior(.basedOnSize)
          .background { surface(radius: 22) }
      }
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.28), value: hasCard)
    .onChange(of: moving) { if !moving { endInteraction() } }
  }
  /// The compact surface measures the same bounded native text it displays;
  /// the full Markdown and native message identity remain in the transcript.
  private static func previewText(_ reply: CodexMessage) -> String {
    let text = String(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
    return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      .map { String($0.characters) } ?? text
  }
  private static func previewHeight(_ reply: CodexMessage, width: CGFloat) -> CGFloat {
    let font = UIFont.systemFont(ofSize: 14)
    let height = (previewText(reply) as NSString).boundingRect(with: .init(width: max(1, width), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
    return ceil(min(height, font.lineHeight * 6))
  }
  private var status: String {
    if needsDecision { return "Нужно ваше решение" }
    if chat.voice.capturing { return chat.voice.status }
    if let work = chat.workStatus { return work.title }
    if !chat.pendingMessages.isEmpty { return "Сообщение сохранено · ожидаю Codex" }
    if !chat.unreadReplies.isEmpty { return "Новых ответов: \(chat.unreadReplies.count)" }
    return chat.draft.isEmpty ? "Продолжить разговор" : "Черновик сохранён"
  }
  private var controls: some View {
    HStack(spacing: 0) {
      Button { draftFocused.wrappedValue = false; if chat.threadID == nil { chat.expanded = true } else { chat.companionExpanded.toggle() } } label: {
        Image(systemName: "square.and.pencil").frame(width: 44, height: 48).contentShape(Rectangle())
          .overlay(alignment: .topTrailing) {
            if !chat.unreadReplies.isEmpty || !chat.draft.isEmpty {
              Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -5, y: 8)
            }
          }
      }.accessibilityLabel(chat.companionExpanded ? "Свернуть поле сообщения" : "Написать в текущую задачу")
        .accessibilityIdentifier("notebook-companion-compose")
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("notebook-window"))
          .updating($moving) { _, state, _ in state = true }
          .onChanged { move($0.translation, false) }.onEnded { move($0.translation, true) })
      NotebookContextCounter()
      Divider().frame(height: 18).padding(.horizontal, 2)
      if chat.voice.capturing {
        Button { Task { await chat.voice.mute() } } label: {
          Image(systemName: chat.voice.muted ? "mic.slash" : "mic").frame(width: 40, height: 48).contentShape(Rectangle())
        }.accessibilityLabel(chat.voice.muted ? "Включить микрофон" : "Выключить микрофон")
          .disabled(chat.voice.ending || chat.voice.changingMute)
        NotebookVoiceOrb(phase: chat.voice.phase).frame(width: 28, height: 28).padding(.horizontal, 4)
          .accessibilityLabel(chat.voice.status)
        Button { Task { await chat.voice.toggleSpeaker() } } label: {
          Image(systemName: chat.voice.speakerMuted ? "speaker.slash" : "speaker.wave.2").frame(width: 40, height: 48).contentShape(Rectangle())
        }.accessibilityLabel(chat.voice.speakerMuted ? "Включить звук GPT" : "Выключить звук GPT")
          .disabled(chat.voice.ending || chat.voice.changingSpeaker || chat.voice.activeID == nil)
        Button { Task { await chat.voice.end() } } label: {
          Image(systemName: "phone.down.fill").foregroundStyle(.red).frame(width: 40, height: 48).contentShape(Rectangle())
        }.accessibilityLabel("Завершить голосовой разговор").disabled(chat.voice.ending)
      } else {
        NotebookDictationButton(chat: chat, compact: true)
        NotebookVoiceStartButton(chat: chat, compact: true)
      }
      Button { chat.revealReply() } label: {
        Image(systemName: "chevron.down").font(.system(size: 12)).frame(width: 36, height: 48).contentShape(Rectangle())
          .overlay(alignment: .topTrailing) {
            if needsDecision || chat.runs.record?.isActive == true { Circle().fill(needsDecision ? .orange : .green).frame(width: 5, height: 5).offset(x: -6, y: 8) }
          }
      }.accessibilityLabel("Открыть переписку").accessibilityIdentifier("notebook-chat-toggle")
        .contextMenu {
          Toggle("Показывать текущую задачу", isOn: $showsTask)
          if chat.runs.record?.isActive == true {
            Button("Работающий терминал", systemImage: "terminal") { chat.expanded = true; chat.files.showTerminal(true) }
          }
        }
    }.font(.system(size: 16)).padding(.horizontal, 4).fixedSize()
      .background { surface(radius: 24) }
  }
  private var composer: some View {
    HStack(alignment: .bottom, spacing: 0) {
      NotebookChatAdditions(chat: chat, canSend: canSend, send: { model.sendChatMessage() }, steer: { model.sendChatMessage(steering: true) })
      TextField("Продолжить", text: $chat.draft, axis: .vertical)
        .focused(draftFocused)
        .lineLimit(1...3).font(.system(size: 14)).padding(.vertical, 12)
        .accessibilityIdentifier("notebook-companion-draft")
        .disabled(chat.dictation.busy && !chat.dictation.canRetry)
      if let conversation = chat.conversation, conversation.busy || conversation.activeTurnID != nil {
        Button { if let turn = conversation.activeTurnID { Task { await chat.stopTurn(threadID: conversation.threadID, turnID: turn) } } } label: { sendSymbol("stop.fill") }
          .accessibilityLabel("Остановить ответ").accessibilityIdentifier("notebook-companion-stop").disabled(conversation.activeTurnID == nil || chat.saving)
      } else {
        Button { model.sendChatMessage() } label: { sendSymbol("arrow.up") }
          .disabled(!canSend).accessibilityLabel("Отправить сообщение").accessibilityIdentifier("notebook-companion-send")
      }
    }.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
  }
  private func sendSymbol(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
      .frame(width: 28, height: 28).background(Color.accentColor, in: Circle())
      .opacity(symbol == "stop.fill" || canSend ? 1 : 0.35).frame(width: 44, height: 44).contentShape(Rectangle())
  }
  private func surface(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius).fill(Color(.systemBackground))
      .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5) }
      .shadow(color: .black.opacity(0.1), radius: 9, y: 3).allowsHitTesting(false)
  }
}

/// The orb is a bounded, non-interactive indication of the existing audio owner.
struct NotebookVoiceOrb: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let phase: NotebookVoiceController.Phase
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || phase == .off || phase == .muted)) { time in
      let shift = reduceMotion ? 0 : sin(time.date.timeIntervalSinceReferenceDate * 1.8) * 0.3
      Circle().fill(LinearGradient(colors: [.indigo.opacity(0.8), .blue.opacity(0.45), .white, .indigo.opacity(0.16)],
        startPoint: .init(x: 0.3 + shift, y: 0), endPoint: .init(x: 0.7 - shift, y: 1)))
        .opacity(phase == .muted ? 0.45 : 1)
    }.allowsHitTesting(false)
  }
}

struct NotebookPearlText: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let text: String
  let active: Bool
  @State private var glint = false
  var body: some View {
    Text(text).foregroundStyle(.secondary)
      .overlay {
        if active && !reduceMotion {
          GeometryReader { geometry in
            LinearGradient(colors: [.clear, .white.opacity(0.85), .indigo.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: geometry.size.width).offset(x: glint ? geometry.size.width : -geometry.size.width)
              .animation(.linear(duration: 2.8).repeatForever(autoreverses: false), value: glint)
              .onAppear { glint = true }.onDisappear { glint = false }
          }.mask(Text(text)).allowsHitTesting(false).accessibilityHidden(true)
        }
      }
  }
}
