import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class NotebookQuestionPlacementTests: XCTestCase {
  func testCardUsesAnAdjacentClearSideInsteadOfTheBottomCorner() {
    let area = CGRect(x: 18, y: 18, width: 800, height: 1000)
    let selection = CGRect(x: 180, y: 220, width: 180, height: 150)
    let card = NotebookQuestionPlacement.frame(size: .init(width: 420, height: 330), in: area, near: selection)
    XCTAssertEqual(card.minX, selection.maxX + 12)
    XCTAssertEqual(card.minY, selection.minY)
    XCTAssertTrue(area.contains(card))
    XCTAssertFalse(card.intersects(selection))
  }

  func testRightEdgeSelectionUsesTheLeftAndKeepsToolControlsVisible() {
    let area = CGRect(x: 18, y: 18, width: 800, height: 1000)
    let selection = CGRect(x: 570, y: 30, width: 220, height: 130)
    let tools = CGRect(x: 600, y: 18, width: 200, height: 52)
    let card = NotebookQuestionPlacement.frame(size: .init(width: 420, height: 330), in: area, near: selection, avoiding: [tools])
    XCTAssertEqual(card.maxX, selection.minX - 12)
    XCTAssertFalse(card.intersects(tools))
    XCTAssertFalse(card.intersects(selection))
  }

  func testPinnedRegionDoesNotCoverTheDifferentElementBeingEdited() {
    let area = CGRect(x: 18, y: 18, width: 784, height: 1080)
    let pinned = CGRect(x: 180, y: 212, width: 190, height: 83)
    let moveAndDelete = CGRect(x: 440, y: 229, width: 94, height: 44)
    let resize = CGRect(x: 503, y: 466, width: 44, height: 44)
    let card = NotebookQuestionPlacement.frame(size: .init(width: 420, height: 230),
      in: area, near: pinned, avoiding: [moveAndDelete, resize])
    XCTAssertTrue(area.contains(card))
    XCTAssertFalse(card.intersects(moveAndDelete))
    XCTAssertFalse(card.intersects(resize))
  }

  func testKeyboardAndRotationLimitTheCardNotThePhysicalSelection() {
    let selection = CGRect(x: 380, y: 700, width: 140, height: 160)
    for area in [CGRect(x: 18, y: 18, width: 800, height: 510), CGRect(x: 18, y: 18, width: 1150, height: 260)] {
      let card = NotebookQuestionPlacement.frame(size: .init(width: 420, height: 600), in: area, near: selection)
      XCTAssertTrue(area.contains(card))
      XCTAssertEqual(card.height, area.height)
    }
    XCTAssertEqual(selection.minY, 700)
  }

  func testOffscreenOrMissingReferenceUsesReachableFallbackWithoutNavigation() {
    let area = CGRect(x: 18, y: 18, width: 800, height: 900)
    for anchor in [nil, CGRect(x: -1000, y: -1000, width: 50, height: 50), CGRect.null, CGRect.infinite] as [CGRect?] {
      let card = NotebookQuestionPlacement.frame(size: .init(width: 420, height: 330), in: area, near: anchor)
      XCTAssertEqual(card.minX, area.minX)
      XCTAssertEqual(card.maxY, area.maxY)
    }
  }

  func testLargeSelectionAndNarrowWindowKeepTheWholeCardWithinAvailableBounds() {
    let area = CGRect(x: 18, y: 18, width: 280, height: 450)
    let card = NotebookQuestionPlacement.frame(size: .init(width: 420, height: 700), in: area,
      near: .init(x: -100, y: -100, width: 2000, height: 2000))
    XCTAssertEqual(card, area)
  }

  @MainActor
  func testNativeCardBoundsRejectSceneGesturesButKeepOutsidePencilAndCamera() throws {
    let gate = NotebookInputGate(), pencil = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    let anchor = UIView(frame: host.view.bounds)
    host.view.addSubview(anchor)
    let card = NotebookControlRegionView(gate: gate)
    card.frame = .init(x: 100, y: 150, width: 300, height: 320)
    host.view.addSubview(card)
    let camera = WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn: false,
      isEnabled: true, inputGate: gate, onCamera: { _ in XCTFail("Card input must not move camera") }, onUndo: {})
    camera.install(on: window, inside: anchor)
    let pan = BoardPanView.Coordinator(isEnabled: true, itemFrames: [], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    pan.install(on: window, inside: anchor)
    defer { camera.uninstall(); pan.uninstall(); card.unregister(); window.isHidden = true }
    let cameraGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is TwoFingerPaperGestureRecognizer })
    let observer = try XCTUnwrap(window.gestureRecognizers?.first { $0 is NotebookContactObserver })
    let panGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
    let touch = QuestionControlTouch(); touch.source = host.view; touch.point = .init(x: 200, y: 200)
    XCTAssertFalse(camera.gestureRecognizer(cameraGesture, shouldReceive: touch))
    XCTAssertFalse(camera.gestureRecognizer(observer, shouldReceive: touch))
    XCTAssertFalse(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    touch.point = .init(x: 50, y: 80)
    XCTAssertTrue(camera.gestureRecognizer(cameraGesture, shouldReceive: touch))
    XCTAssertTrue(camera.gestureRecognizer(observer, shouldReceive: touch))
    XCTAssertTrue(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    gate.beginPencilAction(source: pencil)
    let generation = gate.pencilGeneration
    card.frame.origin.y = 500
    XCTAssertTrue(gate.permitsSceneContact(at: .init(x: 200, y: 200)), "Keyboard movement uses current native bounds")
    XCTAssertFalse(gate.permitsSceneContact(at: .init(x: 200, y: 550)))
    XCTAssertTrue(gate.hasActivePencil)
    XCTAssertEqual(gate.pencilGeneration, generation, "Moving or updating the card does not end outside Pencil")
    gate.endPencilAction(source: pencil)
    card.removeFromSuperview()
    XCTAssertTrue(gate.permitsSceneContact(at: .init(x: 200, y: 550)))
  }

  @MainActor
  func testControlRegionMovesToTheNewGateWithoutLeavingAnOldExclusion() throws {
    let first = NotebookInputGate(), second = NotebookInputGate()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    let card = NotebookControlRegionView(gate: first)
    card.frame = .init(x: 100, y: 150, width: 300, height: 320); host.view.addSubview(card)
    defer { card.unregister(); window.isHidden = true }
    let point = CGPoint(x: 200, y: 200)
    XCTAssertFalse(first.permitsSceneContact(at: point))
    card.use(second)
    XCTAssertTrue(first.permitsSceneContact(at: point))
    XCTAssertFalse(second.permitsSceneContact(at: point))
    card.isHidden = true
    XCTAssertTrue(second.permitsSceneContact(at: point))
  }
}

private final class QuestionControlTouch: UITouch {
  var point = CGPoint.zero
  weak var source: UIView?
  override var view: UIView? { source }
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: view?.window) ?? point }
}
