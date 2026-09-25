import XCTest
@testable import Notebook

final class MetalFrameCompletionTests: XCTestCase {
  func testSimulatorCompletionCannotBecomeDisplayTiming() {
    XCTAssertTrue(MetalFrameCompletion.simulatorRendered.permitsProgress)
    XCTAssertNil(MetalFrameCompletion.simulatorRendered.presentationTime)
  }

  func testDiscardedFrameCannotAdvanceAnInteraction() {
    XCTAssertFalse(MetalFrameCompletion.discarded.permitsProgress)
    XCTAssertNil(MetalFrameCompletion.discarded.presentationTime)
  }

  func testDisplayedFrameKeepsTheOSTimestamp() {
    XCTAssertTrue(MetalFrameCompletion.displayed(12.5).permitsProgress)
    XCTAssertEqual(MetalFrameCompletion.displayed(12.5).presentationTime, 12.5)
    #if targetEnvironment(simulator)
      XCTAssertFalse(MetalFrameCompletion.reportsDisplayTime)
    #else
      XCTAssertTrue(MetalFrameCompletion.reportsDisplayTime)
    #endif
  }

  func testInvalidDisplayTimesCannotAdvanceOrBecomeTimingEvidence() {
    for time in [0, -1, Double.infinity, Double.nan] {
      XCTAssertFalse(MetalFrameCompletion.displayed(time).permitsProgress)
      XCTAssertNil(MetalFrameCompletion.displayed(time).presentationTime)
    }
  }
}
