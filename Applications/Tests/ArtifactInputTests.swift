import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class ArtifactInputTests: XCTestCase {
  func testPaperContactKeepsFingerAndControlOwnershipAndFinishesOnlyItsAcceptedPencil() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    let paper = PaperCanvasContainerView(frame: .init(x: 20, y: 20, width: 220, height: 280))
    host.view.addSubview(paper); paper.layoutIfNeeded()
    defer { paper.retireInput(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let receiver = try XCTUnwrap(window.gestureRecognizers?.first { $0.name == "NotebookPaperPencil" })
    var actions: [PageInkAction] = []
    paper.touchView.onDrawingMutation = { actions.append($0) }
    let finger = ArtifactTouch(window: window, kind: .direct)
    finger.point = .init(x: 120, y: 140); finger.sourceView = host.view
    receiver.touchesBegan([finger], with: ArtifactEvent(finger))
    XCTAssertFalse(paper.touchView.hasActiveAction); receiver.reset()
    let pencil = ArtifactTouch(window: window, kind: .pencil)
    pencil.point = finger.point; pencil.sourceView = host.view
    paper.admitsPencilContact = { _ in false }
    receiver.touchesBegan([pencil], with: ArtifactEvent(pencil))
    XCTAssertFalse(paper.touchView.hasActiveAction); XCTAssertTrue(actions.isEmpty); receiver.reset()
    paper.admitsPencilContact = { _ in true }
    pencil.estimateIndex = 1; pencil.awaitingForce = true; pencil.measuredForce = 0.2
    receiver.touchesBegan([pencil], with: ArtifactEvent(pencil))
    receiver.touchesEnded([pencil], with: ArtifactEvent(pencil)); receiver.reset()
    XCTAssertTrue(actions.isEmpty, "A normal lift still allows UIKit's measured force correction")
    pencil.awaitingForce = false; pencil.measuredForce = 0.8
    receiver.touchesEstimatedPropertiesUpdated([pencil])
    XCTAssertEqual(actions.count, 1)
    XCTAssertEqual(actions.first?.samples.last?.force ?? 0, 0.8, accuracy: 0.001)
    pencil.estimateIndex = nil; pencil.sampleTime += 1
    receiver.touchesBegan([pencil], with: ArtifactEvent(pencil))
    XCTAssertTrue(paper.touchView.hasActiveAction)
    paper.retireInput()
    XCTAssertEqual(actions.count, 2, "Retirement finishes measured ink instead of abandoning it")
    XCTAssertFalse(paper.touchView.hasActiveAction); XCTAssertNil(receiver.view)
  }

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
      css: "html,body,button{margin:0;width:100%;height:100%;background:#eef}", javaScript: "window.chartReady=true;notebook.ready(Promise.resolve())")
    page.replaceElements([element], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let camera = model.presence?.camera
    model.selectElement(.page(pageID: page.id, elementID: element.id))
    model.interactiveElementFocus = .page(pageID: page.id, elementID: element.id)
    var ready = false
    host.rootView = AnyView(PageSurface(page: page, isCurrent: true, isInteractive: true, isVisible: true,
      onRenderReady: .init { ready = $0 }).environment(model).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    try await waitUntil { ready }
    let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? PaperInputView }.first)
    let pencil = ArtifactTouch(window: window, kind: .pencil)
    pencil.point = input.convert(.init(x: input.bounds.midX, y: input.bounds.midY), to: window)
    let event = ArtifactEvent(pencil)
    // Physical iPadOS begins hit testing before UIEvent.allTouches contains
    // the Pencil. The input route must not guess a touch type from that set.
    pencil.sourceView = window.hitTest(pencil.point, with: ArtifactEvent(pencil, includesTouch: false))
    XCTAssertFalse(pencil.sourceView === input)
    let receiver = try XCTUnwrap(window.gestureRecognizers?.first { $0.name == "NotebookPaperPencil" })
    let oldDrawing = try PageInkDrawing.decode(page.drawingData)
    receiver.touchesBegan([pencil], with: event)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    for dx in stride(from: 10.0, through: 100.0, by: 10) {
      pencil.point = input.convert(.init(x: input.bounds.midX + dx, y: input.bounds.midY), to: window)
      pencil.sampleTime += 0.02; receiver.touchesMoved([pencil], with: event)
    }
    receiver.touchesEnded([pencil], with: event)
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
    let address = SceneSourceAddress(plane: .board(boardID), elementID: element.id)
    try await waitUntil { model.compositionTiles.published?.hasInstalledPixels(for: address) == true }
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
  var sourceView: UIView?
  override var view: UIView? { sourceView }
  override var window: UIWindow? { sourceWindow }
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  var measuredForce: CGFloat = 1
  var awaitingForce = false
  var estimateIndex: NSNumber?
  init(window: UIWindow, kind: UITouch.TouchType) { sourceWindow = window; self.kind = kind; super.init() }
  override var type: UITouch.TouchType { kind }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { measuredForce }
  override var estimationUpdateIndex: NSNumber? { estimateIndex }
  override var estimatedPropertiesExpectingUpdates: UITouch.Properties { awaitingForce ? .force : [] }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

private final class ArtifactEvent: UIEvent {
  let touch: UITouch
  let includesTouch: Bool
  init(_ touch: UITouch, includesTouch: Bool = true) { self.touch = touch; self.includesTouch = includesTouch; super.init() }
  override var allTouches: Set<UITouch>? { includesTouch ? [touch] : [] }
}
