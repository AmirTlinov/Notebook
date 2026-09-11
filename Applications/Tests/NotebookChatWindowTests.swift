import XCTest
@testable import Notebook

final class NotebookChatWindowTests: XCTestCase {
  private let portrait = CGRect(x: 18, y: 82, width: 798, height: 1032)

  func testDragUsesTheContactFrameAndStopsAtWindowEdges() {
    var layout = NotebookChatWindowLayout()
    let start = layout.frame(in: portrait, expanded: true)
    layout.move(start, translation: .init(width: -170, height: -240), in: portrait)
    let moved = layout.frame(in: portrait, expanded: true)
    XCTAssertEqual(moved.origin, CGPoint(x: start.minX - 170, y: start.minY - 240))
    layout.move(start, translation: .init(width: -5000, height: 5000), in: portrait)
    XCTAssertEqual(layout.frame(in: portrait, expanded: true).minX, portrait.minX)
    XCTAssertEqual(layout.frame(in: portrait, expanded: true).maxY, portrait.maxY)
  }

  func testResizeKeepsTheOppositeCornerAndRestoresTheSameGeometry() {
    var layout = NotebookChatWindowLayout()
    let start = layout.frame(in: portrait, expanded: true)
    layout.resize(start, translation: .init(width: -120, height: -160), in: portrait)
    let resized = layout.frame(in: portrait, expanded: true)
    XCTAssertEqual(resized.origin, start.origin)
    XCTAssertEqual(resized.size, CGSize(width: 440, height: 480))
    XCTAssertEqual(NotebookChatWindowLayout(restoring: layout.encoded), layout)
    XCTAssertEqual(layout.frame(in: portrait, expanded: false).size, CGSize(width: 112, height: 48))
    XCTAssertEqual(layout.frame(in: portrait, expanded: true), resized)
  }

  func testKeyboardAndRotationOnlyFitThePresentationNotTheSavedPreference() {
    var layout = NotebookChatWindowLayout()
    layout.move(layout.frame(in: portrait, expanded: true), translation: .init(width: -100, height: -180), in: portrait)
    let saved = layout, original = layout.frame(in: portrait, expanded: true)
    for available in [CGRect(x: 18, y: 82, width: 1158, height: 224), CGRect(x: 18, y: 82, width: 310, height: 180)] {
      XCTAssertTrue(available.contains(layout.frame(in: available, expanded: true)))
      XCTAssertEqual(layout, saved)
    }
    XCTAssertEqual(layout.frame(in: portrait, expanded: true), original)
  }

  func testResizeCannotLoseControlsOutsideATinyWindow() {
    var layout = NotebookChatWindowLayout()
    let available = CGRect(x: 18, y: 82, width: 280, height: 180)
    layout.resize(layout.frame(in: available, expanded: true), translation: .init(width: -100, height: -100), in: available)
    XCTAssertEqual(layout.frame(in: available, expanded: true), available)
    XCTAssertEqual(NotebookChatWindowLayout(restoring: "invalid"), NotebookChatWindowLayout())
  }
}
