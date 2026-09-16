import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// Exercise the installed scene's Pencil owner, not a direct fit/model call.
/// Synthetic UIKit contacts do not substitute for physical Pencil calibration.
@MainActor final class NotebookGraphicSceneTests: XCTestCase {
  func testPageHoldAndImmediateShutdownKeepTheFittedObjectAndOriginalMeasurements() async throws {
    try await drawAndClose(onBoard: false)
  }
  func testBoardHoldUsesInstalledCameraAndImmediateShutdownKeepsTheObject() async throws {
    try await drawAndClose(onBoard: true)
  }

  private func drawAndClose(onBoard: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-scene-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace), pageID = try XCTUnwrap(workspace.selectedPageID)
    let viewport = SpatialPoint(x: 834, y: 1194)
    let center: WorldPoint
    if onBoard {
      model.moveItem(workspace.selectedItemID, to: .init(x: 100_000, y: 100_000))
      center = .init(x: 9_000, y: -12_000)
    } else { center = model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID) ?? .zero }
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: onBoard ? .board : .page,
      camera: .init(center: center, scale: onBoard ? 0.6 : WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: onBoard ? nil : workspace.selectedItemID, openProgress: onBoard ? 0 : 1), settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let window = try await mountNotebookScene(model)
    let presence = try XCTUnwrap(model.presence)
    let receiver: UIGestureRecognizer
    let paper: PaperInputView?
    if onBoard {
      receiver = try XCTUnwrap(window.gestureRecognizers?.first { $0 is SpatialPencilGestureRecognizer })
      paper = nil
    } else {
      receiver = try XCTUnwrap(window.gestureRecognizers?.first { $0.name == "NotebookPaperPencil" })
      paper = try XCTUnwrap(descendants(try XCTUnwrap(window.rootViewController?.view))
        .compactMap { $0 as? PaperInputView }.first { $0.isUserInteractionEnabled })
    }
    let touch = SceneGraphicTouch(window: window), event = SceneGraphicEvent()
    let midpoint = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    var measured: [CGPoint] = []
    for index in 0...120 {
      let angle = Double(index) / 120 * 2 * Double.pi
      touch.point = .init(x: midpoint.x + 90 * cos(angle), y: midpoint.y + 60 * sin(angle))
      touch.sampleTime += 0.01
      measured.append(paper?.convert(touch.point, from: window) ?? touch.point)
      if index == 0 {
        // Empty allTouches mirrors iPadOS' initial Pencil hit-test boundary.
        touch.sourceView = window.hitTest(touch.point, with: event)
        receiver.touchesBegan([touch], with: event)
        XCTAssertTrue(model.inputGate.hasActivePencil)
      } else { receiver.touchesMoved([touch], with: event) }
    }
    try await Task.sleep(for: .milliseconds(650))
    receiver.touchesEnded([touch], with: event)
    // No yield to a sheet callback, no extra fit call and no polling for a
    // graphic task before the application's real persistence boundary.
    let closed = await model.shutdown(); XCTAssertTrue(closed)
    let reopened = NotebookStore(root: root)
    let graphic: NotebookGraphic, actual: CGRect, measuredSourceCount: Int
    if onBoard {
      let board = try reopened.loadBoard(items: workspace.items)
      let element = try XCTUnwrap(board.board(workspace.rootBoardID)?.elements.first { $0.graphic != nil })
      graphic = try XCTUnwrap(element.graphic)
      let origin = presence.camera.worldToScreen((element.worldOrigin ?? .zero).offsetBy(x: element.frame.x, y: element.frame.y), viewport: presence.viewport)
      actual = .init(x: origin.x, y: origin.y, width: element.frame.width * presence.camera.scale, height: element.frame.height * presence.camera.scale)
      let journal = try reopened.loadSpatialInk()
      let action = try XCTUnwrap(journal.actions.first { graphic.sourceInkIDs.contains($0.id) })
      XCTAssertTrue(action.isActive); measuredSourceCount = action.spans.flatMap(\.samples).count
    } else {
      let page = try reopened.loadPage(pageID)
      let element = try XCTUnwrap(page.elements.first { $0.graphic != nil })
      graphic = try XCTUnwrap(element.graphic)
      actual = .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
      let action = try XCTUnwrap(PageInkDrawing.decode(page.drawingData).actions.first { graphic.sourceInkIDs.contains($0.id) })
      XCTAssertTrue(action.isActive); measuredSourceCount = action.samples.count
    }
    XCTAssertTrue(graphic.showsGeometry); XCTAssertEqual(graphic.sourceInkIDs.count, 1)
    XCTAssertEqual(measuredSourceCount, measured.count)
    XCTAssertEqual(actual.minX, try XCTUnwrap(measured.map(\.x).min()), accuracy: 0.1)
    XCTAssertEqual(actual.minY, try XCTUnwrap(measured.map(\.y).min()), accuracy: 0.1)
    XCTAssertEqual(actual.width, try XCTUnwrap(measured.map(\.x).max()) - actual.minX, accuracy: 0.1)
    XCTAssertEqual(actual.height, try XCTUnwrap(measured.map(\.y).max()) - actual.minY, accuracy: 0.1)
    XCTAssertEqual(model.presence?.camera, presence.camera)
  }

  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class SceneGraphicTouch: UITouch {
  let sourceWindow: UIWindow
  var sourceView: UIView?
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var view: UIView? { sourceView }
  override var window: UIWindow? { sourceWindow }
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
private final class SceneGraphicEvent: UIEvent {
  override var allTouches: Set<UITouch>? { [] }
}
