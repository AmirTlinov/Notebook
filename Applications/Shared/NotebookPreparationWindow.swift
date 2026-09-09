#if os(iOS)
import UIKit

/// A native backing may need a window before it is mounted in the human scene.
/// This window can submit rendering work, but never joins input or accessibility.
@MainActor
final class NotebookPreparationWindow: UIWindow {
  override var canBecomeKey: Bool { false }

  override init(windowScene: UIWindowScene) {
    super.init(windowScene: windowScene)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
  }

  required init?(coder: NSCoder) { fatalError("Preparation windows are owned by their renderer") }
}
#endif
