import NotebookCore
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Every presented spring sample is the actual scene camera. Interrupting the
/// display clock leaves that sample in the model, not the invisible end target.
@MainActor
final class SceneCameraSettlement {
  @MainActor private final class ClockTarget: NSObject {
    weak var owner: SceneCameraSettlement?
    @objc func tick(_ link: CADisplayLink) { owner?.advance(at: link.timestamp) }
  }
  private let clockTarget = ClockTarget()
  private var link: CADisplayLink?
  private var startedAt = 0.0
  private var duration = 0.0
  private var spring = Spring()
  private var from: SessionPresence?
  private var to: SessionPresence?
  private var publish: ((SessionPresence, Bool) -> Void)?
  private var completion: (() -> Void)?

  @discardableResult
  func start(from: SessionPresence, to: SessionPresence, duration: Double, bounce: Double,
    publish: @escaping (SessionPresence, Bool) -> Void, completion: @escaping () -> Void) -> Bool {
    guard from.isValid, to.isValid, duration.isFinite, bounce.isFinite else { return false }
    cancel()
    guard from.boardID == to.boardID, duration > 0 else { publish(to, true); completion(); return true }
    self.from = from; self.to = to; self.duration = duration
    self.publish = publish; self.completion = completion
    spring = Spring(settlingDuration: duration, dampingRatio: Spring(duration: duration, bounce: bounce).dampingRatio)
    startedAt = CACurrentMediaTime()
    clockTarget.owner = self
    #if os(iOS)
    link = CADisplayLink(target: clockTarget, selector: #selector(ClockTarget.tick(_:)))
    #else
    link = NSScreen.main?.displayLink(target: clockTarget, selector: #selector(ClockTarget.tick(_:)))
    #endif
    guard let link else { cancel(); publish(to, true); completion(); return true }
    link.preferredFrameRateRange = .init(minimum: 30, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    publish(from, false)
    return true
  }

  func cancel() {
    link?.invalidate(); link = nil
    from = nil; to = nil; publish = nil; completion = nil
  }

  private func advance(at time: Double) {
    guard let from, let to, let publish else { return }
    let elapsed = max(0, time - startedAt)
    if elapsed >= duration {
      let completion = completion
      cancel()
      publish(to, true)
      completion?()
    } else {
      guard let sample = Self.sample(from: from, to: to, fraction: spring.value(target: 1.0, time: elapsed)) else {
        let completion = completion; cancel(); completion?(); return
      }
      publish(sample, false)
    }
  }

  static func sample(from: SessionPresence, to: SessionPresence, fraction: Double) -> SessionPresence? {
    guard from.isValid, to.isValid, fraction.isFinite else { return nil }
    guard fraction > 0 else { return from }
    guard fraction < 1 else { return to }
    let amount = fraction
    guard let center = from.camera.center.interpolatedAddress(to: to.camera.center, amount: amount) else { return nil }
    let scale = exp(log(from.camera.scale) + log(to.camera.scale / from.camera.scale) * amount)
    let camera = SpatialCamera(center: center,
      scale: min(max(scale, min(from.camera.scale, to.camera.scale)), max(from.camera.scale, to.camera.scale)))
    let focus = to.focusedItemID ?? from.focusedItemID
    return SessionPresence(boardID: to.boardID, mode: focus == nil ? .board : .cover,
      camera: camera, viewport: to.viewport, focusedItemID: focus,
      openProgress: from.openProgress + (to.openProgress - from.openProgress) * amount,
      documentPageIndex: to.documentPageIndex)
  }

  isolated deinit { link?.invalidate() }
}
