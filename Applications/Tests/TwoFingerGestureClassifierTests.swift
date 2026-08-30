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
      TwoFingerNavigationDecision(horizontal: true, direction: 1)
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
      TwoFingerNavigationDecision(horizontal: true, direction: -1)
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
      TwoFingerNavigationDecision(horizontal: true, direction: 1)
    )
  }

  func testVerticalSwipeChangesNotebook() {
    let decision = TwoFingerGestureClassifier.navigation(
      translation: CGPoint(x: 3, y: -52),
      velocity: CGPoint(x: 20, y: -280),
      fingerDisplacements: [
        CGPoint(x: 2, y: -49),
        CGPoint(x: 4, y: -55),
      ]
    )

    XCTAssertEqual(
      decision,
      TwoFingerNavigationDecision(horizontal: false, direction: 1)
    )
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

  @MainActor
  func testOneRecognizerOwnsTheWholeTwoFingerSequence() {
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 1_100))
    let paper = UIView(frame: host.bounds)
    host.addSubview(paper)
    let controller = TwoFingerPageGestureController(
      onNavigate: { _, _ in },
      onUndo: {}
    )

    controller.install(on: host, inside: paper)
    controller.install(on: host, inside: paper)

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
