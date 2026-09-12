import SwiftUI
import UIKit

/// The transparent background supplies a control's actual UIKit bounds to the
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
    gate.registerControlRegion(source: source) { [weak self] point, _ in
      guard let self, let window, !isHidden, alpha > 0 else { return false }
      return bounds.contains(convert(point, from: window))
    }
  }
  func unregister() { gate.unregisterControlRegion(source: source) }
}
