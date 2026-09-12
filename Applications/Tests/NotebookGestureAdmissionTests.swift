import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookGestureAdmissionTests: XCTestCase {
  func testAcceptedLiftKeepsItsOwnerWhenNewAdmissionClosesAndCallbacksChange() async throws {
    let gate = NotebookInputGate()
    let view = NotebookInteractionTouchView(inputGate: gate)
    let touch = GestureAdmissionTouch()
    var original: [ContactEvent] = [], successor: [ContactEvent] = []
    bind(view) { original.append($0) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(original, [.lift(true)])

    // Preparing a different scene can close new admission, but this finger
    // still belongs to its already installed physical owner.
    gate.bindNewContactAdmission { false }
    bind(view) { successor.append($0) }
    view.updateOwnerAvailability { true }
    touch.point = .init(x: 170, y: 80)
    view.touchesMoved([touch], with: nil)
    view.touchesEnded([touch], with: nil)
    view.touchesEnded([touch], with: nil)
    view.cancelInteraction()
    XCTAssertEqual(original, [.lift(true), .change(.init(width: 70, height: -20)),
      .end(.init(width: 70, height: -20)), .lift(false)])
    XCTAssertEqual(successor, [], "A view update cannot take another owner's admitted contact")
    XCTAssertFalse(view.yieldToCameraPan())

    view.touchesBegan([touch], with: nil)
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(successor, [], "The closed admission still rejects genuinely new contacts")
    gate.bindNewContactAdmission { true }
    view.touchesBegan([touch], with: nil)
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(successor, [.tap])
  }

  func testPhysicalRetirementReleasesTheOldContactBeforeANewOwnerIsAdmitted() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate()), touch = GestureAdmissionTouch()
    var original: [ContactEvent] = [], successor: [ContactEvent] = []
    bind(view) { original.append($0) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    bind(view) { successor.append($0) }
    view.updateOwnerAvailability { false }
    XCTAssertEqual(original, [.lift(true)], "UIKit retires the contact before the deferred SwiftUI notification")
    XCTAssertFalse(view.yieldToCameraPan(), "The old owner no longer holds a camera-arbitration contact")
    view.updateOwnerAvailability { true }
    let next = GestureAdmissionTouch()
    view.touchesBegan([next], with: nil)
    view.touchesEnded([next], with: nil)
    view.touchesEnded([touch], with: nil)
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(original, [.lift(true), .cancel, .lift(false)])
    XCTAssertEqual(successor, [.tap], "Deferred retirement cannot cancel or complete the successor")
  }

  func testPencilRetiresTheAcceptedFingerWithoutALateDropOrFalseTap() async throws {
    let gate = NotebookInputGate()
    let view = NotebookInteractionTouchView(inputGate: gate)
    let touch = GestureAdmissionTouch(), pencil = UUID()
    var events: [ContactEvent] = []
    bind(view) { events.append($0) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertTrue(gate.beginPencilAction(source: pencil))
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    XCTAssertFalse(view.yieldToCameraPan())
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    view.touchesEnded([touch], with: nil)
    gate.endPencilAction(source: pencil)
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    view.touchesBegan([touch], with: nil)
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(events.last, .tap)
  }

  func testSecondFingerCancelsEvenAfterNewAdmissionClosed() async throws {
    let gate = NotebookInputGate(), touch = GestureAdmissionTouch()
    let view = NotebookInteractionTouchView(inputGate: gate)
    var events: [ContactEvent] = []
    bind(view) { events.append($0) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    gate.bindNewContactAdmission { false }
    view.touchesBegan([GestureAdmissionTouch()], with: nil)
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    XCTAssertFalse(view.yieldToCameraPan())
  }

  private func bind(_ view: NotebookInteractionTouchView, receive: @escaping (ContactEvent) -> Void) {
    view.onTap = { _, _ in receive(.tap) }
    view.onLiftChanged = { receive(.lift($0)) }
    view.onTranslationChanged = { receive(.change($0)) }
    view.onTranslationEnded = { receive(.end($0)) }
    view.onCancelled = { receive(.cancel) }
  }
}

private enum ContactEvent: Equatable {
  case tap, lift(Bool), change(CGSize), end(CGSize), cancel
}

@MainActor
private final class GestureAdmissionTouch: UITouch {
  var point = CGPoint(x: 100, y: 100)
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint { point }
}
