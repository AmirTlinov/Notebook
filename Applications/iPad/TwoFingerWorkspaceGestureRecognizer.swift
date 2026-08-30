import UIKit

struct TwoFingerNavigationDecision: Equatable {
  let direction: Int
}

enum TwoFingerMotionIntent: Equatable {
  case undecided
  case navigation
  case magnification
}

/// Chooses the owner of one two-finger sequence from the motion of both
/// fingers. A page swipe is coherent translation; a pinch is differential
/// motion. The short evidence window lets the second finger join before the
/// first hardware sample can steal the sequence as a pinch.
enum TwoFingerIntentArbiter {
  static let activationTravel: CGFloat = 14
  static let magnificationActivation: CGFloat = 0.045
  static let evidenceDelay: TimeInterval = 0.055
  static let participatingTravel: CGFloat = 4

  static func isOpeningApproach(magnification: CGFloat) -> Bool {
    magnification > 1
  }

  static func resolve(
    isPageOpen: Bool,
    translation: CGPoint,
    fingerDisplacements: [CGPoint],
    magnification: CGFloat,
    elapsed: TimeInterval
  ) -> TwoFingerMotionIntent {
    guard fingerDisplacements.count == 2 else { return .undecided }
    let first = fingerDisplacements[0]
    let second = fingerDisplacements[1]
    let firstTravel = hypot(first.x, first.y)
    let secondTravel = hypot(second.x, second.y)
    let maximumTravel = max(firstTravel, secondTravel)
    let bothParticipate = min(firstTravel, secondTravel) >= participatingTravel
    let coherent = bothParticipate
      && first.x * second.x + first.y * second.y > 0
    let horizontal = abs(translation.x) >= abs(translation.y)
    let horizontalAgreement = first.x * second.x > 0
      && min(abs(first.x), abs(second.x)) >= participatingTravel

    if maximumTravel >= activationTravel, coherent,
      (!isPageOpen || (horizontal && horizontalAgreement))
    {
      return .navigation
    }

    let scaleEvidence = abs(log(max(magnification, 0.001)))
    guard scaleEvidence >= magnificationActivation else { return .undecided }
    let differentialTravel = hypot(
      second.x - first.x,
      second.y - first.y
    ) / 2
    let centroidTravel = hypot(translation.x, translation.y)
    let radialMotionOwnsTheGesture = differentialTravel
      >= max(participatingTravel, centroidTravel * 0.8)
    guard radialMotionOwnsTheGesture,
      bothParticipate || elapsed >= evidenceDelay
    else { return .undecided }
    return .magnification
  }
}

enum TwoFingerGestureClassifier {
  static let navigationDistance: CGFloat = 44
  static let navigationSpeed: CGFloat = 520
  static let minimumFingerTravel: CGFloat = 8

  static func navigation(
    translation: CGPoint,
    velocity: CGPoint,
    fingerDisplacements: [CGPoint]
  ) -> TwoFingerNavigationDecision? {
    guard fingerDisplacements.count == 2 else { return nil }
    guard abs(translation.x) >= abs(translation.y) else { return nil }
    let distance = translation.x
    let speed = velocity.x
    guard abs(distance) >= navigationDistance
      || abs(speed) >= navigationSpeed
    else { return nil }

    let fingerTravel = fingerDisplacements.map {
      $0.x
    }
    guard fingerTravel[0] * fingerTravel[1] > 0,
      fingerTravel.allSatisfy({ abs($0) >= minimumFingerTravel })
    else { return nil }

    let directionValue = abs(distance) >= navigationDistance
      ? distance
      : speed
    return TwoFingerNavigationDecision(
      direction: directionValue < 0 ? 1 : -1
    )
  }
}

@MainActor
final class TwoFingerPaperGestureRecognizer: UIGestureRecognizer {
  enum Intent {
    case undecided
    case tap
    case hold
    case navigation
    case magnification
  }

  private static let holdDelay = Duration.milliseconds(340)
  private static let tapMovement: CGFloat = 16
  private static let velocityWindow: TimeInterval = 0.08

  private struct CentroidSample {
    let timestamp: TimeInterval
    let point: CGPoint
  }

