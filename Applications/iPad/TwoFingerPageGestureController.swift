import UIKit

@MainActor
final class TwoFingerPageGestureController: NSObject, UIGestureRecognizerDelegate {
  var onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
  var onUndo: () -> Void

  private weak var view: UIView?
  private var recognizers: [UIGestureRecognizer] = []
  private var repeatTask: Task<Void, Never>?

  init(
    onNavigate: @escaping (_ horizontal: Bool, _ direction: Int) -> Void,
    onUndo: @escaping () -> Void
  ) {
    self.onNavigate = onNavigate
    self.onUndo = onUndo
  }

  func install(on view: UIView) {
    guard self.view !== view else { return }
    uninstall()

    let hold = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handleHold)
    )
    hold.numberOfTouchesRequired = 2
    hold.minimumPressDuration = 0.34
    hold.allowableMovement = 16
    configure(hold)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tap.numberOfTouchesRequired = 2
    tap.numberOfTapsRequired = 1
    configure(tap)
    tap.require(toFail: hold)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    pan.minimumNumberOfTouches = 2
    pan.maximumNumberOfTouches = 2
    configure(pan)

    [hold, tap, pan].forEach(view.addGestureRecognizer)
    self.view = view
    recognizers = [hold, tap, pan]
  }

  func uninstall() {
    stopRepeating()
    for recognizer in recognizers {
      view?.removeGestureRecognizer(recognizer)
    }
    recognizers = []
    view = nil
  }

  private func configure(_ recognizer: UIGestureRecognizer) {
    recognizer.allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    recognizer.cancelsTouchesInView = true
    recognizer.delaysTouchesBegan = false
    recognizer.delegate = self
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    guard recognizer.state == .ended else { return }
    onUndo()
  }

  @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
    switch recognizer.state {
    case .began:
      onUndo()
      startRepeating()
    case .ended, .cancelled, .failed:
      stopRepeating()
    default:
      break
    }
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

  private func startRepeating() {
    stopRepeating()
    repeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(95))
        guard !Task.isCancelled, let self else { return }
        onUndo()
      }
    }
  }

  private func stopRepeating() {
    repeatTask?.cancel()
    repeatTask = nil
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }
}
