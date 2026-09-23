import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookObjectPickupTests: XCTestCase {
  func testUnselectedSwipeYieldsToPageAndCannotPickUpWhenTheFingerStops() async throws {
    let f = PickupFixture(requiresHold: true)
    f.begin()
    XCTAssertTrue(f.gate.permitsPageNavigation)
    XCTAssertTrue(f.gate.permitsSingleFingerNavigation(ObjectIdentifier(f.touch)))
    XCTAssertFalse(f.selection.canPrevent(f.curl))
    f.touch.point.x += 6
    f.selection.touchesMoved([f.touch], with: UIEvent())
    // Stopping after a swipe must not turn the same contact into a hold.
    try await Task.sleep(for: .milliseconds(320))
    f.selection.touchesEnded([f.touch], with: UIEvent())
    XCTAssertEqual(f.events, []); XCTAssertEqual(f.taps, 0)
    XCTAssertTrue(f.gate.permitsPageNavigation)
  }

  func testQuickTapSelectsButHoldPicksUpAndDropsWithTheSameContact() async throws {
    let f = PickupFixture(requiresHold: true)
    f.begin()
    try await Task.sleep(for: .milliseconds(70))
    f.selection.touchesEnded([f.touch], with: UIEvent())
    XCTAssertEqual(f.taps, 1); XCTAssertEqual(f.events, [])
    f.retire()
    // UIKit retires the completed physical sequence before delivering a new
    // one; direct callback fixtures must also allow that reset to run.
    try await Task.sleep(for: .milliseconds(16))
    f.begin()
    // A view publication cannot redirect the frozen down target.
    f.selection.onLift = { _ in XCTFail("A held contact already resolved its material"); return nil }
    try await Task.sleep(for: .milliseconds(320))
    XCTAssertEqual(f.events, ["begin"], "Pickup is visible before any movement or extra tap")
    XCTAssertFalse(f.gate.permitsPageNavigation)
    XCTAssertTrue(f.selection.canPrevent(f.curl))
    f.touch.point = .init(x: 160, y: 140)
    f.selection.touchesMoved([f.touch], with: UIEvent())
    f.selection.touchesEnded([f.touch], with: UIEvent())
    XCTAssertEqual(f.events, ["begin", "end"])
    XCTAssertEqual(f.translation, .init(x: 60, y: 40)); XCTAssertEqual(f.taps, 1)
  }

  func testAlreadySelectedMaterialMovesWithoutAHold() {
    let f = PickupFixture(requiresHold: false)
    f.begin()
    XCTAssertFalse(f.gate.permitsPageNavigation)
    XCTAssertEqual(f.events, [])
    f.touch.point.x += 6
    f.selection.touchesMoved([f.touch], with: UIEvent())
    XCTAssertEqual(f.events, ["begin"])
    f.selection.touchesEnded([f.touch], with: UIEvent())
    XCTAssertEqual(f.events, ["begin", "end"])
  }

  func testUnselectedMaterialYieldsToBothCameraAndPageRegardlessOfDeliveryOrder() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for selectionFirst in [false, true] {
      let f = PickupFixture(requiresHold: true), window = UIWindow(windowScene: scene), root = UIViewController()
      window.rootViewController = root; window.makeKeyAndVisible()
      f.view.frame = root.view.bounds; f.child.frame = f.view.bounds; root.view.addSubview(f.view)
      let camera = WorkspacePanView.Coordinator(isEnabled: true, inputGate: f.gate,
        onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
      camera.install(on: window, inside: f.view)
      defer { camera.uninstall(); f.selection.cancelSelection(); window.isHidden = true; previous?.makeKey() }
      let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
      let page = PageTurnAdmissionRecognizer(); f.child.addGestureRecognizer(page)
      page.canBeginNavigation = { f.gate.permitsPageNavigation }
      if selectionFirst { f.begin() }
      XCTAssertTrue(camera.gestureRecognizer(pan, shouldReceive: f.touch))
      if !selectionFirst { f.begin() }
      page.touchesBegan([f.touch], with: UIEvent())
      XCTAssertTrue(camera.gestureRecognizerShouldBegin(pan))
      f.touch.point.x += 20
      page.touchesMoved([f.touch], with: UIEvent())
      XCTAssertTrue(page.state == .failed || page.state == .possible,
        "Admission must not block the curl; UIKit can already reset .failed to .possible")
      f.selection.touchesMoved([f.touch], with: UIEvent())
      XCTAssertEqual(f.events, [])
      f.selection.touchesEnded([f.touch], with: UIEvent()); f.retire()
    }
  }

  func testSecondFingerCancelsBothPendingAndPickedUpMaterialWithoutACommit() async throws {
    for pickedUp in [false, true] {
      let f = PickupFixture(requiresHold: true)
      f.begin()
      if pickedUp {
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(f.events, ["begin"])
        f.touch.point.x += 30
        f.selection.touchesMoved([f.touch], with: UIEvent())
      }
      let second = PickupTouch()
      _ = f.gate.fingerContactOwner(for: ObjectIdentifier(second)) { .scene }
      f.selection.touchesBegan([second], with: UIEvent())
      f.gate.endFingerContacts([ObjectIdentifier(second)])
      // Even a recognizer reset cannot make the remaining pinch finger fresh.
      f.selection.isEnabled = false; f.selection.isEnabled = true
      f.selection.touchesBegan([f.touch], with: UIEvent())
      f.touch.point.x += 20
      f.selection.touchesMoved([f.touch], with: UIEvent())
      try await Task.sleep(for: .milliseconds(320))
      f.selection.touchesEnded([f.touch], with: UIEvent())
      XCTAssertEqual(f.events, pickedUp ? ["begin", "cancel"] : [])
      XCTAssertEqual(f.taps, 0)
      XCTAssertFalse(f.gate.permitsObjectPickup)
      f.retire()
      XCTAssertTrue(f.gate.permitsObjectPickup)
    }
  }

  func testPencilAndRetiredViewCancelThePendingHold() async throws {
    for pencil in [false, true] {
      let f = PickupFixture(requiresHold: true), source = UUID()
      f.gate.registerFingerCancellation(source: source) { f.selection.cancelSelection() }
      defer { f.gate.unregisterFingerCancellation(source: source) }
      f.begin()
      if pencil { XCTAssertTrue(f.gate.beginPencilAction(source: source)) }
      else { f.selection.cancelSelection() }
      try await Task.sleep(for: .milliseconds(320))
      f.selection.touchesEnded([f.touch], with: UIEvent())
      XCTAssertEqual(f.events, []); XCTAssertEqual(f.taps, 0)
      if pencil { f.gate.endPencilAction(source: source) }
    }
  }

  func testPairSuppressionSurvivesOneFingerLiftingAndGateTransfer() {
    let first = UIView(), second = UIView(), third = UIView()
    let a = ObjectIdentifier(first), b = ObjectIdentifier(second), c = ObjectIdentifier(third)
    let gate = NotebookInputGate(), next = NotebookInputGate()
    _ = gate.fingerContactOwner(for: a) { .scene }
    XCTAssertTrue(gate.permitsObjectPickup)
    _ = gate.fingerContactOwner(for: b) { .scene }
    gate.endFingerContacts([b])
    XCTAssertFalse(gate.permitsObjectPickup)
    gate.transferFingerContacts([a], to: next)
    XCTAssertTrue(gate.permitsObjectPickup)
    XCTAssertFalse(next.permitsObjectPickup)
    _ = next.fingerContactOwner(for: c) { .scene }
    next.endFingerContacts([a])
    XCTAssertFalse(next.permitsObjectPickup)
    next.endFingerContacts([c])
    XCTAssertTrue(next.permitsObjectPickup)
  }
}

@MainActor private final class PickupFixture {
  let gate = NotebookInputGate(), selection = SceneSelectionRecognizer(), touch = PickupTouch()
  let view = UIView(), child = UIView(), curl = UIPanGestureRecognizer()
  var events: [String] = []
  var taps = 0
  var translation = CGPoint.zero
  init(requiresHold: Bool) {
    view.addSubview(child); child.addGestureRecognizer(curl)
    view.addGestureRecognizer(selection); selection.gate = gate
    selection.onPoint = { [weak self] _, _ in self?.taps += 1 }
    selection.onLift = { [weak self] _ in
      .init(requiresHold: requiresHold, begin: { self?.events.append("begin") },
        change: { self?.translation = $0 }, end: { self?.translation = $0; self?.events.append("end") },
        cancel: { self?.events.append("cancel") })
    }
  }
  func begin() { selection.touchesBegan([touch], with: UIEvent()) }
  func retire() {
    gate.endFingerContacts([ObjectIdentifier(touch)])
    selection.isEnabled = false; selection.isEnabled = true
  }
  isolated deinit { selection.cancelSelection() }
}

@MainActor private final class PickupTouch: UITouch {
  var point = CGPoint(x: 100, y: 100)
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { point }
}
