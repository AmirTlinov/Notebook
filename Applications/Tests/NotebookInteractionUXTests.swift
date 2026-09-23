import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// Real mounted scene + installed input recognizers + fixed window pixel probes.
/// No materialization prewarm, no save barrier between ordinary gestures, and no
/// model-coordinate-only oracle. Synthetic contacts are not a hardware Pencil test.
@MainActor
final class NotebookInteractionUXTests: XCTestCase {
  func testColdAndWarmBoardEntryShowDestinationMaterialWithinBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("board-opening-ux-\(UUID())")
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    var workspace = try store.loadIndex(), hierarchy = try store.loadBoard(items: workspace.items)
    let child = try XCTUnwrap(workspace.createBoard(title: "UX destination", actor: actor)).id
    XCTAssertTrue(hierarchy.createBoard(child, in: workspace.rootBoardID, near: .zero, actor: actor))
    _ = workspace.selectItem(child, actor: actor)
    XCTAssertEqual(workspace.selectedItemID, child)
    let element = SpatialElement(id: "ux-board-material", surface: .board(child), kind: .graphic,
      frame: .init(x: -300, y: -300, width: 600, height: 600), worldOrigin: .zero, source: "",
      graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 1, green: 0.2, blue: 0.1))),
      stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(element, in: child, expected: nil, actor: actor))
    try store.saveBoardWorkspaceBundle(index: workspace, board: hierarchy, boardID: child)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(), viewport: .init(x: 834, y: 1194)), settled: true)
    let window = try await mountNotebookScene(model)
    _ = try XCTUnwrap(model.workspace?.item(id: child), "The portal must be in the mounted scene before testing entry")
    _ = try XCTUnwrap(model.boardHierarchy?.board(child), "The mounted portal must admit its board")
    let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    for pass in 0..<2 {
      let start = ContinuousClock.now
      XCTAssertTrue(model.enterBoard(child))
      try await assertUX(pass == 0 ? "board-cold-entry" : "board-warm-entry", since: start,
        budget: NotebookUXObservation.opening, window: window) {
        guard model.presence?.boardID == child, let cohort = model.compositionTiles.published,
          cohort.isPaintInstalled, cohort.plan.rootBoardID == child,
          cohort.plan.allowsLive(.element(element.id), in: .board(child)) else { return false }
        return try NotebookUXObservation.Pixels(window: window).matches([(center, .red)])
      }
      let leaving = ContinuousClock.now
      XCTAssertTrue(model.leaveBoard())
      try await assertUX("board-return-\(pass)", since: leaving, budget: NotebookUXObservation.opening, window: window) {
        model.presence?.boardID == workspace.rootBoardID && model.compositionTiles.published?.isPaintInstalled == true
          && model.compositionTiles.published?.plan.rootBoardID == workspace.rootBoardID
      }
    }
  }

  func testPenAndEraserShowTheCurrentContactAndNeverRestoreDeletedMaterial() async throws {
    let scene = try await fixture()
    let model = scene.model
    model.selectPenColor(.black); model.selectPenWidth(12)
    try await scene.readyPencil(self)
    scene.beginPencil(.init(x: 150, y: 800))
    for x in stride(from: 190, through: 430, by: 40) {
      let start = ContinuousClock.now
      scene.movePencil(.init(x: x, y: 800))
      try await shown("pen-contact-\(x)", scene, since: start, [(CGPoint(x: x - 10, y: 800), .black)])
    }
    var start = ContinuousClock.now
    scene.endPencil()
    try await remainsShown("pen-lift", scene, since: start, [(.init(x: 300, y: 800), .black)])

    // The next contact does not wait for SQLite, publication or a confirmation.
    model.selectEraserWidth(28)
    try await scene.readyPencil(self)
    scene.beginPencil(.init(x: 300, y: 770))
    start = .now; scene.movePencil(.init(x: 300, y: 815))
    let inkProbes: [(CGPoint, NotebookUXObservation.Color)] = [
      (.init(x: 300, y: 800), .paper), (.init(x: 210, y: 800), .black)]
    try await shown("erase-ink-contact", scene, since: start, inkProbes)
    start = .now; scene.endPencil()
    try await remainsShown("erase-ink-lift", scene, since: start, inkProbes)

    try await scene.readyPencil(self)
    scene.beginPencil(.init(x: 230, y: 270))
    start = .now; scene.movePencil(.init(x: 230, y: 390))
    let shapeProbes: [(CGPoint, NotebookUXObservation.Color)] = [
      (.init(x: 230, y: 330), .paper), (.init(x: 350, y: 330), .red)]
    try await shown("erase-shape-contact", scene, since: start, shapeProbes + inkProbes)
    start = .now; scene.endPencil()
    try await remainsShown("erase-shape-lift", scene, since: start, shapeProbes + inkProbes)

    model.selectPenWidth(12)
    try await scene.readyPencil(self)
    start = .now
    scene.beginPencil(.init(x: 160, y: 900)); scene.movePencil(.init(x: 300, y: 900)); scene.endPencil()
    let finalProbes = shapeProbes + inkProbes + [(CGPoint(x: 220, y: 900), NotebookUXObservation.Color.black)]
    try await shown("draw-immediately-after-erase", scene, since: start, finalProbes)
    try await survivesPublication("erasures-survive-publication", scene, finalProbes)
  }

  func testColdLassoCutMovesPixelsBeforeLiftAndAllowsTheNextCutWithoutConfirmation() async throws {
    let scene = try await fixture(erasedShape: true, tool: .lasso)
    let model = scene.model
    model.selectDrawingTool(.lasso); model.drawingToolSettings.lassoMode = .region
    try await scene.readyPencil(self)
    let start = ContinuousClock.now
    scene.contour([.init(x: 180, y: 280), .init(x: 280, y: 280), .init(x: 280, y: 400),
      .init(x: 180, y: 400), .init(x: 180, y: 280)])
    // Do not await materialization: immediately move what the contour enclosed.
    try await assertUX("lasso-contour-admitted", since: start, budget: NotebookUXObservation.selection,
      window: scene.window) { model.selectionSession.region != nil }
    _ = try XCTUnwrap(model.selectionSession.region, "Do not misreport a missing contour as dozens of drag failures")
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 230, y: 330))
    for dy in [120.0, 220.0] {
      let motion = ContinuousClock.now
      scene.moveFinger(.init(x: 230, y: 330 + dy))
      try await shown("cold-cut-visible-during-drag-\(Int(dy))", scene, since: motion, [
        (.init(x: 230, y: 330), .paper), (.init(x: 230, y: 330 + dy), .red),
        (.init(x: 350, y: 330), .red), (.init(x: 400, y: 330), .paper)])
    }
    var released = ContinuousClock.now; scene.endFinger()
    let cutProbes: [(CGPoint, NotebookUXObservation.Color)] = [
      (.init(x: 230, y: 330), .paper), (.init(x: 230, y: 550), .red),
      (.init(x: 350, y: 330), .red), (.init(x: 400, y: 330), .paper)]
    try await remainsShown("cut-lift-keeps-shown-result", scene, since: released, cutProbes)

    // Clicking away must apply, not cancel, and must not require a checkmark.
    try await scene.readyFinger(self)
    released = .now; scene.beginFinger(.init(x: 700, y: 850)); scene.endFinger()
    XCTAssertNil(model.selectionSession.region, "A blank point is not a new lasso contour")
    try await Task.sleep(for: .milliseconds(16))
    try await assertUX("tap-away-releases-selection", since: released, window: scene.window) {
      guard model.selectionSession.region == nil && model.selectionSession.elements.isEmpty else { return false }
      return try scene.pixels(cutProbes)
    }
    try await scene.readyPencil(self)
    scene.contour([.init(x: 220, y: 625), .init(x: 320, y: 625), .init(x: 320, y: 675),
      .init(x: 220, y: 675), .init(x: 220, y: 625)])
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 270, y: 650))
    released = .now; scene.moveFinger(.init(x: 270, y: 750))
    let bothCuts = cutProbes + [(CGPoint(x: 270, y: 650), NotebookUXObservation.Color.paper),
      (.init(x: 270, y: 750), .black), (.init(x: 430, y: 650), .black)]
    try await shown("next-raw-ink-cut-during-drag", scene, since: released, bothCuts)
    released = .now; scene.endFinger()
    try await remainsShown("second-cut-lift", scene, since: released, bothCuts)
    model.selectPenWidth(12)
    try await scene.readyPencil(self)
    released = .now
    scene.beginPencil(.init(x: 160, y: 900)); scene.movePencil(.init(x: 300, y: 900)); scene.endPencil()
    let finalProbes = bothCuts + [(CGPoint(x: 220, y: 900), NotebookUXObservation.Color.black)]
    try await shown("draw-after-cuts-without-confirmation", scene, since: released, finalProbes)
    try await survivesPublication("cuts-survive-publication", scene, finalProbes)
    // The next interaction after source retirement must not rebuild cold masks.
    model.selectDrawingTool(.lasso)
    model.drawingToolSettings.lassoMode = .elements
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 230, y: 550))
    released = .now; scene.moveFinger(.init(x: 330, y: 550))
    try await shown("post-publication-next-drag", scene, since: released, [
      (.init(x: 230, y: 550), .paper), (.init(x: 330, y: 550), .red), (.init(x: 350, y: 330), .red)])
    scene.endFinger()
  }

  func testTapSelectionAndWholeObjectDragMoveOnlyTheShownObject() async throws {
    let scene = try await fixture(tool: .lasso)
    scene.model.selectDrawingTool(.lasso); scene.model.drawingToolSettings.lassoMode = .elements
    try await scene.readyFinger(self)
    var start = ContinuousClock.now
    scene.beginFinger(.init(x: 590, y: 590)); scene.endFinger()
    try await assertUX("tap-selects-shown-object", since: start, budget: NotebookUXObservation.selection,
      window: scene.window) { scene.model.selectionSession.elements.contains { $0.elementID == "ux-blue" } }
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 590, y: 590))
    start = .now; scene.moveFinger(.init(x: 590, y: 790))
    let page = try XCTUnwrap(scene.model.activePage)
    let moved = try XCTUnwrap(scene.model.graphicGraph(page: page).resolve("ux-blue").layout)
    XCTAssertEqual(moved.frame.y, 740, accuracy: 0.5,
      "Diagnostic only: correct model geometry still does not prove the following pixel checks")
    let probes: [(CGPoint, NotebookUXObservation.Color)] = [
      (.init(x: 590, y: 590), .paper), (.init(x: 590, y: 790), .blue), (.init(x: 350, y: 330), .red)]
    try await shown("whole-object-visible-during-drag", scene, since: start, probes)
    start = .now; scene.endFinger()
    try await remainsShown("whole-object-keeps-drop", scene, since: start, probes)
  }

  private func shown(_ name: String, _ scene: Scene, since start: ContinuousClock.Instant,
    _ probes: [(CGPoint, NotebookUXObservation.Color)]) async throws {
    // Return one display opportunity before readback. A snapshot issued inside
    // the input transaction can itself block the update it is meant to observe.
    // The clock still starts before input: this wait and capture both count.
    try await Task.sleep(for: .milliseconds(16))
    try await assertUX(name, since: start, window: scene.window) { try scene.pixels(probes) }
  }

  private func remainsShown(_ name: String, _ scene: Scene, since start: ContinuousClock.Instant,
    _ probes: [(CGPoint, NotebookUXObservation.Color)]) async throws {
    // Once correct material was observed during motion, lift/publication is not
    // entitled to another grace period in which erased or old pixels may return.
    let firstCaptureMatches = try scene.pixels(probes)
    try await assertUX(name, since: start, window: scene.window) { firstCaptureMatches }
  }

  private func survivesPublication(_ name: String, _ scene: Scene,
    _ probes: [(CGPoint, NotebookUXObservation.Color)]) async throws {
    var completed = false
    let publication = Task { @MainActor in
      let saved = await scene.model.finishPendingPersistence()
      await scene.model.reloadExternalChanges()?.value
      completed = true
      return saved
    }
    let start = ContinuousClock.now
    var samples = 0
    repeat {
      let snapshot = try NotebookUXObservation.Pixels(window: scene.window)
      let correct = try snapshot.matches(probes.map { ($0.0.applying(scene.pageToWindow), $0.1) })
      XCTAssertTrue(correct, "\(name): stale/erased pixels returned in sample \(samples)")
      if !correct {
        let shot = XCTAttachment(image: snapshot.image); shot.name = name + "-continuity-failure"
        shot.lifetime = .keepAlways; add(shot)
        break
      }
      samples += 1
      // This is a continuity monitor, not an input replay. Always return the
      // actor/run loop to the writer and display; trying to catch up a screenshot
      // schedule can itself starve publication and manufacture a 2-second stall.
      try await Task.sleep(for: .milliseconds(16))
    } while (!completed || start.duration(to: .now) < .milliseconds(200))
      && start.duration(to: .now) < NotebookUXObservation.coldOpening
    if samples > 0 {
      XCTAssertTrue(completed, "Publication exceeded the 2-second regression ceiling")
      XCTAssertGreaterThan(samples, 1, "A final still image is not continuity evidence")
    }
    let saved = await publication.value; XCTAssertTrue(saved)
    try await remainsShown(name + "-final", scene, since: .now, probes)
  }

  func testInstalledQuickShapeBindingReadsTheVisibleAcceptedMoveBeforeStorage() async throws {
    let scene=try await fixture(),model=scene.model
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    let page=try XCTUnwrap(model.activePage),reference=EditableElementReference.page(pageID:page.id,elementID:"ux-red")
    let lock=try NotebookSQLWriteBlocker(store:model.store)
    defer { try? lock.release() }
    let moved=PageRect(x:510,y:260,width:300,height:180)
    let start=ContinuousClock.now
    XCTAssertTrue(model.performElementOperation(.updateElement,reference:reference,
      values:["frame":try .encode(moved)],summary:"Accepted move before binding"))
    let fit=NotebookQuickShapeFit(frame:.init(x:60,y:350,width:450,height:1),sampleCount:2,
      connection:.init(start:.init(point:.zero),end:.init(point:.init(x:450,y:0))))
    XCTAssertNil(fit.binding(in:page.graphicGraph(),surface:.page(page.id),tolerance:18).connection?.end.binding,
      "The saved page is deliberately too old to own the next binding")
    XCTAssertEqual(scene.paper.resolveQuickShape(fit,1).connection?.end.binding?.elementID,"ux-red")
    try await assertUX("accepted-move-before-quickshape",since:start,window:scene.window) {
      try scene.pixels([(.init(x:600,y:330),.red),(.init(x:230,y:330),.paper),
        (.init(x:590,y:590),.blue),(.init(x:430,y:650),.black)])
    }
    XCTAssertEqual(scene.paper.resolveQuickShape(fit,1).connection?.end.binding?.elementID,"ux-red")
    try lock.release()
    let finished=await model.finishPendingPersistence();XCTAssertTrue(finished)
    XCTAssertEqual(try model.store.loadPage(page.id).element(id:"ux-red")?.frame,moved)
  }

  func fixture(erasedShape: Bool = false, tool: DrawingTool = .pen) async throws -> Scene {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("interaction-ux-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    var page = try XCTUnwrap(model.activePage)
    let body = PageRect(x: 160, y: 260, width: 320, height: 180)
    var graphic = NotebookGraphic(shape: .rectangle, style: .init(strokeWidth: 3,
      fill: .init(red: 1, green: 0.2, blue: 0.1)))
    if erasedShape {
      let measurements = InkMeasurements((0..<512).map { i in
        .init(point: .init(x: 400 + Double(i % 7) * 0.1, y: 280 + Double(i % 128)),
          timeOffset: Double(i) / 240, width: 12, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })
      graphic.mask = NotebookGraphicMask().capturing([
        .init(target: .init(elementID: "ux-red", frame: body), measurements: measurements)], transform: nil)
    }
    XCTAssertTrue(page.replaceElements([
      .init(id: "ux-red", kind: .graphic, frame: body, source: "", html: "", graphic: graphic),
      .init(id: "ux-blue", kind: .graphic, frame: .init(x: 540, y: 540, width: 100, height: 100),
        source: "", html: "", graphic: .init(shape: .ellipse,
          style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1))))], actor: model.actorID))
    let line = PageInkAction(tool: .pen, samples: [180.0, 480.0].map { x in
      .init(point: .init(x: x, y: 650), timeOffset: 0, width: 16, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    })
    XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: [line]).dataRepresentation(), actor: model.actorID))
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let workspace = try XCTUnwrap(model.workspace), viewport = SpatialPoint(x: 834, y: 1194)
    let center = model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID) ?? .zero
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: center, scale: WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: workspace.selectedItemID, openProgress: 1), settled: true)
    model.selectPenColor(.black); model.selectPenWidth(12)
    model.selectDrawingTool(tool)
    let window = try await mountNotebookScene(model)
    let scene = try Scene(model: model, window: window)
    try await assertUX("fixture-visible", since: .now, budget: NotebookUXObservation.opening, window: window) {
      try scene.pixels([(.init(x: 230, y: 330), .red), (.init(x: 590, y: 590), .blue),
        (.init(x: 430, y: 650), .black), (.init(x: 230, y: 550), .paper)])
    }
    return scene
  }

  @MainActor final class Scene {
    let model: NotebookAppModel
    let window: UIWindow
    let paper: PaperInputView
    let pencil: UIGestureRecognizer
    let finger: SceneSelectionRecognizer
    let observer: NotebookContactObserver
    var contact: UXTouch
    var direct: UXTouch
    let event = UIEvent()
    let pageToWindow: CGAffineTransform

    init(model: NotebookAppModel, window: UIWindow) throws {
      self.model = model; self.window = window
      func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
      paper = try XCTUnwrap(descendants(window).compactMap { $0 as? PaperInputView }.first { $0.isUserInteractionEnabled })
      pencil = try XCTUnwrap(window.gestureRecognizers?.first { $0.name == "NotebookPaperPencil" })
      finger = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SceneSelectionRecognizer }.first)
      observer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
      contact = UXTouch(window: window, kind: .pencil); direct = UXTouch(window: window, kind: .direct)
      let origin = paper.convert(CGPoint.zero, to: window), x = paper.convert(.init(x: 1, y: 0), to: window), y = paper.convert(.init(x: 0, y: 1), to: window)
      // Freeze this before any edit. A bug shifting the paper must not also shift
      // the oracle, turning a wrong displayed result into a passing test.
      pageToWindow = .init(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
    }
    func pixels(_ probes: [(CGPoint, NotebookUXObservation.Color)]) throws -> Bool {
      try NotebookUXObservation.Pixels(window: window).matches(probes.map { ($0.0.applying(pageToWindow), $0.1) })
    }
    func readyPencil(_ test: XCTestCase) async throws {
      // Only UIKit's contact reset may gate the next event. Do not wait for a
      // SwiftUI tool snapshot: the input owner must read the current intent.
      try await test.assertUX("next-pencil-contact-ready", since: .now, window: window) {
        self.pencil.state == .possible
      }
    }
    func readyFinger(_ test: XCTestCase) async throws {
      try await test.assertUX("next-finger-contact-ready", since: .now, window: window) {
        self.finger.state == .possible && self.observer.state == .possible
      }
    }
    func beginPencil(_ p: CGPoint) {
      contact = UXTouch(window: window, kind: .pencil)
      contact.point = p.applying(pageToWindow)
      contact.sourceView = window.hitTest(contact.point, with: event)
      pencil.touchesBegan([contact], with: event)
      XCTAssertTrue(model.inputGate.hasActivePencil, "The installed Pencil owner must admit this contact")
    }
    func movePencil(_ p: CGPoint, timestamp: TimeInterval? = nil) {
      contact.touchPhase = .moved
      contact.point = p.applying(pageToWindow); contact.sampleTime = timestamp ?? (contact.sampleTime + 0.02)
      pencil.touchesMoved([contact], with: event)
    }
    func endPencil() { contact.touchPhase = .ended; pencil.touchesEnded([contact], with: event) }
    func contour(_ points: [CGPoint]) {
      beginPencil(points[0]); for p in points.dropFirst() { movePencil(p) }; endPencil()
    }
    func beginFinger(_ p: CGPoint) {
      direct = UXTouch(window: window, kind: .direct)
      direct.point = p.applying(pageToWindow)
      direct.sourceView = window.hitTest(direct.point, with: event)
      let e = UXDirectEvent(touch: direct)
      observer.touchesBegan([direct], with: e); finger.touchesBegan([direct], with: e)
    }
    func moveFinger(_ p: CGPoint, expectsManipulation: Bool = true) {
      direct.touchPhase = .moved
      direct.point = p.applying(pageToWindow); direct.sampleTime += 0.02
      let e = UXDirectEvent(touch: direct)
      observer.touchesMoved([direct], with: e); finger.touchesMoved([direct], with: e)
      if expectsManipulation {
        XCTAssertNotNil(model.selectionSession.manipulation,
          "The installed body owner must admit the drag: recognizer=\(finger.state.rawValue), Pencil=\(model.inputGate.hasActivePencil), interactive=\(model.selectionSession.isInteractive)")
      }
    }
    func endFinger() {
      direct.touchPhase = .ended
      let e = UXDirectEvent(touch: direct)
      finger.touchesEnded([direct], with: e); observer.touchesEnded([direct], with: e)
    }
  }
}

@MainActor final class UXTouch: UITouch {
  let sourceWindow: UIWindow
  let kind: UITouch.TouchType
  var sourceView: UIView?
  var point = CGPoint.zero
  var sampleTime = ProcessInfo.processInfo.systemUptime
  var touchPhase: UITouch.Phase = .began
  init(window: UIWindow, kind: UITouch.TouchType) { sourceWindow = window; self.kind = kind; super.init() }
  override var view: UIView? { sourceView }
  override var window: UIWindow? { sourceWindow }
  override var type: UITouch.TouchType { kind }
  override var phase: UITouch.Phase { touchPhase }
  override var tapCount: Int { 1 }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

@MainActor private final class UXDirectEvent: UIEvent {
  let touch: UITouch
  init(touch: UITouch) { self.touch = touch; super.init() }
  override var allTouches: Set<UITouch>? { [touch] }
}
