import SwiftUI
import UIKit
import NotebookCore

/// The small companion is another presentation of this task, not a voice bot
/// or another transcript. Its controls and card occupy only window space.
struct NotebookCompanion: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var chat: NotebookChatController
  let size: CGSize
  let placement: NotebookCompanionPlacement
  let onControlsSize: (CGSize) -> Void
  let move: (CGSize, Bool) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false

  static func preferredSize(chat: NotebookChatController, available: CGSize, contextCount: Int = 0) -> CGSize {

    let dictationNotice = chat.dictation.busy || chat.dictation.notice != nil
    let hasCard = chat.conversation?.requests.isEmpty == false || chat.voice.error != nil || chat.voice.capturing || chat.dictation.notice != nil
      || (chat.workStatus != nil || !chat.pendingMessages.isEmpty)
    let hasStatus = !status(chat: chat).isEmpty
    let noticeHeight = chat.dictation.notice.map {
      NotebookDictationNotice.preferredHeight(message: $0, width: min(available.width, 352) - 28)
    } ?? 0
    let cardSections = [hasStatus, chat.conversation?.requests.isEmpty == false,
      chat.voice.error != nil, chat.dictation.notice != nil].filter { $0 }.count
    let height: CGFloat = 48 + (hasCard ? 16 : 0) + (hasStatus ? 44 : 0)
      + (chat.conversation?.requests.isEmpty == false ? 160 : 0) + (chat.voice.error != nil ? 90 : 0)
      + noticeHeight + CGFloat(max(0, cardSections - 1)) * 4
      + CGFloat((hasCard ? 1 : 0) + chat.companionReplies.count) * 8
      + chat.companionReplies.reduce(CGFloat(0)) { $0 + 16 + max(40, previewHeight($1, width: min(available.width, 352) - 66)) }
    return .init(width: min(available.width, hasCard || dictationNotice || !chat.companionReplies.isEmpty ? 352 : (chat.voice.capturing ? 228 : 148) + (contextCount > 0 ? 28 : 0)),
      height: min(available.height, min(460, height)))
  }
  private var needsDecision: Bool { chat.conversation?.requests.isEmpty == false }
  private var hasCard: Bool {
    needsDecision || chat.voice.error != nil || chat.voice.capturing || chat.dictation.notice != nil
      || (chat.workStatus != nil || !chat.pendingMessages.isEmpty)
  }
  var body: some View {
    NotebookCompanionLayout(placement: placement) {
      controls.onGeometryChange(for: CGSize.self) { $0.size } action: { onControlsSize($0) }
      cards
    }
    .onChange(of: moving) { if !moving { endInteraction() } }
  }

  private var cards: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if hasCard {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            if !status.isEmpty {
              Button { chat.revealReply() } label: {
                NotebookPearlText(text: status, active: chat.workStatus?.running == true && !chat.voice.capturing)
                  .font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
              }.accessibilityLabel("Открыть переписку · " + (chat.voice.capturing ? chat.voice.taskTitle : chat.taskTitle) + " · " + status)
                .accessibilityIdentifier("notebook-companion-task")
            }
            if let conversation = chat.conversation, let request = conversation.requests.first {
              NotebookCodexRequestView(request: request, threadID: conversation.threadID, chat: chat, maximumHeight: 160)
                .id(request.id)
            }
            if let error = chat.voice.error {
              HStack(alignment: .top) {
                Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("notebook-compact-voice-error")
                Button { chat.voice.dismissError() } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                  .accessibilityLabel("Убрать уведомление о голосе")
              }
            }
            if let notice = chat.dictation.notice {
              NotebookDictationNotice(dictation: chat.dictation, message: notice)
            }
          }.padding(.horizontal, 14).padding(.vertical, 8)
        }.scrollBounceBehavior(.basedOnSize)
          .background { surface(radius: 22) }
      }
      ForEach(chat.companionReplies) { reply in
        HStack(alignment: .top, spacing: 4) {
          Button { chat.revealReply(reply.id) } label: {
            Text(Self.previewText(reply)).font(.system(size: 14)).foregroundStyle(.primary).lineLimit(6)
              .multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
          }.accessibilityHint("Открыть полный ответ в этой переписке").accessibilityIdentifier("notebook-companion-reply")
          Button { chat.dismissCompanionReply(reply.id) } label: {
            Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(.secondary)
              .frame(width: 40, height: 40).contentShape(Rectangle())
          }.accessibilityLabel("Убрать превью ответа").accessibilityIdentifier("notebook-companion-dismiss-reply")
        }.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8).background { surface(radius: 22) }
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.28), value: chat.companionReplies.map(\.id))
    .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.28), value: hasCard)
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
  private var status: String { Self.status(chat: chat) }
  private static func status(chat: NotebookChatController) -> String {
    if chat.conversation?.requests.isEmpty == false { return "Нужно ваше решение" }
    if chat.voice.capturing { return chat.voice.status }
    if let work = chat.workStatus { return work.title }
    if !chat.pendingMessages.isEmpty { return "Сообщение сохранено · ожидаю Codex" }
    return ""
  }
  private var controls: some View {
    HStack(spacing: 0) {
      Button { chat.revealReply() } label: {
        Image(systemName: "square.and.pencil").frame(width: 44, height: 48).contentShape(Rectangle())
          .overlay(alignment: .topTrailing) {
            if !chat.unreadReplies.isEmpty || !chat.draft.isEmpty || needsDecision || chat.runs.record?.isActive == true {
              Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -5, y: 8)
            }
          }
      }.accessibilityLabel("Открыть текущий чат")
        .accessibilityIdentifier("notebook-companion-compose")
        .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("notebook-window"))
          .updating($moving) { _, state, _ in state = true }
          .onChanged { move($0.translation, false) }.onEnded { move($0.translation, true) })
      NotebookContextCounter()
      Divider().frame(height: 18).padding(.horizontal, 2)
      if chat.dictation.busy {
        NotebookDictationInput(chat: chat)
      } else if chat.voice.capturing {
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
    }.font(.system(size: 16)).padding(.horizontal, 4)
      .frame(width: chat.dictation.busy ? size.width : nil)
      .fixedSize(horizontal: !chat.dictation.busy, vertical: true)
      .background { surface(radius: 24) }
      .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-companion-bar")
  }
  private func surface(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius).fill(Color(.systemBackground))
      .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5) }
      .shadow(color: .black.opacity(0.1), radius: 9, y: 3).allowsHitTesting(false)
  }
}

/// Layout keeps the same control subtree while cards appear above or below it.
/// No gesture, delayed action or second presentation state is owned here.
private struct NotebookCompanionLayout: Layout {
  let placement: NotebookCompanionPlacement
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    placement.frame.size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (view, frame) in zip(subviews, [placement.controls, placement.cards]) {
      view.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
        proposal: .init(width: frame.width, height: frame.height))
    }
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
