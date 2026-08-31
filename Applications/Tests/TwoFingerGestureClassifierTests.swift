import XCTest
@testable import Notebook

final class TwoFingerGestureClassifierTests: XCTestCase {
  @MainActor
  func testPencilInvalidatesAnAlreadyStartedFingerSequence() throws {
    let gate = PencilInputGate()
    let fingerRevision = try XCTUnwrap(gate.beginFingerSequence())
    let pencilSource = UUID()

    gate.beginPencilAction(source: pencilSource)
    XCTAssertFalse(gate.acceptsFingerSequence(fingerRevision))
    XCTAssertNil(gate.beginFingerSequence())

    gate.endPencilAction(source: pencilSource)
    XCTAssertFalse(
      gate.acceptsFingerSequence(fingerRevision),
      "Пересёкшуюся пару должен целиком завершить владелец Pencil"
    )
    XCTAssertNotNil(gate.beginFingerSequence())
  }

  func testSmallDeliberatePinchBelongsToTheCamera() {
    let intent = TwoFingerIntentArbiter.resolve(
      allowsPageNavigation: true,
      translation: .zero,
      fingerDisplacements: [
        CGPoint(x: -4, y: 0),
        CGPoint(x: 4, y: 0),
      ],
      magnification: 1.025,
      elapsed: 0.08
    )

    XCTAssertEqual(intent, .magnification)
  }

  func testReleasedPinchRetainsItsMotionIdentity() {
    XCTAssertFalse(
      TwoFingerUndoClassifier.isTap(
        maximumFingerTravel: 5,
        maximumCentroidTravel: 0,
        maximumRelativeTravel: 5,
        elapsed: 0.12
      )
    )
  }

  func testQuietTwoFingerTapStillOwnsUndo() {
    XCTAssertTrue(
      TwoFingerUndoClassifier.isTap(
        maximumFingerTravel: 2.5,
        maximumCentroidTravel: 1.5,
        maximumRelativeTravel: 1.2,
        elapsed: 0.14
      )
    )
  }

  func testMagnificationDirectionSurvivesGestureAcquisition() {
    XCTAssertTrue(
      TwoFingerIntentArbiter.isOpeningApproach(magnification: 1.05)
    )
    XCTAssertFalse(
      TwoFingerIntentArbiter.isOpeningApproach(magnification: 0.95)
    )
  }

  func testNoisyHorizontalPageSwipeOwnsTheGestureBeforePinch() {
    let intent = TwoFingerIntentArbiter.resolve(
      allowsPageNavigation: true,
      translation: CGPoint(x: -10, y: 0),
      fingerDisplacements: [
        CGPoint(x: -5, y: 0),
        CGPoint(x: -15, y: 0),
      ],
      magnification: 0.95,
      elapsed: 0.08
    )

    XCTAssertEqual(intent, .navigation)
  }

  func testTruePinchWithDriftingCentroidOwnsTheCamera() {
    let intent = TwoFingerIntentArbiter.resolve(
      allowsPageNavigation: true,
      translation: CGPoint(x: 10, y: 4),
      fingerDisplacements: [
        CGPoint(x: -36, y: 2),
        CGPoint(x: 56, y: 6),
      ],
      magnification: 1.46,
      elapsed: 0.04
    )

    XCTAssertEqual(intent, .magnification)
  }

  func testFirstMovingFingerWaitsForEvidence() {
    let intent = TwoFingerIntentArbiter.resolve(
      allowsPageNavigation: true,
      translation: CGPoint(x: -8, y: 0),
      fingerDisplacements: [
        CGPoint(x: -16, y: 0),
        .zero,
      ],
      magnification: 0.92,
      elapsed: 0.02
    )

    XCTAssertEqual(intent, .undecided)
  }

  func testAnchoredPinchStartsAfterTheEvidenceWindow() {
    let intent = TwoFingerIntentArbiter.resolve(
      allowsPageNavigation: true,
      translation: CGPoint(x: 8, y: 0),
      fingerDisplacements: [
        .zero,
        CGPoint(x: 16, y: 0),
      ],
      magnification: 1.08,
      elapsed: 0.07
    )

    XCTAssertEqual(intent, .magnification)
  }

  func testTwoFingersMovingLeftTurnToTheNextPage() {
    let decision = TwoFingerGestureClassifier.navigation(
      translation: CGPoint(x: -60, y: 4),
      velocity: CGPoint(x: -300, y: 10),
      fingerDisplacements: [
        CGPoint(x: -58, y: 2),
        CGPoint(x: -62, y: 6),
      ]
    )

    XCTAssertEqual(
      decision,
      TwoFingerNavigationDecision(direction: 1)
    )
  }

