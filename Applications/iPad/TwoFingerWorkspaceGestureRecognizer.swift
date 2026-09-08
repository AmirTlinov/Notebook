import UIKit

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
  static let activationTravel: CGFloat = 12
  static let magnificationActivation: CGFloat = 0.01
  static let evidenceDelay: TimeInterval = 0.055
  static let participatingTravel: CGFloat = 4

  static func isOpeningApproach(magnification: CGFloat) -> Bool {
    magnification > 1
  }

  static func resolve(
    defersHorizontalMotionToPageTurn: Bool,
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
    let coherent =
      bothParticipate
      && first.x * second.x + first.y * second.y > 0
    let horizontal = abs(translation.x) >= abs(translation.y)
    let horizontalAgreement =
      first.x * second.x > 0
      && min(abs(first.x), abs(second.x)) >= participatingTravel

    if maximumTravel >= activationTravel, coherent,
      !defersHorizontalMotionToPageTurn || (horizontal && horizontalAgreement)
    {
      return .navigation
    }

    let scaleEvidence = abs(log(max(magnification, 0.001)))
    guard scaleEvidence >= magnificationActivation else { return .undecided }
    let differentialTravel =
      hypot(
        second.x - first.x,
        second.y - first.y
      ) / 2
    let centroidTravel = hypot(translation.x, translation.y)
    let radialMotionOwnsTheGesture =
      differentialTravel
      >= max(participatingTravel, centroidTravel * 0.8)
    guard radialMotionOwnsTheGesture,
      bothParticipate || elapsed >= evidenceDelay
    else { return .undecided }
    return .magnification
  }
}

/// Undo owns a quiet two-finger contact. Once the pair travels like a pinch or
/// a swipe, that observed motion keeps its meaning through release.
enum TwoFingerUndoClassifier {
  static let maximumFingerTravel: CGFloat = 8
  static let maximumCentroidTravel: CGFloat = 4
  static let maximumRelativeTravel: CGFloat = 3.5
  static let maximumTapDuration: TimeInterval = 0.26

  static func remainsStationary(
    maximumFingerTravel: CGFloat,
    maximumCentroidTravel: CGFloat,
    maximumRelativeTravel: CGFloat
  ) -> Bool {
    maximumFingerTravel <= Self.maximumFingerTravel
      && maximumCentroidTravel <= Self.maximumCentroidTravel
      && maximumRelativeTravel <= Self.maximumRelativeTravel
  }

