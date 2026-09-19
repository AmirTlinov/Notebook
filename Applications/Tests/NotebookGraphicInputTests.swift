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
    XCTAssertNil(accepted, "The contact edits the held object; measured ink is accepted at lift")
    try await Task.sleep(for: .milliseconds(600))
    touch.point.x += 10; touch.sampleTime += 0.01
    paper.touchesMoved([touch], with: nil)
    paper.touchesEnded([touch], with: nil)
    XCTAssertNotNil(fit)
    XCTAssertEqual(try XCTUnwrap(fit).frame.width, 210, accuracy: 0.1,
      "The held edge follows ten points of Pencil travel, not twice the distance")
    XCTAssertEqual(try XCTUnwrap(fit).frame.x, 100, accuracy: 0.1, "The opposite edge remains fixed")
    let raw = try XCTUnwrap(accepted)
    XCTAssertEqual(raw.samples.count, 121, "Handle motion is not appended to the original sketch")
    XCTAssertEqual(raw.samples.last?.point.x ?? 0, 300, accuracy: 0.001)
    XCTAssertFalse(paper.hasActiveAction)
  }

  func testHeldShapesKeepBothDimensionsAdjustableFromEverySideAtAnyScale() {
    for scale in [0.5, 1.0, 3.0] {
      for shape in [NotebookGraphic.Shape.ellipse, .rectangle, .triangle, .diamond, .plus] {
        let frame = PageRect(x: 100 / scale, y: 70 / scale, width: 180 / scale, height: 120 / scale)
        var original = NotebookQuickShapeFit(frame: frame, sampleCount: 49, shape: shape)
        original.precedingStrokeIDs = [UUID()]
        for (x, y) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
          let held = SpatialPoint(x: frame.x + frame.width * (x + 1) / 2,
            y: frame.y + frame.height * (y + 1) / 2)
          let moved = SpatialPoint(x: held.x + (x == 0 ? 9 : x * 20) / scale,
            y: held.y + (y == 0 ? 9 : y * 20) / scale)
          let fit = NotebookQuickShapeSession.adjusted(original, heldAt: held, to: moved, screenScale: scale)
          XCTAssertEqual(fit.frame.width * scale, x == 0 ? 189 : 200, accuracy: 0.0001)
          XCTAssertEqual(fit.frame.height * scale, y == 0 ? 129 : 140, accuracy: 0.0001)
          XCTAssertEqual(fit.frame.x * scale, x < 0 ? 80 : 100, accuracy: 0.0001)
          XCTAssertEqual(fit.frame.y * scale, y < 0 ? 50 : 70, accuracy: 0.0001)
          XCTAssertEqual(fit.shape, shape); XCTAssertEqual(fit.sampleCount, 49)
          XCTAssertEqual(fit.precedingStrokeIDs, original.precedingStrokeIDs)
          XCTAssertEqual(NotebookQuickShapeSession.adjusted(original, heldAt: held, to: held, screenScale: scale), original,
            "Returning to the hold point restores the drawn geometry without drift")
        }
      }
    }
  }

  func testHeldCornersKeepTheOppositeCornerAndDoNotFlipAtMinimumSize() {
    let frame = PageRect(x: 100, y: 70, width: 180, height: 120)
    let original = NotebookQuickShapeFit(frame: frame, sampleCount: 49, shape: .rectangle)
    for (x, y) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
      let held = SpatialPoint(x: x < 0 ? 100 : 280, y: y < 0 ? 70 : 190)
      let fit = NotebookQuickShapeSession.adjusted(original, heldAt: held,
        to: .init(x: held.x + x * 20, y: held.y + y * 30), screenScale: 1)
      XCTAssertEqual(fit.frame.width, 200); XCTAssertEqual(fit.frame.height, 150)
      XCTAssertEqual(fit.frame.x, x < 0 ? 80 : 100)
      XCTAssertEqual(fit.frame.y, y < 0 ? 40 : 70)
      let clamped = NotebookQuickShapeSession.adjusted(original, heldAt: held,
        to: .init(x: held.x - x * 400, y: held.y - y * 400), screenScale: 1)
      XCTAssertEqual(clamped.frame.width, 12); XCTAssertEqual(clamped.frame.height, 12)
      XCTAssertEqual(clamped.frame.x, x < 0 ? 268 : 100)
      XCTAssertEqual(clamped.frame.y, y < 0 ? 178 : 70)
      XCTAssertEqual(NotebookQuickShapeSession.adjusted(original, heldAt: held, to: held, screenScale: 1), original)
    }
  }

  func testHeldArrowMovesTheNearbyTerminalWithoutChangingTheOtherEndOrDirection() throws {
    let connection = NotebookGraphicConnection(
      start: .init(point: .init(x: 10, y: 30), binding: .init(elementID: "tail")),
      end: .init(point: .init(x: 190, y: 30), binding: .init(elementID: "tip")), endArrowhead: .arrow)
    let original = NotebookQuickShapeFit(frame: .init(x: 100, y: 70, width: 200, height: 60),
      sampleCount: 91, connection: connection)
    for terminal in NotebookGraphicConnection.Terminal.allCases {
      let initial = terminal == .start ? connection.start : connection.end
      // A finishing wing need not end exactly at the geometrical arrow tip.
      let held = SpatialPoint(x: 100 + initial.point.x - 8, y: 70 + initial.point.y + 6)
      let fit = NotebookQuickShapeSession.adjusted(original, heldAt: held,
        to: .init(x: held.x - 20, y: held.y + 35), screenScale: 1)
      let adjusted = try XCTUnwrap(fit.connection)
      let endpoint = terminal == .start ? adjusted.start : adjusted.end
      XCTAssertEqual(endpoint.point, .init(x: held.x - 20 - original.frame.x, y: held.y + 35 - original.frame.y))
      XCTAssertNil(endpoint.binding, "The moved terminal is rebound at its new position by the existing resolver")
      XCTAssertEqual(terminal == .start ? adjusted.end : adjusted.start,
        terminal == .start ? connection.end : connection.start)
      XCTAssertEqual(adjusted.endArrowhead, .arrow)
      XCTAssertEqual(fit.frame, original.frame)
    }
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

  func testMultiStrokeArrowSquareAndPlusUseTheExistingPageContact() async throws {
    let cases: [(NotebookGraphic.Shape, [[CGPoint]])] = [
      (.connector, [[.init(x:100,y:180),.init(x:280,y:180)], [.init(x:240,y:150),.init(x:280,y:180),.init(x:240,y:210)]]),
      (.connector, [[.init(x:240,y:150),.init(x:280,y:180)], [.init(x:280,y:180),.init(x:100,y:180)], [.init(x:240,y:210),.init(x:280,y:180)]]),
      (.rectangle, [[.init(x:100,y:100),.init(x:240,y:100),.init(x:240,y:240),.init(x:100,y:240),.init(x:100,y:100)]]),
      (.plus, [[.init(x:100,y:180),.init(x:260,y:180)], [.init(x:180,y:100),.init(x:180,y:260)]])
    ]
    for (expected, strokes) in cases {
      let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
      paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.pen)
      var raw: [PageInkAction] = [], fit: NotebookQuickShapeFit?
      paper.onDrawingMutation = { raw.append($0); fit = paper.completedQuickShape }
      for (index, vertices) in strokes.enumerated() {
        let touch = draw(vertices, on:paper)
        if index == strokes.count-1 { try await Task.sleep(for:.milliseconds(650)) }
        paper.touchesEnded([touch],with:nil)
        paper.finishCurrentAction {} // Ordinary publication fence between contacts.
      }
      let shape = try XCTUnwrap(fit)
      XCTAssertEqual(shape.shape,expected)
      XCTAssertEqual(shape.precedingStrokeIDs,raw.dropLast().map(\.id))
      XCTAssertEqual(shape.sampleCount,raw.last?.samples.count)
      XCTAssertEqual(raw.count,strokes.count)
      if expected == .connector { XCTAssertEqual(shape.connection?.endArrowhead,.arrow) }
    }
  }

  static func measuredShapes(_ name: String) throws -> [[[CGPoint]]] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource:"QuickShapeMeasured",withExtension:"json"))
    let groups = try JSONDecoder().decode([String: [[[[Double]]]]].self,from:Data(contentsOf:url))
    return try XCTUnwrap(groups[name]).map { $0.map { $0.map { CGPoint(x:100+$0[0],y:100+$0[1]) } } }
  }

  func testRealMeasuredFiguresThroughPencilHoldAndLift() async throws {
    var fitTimes: [Double] = []
    let groups: [(String,NotebookGraphic.Shape)] = [("rectangles",.rectangle),("pluses",.plus),
      ("triangles",.triangle),("diamonds",.diamond),("lines",.connector),("arrows",.connector)]
    for (name,expected) in groups {
      for strokes in try Self.measuredShapes(name) {
        let paths = strokes.map { $0.map { SpatialPoint(x:$0.x,y:$0.y) } }
        for _ in 0..<5 {
          let start = ContinuousClock.now
          let fit = NotebookQuickShape.recognize(strokes:paths,screenScale:1)
          let elapsed = start.duration(to:.now).components
          fitTimes.append(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
          XCTAssertEqual(fit?.shape,expected)
        }
        let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
        paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.pen)
        var raw: [PageInkAction] = [], accepted: NotebookQuickShapeFit?
        paper.onDrawingMutation = { raw.append($0); accepted = paper.completedQuickShape }
        for (strokeIndex, points) in strokes.enumerated() {
          let touch = GraphicPencilTouch()
          for (index, point) in points.enumerated() {
            touch.point = point; touch.sampleTime += 1.0/240
            if index == 0 { paper.touchesBegan([touch],with:nil) }
            else { paper.touchesMoved([touch],with:nil) }
          }
          if strokeIndex == strokes.count-1 { try await Task.sleep(for:.milliseconds(650)) }
          paper.touchesEnded([touch],with:nil)
          paper.finishCurrentAction {}
        }
        let fit = try XCTUnwrap(accepted)
        XCTAssertEqual(fit.shape,expected)
        XCTAssertEqual(fit.precedingStrokeIDs,raw.dropLast().map(\.id))
        XCTAssertEqual(raw.map { $0.samples.count },strokes.map(\.count),"Keep all original measurements")
        XCTAssertEqual(fit.sampleCount,strokes.last?.count)
        if expected == .connector {
          let connection = try XCTUnwrap(fit.connection), nib = try XCTUnwrap(strokes.last?.last)
          let distance = [connection.start.point,connection.end.point].map {
            hypot($0.x+fit.frame.x-nib.x,$0.y+fit.frame.y-nib.y)
          }.min()!
          XCTAssertLessThan(distance,0.001,"Recognized endpoint starts under the nib, not at an offset wing")
          XCTAssertEqual(connection.endArrowhead,name == "arrows" ? .arrow : NotebookGraphicConnection.Arrowhead.none)
        }
      }
    }
    fitTimes.sort()
    let timing = "QUICKSHAPE_MEASURED_FIT count=\(fitTimes.count) medianMS=\(fitTimes[fitTimes.count/2]) p95MS=\(fitTimes[Int(Double(fitTimes.count)*0.95)]) maxMS=\(fitTimes.last!)"
    print(timing)
    let evidence = XCTAttachment(string:timing); evidence.name = "measured-shape-fit-time"
    evidence.lifetime = .keepAlways; add(evidence)
  }

  func testPageChangeCancellationAndToolChangeDoNotBorrowPreviousStrokes() async throws {
    for reset in 0...3 {
      let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
      paper.quickShapePageID = UUID()
      var fit: NotebookQuickShapeFit?
      paper.onDrawingMutation = { _ in fit = paper.completedQuickShape }
      let first = draw([.init(x:100,y:180),.init(x:260,y:180)],on:paper)
      if reset == 0 { paper.touchesCancelled([first],with:nil) }
      else { paper.touchesEnded([first],with:nil) }
      if reset == 1 { paper.quickShapePageID = UUID() }
      if reset == 2 { paper.endShapeSequence() }
      if reset == 3 {
        paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.eraser)
        paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.pen)
      }
      let last = draw([.init(x:180,y:100),.init(x:180,y:260)],on:paper)
      try await Task.sleep(for:.milliseconds(650))
      paper.touchesEnded([last],with:nil)
      XCTAssertEqual(fit?.shape,.connector)
      XCTAssertEqual(fit?.precedingStrokeIDs,[])
    }
  }

  func testExpiredSequenceDoesNotAbsorbOldInk() async throws {
    let session = NotebookQuickShapeSession()
    session.remember(UUID(),points:[.init(x:100,y:180),.init(x:260,y:180)])
    try await Task.sleep(for:.seconds(NotebookQuickShapeSession.sequenceSeconds+0.1))
    let vertical = (0...60).map { SpatialPoint(x:180,y:100+Double($0)*160/60) }
    session.begin(at:vertical.last!,screenScale:1) { vertical }
    try await Task.sleep(for:.milliseconds(650))
    let fit = try XCTUnwrap(session.finish())
    XCTAssertEqual(fit.shape,.connector); XCTAssertTrue(fit.precedingStrokeIDs.isEmpty)
  }

  private func draw(_ vertices: [CGPoint], on paper: PaperInputView) -> GraphicPencilTouch {
    let touch = GraphicPencilTouch(); touch.point = vertices[0]
    paper.touchesBegan([touch],with:nil)
    for (a,b) in zip(vertices,vertices.dropFirst()) {
      for index in 1...30 {
        let t = Double(index)/30
        touch.point = .init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t); touch.sampleTime += 0.01
        paper.touchesMoved([touch],with:nil)
      }
    }
    return touch
  }

  func testFigureDragNeedsNoHoldAndSecondFingerCancelsWithoutAWrite() {
    let gate = NotebookInputGate(), recognizer = SceneSelectionRecognizer(), touch = GraphicFingerTouch()
    let view = UIView(); view.addGestureRecognizer(recognizer); recognizer.gate = gate
    var begins = 0, commits = 0, cancelled = 0, taps = 0
    recognizer.onPoint = { _, _ in taps += 1 }
    recognizer.onLift = { _ in .init(begin: { begins += 1 }, change: { _ in },
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
      selection.onLift = { _ in .init(begin: {}, change: { _ in },
        end: { _ in XCTFail("The second finger cancelled the drop") }, cancel: { cancellations += 1 }) }
      let camera = BoardPanView.Coordinator(isEnabled: true, inputGate: gate,
        onBegan: { XCTFail("The object contact cannot also pan") }, onChanged: { _ in },
        onEnded: { _ in }, onCancelled: {})
      camera.install(on: window, inside: anchor)
      XCTAssertFalse(window.gestureRecognizers?.contains { $0 is UITapGestureRecognizer && $0.delegate === camera } == true,
        "Background and object taps have one selection owner; camera cannot clear the editor on the same lift")
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

  func testTextTouchReservesPageContactButOnlyMovementBeginsDrag() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let gate = NotebookInputGate(), selection = SceneSelectionRecognizer(), window = UIWindow(windowScene:scene)
    let anchor = UIView(frame:.init(x:0,y:0,width:600,height:800))
    window.addSubview(anchor); window.addGestureRecognizer(selection)
    selection.coordinateView = anchor; selection.gate = gate
    let curl = UIPanGestureRecognizer(); anchor.addGestureRecognizer(curl)
    var began = false
    selection.onLift = { _ in .init(begin:{ began = true },change:{ _ in },end:{ _ in },cancel:{}) }
    let touch = GraphicFingerTouch()
    selection.touchesBegan([touch],with:UIEvent())
    XCTAssertFalse(gate.permitsPageNavigation,"Paper curl cannot steal the object contact's first movement")
    XCTAssertFalse(began)
    try await Task.sleep(for:.milliseconds(250))
    XCTAssertFalse(began,"Holding does not select or lift text")
    touch.point.x += 10; selection.touchesMoved([touch],with:UIEvent())
    XCTAssertTrue(began); XCTAssertTrue(selection.canPrevent(curl))
    selection.touchesEnded([touch],with:UIEvent()); gate.endFingerContacts([ObjectIdentifier(touch)])
    XCTAssertTrue(gate.permitsPageNavigation)
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
