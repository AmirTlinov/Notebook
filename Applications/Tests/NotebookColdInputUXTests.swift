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
    XCTAssertTrue(receipt.completion.permitsProgress)
    XCTAssertTrue(scene.paper.hasActiveAction)
    if let presented = receipt.completion.presentationTime {
      XCTAssertLessThanOrEqual((presented - start) * 1000, NotebookGestureLatency.budgetMS)
    } else {
      XCTAssertFalse(MetalFrameCompletion.reportsDisplayTime)
    }
    let note = XCTAttachment(string: "cold first dot: handler=\((handled-start)*1000) ms; resolution callback=\((try XCTUnwrap(resolvedAt)-start)*1000) ms; OS display=\(String(describing: receipt.completion.presentationTime.map { ($0-start)*1000 })); firstFrame=\(receipt.isFirstFrame). Simulator callback is GPU readiness, not displayed latency.")
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
    let contact = ContinuousClock.now
    scene.beginPencil(.init(x: 180, y: 800)); scene.movePencil(.init(x: 480, y: 800))
    XCTAssertTrue(scene.paper.hasActiveAction, "The first contact must be admitted, not retried by the test")
    try await assertUX("first-cold-pencil-during-contact", since: contact, window: window) {
      try scene.pixels([(.init(x: 220, y: 800), .black), (.init(x: 430, y: 800), .black), (.init(x: 590, y: 590), .blue)])
    }
    let state = XCTAttachment(string: "beforeLift: activeAction=\(scene.paper.hasActiveAction), activePencil=\(model.inputGate.hasActivePencil), recognizer=\(scene.pencil.state.rawValue), drawing=\(String(describing: model.activePage?.drawingStamp))")
    state.name = "cold-first-contact-owner"; state.lifetime = .keepAlways; add(state)
    XCTAssertTrue(scene.paper.hasActiveAction, "Loading the initial drawing must not cancel an already admitted Pencil contact")
    scene.endPencil()
    let admitted = try XCTUnwrap(model.activePage)
    XCTAssertEqual(admitted.id, page.id)
    XCTAssertEqual(try admitted.inkDrawing().actions.filter { $0.tool == .pen }.count, 1)
    model.selectEraserWidth(28)
    try await scene.readyPencil(self) // Only UIKit contact reset, never render readiness.
    let erase = ContinuousClock.now
    scene.beginPencil(.init(x: 300, y: 770)); scene.movePencil(.init(x: 300, y: 830)); scene.endPencil()
    try await assertUX("first-next-eraser-after-cold-pencil", since: erase, window: window) {
      try scene.pixels([(.init(x: 220, y: 800), .black), (.init(x: 300, y: 800), .paper),
        (.init(x: 430, y: 800), .black), (.init(x: 590, y: 590), .blue)])
    }
    XCTAssertEqual(model.activePage?.id, page.id)
    XCTAssertEqual(try model.activePage?.inkDrawing().actions.count, 2)
    XCTAssertNil(model.persistenceFailure)
  }
}
