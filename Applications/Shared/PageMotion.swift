import Foundation
import Observation

#if os(iOS)
  import QuartzCore
  import UIKit
#endif

struct PageNavigationSample: Equatable, Sendable {
  let translation: CGFloat
  let velocity: CGFloat
  let gripY: CGFloat

  init(
    translation: CGFloat,
    velocity: CGFloat,
    gripY: CGFloat = 0.5
  ) {
    self.translation = translation
    self.velocity = velocity
    self.gripY = min(max(gripY, 0), 1)
  }
}

enum PageNavigationPhase: Equatable, Sendable {
  case began(PageNavigationSample)
  case changed(PageNavigationSample)
  case ended(PageNavigationSample)
  case cancelled
}

struct PageMotionAvailability: Equatable, Sendable {
  let previous: Bool
  let next: Bool
}

enum PageMotionPhysics {
  static let projectionDuration: CGFloat = 0.22
  static let commitProgress: CGFloat = 0.34
  static let flickVelocity: CGFloat = 0.65
  static let edgeTravel: CGFloat = 0.06

  static func trackedPosition(
    origin: CGFloat,
    translation: CGFloat,
    extent: CGFloat,
    availability: PageMotionAvailability
  ) -> CGFloat {
    let raw = origin + translation / max(extent, 1)
    if raw > 0, !availability.previous {
      return rubberBanded(raw)
    }
    if raw < 0, !availability.next {
      return -rubberBanded(-raw)
    }
    return min(max(raw, -1), 1)
  }

  static func boundedPresentation(
    _ position: CGFloat,
    availability: PageMotionAvailability
  ) -> CGFloat {
    var bounded = min(max(position, -1), 1)
    if bounded > 0, !availability.previous {
      bounded = min(bounded, edgeTravel)
    }
    if bounded < 0, !availability.next {
      bounded = max(bounded, -edgeTravel)
    }
    return bounded
  }

  /// A negative sheet position exposes the next page; a positive position
  /// exposes the previous one. Projection lets a deliberate flick finish even
  /// when the fingers have not dragged a third of the sheet.
  static func settlementTarget(
    position: CGFloat,
    velocity: CGFloat,
    availability: PageMotionAvailability
  ) -> CGFloat {
    let projected = position + velocity * projectionDuration
    let directionValue: CGFloat
    if abs(projected) >= commitProgress {
      directionValue = projected
    } else if abs(velocity) >= flickVelocity,
      position == 0 || position * velocity > 0
    {
      directionValue = velocity
    } else {
      return 0
    }
    if directionValue < 0, availability.next { return -1 }
    if directionValue > 0, availability.previous { return 1 }
    return 0
  }

  private static func rubberBanded(_ distance: CGFloat) -> CGFloat {
    edgeTravel * (1 - exp(-max(0, distance) / edgeTravel))
  }
}

struct PageMotionSettlement: Equatable, Sendable {
  let start: CGFloat
  let target: CGFloat
  let initialVelocity: CGFloat
  let angularFrequency: CGFloat
  let maximumDuration: TimeInterval

  func sample(at elapsed: TimeInterval) -> (position: CGFloat, velocity: CGFloat) {
    let time = CGFloat(max(0, elapsed))
    let delta = start - target
    let coefficient = initialVelocity + angularFrequency * delta
    let decay = exp(-angularFrequency * time)
    var position = target + (delta + coefficient * time) * decay
    var velocity =
      (initialVelocity
        - angularFrequency * coefficient * time) * decay

    let crossedTarget =
      (target > start && position > target)
      || (target < start && position < target)
    if crossedTarget {
      position = target
      velocity = 0
    }
    return (position, velocity)
  }

  func isComplete(at elapsed: TimeInterval) -> Bool {
    if elapsed >= maximumDuration { return true }
    let current = sample(at: elapsed)
    return abs(current.position - target) < 0.000_8
      && abs(current.velocity) < 0.008
  }
}

/// The curl is a projection of PageMotion's signed sheet coordinate. It never
/// chooses a destination and never advances time. A negative coordinate bends
/// the current sheet away to expose the next one. A positive coordinate lays
/// the previous sheet over the current one.
struct PageCurlProjection: Equatable, Sendable {
  enum TextureSlot: Equatable, Sendable {
    case previous
    case current
    case next
  }

  let progress: CGFloat
  let direction: CGFloat
  let base: TextureSlot
  let moving: TextureSlot

