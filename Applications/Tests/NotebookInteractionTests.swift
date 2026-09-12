import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookInteractionTests: XCTestCase {
  func testRemovedOwnerRejectsTheWholeContact() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var lifts: [Bool] = []
    var taps: [Int] = []
    view.onLiftChanged = { lifts.append($0) }
    view.onTap = { _, count in taps.append(count) }
    view.updateOwnerAvailability { false }
    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    view.touchesEnded([touch], with: nil)
    XCTAssertEqual(lifts, [])
    XCTAssertEqual(taps, [])
  }

  func testOwnerRestorationDoesNotReviveAnAbandonedContact() async throws {
    let view = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    let touch = CoverInteractionTouch()
    var lifts: [Bool] = []
    view.onLiftChanged = { lifts.append($0) }
    view.touchesBegan([touch], with: nil)
    view.updateOwnerAvailability { false }
    view.updateOwnerAvailability { true }
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(lifts, [])
    XCTAssertFalse(view.yieldToCameraPan(), "Removing the physical owner retired its original contact")

    view.touchesBegan([touch], with: nil)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(lifts, [true], "Only a new contact may acquire manipulation")
    view.cancelInteraction()
    XCTAssertEqual(lifts, [true, false])
  }

  func testOwnerRemovalReleasesAnExistingLiftAfterTheRepresentableUpdate() async throws {
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

    view.updateOwnerAvailability { false }
    XCTAssertEqual(events, [.lift(true)], "updateUIView must not mutate SwiftUI state synchronously")
    try await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(events, [.lift(true), .cancel, .lift(false)])
    XCTAssertFalse(view.yieldToCameraPan(), "Cancellation already released its native contact")
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
    view.updateOwnerAvailability { false }
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

  func testCoverPassesEveryArtifactToItsOwnSelectionContact() {
    let id = UUID()
    let elements = [SpatialElementKind.nativeText, .markdown, .web].enumerated().map { index, kind in
      SpatialElement(id: "material-\(index)", surface: .cover(id), kind: kind,
        frame: .init(x: Double(index * 100), y: 0, width: 80, height: 80), source: "Material",
        stamp: .init(counter: 0, actor: UUID()))
    }
    let cover = NotebookInteractionTouchView(inputGate: NotebookInputGate())
    cover.frame = .init(x: 0, y: 0, width: 400, height: 400)
    cover.passthroughFrames = WorkspaceItemCoverView.interactionPassthroughFrames(elements: elements)
    for x in [20.0, 120, 220] { XCTAssertFalse(cover.point(inside: .init(x: x, y: 20), with: nil)) }
    XCTAssertTrue(cover.point(inside: .init(x: 320, y: 20), with: nil))
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