  func testFastShortSwipeStillNavigates() {
    let decision = TwoFingerGestureClassifier.navigation(
      translation: CGPoint(x: 28, y: 2),
      velocity: CGPoint(x: 700, y: 20),
      fingerDisplacements: [
        CGPoint(x: 26, y: 1),
        CGPoint(x: 30, y: 3),
      ]
    )

    XCTAssertEqual(
      decision,
      TwoFingerNavigationDecision(direction: -1)
    )
  }

  func testShortFlickUsesItsVelocityDirection() {
    let decision = TwoFingerGestureClassifier.navigation(
      translation: CGPoint(x: 12, y: 1),
      velocity: CGPoint(x: -700, y: 10),
      fingerDisplacements: [
        CGPoint(x: 9, y: 1),
        CGPoint(x: 11, y: 1),
      ]
    )

    XCTAssertEqual(
      decision,
      TwoFingerNavigationDecision(direction: 1)
    )
  }

  func testVerticalSwipeLeavesNotebookNavigationToTheBoard() {
    let decision = TwoFingerGestureClassifier.navigation(
      translation: CGPoint(x: 3, y: -52),
      velocity: CGPoint(x: 20, y: -280),
      fingerDisplacements: [
        CGPoint(x: 2, y: -49),
        CGPoint(x: 4, y: -55),
      ]
    )

    XCTAssertNil(decision)
  }

  func testPinchDoesNotNavigate() {
    XCTAssertNil(
      TwoFingerGestureClassifier.navigation(
        translation: CGPoint(x: 0, y: 0),
        velocity: CGPoint(x: 900, y: 0),
        fingerDisplacements: [
          CGPoint(x: -50, y: 0),
          CGPoint(x: 50, y: 0),
        ]
      )
    )
  }

  func testOneMovingFingerDoesNotNavigate() {
    XCTAssertNil(
      TwoFingerGestureClassifier.navigation(
        translation: CGPoint(x: -55, y: 0),
        velocity: CGPoint(x: -700, y: 0),
        fingerDisplacements: [
          CGPoint(x: -110, y: 0),
          CGPoint.zero,
        ]
      )
    )
  }

  func testPageTracksTheFingerOneToOneAfterIntentAcquisition() {
    let position = PageMotionPhysics.trackedPosition(
      origin: 0,
      translation: -250,
      extent: 1_000,
      availability: PageMotionAvailability(previous: true, next: true)
    )

    XCTAssertEqual(position, -0.25, accuracy: 0.000_1)
  }

  func testUnavailablePageHasAVisibleButBoundedPaperEdge() {
    let position = PageMotionPhysics.trackedPosition(
      origin: 0,
      translation: 500,
      extent: 1_000,
      availability: PageMotionAvailability(previous: false, next: true)
    )

    XCTAssertGreaterThan(position, 0)
    XCTAssertLessThanOrEqual(position, PageMotionPhysics.edgeTravel)
  }

  func testSlowShortPageMoveReturnsToItsOwner() {
    let target = PageMotionPhysics.settlementTarget(
      position: -0.2,
      velocity: -0.1,
      availability: PageMotionAvailability(previous: true, next: true)
    )

    XCTAssertEqual(target, 0)
  }

  func testShortFastFlickCommitsTheNextPage() {
    let target = PageMotionPhysics.settlementTarget(
      position: -0.14,
      velocity: -1,
      availability: PageMotionAvailability(previous: true, next: true)
    )

    XCTAssertEqual(target, -1)
  }

  func testClassifierSpeedStillProducesAVisiblePageFlick() {
    let target = PageMotionPhysics.settlementTarget(
      position: -28.0 / 834.0,
      velocity: -700.0 / 834.0,
      availability: PageMotionAvailability(previous: true, next: true)
    )

    XCTAssertEqual(target, -1)
  }

  func testReleaseProjectionRespectsAReversal() {
    let target = PageMotionPhysics.settlementTarget(
      position: -0.48,
      velocity: 1.2,
      availability: PageMotionAvailability(previous: true, next: true)
    )

    XCTAssertEqual(target, 0)
  }

  func testCriticalSettlementStartsWithoutADiscontinuityAndConverges() {
    let settlement = PageMotionSettlement(
      start: -0.43,
      target: -1,
      initialVelocity: -0.7,
      angularFrequency: 17,
      maximumDuration: 0.38
    )

    XCTAssertEqual(settlement.sample(at: 0).position, -0.43, accuracy: 0.000_1)
    XCTAssertEqual(settlement.sample(at: 0).velocity, -0.7, accuracy: 0.000_1)
    XCTAssertEqual(settlement.sample(at: 0.38).position, -1, accuracy: 0.02)
  }