  static func resolve(
    position: CGFloat,
    hasPrevious: Bool,
    hasNext: Bool
  ) -> Self? {
    guard abs(position) > 0.000_1 else { return nil }
    if position < 0, hasNext {
      return Self(
        progress: min(abs(position), 1),
        direction: -1,
        base: .next,
        moving: .current
      )
    }
    if position > 0, hasPrevious {
      return Self(
        progress: min(position, 1),
        direction: 1,
        base: .current,
        moving: .previous
      )
    }
    return nil
  }
}

@MainActor
@Observable
final class PageMotionController: NSObject {
  enum Phase: Equatable {
    case idle
    case tracking
    case settling
  }

  enum Presentation: Equatable {
    case rail
    case dissolve
  }

  private(set) var phase = Phase.idle
  private(set) var presentation = Presentation.rail
  private(set) var position: CGFloat = 0
  private(set) var velocity: CGFloat = 0
  private(set) var gripY: CGFloat = 0.5
  private(set) var dissolveProgress: CGFloat = 1

  var isActive: Bool { phase != .idle }

  @ObservationIgnored private var availability = PageMotionAvailability(
    previous: false,
    next: false
  )
  @ObservationIgnored private var gestureOrigin: CGFloat = 0
  @ObservationIgnored private var extent: CGFloat = 1
  @ObservationIgnored private var settlement: PageMotionSettlement?
  @ObservationIgnored private var settlementStartedAt: TimeInterval = 0
  @ObservationIgnored private var dissolveDuration: TimeInterval = 0
  @ObservationIgnored private var pendingDirection = 0
  @ObservationIgnored private var onCommit: ((Int) -> Void)?
  @ObservationIgnored private var onFinish: (() -> Void)?

  #if os(iOS)
    @ObservationIgnored private var displayLink: CADisplayLink?
  #else
    @ObservationIgnored private var animationTask: Task<Void, Never>?
  #endif

  func begin(
    _ sample: PageNavigationSample,
    extent: CGFloat,
    availability: PageMotionAvailability,
    onCommit: @escaping (Int) -> Void,
    onFinish: @escaping () -> Void
  ) {
    // A dissolve has no spatial coordinate to continue. A new direct gesture
    // takes the durable page at zero and releases the old readout first.
    if presentation == .dissolve, phase != .idle {
      let finish = self.onFinish
      self.onFinish = nil
      finish?()
      position = 0
    }
    stopAnimation()
    presentation = .rail
    dissolveProgress = 1
    self.extent = max(extent, 1)
    self.availability = availability
    self.onCommit = onCommit
    self.onFinish = onFinish
    gripY = sample.gripY
    gestureOrigin = position
    phase = .tracking
    track(sample)
  }

  func track(_ sample: PageNavigationSample) {
    guard phase == .tracking else { return }
    position = PageMotionPhysics.trackedPosition(
      origin: gestureOrigin,
      translation: sample.translation,
      extent: extent,
      availability: availability
    )
    velocity = sample.velocity / extent
  }

  func end(_ sample: PageNavigationSample, reduceMotion: Bool) {
    guard phase == .tracking else { return }
    track(sample)
    let target = PageMotionPhysics.settlementTarget(
      position: position,
      velocity: velocity,
      availability: availability
    )
    settle(to: target, initialVelocity: velocity, reduceMotion: reduceMotion)
  }

  func cancel(reduceMotion: Bool) {
    guard phase != .idle else { return }
    settle(to: 0, initialVelocity: 0, reduceMotion: reduceMotion)
  }

  /// Keyboard navigation uses the same destination, velocity transfer and
  /// settlement as a released direct gesture. It has no second animation
  /// owner and therefore remains interruptible by the next trackpad gesture.
  func select(
    direction: Int,
    availability: PageMotionAvailability,
    reduceMotion: Bool,
    onCommit: @escaping (Int) -> Void,
    onFinish: @escaping () -> Void
  ) {
    guard direction == -1 || direction == 1,
      (direction < 0 && availability.previous)
        || (direction > 0 && availability.next)
    else { return }
    if phase != .idle { reset() }
    stopAnimation()
    presentation = .rail
    dissolveProgress = 1
    self.availability = availability
    self.onCommit = onCommit
    self.onFinish = onFinish
    position = 0
    velocity = CGFloat(-direction) * 0.85
    gripY = 0.5
    settle(
      to: CGFloat(-direction),
      initialVelocity: velocity,
      reduceMotion: reduceMotion
    )
  }

  /// A durable selection received from another input owner already names the
  /// new page. Present it from the old adjacent page, then settle to the new
  /// canonical zero without committing the selection a second time.
  func presentCommittedChange(
    from offset: CGFloat,
    reduceMotion: Bool,
    onFinish: @escaping () -> Void
  ) {
    guard offset != 0 else {
      onFinish()
      return
    }
    if phase != .idle { reset() }
    stopAnimation()
    presentation = .rail
    dissolveProgress = 1
    availability = PageMotionAvailability(previous: true, next: true)
    onCommit = nil
    self.onFinish = onFinish
    position = min(max(offset, -1), 1)
    velocity = 0
    gripY = 0.5
    settle(to: 0, initialVelocity: 0, reduceMotion: reduceMotion)
  }

