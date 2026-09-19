import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookSceneSelectionTests: XCTestCase {
  func testLinkKeepsItsTapAndOnlyDraggingLiftsItsMaterial() async throws {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    let content = UIView(), neighbour = UIView()
    view.addSubview(content)
    let nativeHold = UILongPressGestureRecognizer(), neighbourHold = UILongPressGestureRecognizer(), camera = UIPanGestureRecognizer()
    content.addGestureRecognizer(nativeHold); neighbour.addGestureRecognizer(neighbourHold)
    var begins = 0, drops = 0
    recognizer.onPoint = { _, _ in XCTFail("The original link owns a short tap") }
    recognizer.onLift = { _ in .init(begin: { begins += 1 }, change: { _ in }, end: { _ in drops += 1 }, cancel: {}) }
    func begin() {
      _ = gate.fingerContactOwner(for: ObjectIdentifier(touch)) { .webLink(ObjectIdentifier(view)) }
      recognizer.touchesBegan([touch], with: UIEvent())
    }
    begin()
    XCTAssertFalse(recognizer.canPrevent(nativeHold), "A possible lift cannot take the link's short tap")
    recognizer.touchesEnded([touch], with: UIEvent())
    // UIKit may already have reset .failed to .possible; observe the effects,
    // not a terminal state that the framework is free to retire immediately.
    XCTAssertEqual(begins, 0); XCTAssertEqual(drops, 0)
    recognizer.isEnabled = false; recognizer.isEnabled = true
    begin(); try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(begins,0)
    touch.point.x += 20; recognizer.touchesMoved([touch],with:UIEvent())
    XCTAssertTrue(recognizer.cancelsTouchesInView)
    XCTAssertTrue(recognizer.canPrevent(nativeHold), "The lifted material cannot also select text or open a link menu")
    XCTAssertFalse(recognizer.canPrevent(neighbourHold)); XCTAssertFalse(recognizer.canPrevent(camera))
    XCTAssertEqual(begins, 1)
    recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(drops, 1)
    recognizer.cancelSelection(); gate.endFingerContacts([ObjectIdentifier(touch)])
  }

  func testFingerTapSelectsOnceAndPaperMotionRemainsNavigation() {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer)
    recognizer.gate = gate
    XCTAssertFalse(recognizer.canPrevent(UIPanGestureRecognizer()))
    XCTAssertFalse(recognizer.canBePrevented(by: UIPanGestureRecognizer()))
    var points: [CGPoint] = []
    recognizer.onPoint = { end, _ in points.append(end) }
    recognizer.touchesBegan([touch], with: UIEvent()); recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(points, [.init(x: 100, y: 100)])
    recognizer.isEnabled = false; recognizer.isEnabled = true; touch.point = .init(x: 110, y: 100)
    recognizer.touchesBegan([touch], with: UIEvent()); touch.point.x += 30
    recognizer.touchesMoved([touch], with: UIEvent()); recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(points.count, 1)
    recognizer.cancelSelection()
  }
  func testHoldingPaperNeverSelectsARegionAndMotionRemainsNavigation() async throws {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    var committed = 0
    recognizer.onPoint = { _, _ in committed += 1 }
    recognizer.touchesBegan([touch],with:UIEvent())
    try await Task.sleep(for:.milliseconds(450))
    XCTAssertEqual(committed,0); XCTAssertEqual(recognizer.state,.possible)
    touch.point = .init(x:180,y:170); recognizer.touchesMoved([touch],with:UIEvent())
    recognizer.touchesEnded([touch],with:UIEvent())
    XCTAssertEqual(committed,0)
    recognizer.reset()
    recognizer.touchesBegan([touch],with:UIEvent())
    let pencil = UUID(); XCTAssertTrue(gate.beginPencilAction(source:pencil))
    recognizer.touchesEnded([touch],with:UIEvent()); XCTAssertEqual(committed,0)
    gate.endPencilAction(source:pencil)
  }
  func testArtifactDragMovesFromItsBodyAndNeverCommitsAnAreaOrSecondDrop() async throws {
    let recognizer = SceneSelectionRecognizer(), gate = NotebookInputGate(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    var begins = 0, drops = 0, cancels = 0
    var moved = CGPoint.zero
    recognizer.onPoint = { _, _ in XCTFail("Moving never publishes a second context") }
    recognizer.onLift = { point in
      XCTAssertEqual(point, touch.point)
      return SceneSelectionLift(begin: { begins += 1 }, change: { moved = $0 },
        end: { moved = $0; drops += 1 }, cancel: { cancels += 1 })
    }
    recognizer.touchesBegan([touch], with: UIEvent())
    // A view update during the drag cannot redirect it to a different owner.
    recognizer.onLift = { _ in XCTFail("The down contact already resolved its owner"); return nil }
    try await Task.sleep(for: .milliseconds(250))
    touch.point = .init(x: 160, y: 140); recognizer.touchesMoved([touch], with: UIEvent())
    XCTAssertEqual(moved, .init(x: 60, y: 40))
    recognizer.touchesEnded([touch], with: UIEvent())
    recognizer.cancelSelection(); recognizer.reset()
    XCTAssertEqual(begins, 1); XCTAssertEqual(drops, 1); XCTAssertEqual(cancels, 0)
  }

  func testPencilCancelsAnArtifactLiftWithoutMovingOrSelectingAnythingElse() async throws {
    let recognizer = SceneSelectionRecognizer(), gate = NotebookInputGate(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    let source = UUID()
    gate.registerFingerCancellation(source: source) { recognizer.cancelSelection() }
    defer { gate.unregisterFingerCancellation(source: source) }
    var cancelled = 0
    recognizer.onLift = { _ in .init(begin: {}, change: { _ in }, end: { _ in XCTFail("Pencil cancelled this drop") }, cancel: { cancelled += 1 }) }
    recognizer.onPoint = { _, _ in XCTFail("Pencil cannot indicate a different fragment") }
    recognizer.touchesBegan([touch], with: UIEvent())
    try await Task.sleep(for: .milliseconds(250))
    touch.point.x += 10; recognizer.touchesMoved([touch],with:UIEvent())
    let pencil = UUID(); XCTAssertTrue(gate.beginPencilAction(source: pencil))
    recognizer.touchesEnded([touch], with: UIEvent()); recognizer.reset()
    XCTAssertEqual(cancelled, 1); XCTAssertTrue(gate.hasActivePencil)
    gate.endPencilAction(source: pencil)
  }

}
@MainActor private final class SelectionTouch: UITouch {
  var point = CGPoint(x: 100, y: 100)
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { point }
}
