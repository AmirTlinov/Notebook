import XCTest
@testable import Notebook

final class NotebookChatWindowTests: XCTestCase {
  private let portrait = CGRect(x: 18, y: 82, width: 798, height: 1032)

  func testTerminalStartsAtHalfAndItsDividerPreservesTheWindowAndTemporaryKeyboardPreference() {
    let window = NotebookChatWindowLayout(), frame = window.frame(in: portrait, expanded: true)
    let first = NotebookTerminalSplit(height: 500, fraction: nil)
    XCTAssertEqual(first.terminal, first.conversation)
    let fraction = first.fraction(after: -60)
    let larger = NotebookTerminalSplit(height: 500, fraction: fraction)
    XCTAssertEqual(larger.terminal, first.terminal + 60, accuracy: 0.001)
    XCTAssertEqual(NotebookTerminalSplit(height: 500, fraction: 1).conversation, 180)
    XCTAssertEqual(NotebookTerminalSplit(height: 500, fraction: 0).terminal, 120)
    for height: CGFloat in [60, 200, 500] {
      let fit = NotebookTerminalSplit(height: height, fraction: fraction)
      XCTAssertGreaterThanOrEqual(fit.conversation, 0)
      XCTAssertGreaterThanOrEqual(fit.terminal, 0)
      XCTAssertEqual(fit.conversation + fit.terminal + NotebookTerminalSplit.divider, height)
    }
    XCTAssertEqual(NotebookTerminalSplit(height: 500, fraction: fraction).terminal, larger.terminal)
    XCTAssertEqual(window.frame(in: portrait, expanded: true), frame)
  }

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
    layout.resize(start, corner: .bottomTrailing, translation: .init(width: -120, height: -160), in: portrait)
    let resized = layout.frame(in: portrait, expanded: true)
    XCTAssertEqual(resized.origin, start.origin)
    XCTAssertEqual(resized.size, CGSize(width: 440, height: 480))
    XCTAssertEqual(NotebookChatWindowLayout(restoring: layout.encoded), layout)
    XCTAssertEqual(layout.frame(in: portrait, expanded: false).size, CGSize(width: 112, height: 48))
    XCTAssertEqual(layout.frame(in: portrait, expanded: true), resized)
  }

  func testEveryCornerKeepsItsOppositePointAndClampsToTheAvailableWindow() {
    for corner in NotebookChatResizeCorner.allCases {
      var layout = NotebookChatWindowLayout(); layout.anchor = .init(x: 0.5, y: 0.5)
      let start = layout.frame(in: portrait, expanded: true)
      layout.resize(start, corner: corner, translation: .init(width: corner.leading ? 120 : -120, height: corner.top ? 160 : -160), in: portrait)
      let frame = layout.frame(in: portrait, expanded: true)
      XCTAssertEqual(frame.size, CGSize(width: 440, height: 480))
      XCTAssertEqual(corner.leading ? frame.maxX : frame.minX, corner.leading ? start.maxX : start.minX, accuracy: 0.001)
      XCTAssertEqual(corner.top ? frame.maxY : frame.minY, corner.top ? start.maxY : start.minY, accuracy: 0.001)
      XCTAssertEqual(NotebookChatWindowLayout(restoring: layout.encoded), layout)
      layout.resize(start, corner: corner, translation: .init(width: corner.leading ? -5000 : 5000, height: corner.top ? -5000 : 5000), in: portrait)
      XCTAssertTrue(portrait.contains(layout.frame(in: portrait, expanded: true)))
      let shape = NotebookChatCornerHitShape(corner: corner).path(in: CGRect(x: 0, y: 0, width: 36, height: 36))
      XCTAssertFalse(shape.contains(CGPoint(x: 18, y: 18)), "The corner cannot take a nearby button's central tap")
    }
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
    for corner in NotebookChatResizeCorner.allCases {
      layout.resize(layout.frame(in: available, expanded: true), corner: corner, translation: .init(width: -100, height: -100), in: available)
      XCTAssertEqual(layout.frame(in: available, expanded: true), available)
    }
    XCTAssertEqual(NotebookChatWindowLayout(restoring: "invalid"), NotebookChatWindowLayout())
  }
}
