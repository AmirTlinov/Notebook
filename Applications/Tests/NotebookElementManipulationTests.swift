import NotebookCore
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class NotebookElementManipulationTests: XCTestCase {
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
      let original = try XCTUnwrap(model.presence)
      let notebook = try XCTUnwrap(original.selectedItemID)
      // A visible closed board legitimately contributes its portal header.
      // Keep this unrelated board outside coverage and outside the selection.
      let child = try XCTUnwrap(model.createBoard(at: .init(x: 100_000, y: 100_000)))
      await model.finishPendingPersistence()
      let root = try XCTUnwrap(model.presence?.boardID)
      let before = try model.store.readTransaction { store in
        try store.loadBoard(items: store.loadIndex().items)
      }
      var board = before
      let element = SpatialElement(id: "same-local-id", surface: .board(root), kind: .web,
        frame: .init(x: 0, y: 0, width: 100, height: 100), worldOrigin: .zero,
        source: "chart", html: "<b>Keep me</b>", stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(board.upsertElement(element, in: root, expected: nil, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: board)
      let presence = SessionPresence(boardID: root, mode: .board, camera: .init(scale: 0.2), viewport: .init(x: 834, y: 1194),
        selectedItemID: notebook, notebookPageID: original.notebookPageID)
      let state = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport,
        pinnedElements: [root: [element.id], child: [element.id]])
      XCTAssertTrue(state.missingPinnedElements.isEmpty,"An unopened child is not queried for unrelated stale pins")
      XCTAssertNil(state.hierarchy.board(child))
      XCTAssertNil(state.coverage[child], "Foreign pins must not admit a child content window")
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
    controller.view.addSubview(controls);controls.layoutIfNeeded()
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
    menus.registerSelectionActions(source:object,selection:object,anchor:.init(x:100,y:300,width:240,height:44),in:controller.view,
      primary:[],secondary:[UIAction(title:"Подпись фигуры") { _ in }],destructive:[],enabled:true)
    menus.requestSelectionMenu(object,at:.init(x:150,y:320))
    let more=try XCTUnwrap(menuButtons(menus).compactMap { $0 as? NotebookContextMenuButton }.first)
    menus.show(source:text,anchor:.init(x:140,y:400,width:180,height:44),in:controller.view,buttons:[button])
    menus.view.layoutIfNeeded()
    more.onMenuDismiss?() // The old native menu finishes after text has acquired its controls.
    menus.hide(source:object) // A late dismantle must not hide the new text selection.
    XCTAssertEqual(menuButtons(menus),[button])
    let surface=try XCTUnwrap(menus.view.subviews.first { $0.accessibilityIdentifier == "notebook-context-menu" })
    XCTAssertFalse(surface.isHidden)
    let point = button.convert(.init(x:22,y:22),to:window)
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger))
    XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.pencil))
    XCTAssertTrue(gate.permitsSceneContact(at:.init(x:30,y:600),kind:.finger))
    menus.hide(source:text)
    XCTAssertTrue(surface.isHidden)
    XCTAssertTrue(gate.permitsSceneContact(at:point,kind:.pencil))
  }

  func testRequestedActionsFollowOffsetGeometryAndLeaveTheCanvasAvailable() throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where:\.isKeyWindow)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    let gate=NotebookInputGate(),menus=mountContextMenus(in:controller.view,gate:gate)
    menus.view.frame=controller.view.bounds.insetBy(dx:20,dy:60)
    let geometry=UIView(frame:controller.view.bounds.offsetBy(dx:45,dy:90))
    controller.view.insertSubview(geometry,belowSubview:menus.view)
    let selection=UUID(),source=UUID()
    var copies=0
    menus.selectionActions = { _,_ in NotebookContextMenus.clipboardActions(cut:nil,copy:{ copies += 1 },paste:nil) }
    let remove=UIAction(title:"Удалить",image:UIImage(systemName:"trash"),identifier:.init("remove"),attributes:.destructive) { _ in }
    let surface=try XCTUnwrap(menus.view.subviews.first { $0.accessibilityIdentifier == "notebook-context-menu" })
    func register(_ frame:CGRect) {
      menus.registerSelectionActions(source:source,selection:selection,anchor:frame,in:geometry,
        primary:[],secondary:[],destructive:[remove],enabled:true)
      menus.view.layoutIfNeeded()
    }
    let frames=[CGRect(x:300,y:10,width:120,height:100),
      CGRect(x:20,y:menus.view.bounds.height-200,width:160,height:100)]
    for frame in frames {
      register(frame)
      // The earlier touch may be far away after a new camera projection.
      menus.requestSelectionMenu(selection,at:.init(x:5,y:5))
      menus.view.layoutIfNeeded()
      let selected=geometry.convert(frame,to:menus.view),panel=surface.frame
      XCTAssertFalse(surface.isHidden)
      XCTAssertTrue(menus.view.bounds.contains(panel))
      XCTAssertFalse(panel.intersects(selected))
      XCTAssertGreaterThan(min(panel.maxX,selected.maxX)-max(panel.minX,selected.minX),0)
      let gap=max(selected.minY-panel.maxY,panel.minY-selected.maxY)
      XCTAssertEqual(gap,14,accuracy:0.5,"Actions stay adjacent to the current material, in the host's coordinate space")
      let body=geometry.convert(CGPoint(x:frame.midX,y:frame.midY),to:window)
      XCTAssertTrue(gate.permitsSceneContact(at:body,kind:.finger),"An open row must allow the next direct drag")
      XCTAssertTrue(gate.permitsSceneContact(at:body,kind:.pencil))
      let control=surface.convert(CGPoint(x:surface.bounds.midX,y:surface.bounds.midY),to:window)
      XCTAssertFalse(gate.permitsSceneContact(at:control,kind:.finger))
      XCTAssertFalse(menus.blocksCanvasInput)
    }
    menus.detachSelectionActions(source:source)
    XCTAssertTrue(surface.isHidden,"An unmounted geometry lease cannot leave stale clickable controls")
    register(frames[0])
    XCTAssertFalse(surface.isHidden,"The same selection recovers its requested actions after repaint")
    let copy=try XCTUnwrap(menuButtons(menus).first { $0.accessibilityIdentifier == "selection-copy" })
    copy.sendActions(for:.touchUpInside)
    XCTAssertEqual(copies,1)
    XCTAssertFalse(menus.hasPresentedMenu)
    menus.requestSelectionMenu(selection,at:.zero)
    menus.hide(source:source)
    register(frames[1])
    XCTAssertTrue(surface.isHidden,"Finishing a manipulation must not resurrect the old requested row")
    menus.uninstall()
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

  func testDeferredMenuCannotReturnAfterItsContactOrSelectionEnds() async throws {
    try await fixture { model,reference in
      let window=UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
      let controller=UIViewController();window.rootViewController=controller;window.makeKeyAndVisible()
      defer { window.isHidden=true;window.rootViewController=nil }
      let menus=mountContextMenus(in:controller.view,gate:model.inputGate),source=UUID()
      model.selectElement(reference);menus.updateSelection(model)
      let selection=model.selectionSession.id
      var requests=0
      menus.selectionActions = { _,_ in requests += 1;return [] }
      @MainActor func register(enabled:Bool) {
        menus.registerSelectionActions(source:source,selection:selection,anchor:.init(x:100,y:200,width:100,height:100),
          in:controller.view,primary:[UIAction(title:"Редактировать") { _ in }],secondary:[],destructive:[],enabled:enabled)
      }
      register(enabled:false);menus.requestSelectionMenu(selection,at:.init(x:150,y:250))
      let contact=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
      menus.updateSelection(model);model.cancelElementManipulation(contact)
      register(enabled:true)
      XCTAssertEqual(requests,0,"A deferred menu must not reopen after its contact became a drag")
      XCTAssertFalse(menus.hasPresentedMenu)
      register(enabled:false);menus.requestSelectionMenu(selection,at:.init(x:150,y:250))
      model.endSurfaceEditing();menus.updateSelection(model)
      register(enabled:true)
      XCTAssertEqual(requests,0,"Late geometry cannot reinstall actions for an ended editing target")
      XCTAssertFalse(menus.hasPresentedMenu)
      menus.uninstall()
    }
  }

  func testToolbarActionsUseTheirNativeAnchorAndRetireWithTheirPresentedSheet() async throws {
    try await fixture { model,reference in
      let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let previous=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene)
      let menus=NotebookContextMenus(),destination=clipboardDestination(reference,model:model)
      model.selectElement(reference)
      let controller=UIHostingController(rootView:ZStack(alignment:.topLeading) {
        NotebookContextMenuHost(owner:menus,gate:model.inputGate)
          .frame(maxWidth:.infinity,maxHeight:.infinity)
        NotebookActionsMenu(destination:destination).padding(.leading,80).padding(.top,100)
      }.environment(model).environment(\.notebookContextMenus,menus))
      window.rootViewController=controller;window.makeKeyAndVisible()
      defer { menus.uninstall();window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
      @MainActor func descendants(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(descendants) }
      @MainActor func actionsButton()->UIButton? {
        descendants(window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "notebook-actions-open" }
      }
      try await assertUX("toolbar-actions-anchor-mounted",since:.now,budget:.seconds(2),window:window) {
        actionsButton()?.window === window && actionsButton()?.bounds.size == CGSize(width:44,height:44)
      }
      let button=try XCTUnwrap(actionsButton())
      button.sendActions(for:.touchUpInside)
      let presented=try XCTUnwrap(controller.presentedViewController)
      await settlePresentation(presented)
      XCTAssertTrue(presented.popoverPresentationController?.sourceView === button)
      XCTAssertEqual(presented.popoverPresentationController?.sourceRect,button.bounds)
      XCTAssertEqual(presented.popoverPresentationController?.permittedArrowDirections,.up)
      XCTAssertTrue(button.isSelected)
      XCTAssertTrue(menus.blocksCanvasInput)
      // A composition sheet is presented by this content controller. Retiring
      // its captured context must close the whole UIKit presentation chain.
      let sheet=UIHostingController(rootView:Text("Composition"));sheet.modalPresentationStyle = .pageSheet
      presented.present(sheet,animated:false)
      await settlePresentation(sheet)
      XCTAssertTrue(sheet.presentingViewController === presented)
      model.clearSelection()
      try await assertUX("toolbar-context-retires-parent-and-sheet",since:.now,budget:.seconds(2),window:window) {
        presented.presentingViewController == nil && sheet.presentingViewController == nil
          && !menus.hasPresentedMenu && !button.isSelected
      }
      XCTAssertTrue(model.inputGate.permitsSceneContact(at:.init(x:30,y:600),kind:.finger))
      XCTAssertTrue(model.inputGate.permitsSceneContact(at:.init(x:30,y:600),kind:.pencil))
      button.sendActions(for:.touchUpInside)
      let replacement=try XCTUnwrap(controller.presentedViewController)
      await settlePresentation(replacement)
      XCTAssertFalse(replacement === presented)
      XCTAssertTrue(button.isSelected)
      menus.detachContentAnchor(button)
      try await assertUX("toolbar-anchor-detach-completes",since:.now,budget:.seconds(2),window:window) {
        replacement.presentingViewController == nil && !menus.hasPresentedMenu
      }
      XCTAssertNil(replacement.presentingViewController)
      XCTAssertFalse(button.isSelected)
    }
  }

  func testPresentedControlsKeepTheirIntentThroughDownAndLift() async throws {
    try await fixture { model,reference in
      let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      let previous=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene)
      let controller=UIViewController();window.rootViewController=controller;window.makeKeyAndVisible()
      let menus=mountContextMenus(in:controller.view,gate:model.inputGate)
      let owner=WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn:false,isEnabled:true,inputGate:model.inputGate,
        onCamera:{ _ in XCTFail("A presented control owns its contact") },onUndo:{},onRedo:{})
      owner.install(on:window,inside:menus.view)
      defer { owner.uninstall();menus.uninstall();window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
      let observer=try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
      model.selectElement(reference)
      var captured:NotebookContextMenus.PresentationIntent?
      var hostedButton:UIButton?
      menus.presentContent(in:model,at:.init(x:200,y:300)) { intent in
        captured=intent
        return PresentedControlButton { hostedButton=$0 }
          .frame(width:160,height:44).padding(20).frame(width:200,height:100,alignment:.topLeading)
      }
      let intent=try XCTUnwrap(captured),presented=try XCTUnwrap(controller.presentedViewController)
      await settlePresentation(presented)
      var callbacks=0
      @MainActor func press(_ button:UIButton,in parent:UIViewController) async throws {
        parent.view.layoutIfNeeded()
        button.addAction(UIAction { _ in
          guard menus.isCurrent(intent,in:model) else { return }
          callbacks += 1
        },for:.touchUpInside)
        let touch=PresentedControlTouch(window:window,view:button)
        let contact=model.inputGate.acceptedContactGeneration,navigation=model.navigationGeneration
        XCTAssertTrue(owner.gestureRecognizer(observer,shouldReceive:touch))
        XCTAssertFalse(sceneReceives(touch,inside:menus.view))
        observer.touchesBegan([touch],with:UIEvent())
        XCTAssertTrue(model.inputGate.isActive)
        XCTAssertEqual(model.inputGate.admittedFingerContactCount,1)
        XCTAssertEqual(model.inputGate.acceptedContactGeneration,contact)
        XCTAssertEqual(model.navigationGeneration,navigation)
        menus.updateSelection(model) // The same native update that previously dismissed Back on down.
        XCTAssertTrue(menus.isCurrent(intent,in:model))
        XCTAssertNotNil(presented.presentingViewController)
        var idleReleased=false
        model.inputGate.performAfterIdle { idleReleased=true }
        XCTAssertFalse(idleReleased,"The presented contact keeps its physical lifetime barrier")
        let previousCallbacks=callbacks
        observer.touchesEnded([touch],with:UIEvent())
        button.sendActions(for:.touchUpInside)
        XCTAssertEqual(callbacks,previousCallbacks+1,"The accepted control action survives its own down event")
        XCTAssertEqual(model.inputGate.admittedFingerContactCount,0)
        try await assertUX("presented-control-lift-releases-barrier",since:.now,budget:.seconds(2),window:window) { idleReleased }
        observer.reset()
      }
      try await press(try XCTUnwrap(hostedButton),in:presented)
      let sheet=UIViewController();sheet.modalPresentationStyle = .pageSheet
      let sheetButton=UIButton(frame:.init(x:20,y:20,width:160,height:44))
      sheet.view.addSubview(sheetButton)
      presented.present(sheet,animated:false);await settlePresentation(sheet)
      XCTAssertTrue(sheet.presentingViewController === presented)
      try await press(sheetButton,in:sheet)
      XCTAssertEqual(callbacks,2)
      XCTAssertTrue(menus.isCurrent(intent,in:model))
    }
  }

  func testLateClipboardCompositionCannotReplaceANewerMenuOrCloseItsPresentation() async throws {
    try await fixture { model,reference in
      let window=UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
      let controller=UIViewController();window.rootViewController=controller;window.makeKeyAndVisible()
      let menus=mountContextMenus(in:controller.view,gate:model.inputGate),reader=ClipboardReadBarrier()
      defer { reader.cancel();menus.uninstall();window.isHidden=true;window.rootViewController=nil }
      model.selectElement(reference)
      var oldIntent:NotebookContextMenus.PresentationIntent?
      menus.presentContent(in:model,at:.init(x:100,y:200)) { intent in oldIntent=intent;return Text("Old menu") }
      let originalController=try XCTUnwrap(controller.presentedViewController)
      await settlePresentation(originalController)
      let original=try XCTUnwrap(oldIntent),destination=clipboardDestination(reference,model:model)
      var callbacks=0
      let task=try XCTUnwrap(menus.pasteClipboard([],at:destination,in:model,presentation:original,
        read:{ _,_,work in try await reader.read(work) }) { intent,_ in
          callbacks += 1
          menus.presentContent(for:intent,in:model,at:.init(x:100,y:200)) { _ in Text("Stale composition") }
        })
      await reader.waitUntilStarted()
      model.clearSelection()
      var supersededIntent:NotebookContextMenus.PresentationIntent?
      menus.presentContent(in:model,at:.init(x:120,y:210)) { intent in supersededIntent=intent;return Text("Superseded menu") }
      var nextIntent:NotebookContextMenus.PresentationIntent?
      menus.presentContent(in:model,at:.init(x:160,y:220)) { intent in nextIntent=intent;return Text("New menu") }
      let next=try XCTUnwrap(nextIntent)
      XCTAssertFalse(menus.isCurrent(try XCTUnwrap(supersededIntent),in:model))
      try await assertUX("latest-menu-follows-dismissal-completion",since:.now,budget:.seconds(2),window:window) {
        originalController.presentingViewController == nil && controller.presentedViewController != nil
          && controller.presentedViewController !== originalController && menus.isCurrent(next,in:model)
      }
      let presented=try XCTUnwrap(controller.presentedViewController)
      await settlePresentation(presented)
      reader.finish(.composition("late structured source"))
      await task.value
      XCTAssertEqual(callbacks,0)
      XCTAssertTrue(controller.presentedViewController === presented)
      menus.finishContentPresentation(original) // A delayed old close callback has the same owner gate.
      XCTAssertTrue(menus.isCurrent(next,in:model))
      XCTAssertTrue(controller.presentedViewController === presented)
    }
  }

  func testNewPasteIntentOwnsItsErrorAndRejectsAnOlderComposition() async throws {
    try await fixture { model,reference in
      let menus=NotebookContextMenus(),reader=ClipboardReadBarrier()
      defer { reader.cancel();menus.uninstall() }
      model.selectElement(reference)
      let presentation=menus.beginContentPresentation(in:model),destination=clipboardDestination(reference,model:model)
      var results:[String]=[]
      let older=try XCTUnwrap(menus.pasteClipboard([],at:destination,in:model,presentation:presentation,
        read:{ _,_,work in try await reader.read(work) }) { _,_ in results.append("old") })
      await reader.waitUntilStarted()
      let latest=menus.pasteClipboard([],at:destination,in:model,presentation:presentation) { _,outcome in
        if case .failed = outcome { results.append("latest error") } else { results.append("unexpected") }
      }
      XCTAssertNil(latest,"Synchronous capacity refusal starts no source worker")
      reader.finish(.composition("older composition"));await older.value
      XCTAssertEqual(results,["latest error"],"The latest read owns transient completion, including capacity refusal")
      XCTAssertTrue(menus.isCurrent(presentation,in:model))
    }
  }

  func testPasteReservesBeforeItsTaskStartsAndCannotShowAStaleAdmissionCue() async throws {
    try await fixture { model,reference in
      let menus=NotebookContextMenus()
      defer { menus.uninstall() }
      model.selectElement(reference)
      let original=menus.beginContentPresentation(in:model),destination=clipboardDestination(reference,model:model)
      var callbacks=0
      let task=try XCTUnwrap(menus.pasteClipboard([],at:destination,in:model,presentation:original) { _,_ in callbacks += 1 })
      XCTAssertThrowsError(try model.beginClipboardWork(),"The first gesture already owns its 192 MiB source credit before returning")
      let remaining=try XCTUnwrap(model.reserveClipboardWork(maximumCost:.init(payloadBytes:64 * 1_024 * 1_024)))
      defer { model.releaseClipboardWork(remaining) }
      let current=menus.beginContentPresentation(in:model)
      model.showCue("Current menu")
      // No actor suspension occurred before replacement. The old task starts
      // with full admission, and must reuse its gesture lease without a new cue.
      await task.value
      XCTAssertEqual(callbacks,0)
      XCTAssertEqual(model.actionCue,"Current menu")
      XCTAssertTrue(menus.isCurrent(current,in:model))
    }
  }

  func testClipboardErrorCannotReturnAfterItsDestinationOrContactChanges() async throws {
    try await fixture { model,reference in
      for changesDestination in [true,false] {
        let menus=NotebookContextMenus(),reader=ClipboardReadBarrier()
        defer { reader.cancel();menus.uninstall() }
        if changesDestination {
          // Cover presentation admits a document-page position. Page mode
          // fixes that index at zero, so it cannot exercise this context change.
          let presence=try XCTUnwrap(model.presence)
          model.updatePresence(.init(boardID:presence.boardID,mode:.cover,camera:presence.camera,
            viewport:presence.viewport,focusedItemID:presence.focusedItemID,openProgress:presence.openProgress,
            documentPageIndex:presence.documentPageIndex,selectedItemID:presence.selectedItemID,
            notebookPageID:presence.notebookPageID),settled:false)
        }
        model.selectElement(reference)
        let intent=menus.beginContentPresentation(in:model),destination=clipboardDestination(reference,model:model)
        let cue=model.actionCue
        var failures=0
        let task=try XCTUnwrap(menus.pasteClipboard([],at:destination,in:model,presentation:intent,
          read:{ _,_,work in try await reader.read(work) }) { _,_ in failures += 1;model.showCue("stale error") })
        await reader.waitUntilStarted()
        if changesDestination {
          let presence=try XCTUnwrap(model.presence)
          let replacement=SessionPresence(boardID:presence.boardID,mode:presence.mode,camera:presence.camera,
            viewport:presence.viewport,focusedItemID:presence.focusedItemID,openProgress:presence.openProgress,
            documentPageIndex:presence.documentPageIndex+1,selectedItemID:presence.selectedItemID,
            notebookPageID:presence.notebookPageID)
          XCTAssertTrue(replacement.isValid)
          model.updatePresence(replacement,settled:false)
          XCTAssertEqual(model.presence,replacement)
        } else { model.inputGate.notifyAcceptedContact() }
        reader.fail(CollaborationError("clipboard_failure","Late provider failure"))
        await task.value
        XCTAssertEqual(failures,0)
        XCTAssertEqual(model.actionCue,cue)
        XCTAssertFalse(menus.isCurrent(intent,in:model))
        // The actual failed source call has ended; settle its provisional lease
        // before the next independent case enters the same model admission.
        reader.releaseCredit(in:model)
      }
    }
  }

  func testClipboardFragmentStillCommitsToItsCapturedPageAfterTheMenuLeaves() async throws {
    try await fixture { model,reference in
      let menus=NotebookContextMenus(),reader=ClipboardReadBarrier()
      defer { reader.cancel();menus.uninstall() }
      model.selectElement(reference)
      let intent=menus.beginContentPresentation(in:model),destination=clipboardDestination(reference,model:model)
      let id="accepted-paste-"+UUID().uuidString.lowercased()
      let fragment=NotebookPasteFragment(elements:[
        .init(id:id,kind:.nativeText,frame:.init(x:0,y:0,width:120,height:44),source:"Captured page",html:"")],
        size:.init(x:120,y:44))
      var callbacks=0
      let task=try XCTUnwrap(menus.pasteClipboard([],at:destination,in:model,presentation:intent,
        read:{ _,_,work in try await reader.read(work) }) { _,_ in callbacks += 1 })
      await reader.waitUntilStarted()
      menus.finishContentPresentation(intent);model.clearSelection()
      reader.finish(.fragment(fragment));await task.value
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
      XCTAssertNotNil(try model.store.loadPage(destination.target.id).element(id:id))
      XCTAssertEqual(callbacks,0,"Acceptance persists while close/error presentation belongs to the retired menu")
    }
  }

  private func settlePresentation(_ controller:UIViewController) async {
    if let transition=controller.transitionCoordinator {
      await withCheckedContinuation { continuation in
        if !transition.animate(alongsideTransition:nil,completion:{ _ in continuation.resume() }) { continuation.resume() }
      }
    }
  }
  private func clipboardDestination(_ reference:EditableElementReference,model:NotebookAppModel) -> NotebookPasteDestination {
    guard case .page(let id,_)=reference else { preconditionFailure("The fixture owns a page") }
    return .init(target:.init(kind:.page,id:id),title:"Лист",center:.init(x:400,y:500),
      availableSize:.init(x:model.notebookPageSize.width,y:model.notebookPageSize.height),worldOrigin:nil)
  }
  @MainActor private final class ClipboardReadBarrier {
    private var continuation:CheckedContinuation<NotebookClipboard.Content,Error>?
    private var started:CheckedContinuation<Void,Never>?
    private var reservation:NotebookPersistenceAdmission.Reservation?
    func read(_ work:NotebookClipboardWorkLease) async throws -> NotebookClipboard.Content {
      reservation=work.reservation
      defer { withExtendedLifetime(work) {} }
      let content=try await withCheckedThrowingContinuation { continuation in
        self.continuation=continuation;started?.resume();started=nil
      }
      return content
    }
    func waitUntilStarted() async {
      if continuation != nil { return }
      await withCheckedContinuation { started=$0 }
    }
    func finish(_ content:NotebookClipboard.Content) { continuation?.resume(returning:content);continuation=nil }
    func fail(_ error:Error) { continuation?.resume(throwing:error);continuation=nil }
    func cancel() { fail(CancellationError()) }
    func releaseCredit(in model:NotebookAppModel) {
      if let reservation { model.releaseClipboardWork(reservation);self.reservation=nil }
    }
  }

  func testStylePaletteKeepsAcceptedEditsAcrossRepaintAndRetiresWithSelection() async throws {
    try await fixture { model, reference in
      var page = try XCTUnwrap(model.activePage)
      page.replaceElements([.init(id:reference.elementID,kind:.graphic,
        frame:.init(x:100,y:100,width:180,height:140),source:"",html:"",graphic:NotebookGraphic())],actor:model.actorID)
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      let window = try await mountNotebookScene(model)
      model.selectElement(reference)
      @MainActor func descendants(_ view:UIView)->[UIView] { [view]+view.subviews.flatMap(descendants) }
      @MainActor func controls()->NotebookSelectionControlsView? {
        descendants(window).compactMap { $0 as? NotebookSelectionControlsView }.first
      }
      try await assertUX("style-actions-installed",since:.now,budget:.seconds(2),window:window) {
        controls()?.primaryActions.contains { $0.title == "Оформление фигуры" } == true
      }
      let menu = try XCTUnwrap(descendants(window).compactMap { ($0 as? NotebookContextMenus.HostView)?.owner }.first)
      XCTAssertEqual(menu.view.convert(menu.view.bounds,to:window),window.bounds,
        "The real SwiftUI action host uses the same full viewport as the selected geometry")
      let action = try XCTUnwrap(controls()?.primaryActions.first { $0.title == "Оформление фигуры" } as? UIAction)
      UIButton().sendAction(action)
      let palette = try XCTUnwrap(window.rootViewController?.presentedViewController as? NotebookElementStyleController)
      if let transition=palette.transitionCoordinator {
        await withCheckedContinuation { continuation in
          if !transition.animate(alongsideTransition:nil,completion:{ _ in continuation.resume() }) { continuation.resume() }
        }
      }
      let blue = try XCTUnwrap(descendants(palette.view).first { $0.accessibilityIdentifier == "element-color-11" } as? UIButton)
      blue.sendActions(for:.touchUpInside)
      try await assertUX("palette-keeps-first-edit",since:.now,budget:.seconds(2),window:window) {
        let current=try XCTUnwrap(model.activePage)
        return blue.accessibilityTraits.contains(.selected) && model.pagePresentations.isPresented(current)
      }
      XCTAssertTrue(window.rootViewController?.presentedViewController === palette)
      XCTAssertTrue(menu.hasPresentedMenu)
      let width = try XCTUnwrap(descendants(palette.view).first { $0.accessibilityIdentifier == "element-width" } as? UISlider)
      width.value=2; width.sendActions(for:.valueChanged)
      let dash = try XCTUnwrap(descendants(palette.view).first { $0.accessibilityIdentifier == "element-dash-1" } as? UIButton)
      dash.sendActions(for:.touchUpInside)
      let saved = await model.finishPendingPersistence();XCTAssertTrue(saved)
      XCTAssertTrue(window.rootViewController?.presentedViewController === palette)
      let accepted = try XCTUnwrap(model.graphicElement(reference)?.style)
      XCTAssertEqual(accepted.strokeWidth,4)
      XCTAssertEqual(accepted.stroke,.init(red:0.22,green:0.40,blue:0.89))
      XCTAssertNotEqual(accepted.dash,.solid)
      let selection=model.selectionSession.id
      model.endSurfaceEditing()
      XCTAssertEqual(model.selectionSession.id,selection,"A context transition can retain the selection identifier")
      try await assertUX("palette-retires-with-editing-target",since:.now,budget:.seconds(2),window:window) {
        palette.presentingViewController == nil && !menu.hasPresentedMenu
      }
      palette.updateStyle { $0.strokeWidth=19 }
      XCTAssertEqual(model.graphicElement(reference)?.style,accepted,"A retained editor cannot write through its ended selection")
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:reference.elementID)?.graphic?.style,accepted)
      model.selectElement(reference)
      try await assertUX("palette-next-selection-ready",since:.now,budget:.seconds(2),window:window) {
        controls()?.primaryActions.contains { $0.title == "Оформление фигуры" } == true
      }
      let reopen = try XCTUnwrap(controls()?.primaryActions.first { $0.title == "Оформление фигуры" } as? UIAction)
      UIButton().sendAction(reopen)
      let replacementPalette = try XCTUnwrap(window.rootViewController?.presentedViewController as? NotebookElementStyleController)
      if let transition=replacementPalette.transitionCoordinator {
        await withCheckedContinuation { continuation in
          if !transition.animate(alongsideTransition:nil,completion:{ _ in continuation.resume() }) { continuation.resume() }
        }
      }
      var changed = try model.store.loadPage(page.id)
      let material = try XCTUnwrap(changed.element(id:reference.elementID)),peer=UUID()
      changed.replaceElements([],actor:peer);try model.store.savePage(changed)
      changed.replaceElements([material],actor:peer);try model.store.savePage(changed)
      await model.reloadExternalChanges()?.value
      try await assertUX("palette-retires-with-material-identity",since:.now,budget:.seconds(2),window:window) {
        replacementPalette.presentingViewController == nil
      }
      replacementPalette.updateStyle { $0.strokeWidth=23 }
      XCTAssertEqual(model.graphicElement(reference)?.style,accepted,"A recreated ID cannot adopt the previous material's editor")
    }
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

private struct PresentedControlButton: UIViewRepresentable {
  let created:(UIButton)->Void
  func makeUIView(context:Context)->UIButton {
    let button=UIButton(type:.system)
    created(button)
    return button
  }
  func updateUIView(_ button:UIButton,context:Context) {}
}

@MainActor private final class PresentedControlTouch: UITouch {
  private let sourceWindow:UIWindow
  private let sourceView:UIView
  private let point:CGPoint
  init(window:UIWindow,view:UIView) {
    sourceWindow=window;sourceView=view
    point=view.convert(.init(x:view.bounds.midX,y:view.bounds.midY),to:window)
    super.init()
  }
  override var type:UITouch.TouchType { .direct }
  override var window:UIWindow? { sourceWindow }
  override var view:UIView? { sourceView }
  override func location(in view:UIView?)->CGPoint { view?.convert(point,from:sourceWindow) ?? point }
}
