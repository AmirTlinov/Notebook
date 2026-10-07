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
    @objc func tick(_ link: CADisplayLink) {
      owner?.advance(presentationTime: link.targetTimestamp, observedTime: CACurrentMediaTime())
    }
  }
  private let clockTarget = ClockTarget()
  private var link: CADisplayLink?
  private(set) var startedAt = 0.0
  private var duration = 0.0
  private var spring = Spring()
  private var from: SessionPresence?
  private var to: SessionPresence?
  private var publish: ((SessionPresence, Bool) -> Void)?
  enum Outcome: Equatable { case completed, cancelled, superseded, failed }
  private var completion: ((Outcome) -> Void)?
  private(set) var current: SessionPresence?
  private(set) var operationID: UUID?
  var destination: SessionPresence? { to }
  /// Only this request may cancel its navigation transition. A queued request
  /// does not own a different, already running human camera settlement.
  private(set) var navigationID: UUID?

  @discardableResult
  func start(from: SessionPresence, to: SessionPresence, duration: Double, bounce: Double, navigationID: UUID? = nil,
    publish: @escaping (SessionPresence, Bool) -> Void, completion: @escaping (Outcome) -> Void) -> Bool {
    guard from.isValid, to.isValid, duration.isFinite, bounce.isFinite else { completion(.failed); return false }
    cancel(outcome: .superseded)
    let id = UUID()
    operationID = id; current = from
    self.from = from; self.to = to; self.duration = duration
    self.navigationID = navigationID
    self.publish = publish; self.completion = completion
    guard from != to, from.boardID == to.boardID, duration > 0 else { finish(.completed, pose: to); return true }
    spring = Spring(settlingDuration: duration, dampingRatio: Spring(duration: duration, bounce: bounce).dampingRatio)
    startedAt = CACurrentMediaTime()
    clockTarget.owner = self
    #if os(iOS)
    link = CADisplayLink(target: clockTarget, selector: #selector(ClockTarget.tick(_:)))
    #else
    link = NSScreen.main?.displayLink(target: clockTarget, selector: #selector(ClockTarget.tick(_:)))
    #endif
    guard let link else { finish(.completed, pose: to); return true }
    link.preferredFrameRateRange = .init(minimum: 30, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    publish(from, false)
    return true
  }

  /// Termination releases every callback before notifying its owner. A callback
  /// may immediately start the next movement without being cleared by the old one.
  @discardableResult
  func cancel(outcome: Outcome = .cancelled) -> SessionPresence? {
    finish(outcome)
    return current
  }

  private func finish(_ outcome: Outcome, pose: SessionPresence? = nil) {
    guard operationID != nil else { return }
    let publish = publish, completion = completion
    link?.invalidate(); link = nil
    from = nil; to = nil; self.publish = nil; self.completion = nil
    navigationID = nil; operationID = nil
    if let pose { current = pose; publish?(pose, outcome == .completed) }
    completion?(outcome)
  }

  func advance(presentationTime: Double, observedTime: Double) {
    guard let from, let to, let publish else { return }
    // Prepare the upcoming frame, but retain input and passage ownership until
    // the real deadline. The render target cannot start the next stage early.
    let deadline = startedAt + duration
    if observedTime >= deadline { finish(.completed, pose: to); return }
    let elapsed = max(0, presentationTime - startedAt)
    let fraction = presentationTime >= deadline ? 1 : spring.value(target: 1.0, time: elapsed)
    guard let sample = Self.sample(from: from, to: to, fraction: fraction) else {
      finish(.failed); return
    }
    current = sample
    publish(sample, false)
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
    if from.mode == to.mode, from.focusedItemID == to.focusedItemID,
      from.openProgress == to.openProgress, from.notebookPageID == to.notebookPageID,
      from.documentPageIndex == to.documentPageIndex {
      return to.replacingCamera(camera)
    }
    let focus = to.focusedItemID ?? from.focusedItemID
    return SessionPresence(boardID: to.boardID, mode: focus == nil ? .board : .cover,
      camera: camera, viewport: to.viewport, focusedItemID: focus,
      openProgress: from.openProgress + (to.openProgress - from.openProgress) * amount,
      documentPageIndex: to.documentPageIndex)
  }

  isolated deinit { finish(.cancelled) }
}

extension SessionPresence {
  func replacingCamera(_ camera: SpatialCamera) -> SessionPresence {
    .init(boardID: boardID, mode: mode, camera: camera, viewport: viewport,
      focusedItemID: focusedItemID, openProgress: openProgress, documentPageIndex: documentPageIndex,
      selectedItemID: selectedItemID, notebookPageID: notebookPageID)
  }
}
