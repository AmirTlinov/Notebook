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
    recognizer.onPoint = { _, end, _ in points.append(end) }
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
    recognizer.onPoint = { _, _, held in XCTAssertTrue(held); committed += 1 }
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
}
@MainActor private final class SelectionTouch: UITouch {
  var point = CGPoint(x: 100, y: 100)
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { point }
}
