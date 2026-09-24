import NotebookCore
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Stored content, the native page owner and current window must agree across
/// a sequence, not merely inside one fresh gesture fixture. All stores are isolated.
@MainActor final class NotebookPageLifecycleUXTests: XCTestCase {
  private typealias Scene = NotebookInteractionUXTests.Scene
  private typealias Probe = NotebookSelectionComposition.Probe

  func testPresentedLandingAdmitsTheNextReverseBeforeSwiftUIRepublishesInput() async throws {
    let model = try await modelWithPages(2, distinctLeaves: true)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: notebook, expectedRoot: model.notebookPageRoot(notebook)!), 0)
    let scene = try await mount(model), owner = try pageOwner(scene.window)
    try await shown("immediate-reverse-source", window: scene.window, probes: leafProbes(0, scene.pageToWindow))
    _ = try await turnTarget(owner, forward: true)
    let native = owner.sheetController
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let present = curl.onFramePresented, admit = native.willTurn
    let pan = NotebookCurlPan()
    var attempted = false, admitted: Bool?
    native.willTurn = { target in let accepted = admit(target); admitted = accepted; return accepted }
    defer { native.willTurn = admit }
    curl.onFramePresented = { image, progress, timestamp in
      present?(image, progress, timestamp)
      guard timestamp > 0, progress == 1, owner.displayedIndex == 1, !attempted else { return }
      attempted = true
      // The actual landing has released the native owner. A deferred SwiftUI
      // notification of that same landing must not continue denying its input.
      pan.phase = .began; pan.offset.x = 20
      XCTAssertTrue(native.gestureRecognizerShouldBegin(pan))
      native.perform(NSSelectorFromString("panned:"), with: pan)
      pan.phase = .changed; pan.offset.x = native.view.bounds.width + 10
      native.perform(NSSelectorFromString("panned:"), with: pan)
      pan.phase = .ended; pan.speed.x = 600
      native.perform(NSSelectorFromString("panned:"), with: pan)
    }
    XCTAssertTrue(model.notebookPageNavigation.send(.step(1), ownerID: notebook,
      source: try XCTUnwrap(model.notebookPageRoot(notebook))))
    let deadline = CACurrentMediaTime() + 2
    while (!attempted || owner.displayedIndex != 0), CACurrentMediaTime() < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(attempted)
    XCTAssertEqual(admitted, true, "The retired curl's deferred SwiftUI state cannot own the next gesture")
    XCTAssertEqual(owner.displayedIndex, 0)
    try await shown("immediate-reverse-landed", window: scene.window, probes: leafProbes(0, scene.pageToWindow))
  }

  func testShowReferenceKeepsTheAcceptedColdPageAcrossCameraSettlement() async throws {
    let model = try await modelWithPages(5, distinctLeaves: true, includesSVG: true)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    let target = try XCTUnwrap(model.activePage?.id), root = try XCTUnwrap(model.notebookPageRoot(notebook))
    await model.prepareNotebookPage(at: 0, in: notebook)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: notebook, expectedRoot: root), 0)
    let scene = try await mount(model), owner = try pageOwner(scene.window)
    try await shown("reference-source", window: scene.window, probes: leafProbes(0, scene.pageToWindow))
    XCTAssertFalse(owner.preparedPageIndices.contains(4), "Use a genuinely unmounted destination")
    model.requestShow(.init(target: .init(kind: .page, id: target), revision: "cold-page-reference"))
    try await shown("reference-after-camera-settlement", window: scene.window,
      probes: leafProbes(4, scene.pageToWindow), budget: NotebookUXObservation.opening, acknowledged: {
        owner.displayedIndex == 4 && model.activePage?.id == target && model.requestedReference == nil
      })
    XCTAssertEqual(model.presence?.notebookPageID, target)
  }

  func testDenseVectorSheetsKeepTheirOwnPixelsThroughImmediateReversals() async throws {
    let model = try await modelWithPages(2), notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    for index in 0..<2 {
      await model.prepareNotebookPage(at: index, in: notebook)
      var page = try XCTUnwrap(model.notebookPage(at: index, in: notebook))
      let vectors: [AgentElement] = (0..<13).map { number in
        let strokes = (0..<40).map { "<path d='M0 \($0 * 3)L160 \(120 - $0 * 3)'/>" }.joined()
        return .init(id: "vector-\(index)-\(number)", kind: .web,
          frame: NotebookNavigationLoadFixture.frame(number, programs: false), source: "",
          html: "<svg xmlns='http://www.w3.org/2000/svg' width='100%' height='100%' viewBox='0 0 170 160'><g stroke='black' stroke-width='.2' fill='none'>\(strokes)</g><rect y='130' width='170' height='30' fill='\(index == 0 ? "#ff3322" : "#2288ff")'/></svg>")
      }
      XCTAssertTrue(vectors.allSatisfy(\.usesNativeSVGRaster))
      let marker = AgentElement(id: "leaf-identity", kind: .graphic,
        frame: .init(x: 100 + Double(index)*100, y: 1080, width: 60, height: 30), source: "", html: "",
        graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1))))
      XCTAssertTrue(page.replaceElements(vectors + [marker], actor: model.actorID))
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: []).dataRepresentation(), actor: model.actorID))
      try model.store.savePage(page)
    }
    await model.reloadExternalChanges()?.value
    _ = model.selectNotebookPage(0, notebookID: notebook, expectedRoot: model.notebookPageRoot(notebook)!)
    let scene = try await mount(model), owner = try pageOwner(scene.window)
    let deadline = ContinuousClock.now + .seconds(10)
    while !owner.preparedPageIndices.isSuperset(of: [0, 1]), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(8)) }
    XCTAssertTrue(owner.preparedPageIndices.isSuperset(of: [0, 1]))
    let source = try XCTUnwrap(model.notebookPageRoot(notebook))
    for target in [1, 0, 1, 0, 1, 0] {
      if target == 1 {
        XCTAssertTrue(model.notebookPageNavigation.send(.step(1), ownerID: notebook, source: source))
      } else {
        // Exercise the interactive action on the full scene, not a second
        // commanded animation. Hardware touch arbitration is checked separately.
        let native = owner.sheetController, pan = NotebookCurlPan()
        let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
        let presented = curl.onFramePresented
        var endpointPresented = false
        curl.onFramePresented = { image, progress, timestamp in
          if progress == 0, timestamp > 0 { endpointPresented = true }
          presented?(image, progress, timestamp)
        }
        pan.phase = .began; pan.offset.x = 20
        XCTAssertTrue(native.gestureRecognizerShouldBegin(pan))
        native.perform(NSSelectorFromString("panned:"), with: pan)
        pan.phase = .changed; pan.offset.x = native.view.bounds.width + 10
        native.perform(NSSelectorFromString("panned:"), with: pan)
        let heldLimit = ContinuousClock.now + .seconds(2)
        while !endpointPresented, ContinuousClock.now < heldLimit { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(endpointPresented)
        pan.phase = .ended
        native.perform(NSSelectorFromString("panned:"), with: pan)
      }
      let limit = ContinuousClock.now + .seconds(2)
      while owner.displayedIndex != target, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(1)) }
      XCTAssertEqual(owner.displayedIndex, target)
      for _ in 0..<4 {
        let pixels = try NotebookUXObservation.Pixels(window: scene.window)
        var probes = [0, 1].map { index in
          (CGPoint(x: 130 + Double(index)*100, y: 1095).applying(scene.pageToWindow),
            index == target ? NotebookUXObservation.Color.blue : .paper)
        }
        for number in 0..<13 {
          let frame = NotebookNavigationLoadFixture.frame(number, programs: false)
          probes.append((CGPoint(x: frame.x + 80, y: frame.y + 145).applying(scene.pageToWindow),
            target == 0 ? .red : .blue))
        }
        XCTAssertTrue(try pixels.matches(probes), "A reverse landing reintroduced the other leaf's graphic or SVG pixels")
        try await Task.sleep(for: .milliseconds(4))
      }
    }
  }

  func testPageMountsTheFullSizeErasureMaskOnlyWhileItHasLiveCoverage() async throws {
    let model = try await modelWithPages(1)
    var page = try XCTUnwrap(model.activePage)
    XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: []).dataRepresentation(), actor: model.actorID))
    try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let resources = SceneRenderResources.shared, reservedBefore = resources.reservedBytes
    let scene = try await mount(model)
    try await shown("idle-page-before-eraser", window: scene.window,
      probes: [probe("shape", [(230, 330)], .red, scene.pageToWindow)], budget: NotebookUXObservation.opening)
    XCTAssertLessThanOrEqual(resources.reservedBytes, reservedBefore,
      "An ink-free idle sheet must not reserve a full-screen white Metal erasure mask")
    model.selectEraserWidth(28)
    try await scene.readyPencil(self)
    let began = ContinuousClock.now
    scene.beginPencil(.init(x: 230, y: 270)); scene.movePencil(.init(x: 230, y: 410))
    // SwiftUI's native mask is not necessarily in UIView.subviews. Its actual
    // held-contact pixels, not an incomplete hierarchy walk, prove activation.
    try await shown("live-eraser-first-contact-pixels", window: scene.window,
      probes: [probe("live-cut", [(230, 330)], .paper, scene.pageToWindow),
        probe("untouched-shape", [(350, 330)], .red, scene.pageToWindow),
        probe("untouched-neighbor", [(590, 590)], .blue, scene.pageToWindow)], since: began)
    scene.endPencil()
    try await shown("lazy-mask-preserves-erased-pixels", window: scene.window,
      probes: [probe("erased-shape", [(230, 330)], .paper, scene.pageToWindow)])
    let retired = ContinuousClock.now
    let oneScreenImage = Int(scene.window.bounds.width * scene.window.bounds.height
      * pow(scene.window.screen.scale, 2) * 4)
    try await assertUX("finished-eraser-releases-mask", since: retired,
      budget: NotebookUXObservation.selection, window: scene.window) {
      // The small permanent cutout remains; the two full-screen temporary
      // drawables must retire rather than surviving behind it indefinitely.
      resources.reservedBytes - reservedBefore < oneScreenImage
    }
  }

  func testRejectedEraseRestoresTheSameRevisionInsteadOfLeavingFalseDeletedPixels() async throws {
    try await rejectedErase(acceptsLocalTailFirst: false)
  }

  func testRejectedEraseCannotRollBackAnEarlierAcceptedUnpublishedStroke() async throws {
    try await rejectedErase(acceptsLocalTailFirst: true)
  }

  private func rejectedErase(acceptsLocalTailFirst: Bool) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let host = UIViewController(), paper = PaperCanvasContainerView(frame: .init(x: 0, y: 0, width: 600, height: 400))
    window.rootViewController = host; host.view.backgroundColor = .white; host.view.addSubview(paper)
    window.makeKeyAndVisible()
    let actor = UUID(), gate = NotebookInputGate()
    var page = PageDocument(size: .init(width: 600, height: 400), actor: actor)
    XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: [line(y: 200)]).dataRepresentation(), actor: actor))
    let owner = PencilCanvasView.Coordinator(inputGate: gate, reserveAction: { _ in page.drawingStamp.advanced(by: actor) },
      releaseAction: { _, _ in }, acceptAction: { _, _, _, _ in nil })
    owner.attach(to: paper); owner.apply(page.inkSource, pageID: page.id, to: paper)
    defer { owner.detach(from: paper); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await shown("rejection-original-material", window: window,
      probes: [probe("original-ink", [(230, 200), (300, 200), (430, 200)], .black)], budget: NotebookUXObservation.opening)
    if acceptsLocalTailFirst {
      // A locally accepted tail is newer than Coordinator's last externally
      // applied source. Resetting a stamp and replaying that old source would
      // repair the gap but incorrectly delete this successful previous stroke.
      owner.acceptAction = { action, _, stamp, _ in
        guard let change = try? page.prepareInkChange(.append(action), stamp: stamp) else { return nil }
        XCTAssertTrue(page.publishLiveInkChange(change)); return change
      }
      XCTAssertTrue(paper.touchView.onActionWillBegin?() == true)
      owner.commit(line(y: 300), on: paper)
      owner.apply(page.inkSource, pageID: page.id, to: paper)
      try await shown("accepted-local-tail-before-rejection", window: window,
        probes: [probe("accepted-tail", [(230, 300), (300, 300), (430, 300)], .black)])
      owner.acceptAction = { _, _, _, _ in nil }
    }
    XCTAssertTrue(paper.touchView.onActionWillBegin?() == true)
    let cut = PageInkAction(tool: .eraser, samples: [sample(300, 150, width: 28), sample(300, 350, width: 28)])
    let contact = ActiveEraserStroke()
    contact.replaceMeasuredTail(from: 0, with: [150.0, 350.0].map { y in
      PKStrokePoint(location: .init(x: 300, y: y), timeOffset: 0, size: .init(width: 28, height: 28),
        opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
    paper.inkView.displayActiveEraser(contact)
    paper.inkView.commitActiveEraser(cut)
    let start = ContinuousClock.now
    owner.commit(cut, on: paper) // PaperInputView finishes GPU preview before requesting model admission.
    owner.apply(page.inkSource, pageID: page.id, to: paper) // An ordinary same-revision publication is not a rollback.
    let retainedRows = acceptsLocalTailFirst ? [200.0, 300.0] : [200.0]
    try await shown("rejected-erase-is-not-shown-as-saved", window: window,
      probes: retainedRows.map { y in probe("restored-ink-\(y)", [(230, y), (300, y), (430, y)], .black) }, since: start)
    XCTAssertEqual(try page.inkDrawing().actions.count, retainedRows.count, "The rejected action never entered the authoritative source")
  }

  func testFingerCanSelectTheNextObjectImmediatelyAfterErasing() async throws {
    let model = try await modelWithPages(1), pageID = try XCTUnwrap(model.activePage?.id)
    let scene = try await mount(model)
    try await eraseBothMaterials(scene)
    model.selectDrawingTool(.lasso); model.drawingToolSettings.lassoMode = .elements
    try await scene.readyFinger(self)
    let presentedAtContact = model.activePage.map { model.pagePresentations.isPresented($0) } == true
    let start = ContinuousClock.now
    scene.beginFinger(.init(x: 590, y: 590)); scene.endFinger()
    try await assertUX("next-object-after-erase", since: start, budget: NotebookUXObservation.selection,
      window: scene.window) { model.selectionSession.element == .page(pageID: pageID, elementID: "blue") }
    let note = XCTAttachment(string: "selection=\(model.selectionSession.elements); pagePresentedAtContact=\(presentedAtContact); pencilActive=\(model.inputGate.hasActivePencil); fingerState=\(scene.finger.state.rawValue)")
    note.name = "next-object-after-erase-owner"; note.lifetime = .keepAlways; add(note)
    try await shown("next-object-is-still-visible", window: scene.window,
      probes: [probe("unmodified-next-object", [(590, 590)], .blue, scene.pageToWindow)])
  }

  private func eraseBothMaterials(_ scene: Scene) async throws {
    let model = scene.model
    try await shown("source-before-erase-sequence", window: scene.window, probes: [
      probe("shape", [(230, 330)], .red, scene.pageToWindow),
      probe("neighbor", [(590, 590)], .blue, scene.pageToWindow),
      probe("line", [(300, 650)], .black, scene.pageToWindow)], budget: NotebookUXObservation.opening)
    model.selectEraserWidth(28)
    for (x, top, bottom) in [(230.0, 270.0, 410.0), (300.0, 625.0, 675.0)] {
      try await scene.readyPencil(self)
      scene.beginPencil(.init(x: x, y: top)); scene.movePencil(.init(x: x, y: bottom)); scene.endPencil()
    }
  }

  func testDeletedGraphicAndErasedMaterialStayAbsentAfterStaleSaveAndColdReopen() async throws {
    let model = try await modelWithPages(1), pageID = try XCTUnwrap(model.activePage?.id)
    let before = try model.store.loadPage(pageID), scene = try await mount(model)
    try await eraseBothMaterials(scene)
    let deleted = EditableElementReference.page(pageID: pageID, elementID: "blue")
    // Selection routing has its own sequence test above. Use the real model
    // command here so its failure cannot masquerade as data resurrection.
    model.selectElement(deleted)
    XCTAssertEqual(model.selectionSession.element, deleted)
    let deletionStart = ContinuousClock.now
    model.deleteElement(deleted) // The actual toolbar command, not a replacement PageDocument.
    let probes = retainedMaterial(scene.pageToWindow)
    try await shown("delete-and-erase-before-save", window: scene.window, probes: probes, since: deletionStart)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    // g=0 keeps the authored body for undo; absence of contribution is not
    // absence of a database row. The independent pixel oracle must agree.
    XCTAssertNotEqual(try model.store.loadPage(pageID).element(id: "blue")?.graphic?.visible, true)

    // An older whole-page producer adds unrelated ink after the addressed
    // deletion. Its old element list must not recreate the deleted shape.
    var stale = before
    let oldInk = try stale.inkDrawing()
    XCTAssertTrue(stale.replaceDrawing(try PageInkDrawing(actions: oldInk.actions + [line(y: 950)]).dataRepresentation(), actor: model.actorID))
    try model.store.savePage(stale)
    let durable = try model.store.loadPage(pageID)
    XCTAssertNotEqual(durable.element(id: "blue")?.graphic?.visible, true, "A stale whole-page save cannot defeat the deletion's causal record")
    XCTAssertEqual(try durable.inkDrawing().actions.filter { $0.isActive && $0.tool == .eraser }.count, 2)
    await model.reloadExternalChanges()?.value
    let final = probes + [probe("new-independent-ink", [(300, 950)], .black, scene.pageToWindow)]
    try await shown("stale-save-does-not-resurrect", window: scene.window, probes: final)

    let root = model.store.root
    scene.window.isHidden = true; scene.window.rootViewController = nil
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    let reopened = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(reopened, removing: root)
    await reopened.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertEqual(reopened.activePage?.id, pageID)
    preparePagePresence(reopened)
    let opening = ContinuousClock.now, cold = try openWindow(reopened)
    // Keep the original coordinates: a displaced new page cannot move the oracle.
    try await shown("cold-reopen-preserves-absence", window: cold, probes: final, since: opening,
      budget: NotebookUXObservation.opening,
      witness: probes[1], absence: [probes[0], probes[2], probes[3]])
    XCTAssertNotEqual(reopened.activePage?.element(id: "blue")?.graphic?.visible, true)
  }

  func testNativePageTurnsShowTheStoredLeafAfterEvictionReverseAndCancellation() async throws {
    let model = try await modelWithPages(5, distinctLeaves: true)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    var ids: [UUID] = []
    for index in 0..<5 {
      let window = try model.store.readNotebookPageWindow(itemID: notebook, pages: [.index(index)])
      ids.append(try XCTUnwrap(window.pages.first?.document.id))
    }
    await model.prepareNotebookPage(at: 0, in: notebook)
    _ = model.selectNotebookPage(0, notebookID: notebook, expectedRoot: model.notebookPageRoot(notebook)!)
    let scene = try await mount(model)
    for (step, index) in [1, 2, 3, 4, 5, 4, 3, 2, 1, 0].enumerated() {
      let owner = try pageOwner(scene.window)
      let forward = index > owner.displayedIndex
      if index == 5 {
        let root = model.notebookPageRoot(notebook)
        try await turn(owner, forward: true, completes: false)
        try await shown("cancel-trailing-page-keeps-last-stored-leaf", window: scene.window,
          probes: leafProbes(4, scene.pageToWindow))
        XCTAssertEqual(model.notebookPageCount(notebook), 5)
        XCTAssertEqual(model.notebookPageRoot(notebook), root)
        XCTAssertEqual(model.presence?.notebookPageID, ids[4])
      }
      let start = ContinuousClock.now
      try await turn(owner, forward: forward, completes: true)
      try await shown("leaf-\(step)-\(index)", window: scene.window,
        probes: leafProbes(index, scene.pageToWindow), since: start, budget: NotebookUXObservation.opening,
        acknowledged: { model.activePage.map { model.pagePresentations.isPresented($0) } == true })
      if index == 5 {
        let created = try XCTUnwrap(model.presence?.notebookPageID)
        XCTAssertFalse(ids.contains(created)); ids.append(created)
        XCTAssertEqual(model.notebookPageCount(notebook), 6)
        try await assertUX("new-leaf-hands-off-input", since: .now, window: scene.window) {
          self.hasEnabledPaper(scene.window)
        }
        let current = try Scene(model: model, window: scene.window)
        model.selectPenWidth(12); try await current.readyPencil(self)
        let pencilStart = ContinuousClock.now
        current.beginPencil(.init(x: 180, y: 950)); current.movePencil(.init(x: 480, y: 950)); current.endPencil()
        // Window capture occupies MainActor while Metal's actual presented
        // callback is queued. Require pixels AND that exact source receipt in
        // the same original 100 ms window, not synchronously after one capture.
        try await shown("new-leaf-accepts-its-own-ink", window: scene.window,
          probes: [probe("new-leaf-line", [(300, 950)], .black, scene.pageToWindow)], since: pencilStart,
          acknowledged: { model.activePage.map { model.pagePresentations.isPresented($0) } == true })
      } else {
        try await shown("new-leaf-ink-does-not-leak-\(step)", window: scene.window,
          probes: [probe("other-leaf-stays-empty", [(300, 950)], .paper, scene.pageToWindow)])
      }
      XCTAssertEqual(model.presence?.notebookPageID, ids[index])
      XCTAssertEqual(model.workspace?.selectedPageID, ids[index])
      XCTAssertEqual(owner.displayedIndex, index)
      XCTAssertEqual(owner.sheetController.page?.view.accessibilityIdentifier, "page-turn-page-\(index)")
      XCTAssertTrue(model.activePage.map { model.pagePresentations.isPresented($0) } == true,
        "leaf=\(index) must acknowledge its own installed source")
      XCTAssertLessThanOrEqual(owner.cachedPageIdentities.count, 4)
    }
    let owner = try pageOwner(scene.window)
    try await turn(owner, forward: true, completes: false)
    try await shown("cancel-keeps-leaf-zero", window: scene.window, probes: leafProbes(0, scene.pageToWindow))
    XCTAssertEqual(model.presence?.notebookPageID, ids[0])
    try await turn(owner, forward: true, completes: true)
    try await shown("turn-after-cancel-shows-leaf-one", window: scene.window, probes: leafProbes(1, scene.pageToWindow))
    XCTAssertEqual(model.presence?.notebookPageID, ids[1])
    for index in 2...5 {
      try await turn(try pageOwner(scene.window), forward: true, completes: true)
      try await shown("return-to-created-leaf-\(index)", window: scene.window,
        probes: leafProbes(index, scene.pageToWindow) + [probe("created-line", [(300, 950)], index == 5 ? .black : .paper, scene.pageToWindow)],
        budget: NotebookUXObservation.opening)
      XCTAssertEqual(model.presence?.notebookPageID, ids[index])
    }
    XCTAssertEqual(model.notebookPageCount(notebook), 6, "Only the explicit trailing turn creates a leaf; reverse/cancel must not")
  }

  func testSVGNeighbourPreparesDuringTheCurrentCurlNotAfterFingerLift() async throws {
    let model = try await modelWithPages(4, distinctLeaves:true, includesSVG:true)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    await model.prepareNotebookPage(at:0,in:notebook)
    _ = model.selectNotebookPage(0,notebookID:notebook,expectedRoot:model.notebookPageRoot(notebook)!)
    let scene = try await mount(model), owner = try pageOwner(scene.window)
    let (previous,target) = try await turnTarget(owner,forward:true)
    scene.beginFinger(.init(x:730,y:1050))
    scene.moveFinger(.init(x:710,y:1050),expectsManipulation:false)
    defer { scene.endFinger() }
    XCTAssertTrue(model.inputGate.isActive)
    owner.sheetController(owner.sheetController,willTurnTo: target)
    let start = ContinuousClock.now
    while !owner.preparedPageIndices.contains(2), ContinuousClock.now-start < .seconds(2) {
      try await Task.sleep(for:.milliseconds(16))
    }
    XCTAssertTrue(owner.preparedPageIndices.contains(2),
      "The page beyond the landing must render its SVG while this curl owns the finger, not wait for input settlement")
    let elapsed = ContinuousClock.now-start
    let evidence = XCTAttachment(string:"nextSVGReady=\(owner.preparedPageIndices.contains(2)); elapsed=\(elapsed); fingerActive=\(model.inputGate.isActive)")
    evidence.name="svg-prewarm-during-curl";evidence.lifetime = .keepAlways;add(evidence)
    owner.sheetController.show(target,direction:.forward,animated:false)
    owner.sheetController(owner.sheetController,didTurnFrom: previous, completed:true)
    scene.endFinger()
    let (_,next) = try await turnTarget(owner,forward:true)
    XCTAssertEqual(next.view.accessibilityIdentifier,"page-turn-page-2")
    XCTAssertLessThanOrEqual(owner.cachedPageIdentities.count,4)
  }

  func testPeerRemovedLeafCannotCommitAnOldCurlIntoItsReplacementSlot() async throws {
    let model = try await modelWithPages(1, distinctLeaves: true)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID), first = try XCTUnwrap(model.activePage?.id)
    let peer = UUID()
    let removed = try appendPeerLeaf(index: 1, notebook: notebook, store: model.store, actor: peer)
    let survivor = try appendPeerLeaf(index: 2, notebook: notebook, store: model.store, actor: peer)
    await model.reloadExternalChanges()?.value
    let oldRoot = try XCTUnwrap(model.notebookPageRoot(notebook)), scene = try await mount(model)
    let owner = try pageOwner(scene.window), native = owner.sheetController
    try await shown("peer-directory-original-leaf", window: scene.window,
      probes: leafProbes(0, scene.pageToWindow), budget: NotebookUXObservation.opening)
    let (previous, target) = try await turnTarget(owner, forward: true)
    owner.sheetController(native, willTurnTo: target)
    let animation = Task { @MainActor in
      await withCheckedContinuation { continuation in
        native.show(target, direction: .forward, animated: true) {
          continuation.resume(returning: $0)
        }
      }
    }
    await Task.yield()
    // The peer removes its still-unadopted leaf while UIKit owns the old curl.
    // The surviving leaf moves into that numeric slot, but is a different UUID.
    _ = try model.store.undoCollaborationAction(removed.receipt.id, actor: peer)
    await model.reloadExternalChanges()?.value
    try await assertUX("new-root-retires-old-page-shell", since: .now,
      budget: NotebookUXObservation.opening, window: scene.window) {
      model.notebookPageRoot(notebook) != oldRoot
        && owner.cachedPageIdentities[0] != ObjectIdentifier(previous)
    }
    _ = await animation.value // Cancellation is legal when the source was retired.
    owner.sheetController(native, didTurnFrom: previous, completed: true)
    owner.sheetController(native, didTurnFrom: previous, completed: false)
    try await shown("old-curl-cannot-land-on-a-different-uuid", window: scene.window,
      probes: leafProbes(0, scene.pageToWindow), budget: NotebookUXObservation.opening)
    XCTAssertEqual(model.presence?.notebookPageID, first)
    XCTAssertEqual(model.workspace?.selectedPageID, first)
    XCTAssertEqual(owner.displayedIndex, 0)
    XCTAssertNil(try model.store.resolveNotebookPage(removed.pageID, in: notebook))
    XCTAssertEqual(try model.store.resolveNotebookPage(survivor.pageID, in: notebook)?.index, 1)
    XCTAssertNil(model.selectNotebookPage(1, notebookID: notebook, expectedRoot: oldRoot))

    let current = try Scene(model: model, window: scene.window)
    model.selectPenWidth(12); try await current.readyPencil(self)
    let pencilStart = ContinuousClock.now
    current.beginPencil(.init(x: 180, y: 950)); current.movePencil(.init(x: 480, y: 950)); current.endPencil()
    try await shown("cancelled-root-gives-next-pencil-to-current-uuid", window: scene.window,
      probes: [probe("new-current-line", [(300, 950)], .black, scene.pageToWindow)], since: pencilStart,
      acknowledged: { model.activePage.map { model.pagePresentations.isPresented($0) } == true })
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.loadPage(first).inkDrawing().activeActions.count, 2)
    XCTAssertEqual(try model.store.loadPage(survivor.pageID).inkDrawing().activeActions.count, 1)
    try await turn(owner, forward: true, completes: true)
    let survivorProbes = leafProbes(2, scene.pageToWindow)
      + [probe("neighbor-keeps-its-own-ink", [(300, 950)], .paper, scene.pageToWindow)]
    try await shown("new-turn-resolves-surviving-uuid", window: scene.window,
      probes: survivorProbes, budget: NotebookUXObservation.opening,
      acknowledged: { model.activePage.map { model.pagePresentations.isPresented($0) } == true })
    XCTAssertEqual(model.presence?.notebookPageID, survivor.pageID)
    XCTAssertEqual(model.notebookPageIndex(survivor.pageID, in: notebook), 1)
    XCTAssertEqual(owner.displayedIndex, 1)
    XCTAssertTrue(model.activePage.map { model.pagePresentations.isPresented($0) } == true)
    XCTAssertLessThanOrEqual(owner.cachedPageIdentities.count, 4)

    let root = model.store.root
    scene.window.isHidden = true; scene.window.rootViewController = nil
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    let reopened = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(reopened, removing: root)
    await reopened.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertEqual(reopened.activePage?.id, survivor.pageID)
    XCTAssertEqual(reopened.notebookPageIndex(survivor.pageID, in: notebook), 1)
    preparePagePresence(reopened)
    let opening = ContinuousClock.now, cold = try openWindow(reopened)
    try await shown("cold-open-keeps-surviving-leaf-not-old-slot", window: cold,
      probes: survivorProbes, since: opening, budget: NotebookUXObservation.opening,
      acknowledged: { reopened.activePage.map { reopened.pagePresentations.isPresented($0) } == true })
  }

  private func appendPeerLeaf(index: Int, notebook: UUID, store: NotebookStore, actor: UUID) throws
    -> (receipt: CollaborationReceipt, pageID: UUID) {
    let extent = try XCTUnwrap(store.readItemLifecycle(notebook)), pageID = UUID()
    var read = NotebookCommand(command: .read); read.readSnapshots = true
    read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": .encode(notebook)]).decode(NotebookReadQuery.self)]
    let rows = try NotebookCommandDispatcher(store: store).handle(read).decode([JSONValue].self)
    let basis = try XCTUnwrap(rows.first?["basis"]?.decode(NotebookReadBasis.self))
    let page = CollaborationTarget(kind: .page, id: pageID)
    var operations = [CollaborationOperation(kind: .appendPage, target: extent.target, id: pageID.uuidString)]
    for element in leafElements(index, distinct: true) {
      operations.append(.init(kind: .insertElement, target: page, id: element.id, values: [
        "kind": .string("graphic"), "source": .string(""), "frame": try .encode(element.frame),
        "graphic": try .encode(element.graphic)]))
    }
    let y = 700.0 + Double(index) * 35
    operations.append(.init(kind: .appendInkStroke, target: page, id: UUID().uuidString,
      values: ["width": .number(16), "points": .array([180.0, 480.0].map {
        .object(["x": .number($0), "y": .number(y)])
      })]))
    let expected = try store.expectations(base: basis, operations: operations)
    return (try store.applyCollaborationAction(.init(summary: "Peer leaf \(index)", expected: expected,
      operations: operations), actor: actor), pageID)
  }

  func testLassoFragmentKeepsBothSidesThroughSecondMoveResizeAndColdReopen() async throws {
    let model = try await modelWithPages(1), scene = try await mount(model)
    model.selectDrawingTool(.lasso); model.drawingToolSettings.lassoMode = .region
    try await scene.readyPencil(self)
    let selectedAt = ContinuousClock.now
    scene.contour([.init(x: 180, y: 280), .init(x: 280, y: 280), .init(x: 280, y: 400),
      .init(x: 180, y: 400), .init(x: 180, y: 280)])
    let cut = CGRect(x: 180, y: 280, width: 100, height: 120)
    // Before any drag, the shown handles must surround this exact partial
    // material, not its whole parent or a previous selection.
    try await shown("lasso-selection-before-any-drag", window: scene.window,
      probes: NotebookSelectionComposition.controls(cut, transform: scene.pageToWindow, visible: true)
        + [probe("enclosed-body", [(230, 340)], .red, scene.pageToWindow),
           probe("outside-body", [(350, 340)], .red, scene.pageToWindow)], since: selectedAt)
    let region = try XCTUnwrap(model.selectionSession.region)
    XCTAssertEqual(model.selectionSession.editingElement, region.reference)
    func visibleMenus(_ view: UIView) -> Int {
      guard !view.isHidden, view.alpha > 0.01 else { return 0 }
      return (view.accessibilityIdentifier == "notebook-context-menu" ? 1 : 0)
        + view.subviews.reduce(0) { $0 + visibleMenus($1) }
    }
    XCTAssertEqual(visibleMenus(scene.window), 1, "One visible action owner before moving the selected region")
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 250, y: 340)); scene.moveFinger(.init(x: 250, y: 560))
    var dropped = ContinuousClock.now; scene.endFinger()
    var fragment = CGRect(x: 180, y: 500, width: 100, height: 120)
    try await shown("fragment-first-drop", window: scene.window, probes: fragmentProbes(fragment, scene.pageToWindow), since: dropped)
    try await scene.readyFinger(self)
    scene.beginFinger(.init(x: 250, y: 560)); scene.moveFinger(.init(x: 350, y: 560))
    dropped = .now; scene.endFinger()
    fragment = fragment.offsetBy(dx: 100, dy: 0)
    try await shown("fragment-second-drop", window: scene.window, probes: fragmentProbes(fragment, scene.pageToWindow), since: dropped)
    let selected = try XCTUnwrap(model.selectionSession.editingElement ?? model.selectionSession.elements.first)
    let resize = try XCTUnwrap(model.beginElementManipulation(selected, kind: .resize(.bottomTrailing)))
    let resized = ContinuousClock.now
    XCTAssertTrue(model.finishElementManipulation(resize, translation: .init(x: 40, y: 20)))
    fragment.size = .init(width: 140, height: 140)
    model.clearSelection()
    let final = fragmentProbes(fragment, scene.pageToWindow)
    try await shown("fragment-resize-whole-body", window: scene.window, probes: final, since: resized)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    try await shown("fragment-after-publication", window: scene.window, probes: final)
    let root = model.store.root, pageID = model.activePage?.id
    scene.window.isHidden = true; scene.window.rootViewController = nil
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    let reopened = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(reopened, removing: root)
    await reopened.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertEqual(reopened.activePage?.id, pageID)
    preparePagePresence(reopened)
    let opening = ContinuousClock.now, cold = try openWindow(reopened)
    try await shown("fragment-cold-reopen", window: cold, probes: final, since: opening,
      budget: NotebookUXObservation.opening, witness: final[2], absence: [final[1]])
  }

  func testMaskedMaterialKeepsBothHalvesWhenItsAncestorMovesIntoView() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let frame = PageRect(x: 0, y: 0, width: 300, height: 300)
    let mask = NotebookGraphicMask().capturing([.init(target: .init(elementID: "masked", frame: frame),
      samples: [sample(220, 80, width: 24), sample(220, 220, width: 24)])], transform: nil)
    let graphic = NotebookGraphic(shape: .rectangle, style: .init(fill: .init(red: 1, green: 0.2, blue: 0.1)), mask: mask)
    func content(_ x: CGFloat) -> some View {
      ZStack(alignment: .topLeading) {
        Color.white
        NotebookGraphicView(graphic: graphic).frame(width: 300, height: 300).offset(x: x, y: 120)
      }.ignoresSafeArea()
    }
    let host = UIHostingController(rootView: content(-120))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await shown("mask-starts-partly-offscreen", window: window, probes: [
      probe("visible-body", [(30, 160), (150, 370)], .red),
      probe("visible-hole", [(100, 270)], .paper)], budget: NotebookUXObservation.opening)
    let start = ContinuousClock.now
    host.rootView = content(100) // No manual projection.refresh or forced layout in the oracle.
    let points = stride(from: 120.0, through: 380.0, by: 40).flatMap { x in
      stride(from: 140.0, through: 400.0, by: 40).compactMap { y in
        abs(x - 320) < 20 && (190...350).contains(y) ? nil : (x, y)
      }
    }
    let moved = [
      probe("both-halves", points, .red), probe("moved-hole", [(320, 240), (320, 300)], .paper),
      probe("old-body-absent", [(30, 180), (70, 370)], .paper)]
    try await shown("mask-move-reveals-complete-body", window: window, probes: moved, since: start)
    try await Task.sleep(for: .milliseconds(250))
    try await shown("mask-move-is-not-just-one-late-frame", window: window, probes: moved)
    // Diagnostic control, NOT the proposed fix: a new host receives the exact
    // same immutable source and pose. This distinguishes retained projection
    // from damage to the authored mask. Production must not remount to move.
    window.rootViewController = UIHostingController(rootView: content(100))
    try await shown("same-source-fresh-pose-control", window: window, probes: moved,
      budget: NotebookUXObservation.opening)
  }

  private func modelWithPages(_ count: Int, distinctLeaves: Bool = false, includesSVG:Bool = false) async throws -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-lifecycle-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    for index in 0..<count {
      if index > 0 { XCTAssertEqual(model.selectNotebookPage(index, notebookID: notebook, expectedRoot: model.notebookPageRoot(notebook)!), index) }
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      var page = try XCTUnwrap(model.activePage)
      XCTAssertTrue(page.replaceElements(leafElements(index, distinct: distinctLeaves) + (includesSVG ? [svgLeaf(index)] : []), actor: model.actorID))
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: [line(y: distinctLeaves ? 700 + Double(index) * 35 : 650)]).dataRepresentation(), actor: model.actorID))
      try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
    }
    return model
  }

  private func svgLeaf(_ index:Int) -> AgentElement {
    // Static exported handwriting/diagrams, not a live JS program or a blank page.
    let paths=(0..<120).map { row in
      let segments=(0..<24).map { column in "L\(column*24) \(row*3+(column%3))" }.joined(separator:" ")
      return "<path d='M0 \(row*3) \(segments)'/>"
    }.joined()
    return .init(id:"svg-\(index)",kind:.web,frame:.init(x:70,y:75,width:650,height:150),source:"Sheet \(index)",
      html:"<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 650 370'><g fill='none' stroke='#235688' stroke-width='1'>\(paths)</g><text x='10' y='365'>\(index)</text></svg>",
      css:"html,body,svg{margin:0;width:100%;height:100%;display:block}")
  }

  private func leafElements(_ index: Int, distinct: Bool) -> [AgentElement] {
    let red = distinct ? PageRect(x: 160 + Double(index) * 70, y: 260, width: 50, height: 100)
      : PageRect(x: 160, y: 260, width: 320, height: 180)
    let blue = distinct ? PageRect(x: 160 + Double(index) * 70, y: 520, width: 50, height: 100)
      : PageRect(x: 540, y: 540, width: 100, height: 100)
    return [.init(id: "red", kind: .graphic, frame: red, source: "", html: "",
      graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 1, green: 0.2, blue: 0.1)))),
      .init(id: "blue", kind: .graphic, frame: blue, source: "", html: "",
      graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1))))]
  }

  private func mount(_ model: NotebookAppModel) async throws -> Scene {
    preparePagePresence(model)
    let window = try await mountNotebookScene(model)
    return try Scene(model: model, window: window)
  }
  private func preparePagePresence(_ model: NotebookAppModel) {
    guard let workspace = model.workspace else { return XCTFail("Missing notebook") }
    let viewport = SpatialPoint(x: 834, y: 1194)
    let center = model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID) ?? .zero
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: center, scale: WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: workspace.selectedItemID, openProgress: 1,
      selectedItemID: workspace.selectedItemID, notebookPageID: workspace.selectedPageID), settled: true)
  }
  private func openWindow(_ model: NotebookAppModel) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    window.rootViewController = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.makeKeyAndVisible()
    addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    return window
  }

  private func sample(_ x: Double, _ y: Double, width: Double = 16) -> SpatialInkSample {
    .init(point: .init(x: x, y: y), timeOffset: 0, width: width, opacity: 1, force: 1, azimuth: 0, altitude: 1)
  }
  private func line(y: Double) -> PageInkAction { .init(tool: .pen, samples: [sample(180, y), sample(480, y)]) }
  private func probe(_ name: String, _ points: [(Double, Double)], _ color: NotebookUXObservation.Color,
    _ transform: CGAffineTransform = .identity) -> Probe {
    .init(name: name, points: points.map { CGPoint(x: $0.0, y: $0.1).applying(transform) }, color: color)
  }
  private func retainedMaterial(_ t: CGAffineTransform) -> [Probe] {
    [probe("erased-shape-hole", [(230, 300), (230, 350), (230, 395)], .paper, t),
     probe("remaining-both-sides", [(190, 300), (190, 400), (300, 300), (450, 400)], .red, t),
     probe("deleted-whole-shape", [(560, 560), (620, 560), (560, 620), (620, 620)], .paper, t),
     probe("erased-ink-gap", [(300, 650)], .paper, t),
     probe("retained-ink-sides", [(200, 650), (450, 650)], .black, t)]
  }
  private func leafProbes(_ index: Int, _ t: CGAffineTransform) -> [Probe] {
    var result: [Probe] = []
    for slot in 0..<5 {
      let x = 185.0 + Double(slot) * 70.0, y = 700.0 + Double(slot) * 35.0
      result.append(probe("leaf-\(slot)-graphic-red", [(x, 310.0)], slot == index ? .red : .paper, t))
      result.append(probe("leaf-\(slot)-graphic-blue", [(x, 570.0)], slot == index ? .blue : .paper, t))
      result.append(probe("leaf-\(slot)-ink", [(300.0, y)], slot == index ? .black : .paper, t))
    }
    return result
  }
  private func fragmentProbes(_ r: CGRect, _ t: CGAffineTransform) -> [Probe] {
    let body = [0.15, 0.5, 0.85].flatMap { x in [0.15, 0.5, 0.85].map { y in
      (Double(r.minX + r.width * x), Double(r.minY + r.height * y))
    } }
    return [probe("complete-fragment", body, .red, t),
      probe("source-hole", [(195, 300), (250, 300), (195, 380), (250, 380)], .paper, t),
      probe("source-not-cut-away", [(350, 300), (350, 420), (460, 350)], .red, t),
      probe("untouched-neighbor", [(560, 560), (620, 620)], .blue, t),
      probe("untouched-ink", [(200, 650), (450, 650)], .black, t)]
  }

  private func shown(_ name: String, window: UIWindow, probes: [Probe],
    since start: ContinuousClock.Instant = .now, budget: Duration = NotebookUXObservation.correctnessTimeout,
    witness: Probe? = nil, absence: [Probe] = [], acknowledged: () -> Bool = { true }) async throws {
    try await Task.sleep(for: .milliseconds(16))
    var failures: [String] = [], last: UIImage?, resurrections: [String] = []
    var captures:[Duration]=[]
    let result = try await assertUX(name, since: start, budget: budget, window: window) {
      // When this case also requires the OS presentation receipt, let that
      // callback run before the expensive window read. Repeated captures while
      // awaiting it block MainActor and manufacture delay. The original clock
      // still includes the gesture, receipt wait and final pixel observation.
      guard acknowledged() else { return false }
      let captureStart=ContinuousClock.now
      let image = try NotebookUXObservation.Pixels(window: window).image
      captures.append(captureStart.duration(to:.now))
      let frame = try NotebookSelectionComposition.Frame(image)
      last = image; failures = frame.failures(probes)
      if let witness, frame.failures([witness]).isEmpty, !absence.isEmpty {
        let returned = frame.failures(absence)
        if !returned.isEmpty {
          if resurrections.isEmpty {
            let picture = XCTAttachment(image: image); picture.name = name + "-returned-material"
            picture.lifetime = .keepAlways; add(picture)
          }
          resurrections += returned
        }
      }
      return failures.isEmpty
    }
    XCTAssertTrue(resurrections.isEmpty, "Previously erased/deleted material appeared during opening: \(resurrections)")
    let note = XCTAttachment(string: "\(name): \(failures); elapsed including capture=\(result.milliseconds) ms; captures=\(captures)")
    note.name = name + "-composition"; note.lifetime = .keepAlways; add(note)
    if let last { let picture = XCTAttachment(image: last); picture.name = name; picture.lifetime = .keepAlways; add(picture) }
  }

  private func pageOwner(_ window: UIWindow) throws -> IPadPageTurnController {
    func descendants(_ controller: UIViewController) -> [UIViewController] { [controller] + controller.children.flatMap(descendants) }
    return try XCTUnwrap(window.rootViewController.flatMap { descendants($0).compactMap { $0 as? IPadPageTurnController }.first })
  }
  private func hasEnabledPaper(_ view: UIView) -> Bool {
    if let paper = view as? PaperInputView, paper.isUserInteractionEnabled { return true }
    return view.subviews.contains { hasEnabledPaper($0) }
  }
  /// Uses real mounted PageSurface readiness and UIKit animation. The native
  /// delegate's landing is driven here; this is not a hardware finger swipe.
  private func turn(_ owner: IPadPageTurnController, forward: Bool, completes: Bool) async throws {
    let native = owner.sheetController, (previous, target) = try await turnTarget(owner, forward: forward)
    owner.sheetController(native, willTurnTo: target)
    let finished = await withCheckedContinuation { continuation in
      native.show(completes ? target : previous, direction: forward ? .forward : .reverse,
        animated: completes) { continuation.resume(returning: $0) }
    }
    XCTAssertTrue(finished)
    owner.sheetController(native, didTurnFrom: previous, completed: completes)
  }

  private func turnTarget(_ owner: IPadPageTurnController, forward: Bool) async throws -> (UIViewController, UIViewController) {
    let native = owner.sheetController, previous = try XCTUnwrap(native.page)
    let deadline = ContinuousClock.now + NotebookUXObservation.opening
    var next: UIViewController?
    repeat {
      next = forward ? owner.sheetController(native, after: previous)
        : owner.sheetController(native, before: previous)
      if next == nil { try await Task.sleep(for: .milliseconds(16)) }
    } while next == nil && ContinuousClock.now < deadline
    let target = try XCTUnwrap(next, "The real next sheet did not become ready; a fake ready(true) would hide this failure")
    return (previous, target)
  }
}
