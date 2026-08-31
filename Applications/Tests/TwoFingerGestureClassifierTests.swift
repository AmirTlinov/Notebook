import XCTest

@testable import Notebook

final class TwoFingerGestureClassifierTests: XCTestCase {
  @MainActor
  func testIPadPageTurnUsesTheSystemPageCurl() {
    let controller = PageTurnPlatformContract.makePageViewController()

    XCTAssertEqual(controller.transitionStyle, .pageCurl)
    XCTAssertEqual(controller.navigationOrientation, .horizontal)
    XCTAssertFalse(controller.isDoubleSided)
  }

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
      defersHorizontalMotionToPageTurn: true,
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
      defersHorizontalMotionToPageTurn: true,
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

  func testTwelvePointCoherentTravelAcquiresThePageRail() {
    let acquired = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: -12, y: 0),
      fingerDisplacements: [
        CGPoint(x: -12, y: 0),
        CGPoint(x: -12, y: 0),
      ],
      magnification: 1,
      elapsed: 0.03
    )
    let waiting = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
      translation: CGPoint(x: -11.9, y: 0),
      fingerDisplacements: [
        CGPoint(x: -11.9, y: 0),
        CGPoint(x: -11.9, y: 0),
      ],
      magnification: 1,
      elapsed: 0.03
    )

    XCTAssertEqual(acquired, .navigation)
    XCTAssertEqual(waiting, .undecided)
  }

  func testTruePinchWithDriftingCentroidOwnsTheCamera() {
    let intent = TwoFingerIntentArbiter.resolve(
      defersHorizontalMotionToPageTurn: true,
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
      defersHorizontalMotionToPageTurn: true,
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
      defersHorizontalMotionToPageTurn: true,
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

    XCTAssertEqual(
      intervals.map(\.surface),
      [
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
      defersHorizontalMotionToPageTurn: true,
      isEnabled: true,
      pencilInputGate: PencilInputGate(),
      onCamera: { _ in },
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
