import XCTest

@testable import Notebook

final class PageTurnSurfaceTests: XCTestCase {
  func testSlowShortTurnReturnsToTheCurrentPage() {
    XCTAssertFalse(
      MacPageTurnDecision.commits(progress: 0.20, velocity: 0.10)
    )
  }

  func testFastShortTurnKeepsTheTrackpadMomentum() {
    XCTAssertTrue(
      MacPageTurnDecision.commits(progress: 0.14, velocity: 1.10)
    )
  }

  func testReversingBeforeReleaseCancelsTheTurn() {
    XCTAssertFalse(
      MacPageTurnDecision.commits(progress: 0.48, velocity: -1.00)
    )
  }
}
