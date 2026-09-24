import SwiftUI
import UIKit
import NotebookCore

/// The small companion is another presentation of this task, not a voice bot
/// or another transcript. Its controls and card occupy only window space.
struct NotebookCompanion: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var chat: NotebookChatController
  let placement: NotebookCompanionPlacement
  let move: (CGSize, Bool) -> Void
  let endInteraction: () -> Void
  @GestureState private var moving = false

  static let controlDiameter = NotebookChrome.controlSize + 4
  static let controlsSize = CGSize(width: controlDiameter, height: controlDiameter)

  static func preferredSize(chat: NotebookChatController, available: CGSize) -> CGSize {

    let dictationNotice = chat.dictation.busy || chat.dictation.notice != nil
    let hasCard = chat.conversation?.requests.isEmpty == false || chat.voice.error != nil || chat.voice.capturing || chat.dictation.notice != nil
      || (chat.workStatus != nil || !chat.pendingMessages.isEmpty)
    let hasStatus = !status(chat: chat).isEmpty
    let noticeHeight = chat.dictation.notice.map {
      NotebookDictationNotice.preferredHeight(message: $0, width: min(available.width, 352) - 28)
    } ?? 0
    let cardSections = [hasStatus, chat.conversation?.requests.isEmpty == false,
      chat.voice.error != nil, chat.dictation.notice != nil].filter { $0 }.count
    let height: CGFloat = controlDiameter + (hasCard ? 16 : 0) + (hasStatus ? 44 : 0)
      + (chat.conversation?.requests.isEmpty == false ? 160 : 0) + (chat.voice.error != nil ? 90 : 0)
      + noticeHeight + CGFloat(max(0, cardSections - 1)) * 4
      + CGFloat((hasCard ? 1 : 0) + chat.companionReplies.count) * 8
      + chat.companionReplies.reduce(CGFloat(0)) { $0 + 16 + max(40, previewHeight($1, width: min(available.width, 352) - 66)) }
    return .init(width: min(available.width, hasCard || dictationNotice || !chat.companionReplies.isEmpty ? 352 : controlDiameter),
      height: min(available.height, min(460, height)))
  }
  private var needsDecision: Bool { chat.conversation?.requests.isEmpty == false }
  private var hasCard: Bool {
    needsDecision || chat.voice.error != nil || chat.voice.capturing || chat.dictation.notice != nil
      || (chat.workStatus != nil || !chat.pendingMessages.isEmpty)
  }
  var body: some View {
    NotebookCompanionLayout(placement: placement) {
      controls
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
              NotebookCodexRequestView(request: request, job: chat.decisionJob(request, threadID: conversation.threadID), respond: { decision in
                await chat.respond(request, decision: decision, threadID: conversation.threadID)
              }, maximumHeight: 160)
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
          .notebookPanel(radius:NotebookChrome.cardRadius)
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
        }.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8).notebookPanel(radius:NotebookChrome.cardRadius)
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
    if !chat.pendingMessages.isEmpty { return "Приём сообщения не подтверждён" }
    return ""
  }
  private var controls: some View {
    HStack(spacing: 0) {
      Button { chat.revealReply() } label: {
        NotebookChatInputGlyph(chat:chat).frame(width:44,height:44).contentShape(Rectangle())
          .overlay(alignment: .topTrailing) {
            if !chat.unreadReplies.isEmpty || !chat.draft.isEmpty || needsDecision || chat.runs.record?.isActive == true {
              Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: -5, y: 8)
            }
          }
      }.accessibilityLabel("Открыть текущий чат")
        .accessibilityIdentifier("notebook-companion-compose")
        .accessibilityValue(chat.dictation.busy ? "Диктовка" : chat.voice.capturing ? chat.voice.status : "Текст")
        .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("notebook-window"))
          .updating($moving) { _, state, _ in state = true }
          .onChanged { move($0.translation, false) }.onEnded { move($0.translation, true) })
    }.font(NotebookChrome.iconFont).buttonStyle(.plain)
      .frame(width:Self.controlDiameter,height:Self.controlDiameter)
      .notebookPanel(radius:Self.controlDiameter/2).contentShape(Circle()).fixedSize()
      .accessibilityElement(children: .contain).accessibilityIdentifier("notebook-companion-bar")
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

/// Observation is bounded to the glyph, not the canvas or chat layout.
private struct NotebookChatInputGlyph: View {
  @Bindable var chat: NotebookChatController
  var body: some View {
    if chat.dictation.busy {
      NotebookAudioLevelGlyph(symbol:"mic",level:chat.dictation.level)
    } else if chat.voice.capturing {
      NotebookAudioLevelGlyph(symbol:chat.voice.muted ? "mic.slash" : "waveform",level:chat.voice.inputLevel)
    } else { Image(systemName:"bubble.left") }
  }
}

struct NotebookAudioLevelGlyph: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let symbol: String
  let level: Double
  var body: some View {
    let value = level.isFinite ? min(1,max(0,level)) : 0
    Image(systemName:symbol)
      .foregroundStyle(.primary.opacity(0.65+0.35*value))
      .scaleEffect(reduceMotion ? 1 : 1+0.18*value)
      .background {
        Circle().stroke(.primary.opacity(0.08+value*0.32),lineWidth:1+value*2)
          .frame(width:28+value*8,height:28+value*8)
      }
      .animation(reduceMotion ? nil : .linear(duration:0.1),value:value)
      .allowsHitTesting(false)
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
