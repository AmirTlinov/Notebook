import SwiftUI
import UIKit

struct TwoFingerNavigationInstaller: UIViewRepresentable {
  let onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
  let onUndo: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onNavigate: onNavigate, onUndo: onUndo)
  }

  func makeUIView(context: Context) -> AttachmentView {
    let view = AttachmentView()
    view.onWindow = { [weak coordinator = context.coordinator] window in
      coordinator?.install(on: window)
    }
    return view
  }

  func updateUIView(_ view: AttachmentView, context: Context) {
    context.coordinator.onNavigate = onNavigate
    context.coordinator.onUndo = onUndo
  }

  static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  final class AttachmentView: UIView {
    var onWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      onWindow?(window)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      nil
    }
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
    var onUndo: () -> Void
    private weak var installedView: UIView?
    private var panRecognizer: UIPanGestureRecognizer?
    private var tapRecognizer: UITapGestureRecognizer?

    init(
      onNavigate: @escaping (_ horizontal: Bool, _ direction: Int) -> Void,
      onUndo: @escaping () -> Void
    ) {
      self.onNavigate = onNavigate
      self.onUndo = onUndo
    }

    func install(on view: UIView?) {
      guard let view, installedView !== view else { return }
      uninstall()
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
      tap.numberOfTouchesRequired = 2
      tap.numberOfTapsRequired = 1
      tap.cancelsTouchesInView = true
      tap.delaysTouchesBegan = false
      tap.delegate = self

      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
      pan.minimumNumberOfTouches = 2
      pan.maximumNumberOfTouches = 2
      pan.cancelsTouchesInView = true
      pan.delaysTouchesBegan = false
      pan.delegate = self
      pan.require(toFail: tap)

      view.addGestureRecognizer(tap)
      view.addGestureRecognizer(pan)
      installedView = view
      tapRecognizer = tap
      panRecognizer = pan
    }

    func uninstall() {
      if let panRecognizer {
        installedView?.removeGestureRecognizer(panRecognizer)
      }
      if let tapRecognizer {
        installedView?.removeGestureRecognizer(tapRecognizer)
      }
      panRecognizer = nil
      tapRecognizer = nil
      installedView = nil
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      onUndo()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      let translation = recognizer.translation(in: recognizer.view)
      let velocity = recognizer.velocity(in: recognizer.view)
      let horizontal = abs(translation.x) >= abs(translation.y)
      let distance = horizontal ? translation.x : translation.y
      let speed = horizontal ? velocity.x : velocity.y
      guard abs(distance) >= 54 || abs(speed) >= 620 else { return }
      onNavigate(horizontal, distance < 0 ? 1 : -1)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}