  @MainActor
  func testPageMotionCommitsSelectionExactlyOnceAfterSettlement() async {
    let controller = PageMotionController()
    var commits: [Int] = []
    var finishes = 0
    let availability = PageMotionAvailability(previous: true, next: true)
    controller.begin(
      PageNavigationSample(translation: 0, velocity: 0),
      extent: 1_000,
      availability: availability,
      onCommit: { commits.append($0) },
      onFinish: { finishes += 1 }
    )
    controller.end(
      PageNavigationSample(translation: -420, velocity: -250),
      reduceMotion: false
    )

    try? await Task.sleep(for: .milliseconds(450))

    XCTAssertEqual(commits, [1])
    XCTAssertEqual(finishes, 1)
    XCTAssertEqual(controller.phase, .idle)
    XCTAssertEqual(controller.position, 0)
  }

  @MainActor
  func testNewGestureInterruptsSettlementAtItsPresentedPosition() async {
    let controller = PageMotionController()
    let availability = PageMotionAvailability(previous: true, next: true)
    controller.begin(
      PageNavigationSample(translation: 0, velocity: 0),
      extent: 1_000,
      availability: availability,
      onCommit: { _ in },
      onFinish: {}
    )
    controller.end(
      PageNavigationSample(translation: -420, velocity: -250),
      reduceMotion: false
    )
    try? await Task.sleep(for: .milliseconds(45))
    let presented = controller.position

    controller.begin(
      PageNavigationSample(translation: 0, velocity: 0),
      extent: 1_000,
      availability: availability,
      onCommit: { _ in },
      onFinish: {}
    )

    XCTAssertEqual(controller.position, presented, accuracy: 0.000_1)
    controller.reset()
  }

  func testFastBoardSampleIsSplitAroundCrossedCover() {
    let itemID = UUID()
    let intervals = SpatialSurfaceRouter.intervals(
      from: CGPoint(x: 0, y: 50),
      to: CGPoint(x: 300, y: 50),
      covers: [
        SpatialScreenSurface(
          id: .cover(itemID),
          frame: CGRect(x: 100, y: 0, width: 100, height: 100),
          zIndex: 1
        )
      ]
    )

    XCTAssertEqual(intervals.map(\.surface), [
      .board,
      .cover(itemID),
      .board,
    ])
    XCTAssertEqual(intervals[0].upperBound, 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(intervals[1].upperBound, 2.0 / 3.0, accuracy: 0.0001)
  }

  func testTopCoverOwnsAnOverlappingSegment() {
    let lower = UUID()
    let upper = UUID()
    let intervals = SpatialSurfaceRouter.intervals(
      from: CGPoint(x: 0, y: 50),
      to: CGPoint(x: 300, y: 50),
      covers: [
        SpatialScreenSurface(
          id: .cover(lower),
          frame: CGRect(x: 50, y: 0, width: 200, height: 100),
          zIndex: 1
        ),
        SpatialScreenSurface(
          id: .cover(upper),
          frame: CGRect(x: 125, y: 0, width: 50, height: 100),
          zIndex: 2
        ),
      ]
    )

    XCTAssertTrue(intervals.contains { $0.surface == .cover(upper) })
    XCTAssertEqual(
      SpatialSurfaceRouter.surface(
        at: CGPoint(x: 150, y: 50),
        covers: [
          SpatialScreenSurface(
            id: .cover(lower),
            frame: CGRect(x: 50, y: 0, width: 200, height: 100),
            zIndex: 1
          ),
          SpatialScreenSurface(
            id: .cover(upper),
            frame: CGRect(x: 125, y: 0, width: 50, height: 100),
            zIndex: 2
          ),
        ]
      ),
      .cover(upper)
    )
  }

  @MainActor
  func testOneRecognizerOwnsTheWholeTwoFingerSequence() {
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 1_100))
    let scene = UIView(frame: host.bounds)
    host.addSubview(scene)
    let controller = WorkspaceGestureLayer.Coordinator(
      allowsPageNavigation: true,
      isEnabled: true,
      pencilInputGate: PencilInputGate(),
      onCamera: { _ in },
      onPageNavigation: { _ in },
      onUndo: {}
    )

    controller.install(on: host, inside: scene)
    controller.install(on: host, inside: scene)

    let paperRecognizers = (host.gestureRecognizers ?? []).compactMap {
      $0 as? TwoFingerPaperGestureRecognizer
    }
    XCTAssertEqual(paperRecognizers.count, 1)

    controller.uninstall()
    XCTAssertFalse(
      (host.gestureRecognizers ?? []).contains {
        $0 is TwoFingerPaperGestureRecognizer
      }
    )
  }
}
