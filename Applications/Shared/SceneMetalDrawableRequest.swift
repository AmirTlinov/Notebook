import Foundation
import QuartzCore
import Metal

/// One finite acquisition for a physical renderer. Cancellation revokes its
/// result; the outstanding worker and its pool grants drain before replacement.
final class SceneMetalDrawableRequest: @unchecked Sendable {
  struct Timing: Sendable {
    let requested, workerBegan, nextDrawableBegan, nextDrawableReturned, drained: TimeInterval
    let mainActorDeliveryBeforeTake: TimeInterval?
    let taken: TimeInterval
  }
  struct Pool: @unchecked Sendable {
    let layer: CAMetalLayer
    let reservation: RasterReservation?
    let owner: AnyObject?
    let byteCeiling: Int?
    let size: CGSize
    @MainActor init(layer: CAMetalLayer, reservation: RasterReservation?, owner: AnyObject? = nil,
      byteCeiling: Int? = nil) {
      self.layer = layer; self.reservation = reservation; self.owner = owner
      self.byteCeiling = byteCeiling; size = layer.drawableSize
      layer.allowsNextDrawableTimeout = true
    }
  }
  struct Acquired {
    let drawable: any CAMetalDrawable
    let timing: Timing?
  }
  private let lock = NSLock()
  private var pools: [Pool]
  private let requestedAt: TimeInterval?
  private var acquisitionTimes: (workerBegan: TimeInterval, began: TimeInterval, returned: TimeInterval)?
  private var drainedAt: TimeInterval?
  private var mainDeliveryAt: TimeInterval?
  private var cancelled = false
  private var started = false
  private var failed = false
  private var workerFinished = false
  private var drained = false
  private var drawables: [any CAMetalDrawable]?
  private var drainCallbacks: [@MainActor @Sendable () -> Void] = []

  @MainActor convenience init(layer: CAMetalLayer, reservation: RasterReservation?, measured: Bool) {
    self.init(pools: [.init(layer: layer, reservation: reservation)], measured: measured)
  }
  init(pools: [Pool], measured: Bool = false) {
    precondition(!pools.isEmpty && pools.count <= 256)
    self.pools = pools; requestedAt = measured ? CACurrentMediaTime() : nil
  }
  func start(completed callback: @escaping @MainActor @Sendable () -> Void) {
    precondition(lock.withLock { if started { return false }; started = true; return true })
    Task.detached(priority: .userInitiated) { [self] in
      let workerBegan = requestedAt.map { _ in CACurrentMediaTime() }
      autoreleasepool {
        let borrowed = lock.withLock { pools }
        let began = requestedAt.map { _ in CACurrentMediaTime() }
        var values: [any CAMetalDrawable] = []
        for pool in borrowed {
          if isCancelled { break }
          guard let value = pool.layer.nextDrawable(),
            value.texture.width == Int(pool.size.width), value.texture.height == Int(pool.size.height),
            pool.byteCeiling.map({ value.texture.allocatedSize <= $0 }) ?? true else { break }
          values.append(value)
        }
        let returned = requestedAt.map { _ in CACurrentMediaTime() }
        lock.withLock {
          failed = !cancelled && values.count != borrowed.count
          if !cancelled && !failed { drawables = values }
          if let workerBegan, let began, let returned { acquisitionTimes = (workerBegan, began, returned) }
        }
        withExtendedLifetime(borrowed) {}
      }
      lock.withLock {
        workerFinished = true
        if requestedAt != nil { drainedAt = CACurrentMediaTime() }
      }
      await MainActor.run {
        let callbacks = lock.withLock {
          // Release physical pool borrows on their owner before a terminal
          // stop can observe drain. The worker's local borrow has already left.
          if cancelled || failed { pools.removeAll() }
          drained = true
          if requestedAt != nil { mainDeliveryAt = CACurrentMediaTime() }
          let callbacks = drainCallbacks; drainCallbacks.removeAll()
          return callbacks
        }
        callbacks.forEach { $0() }; callback()
      }
    }
  }
  var hasFailed: Bool { lock.withLock { drained && !cancelled && failed } }
  var isCancelled: Bool { lock.withLock { cancelled } }
  var isDrained: Bool { lock.withLock { drained } }
  @MainActor func takeAll() -> [any CAMetalDrawable]? {
    lock.withLock {
      guard workerFinished, !cancelled, let drawables else { return nil }
      self.drawables = nil; pools.removeAll(); return drawables
    }
  }
  @MainActor func take() -> Acquired? {
    lock.withLock {
      guard workerFinished, !cancelled, let drawables, drawables.count == 1 else { return nil }
      self.drawables = nil
      pools.removeAll()
      let timing: Timing?
      if let requestedAt, let acquisitionTimes, let drainedAt {
        timing = .init(requested: requestedAt, workerBegan: acquisitionTimes.workerBegan,
          nextDrawableBegan: acquisitionTimes.began, nextDrawableReturned: acquisitionTimes.returned,
          drained: drainedAt, mainActorDeliveryBeforeTake: mainDeliveryAt, taken: CACurrentMediaTime())
      } else { timing = nil }
      return .init(drawable: drawables[0], timing: timing)
    }
  }
  func revoke() {
    lock.withLock { cancelled = true; drawables = nil }
  }
  @MainActor @discardableResult func cancel() -> Bool {
    lock.withLock {
      cancelled = true; drawables = nil
      if workerFinished { pools.removeAll(); return true }
      return false
    }
  }
  @MainActor func holds(_ value: RasterReservation) -> Bool { pools.contains { $0.reservation === value } }
  @MainActor func whenDrained(_ callback: @escaping @MainActor @Sendable () -> Void) {
    let alreadyDrained = lock.withLock {
      if drained { return true }
      drainCallbacks.append(callback); return false
    }
    if alreadyDrained { callback() }
  }
}
