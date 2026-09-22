import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicModelTests: XCTestCase {
  func testImmediateUndoWaitsForVisibleShapeCommandInsteadOfUndoingOlderInk() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("graphic-immediate-undo-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let started = await model.finishPendingPersistence()
    XCTAssertTrue(started)
    let pageID=try XCTUnwrap(model.activePage?.id),actor=model.actorID
    let samples=(0...48).map { index -> SpatialInkSample in
      let angle=Double(index)/48*2*Double.pi
      return .init(point:.init(x:150+60*cos(angle),y:150+60*sin(angle)),timeOffset:Double(index)/100,
        width:2,opacity:1,force:1,azimuth:0,altitude:.pi/2)
    }
    let stroke=PageInkAction(tool:.pen,samples:samples)
    let page=try model.store.loadPage(pageID)
    let change=try page.prepareInkChange(.append(stroke),stamp:.init(counter:1,actor:actor))
    _=try model.store.commitPageInk(pageID:pageID,command:.append(try XCTUnwrap(change.drawing.action(id:stroke.id)),
      baseStamp:change.baseStamp,stamp:change.stamp))
    await model.reloadExternalChanges()?.value
    let blocker=try NotebookSQLWriteBlocker(store:model.store);defer { try? blocker.release() }
    let fit=NotebookQuickShapeFit(frame:.init(x:90,y:90,width:120,height:120),sampleCount:49)
    model.acceptQuickShape(fit,pageID:pageID,stroke:stroke)
    XCTAssertTrue(model.graphicCommandPending)
    model.undoLastSurfaceAction()
    try blocker.release()
    let persisted = await model.finishPendingPersistence()
    XCTAssertTrue(persisted)
    let receipts=try model.store.collaborationActions(afterID:nil).filter {
      $0.action.operations.contains { $0.kind == .convertInkToElement }
    }
    let conversion=try XCTUnwrap(receipts.first)
    XCTAssertNotNil(conversion.undo,"Immediate Undo must join and reverse the visible shape command")
    let restored = try model.store.loadPage(pageID)
    XCTAssertTrue(restored.graphicPresentation.geometryIDs.isEmpty)
    XCTAssertEqual(restored.elements.first?.graphic?.representation,.ink)
    XCTAssertTrue(try restored.inkDrawing().action(id:stroke.id)?.isActive == true,
      "Undo must not fall through to the preceding raw stroke")
  }

  func testConsecutiveHeldShapesKeepBothIdentitiesWhileThePreviousCommandWaits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-queue-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let pageID = try XCTUnwrap(model.activePage?.id)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let writer=try NotebookSQLWriteBlocker(store:model.store);defer { try? writer.release() }
    let fence = UUID()
    XCTAssertTrue(model.inputGate.beginPencilAction(source: fence))
    defer { model.inputGate.endPencilAction(source: fence) }
    var ids: [String] = []
    for index in 0..<2 {
      let fit = NotebookQuickShapeFit(frame: .init(x: 100 + Double(index)*180, y: 100, width: 100, height: 80), sampleCount: 49)
      let stroke = PageInkAction(tool: .pen, samples: (0...48).map { sample in
        let angle = Double(sample)/48 * 2 * Double.pi
        return .init(point: .init(x: fit.frame.x + 50 + 50*cos(angle), y: 140 + 40*sin(angle)),
          timeOffset: Double(sample)/100, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
      })
      let object = NotebookWorkingGraphic(strokeID: stroke.id, fit: fit, surface: .page(pageID), color: .black, width: 2)
      ids.append(object.id)
      model.updateWorkingGraphic(object, strokeID: stroke.id)
      let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
      _ = model.acceptDrawingAction(stroke, pageID: pageID, stamp: stamp, quickShape: fit)
    }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(model.workingGraphics.map(\.id), ids)
    XCTAssertTrue(model.workingGraphics.allSatisfy { $0.accepted && $0.publicationCursor == nil })
    model.inputGate.endPencilAction(source: fence)
    try writer.release()
    let closed = await model.shutdown(); XCTAssertTrue(closed)
    let reopened = NotebookStore(root: root), page = try reopened.loadPage(pageID)
    XCTAssertEqual(Set(page.elements.map(\.id)), Set(ids))
    XCTAssertEqual(try reopened.collaborationActions(afterID: nil).filter {
      $0.action.operations.contains { $0.kind == .convertInkToElement }
    }.count, 2)
  }

  func testPageShapeUsesNativeCommandsAgentEditsAndSequentialUndo() async throws { try await scenario(onBoard: false) }
  func testBoardShapeUsesNativeCommandsAgentEditsAndSequentialUndo() async throws { try await scenario(onBoard: true) }
  func testPageShapeSequentialUndoSurvivesColdModelReopening() async throws { try await scenario(onBoard: false, reopens: true) }
  func testBoardShapeSequentialUndoSurvivesColdModelReopening() async throws { try await scenario(onBoard: true, reopens: true) }

  func testAcceptedMoveKeepsItsGeometryWhileTheWriterAndAnOlderSceneArePending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-handoff-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let pageID = try XCTUnwrap(model.activePage?.id), target = CollaborationTarget(kind: .page, id: pageID)
    let reference = EditableElementReference.page(pageID: pageID, elementID: "circle")
    let store = model.store
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    _ = try store.applyCollaborationAction(.init(summary: "Circle", expected: [
      .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: "circle", values: ["kind": .string("graphic"), "source": .string(""),
          "frame": .encode(PageRect(x: 100, y: 100, width: 100, height: 100)), "graphic": .encode(NotebookGraphic())])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    let before = await model.finishPendingPersistence(); XCTAssertTrue(before)
    let presence = try XCTUnwrap(model.presence)
    let older = try NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport)
    let writer = try NotebookSQLWriteBlocker(store: store)
    defer { try? writer.release() }
    model.selectElement(reference)
    let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
    XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: 38, y: 26)))
    let expected = PageRect(x: 138, y: 126, width: 100, height: 100)
    XCTAssertEqual(model.graphicLayout(reference)?.frame, expected)
    await withCheckedContinuation { continuation in model.inputGate.performAfterIdle { continuation.resume() } }
    XCTAssertTrue(model.acceptExternalScene(older, observedEpoch: model.collaborationReadEpoch,
      observedPresence: presence, itemPins: [:]), "An older canonical cut can publish while the command is still queued")
    XCTAssertEqual(model.activePage?.elements.first?.frame, .init(x: 100, y: 100, width: 100, height: 100))
    XCTAssertEqual(model.graphicLayout(reference)?.frame, expected, "Canonical publication without this command cannot retire its draft")
    XCTAssertTrue(model.graphicCommandPending)
    try writer.release()
    let completed = await model.finishPendingPersistence(); XCTAssertTrue(completed)
    XCTAssertTrue(model.elementCommandDrafts.isEmpty)
    XCTAssertEqual(model.activePage?.elements.first?.frame, expected)
    XCTAssertEqual(model.graphicLayout(reference)?.frame, expected)
  }

  func testFastConsecutiveDragsAndStylesKeepEachAcceptedValueWhileSQLiteIsBusy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-continuation-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    let pageID = try XCTUnwrap(model.activePage?.id), target = CollaborationTarget(kind:.page,id:pageID)
    let store = model.store
    _ = try store.applyCollaborationAction(.init(summary:"Two figures",expected:[.init(target:target,revision:store.targetContentRevision(target:target))],
      operations: try ["a","b"].enumerated().map { index, id in
        try .init(kind:.insertElement,target:target,id:id,values:["kind":.string("graphic"),"source":.string(""),
          "frame":.encode(PageRect(x:100+Double(index)*220,y:100,width:100,height:100)),"graphic":.encode(NotebookGraphic())])
      }),actor:UUID())
    await model.reloadExternalChanges()?.value; await model.finishPendingPersistence()
    let a = EditableElementReference.page(pageID:pageID,elementID:"a"), b = EditableElementReference.page(pageID:pageID,elementID:"b")
    let writer = try NotebookSQLWriteBlocker(store:store)
    defer { try? writer.release() }
    model.selectElement(a)
    let first = try XCTUnwrap(model.beginElementManipulation(a,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:20,y:30)))
    let second = try XCTUnwrap(model.beginElementManipulation(a,kind:.resize(.bottomTrailing)))
    XCTAssertEqual(model.selectionSession.manipulation?.original,.init(x:120,y:130,width:100,height:100))
    XCTAssertTrue(model.finishElementManipulation(second,translation:.init(x:-60,y:-70)))
    model.setGraphicStyle(reference:a) { $0.stroke = .init(red:1,green:0,blue:0) }
    model.setGraphicStyle(reference:a) { $0.strokeWidth = 4 }
    model.selectElement(b)
    let other = try XCTUnwrap(model.beginElementManipulation(b,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(other,translation:.init(x:50,y:0)))
    model.selectElement(a)
    let third = try XCTUnwrap(model.beginElementManipulation(a,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(third,translation:.init(x:7,y:9)))
    let expected = PageRect(x:127,y:139,width:40,height:30)
    XCTAssertEqual(model.graphicLayout(a)?.frame,expected)
    XCTAssertEqual(model.graphicElement(a)?.style.strokeWidth,4)
    XCTAssertEqual(model.graphicElement(a)?.style.stroke,.init(red:1,green:0,blue:0))
    XCTAssertEqual(model.graphicLayout(b)?.frame.x,370)
    XCTAssertEqual(model.elementCommandDrafts.count,2)
    try writer.release()
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(model.elementCommandDrafts.isEmpty)
    XCTAssertTrue(model.elementCommandSources.isEmpty)
    let reopened = NotebookStore(root:root)
    XCTAssertEqual(try reopened.readPageElement(pageID:pageID,elementID:"a")?.frame,expected)
    XCTAssertEqual(try reopened.readPageElement(pageID:pageID,elementID:"a")?.graphic?.style,model.graphicElement(a)?.style)
    let actions = try reopened.collaborationActions(afterID:nil).filter { $0.author == .human }
    XCTAssertEqual(actions.count,6,"Every completed gesture/style choice is authored exactly once")
    let last = try XCTUnwrap(actions.first { receipt in
      receipt.action.operations.contains { $0.id == "a" && (try? $0.values["frame"]?.decode(PageRect.self)) == expected }
    })
    _ = try reopened.undoCollaborationAction(last.id,actor:model.actorID)
    XCTAssertEqual(try reopened.readPageElement(pageID:pageID,elementID:"a")?.frame,.init(x:120,y:130,width:40,height:30))
  }

  func testAcceptedVertexAndRoundingContinueThroughTheSameWriterAndUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-corners-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    let pageID = try XCTUnwrap(model.activePage?.id), target = CollaborationTarget(kind:.page,id:pageID), store = model.store
    _ = try store.applyCollaborationAction(.init(summary:"Box",expected:[.init(target:target,revision:store.targetContentRevision(target:target))],
      operations:[.init(kind:.insertElement,target:target,id:"box",values:["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:100,y:100,width:160,height:120)),"graphic":try .encode(NotebookGraphic(shape:.rectangle))])]),actor:UUID())
    await model.reloadExternalChanges()?.value; await model.finishPendingPersistence()
    let reference = EditableElementReference.page(pageID:pageID,elementID:"box")
    let writer = try NotebookSQLWriteBlocker(store:store); defer { try? writer.release() }
    model.selectElement(reference)
    let first = try XCTUnwrap(model.beginElementManipulation(reference,kind:.vertex(0)))
    XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:30,y:15)))
    let accepted = try XCTUnwrap(model.graphicElement(reference)?.vertices)
    let round = try XCTUnwrap(model.beginElementManipulation(reference,kind:.roundCorners))
    model.updateElementManipulation(round,translation:.init(x:30,y:30))
    let liveRadius = try XCTUnwrap(model.graphicGraph(page:try XCTUnwrap(model.activePage)).nodes["box"]?.graphic.cornerRadius)
    XCTAssertGreaterThan(liveRadius,0)
    XCTAssertNil(try store.readPageElement(pageID:pageID,elementID:"box")?.graphic?.cornerRadius)
    XCTAssertTrue(model.finishElementManipulation(round,translation:.init(x:30,y:30)))
    model.setGraphicStyle(reference:reference) { $0.strokeWidth = 4 }
    XCTAssertEqual(model.graphicElement(reference)?.vertices,accepted)
    XCTAssertEqual(model.graphicElement(reference)?.cornerRadius,liveRadius)
    try writer.release(); let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let reopened = NotebookStore(root:root)
    let graphic = try XCTUnwrap(reopened.readPageElement(pageID:pageID,elementID:"box")?.graphic)
    XCTAssertEqual(graphic.vertices,accepted); XCTAssertEqual(graphic.cornerRadius,liveRadius); XCTAssertEqual(graphic.style.strokeWidth,4)
    let rounding = try XCTUnwrap(reopened.collaborationActions(afterID:nil).first { $0.action.operations.first?.values["graphic"]?["cornerRadius"] != nil })
    _ = try reopened.undoCollaborationAction(rounding.id,actor:model.actorID)
    let undone = try XCTUnwrap(reopened.readPageElement(pageID:pageID,elementID:"box")?.graphic)
    XCTAssertNil(undone.cornerRadius); XCTAssertEqual(undone.vertices,accepted); XCTAssertEqual(undone.style.strokeWidth,4)
  }

  func testRejectedMoveReleasesAcceptedDraftWithoutOverwritingConcurrentGeometry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-rejected-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let pageID = try XCTUnwrap(model.activePage?.id), target = CollaborationTarget(kind: .page, id: pageID)
    let reference = EditableElementReference.page(pageID: pageID, elementID: "circle")
    let store = model.store
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    func action(_ kind: CollaborationOperation.Kind, values: [String: JSONValue]) throws {
      let revision = try store.targetContentRevision(target: target)
      _ = try store.applyCollaborationAction(.init(summary: "Concurrent geometry",
        references: kind == .updateElement ? [.init(target: target, elementID: "circle", revision: revision)] : [],
        expected: [.init(target: target, revision: revision)],
        operations: [.init(kind: kind, target: target, id: "circle", values: values)]), actor: UUID())
    }
    let original = PageRect(x: 100, y: 100, width: 100, height: 100)
    try action(.insertElement, values: ["kind": .string("graphic"), "source": .string(""),
      "frame": .encode(original), "graphic": .encode(NotebookGraphic(label: "+"))])
    await model.reloadExternalChanges()?.value
    model.selectElement(reference)
    let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
    model.updateElementManipulation(contact, translation: .init(x: 38, y: 26))
    let preview = try XCTUnwrap(model.graphicLayout(reference))
    let concurrent = PageRect(x: 230, y: 180, width: 100, height: 100)
    try action(.updateElement, values: ["frame": .encode(concurrent), "graphic": .object(["label": .string("agent")])])
    XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: 38, y: 26)))
    XCTAssertEqual(model.graphicLayout(reference), preview)
    model.setGraphicStyle(reference:reference) { $0.strokeWidth = 8 }
    try await wait { !model.graphicCommandPending }
    XCTAssertTrue(model.elementCommandDrafts.isEmpty)
    XCTAssertNotNil(model.actionCue, "Rejection is visible, not a silently successful drag")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.graphicLayout(reference)?.frame, concurrent)
    XCTAssertEqual(model.graphicElement(reference)?.style.strokeWidth,2,"A rejected predecessor cannot rebase its dependent edit onto a peer")
    XCTAssertEqual(model.graphicElement(reference)?.label, "agent")
    XCTAssertEqual(try store.readPageElement(pageID: pageID, elementID: "circle")?.frame, concurrent)
    XCTAssertEqual(try store.collaborationActions(afterID: nil).count, 2, "The rejected native command has no receipt to undo")
  }

  private func scenario(onBoard: Bool, reopens: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-model-\(UUID())")
    var model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace, "Startup: \(model.loadState)"), pageID = try XCTUnwrap(workspace.selectedPageID)
    let target = CollaborationTarget(kind: onBoard ? .board : .page, id: onBoard ? workspace.rootBoardID : pageID)
    if onBoard { model.updatePresence(.init(boardID: target.id, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)), settled: true) }
    let initialSave = await model.finishPendingPersistence(); XCTAssertTrue(initialSave)
    let store = model.store, strokeID = UUID()
    var values: [String: JSONValue] = ["points": .array((0...48).map { index in
      let a = Double(index) / 48 * 2 * Double.pi
      return .object(["x": .number(150 + 60 * cos(a)), "y": .number(150 + 60 * sin(a))])
    })]
    if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    _ = try store.applyCollaborationAction(.init(summary: "Measured samples",
      expected: [.init(target: target, revision: store.targetContentRevision(target: target), inkRevision: store.inkRevision(on: target))],
      operations: [.init(kind: .appendInkStroke, target: target, id: strokeID.uuidString, values: values)]), actor: model.actorID)
    await model.reloadExternalChanges()?.value
    let fit = NotebookQuickShapeFit(frame: .init(x: 90, y: 90, width: 120, height: 120), sampleCount: 49)
    if onBoard {
      model.acceptQuickShape(fit, boardID: target.id, origin: .zero, stroke: try XCTUnwrap(store.loadSpatialInk().actions.first { $0.id == strokeID }))
    } else {
      let page = try store.loadPage(pageID), ink = try PageInkDrawing.decode(page.drawingData)
      model.acceptQuickShape(fit, pageID: pageID, stroke: try XCTUnwrap(ink.actions.first { $0.id == strokeID }))
    }
    try await wait { !model.graphicCommandPending }
    await model.reloadExternalChanges()?.value
    let id: String
    if onBoard { id = try XCTUnwrap(model.boardHierarchy?.board(target.id)?.elements.first { $0.graphic != nil }?.id) }
    else { id = try XCTUnwrap(model.pages[pageID]?.elements.first { $0.graphic != nil }?.id) }
    let reference: EditableElementReference = onBoard ? .spatial(boardID: target.id, elementID: id) : .page(pageID: pageID, elementID: id)
    func graphic() throws -> NotebookGraphic? {
      if onBoard { return try store.readSpatialElement(boardID: target.id, elementID: id)?.graphic }
      return try store.readPageElement(pageID: pageID, elementID: id)?.graphic
    }
    let conversion = try XCTUnwrap(store.collaborationActions(afterID: nil).first { $0.action.operations.contains { $0.kind == .convertInkToElement } })
    XCTAssertEqual(conversion.author, .human)
    let creationCursor = model.workingGraphics.first(where: { $0.id == id })?.publicationCursor
    model.moveElementAccessibly(reference, by: .init(x: 24, y: 18))
    try await wait { !model.graphicCommandPending }
    await model.reloadExternalChanges()?.value
    if onBoard {
      XCTAssertNotNil(creationCursor)
      XCTAssertEqual(model.workingGraphics.first(where: { $0.id == id })?.publicationCursor, creationCursor,
        "An edit cannot re-open the original creation draft while its display confirmation is pending")
    }
    let moved = try XCTUnwrap(store.collaborationActions(afterID: nil).first { $0.action.operations.contains { $0.kind == .updateElement } })
    XCTAssertEqual(moved.author, .human)
    let edit = try store.applyCollaborationAction(.init(summary: "Agent label",
      references: [.init(target: target, elementID: id, revision: store.targetContentRevision(target: target))],
      expected: [.init(target: target, revision: store.targetContentRevision(target: target))],
      operations: [.init(kind: .updateElement, target: target, id: id, values: ["graphic": .object(["label": .string("+")])])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.graphicElement(reference)?.label, "+")
    model.selectElement(reference); model.deleteElement(reference)
    try await wait { !model.graphicCommandPending }
    XCTAssertEqual(try graphic()?.visible, false)
    let deletion = try XCTUnwrap(store.collaborationActions(afterID: nil).first { $0.action.operations.contains { $0.kind == .removeElement } })
    for receipt in [deletion, edit, moved, conversion] {
      if reopens {
        let saved = await model.shutdown(); XCTAssertTrue(saved)
        model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
        retainNotebookUntilTeardown(model, removing: root)
        await model.start(pageSize: NotebookAppModel.defaultPageSize)
      }
      model.undoCollaboration(receipt.id)
      // Quiescent save joins the accepted command, including its idle wait;
      // returning early here would lose the inverse on immediate process exit.
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      XCTAssertNotNil(try store.collaborationActions(afterID: nil).first { $0.id == receipt.id }?.undo)
      await model.reloadExternalChanges()?.value
    }
    XCTAssertEqual(try graphic()?.representation, .ink)
    XCTAssertEqual(try graphic()?.visible, true)
    XCTAssertEqual(try graphic()?.label, "")
  }

  private func wait(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(try predicate())
  }
}
