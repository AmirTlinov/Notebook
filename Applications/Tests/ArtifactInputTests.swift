import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class ArtifactInputTests: XCTestCase {
  func testPencilHitsPaperAboveASelectedLiveArtifactAndPersistsItsOwnStroke() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let element = AgentElement(id: "pencil-over-chart", kind: .web,
      frame: .init(x: page.size.width * 0.2, y: page.size.height * 0.2, width: page.size.width * 0.6, height: page.size.height * 0.6),
      source: "chart", html: "<button>Graph control</button>",
      css: "html,body,button{margin:0;width:100%;height:100%;background:#eef}", javaScript: "window.chartReady=true")
    page.replaceElements([element], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let camera = model.presence?.camera
    model.selectElement(.page(pageID: page.id, elementID: element.id))
    model.interactiveElementFocus = .page(pageID: page.id, elementID: element.id)
    var ready = false
    host.rootView = AnyView(PageSurface(page: page, isInteractive: true, isVisible: true,
      onRenderReady: .init { ready = $0 }).environment(model).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    try await waitUntil { ready }
    let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PaperInputView }.first)
    let pencil = ArtifactTouch(window: window, kind: .pencil)
    pencil.point = input.convert(.init(x: input.bounds.midX, y: input.bounds.midY), to: window)
    let event = ArtifactEvent(pencil)
    XCTAssertTrue(window.hitTest(pencil.point, with: event) === input,
      "Neither an agent's HTML button nor selected frame may intercept Pencil")
    let oldDrawing = try PageInkDrawing.decode(page.drawingData)
    input.touchesBegan([pencil], with: event)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    for dx in stride(from: 10.0, through: 100.0, by: 10) {
      pencil.point = input.convert(.init(x: input.bounds.midX + dx, y: input.bounds.midY), to: window)
      pencil.sampleTime += 0.02; input.touchesMoved([pencil], with: event)
    }
    input.touchesEnded([pencil], with: event)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let durable = try model.store.loadPage(page.id)
    let drawing = try PageInkDrawing.decode(durable.drawingData)
    XCTAssertEqual(drawing.actions.count, oldDrawing.actions.count + 1)
    XCTAssertEqual(durable.elements, [element]); XCTAssertEqual(model.presence?.camera, camera)
    XCTAssertFalse(model.inputGate.hasActivePencil)
    let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let proof = XCTAttachment(image: image)
    proof.name = "pencil-over-live-selected-artifact"; proof.lifetime = .keepAlways; add(proof)
  }

  func testBoardArtifactHoldUsesFrozenScaleAndPersistsWithoutMovingCameraOrPointingAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    _ = await model.finishPendingPersistence()
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
    var board = before
    let element = SpatialElement(id: "held-chart", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 200, height: 160), worldOrigin: .zero,
      source: "chart", html: "<svg viewBox='0 0 200 160'><path d='M10 100 L80 20 L180 150' stroke='blue' fill='none'/></svg>",
      css: "body{margin:0;background:white}", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(board.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    _ = try model.store.saveBoardEdits(before: before, after: board)
    await model.reloadExternalChanges()?.value
    window.rootViewController = host; window.makeKeyAndVisible()
    let size = window.bounds.size
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 100, y: 80), scale: 0.5), viewport: .init(x: size.width, y: size.height))
    model.updatePresence(presence, settled: true)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).ignoresSafeArea())
    try await waitUntil { model.compositionTiles.published != nil && !model.scenePreparationPending }
    let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SceneSelectionRecognizer }.first)
    let finger = ArtifactTouch(window: window, kind: .direct)
    finger.point = .init(x: size.width / 2, y: size.height / 2)
    let event = ArtifactEvent(finger)
    recognizer.touchesBegan([finger], with: event)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(model.selectionSession.element, .spatial(boardID: boardID, elementID: element.id))
    finger.point.x += 80; finger.point.y += 40
    recognizer.touchesMoved([finger], with: event)
    XCTAssertEqual(model.selectionSession.manipulation?.movement, .init(x: 160, y: 80))
    recognizer.touchesEnded([finger], with: event)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let durable = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
    let moved = try XCTUnwrap(durable.board(boardID)?.elements.first { $0.id == element.id })
    XCTAssertEqual(moved.frame.x, 160); XCTAssertEqual(moved.frame.y, 80)
    XCTAssertEqual(moved.html, element.html)
    XCTAssertEqual(model.presence?.camera, presence.camera)
    XCTAssertEqual(model.agentQuestion?.references.first?.elementID, element.id)
    XCTAssertTrue(model.chat?.jobs.isEmpty == true, "Selection never sends a hidden agent message")
    XCTAssertNil(model.selectionSession.manipulation)
  }

  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(predicate()); if !predicate() { throw CocoaError(.featureUnsupported) }
  }
}

@MainActor private final class ArtifactTouch: UITouch {
  let sourceWindow: UIWindow
  let kind: UITouch.TouchType
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  init(window: UIWindow, kind: UITouch.TouchType) { sourceWindow = window; self.kind = kind; super.init() }
  override var type: UITouch.TouchType { kind }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

private final class ArtifactEvent: UIEvent {
  let touch: UITouch
  init(_ touch: UITouch) { self.touch = touch; super.init() }
  override var allTouches: Set<UITouch>? { [touch] }
}
