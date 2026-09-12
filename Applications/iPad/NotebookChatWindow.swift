import SwiftUI

/// The terminal divides window space, not paper space. The saved proportion
/// survives a temporarily short keyboard viewport without changing the camera.
struct NotebookTerminalSplit {
  static let divider: CGFloat = 12
  let available: CGFloat
  let terminal: CGFloat
  var conversation: CGFloat { available - terminal }
  init(height: CGFloat, fraction: Double?) {
    available = max(0, height - Self.divider)
    // Leave room for the composer and readable message lines.
    // The terminal may be shorter; its prompt needs fewer rows than a reply.
    let conversationMinimum = min(180, available / 2)
    let terminalMinimum = min(120, available / 2)
    let preferred = fraction.flatMap { $0.isFinite ? $0 : nil } ?? 0.5
    terminal = min(available - conversationMinimum, max(terminalMinimum, available * preferred))
  }
  func fraction(after translation: CGFloat) -> Double {
    guard available > 0 else { return 0.5 }
    let next = Self(height: available + Self.divider, fraction: Double((terminal - translation) / available))
    return Double(next.terminal / available)
  }
}

enum NotebookChatResizeCorner: String, CaseIterable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing
  var leading: Bool { self == .topLeading || self == .bottomLeading }
  var top: Bool { self == .topLeading || self == .topTrailing }
  var alignment: Alignment { switch self { case .topLeading: .topLeading; case .topTrailing: .topTrailing; case .bottomLeading: .bottomLeading; case .bottomTrailing: .bottomTrailing } }
  var label: String { switch self { case .topLeading: "верхний левый"; case .topTrailing: "верхний правый"; case .bottomLeading: "нижний левый"; case .bottomTrailing: "нижний правый" } }
}

/// Only the outer rim takes the drag; nearby header/composer buttons retain
/// their full central hit targets. Nothing is painted over the conversation.
struct NotebookChatCornerHitShape: Shape {
  let corner: NotebookChatResizeCorner
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.addRect(CGRect(x: corner.leading ? rect.minX : rect.maxX - 14, y: rect.minY, width: 14, height: rect.height))
    path.addRect(CGRect(x: rect.minX, y: corner.top ? rect.minY : rect.maxY - 14, width: rect.width, height: 14))
    return path
  }
}

/// The preferred window geometry survives temporary keyboard/rotation limits.
/// It has no world coordinates and cannot publish a board-camera change.
struct NotebookChatWindowLayout: Codable, Equatable {
  var anchor = CGPoint(x: 1, y: 1)
  var size = CGSize(width: 560, height: 640)

  func frame(in available: CGRect, expanded: Bool, compactSize: CGSize = CGSize(width: 112, height: 48)) -> CGRect {
    let requested = expanded ? size : compactSize
    let fitted = CGSize(width: min(requested.width, available.width), height: min(requested.height, available.height))
    return CGRect(x: available.minX + (available.width - fitted.width) * anchor.x,
      y: available.minY + (available.height - fitted.height) * anchor.y, width: fitted.width, height: fitted.height)
  }

  mutating func move(_ frame: CGRect, translation: CGSize, in available: CGRect) {
    anchor = CGPoint(x: fraction(frame.minX + translation.width - available.minX, travel: available.width - frame.width, previous: anchor.x),
      y: fraction(frame.minY + translation.height - available.minY, travel: available.height - frame.height, previous: anchor.y))
  }

  mutating func resize(_ frame: CGRect, corner: NotebookChatResizeCorner, translation: CGSize, in available: CGRect) {
    let widthLimit = corner.leading ? frame.maxX - available.minX : available.maxX - frame.minX
    let heightLimit = corner.top ? frame.maxY - available.minY : available.maxY - frame.minY
    size = CGSize(width: min(max(320, frame.width + (corner.leading ? -translation.width : translation.width)), widthLimit),
      height: min(max(240, frame.height + (corner.top ? -translation.height : translation.height)), heightLimit))
    let origin = CGPoint(x: corner.leading ? frame.maxX - size.width : frame.minX,
      y: corner.top ? frame.maxY - size.height : frame.minY)
    move(CGRect(origin: origin, size: size), translation: .zero, in: available)
  }

  private func fraction(_ value: CGFloat, travel: CGFloat, previous: CGFloat) -> CGFloat {
    travel > 0 ? min(1, max(0, value / travel)) : previous
  }

  var encoded: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }

  init() {}
  init(restoring value: String) {
    guard let data = value.data(using: .utf8), let saved = try? JSONDecoder().decode(Self.self, from: data),
      saved.anchor.x.isFinite, saved.anchor.y.isFinite, (0...1).contains(saved.anchor.x), (0...1).contains(saved.anchor.y),
      saved.size.width.isFinite, saved.size.height.isFinite, saved.size.width > 0, saved.size.height > 0 else {
      self.init(); return
    }
    self = saved
  }
}

struct NotebookChatWindow: View {
  @Bindable var chat: NotebookChatController
  let available: CGRect
  let openPairing: () -> Void
  let openHistory: () -> Void
  let frameChanged: (CGRect) -> Void
  @AppStorage("notebook.chat-window") private var savedLayout = ""
  @State private var interaction: (frame: CGRect, available: CGRect, layout: NotebookChatWindowLayout)?
  @State private var liveLayout: NotebookChatWindowLayout?
  @State private var interruptedDrag = false

  private var layout: NotebookChatWindowLayout { liveLayout ?? .init(restoring: savedLayout) }

  var body: some View {
    let frame = layout.frame(in: available, expanded: chat.expanded,
      compactSize: NotebookCollapsedChat.preferredSize(chat: chat, available: available.size))
    NotebookChatPanel(chat: chat, size: frame.size, openPairing: openPairing, openHistory: openHistory,
      move: { update($0, ended: $1, corner: nil, frame: frame) },
      resize: { update($0, ended: $1, corner: $2, frame: frame) },
      endInteraction: { interruptedDrag = false; finishInteraction() })
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameChanged($0) }
      .position(x: frame.midX, y: frame.midY)
      .onChange(of: available) {
        if interaction != nil { interruptedDrag = true }
        finishInteraction()
      }
      .onChange(of: chat.expanded) { finishInteraction() }
      .onDisappear { finishInteraction() }
  }

  private func update(_ translation: CGSize, ended: Bool, corner: NotebookChatResizeCorner?, frame: CGRect) {
    if interruptedDrag {
      if ended { interruptedDrag = false }
      return
    }
    if interaction == nil { interaction = (frame, available, layout) }
    guard let start = interaction else { return }
    var next = start.layout
    if let corner { next.resize(start.frame, corner: corner, translation: translation, in: start.available) }
    else { next.move(start.frame, translation: translation, in: start.available) }
    liveLayout = next
    if ended { finishInteraction() }
  }

  private func finishInteraction() {
    if let liveLayout { savedLayout = liveLayout.encoded }
    interaction = nil; liveLayout = nil
  }
}
