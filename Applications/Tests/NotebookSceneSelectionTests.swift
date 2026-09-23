import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookSceneSelectionTests: XCTestCase {
  func testPageCurlAdmissionResolvesOwnershipBeforeMotion() {
    let view = UIView(), owner = PageTurnAdmissionRecognizer(), touch = SelectionTouch()
    view.addGestureRecognizer(owner)
    var allowed = true
    owner.canBeginNavigation = { allowed }
    owner.touchesBegan([touch],with:UIEvent())
    XCTAssertEqual(owner.state,.possible)
    // Selection refines the owner later in the same touchdown dispatch.
    allowed = false; touch.point.x += 20
    owner.touchesMoved([touch],with:UIEvent())
    XCTAssertEqual(owner.state,.began,"Dependent curl cannot begin after the object reserves this finger")
    XCTAssertFalse(owner.canPrevent(UIPanGestureRecognizer()),"Admission does not block the object's own recognizer")
    owner.isEnabled = false; owner.isEnabled = true; allowed = true
    owner.touchesBegan([touch],with:UIEvent()); touch.point.x += 20
    owner.touchesMoved([touch],with:UIEvent())
    XCTAssertEqual(owner.state,.failed,"A fitted empty-paper swipe belongs to UIKit")
    let zoomed = PageTurnAdmissionRecognizer(); view.addGestureRecognizer(zoomed)
    zoomed.canBeginNavigation = { false }
    zoomed.touchesBegan([touch],with:UIEvent())
    XCTAssertEqual(zoomed.state,.began,"Zoomed paper denies curl from touchdown")
  }

  func testColdSwipeKeepsIntentUntilLiftAndReversalOrPinchCancelsIt() {
    let view = UIView(), touch = SelectionTouch()
    var owner = PageTurnAdmissionRecognizer()
    var directions: [Int] = [], outcomes: [Bool] = []
    func begin() {
      view.removeGestureRecognizer(owner); owner = PageTurnAdmissionRecognizer(); view.addGestureRecognizer(owner)
      owner.prepareDirection = { directions.append($0); return false }
      owner.finishColdSwipe = { outcomes.append($0) }
      touch.point = .init(x:200,y:200); owner.touchesBegan([touch],with:UIEvent())
    }
    begin(); touch.point.x = 180; owner.touchesMoved([touch],with:UIEvent())
    XCTAssertEqual(owner.state,.began); XCTAssertEqual(directions,[1]); XCTAssertTrue(outcomes.isEmpty)
    touch.point.x = 90; owner.touchesEnded([touch],with:UIEvent())
    XCTAssertEqual(outcomes,[true], "One completed cold gesture must not disappear into a nil neighbour")
    begin(); touch.point.x = 180; owner.touchesMoved([touch],with:UIEvent())
    touch.point.x = 200; owner.touchesEnded([touch],with:UIEvent())
    XCTAssertEqual(outcomes,[true,false], "A reversal is not a deferred page change")
    begin(); touch.point.x = 180; owner.touchesMoved([touch],with:UIEvent())
    owner.touchesCancelled([touch],with:UIEvent())
    XCTAssertEqual(outcomes,[true,false,false])
    begin(); touch.point.x = 180; owner.touchesMoved([touch],with:UIEvent())
    let second = SelectionTouch(); second.point = .init(x:220,y:200)
    owner.touchesBegan([second],with:UIEvent())
    second.point.x = 320; owner.touchesMoved([second],with:UIEvent())
    XCTAssertEqual(outcomes,[true,false,false,false], "Pinch must cancel the old page intent before finger-up")
  }

  func testKeyboardLayoutShiftIsNotFingerMotion() {
    let window = UIWindow(frame:.init(x:0,y:0,width:600,height:800)), anchor = UIView(frame:.init(x:0,y:0,width:600,height:800))
    window.addSubview(anchor)
    let recognizer = SceneSelectionRecognizer(), gate = NotebookInputGate()
    window.addGestureRecognizer(recognizer); recognizer.coordinateView = anchor; recognizer.gate = gate
    let touch = WindowSelectionTouch(window:window)
    var begins = 0, drops = 0, taps = 0, delta = CGPoint.zero
    recognizer.onPoint = { _,_ in taps += 1 }
    recognizer.onLift = { _ in .init(begin:{ begins += 1 },change:{ delta = $0 },end:{ delta = $0; drops += 1 },cancel:{}) }
    recognizer.touchesBegan([touch],with:UIEvent())
    anchor.frame.origin = .init(x:70,y:-176)
    recognizer.touchesMoved([touch],with:UIEvent())
    recognizer.touchesEnded([touch],with:UIEvent())
    XCTAssertEqual(begins,0); XCTAssertEqual(drops,0); XCTAssertEqual(taps,1)
    recognizer.isEnabled = false; recognizer.isEnabled = true
    recognizer.touchesBegan([touch],with:UIEvent())
    anchor.frame.origin = .zero; touch.point = .init(x:140,y:160)
    recognizer.touchesMoved([touch],with:UIEvent())
    recognizer.touchesEnded([touch],with:UIEvent())
    XCTAssertEqual(begins,1); XCTAssertEqual(drops,1); XCTAssertEqual(delta,.init(x:40,y:60))
  }

  func testLinkKeepsItsTapAndHoldingLiftsItsMaterial() async throws {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = SelectionTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    let content = UIView(), neighbour = UIView()
    view.addSubview(content)
    let nativeHold = UILongPressGestureRecognizer(), neighbourHold = UILongPressGestureRecognizer(), camera = UIPanGestureRecognizer()
    content.addGestureRecognizer(nativeHold); neighbour.addGestureRecognizer(neighbourHold)
    var begins = 0, drops = 0
    recognizer.onPoint = { _, _ in XCTFail("The original link owns a short tap") }
    recognizer.onLift = { _ in .init(requiresHold: true, begin: { begins += 1 }, change: { _ in }, end: { _ in drops += 1 }, cancel: {}) }
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
    gate.endFingerContacts([ObjectIdentifier(touch)])
    recognizer.isEnabled = false; recognizer.isEnabled = true
    try await Task.sleep(for: .milliseconds(16))
    begin(); try await Task.sleep(for: .milliseconds(320))
    XCTAssertEqual(begins,1)
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

@MainActor private final class WindowSelectionTouch: UITouch {
  let coordinateWindow: UIWindow
  var point = CGPoint(x:100,y:100)
  init(window: UIWindow) { coordinateWindow = window; super.init() }
  override var type: UITouch.TouchType { .direct }
  override func location(in view: UIView?) -> CGPoint { coordinateWindow.convert(point,to:view) }
}
