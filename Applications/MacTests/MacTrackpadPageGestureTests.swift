@testable import Notebook
import XCTest

final class MacTrackpadPageGestureTests: XCTestCase {
  func testPageCurlShadersAreAvailableInTheMacBundle() {
    XCTAssertTrue(PageCurlMetalSupport.isAvailable)
  }

  func testTrackpadSequencePreservesCumulativeFingerTravelAndRecentSpeed() {
    var sequence = MacTrackpadPageSequence()

    let first = sequence.append(
      translationDelta: -18,
      timestamp: 10,
      gripY: 0.28
    )
    let second = sequence.append(
      translationDelta: -22,
      timestamp: 10.04
    )

    XCTAssertEqual(first.translation, -18)
    XCTAssertEqual(second.translation, -40)
    XCTAssertEqual(second.velocity, -550, accuracy: 0.001)
    XCTAssertEqual(second.gripY, 0.28)
    XCTAssertEqual(sequence.currentSample, second)
  }

  func testTrackpadVelocityForgetsSamplesOutsideTheHardwareWindow() {
    var sequence = MacTrackpadPageSequence()
    _ = sequence.append(translationDelta: -10, timestamp: 20)
    _ = sequence.append(translationDelta: -10, timestamp: 20.04)
    let recent = sequence.append(translationDelta: 12, timestamp: 20.14)

    XCTAssertEqual(recent.translation, -8)
    XCTAssertEqual(recent.velocity, 0)
  }

  func testResetStartsANewPhysicalSequenceAtZero() {
    var sequence = MacTrackpadPageSequence()
    _ = sequence.append(translationDelta: 30, timestamp: 1)
    sequence.reset()

    XCTAssertFalse(sequence.isActive)
    XCTAssertNil(sequence.currentSample)
    XCTAssertEqual(
      sequence.append(translationDelta: -7, timestamp: 2).translation,
      -7
    )
  }
}
