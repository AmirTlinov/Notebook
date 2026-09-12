import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookSceneSelectionTests: XCTestCase {
  func testFingerTapIsOneSelectionAndMotionBeforeHoldRemainsNavigation() {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer)
    recognizer.gate = gate
    XCTAssertFalse(recognizer.canPrevent(UIPanGestureRecognizer()))
    XCTAssertFalse(recognizer.canBePrevented(by: UIPanGestureRecognizer()))
    var points: [CGPoint] = []
    recognizer.onPoint = { _, end, _, _ in points.append(end) }
    recognizer.touchesBegan([touch], with: UIEvent()); recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(points, [.init(x: 100, y: 100)])
    recognizer.isEnabled = false; recognizer.isEnabled = true; touch.point = .init(x: 110, y: 100)
    recognizer.touchesBegan([touch], with: UIEvent()); touch.point.x += 30
    recognizer.touchesMoved([touch], with: UIEvent()); recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(points.count, 1)
    recognizer.cancelSelection()
  }
  func testHoldSelectsRegionButPencilAndSecondFingerCancelTheSameContact() async throws {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer)
    recognizer.gate = gate
    var committed = 0; var preview: CGRect?
    recognizer.onPoint = { _, _, held, _ in XCTAssertTrue(held); committed += 1 }
    recognizer.onPreview = { preview = $0 }
    recognizer.touchesBegan([touch], with: UIEvent())
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertNotNil(preview)
    touch.point = .init(x: 180, y: 170); recognizer.touchesMoved([touch], with: UIEvent())
    XCTAssertEqual(preview?.size, .init(width: 80, height: 70))
    recognizer.touchesEnded([touch], with: UIEvent()); XCTAssertEqual(committed, 1)
    recognizer.isEnabled = false; recognizer.isEnabled = true; recognizer.touchesBegan([touch], with: UIEvent())
    let pencil = UUID(); XCTAssertTrue(gate.beginPencilAction(source: pencil))
    recognizer.touchesEnded([touch], with: UIEvent()); XCTAssertEqual(committed, 1)
    gate.endPencilAction(source: pencil)
    recognizer.isEnabled = false; recognizer.isEnabled = true; recognizer.touchesBegan([touch], with: UIEvent())
    recognizer.touchesBegan([SelectionTouch()], with: UIEvent())
    recognizer.touchesEnded([touch], with: UIEvent()); XCTAssertEqual(committed, 1)
    XCTAssertNil(preview); recognizer.cancelSelection()
  }
  func testArtifactHoldMovesFromItsBodyAndNeverCommitsAnAreaOrSecondDrop() async throws {
    let recognizer = SceneSelectionRecognizer(), gate = NotebookInputGate(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    var begins = 0, drops = 0, cancels = 0
    var moved = CGPoint.zero
    recognizer.onPreview = { if $0 != nil { XCTFail("An artifact hold is not an area selection") } }
    recognizer.onPoint = { _, _, _, _ in XCTFail("Moving never publishes a second context") }
    recognizer.onLift = { point in
      XCTAssertEqual(point, touch.point)
      return SceneSelectionLift(begin: { begins += 1 }, change: { moved = $0 },
        end: { moved = $0; drops += 1 }, cancel: { cancels += 1 })
    }
    recognizer.touchesBegan([touch], with: UIEvent())
    // A view update during the hold cannot redirect it to a different owner.
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
    recognizer.onPoint = { _, _, _, _ in XCTFail("Pencil cannot indicate a different fragment") }
    recognizer.touchesBegan([touch], with: UIEvent())
    try await Task.sleep(for: .milliseconds(250))
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
