#if os(iOS)
import UIKit

/// Preparation needs a native window, not a second window on the display.
/// iPadOS can restore a scene window's frame to the screen even after an
/// offscreen frame was assigned. A clipped child of the existing window keeps
/// its local rendering coordinates without ever becoming another visible UI.
@MainActor
final class NotebookPreparationHost {
  let view = UIView()

  init(windowScene: UIWindowScene) throws {
    guard let window = windowScene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }) else {
      throw SceneRenderError.snapshotPending("preparation_window")
    }
    view.backgroundColor = .clear
    view.isOpaque = false
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    view.clipsToBounds = true
    window.addSubview(view)
  }

  func resize(to size: CGSize) {
    view.frame = CGRect(origin: .init(x: -20_000 - size.width, y: -20_000 - size.height), size: size)
  }

  func close() { view.removeFromSuperview() }
  isolated deinit { close() }
}
#endif
