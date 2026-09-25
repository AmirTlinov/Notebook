import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Starts the real root cold. Unlike mountNotebookScene, it does not first wait
/// for a presentation receipt, force layout, or pre-install a model/page host.
/// Contacts enter installed recognizers; they are not hardware Pencil evidence.
@MainActor final class NotebookColdInputUXTests: XCTestCase {
  func testBlankPageReportsItsFirstContactFrameWithoutSnapshotPolling() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-ink-frame-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace), viewport = SpatialPoint(x: 834, y: 1194)
    let center = model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID) ?? .zero
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: center, scale: WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: workspace.selectedItemID, openProgress: 1), settled: true)
    model.selectPenColor(.black); model.selectPenWidth(12)
    let window = try await mountNotebookScene(model)
    let scene = try NotebookInteractionUXTests.Scene(model: model, window: window)
    let canvas = try XCTUnwrap(scene.paper.superview as? PaperCanvasContainerView).inkView
    let requestsBeforeContact = canvas.drawableRequestCount
    var first: InkCanvasView.ContactFrameResolution?, resolvedAt: TimeInterval?
    canvas.onContactFrameResolved = { receipt in
      guard first == nil else { return }
      first = receipt; resolvedAt = CACurrentMediaTime()
    }
    defer { canvas.onContactFrameResolved = nil }
    let start = CACurrentMediaTime()
    scene.beginPencil(.init(x: 180, y: 800))
    let handled = CACurrentMediaTime()
    let expected = try XCTUnwrap(canvas.activeContactFrame)
    // No moves, lift, screenshots, forced layout or synchronous CA flush can
    // manufacture this receipt. The first dot must render while still held.
    let limit = ContinuousClock.now + .seconds(1)
    while first == nil, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(1)) }
    let receipt = try XCTUnwrap(first)
    XCTAssertTrue(receipt.isFirstFrame, "A later warm frame cannot measure the cold first drawable")
    XCTAssertGreaterThan(canvas.drawableRequestCount, requestsBeforeContact)
    XCTAssertEqual(receipt.contact, expected)
    XCTAssertTrue(receipt.completion.isReady)
    XCTAssertTrue(scene.paper.hasActiveAction)
    if let presented = receipt.completion.presentedTime {
      XCTAssertLessThanOrEqual((presented - start) * 1000, NotebookGestureLatency.budgetMS)
    } else {
      #if targetEnvironment(simulator)
      XCTAssertNil(receipt.completion.presentedTime)
      #else
      XCTFail("The physical drawable must supply its OS presentation timestamp")
      #endif
    }
    let note = XCTAttachment(string: "cold first dot: handler=\((handled-start)*1000) ms; resolution callback=\((try XCTUnwrap(resolvedAt)-start)*1000) ms; OS display=\(String(describing: receipt.completion.presentedTime.map { ($0-start)*1000 })); firstFrame=\(receipt.isFirstFrame). Simulator callback is GPU readiness, not displayed latency.")
    note.name = "cold-first-dot-phases"; note.lifetime = .keepAlways; add(note)
    // Pixel correctness is a separate observation after timing, including the
    // same held dot (not a later long line at another location).
    try await assertUX("cold-first-held-dot", since: .now, window: window) {
      try scene.pixels([(.init(x: 180, y: 800), .black), (.init(x: 300, y: 800), .paper)])
    }
    scene.endPencil()
  }

  func testFirstPencilAfterColdOpenWritesAndErasesTheDisplayedPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-input-\(UUID())")
    let store = NotebookStore(root: root), actor = UUID()
    let initial = WorkspaceIndex.initial(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    var page = initial.page
    XCTAssertTrue(page.replaceElements([.init(id: "witness", kind: .graphic,
      frame: .init(x: 540, y: 540, width: 100, height: 100), source: "", html: "",
      graphic: .init(shape: .rectangle, style: .init(fill: .init(red: 0.1, green: 0.5, blue: 1))))], actor: actor))
    try store.saveWorkspaceBundle(index: initial.index, page: page,
      board: store.loadOrCreateBoard(workspace: initial.index, actor: actor))
    let board = try store.loadBoard(items: initial.index.items)
    let center = try XCTUnwrap(board.focusedCenter(of: initial.index.selectedItemID, in: initial.index.rootBoardID))
    try store.savePresence(.init(boardID: initial.index.rootBoardID, mode: .page,
      camera: .init(center: center, scale: 1), viewport: .init(x: 834, y: 1194),
      focusedItemID: initial.index.selectedItemID, openProgress: 1,
      selectedItemID: initial.index.selectedItemID, notebookPageID: page.id))
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    model.selectPenColor(.black); model.selectPenWidth(12)
    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = windowScene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: windowScene)
    let start = ContinuousClock.now
    window.rootViewController = UIHostingController(rootView: NotebookRootView().environment(model))
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let scale = min(window.bounds.width / 834, window.bounds.height / 1194)
    let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
      tx: window.bounds.midX - 417 * scale, ty: window.bounds.midY - 597 * scale)
    let witness = CGPoint(x: 590, y: 590).applying(transform)
    // Give the newly attached window its first update opportunity. This is
    // inside the opening clock, not a readiness/preparation barrier.
    try await Task.sleep(for: .milliseconds(16))
    // The first correct visible material triggers input, even if a separate
    // readiness registry is stale. Waiting on that registry would hide the bug.
    let opened = try await assertUX("cold-first-visible-material", since: start,
      budget: NotebookUXObservation.coldOpening, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([(witness, .blue)])
    }
    guard opened.matched else { return }
    let scene = try NotebookInteractionUXTests.Scene(model: model, window: window)
    XCTAssertEqual(scene.pageToWindow.a, transform.a, accuracy: 0.001)
    XCTAssertEqual(scene.pageToWindow.d, transform.d, accuracy: 0.001)
    XCTAssertEqual(scene.pageToWindow.tx, transform.tx, accuracy: 0.5)
    XCTAssertEqual(scene.pageToWindow.ty, transform.ty, accuracy: 0.5)
    XCTAssertEqual(model.activePage?.id, page.id)
    XCTAssertEqual(scene.pencil.state, .possible)
    let canvas = try XCTUnwrap(scene.paper.superview as? PaperCanvasContainerView).inkView
    var frames: [String] = [], probes: [String] = []
    var readyContact: InkCanvasView.ContactFrame?
    let phaseStart = CACurrentMediaTime()
    canvas.onContactFrameResolved = { receipt in
      if receipt.completion.isReady, receipt.tileCount == 1 { readyContact = receipt.contact }
      frames.append("callback=\((CACurrentMediaTime()-phaseStart)*1000)ms; first=\(receipt.isFirstFrame); ready=\(receipt.completion.isReady); OS=\(String(describing:receipt.completion.presentedTime))")
    }
    defer { canvas.onContactFrameResolved = nil }
    let contact = ContinuousClock.now
    scene.beginPencil(.init(x: 180, y: 800)); scene.movePencil(.init(x: 480, y: 800))
    let handledMS = (CACurrentMediaTime()-phaseStart)*1000
    let measuredContact = try XCTUnwrap(canvas.activeContactFrame)
    XCTAssertTrue(scene.paper.hasActiveAction, "The first contact must be admitted, not retried by the test")
    try await assertUX("first-cold-pencil-during-contact", since: contact, window: window) {
      // The same clock includes native readiness AND the actual pixels. A
      // full-window readback before this exact contact's GPU completion cannot
      // establish its pixels and only starves the update being measured.
      guard readyContact == measuredContact else { return false }
      let began = CACurrentMediaTime()
      let matched = try scene.pixels([(.init(x: 220, y: 800), .black), (.init(x: 430, y: 800), .black), (.init(x: 590, y: 590), .blue)])
      probes.append("start=\((began-phaseStart)*1000)ms; capture+decode=\((CACurrentMediaTime()-began)*1000)ms; matched=\(matched)")
      return matched
    }
    let phases = XCTAttachment(string: "handler=\(handledMS)ms\n" + frames.joined(separator: "\n") + "\n" + probes.joined(separator: "\n"))
    phases.name = "cold-held-stroke-observation-phases"; phases.lifetime = .keepAlways; add(phases)
    let state = XCTAttachment(string: "beforeLift: activeAction=\(scene.paper.hasActiveAction), activePencil=\(model.inputGate.hasActivePencil), recognizer=\(scene.pencil.state.rawValue), drawing=\(String(describing: model.activePage?.drawingStamp))")
    state.name = "cold-first-contact-owner"; state.lifetime = .keepAlways; add(state)
    XCTAssertTrue(scene.paper.hasActiveAction, "Loading the initial drawing must not cancel an already admitted Pencil contact")
    func materialCounters(_ phase:String) -> String {
      "\(phase): meshPreparations=\(canvas.pageMeshPreparationCount) meshBuilds=\(canvas.pageMeshBuildCount) projections=\(canvas.pageProjectionChangeCount) drawableResizes=\(canvas.pageDrawableResizeCount) drawableAllocations=\(canvas.pageDrawableAllocationCount) retainedAllocations=\(canvas.pageRetainedAllocationCount) committedPasses=\(canvas.pageCommittedPassCount) geometryReady=\(canvas.pageGeometryIsReady)"
    }
    var materialPhases=[materialCounters("before-pen-lift")]
    defer {
      let note=XCTAttachment(string:materialPhases.joined(separator:"\n"))
      note.name="cold-eraser-material-counters";note.lifetime = .keepAlways;add(note)
    }
    scene.endPencil()
    materialPhases.append(materialCounters("after-pen-lift"))
    let admitted = try XCTUnwrap(model.activePage)
    XCTAssertEqual(admitted.id, page.id)
    XCTAssertEqual(try admitted.inkDrawing().actions.filter { $0.tool == .pen }.count, 1)
    model.selectEraserWidth(28)
    try await scene.readyPencil(self) // Only UIKit contact reset, never render readiness.
    var erasePhases: [String] = []
    var recordsEraseCounters=false
    let erasePhaseStart = CACurrentMediaTime(), previousReadiness = canvas.onRenderReadinessChange
    canvas.onRenderReadinessChange = { ready in
      erasePhases.append("ready=\(ready) at \((CACurrentMediaTime()-erasePhaseStart)*1000)ms")
      if ready,recordsEraseCounters {
        materialPhases.append(materialCounters("first-eraser-stable-callback"))
        recordsEraseCounters=false
      }
      previousReadiness?(ready)
    }
    defer { canvas.onRenderReadinessChange = previousReadiness }
    let erase = ContinuousClock.now
    recordsEraseCounters=true
    scene.beginPencil(.init(x: 300, y: 770)); scene.movePencil(.init(x: 300, y: 830)); scene.endPencil()
    erasePhases.append("handler=\((CACurrentMediaTime()-erasePhaseStart)*1000)ms")
    materialPhases.append(materialCounters("after-eraser-handler"))
    try await assertUX("first-next-eraser-after-cold-pencil", since: erase, window: window) {
      guard canvas.isStableFramePresented else {
        erasePhases.append("probe skipped at \((CACurrentMediaTime()-erasePhaseStart)*1000)ms")
        return false
      }
      let began = CACurrentMediaTime()
      let matched = try scene.pixels([(.init(x: 220, y: 800), .black), (.init(x: 300, y: 800), .paper),
        (.init(x: 430, y: 800), .black), (.init(x: 590, y: 590), .blue)])
      erasePhases.append("capture start=\((began-erasePhaseStart)*1000)ms duration=\((CACurrentMediaTime()-began)*1000)ms matched=\(matched)")
      return matched
    }
    let eraseNote = XCTAttachment(string: erasePhases.joined(separator: "\n"))
    eraseNote.name = "cold-eraser-observation-phases"; eraseNote.lifetime = .keepAlways; add(eraseNote)
    XCTAssertEqual(model.activePage?.id, page.id)
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.count, 2)
    XCTAssertNil(model.persistenceFailure)
  }
}
