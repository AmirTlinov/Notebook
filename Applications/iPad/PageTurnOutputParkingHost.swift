import QuartzCore
import UIKit

/// The mounted opaque paper lends its existing background to an idle output.
/// The renderer retains the drawable pool; this receiver owns only its mount.
@MainActor
class PageTurnOutputParkingHost: UIView, PageTurnOutputHost {
  private weak var parkedOutput: CAMetalLayer?
  private weak var parkedWindow: UIWindow?
  private weak var parkedParent: UIView?
  private var parkedBounds: CGRect?
  private var onOutputRevoked: (@MainActor () -> Void)?

  var canParkOutput: Bool {
    guard let window, !window.isHidden, superview != nil, !bounds.isEmpty,
      convert(bounds, to: window).intersects(window.bounds) else { return false }
    var ancestor: UIView? = self
    while let view = ancestor {
      guard !view.isHidden, view.alpha == 1 else { return false }
      ancestor = view.superview
    }
    return true
  }

  func parkOutput(_ output: CAMetalLayer, onRevoked: @escaping @MainActor () -> Void) -> Bool {
    guard canParkOutput else { return false }
    if parkedOutput !== output { revokeCurrentOutput() }
    guard canParkOutput else { return false }
    parkedOutput = output; parkedWindow = window; parkedParent = superview
    parkedBounds = bounds; onOutputRevoked = onRevoked
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.insertSublayer(output, at: 0); output.frame = bounds
    CATransaction.commit()
    return true
  }

  func unparkOutput(_ output: CAMetalLayer) {
    guard parkedOutput === output else { return }
    clearParking()
  }

  func revokeCurrentOutput() {
    let revoked = onOutputRevoked
    clearParking()
    revoked?()
  }

  private func clearParking() {
    parkedOutput = nil; parkedWindow = nil; parkedParent = nil
    parkedBounds = nil; onOutputRevoked = nil
  }

  private func validateParking() {
    guard onOutputRevoked != nil else { return }
    guard canParkOutput, parkedOutput?.superlayer === layer,
      parkedWindow === window, parkedParent === superview, parkedBounds == bounds else {
      revokeCurrentOutput(); return
    }
  }

  override var bounds: CGRect { didSet { validateParking() } }
  override func layoutSubviews() { super.layoutSubviews(); validateParking() }
  override func didMoveToWindow() { super.didMoveToWindow(); validateParking() }
  override func didMoveToSuperview() { super.didMoveToSuperview(); validateParking() }
}
