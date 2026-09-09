import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookInteractionTests: XCTestCase {
  func testPendingContactStillDeliversTheTapThatEndsTextEditing() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var lifts: [Bool] = []
    var taps: [Int] = []
    view.onLiftChanged = { lifts.append($0) }
    view.onTap = { _, count in taps.append(count) }
    view.setPermitsManipulation(false)
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(lifts, [])
    XCTAssertEqual(taps, [1])
  }

  func testPreparationClosingAndReopeningDoesNotLiftTheSameContact() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var lifts: [Bool] = []
    view.onLiftChanged = { lifts.append($0) }
    view.touchesBegan([touch], with: nil)
    view.setPermitsManipulation(false)
    view.setPermitsManipulation(true)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(lifts, [])
    XCTAssertTrue(view.yieldToCameraPan(), "The interrupted hold still belongs to camera movement")

    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(lifts, [true], "Only a new contact may acquire manipulation")
    view.cancelInteraction()
    XCTAssertEqual(lifts, [true, false])
  }

  func testPendingReleasesAnExistingLiftAfterTheRepresentableUpdate() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    XCTAssertEqual(events, [.lift(true)])

    view.setPermitsManipulation(false)
    XCTAssertEqual(events, [.lift(true)], "updateUIView must not mutate SwiftUI state synchronously")
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    XCTAssertTrue(view.yieldToCameraPan(), "Cancellation immediately releases native camera arbitration")
    XCTAssertEqual(events.count, 3)
  }

  func testFingerEndingBeforeDeferredCancellationCompletesTheLiftExactlyOnce() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    var taps = 0
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.onTap = { _, _ in taps += 1 }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    view.setPermitsManipulation(false)
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events.count, 3)
    XCTAssertEqual(taps, 0, "A cancelled lifted contact cannot become a tap")
  }

  func testACompletedLiftCommitsItsMeasuredTranslation() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    touch.point.x += 70
    touch.point.y -= 20
    view.touchesMoved([touch], with: nil)
    XCTAssertFalse(view.yieldToCameraPan(), "An admitted hold owns its finger until drop")
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .end(.init(width: 70, height: -20)), .lift(false)])
  }

  func testUIKitCancellationDropsOnlyTheManipulationPreview() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var events: [CoverInteractionEvent] = []
    view.onLiftChanged = { events.append(.lift($0)) }
    view.onTranslationEnded = { events.append(.end($0)) }
    view.onCancelled = { events.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    touch.point.x += 70
    view.touchesMoved([touch], with: nil)
    view.touchesCancelled([touch], with: nil)
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events.count, 3)
  }

  func testDismantlingDefersCleanupAndKeepsItsOriginalOwnerCallbacks() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var oldEvents: [CoverInteractionEvent] = []
    var newEvents: [CoverInteractionEvent] = []
    view.onLiftChanged = { oldEvents.append(.lift($0)) }
    view.onTranslationEnded = { oldEvents.append(.end($0)) }
    view.onCancelled = { oldEvents.append(.cancel) }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    NotebookInteractionView.dismantleUIView(view, coordinator: ())
    XCTAssertEqual(oldEvents, [.lift(true)])
    view.onLiftChanged = { newEvents.append(.lift($0)) }
    view.onTranslationEnded = { newEvents.append(.end($0)) }
    view.onCancelled = { newEvents.append(.cancel) }
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(oldEvents, [.lift(true), .cancel, .lift(false)])
    XCTAssertEqual(newEvents, [])
  }

  func testPendingHitTestingPassesThroughOnlyToTheLiveTextEditor() {
    let coverID = UUID()
    let elements = [SpatialElementKind.nativeText, .nativeText, .web].enumerated().map { index, kind in
      SpatialElement(id: "element-\(index)", surface: .cover(coverID), kind: kind,
        frame: .init(x: Double(index * 100), y: 0, width: 80, height: 80), source: "Content",
        stamp: .init(counter: 0, actor: UUID()))
    }
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    view.frame = .init(x: 0, y: 0, width: 400, height: 400)
    view.passthroughFrames = WorkspaceItemCoverView.interactionPassthroughFrames(
      elements: elements, editingTextID: "element-0", scenePreparationPending: true)
    XCTAssertFalse(view.point(inside: .init(x: 20, y: 20), with: nil))
    XCTAssertTrue(view.point(inside: .init(x: 120, y: 20), with: nil))
    XCTAssertTrue(view.point(inside: .init(x: 220, y: 20), with: nil),
      "A disabled diagram cannot swallow the outside tap or camera contact")
    XCTAssertTrue(view.point(inside: .init(x: 320, y: 20), with: nil))
    view.passthroughFrames = WorkspaceItemCoverView.interactionPassthroughFrames(
      elements: elements, editingTextID: nil, scenePreparationPending: true)
    XCTAssertTrue(view.point(inside: .init(x: 20, y: 20), with: nil))
  }
}

private enum CoverInteractionEvent: Equatable {
  case lift(Bool)
  case end(CGSize)
  case cancel
}

@MainActor
private final class CoverInteractionTouch: UITouch {
  var point = CGPoint(x: 100, y: 100)
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint { point }
}