  /// A non-adjacent remote jump has no honest spatial path. The same temporal
  /// owner therefore performs one compact dissolve instead of pretending the
  /// unseen intermediate pages crossed the screen.
  func presentDissolve(
    duration: TimeInterval = 0.14,
    onFinish: @escaping () -> Void
  ) {
    if phase != .idle { reset() }
    stopAnimation()
    presentation = .dissolve
    phase = .settling
    position = 0
    velocity = 0
    gripY = 0.5
    dissolveProgress = 0
    dissolveDuration = max(0.001, duration)
    settlementStartedAt = ProcessInfo.processInfo.systemUptime
    settlement = nil
    pendingDirection = 0
    onCommit = nil
    self.onFinish = onFinish
    startAnimation()
  }

  /// Camera movement and page movement cannot own the same pixels. If a pinch
  /// begins while a released page is settling, finish that already chosen
  /// destination before handing the surface to the camera.
  func finishBeforeCompetingGesture() {
    guard phase == .settling else { return }
    if presentation == .dissolve {
      dissolveProgress = 1
      completeSettlement()
      return
    }
    guard let settlement else { return }
    position = settlement.target
    completeSettlement()
  }

  func reset() {
    stopAnimation()
    phase = .idle
    presentation = .rail
    position = 0
    velocity = 0
    gripY = 0.5
    dissolveProgress = 1
    settlement = nil
    dissolveDuration = 0
    pendingDirection = 0
    onCommit = nil
    let finish = onFinish
    onFinish = nil
    finish?()
  }

  private func settle(
    to target: CGFloat,
    initialVelocity: CGFloat,
    reduceMotion: Bool
  ) {
    stopAnimation()
    presentation = .rail
    dissolveProgress = 1
    let frequency: CGFloat = reduceMotion ? 34 : 22
    let duration: TimeInterval = reduceMotion ? 0.14 : 0.30
    settlement = PageMotionSettlement(
      start: position,
      target: target,
      initialVelocity: initialVelocity,
      angularFrequency: frequency,
      maximumDuration: duration
    )
    settlementStartedAt = ProcessInfo.processInfo.systemUptime
    pendingDirection = target < 0 ? 1 : (target > 0 ? -1 : 0)
    phase = .settling

    if abs(position - target) < 0.000_1 {
      position = target
      completeSettlement()
      return
    }
    startAnimation()
  }

  private func advance(at timestamp: TimeInterval) {
    if phase == .settling, presentation == .dissolve {
      let elapsed = max(0, timestamp - settlementStartedAt)
      let linear = min(1, elapsed / dissolveDuration)
      let eased = linear * linear * (3 - 2 * linear)
      dissolveProgress = CGFloat(eased)
      if linear >= 1 { completeSettlement() }
      return
    }
    guard phase == .settling, let settlement else {
      stopAnimation()
      return
    }
    let elapsed = max(0, timestamp - settlementStartedAt)
    let sample = settlement.sample(at: elapsed)
    position = PageMotionPhysics.boundedPresentation(
      sample.position,
      availability: availability
    )
    velocity = sample.velocity
    if settlement.isComplete(at: elapsed) {
      position = settlement.target
      velocity = 0
      completeSettlement()
    }
  }

  private func completeSettlement() {
    stopAnimation()
    let direction = pendingDirection
    pendingDirection = 0
    if direction != 0 {
      onCommit?(direction)
    }
    phase = .idle
    presentation = .rail
    position = 0
    velocity = 0
    gripY = 0.5
    dissolveProgress = 1
    settlement = nil
    dissolveDuration = 0
    onCommit = nil
    let finish = onFinish
    onFinish = nil
    finish?()
  }

  private func startAnimation() {
    #if os(iOS)
      let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: 60,
        maximum: 120,
        preferred: 120
      )
      link.add(to: .main, forMode: .common)
      displayLink = link
    #else
      animationTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(8))
          guard !Task.isCancelled, let self else { return }
          advance(at: ProcessInfo.processInfo.systemUptime)
          if phase != .settling { return }
        }
      }
    #endif
  }

  private func stopAnimation() {
    #if os(iOS)
      displayLink?.invalidate()
      displayLink = nil
    #else
      animationTask?.cancel()
      animationTask = nil
    #endif
  }

  #if os(iOS)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
      advance(at: link.timestamp)
    }
  #endif
}