  private var activeTouches: [ObjectIdentifier: UITouch] = [:]
  private var startLocations: [ObjectIdentifier: CGPoint] = [:]
  private var startTimestamp: TimeInterval?
  private var startCentroid: CGPoint?
  private var startDistance: CGFloat?
  private var centroidSamples: [CentroidSample] = []
  private var holdTask: Task<Void, Never>?
  private var maximumFingerMovement: CGFloat = 0
  private var magnificationSamples: [(timestamp: TimeInterval, value: CGFloat)] = []

  private(set) var intent = Intent.undecided
  private(set) var translation = CGPoint.zero
  private(set) var velocity = CGPoint.zero
  private(set) var fingerDisplacements: [CGPoint] = []
  private(set) var navigationDecision: TwoFingerNavigationDecision?
  private(set) var magnification: CGFloat = 1
  private(set) var magnificationVelocity: CGFloat = 0
  private(set) var isOpeningApproach = false
  private(set) var centroid = CGPoint.zero

  var isPageOpen = false

  var startCentroidValue: CGPoint { startCentroid ?? centroid }
  var gestureElapsed: TimeInterval {
    guard let startTimestamp else { return 0 }
    return max(0, currentTimestamp() - startTimestamp)
  }

  override func touchesBegan(
    _ touches: Set<UITouch>,
    with event: UIEvent
  ) {
    for touch in touches {
      activeTouches[ObjectIdentifier(touch)] = touch
    }
    guard activeTouches.count <= 2 else {
      finishAsInvalid()
      return
    }
    guard activeTouches.count == 2, startCentroid == nil else { return }
    beginTrackingPair()
  }

  override func touchesMoved(
    _ touches: Set<UITouch>,
    with event: UIEvent
  ) {
    guard startCentroid != nil else { return }
    updateMetrics()

    switch intent {
    case .undecided:
      let motionIntent = TwoFingerIntentArbiter.resolve(
        isPageOpen: isPageOpen,
        translation: translation,
        fingerDisplacements: fingerDisplacements,
        magnification: magnification,
        elapsed: max(0, currentTimestamp() - (startTimestamp ?? 0))
      )
      switch motionIntent {
      case .navigation:
        cancelHold()
        intent = .navigation
        state = .began
      case .magnification:
        cancelHold()
        let isOpeningApproach = TwoFingerIntentArbiter.isOpeningApproach(
          magnification: magnification
        )
        beginMagnificationFromCurrentPair()
        self.isOpeningApproach = isOpeningApproach
        intent = .magnification
        state = .began
      case .undecided:
        break
      }
    case .magnification where state == .began || state == .changed:
      state = .changed
    case .navigation where state == .began || state == .changed:
      state = .changed
    case .hold where state == .began || state == .changed:
      state = .changed
    default:
      break
    }
  }

  override func touchesEnded(
    _ touches: Set<UITouch>,
    with event: UIEvent
  ) {
    guard startCentroid != nil else {
      state = .failed
      return
    }
    updateMetrics()
    cancelHold()
    navigationDecision = TwoFingerGestureClassifier.navigation(
      translation: translation,
      velocity: velocity,
      fingerDisplacements: fingerDisplacements
    )

    switch intent {
    case .hold:
      state = .ended
    case .navigation:
      state = .ended
    case .magnification:
      state = .ended
    case .undecided where maximumFingerMovement <= Self.tapMovement:
      intent = .tap
      state = .recognized
    case .undecided where navigationDecision != nil:
      intent = .navigation
      state = .recognized
    case .tap, .undecided:
      state = .failed
    }
  }

  override func touchesCancelled(
    _ touches: Set<UITouch>,
    with event: UIEvent
  ) {
    cancelHold()
    if state == .began || state == .changed {
      state = .cancelled
    } else {
      state = .failed
    }
  }

  override func reset() {
    super.reset()
    cancelHold()
    activeTouches.removeAll(keepingCapacity: true)
    startLocations.removeAll(keepingCapacity: true)
    startTimestamp = nil
    startCentroid = nil
    startDistance = nil
    centroidSamples.removeAll(keepingCapacity: true)
    maximumFingerMovement = 0
    intent = .undecided
    translation = .zero
    velocity = .zero
    fingerDisplacements = []
    navigationDecision = nil
    magnification = 1
    magnificationVelocity = 0
    isOpeningApproach = false
    centroid = .zero
    magnificationSamples.removeAll(keepingCapacity: true)
  }

