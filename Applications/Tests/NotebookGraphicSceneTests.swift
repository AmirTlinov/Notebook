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

  func testPageHeldLineBindsNodesAndFollowsAnUnwrittenMove() async throws {
    try await drawConnection(onBoard:false)
  }

  func testBoardHeldLineBindsNodesUsingTheInstalledWorldProjection() async throws {
    try await drawConnection(onBoard:true)
  }

  private func drawConnection(onBoard: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("connector-scene-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace, "Startup: \(model.loadState)"), pageID = try XCTUnwrap(workspace.selectedPageID)
    let target = CollaborationTarget(kind:onBoard ? .board : .page,id:onBoard ? workspace.rootBoardID : pageID)
    let origin = WorldPoint(x:9000,y:-12000), viewport = SpatialPoint(x:834,y:1194)
    if onBoard { model.moveItem(workspace.selectedItemID,to:.init(x:100_000,y:100_000)) }
    let center = onBoard ? origin.offsetBy(x:417,y:597)
      : model.boardHierarchy?.focusedCenter(of:workspace.selectedItemID,in:workspace.rootBoardID) ?? .zero
    model.updatePresence(.init(boardID:workspace.rootBoardID,mode:onBoard ? .board : .page,
      camera:.init(center:center,scale:onBoard ? 0.8 : WorkspaceItemGeometry.notebook.fitScale(viewport:viewport)),
      viewport:viewport,focusedItemID:onBoard ? nil : workspace.selectedItemID,openProgress:onBoard ? 0 : 1),settled:true)
    let initiallySaved = await model.finishPendingPersistence(); XCTAssertTrue(initiallySaved)
    let store = model.store
    func node(_ id: String, x: Double) throws -> CollaborationOperation {
      var values: [String:JSONValue] = ["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:x,y:400,width:100,height:100)),"graphic":try .encode(NotebookGraphic(label:id))]
      if onBoard { values["worldOrigin"] = try .encode(origin) }
      return .init(kind:.insertElement,target:target,id:id,values:values)
    }
    _ = try store.applyCollaborationAction(.init(summary:"Two nodes",
      expected:[.init(target:target,revision:store.targetContentRevision(target:target))],
      operations:[node("a",x:140),node("b",x:480)]),actor:UUID())
    await model.reloadExternalChanges()?.value
    let window = try await mountNotebookScene(model), presence = try XCTUnwrap(model.presence)
    let paper = descendants(try XCTUnwrap(window.rootViewController?.view)).compactMap { $0 as? PaperInputView }
      .first { $0.isUserInteractionEnabled }
    let receiver = try XCTUnwrap(window.gestureRecognizers?.first {
      onBoard ? $0 is SpatialPencilGestureRecognizer : $0.name == "NotebookPaperPencil"
    })
    let touch = SceneGraphicTouch(window:window), event = SceneGraphicEvent()
    for index in 0...120 {
      let t = Double(index)/120, point = SpatialPoint(x:240+240*t,y:450+sin(t*8*Double.pi)*0.5)
      if onBoard {
        let p = presence.camera.worldToScreen(origin.offsetBy(x:point.x,y:point.y),viewport:presence.viewport)
        touch.point = .init(x:p.x,y:p.y)
      } else { touch.point = try XCTUnwrap(paper).convert(.init(x:point.x,y:point.y),to:window) }
      touch.sampleTime += 0.01
      if index == 0 {
        touch.sourceView = window.hitTest(touch.point,with:event)
        receiver.touchesBegan([touch],with:event)
        XCTAssertTrue(model.inputGate.hasActivePencil)
      } else { receiver.touchesMoved([touch],with:event) }
    }
    try await Task.sleep(for:.milliseconds(650))
    receiver.touchesEnded([touch],with:event)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let graphic: NotebookGraphic, id: String
    if onBoard {
      let element = try XCTUnwrap(store.loadBoard(items:workspace.items).board(target.id)?.elements.first { $0.graphic?.connection != nil })
      graphic = try XCTUnwrap(element.graphic); id = element.id
    } else {
      let element = try XCTUnwrap(store.loadPage(pageID).elements.first { $0.graphic?.connection != nil })
      graphic = try XCTUnwrap(element.graphic); id = element.id
    }
    XCTAssertEqual(graphic.connection?.start.binding?.elementID,"a")
    XCTAssertEqual(graphic.connection?.end.binding?.elementID,"b")
    XCTAssertEqual(graphic.connection?.endArrowhead,NotebookGraphicConnection.Arrowhead.none)
    XCTAssertEqual(graphic.sourceInkIDs.count,1)
    let link: EditableElementReference = onBoard ? .spatial(boardID:target.id,elementID:id) : .page(pageID:pageID,elementID:id)
    let node: EditableElementReference = onBoard ? .spatial(boardID:target.id,elementID:"a") : .page(pageID:pageID,elementID:"a")
    let deadline = ContinuousClock.now + .seconds(8)
    while model.graphicLayout(link) == nil && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(20)) }
    let before = try XCTUnwrap(model.graphicLayout(link)), revision = try store.targetContentRevision(target:target)
    model.selectElement(node)
    let contact = try XCTUnwrap(model.beginElementManipulation(node,kind:.move))
    model.updateElementManipulation(contact,translation:.init(x:0,y:90))
    let preview = try XCTUnwrap(model.graphicLayout(link))
    XCTAssertGreaterThan(preview.frame.y+preview.start.y,before.frame.y+before.start.y+60)
    XCTAssertEqual(try store.targetContentRevision(target:target),revision,"Draft movement must not write samples to SQLite")
    model.cancelElementManipulation(contact)
    XCTAssertEqual(model.graphicLayout(link),before)
    let finalContact = try XCTUnwrap(model.beginElementManipulation(node,kind:.move))
    model.finishElementManipulation(finalContact,translation:.init(x:0,y:90))
    let moved = await model.finishPendingPersistence(); XCTAssertTrue(moved)
    await model.reloadExternalChanges()?.value
    let actual = try XCTUnwrap(store.readGraphicResolution(target:target,elementID:id).layout)
    XCTAssertEqual(actual,preview)
    let retained = try onBoard ? store.readSpatialElement(boardID:target.id,elementID:id)?.graphic
      : store.readPageElement(pageID:pageID,elementID:id)?.graphic
    XCTAssertEqual(retained,graphic,"Node movement must not rewrite the connector's authored coordinates")
    model.selectElement(link)
    let detach = try XCTUnwrap(model.beginElementManipulation(link,kind:.endpoint(.end)))
    model.finishElementManipulation(detach,translation:.init(x:110,y:130))
    let detached = await model.finishPendingPersistence(); XCTAssertTrue(detached)
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.graphicElement(link)?.connection?.end.binding,"Dragging an endpoint out of a node detaches it explicitly")
    let loose = try XCTUnwrap(model.graphicLayout(link))
    let rebind = try XCTUnwrap(model.beginElementManipulation(link,kind:.endpoint(.end)))
    let linkOrigin = model.selectionSession.manipulation?.worldOrigin ?? .zero
    let offset = linkOrigin.delta(to:onBoard ? origin : .zero)
    model.finishElementManipulation(rebind,translation:.init(x:offset.x+530-loose.frame.x-loose.end.x,
      y:offset.y+450-loose.frame.y-loose.end.y))
    let rebound = await model.finishPendingPersistence(); XCTAssertTrue(rebound)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.graphicElement(link)?.connection?.end.binding?.elementID,"b")
    let bend = try XCTUnwrap(model.beginElementManipulation(link,kind:.bend))
    model.finishElementManipulation(bend,translation:.init(x:0,y:70))
    let bent = await model.finishPendingPersistence(); XCTAssertTrue(bent)
    await model.reloadExternalChanges()?.value
    XCTAssertGreaterThan(abs(model.graphicElement(link)?.connection?.bend ?? 0),50)
    model.setGraphicLabel("1:2",reference:link)
    let labelled = await model.finishPendingPersistence(); XCTAssertTrue(labelled)
    await model.reloadExternalChanges()?.value
    model.setGraphicStyle(reference:link) { $0.strokeWidth = 4; $0.dash = .dashed }
    let styled = await model.finishPendingPersistence(); XCTAssertTrue(styled)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.graphicElement(link)?.style.dash,.dashed)
    let finalLayout = try XCTUnwrap(store.readGraphicResolution(target:target,elementID:id).layout)
    XCTAssertEqual(model.presence?.camera,presence.camera)
    let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
    let evidence = XCTAttachment(image:image); evidence.name = onBoard ? "bound-line-board-preview" : "bound-line-page-preview"
    evidence.lifetime = .keepAlways; add(evidence)
    let closed = await model.shutdown(); XCTAssertTrue(closed)
    XCTAssertEqual(try NotebookStore(root:root).readGraphicResolution(target:target,elementID:id).layout,finalLayout)
  }

  private func drawAndClose(onBoard: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-scene-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace, "Startup: \(model.loadState)"), pageID = try XCTUnwrap(workspace.selectedPageID)
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
