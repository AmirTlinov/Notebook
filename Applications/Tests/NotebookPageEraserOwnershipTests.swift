import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

extension NotebookInteractionUXTests {
  func testPageLiveEraserHasOnePaintOwnerThroughRetractionCancelAndAcceptedUndoRedo() async throws {
    let scene = try await fixture(tool: .eraser), model = scene.model
    model.selectEraserWidth(28)
    let page = try XCTUnwrap(model.activePage)
    let initialActions = try page.inkDrawing().actions.map(\.id)
    let materialIDs = pageMaterialIDs(in: scene.window)
    XCTAssertTrue(pageLiveMasks(in: scene.window).isEmpty)
    try await scene.readyPencil(self)

    let first = ContinuousClock.now
    scene.beginPencil(.init(x: 230, y: 330))
    try await assertUX("one-native-page-mask-at-first-hit", since: first, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).count == 1
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && (try scene.pixels([(.init(x: 230, y: 330), .paper), (.init(x: 350, y: 330), .red)]))
    }
    XCTAssertFalse(model.elementErasures(on: .page(page.id)).isEmpty,
      "Interaction still knows the active contact; only duplicate painting is removed")
    XCTAssertTrue(model.pagePresentationErasures(page).isEmpty)

    // The actual input sampler replaces a corrected final sample with the same
    // timestamp. Retraction must revoke the mask, not leave its first prefix.
    let retracted = ContinuousClock.now
    scene.movePencil(.init(x: 700, y: 330), timestamp: scene.contact.sampleTime)
    try await assertUX("corrected-contact-retracts-page-mask", since: retracted, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && (try scene.pixels([(.init(x: 230, y: 330), .red)]))
    }
    XCTAssertTrue(model.workingElementErasures.isEmpty)

