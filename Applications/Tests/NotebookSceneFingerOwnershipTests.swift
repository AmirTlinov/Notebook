import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookSceneFingerOwnershipTests: XCTestCase {
  func testSelectionCannotPointOrLiftLoadedProgramButStillSelectsPaperAndEmptyCanvas() async throws {
    let fixture = try SceneSelectionOwnershipFixture()
    defer { fixture.close() }
    let program = try await mountedWeb(in: fixture.root.view, y: 100, holdsFingerInput: true)
    let paper = try await mountedWeb(in: fixture.root.view, y: 500, holdsFingerInput: false)
    defer { program.retire(); paper.retire() }
    let programWeb = try XCTUnwrap(program.webView), paperWeb = try XCTUnwrap(paper.webView)
    let programHit = try XCTUnwrap(programWeb.hitTest(CGPoint(x: 100, y: 60), with: nil))
    let paperHit = try XCTUnwrap(paperWeb.hitTest(CGPoint(x: 100, y: 60), with: nil))
    var points = 0, liftRequests = 0, liftBegins = 0, liftEnds = 0
    fixture.selection.recognizer.onPoint = { _, _, _, _ in points += 1 }
    fixture.selection.recognizer.onLift = { _ in liftRequests += 1; return nil }

    // Exercise UIKit's delegate -> accepted callback route against an actual
    // loaded WK subtree. This is a deterministic admission seam, not a claim
    // that these test UITouch objects were delivered by the OS.
    let tap = fixture.touch(target: programHit, point: CGPoint(x: 100, y: 160))
    let acceptedTap = fixture.begin(tap)
    fixture.end(tap, deliveredToSelection: acceptedTap)
    XCTAssertFalse(acceptedTap, "A program click must not also publish scene attention")
    XCTAssertEqual(points, 0); XCTAssertEqual(liftRequests, 0)

    fixture.selection.recognizer.onLift = { _ in
      liftRequests += 1
      return SceneSelectionLift(begin: { liftBegins += 1 }, change: { _ in },
        end: { _ in liftEnds += 1 }, cancel: {})
    }
    let hold = fixture.touch(target: programHit, point: CGPoint(x: 100, y: 160))
    let acceptedHold = fixture.begin(hold)
    if acceptedHold { try await Task.sleep(for: .milliseconds(250)) }
    fixture.end(hold, deliveredToSelection: acceptedHold)
    XCTAssertFalse(acceptedHold, "An accepted program contact cannot start an artifact lift")
    XCTAssertEqual(liftRequests, 0); XCTAssertEqual(liftBegins, 0); XCTAssertEqual(liftEnds, 0)

    fixture.selection.recognizer.onLift = { _ in nil }
    let paperTouch = fixture.touch(target: paperHit, point: CGPoint(x: 100, y: 560))
    let acceptedPaper = fixture.begin(paperTouch)
    fixture.end(paperTouch, deliveredToSelection: acceptedPaper)
    XCTAssertTrue(acceptedPaper, "The paper's WK class does not make it an interactive program")
    XCTAssertEqual(points, 1)
    let empty = fixture.touch(target: fixture.root.view, point: CGPoint(x: 500, y: 400))
    let acceptedEmpty = fixture.begin(empty)
    fixture.end(empty, deliveredToSelection: acceptedEmpty)
    XCTAssertTrue(acceptedEmpty); XCTAssertEqual(points, 2)
    XCTAssertEqual(fixture.gate.admittedFingerContactCount, 0)
  }

  func testSelectionRespectsFrozenNativeOwnerAndPreservesCoverTextScrollAndPencilOwners() throws {
    let fixture = try SceneSelectionOwnershipFixture()
    defer { fixture.close() }
    let button = UIButton(type: .system), content = UIView()
    button.addSubview(content); fixture.root.view.addSubview(button)
    let touch = fixture.touch(target: content, point: CGPoint(x: 100, y: 160))
    fixture.observer.touchesBegan([touch], with: UIEvent())
    fixture.root.view.addSubview(content)
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: content), .scene)
    XCTAssertFalse(fixture.admits(touch),
      "Selection must use the original accepted owner even after reparenting")
    fixture.observer.touchesEnded([touch], with: UIEvent())
    let fresh = fixture.touch(target: content, point: CGPoint(x: 100, y: 160))
    XCTAssertTrue(fixture.admits(fresh), "The ended contact must not reserve future scene contacts")
    fixture.observer.touchesBegan([fresh], with: UIEvent())
    fixture.observer.touchesCancelled([fresh], with: UIEvent())

    let text = UITextView(), scroll = UIScrollView(), scrollContent = UIView()
    text.isEditable = false; text.isSelectable = true
    let cover = NotebookInteractionTouchView(inputGate: fixture.gate), coverContent = UIView()
    cover.addSubview(coverContent); scroll.addSubview(scrollContent)
    for view in [text, scroll, cover] { fixture.root.view.addSubview(view) }
    for target in [button, text, scrollContent, coverContent] {
      let native = fixture.touch(target: target, point: CGPoint(x: 100, y: 160))
      XCTAssertFalse(fixture.admits(native))
      fixture.observer.touchesBegan([native], with: UIEvent())
      fixture.observer.touchesCancelled([native], with: UIEvent())
    }
    let pencil = SceneFingerOwnershipTouch(target: fixture.root.view, window: fixture.window,
      point: CGPoint(x: 500, y: 400), kind: .pencil)
    XCTAssertFalse(fixture.admits(pencil), "Selection must leave Pencil to its existing input owner")
    XCTAssertEqual(fixture.gate.admittedFingerContactCount, 0)
  }

  func testCameraAdmissionKeepsLoadedProgramInputButAllowsDocumentPaper() async throws {
    let gate = NotebookInputGate(), root = UIViewController()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = root; window.makeKeyAndVisible()
    let anchor = GestureAnchorView(frame: root.view.bounds)
    anchor.isUserInteractionEnabled = false; root.view.addSubview(anchor)
    let coordinator = WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn: false,
      isEnabled: true, inputGate: gate, onCamera: { _ in XCTFail("Admission must not synthesize a camera gesture") }, onUndo: {})
    coordinator.install(on: window, inside: anchor)
    defer {
      coordinator.uninstall(); window.isHidden = true; window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    let camera = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TwoFingerPaperGestureRecognizer }.first)
    let observer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
    let program = try await mountedWeb(in: root.view, y: 100, holdsFingerInput: true)
    let paper = try await mountedWeb(in: root.view, y: 500, holdsFingerInput: false)
    defer { program.retire(); paper.retire() }
    let programWeb = try XCTUnwrap(program.webView), paperWeb = try XCTUnwrap(paper.webView)
    let programHit = try XCTUnwrap(programWeb.hitTest(CGPoint(x: 100, y: 60), with: nil))
    let paperHit = try XCTUnwrap(paperWeb.hitTest(CGPoint(x: 100, y: 60), with: nil))
    let first = SceneFingerOwnershipTouch(target: programHit, window: window, point: CGPoint(x: 100, y: 160))
    let second = SceneFingerOwnershipTouch(target: programHit, window: window, point: CGPoint(x: 110, y: 160))
    // These are deterministic native admission callbacks against a loaded WK
    // subtree, not injected DOM events or a claim of real touch delivery.
    XCTAssertFalse(coordinator.gestureRecognizer(camera, shouldReceive: first))
    XCTAssertTrue(coordinator.gestureRecognizer(observer, shouldReceive: first))
    observer.touchesBegan([first], with: UIEvent())
    XCTAssertFalse(coordinator.gestureRecognizer(camera, shouldReceive: second),
      "A later finger must not let the camera take the program's accepted sequence")
    observer.touchesBegan([second], with: UIEvent())
    XCTAssertEqual(gate.admittedFingerContactCount, 2)
    observer.touchesEnded([first, second], with: UIEvent())
    XCTAssertEqual(gate.admittedFingerContactCount, 0)
    let paperTouch = SceneFingerOwnershipTouch(target: paperHit, window: window, point: CGPoint(x: 100, y: 560))
    XCTAssertTrue(coordinator.gestureRecognizer(camera, shouldReceive: paperTouch),
      "The paper's WK class must not prohibit camera navigation")
    observer.touchesBegan([paperTouch], with: UIEvent())
    observer.touchesCancelled([paperTouch], with: UIEvent())
    XCTAssertEqual(gate.admittedFingerContactCount, 0)
  }

  func testNativeOwnerSurvivesReparentingAndEndsWithTheMeasuredContact() {
    let gate = NotebookInputGate(), root = UIView(), button = UIButton(type: .system), content = UIView()
    button.addSubview(content); root.addSubview(button)
    let touch = SceneFingerOwnershipTouch(target: content)
    let original = NotebookSceneFingerRouting.owner(of: touch, gate: gate)
    XCTAssertEqual(original, .nativeInput(ObjectIdentifier(button)))
    root.addSubview(content)
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: content), .scene)
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: touch, gate: gate), original,
      "A scene publication or native reparent must not replace an accepted owner")
    gate.endFingerContacts([ObjectIdentifier(touch)])
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: touch, gate: gate), .scene)
    gate.endFingerContacts([ObjectIdentifier(touch)])
    XCTAssertEqual(gate.admittedFingerContactCount, 0)
  }

  func testNativeTextAndEnabledScrollKeepInputWhileUnownedCanvasAllowsCamera() {
    let button = UIButton(type: .system), text = UITextView(), scroll = UIScrollView(), child = UIView()
    XCTAssertNotEqual(NotebookSceneFingerRouting.owner(of: button), .scene)
    text.isEditable = false; text.isSelectable = true
    XCTAssertNotEqual(NotebookSceneFingerRouting.owner(of: text), .scene, "Native selection remains an input owner")
    scroll.addSubview(child)
    XCTAssertNotEqual(NotebookSceneFingerRouting.owner(of: child), .scene)
    scroll.panGestureRecognizer.isEnabled = false
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: child), .scene,
      "An inert document scroll container is not an active scrolling control")
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: UIView()), .scene)
  }

  func testObserverTransfersFrozenOwnerAndCleansCancellationAndRetirement() {
    let gate = NotebookInputGate(), next = NotebookInputGate(), button = UIButton(type: .system)
    let touch = SceneFingerOwnershipTouch(target: button), observer = NotebookContactObserver(gate: gate)
    observer.touchesBegan([touch], with: UIEvent())
    observer.use(next)
    XCTAssertEqual(gate.admittedFingerContactCount, 0)
    XCTAssertEqual(next.admittedFingerContactCount, 1)
    let canvas = UIView()
    touch.target = canvas
    XCTAssertEqual(NotebookSceneFingerRouting.owner(of: touch, gate: next), .nativeInput(ObjectIdentifier(button)))
    observer.touchesCancelled([touch], with: UIEvent())
    observer.finish(); observer.finish()
    XCTAssertEqual(next.admittedFingerContactCount, 0)
    let remaining = SceneFingerOwnershipTouch(target: button)
    observer.touchesBegan([remaining], with: UIEvent())
    observer.finish()
    XCTAssertEqual(next.admittedFingerContactCount, 0)
  }

  func testLedgerDoesNotRetainTouchOrViewAndObserverDeinitReleasesItsClaims() {
    let gate = NotebookInputGate()
    weak var releasedView: UIView?, releasedTouch: UITouch?, releasedObserver: NotebookContactObserver?
    autoreleasepool {
      let button = UIButton(type: .system), touch = SceneFingerOwnershipTouch(target: nil)
      touch.target = button
      let observer = NotebookContactObserver(gate: gate)
      releasedView = button; releasedTouch = touch; releasedObserver = observer
      observer.touchesBegan([touch], with: UIEvent())
      XCTAssertEqual(gate.admittedFingerContactCount, 1)
    }
    XCTAssertNil(releasedView); XCTAssertNil(releasedTouch); XCTAssertNil(releasedObserver)
    XCTAssertEqual(gate.admittedFingerContactCount, 0)
  }

  func testRestingSceneFingerDoesNotKeepPencilCompletionBehindTheIdleBarrier() async throws {
    for fingerFirst in [true, false] {
      let gate = NotebookInputGate(), surface = UIView(), pencil = UUID()
      let observer = NotebookContactObserver(gate: gate), hand = SceneFingerOwnershipTouch(target: surface)
      if fingerFirst { observer.touchesBegan([hand], with: UIEvent()) }
      XCTAssertTrue(gate.beginPencilAction(source: pencil))
      if !fingerFirst { observer.touchesBegan([hand], with: UIEvent()) }
      var completed = false
      gate.performAfterIdle { completed = true }
      XCTAssertFalse(completed)
      gate.endPencilAction(source: pencil)
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertFalse(gate.isActive, "A scene finger cancelled by Pencil is not an unfinished command")
      XCTAssertTrue(completed)
      XCTAssertEqual(gate.admittedFingerContactCount, 1, "Only physical lift retires the contact identity")
      observer.touchesEnded([hand], with: UIEvent())
      XCTAssertEqual(gate.admittedFingerContactCount, 0)
      observer.touchesBegan([hand], with: UIEvent())
      XCTAssertTrue(gate.isActive, "A fresh finger-only gesture must still own the barrier")
      observer.touchesEnded([hand], with: UIEvent())
    }
  }

  func testPencilDoesNotReleaseAnIndependentNativeControlContact() async throws {
    let gate = NotebookInputGate(), button = UIButton(), pencil = UUID()
    let observer = NotebookContactObserver(gate: gate), finger = SceneFingerOwnershipTouch(target: button)
    observer.touchesBegan([finger], with: UIEvent())
    XCTAssertTrue(gate.beginPencilAction(source: pencil))
    var completed = false
    gate.performAfterIdle { completed = true }
    gate.endPencilAction(source: pencil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(gate.isActive); XCTAssertFalse(completed)
    observer.touchesEnded([finger], with: UIEvent())
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(gate.isActive); XCTAssertTrue(completed)
  }

  func testMeasuredPencilLiftHasNoSecondWindowObserverBarrier() async throws {
    let gate = NotebookInputGate(), surface = UIView(), source = UUID()
    let observer = NotebookContactObserver(gate: gate)
    let pencil = SceneFingerOwnershipTouch(target: surface, kind: .pencil)
    XCTAssertEqual(observer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
    observer.touchesBegan([pencil], with: UIEvent())
    XCTAssertFalse(gate.isActive)
    XCTAssertEqual(gate.admittedFingerContactCount, 0, "Pencil is not a finger-routing claim")
    let hand = SceneFingerOwnershipTouch(target: surface)
    observer.touchesBegan([hand], with: UIEvent())
    XCTAssertTrue(gate.beginPencilAction(source: source))
    var completed = false
    gate.performAfterIdle { completed = true }
    XCTAssertFalse(completed, "The measured Pencil contact still owns the barrier")
    gate.endPencilAction(source: source)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(gate.isActive)
    XCTAssertTrue(completed, "Measured ink is complete; neither observer reset nor hand-up may postpone it")
    XCTAssertEqual(gate.admittedFingerContactCount, 1)
    observer.touchesEnded([hand], with: UIEvent())
  }

  func testRestingContactTransfersWithoutRevivingItsActivity() async throws {
    let gate = NotebookInputGate(), next = NotebookInputGate(), surface = UIView(), pencil = UUID()
    let observer = NotebookContactObserver(gate: gate), hand = SceneFingerOwnershipTouch(target: surface)
    observer.touchesBegan([hand], with: UIEvent())
    XCTAssertTrue(gate.beginPencilAction(source: pencil))
    gate.endPencilAction(source: pencil)
    observer.use(next)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(gate.isActive); XCTAssertFalse(next.isActive)
    XCTAssertEqual(gate.admittedFingerContactCount, 0)
    XCTAssertEqual(next.admittedFingerContactCount, 1)
    observer.touchesCancelled([hand], with: UIEvent())
    XCTAssertEqual(next.admittedFingerContactCount, 0)
    observer.touchesBegan([hand], with: UIEvent())
    XCTAssertTrue(next.isActive)
    XCTAssertTrue(next.beginPencilAction(source: pencil))
    next.endPencilAction(source: pencil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(next.isActive, "Pencil cancellation was rebound to the current gate")
    observer.finish()
  }

  private func mountedWeb(in root: UIView, y: CGFloat, holdsFingerInput: Bool) async throws -> PhysicalWebViewport {
    let web = WKWebView(frame: .zero)
    web.scrollView.isScrollEnabled = false
    web.scrollView.panGestureRecognizer.isEnabled = false
    web.scrollView.pinchGestureRecognizer?.isEnabled = false
    let host = PhysicalWebViewport(webView: web, contentSize: CGSize(width: 320, height: 240), holdsFingerInput: holdsFingerInput)
    host.frame = CGRect(x: 0, y: y, width: 320, height: 240)
    root.addSubview(host); host.setNeedsLayout(); host.layoutIfNeeded()
    web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><button style='width:200px;height:100px'>Ready control</button><p>Paper content</p>", baseURL: nil)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if let ready = try? await web.evaluateJavaScript("document.readyState"), ready as? String == "complete" {
        let title = try await web.evaluateJavaScript("document.querySelector('button')?.textContent")
        if title as? String == "Ready control" { return host }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The real WK source did not load")
    throw NSError(domain: "NotebookSceneFingerOwnershipTests", code: 1)
  }
}

@MainActor
private final class SceneFingerOwnershipTouch: UITouch {
  weak var target: UIView?
  private weak var sourceWindow: UIWindow?
  private let point: CGPoint
  private let kind: UITouch.TouchType
  init(target: UIView?, window: UIWindow? = nil, point: CGPoint = .zero, kind: UITouch.TouchType = .direct) {
    self.target = target; sourceWindow = window; self.point = point; self.kind = kind
    super.init()
  }
  override var view: UIView? { target }
  override var type: UITouch.TouchType { kind }
  override func location(in view: UIView?) -> CGPoint { sourceWindow?.convert(point, to: view) ?? point }
}

@MainActor
private final class SceneSelectionOwnershipFixture {
  let gate = NotebookInputGate()
  let root = UIViewController()
  let window: UIWindow
  let anchor: GestureAnchorView
  let selection = NotebookSelectionGesture.Coordinator()
  let observer: NotebookContactObserver
  private let previousKeyWindow: UIWindow?

  init() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    window = UIWindow(windowScene: scene)
    window.rootViewController = root; window.makeKeyAndVisible()
    root.view.layoutIfNeeded()
    anchor = GestureAnchorView(frame: root.view.bounds)
    anchor.isUserInteractionEnabled = false; root.view.addSubview(anchor)
    observer = NotebookContactObserver(gate: gate)
    window.addGestureRecognizer(observer)
    selection.gate = gate; selection.install(anchor)
  }

  func touch(target: UIView, point: CGPoint) -> SceneFingerOwnershipTouch {
    SceneFingerOwnershipTouch(target: target, window: window, point: point)
  }
  func admits(_ touch: UITouch) -> Bool {
    selection.gestureRecognizer(selection.recognizer, shouldReceive: touch)
  }
  func begin(_ touch: UITouch) -> Bool {
    selection.recognizer.isEnabled = false; selection.recognizer.isEnabled = true
    let accepted = admits(touch)
    observer.touchesBegan([touch], with: UIEvent())
    if accepted { selection.recognizer.touchesBegan([touch], with: UIEvent()) }
    return accepted
  }
  func end(_ touch: UITouch, deliveredToSelection: Bool) {
    if deliveredToSelection { selection.recognizer.touchesEnded([touch], with: UIEvent()) }
    observer.touchesEnded([touch], with: UIEvent())
  }
  func close() {
    selection.uninstall(); observer.finish(); window.removeGestureRecognizer(observer)
    window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey()
  }
}
