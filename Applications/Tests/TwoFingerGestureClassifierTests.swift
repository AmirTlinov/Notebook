import XCTest
@testable import Tetrad

final class TwoFingerGestureClassifierTests: XCTestCase {
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

  func testFastBoardSampleIsSplitAroundCrossedCover() {
    let notebookID = UUID()
    let intervals = SpatialSurfaceRouter.intervals(
      from: CGPoint(x: 0, y: 50),
      to: CGPoint(x: 300, y: 50),
      covers: [
        SpatialScreenSurface(
          id: .cover(notebookID),
          frame: CGRect(x: 100, y: 0, width: 100, height: 100),
          zIndex: 1
        )
      ]
    )

    XCTAssertEqual(intervals.map(\.surface), [
      .board,
      .cover(notebookID),
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
      isPageOpen: true,
      onCamera: { _ in },
      onNavigate: { _ in },
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