  static func isTap(
    maximumFingerTravel: CGFloat,
    maximumCentroidTravel: CGFloat,
    maximumRelativeTravel: CGFloat,
    elapsed: TimeInterval
  ) -> Bool {
    elapsed <= maximumTapDuration
      && remainsStationary(
        maximumFingerTravel: maximumFingerTravel,
        maximumCentroidTravel: maximumCentroidTravel,
        maximumRelativeTravel: maximumRelativeTravel
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
  private var maximumCentroidMovement: CGFloat = 0
  private var maximumRelativeMovement: CGFloat = 0
  private var magnificationSamples: [(timestamp: TimeInterval, value: CGFloat)] = []
  private var fingerSequenceRevision: UInt64?
  private let inputSource = UUID()

  private(set) var intent = Intent.undecided
  private(set) var translation = CGPoint.zero
  private(set) var velocity = CGPoint.zero
  private(set) var fingerDisplacements: [CGPoint] = []
  private(set) var magnification: CGFloat = 1
  private(set) var magnificationVelocity: CGFloat = 0
  private(set) var isOpeningApproach = false
  private(set) var centroid = CGPoint.zero

  var defersHorizontalMotionToPageTurn = false
  weak var inputGate: NotebookInputGate? {
    didSet {
      guard oldValue !== inputGate else { return }
      oldValue?.unregisterFingerCancellation(source: inputSource)
      cancelForExclusiveInput()
      inputGate?.registerFingerCancellation(source: inputSource) { [weak self] in
        self?.cancelForExclusiveInput()
      }
    }
  }

  var permitsUndoRepetition: Bool {
    intent == .hold && (state == .began || state == .changed) && fingerSequenceIsAccepted
  }

  isolated deinit {
    holdTask?.cancel()
    inputGate?.unregisterFingerCancellation(source: inputSource)
  }

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
    if fingerSequenceRevision == nil {
      guard let revision = inputGate?.beginFingerSequence() else {
        finishAsInvalid()
        return
      }
      fingerSequenceRevision = revision
    }
    guard fingerSequenceIsAccepted else {
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
    guard fingerSequenceIsAccepted else {
      finishAsInvalid()
      return
    }
    updateMetrics()

    switch intent {
    case .undecided:
      let motionIntent = TwoFingerIntentArbiter.resolve(
        defersHorizontalMotionToPageTurn: defersHorizontalMotionToPageTurn,
        translation: translation,
        fingerDisplacements: fingerDisplacements,
        magnification: magnification,
        elapsed: max(0, currentTimestamp() - (startTimestamp ?? 0))
      )
      switch motionIntent {
      case .navigation:
        cancelHold()
        if defersHorizontalMotionToPageTurn {
          state = .failed
          return
        }
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
        if !undoContactRemainsStationary { cancelHold() }
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
    guard fingerSequenceIsAccepted else {
      finishAsInvalid()
      return
    }
    updateMetrics()
    cancelHold()
    let releaseIntent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: defersHorizontalMotionToPageTurn,
      translation: translation,
      fingerDisplacements: fingerDisplacements,
      magnification: magnification,
      elapsed: gestureElapsed
    )

    switch intent {
    case .hold:
      state = .ended
    case .navigation:
      state = .ended
    case .magnification:
      state = .ended
    case .undecided
    where TwoFingerUndoClassifier.isTap(
      maximumFingerTravel: maximumFingerMovement,
      maximumCentroidTravel: maximumCentroidMovement,
      maximumRelativeTravel: maximumRelativeMovement,
      elapsed: gestureElapsed
    ):
      intent = .tap
      state = .recognized
    case .undecided where releaseIntent == .navigation:
      if defersHorizontalMotionToPageTurn {
        state = .failed
      } else {
        intent = .navigation
        state = .recognized
      }
    case .tap, .undecided:
      state = .failed
    }
  }

  override func touchesCancelled(
    _ touches: Set<UITouch>,
    with event: UIEvent
  ) {
    finishAsInvalid()
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
    maximumCentroidMovement = 0
    maximumRelativeMovement = 0
    intent = .undecided
    translation = .zero
    velocity = .zero
    fingerDisplacements = []
    magnification = 1
    magnificationVelocity = 0
    isOpeningApproach = false
    centroid = .zero
    magnificationSamples.removeAll(keepingCapacity: true)
    fingerSequenceRevision = nil
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
        fingerSequenceIsAccepted,
        undoContactRemainsStationary
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
    maximumCentroidMovement = max(
      maximumCentroidMovement,
      hypot(translation.x, translation.y)
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
    if fingerDisplacements.count == 2 {
      maximumRelativeMovement = max(
        maximumRelativeMovement,
        hypot(
          fingerDisplacements[1].x - fingerDisplacements[0].x,
          fingerDisplacements[1].y - fingerDisplacements[0].y
        ) / 2
      )
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
    switch state {
    case .began, .changed: state = .cancelled
    case .possible: state = .failed
    default: break
    }
  }

  private func cancelForExclusiveInput() {
    guard fingerSequenceRevision != nil,
      state == .possible || state == .began || state == .changed else { return }
    finishAsInvalid()
  }

  private func cancelHold() {
    holdTask?.cancel()
    holdTask = nil
  }

  private var fingerSequenceIsAccepted: Bool {
    guard let fingerSequenceRevision else { return false }
    return inputGate?.acceptsFingerSequence(fingerSequenceRevision)
      == true
  }

  private var undoContactRemainsStationary: Bool {
    TwoFingerUndoClassifier.remainsStationary(
      maximumFingerTravel: maximumFingerMovement,
      maximumCentroidTravel: maximumCentroidMovement,
      maximumRelativeTravel: maximumRelativeMovement
    )
  }

}
