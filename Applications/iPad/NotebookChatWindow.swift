import SwiftUI

/// The preferred window geometry survives temporary keyboard/rotation limits.
/// It has no world coordinates and cannot publish a board-camera change.
struct NotebookChatWindowLayout: Codable, Equatable {
  var anchor = CGPoint(x: 1, y: 1)
  var size = CGSize(width: 560, height: 640)

  func frame(in available: CGRect, expanded: Bool) -> CGRect {
    let requested = expanded ? size : CGSize(width: 112, height: 48)
    let fitted = CGSize(width: min(requested.width, available.width), height: min(requested.height, available.height))
    return CGRect(x: available.minX + (available.width - fitted.width) * anchor.x,
      y: available.minY + (available.height - fitted.height) * anchor.y, width: fitted.width, height: fitted.height)
  }

  mutating func move(_ frame: CGRect, translation: CGSize, in available: CGRect) {
    anchor = CGPoint(x: fraction(frame.minX + translation.width - available.minX, travel: available.width - frame.width, previous: anchor.x),
      y: fraction(frame.minY + translation.height - available.minY, travel: available.height - frame.height, previous: anchor.y))
  }

  mutating func resize(_ frame: CGRect, translation: CGSize, in available: CGRect) {
    size = CGSize(width: min(max(320, frame.width + translation.width), available.maxX - frame.minX),
      height: min(max(240, frame.height + translation.height), available.maxY - frame.minY))
    move(CGRect(origin: frame.origin, size: size), translation: .zero, in: available)
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
    let frame = layout.frame(in: available, expanded: chat.expanded)
    NotebookChatPanel(chat: chat, size: frame.size, openPairing: openPairing, openHistory: openHistory,
      move: { update($0, ended: $1, resizing: false, frame: frame) },
      resize: { update($0, ended: $1, resizing: true, frame: frame) },
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

  private func update(_ translation: CGSize, ended: Bool, resizing: Bool, frame: CGRect) {
    if interruptedDrag {
      if ended { interruptedDrag = false }
      return
    }
    if interaction == nil { interaction = (frame, available, layout) }
    guard let start = interaction else { return }
    var next = start.layout
    if resizing { next.resize(start.frame, translation: translation, in: start.available) }
    else { next.move(start.frame, translation: translation, in: start.available) }
    liveLayout = next
    if ended { finishInteraction() }
  }

  private func finishInteraction() {
    if let liveLayout { savedLayout = liveLayout.encoded }
    interaction = nil; liveLayout = nil
  }
}
