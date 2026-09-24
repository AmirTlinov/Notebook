import NotebookCore
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class NotebookElementManipulationTests: XCTestCase {
  func testEveryCornerKeepsTheOppositeCornerAtLimits() {
    let original = CGRect(x: 100, y: 80, width: 200, height: 160)
    let reference = EditableElementReference.page(pageID: UUID(), elementID: "chart")
    let page = CGRect(x: 0, y: 0, width: 600, height: 800)
    for corner in NotebookElementResizeHandle.allCases {
      for delta in [CGPoint(x: 30, y: 25), .init(x: -5000, y: -5000), .init(x: 5000, y: 5000)] {
        var contact = NotebookElementManipulation(reference: reference, kind: .resize(corner), frame: original, bounds: page)
        contact.update(translation: delta)
        let result = contact.frame
        XCTAssertEqual(corner.leading ? result.maxX : result.minX, corner.leading ? original.maxX : original.minX)
        XCTAssertEqual(corner.top ? result.maxY : result.minY, corner.top ? original.maxY : original.minY)
        XCTAssertGreaterThanOrEqual(result.width, 1); XCTAssertGreaterThanOrEqual(result.height, 1)
        XCTAssertTrue(page.contains(result))

      }
    }
  }

  func testIndividualVerticesKeepOtherCornersFixedAndStopBeforeCrossing() throws {
    let ref = EditableElementReference.page(pageID:UUID(),elementID:"polygon")
    for shape in [NotebookGraphic.Shape.triangle,.rectangle,.diamond] {
      let graphic = NotebookGraphic(shape:shape), frame = CGRect(x:100,y:100,width:160,height:120)
      var contact = NotebookElementManipulation(reference:ref,kind:.vertex(0),frame:frame,bounds:.init(x:0,y:0,width:600,height:800),graphic:graphic)
      let points = try XCTUnwrap(contact.originalVertices)
      contact.update(translation:.init(x:35,y:-30))
      let changed = try XCTUnwrap(contact.vertices)
      for index in points.indices {
        XCTAssertEqual(contact.frame.minX+changed[index].x*contact.frame.width,frame.minX+points[index].x*frame.width+(index == 0 ? 35 : 0),accuracy:0.001)
        XCTAssertEqual(contact.frame.minY+changed[index].y*contact.frame.height,frame.minY+points[index].y*frame.height+(index == 0 ? -30 : 0),accuracy:0.001)
      }
      contact.update(translation:.init(x:5_000,y:5_000))
      XCTAssertTrue(NotebookGraphicGeometry.isConvex(try XCTUnwrap(contact.vertices),sameWindingAs:points))
      XCTAssertTrue(CGRect(x:0,y:0,width:600,height:800).contains(contact.frame))
    }
  }

  func testCornerRadiusContactDoesNotResizeAndCanReturnToSharp() {
    let graphic = NotebookGraphic(shape:.rectangle), frame = CGRect(x:100,y:100,width:160,height:120)
    var contact = NotebookElementManipulation(reference:.page(pageID:UUID(),elementID:"box"),kind:.roundCorners,
      frame:frame,bounds:nil,graphic:graphic)
    contact.update(translation:.init(x:30,y:30))
    XCTAssertEqual(contact.cornerRadius,30,accuracy:0.001); XCTAssertEqual(contact.frame,frame)
    contact.update(translation:.init(x:5_000,y:5_000))
    XCTAssertEqual(contact.cornerRadius,60,accuracy:0.001)
    contact.update(translation:.init(x:-40,y:-40)); XCTAssertEqual(contact.cornerRadius,0)
  }

  func testBendContactTracksBothAxesWithoutMovingItsFreeEnds() throws {
    let graphic = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero),end:.init(point:.init(x:200,y:100)),bend:20,endArrowhead:.none))
    let surface = SurfaceID.page(UUID()), frame = PageRect(x:100,y:100,width:200,height:100)
    func layout(_ graphic: NotebookGraphic) throws -> NotebookGraphicLayout {
      try XCTUnwrap(NotebookGraphicGraph([.init(id:"line",graphic:graphic,frame:frame,surface:surface,shown:true)]).resolve("line").layout)
    }
    let before = try layout(graphic)
    var contact = NotebookElementManipulation(reference:.page(pageID:UUID(),elementID:"line"),kind:.bend,
      frame:.init(x:100,y:100,width:200,height:100),bounds:nil,connection:graphic.connection,layout:try XCTUnwrap(NotebookGraphicGraph([.init(id:"line",graphic:graphic,frame:frame,surface:surface,shown:true)]).resolve("line",space:.body).layout),graphic:graphic)
    contact.update(translation:.zero); XCTAssertEqual(contact.connection,graphic.connection)
    contact.update(translation:.init(x:330,y:240))
    var changed = graphic; changed.connection = contact.connection
    let after = try layout(changed)
    XCTAssertEqual(after.frame.x+after.bend.x-before.frame.x-before.bend.x,330,accuracy:0.001)
    XCTAssertEqual(after.frame.y+after.bend.y-before.frame.y-before.bend.y,240,accuracy:0.001)
    XCTAssertEqual(changed.connection?.start,graphic.connection?.start); XCTAssertEqual(changed.connection?.end,graphic.connection?.end)
  }

  func testTouchTargetsDoNotImposeA44PointGeometryMinimumOrAnArtificialBoardMaximum() {
    let ref = EditableElementReference.spatial(boardID: UUID(), elementID: "small")
    var small = NotebookElementManipulation(reference: ref, kind: .resize(.bottomTrailing),
      frame: .init(x: 100,y:100,width:40,height:32), bounds:nil)
    small.update(translation:.init(x:-28,y:-20))
    XCTAssertEqual(small.frame,.init(x:100,y:100,width:12,height:12))
    var large = NotebookElementManipulation(reference: ref, kind: .resize(.topLeading),
      frame:.init(x:100,y:100,width:3000,height:2200),bounds:nil)
    large.update(translation:.init(x:-400,y:-500))
    XCTAssertEqual(large.frame,.init(x:-300,y:-400,width:3400,height:2700))
    XCTAssertEqual(NotebookElementResizeHandle.visible(in:.init(width:40,height:32)).count,4)
    XCTAssertEqual(NotebookElementResizeHandle.visible(in:.init(width:160,height:32)).count,6)
  }

  func testMaterialResizeProjectsTheActualLiveFrameBeforeCommit() async throws {
    try await fixture { model, reference in
      model.selectElement(reference)
      let source = try XCTUnwrap(model.activePage?.elements.first?.frame)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference,kind:.resize(.topLeading)))
      model.updateElementManipulation(contact,translation:.init(x:-35,y:-25))
      XCTAssertEqual(model.elementPresentationFrame(reference,fallback:source),.init(x:65,y:55,width:235,height:185))
      XCTAssertEqual(model.activePage?.elements.first?.frame,source,"A live resize is not a per-sample storage write")
      model.cancelElementManipulation(contact)
      XCTAssertEqual(model.elementPresentationFrame(reference,fallback:source),source)
    }
  }

  func testLateLiftAndPencilCannotCommitAnOldContact() async throws {
    try await fixture { model, reference in
      model.selectElement(reference)
      let old = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
      model.updateElementManipulation(old, translation: .init(x: -20, y: -30))
      model.selectElement(reference)
      XCTAssertTrue(model.isPointing, "Reselecting the same element cannot drop an accepted contact")
      let pencil = UUID(); XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertFalse(model.isPointing)
      XCTAssertFalse(model.finishElementManipulation(old, translation: .init(x: -100, y: -100)))
      model.inputGate.endPencilAction(source: pencil)
      let next = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
      model.cancelElementManipulation(old)
      XCTAssertEqual(model.selectionSession.manipulation?.id, next)
      model.clearSelection()
      XCTAssertFalse(model.finishElementManipulation(next, translation: .init(x: 100, y: 100)))
      await model.finishPendingPersistence()
      XCTAssertEqual(model.activePage?.elements.first?.frame, .init(x: 100, y: 80, width: 200, height: 160))
    }
  }

  func testResizeKeepsPaperAndRejectsASupersededContact() async throws {
    try await fixture { model, reference in
      let before = try XCTUnwrap(model.activePage), camera = model.presence?.camera
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
      XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: -30, y: -20)))
      await model.finishPendingPersistence()
      let page = try model.store.loadPage(before.id)
      XCTAssertEqual(page.elements.first?.frame, .init(x: 70, y: 60, width: 230, height: 180))
      XCTAssertEqual(page.elements.first?.html, before.elements.first?.html)
      XCTAssertEqual(page.drawingData, before.drawingData); XCTAssertEqual(model.presence?.camera, camera)
      let next = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
      let replacement = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      XCTAssertTrue(model.finishElementManipulation(replacement, translation: .init(x: 10, y: 0)))
      XCTAssertFalse(model.finishElementManipulation(next, translation: .init(x: 100, y: 100)), "A replacement contact cannot be overwritten by the old lift")
      XCTAssertEqual(model.elementPresentationFrame(reference,fallback:page.elements[0].frame),.init(x:80,y:60,width:230,height:180),
        "The accepted draft is visible before the serial writer publishes its page")
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
      XCTAssertEqual(try model.store.loadPage(before.id).elements.first?.frame,.init(x:80,y:60,width:230,height:180))
    }
  }

  func testStaleCornerRejectsConcurrentSourceThenFreshContactKeepsContentAndInk() async throws {
    try await fixture { model, reference in
      let before = try XCTUnwrap(model.activePage)
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
      let target = CollaborationTarget(kind: .page, id: before.id), agent = UUID(), stroke = UUID()
      let action = CollaborationAction(summary: "Update the chart while its corner is held", expected: [
        .init(target: target, revision: before.agentStamp.revision, inkRevision: before.drawingStamp.revision)
      ], operations: [
        .init(kind: .updateElement, target: target, id: "chart", values: ["html": .string("<p>Agent's new explanation</p>")]),
        .init(kind: .appendInkStroke, target: target, id: stroke.uuidString, values: ["points": .array([
          .object(["x": .number(400), "y": .number(200)]), .object(["x": .number(420), "y": .number(240)])])])
      ])
      _ = try model.store.applyCollaborationAction(action, actor: agent)
      XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: -30, y: -20)))
      let rejected=await model.graphicCommandTask?.value
      XCTAssertNil(rejected,"An old contact cannot silently adopt a peer's replaced source")
      let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
      XCTAssertEqual(try model.store.loadPage(before.id).elements.first?.frame,before.elements.first?.frame)
      XCTAssertNotNil(model.actionCue)
      await model.reloadExternalChanges()?.value
      model.selectElement(reference)
      let fresh=try XCTUnwrap(model.beginElementManipulation(reference,kind:.resize(.topLeading)))
      XCTAssertTrue(model.finishElementManipulation(fresh,translation:.init(x:-30,y:-20)))
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
      let merged = try model.store.loadPage(before.id)
      XCTAssertEqual(merged.elements.first?.frame, .init(x: 70, y: 60, width: 230, height: 180))
      XCTAssertEqual(merged.elements.first?.html, "<p>Agent's new explanation</p>")
      XCTAssertTrue(try PageInkDrawing.decode(merged.drawingData).actions.contains { $0.id == stroke && $0.isActive })
    }
  }

  func testOldTextEditorCannotReleaseAnotherBoardOrANewSelection() async throws {
    try await fixture { model, _ in
      let first = EditableElementReference.spatial(boardID: UUID(), elementID: "title")
      let second = EditableElementReference.spatial(boardID: UUID(), elementID: "title")
      model.selectElement(first); let old = model.selectionSession.id
      if case .spatial(let board, let id) = second { model.interactiveElementFocus = .board(boardID: board, elementID: id) }
      model.finishInteractiveElementInput(first, selectionID: old)
      XCTAssertTrue(model.selectionSession.isInteractive)
      let current = model.selectionSession.id
      model.finishInteractiveElementInput(first, selectionID: current)
      XCTAssertTrue(model.selectionSession.isInteractive, "The same local ID on another board is not this editor")
      model.clearSelection()
      if case .spatial(let board, let id) = second { model.interactiveElementFocus = .board(boardID: board, elementID: id) }
      model.finishInteractiveElementInput(second, selectionID: current)
      XCTAssertTrue(model.selectionSession.isInteractive)
      model.finishInteractiveElementInput(second, selectionID: model.selectionSession.id)
      XCTAssertFalse(model.selectionSession.isInteractive)
    }
  }

  func testCancellingAPreviewPreservesAnAgentEditAndCannotCommitOnLateLift() async throws {
    try await fixture { model, reference in
      let before = try XCTUnwrap(model.activePage)
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      model.updateElementManipulation(contact, translation: .init(x: 80, y: 60))
      let target = CollaborationTarget(kind: .page, id: before.id)
      _ = try model.store.applyCollaborationAction(.init(summary: "Concurrent source", expected: [
        .init(target: target, revision: before.agentStamp.revision)], operations: [
        .init(kind: .updateElement, target: target, id: "chart", values: ["html": .string("<p>New source</p>")])]), actor: UUID())
      model.cancelElementManipulation(contact)
      XCTAssertFalse(model.finishElementManipulation(contact, translation: .init(x: 80, y: 60)))
      await model.reloadExternalChanges()?.value
      let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
      let saved = try model.store.loadPage(before.id)
      XCTAssertEqual(saved.elements.first?.html, "<p>New source</p>")
      XCTAssertEqual(saved.elements.first?.frame, before.elements.first?.frame)
      XCTAssertNil(model.selectionSession.manipulation)
    }
  }

  func testADeletionDuringAHeldContactCannotBeAdoptedByItsLateLift() async throws {
    try await fixture { model, reference in
      let before = try XCTUnwrap(model.activePage)
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      model.updateElementManipulation(contact, translation: .init(x: 80, y: 60))
      let target = CollaborationTarget(kind: .page, id: before.id)
      _ = try model.store.applyCollaborationAction(.init(summary: "Remove held material", expected: [
        .init(target: target, revision: before.agentStamp.revision)], operations: [
        .init(kind: .removeElement, target: target, id: "chart")]), actor: UUID())
      await model.reloadExternalChanges()?.value
      _ = model.finishElementManipulation(contact, translation: .init(x: 80, y: 60))
      let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
      await model.reloadExternalChanges()?.value
      XCTAssertTrue(try model.store.loadPage(before.id).elements.isEmpty, "A stale gesture is not an intentional adoption of a deleted member")
      XCTAssertTrue(model.activePage?.elements.isEmpty == true)
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertNil(model.selectionSession.element)
      XCTAssertTrue(try NotebookStore(root: model.store.root).loadPage(before.id).elements.isEmpty)
    }
  }

  func testARecreatedIDIsNotTheMaterialAcceptedByTheOldContact() async throws {
    try await fixture { model, reference in
      var page = try XCTUnwrap(model.activePage)
      let initial = try XCTUnwrap(page.elements.first)
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      let other = UUID()
      XCTAssertTrue(page.replaceElements([], actor: other)); _ = try model.store.savePage(page)
      XCTAssertTrue(page.replaceElements([.init(id: initial.id, kind: initial.kind, frame: initial.frame,
        source: "Replacement", html: "<p>Different material</p>")], actor: other))
      _ = try model.store.savePage(page)
      _ = model.finishElementManipulation(contact, translation: .init(x: 90, y: 60))
      let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
      await model.reloadExternalChanges()?.value
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.first?.frame, initial.frame)
      XCTAssertEqual(saved.elements.first?.source, "Replacement")
    }
  }

  func testFrameCommitPublishesTheCurrentPageFrontierAndItsNewNeighbour() async throws {
    try await fixture { model, reference in
      var page = try XCTUnwrap(model.activePage)
      model.selectElement(reference)
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      let inserted = page.replaceElements(page.elements + [.init(id: "neighbour", kind: .web,
        frame: .init(x: 500, y: 100, width: 100, height: 100), source: "New", html: "<p>New</p>")], actor: UUID())
      XCTAssertTrue(inserted); _ = try model.store.savePage(page)
      XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: 30, y: 20)))
      let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(model.activePage?.agentStamp, saved.agentStamp)
      XCTAssertTrue(model.activePage?.elements.contains { $0.id == "neighbour" } == true)
    }
  }

  func testMissingElementPinsKeepTheirBoardAddress() async throws {
    try await fixture { model, _ in
      let child = try XCTUnwrap(model.createBoard(at: .zero))
      await model.finishPendingPersistence()
      let root = try XCTUnwrap(model.presence?.boardID)
      let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
      var board = before
      let element = SpatialElement(id: "same-local-id", surface: .board(root), kind: .web,
        frame: .init(x: 0, y: 0, width: 100, height: 100), worldOrigin: .zero,
        source: "chart", html: "<b>Keep me</b>", stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(board.upsertElement(element, in: root, expected: nil, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: board)
      let presence = SessionPresence(boardID: root, mode: .board, camera: .init(scale: 0.2), viewport: .init(x: 834, y: 1194))
      let state = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport,
        pinnedElements: [root: [element.id], child: [element.id]])
      XCTAssertTrue(state.missingPinnedElements.isEmpty,"An unopened child is not queried for unrelated stale pins")
      XCTAssertNil(state.hierarchy.board(child))
      XCTAssertNotNil(state.hierarchy.board(root)?.elements.first { $0.id == element.id })
    }
  }

  func testGroupMoveHandleUsesTheSameContactGateAndDoesNotBlockPencil() throws {
    let gate=NotebookInputGate()
    let window=UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller=UIViewController();window.rootViewController=controller;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let controls=NotebookSelectionControlsView(gate:gate,contextMenus:mountContextMenus(in:controller.view,gate:gate))
    controls.frame=controller.view.bounds
    controls.configure(selectionID:UUID(),frame:.init(x:100,y:150,width:240,height:180),subject:.group)
    controls.setGroupActions();controller.view.addSubview(controls);controls.layoutIfNeeded()
    let center=controls.convert(.init(x:220,y:240),to:window)
    XCTAssertTrue(window.hitTest(center,with:nil) === controls)
    XCTAssertFalse(gate.permitsSceneContact(at:center,kind:.finger));XCTAssertTrue(gate.permitsSceneContact(at:center,kind:.pencil))
    let handles=(controls.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
    XCTAssertEqual(handles.count,9)
    XCTAssertEqual(handles.filter { $0.accessibilityIdentifier == "move-element-group" }.count,1)
    controls.removeFromSuperview();XCTAssertTrue(gate.permitsSceneContact(at:center,kind:.finger))
  }

  func testCornerAdmissionLeavesPencilAndUnrelatedPaperAvailable() throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let menus = mountContextMenus(in:controller.view,gate:gate)
    let controls = NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    controls.frame = controller.view.bounds
    controls.configure(selectionID: UUID(), frame: .init(x: 100, y: 150, width: 240, height: 180))
    controller.view.addSubview(controls); controls.layoutIfNeeded()
    let corner = controls.convert(.init(x: 100, y: 150), to: window)
    XCTAssertFalse(gate.permitsSceneContact(at: corner, kind: .finger))
    XCTAssertTrue(gate.permitsSceneContact(at: corner, kind: .pencil))
    XCTAssertTrue(gate.permitsSceneContact(at: controls.convert(.init(x: 220, y: 220), to: window), kind: .finger))
    let corners = (controls.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
    XCTAssertEqual(corners.count, 8)
    for corner in corners { XCTAssertEqual(corner.accessibilityFrameInContainerSpace.size, .init(width: 44, height: 44)) }
    for edgeFrame in [CGRect(x: 0, y: 0, width: 240, height: 180), controls.bounds.insetBy(dx: 2, dy: 2)] {
      controls.configure(selectionID: UUID(), frame: edgeFrame); controls.layoutIfNeeded()
      for corner in NotebookElementResizeHandle.allCases {
        let point = controls.convert(corner.point(in: edgeFrame), to: window)
        XCTAssertTrue(window.hitTest(point, with: nil) === controls, "A screen edge cannot hide a corner under delete")
        XCTAssertTrue(gate.permitsSceneContact(at: point, kind: .pencil))
      }
    }
    controls.removeFromSuperview()
    XCTAssertTrue(gate.permitsSceneContact(at: corner, kind: .finger))
  }

  func testSmallFigureCenterKeepsBodyDragAndEveryHandleReachable() throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let menus = mountContextMenus(in:controller.view,gate:gate)
    let controls = NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    controls.frame = controller.view.bounds; controller.view.addSubview(controls)
    for size in [CGSize(width:40,height:32),.init(width:12,height:12),.init(width:64,height:100)] {
      let frame = CGRect(origin:.init(x:200,y:300),size:size)
      controls.configure(selectionID:UUID(),frame:frame); controls.layoutIfNeeded()
      let center = controls.convert(.init(x:frame.midX,y:frame.midY),to:window)
      XCTAssertFalse(window.hitTest(center,with:nil) === controls,"The center is not a hidden resize handle")
      XCTAssertTrue(gate.permitsSceneContact(at:center,kind:.finger))
      for handle in NotebookElementResizeHandle.visible(in: size) {
        let point = controls.convert(handle.point(in:frame),to:window)
        XCTAssertTrue(window.hitTest(point,with:nil) === controls)
        XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger))
      }
    }
  }

  func testHandleHitAreasLeaveNearbyPaperAvailableWithoutShrinkingAccessibility() throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let menus = mountContextMenus(in:controller.view,gate:gate)
    let controls = NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    controls.frame = controller.view.bounds; controller.view.addSubview(controls)
    let frame = CGRect(x:200,y:300,width:240,height:180)
    for mode in [NotebookSelectionSession.GeometryMode.transform,.vertices,.rounding] {
      controls.graphic = .init(shape:.triangle)
      controls.configure(selectionID:UUID(),frame:frame,mode:mode); controls.layoutIfNeeded()
      try checkHandles()
    }
    let graphic = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero),end:.init(point:.init(x:240,y:180))))
    let graph = NotebookGraphicGraph([.init(id:"line",graphic:graphic,
      frame:.init(x:200,y:300,width:240,height:180),surface:.page(UUID()),shown:true)])
    controls.graphic = graphic
    controls.configure(selectionID:UUID(),frame:frame,layout:try XCTUnwrap(graph.resolve("line").layout))
    controls.layoutIfNeeded(); try checkHandles()

    func checkHandles() throws {
      let handles = (controls.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
      XCTAssertFalse(handles.isEmpty)
      for handle in handles {
        let rect = handle.accessibilityFrameInContainerSpace
        XCTAssertEqual(rect.size,.init(width:44,height:44),"VoiceOver retains a comfortable semantic target")
        let center = CGPoint(x:rect.midX,y:rect.midY)
        let grip = controls.convert(.init(x:center.x+4,y:center.y),to:window)
        XCTAssertTrue(window.hitTest(grip,with:nil) === controls)
        XCTAssertFalse(gate.permitsSceneContact(at:grip,kind:.finger))
        let blank = controls.convert(.init(x:center.x+16,y:center.y-16),to:window)
        XCTAssertFalse(window.hitTest(blank,with:nil) === controls,"The invisible corner of a 44pt square is paper, not a handle")
        XCTAssertTrue(gate.permitsSceneContact(at:blank,kind:.finger))
      }
    }
  }

  func testGeometryHandlesDoNotMountWholeObjectActions() throws {
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let gate = NotebookInputGate(), menus = mountContextMenus(in:controller.view,gate:gate)
    let controls = NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    controls.frame = controller.view.bounds; controller.view.addSubview(controls)
    let selection = UUID(), frame = CGRect(x:80,y:240,width:160,height:120)
    controls.graphic = .init(shape:.triangle)
    for mode in [NotebookSelectionSession.GeometryMode.transform,.vertices,.rounding] {
      controls.configure(selectionID:selection,frame:frame,mode:mode)
      controls.layoutIfNeeded(); menus.view.layoutIfNeeded()
      XCTAssertFalse((controls.accessibilityElements ?? []).isEmpty,"Manipulation grips remain available")
      XCTAssertTrue(menuButtons(menus).isEmpty,"Whole-object actions appear only after hold-up")
      XCTAssertTrue(menus.view.subviews.allSatisfy(\.isHidden))
      XCTAssertFalse(menus.hasPresentedMenu)
    }
    let endpoint = NotebookContextMenuButton(type:.system), identity = endpoint.menu
    for _ in 0..<20 {
      endpoint.contents = [UIAction(title:"Круг") { _ in }]
      XCTAssertTrue(endpoint.menu === identity,"Updates cannot replace an active UIKit menu")
    }
    XCTAssertTrue(controls.subviews.allSatisfy { !($0 is UIButton) },"Grips do not own another action surface")
  }

  func testWorkspaceCardsKeepBodyInputWithoutFloatingActionsOrResizeHandles() throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let menus = mountContextMenus(in:controller.view,gate:gate)
    let controls = NotebookSelectionControlsView(gate:gate,contextMenus:menus)
    controls.frame = controller.view.bounds; controller.view.addSubview(controls)
    for kind in [WorkspaceItemKind.notebook,.document,.board] {
      for frame in [CGRect(x:100,y:220,width:260,height:360),controls.bounds.insetBy(dx:-100,dy:-100)] {
        controls.configure(selectionID:UUID(),frame:frame,subject:.item(kind))
        controls.layoutIfNeeded(); menus.view.layoutIfNeeded()
        XCTAssertTrue(menuButtons(menus).isEmpty)
        XCTAssertTrue(menus.view.subviews.allSatisfy(\.isHidden))
        XCTAssertEqual(controls.accessibilityElements?.count,0,"Cards expose no unsupported resize handles")
        let center = controls.convert(.init(x:frame.midX,y:frame.midY),to:window)
        XCTAssertTrue(gate.permitsSceneContact(at:center,kind:.finger),"Body drag remains with WorkspaceItemPose")
        XCTAssertTrue(gate.permitsSceneContact(at:center,kind:.pencil))
      }
    }
  }

  func testContextMenuReplacementRetiresOnlyItsOwnSource() throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let menus = mountContextMenus(in:controller.view,gate:gate)
    let object = UUID(), text = UUID(), button = UIButton(type:.system)
    NotebookContextMenus.configure(button,symbol:"textformat",title:"Текст",id:"text")
    menus.show(source:object,anchor:.init(x:100,y:300,width:240,height:44),in:controller.view,buttons:[UIButton(type:.system)])
    menus.show(source:text,anchor:.init(x:140,y:400,width:180,height:44),in:controller.view,buttons:[button])
    menus.view.layoutIfNeeded()
    menus.hide(source:object) // A late dismantle must not hide the new text selection.
    XCTAssertEqual(menuButtons(menus),[button]); XCTAssertEqual(menus.view.subviews.count,1)
    XCTAssertFalse(menus.frame(for:text,in:controller.view).isNull)
    let point = button.convert(.init(x:22,y:22),to:window)
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger))
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.pencil))
    XCTAssertTrue(gate.permitsSceneContact(at:.init(x:30,y:600),kind:.finger))
    menus.hide(source:text)
    XCTAssertTrue(menus.frame(for:text,in:controller.view).isNull)
    XCTAssertTrue(gate.permitsSceneContact(at:point,kind:.pencil))
  }

  func testProgrammaticallyDismissedPopoverReleasesCanvasInput() async throws {
    let gate = NotebookInputGate()
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let menus = mountContextMenus(in:controller.view,gate:gate)
    menus.presentContent(Text("Context"),at:.init(x:100,y:200))
    let presented = try XCTUnwrap(controller.presentedViewController)
    // Wait for UIKit's actual presentation, not a guessed animation duration.
    if let transition = presented.transitionCoordinator {
      await withCheckedContinuation { continuation in
        if !transition.animate(alongsideTransition:nil,completion:{ _ in continuation.resume() }) {
          continuation.resume()
        }
      }
    }
    XCTAssertTrue(menus.hasPresentedMenu)
    XCTAssertFalse(gate.permitsSceneContact(at:.init(x:30,y:600),kind:.finger))
    await withCheckedContinuation { continuation in
      presented.dismiss(animated:false) { continuation.resume() }
    }
    // Keep the old controller alive: availability follows presentation, not ARC.
    XCTAssertNil(presented.presentingViewController)
    XCTAssertFalse(menus.hasPresentedMenu)
    XCTAssertTrue(gate.permitsSceneContact(at:.init(x:30,y:600),kind:.finger))
    XCTAssertTrue(gate.permitsSceneContact(at:.init(x:30,y:600),kind:.pencil))
    menus.presentContent(Text("Next context"),at:.init(x:100,y:200))
    XCTAssertTrue(menus.hasPresentedMenu)
    menus.dismissPresentedContent()
  }

  private func mountContextMenus(in host: UIView, gate: NotebookInputGate) -> NotebookContextMenus {
    let menus = NotebookContextMenus(); menus.use(gate)
    menus.view.frame = host.bounds; host.addSubview(menus.view)
    return menus
  }
  private func menuButtons(_ menus: NotebookContextMenus) -> [UIButton] {
    func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    return descendants(menus.view).compactMap { $0 as? UIButton }.filter { !$0.isHidden }
  }

  private func fixture(_ body: (NotebookAppModel, EditableElementReference) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([.init(id: "chart", kind: .web, frame: .init(x: 100, y: 80, width: 200, height: 160), source: "source", html: "<p>Same material</p>")], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    try await body(model, .page(pageID: page.id, elementID: "chart"))
  }
}
