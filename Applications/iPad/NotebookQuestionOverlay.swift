import NotebookCore
import SwiftUI
import UIKit

/// The existing question follows its pinned physical references. Layout never
/// issues navigation or changes the question's read/write grant.
struct NotebookQuestionOverlay: View {
  @Environment(NotebookAppModel.self) private var model
  let question: NotebookAgentQuestion
  let sceneOrigin: CGPoint
  let footerHeight: CGFloat
  let controls: [CGRect]

  var body: some View {
    GeometryReader { geometry in
      let origin = geometry.frame(in: .global).origin
      let available = CGRect(x: 18, y: 18, width: max(1, geometry.size.width - 36),
        height: max(1, geometry.size.height - 36 - footerHeight - (footerHeight > 0 ? 12 : 0)))
      let anchor = model.presence.flatMap { presence in
        question.references.compactMap { NotebookAttentionProjection.frame($0, model: model, presence: presence) }
          .reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
      }?.offsetBy(dx: sceneOrigin.x - origin.x, dy: sceneOrigin.y - origin.y)
      NotebookQuestionPlacementLayout(area: available, anchor: anchor,
        controls: controls.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }) {
        NotebookAgentQuestionCard(question: question, maximumHeight: available.height)
          .background(NotebookControlRegion(gate: model.inputGate))
      }
    }
  }
}

/// Four adjacent candidates and the available corners are a constant-size
/// search. Prefer a clear neighbour; if the selection covers the viewport,
/// minimize the covered selected area while leaving native controls accessible.
enum NotebookQuestionPlacement {
  static func frame(size: CGSize, in area: CGRect, near anchor: CGRect?, avoiding controls: [CGRect] = []) -> CGRect {
    let size = CGSize(width: min(max(1, size.width), area.width), height: min(max(1, size.height), area.height))
    func bounded(_ x: CGFloat, _ y: CGFloat) -> CGRect {
      .init(x: min(max(area.minX, x), area.maxX - size.width),
        y: min(max(area.minY, y), area.maxY - size.height), width: size.width, height: size.height)
    }
    let visible = anchor.flatMap { rect -> CGRect? in
      guard !rect.isNull, !rect.isInfinite else { return nil }
      let clipped = rect.intersection(area)
      return clipped.isNull || clipped.isEmpty ? nil : clipped
    }
    var candidates: [CGRect] = []
    if let visible {
      candidates = [bounded(visible.maxX + 12, visible.minY), bounded(visible.minX - 12 - size.width, visible.minY),
        bounded(visible.minX, visible.maxY + 12), bounded(visible.minX, visible.minY - 12 - size.height)]
    }
    candidates += [bounded(area.minX, area.maxY - size.height), bounded(area.minX, area.minY),
      bounded(area.maxX - size.width, area.maxY - size.height), bounded(area.maxX - size.width, area.minY)]
    func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
      let intersection = lhs.intersection(rhs)
      return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    func score(_ candidate: CGRect) -> (CGFloat, CGFloat) {
      (controls.reduce(0) { $0 + overlap(candidate, $1.insetBy(dx: -8, dy: -8)) },
        visible.map { overlap(candidate, $0.insetBy(dx: -12, dy: -12)) } ?? 0)
    }
    return candidates.dropFirst().reduce(candidates[0]) { best, candidate in
      let a = score(best), b = score(candidate)
      return b.0 < a.0 || (b.0 == a.0 && b.1 < a.1) ? candidate : best
    }
  }
}

private struct NotebookQuestionPlacementLayout: Layout {
  let area: CGRect
  let anchor: CGRect?
  let controls: [CGRect]
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let card = subviews.first else { return }
    let proposed = ProposedViewSize(width: min(420, area.width), height: area.height)
    let frame = NotebookQuestionPlacement.frame(size: card.sizeThatFits(proposed), in: area, near: anchor, avoiding: controls)
    card.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
      proposal: .init(width: frame.width, height: frame.height))
  }
}

/// The transparent background supplies the card's actual UIKit bounds to the
/// input gate. It does not install a recognizer or claim touches outside them.
struct NotebookControlRegion: UIViewRepresentable {
  let gate: NotebookInputGate
  func makeUIView(context: Context) -> NotebookControlRegionView { NotebookControlRegionView(gate: gate) }
  func updateUIView(_ view: NotebookControlRegionView, context: Context) { view.use(gate) }
  static func dismantleUIView(_ view: NotebookControlRegionView, coordinator: ()) { view.unregister() }
}

final class NotebookControlRegionView: UIView {
  private let source = UUID()
  private var gate: NotebookInputGate
  init(gate: NotebookInputGate) {
    self.gate = gate
    super.init(frame: .zero)
    isUserInteractionEnabled = false
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func use(_ next: NotebookInputGate) {
    guard next !== gate else { return }
    unregister(); gate = next; register()
  }
  override func didMoveToWindow() { super.didMoveToWindow(); unregister(); register() }
  private func register() {
    guard window != nil else { return }
    gate.registerControlRegion(source: source) { [weak self] point in
      guard let self, let window, !isHidden, alpha > 0 else { return false }
      return bounds.contains(convert(point, from: window))
    }
  }
  func unregister() { gate.unregisterControlRegion(source: source) }
}
