import TetradCore
import XCTest
@testable import Tetrad

final class DrawingStyleTests: XCTestCase {
  func testLargestEraserSpansTwentyNotebookCells() {
    XCTAssertEqual(
      EraserStyle.maximumSelectableWidth,
      PhysicalPaper.gridSpacing * 20,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      EraserStyle(maximumWidth: .infinity).maximumWidth,
      EraserStyle.maximumSelectableWidth
    )
  }
}
