import UIKit

struct TwoFingerNavigationDecision: Equatable {
  let direction: Int
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
  private static let navigationActivation: CGFloat = 14
  private static let magnificationActivation: CGFloat = 0.045
  private static let velocityWindow: TimeInterval = 0.08

  private struct CentroidSample {
    let timestamp: TimeInterval
    let point: CGPoint
  }

  private var activeTouches: [ObjectIdentifier: UITouch] = [:]
  private var startLocations: [ObjectIdentifier: CGPoint] = [:]
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
  private(set) var centroid = CGPoint.zero

  var startCentroidValue: CGPoint { startCentroid ?? centroid }

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
    case .undecided where abs(log(max(magnification, 0.001)))
      >= Self.magnificationActivation:
      cancelHold()
      intent = .magnification
      state = .began
    case .undecided where maximumFingerMovement >= Self.navigationActivation
      && hasCoherentTranslation:
      cancelHold()
      intent = .navigation
      state = .began
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
    centroid = .zero
    magnificationSamples.removeAll(keepingCapacity: true)
  }

  private func beginTrackingPair() {
    startLocations = activeTouches.mapValues { $0.location(in: view) }
    let centroid = currentCentroid()
    startCentroid = centroid
    self.centroid = centroid
    startDistance = currentDistance()
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

  /// A pan starts only after both fingers agree on one direction. Waiting for
  /// that agreement prevents the first moving finger of a wide pinch from
  /// stealing the whole sequence as navigation.
  private var hasCoherentTranslation: Bool {
    guard fingerDisplacements.count == 2 else { return false }
    let first = fingerDisplacements[0]
    let second = fingerDisplacements[1]
    let firstTravel = hypot(first.x, first.y)
    let secondTravel = hypot(second.x, second.y)
    guard min(firstTravel, secondTravel) >= 4 else { return false }
    return first.x * second.x + first.y * second.y > 0
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