    scene.movePencil(.init(x: 230, y: 330))
    try await assertUX("same-contact-reenters-page-mask", since: .now, window: scene.window) {
      self.pageLiveMasks(in: scene.window).count == 1
        && self.pageMaterialIDs(in: scene.window) == materialIDs
    }
    let cancelled = ContinuousClock.now
    scene.contact.touchPhase = .cancelled
    scene.pencil.touchesCancelled([scene.contact], with: scene.event)
    // UIKit interruption keeps already measured ink, just like the production
    // spatial recognizer. It is not the user's Undo command.
    let interrupted = try XCTUnwrap(model.activePage).inkDrawing().actions.filter { !initialActions.contains($0.id) }
    XCTAssertEqual(interrupted.count, 1)
    XCTAssertEqual(interrupted.first?.tool, .eraser)
    XCTAssertEqual(interrupted.first?.isActive, true)
    XCTAssertEqual(interrupted.first?.samples.count, 2,
      "The corrected first point at x=700 and the new point at x=230 form one measured segment")
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertTrue(model.workingElementErasures.isEmpty)
    try await assertUX("cancel-accepts-measured-cut-once", since: cancelled, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window).count == materialIDs.count + 1
        && (try scene.pixels([(.init(x: 230, y: 330), .paper), (.init(x: 350, y: 330), .paper),
          (.init(x: 350, y: 400), .red)]))
    }
    try await scene.readyPencil(self)
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.count, initialActions.count + 1,
      "UIKit reset after cancellation must not accept the same contact twice")
    model.undoLastSurfaceAction()
    try await assertUX("undo-restores-interrupted-page-cut", since: .now, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && (try scene.pixels([(.init(x: 230, y: 330), .red), (.init(x: 350, y: 330), .red)]))
    }
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.filter(\.isActive).map(\.id), initialActions)

    try await scene.readyPencil(self)
    scene.beginPencil(.init(x: 230, y: 280)); scene.movePencil(.init(x: 230, y: 400))
    scene.endPencil()
    try await assertUX("accepted-cut-hands-off-to-one-durable-mask", since: .now, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window).count == materialIDs.count + 1
        && (try scene.pixels([(.init(x: 230, y: 330), .paper), (.init(x: 350, y: 330), .red)]))
    }
    XCTAssertTrue(model.workingElementErasures.isEmpty)
    XCTAssertEqual(model.pagePresentationErasures(page)["ux-red"]?.count, 1)
    XCTAssertEqual(model.elementErasures(on: .page(page.id))["ux-red"]?.count, 1)

    model.undoLastSurfaceAction()
    try await assertUX("accepted-undo-revokes-both-mask-stages", since: .now, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && (try scene.pixels([(.init(x: 230, y: 330), .red)]))
    }
    model.redoLastSurfaceAction()
    try await assertUX("accepted-redo-presents-the-same-cut", since: .now, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window).count == materialIDs.count + 1
        && (try scene.pixels([(.init(x: 230, y: 330), .paper), (.init(x: 350, y: 330), .red)]))
    }
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPage(page.id).inkDrawing().elementErasures["ux-red"]?.count, 1)
  }

  func testPageLiveEraserPreservesAnExistingDurableMaskHostAndItsPixels() async throws {
    let scene = try await fixture(erasedShape: true, tool: .eraser)
    scene.model.selectEraserWidth(28)
    let materialIDs = pageMaterialIDs(in: scene.window)
    XCTAssertFalse(materialIDs.isEmpty, "The authored cut already owns durable mask material")
    try await scene.readyPencil(self)
    let began = ContinuousClock.now
    scene.beginPencil(.init(x: 230, y: 330))
    try await assertUX("warm-mask-keeps-identity-during-new-contact", since: began, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).count == 1
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && (try scene.pixels([(.init(x: 230, y: 330), .paper), (.init(x: 400, y: 330), .paper),
          (.init(x: 350, y: 330), .red)]))
    }
    let cancelled = ContinuousClock.now
    scene.contact.touchPhase = .cancelled
    scene.pencil.touchesCancelled([scene.contact], with: scene.event)
    try await assertUX("cancel-accepts-cut-alongside-existing-durable-mask", since: cancelled, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && (try scene.pixels([(.init(x: 230, y: 330), .paper), (.init(x: 400, y: 330), .paper)]))
    }
    scene.model.undoLastSurfaceAction()
    try await assertUX("undo-keeps-only-the-original-durable-cut", since: .now, window: scene.window) {
      try self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && (try scene.pixels([(.init(x: 230, y: 330), .red), (.init(x: 400, y: 330), .paper)]))
    }
  }

  func testPageWholeProgramEraseUnmountsBeforeLiftAndCancelledInputCanBeUndone() async throws {
    let scene = try await fixture(tool: .eraser), model = scene.model
    model.selectEraserWidth(28)
    var page = try XCTUnwrap(model.activePage)
    let program = AgentElement(id: "erase-page-program", kind: .web,
      frame: .init(x: 600, y: 200, width: 160, height: 100), source: "Whole erase lifetime",
      html: "<div style='width:100%;height:100%;background:#1a80ff'></div>",
      javaScript: "notebook.ready(Promise.resolve());")
    XCTAssertTrue(page.replaceElements(page.elements + [program], actor: model.actorID))
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    func programs() -> [WKWebView] { pageMaskViews(in: scene.window).compactMap { $0 as? WKWebView } }
    try await assertUX("whole-page-program-is-mounted", since: .now,
      budget: NotebookUXObservation.opening, window: scene.window) {
      try programs().count == 1 && model.activePage.map(model.pagePresentations.isPresented) == true
        && scene.pixels([(.init(x: 730, y: 270), .blue)])
    }
    let materialIDs = pageMaterialIDs(in: scene.window)
    let initialActions = try model.activePage?.inkDrawing().actions.map(\.id)
    try await scene.readyPencil(self)
    let hit = ContinuousClock.now
    scene.beginPencil(.init(x: 620, y: 220))
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertEqual(model.pagePresentationErasures(page)[program.id]?.first?.target.wholeElement, true)
    try await assertUX("whole-page-program-retires-before-lift", since: hit, window: scene.window) {
      try programs().isEmpty && self.pageMaterialIDs(in: scene.window) == materialIDs
        && scene.pixels([(.init(x: 730, y: 270), .paper)])
    }
    XCTAssertTrue(model.inputGate.hasActivePencil, "The whole body disappeared before acceptance, not because Pencil lifted")
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.map(\.id), initialActions)
    scene.contact.touchPhase = .cancelled
    scene.pencil.touchesCancelled([scene.contact], with: scene.event)
    try await assertUX("cancel-accepts-whole-page-program-erasure", since: .now, window: scene.window) {
      try programs().isEmpty && self.pageLiveMasks(in: scene.window).isEmpty
        && model.activePage.map(model.pagePresentations.isPresented) == true
        && scene.pixels([(.init(x: 730, y: 270), .paper)])
    }
    XCTAssertTrue(model.workingElementErasures.isEmpty)
    XCTAssertFalse(model.inputGate.hasActivePencil)
    let interrupted = try XCTUnwrap(model.activePage).inkDrawing().actions.filter { $0.tool == .eraser }
    XCTAssertEqual(interrupted.count, 1)
    XCTAssertEqual(interrupted.first?.isActive, true)
    try await scene.readyPencil(self)
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.filter { $0.tool == .eraser }.count, 1)
    model.undoLastSurfaceAction()
    try await assertUX("undo-restores-the-interrupted-whole-page-program", since: .now,
      budget: NotebookUXObservation.opening, window: scene.window) {
      try programs().count == 1 && self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && model.activePage.map(model.pagePresentations.isPresented) == true
        && scene.pixels([(.init(x: 730, y: 270), .blue)])
    }
    XCTAssertTrue(model.workingElementErasures.isEmpty)
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.filter(\.isActive).map(\.id), initialActions)

    try await scene.readyPencil(self)
    scene.beginPencil(.init(x: 620, y: 220)); scene.endPencil()
    try await assertUX("accepted-whole-program-erasure-is-ready-without-retired-webkit", since: .now, window: scene.window) {
      try programs().isEmpty && self.pageLiveMasks(in: scene.window).isEmpty
        && self.pageMaterialIDs(in: scene.window) == materialIDs
        && model.activePage.map(model.pagePresentations.isPresented) == true
        && scene.pixels([(.init(x: 730, y: 270), .paper)])
    }
    model.undoLastSurfaceAction()
    try await assertUX("whole-program-undo-requires-restored-source-receipt", since: .now,
      budget: NotebookUXObservation.opening, window: scene.window) {
      try programs().count == 1 && self.pageLiveMasks(in: scene.window).isEmpty
        && model.activePage.map(model.pagePresentations.isPresented) == true
        && scene.pixels([(.init(x: 730, y: 270), .blue)])
    }
    model.redoLastSurfaceAction()
    try await assertUX("whole-program-redo-retires-pending-mask", since: .now, window: scene.window) {
      try programs().isEmpty && self.pageLiveMasks(in: scene.window).isEmpty
        && model.activePage.map(model.pagePresentations.isPresented) == true
        && scene.pixels([(.init(x: 730, y: 270), .paper)])
    }
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPage(page.id).inkDrawing().elementErasures[program.id]?.count, 1)
    let root = model.store.root, presence = try XCTUnwrap(model.presence)
    scene.window.isHidden = true; scene.window.rootViewController = nil
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    let cold = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(cold, removing: root)
    await cold.start(pageSize: NotebookAppModel.defaultPageSize)
    cold.updatePresence(presence, settled: true)
    let window = try await mountNotebookScene(cold), reopened = try Scene(model: cold, window: window)
    XCTAssertEqual(reopened.pageToWindow, scene.pageToWindow)
    try await assertUX("cold-whole-program-erasure-needs-no-never-mounted-source", since: .now,
      budget: NotebookUXObservation.opening, window: window) {
      try self.pageMaskViews(in: window).allSatisfy { !($0 is WKWebView) }
        && self.pageLiveMasks(in: window).isEmpty
        && cold.activePage.map(cold.pagePresentations.isPresented) == true
        && reopened.pixels([(.init(x: 730, y: 270), .paper)])
    }
  }

  private func pageMaskViews(in root: UIView) -> [UIView] {
    var seen = Set<ObjectIdentifier>()
    func collect(_ view: UIView) -> [UIView] {
      guard seen.insert(ObjectIdentifier(view)).inserted else { return [] }
      return [view] + view.subviews.flatMap(collect) + (view.mask.map(collect) ?? [])
    }
    return collect(root)
  }
  private func pageMaterialIDs(in window: UIWindow) -> Set<ObjectIdentifier> {
    Set(pageMaskViews(in: window).compactMap { ($0 as? InkMaterialHost).map(ObjectIdentifier.init) })
  }
  private func pageLiveMasks(in window: UIWindow) -> [NotebookLiveElementEraserMaskView] {
    pageMaskViews(in: window).compactMap { $0 as? NotebookLiveElementEraserMaskView }
  }
}

