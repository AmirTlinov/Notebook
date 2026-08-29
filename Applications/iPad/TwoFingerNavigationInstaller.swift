import SwiftUI
import UIKit

struct TwoFingerNavigationInstaller: UIViewRepresentable {
  let onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onNavigate: onNavigate)
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
    private weak var installedView: UIView?
    private var recognizer: UIPanGestureRecognizer?

    init(onNavigate: @escaping (_ horizontal: Bool, _ direction: Int) -> Void) {
      self.onNavigate = onNavigate
    }

    func install(on view: UIView?) {
      guard let view, installedView !== view else { return }
      uninstall()
      let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle))
      recognizer.minimumNumberOfTouches = 2
      recognizer.maximumNumberOfTouches = 2
      recognizer.cancelsTouchesInView = true
      recognizer.delaysTouchesBegan = false
      recognizer.delegate = self
      view.addGestureRecognizer(recognizer)
      installedView = view
      self.recognizer = recognizer
    }

    func uninstall() {
      if let recognizer { installedView?.removeGestureRecognizer(recognizer) }
      recognizer = nil
      installedView = nil
    }

    @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
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