  private func beginTrackingPair() {
    startLocations = activeTouches.mapValues { $0.location(in: view) }
    let centroid = currentCentroid()
    startCentroid = centroid
    self.centroid = centroid
    startDistance = currentDistance()
    startTimestamp = currentTimestamp()
    centroidSamples = [
      CentroidSample(timestamp: currentTimestamp(), point: centroid)
    ]
    holdTask = Task { [weak self] in
      try? await Task.sleep(for: Self.holdDelay)
      guard !Task.isCancelled,
        let self,
        state == .possible,
        activeTouches.count == 2,
        maximumFingerMovement <= Self.tapMovement
      else { return }
      intent = .hold
      state = .began
    }
  }

  /// The second finger may arrive a few hardware samples after the first one.
  /// The intent arbiter already waits for both fingers, so the owned pinch must
  /// start from that confirmed pair rather than from their staggered touchdown.
  /// Otherwise the first reported scale can be much larger than the motion the
  /// person actually made.
  private func beginMagnificationFromCurrentPair() {
    let timestamp = currentTimestamp()
    startLocations = activeTouches.mapValues { $0.location(in: view) }
    let current = currentCentroid()
    startCentroid = current
    centroid = current
    startDistance = currentDistance()
    startTimestamp = timestamp
    translation = .zero
    velocity = .zero
    fingerDisplacements = activeTouches.values.map { _ in .zero }
    magnification = 1
    magnificationVelocity = 0
    centroidSamples = [CentroidSample(timestamp: timestamp, point: current)]
    magnificationSamples = [(timestamp: timestamp, value: 1)]
  }

  private func updateMetrics() {
    guard let startCentroid else { return }
    let current = currentCentroid()
    centroid = current
    translation = CGPoint(
      x: current.x - startCentroid.x,
      y: current.y - startCentroid.y
    )

    fingerDisplacements = startLocations.compactMap { identifier, start in
      guard let touch = activeTouches[identifier] else { return nil }
      let location = touch.location(in: view)
      let displacement = CGPoint(
        x: location.x - start.x,
        y: location.y - start.y
      )
      maximumFingerMovement = max(
        maximumFingerMovement,
        hypot(displacement.x, displacement.y)
      )
      return displacement
    }

    let timestamp = currentTimestamp()
    if let startDistance, startDistance > 0 {
      magnification = max(currentDistance() / startDistance, 0.001)
      magnificationSamples.append((timestamp, magnification))
      magnificationSamples.removeAll {
        timestamp - $0.timestamp > Self.velocityWindow
      }
      if let firstScale = magnificationSamples.first,
        let lastScale = magnificationSamples.last,
        lastScale.timestamp - firstScale.timestamp > 0.001
      {
        magnificationVelocity =
          (lastScale.value - firstScale.value)
          / (lastScale.timestamp - firstScale.timestamp)
      }
    }
    centroidSamples.append(CentroidSample(timestamp: timestamp, point: current))
    centroidSamples.removeAll {
      timestamp - $0.timestamp > Self.velocityWindow
    }
    guard let first = centroidSamples.first,
      let last = centroidSamples.last,
      last.timestamp - first.timestamp > 0.001
    else { return }
    let elapsed = last.timestamp - first.timestamp
    velocity = CGPoint(
      x: (last.point.x - first.point.x) / elapsed,
      y: (last.point.y - first.point.y) / elapsed
    )
  }

  private func currentCentroid() -> CGPoint {
    let locations = activeTouches.values.map { $0.location(in: view) }
    guard !locations.isEmpty else { return .zero }
    return CGPoint(
      x: locations.reduce(0) { $0 + $1.x } / CGFloat(locations.count),
      y: locations.reduce(0) { $0 + $1.y } / CGFloat(locations.count)
    )
  }

  private func currentDistance() -> CGFloat {
    let locations = activeTouches.values.map { $0.location(in: view) }
    guard locations.count == 2 else { return 0 }
    return hypot(
      locations[0].x - locations[1].x,
      locations[0].y - locations[1].y
    )
  }

  private func currentTimestamp() -> TimeInterval {
    activeTouches.values.map(\.timestamp).max() ?? 0
  }

  private func finishAsInvalid() {
    cancelHold()
    if state == .began || state == .changed {
      state = .cancelled
    } else {
      state = .failed
    }
  }

  private func cancelHold() {
    holdTask?.cancel()
    holdTask = nil
  }

}