@MainActor
final class NotebookPageEraserProjectionTests: XCTestCase {
  func testWholeErasedProgramReadinessDoesNotInventARetiredSourceReceipt() {
    let program = AgentElement(id: "whole-erased", kind: .web,
      frame: .init(x: 0, y: 0, width: 100, height: 100), source: "program", html: "body")
    var readiness = AgentOverlayReadiness()
    XCTAssertFalse(readiness.isReady(for: [program]))
    XCTAssertTrue(readiness.isReady(for: [program], erasedIDs: [program.id]),
      "A cold erased body never mounts a source that could acknowledge readiness")
    XCTAssertFalse(readiness.isReady(for: [program]), "Undo still requires the real restored body")
    XCTAssertTrue(readiness.record(program, ready: true))
    XCTAssertTrue(readiness.isReady(for: [program]))
    XCTAssertTrue(readiness.record(program, ready: false))
    XCTAssertTrue(readiness.isReady(for: [program], erasedIDs: [program.id]),
      "The retired body's late teardown cannot invalidate the displayed absence")
    XCTAssertFalse(readiness.isReady(for: [program]))
  }

  func testPaintProjectionPreservesWholeHitsAndAcceptedHandoffWithoutActivePartialMasks() throws {
    let actor = UUID(), page = PageDocument(size: .init(width: 400, height: 400), actor: actor)
    let cache = NotebookElementErasureCache(), surface = SurfaceID.page(page.id)
    let target = InkElementTarget(elementID: "shape", frame: .init(x: 0, y: 0, width: 400, height: 400))
    let action = PageInkAction(tool: .eraser, samples: [
      .init(point: .init(x: 100, y: 100), timeOffset: 0, width: 20, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ], elementTargets: [target])
    var contact = NotebookElementErasing(id: action.id, surface: surface, samples: action.samples, targets: [target])
    XCTAssertTrue(cache.pagePresentation(page, working: [action.id: [contact]]).isEmpty)
    XCTAssertEqual(cache.projection(on: surface, base: [:], working: [action.id: [contact]])["shape"]?.count, 1)
    let whole = InkElementTarget(elementID: "program", frame: target.frame, wholeElement: true)
    let mixed = NotebookElementErasing(id: action.id, surface: surface, samples: action.samples, targets: [target, whole])
    let activePaint = cache.pagePresentation(page, working: [action.id: [mixed]])
    XCTAssertNil(activePaint["shape"], "The partial cut has only the page-wide paint owner")
    XCTAssertEqual(activePaint["program"]?.first?.target.wholeElement, true,
      "Whole-element visibility never required a second material mask")
    contact.accepted = true
    XCTAssertEqual(cache.pagePresentation(page, working: [action.id: [contact]])["shape"]?.count, 1,
      "An admitted handoff is never hidden while the permanent source is installed")
    let accepted = try page.prepareInkChange(.append(action), stamp: .init(counter: 1, actor: actor))
    XCTAssertTrue(page.publishLiveInkChange(accepted)); cache.record(accepted)
    XCTAssertEqual(cache.pagePresentation(page, working: [:])["shape"]?.count, 1)
    let undo = try page.prepareInkChange(.setActive([action.id], false), stamp: .init(counter: 2, actor: actor))
    XCTAssertTrue(page.publishLiveInkChange(undo)); cache.record(undo)
    XCTAssertTrue(cache.pagePresentation(page, working: [:]).isEmpty)
    let redo = try page.prepareInkChange(.setActive([action.id], true), stamp: .init(counter: 3, actor: actor))
    XCTAssertTrue(page.publishLiveInkChange(redo)); cache.record(redo)
    XCTAssertEqual(cache.pagePresentation(page, working: [:])["shape"]?.count, 1)
  }
}
