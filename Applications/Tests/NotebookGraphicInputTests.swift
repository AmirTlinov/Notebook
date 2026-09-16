import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicInputTests: XCTestCase {
  func testMeasuredPencilHoldUsesTheExistingPageContactAndKeepsItsOriginalSamples() async throws {
    let paper = PaperInputView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
    paper.configure(penStyle: .standard, eraserStyle: .standard, drawingTool: .pen)
    let touch = GraphicPencilTouch()
    var accepted: PageInkAction?, fit: NotebookQuickShapeFit?
    paper.onDrawingMutation = { accepted = $0; fit = paper.completedQuickShape }
    touch.point = CGPoint(x: 300, y: 200)
    paper.touchesBegan([touch], with: nil)
    for i in 1...120 {
      let angle = Double(i) / 120 * 2 * Double.pi
      touch.point = .init(x: 200 + 100 * cos(angle), y: 200 + 65 * sin(angle)); touch.sampleTime += 0.01
      paper.touchesMoved([touch], with: nil)
    }
    XCTAssertNil(accepted, "A hold previews; it does not publish a stroke or shape")
    try await Task.sleep(for: .milliseconds(600))
    touch.point.x += 10; touch.sampleTime += 0.01
    paper.touchesMoved([touch], with: nil)
    paper.touchesEnded([touch], with: nil)
    XCTAssertNotNil(fit)
    XCTAssertGreaterThan(try XCTUnwrap(fit).frame.width, 210, "Pencil adjusts the recognized geometry before lift")
    let raw = try XCTUnwrap(accepted)
    XCTAssertEqual(raw.samples.count, 121, "Handle motion is not appended to the original sketch")
    XCTAssertEqual(raw.samples.last?.point.x ?? 0, 300, accuracy: 0.001)
    XCTAssertFalse(paper.hasActiveAction)
  }

  func testPencilCancellationAndOrdinaryHandwritingNeverConvert() async throws {
    for cancel in [false, true] {
      let paper = PaperInputView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
      paper.configure(penStyle: .standard, eraserStyle: .standard, drawingTool: .pen)
      let touch = GraphicPencilTouch(); var raw: PageInkAction?, shape: NotebookQuickShapeFit?
      paper.onDrawingMutation = { raw = $0; shape = paper.completedQuickShape }
      paper.touchesBegan([touch], with: nil)
      for i in 1...80 {
        let angle = Double(i) / 80 * 2 * Double.pi
        touch.point = .init(x: 200 + 60 * cos(angle), y: 200 + 60 * sin(angle)); touch.sampleTime += 0.01
        paper.touchesMoved([touch], with: nil)
      }
      if cancel {
        try await Task.sleep(for: .milliseconds(600)); paper.touchesCancelled([touch], with: nil)
      } else { paper.touchesEnded([touch], with: nil) }
      XCTAssertNotNil(raw); XCTAssertNil(shape)
    }
  }

  func testFigureDragNeedsNoHoldAndSecondFingerCancelsWithoutAWrite() {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = GraphicFingerTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    var begins = 0, commits = 0, cancelled = 0, taps = 0
    recognizer.onPoint = { _, _, _, _ in taps += 1 }
    recognizer.onLift = { _ in .init(requiresHold: false, begin: { begins += 1 }, change: { _ in },
      end: { _ in commits += 1 }, cancel: { cancelled += 1 }) }
    recognizer.touchesBegan([touch], with: UIEvent())
    XCTAssertEqual(begins, 0)
    recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(taps, 1); XCTAssertEqual(commits, 0)
    recognizer.reset()
    recognizer.touchesBegan([touch], with: UIEvent())
    touch.point.x += 10; recognizer.touchesMoved([touch], with: UIEvent())
    XCTAssertEqual(begins, 1)
    recognizer.touchesBegan([GraphicFingerTouch()], with: UIEvent())
    recognizer.touchesEnded([touch], with: UIEvent())
    XCTAssertEqual(cancelled, 1); XCTAssertEqual(commits, 0)
  }

  func testFigureOwnsOneFingerRegardlessOfRecognizerDeliveryOrderAndPairStartsAtCurrentPositions() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for selectionFirst in [false, true] {
      let window = UIWindow(windowScene: scene), host = UIViewController()
      let anchor = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
      window.rootViewController = host; host.view.addSubview(anchor); window.makeKeyAndVisible()
      let gate = NotebookInputGate(), selection = SceneSelectionRecognizer()
      window.addGestureRecognizer(selection); selection.coordinateView = anchor; selection.gate = gate
      let curl = UIPanGestureRecognizer(); anchor.addGestureRecognizer(curl)
      var cancellations = 0
      selection.onLift = { _ in .init(requiresHold: false, begin: {}, change: { _ in },
        end: { _ in XCTFail("The second finger cancelled the drop") }, cancel: { cancellations += 1 }) }
      let camera = BoardPanView.Coordinator(isEnabled: true, itemFrames: [], inputGate: gate,
        onTap: {}, onBegan: { XCTFail("The object contact cannot also pan") }, onChanged: { _ in },
        onEnded: { _ in }, onCancelled: {})
      camera.install(on: window, inside: anchor)
      let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
      let first = GraphicFingerTouch(), second = GraphicFingerTouch(), event = UIEvent()
      let pair = TwoFingerPaperGestureRecognizer(); anchor.addGestureRecognizer(pair)
      pair.inputGate = gate; pair.defersHorizontalMotionToPageTurn = true
      defer { camera.uninstall(); window.isHidden = true; previous?.makeKey() }
      if selectionFirst { selection.touchesBegan([first], with: event) }
      XCTAssertTrue(camera.gestureRecognizer(pan, shouldReceive: first))
      if !selectionFirst { selection.touchesBegan([first], with: event) }
      XCTAssertTrue(selection.canPrevent(curl), "System paper navigation is rejected before it starts an animation")
      XCTAssertFalse(selection.canPrevent(pan))
      pair.touchesBegan([first], with: event)
      XCTAssertFalse(camera.gestureRecognizerShouldBegin(pan))
      XCTAssertFalse(gate.permitsPageNavigation)
      first.point.x += 10; first.sampleTime += 0.1
      selection.touchesMoved([first], with: event); pair.touchesMoved([first], with: event)
      second.point.x = 160; second.sampleTime = first.sampleTime
      selection.touchesBegan([second], with: event); pair.touchesBegan([second], with: event)
      XCTAssertEqual(cancellations, 1)
      XCTAssertEqual(pair.startCentroidValue, CGPoint(x: 135, y: 100))
      XCTAssertFalse(camera.gestureRecognizerShouldBegin(pan), "Cancellation must not revive the original one-finger camera")
      first.point.x += 20; second.point.x += 20
      first.sampleTime += 0.1; second.sampleTime = first.sampleTime
      pair.touchesMoved([first, second], with: event)
      XCTAssertEqual(pair.intent, .navigation, "An object handoff owns the camera, not a page curl or undo")
      XCTAssertEqual(pair.translation, CGPoint(x: 20, y: 0))
      selection.touchesEnded([first], with: event)
      pair.touchesEnded([first, second], with: event)
      gate.endFingerContacts([ObjectIdentifier(first), ObjectIdentifier(second)])
      XCTAssertTrue(gate.permitsPageNavigation)
    }
  }

  func testNativeControlOwnershipCannotBeRefinedIntoAnObjectDrag() {
    let gate = NotebookInputGate(), touch = GraphicFingerTouch(), control = UITextField()
    let id = ObjectIdentifier(touch), owner = NotebookInputGate.FingerContactOwner.nativeInput(ObjectIdentifier(control))
    _ = gate.fingerContactOwner(for: id) { owner }
    gate.claimSceneObjectContact(id)
    XCTAssertEqual(gate.fingerContactOwner(for: id) { .scene }, owner)
    XCTAssertFalse(gate.hasSceneObjectContact)
    XCTAssertFalse(gate.permitsSingleFingerNavigation(id))
  }

  func testNativeCommandWaitsForTheSameContactReleaseMarker() async throws {
    let gate = NotebookInputGate(), source = UUID(); var events: [String] = []
    gate.onActivityChange = { events.append($0 ? "active" : "idle") }
    gate.beginContact(source: source)
    gate.performAfterIdle { events.append("command") }
    XCTAssertEqual(events, ["active"])
    gate.endContact(source: source)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(events, ["active", "idle", "command"])
  }

  func testNativeGraphicRasterNeverRequestsAWebKitSource() async throws {
    let element = AgentElement(id: "circle", kind: .graphic,
      frame: .init(x: 20, y: 20, width: 120, height: 120), source: "", html: "", graphic: .init(label: "+"))
    let page = PageDocument(size: .init(width: 200, height: 200), actor: UUID(), elements: [element])
    let resources = SceneRenderResources()
    let result = try await PageCompositionRenderer.render(page, scale: 1, resources: resources) { _ in
      XCTFail("Native geometry must not ask for WebKit pixels")
      throw SceneRenderError.snapshotPending("unexpected_webkit")
    }
    XCTAssertFalse(result.png.isEmpty)
  }

  func testPresentationMaskDoesNotChangeCanonicalInk() throws {
    let actor = UUID(), id = UUID()
    var journal = SpatialInkJournal(stamp: .init(counter: 1, actor: actor))
    let stroke = try XCTUnwrap(journal.append(tool: .pen, spans: [.init(surface: .board(id), samples: [
      .init(point: .zero, worldPoint: .zero, timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1),
      .init(point: .init(x: 20, y: 20), worldPoint: .init(x: 20, y: 20), timeOffset: 0.1, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], actor: actor))
    let raw = journal
    let shown = try SpatialInkMesh.prepare(surface: .board(id), journal: journal)
    let hidden = try SpatialInkMesh.prepare(surface: .board(id), journal: journal, suppressedInkIDs: [stroke.id])
    XCTAssertFalse(shown.batches.isEmpty); XCTAssertTrue(hidden.batches.isEmpty)
    XCTAssertEqual(journal, raw)
    let source = SpatialInkInstalledSource(surface: .board(id), journal: journal, suppressedInkIDs: [stroke.id])
    XCTAssertEqual(try source.reconciled(with: raw), raw)
    XCTAssertEqual(source.suppressedInkIDs, [stroke.id])
  }
}

@MainActor private final class GraphicPencilTouch: UITouch {
  var point = CGPoint(x: 260, y: 200)
  var sampleTime: TimeInterval = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func location(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
@MainActor private final class GraphicFingerTouch: UITouch {
  var point = CGPoint(x: 100, y: 100)
  var sampleTime: TimeInterval = 1
  override var type: UITouch.TouchType { .direct }
  override var timestamp: TimeInterval { sampleTime }
  override func location(in view: UIView?) -> CGPoint { point }
}
