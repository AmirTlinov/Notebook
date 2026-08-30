import UIKit

struct TwoFingerNavigationDecision: Equatable {
  let horizontal: Bool
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
    let horizontal = abs(translation.x) >= abs(translation.y)
    let distance = horizontal ? translation.x : translation.y
    let speed = horizontal ? velocity.x : velocity.y
    guard abs(distance) >= navigationDistance
      || abs(speed) >= navigationSpeed
    else { return nil }

    let fingerTravel = fingerDisplacements.map {
      horizontal ? $0.x : $0.y
    }
    guard fingerTravel[0] * fingerTravel[1] > 0,
      fingerTravel.allSatisfy({ abs($0) >= minimumFingerTravel })
    else { return nil }

    let directionValue = abs(distance) >= navigationDistance
      ? distance
      : speed
    return TwoFingerNavigationDecision(
      horizontal: horizontal,
      direction: directionValue < 0 ? 1 : -1
    )
  }
}

@MainActor
final class TwoFingerPageGestureController: NSObject, UIGestureRecognizerDelegate {
  var onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
  var onUndo: () -> Void

  private weak var hostView: UIView?
  private weak var paperView: UIView?
  private var recognizer: TwoFingerPaperGestureRecognizer?
  private var repeatTask: Task<Void, Never>?

  init(
    onNavigate: @escaping (_ horizontal: Bool, _ direction: Int) -> Void,
    onUndo: @escaping () -> Void
  ) {
    self.onNavigate = onNavigate
    self.onUndo = onUndo
  }

  func install(on hostView: UIView, inside paperView: UIView) {
    guard self.hostView !== hostView || self.paperView !== paperView else {
      return
    }
    uninstall()

    let recognizer = TwoFingerPaperGestureRecognizer(
      target: self,
      action: #selector(handleGesture)
    )
    recognizer.allowedTouchTypes = [
      NSNumber(value: UITouch.TouchType.direct.rawValue)
    ]
    recognizer.cancelsTouchesInView = true
    recognizer.delaysTouchesBegan = false
    recognizer.delaysTouchesEnded = false
    recognizer.delegate = self
    hostView.addGestureRecognizer(recognizer)

    self.hostView = hostView
    self.paperView = paperView
    self.recognizer = recognizer
  }

  func uninstall() {
    stopRepeating()
    if let recognizer {
      hostView?.removeGestureRecognizer(recognizer)
    }
    recognizer = nil
    hostView = nil
    paperView = nil
  }

  @objc private func handleGesture(
    _ recognizer: TwoFingerPaperGestureRecognizer
  ) {
    switch recognizer.state {
    case .began where recognizer.intent == .hold:
      onUndo()
      startRepeating()
    case .ended:
      stopRepeating()
      switch recognizer.intent {
      case .tap:
        onUndo()
      case .navigation:
        if let decision = recognizer.navigationDecision {
          onNavigate(decision.horizontal, decision.direction)
        }
      case .hold, .undecided:
        break
      }
    case .cancelled, .failed:
      stopRepeating()
    default:
      break
    }
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
    shouldReceive touch: UITouch
  ) -> Bool {
    guard let paperView, paperView.window != nil else { return false }
    return paperView.bounds.contains(touch.location(in: paperView))
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

@MainActor
final class TwoFingerPaperGestureRecognizer: UIGestureRecognizer {
  enum Intent {
    case undecided
    case tap
    case hold
    case navigation
  }

  private static let holdDelay = Duration.milliseconds(340)
  private static let tapMovement: CGFloat = 16
  private static let navigationActivation: CGFloat = 14
  private static let velocityWindow: TimeInterval = 0.08

  private struct CentroidSample {
    let timestamp: TimeInterval
    let point: CGPoint
  }

  private var activeTouches: [ObjectIdentifier: UITouch] = [:]
  private var startLocations: [ObjectIdentifier: CGPoint] = [:]
  private var startCentroid: CGPoint?
  private var centroidSamples: [CentroidSample] = []
  private var holdTask: Task<Void, Never>?
  private var maximumFingerMovement: CGFloat = 0

  private(set) var intent = Intent.undecided
  private(set) var translation = CGPoint.zero
  private(set) var velocity = CGPoint.zero
  private(set) var fingerDisplacements: [CGPoint] = []
  private(set) var navigationDecision: TwoFingerNavigationDecision?

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
    case .undecided where maximumFingerMovement
      >= Self.navigationActivation:
      cancelHold()
      intent = .navigation
      state = .began
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
    centroidSamples.removeAll(keepingCapacity: true)
    maximumFingerMovement = 0
    intent = .undecided
    translation = .zero
    velocity = .zero
    fingerDisplacements = []
    navigationDecision = nil
  }

  private func beginTrackingPair() {
    startLocations = activeTouches.mapValues { $0.location(in: view) }
    let centroid = currentCentroid()
    startCentroid = centroid
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
