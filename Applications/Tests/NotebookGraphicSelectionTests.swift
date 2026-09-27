import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicSelectionTests: XCTestCase {
  func testMountedBoardSelectionKeepsPainterOrderAndPassivePortalOutOfTheHostRegistry() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("board-selection-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let workspace=try XCTUnwrap(model.workspace),boardID=workspace.rootBoardID
    let before=try model.store.loadBoard(items:workspace.items)
    var after=before
    let blue=SpatialInkColor(red:0,green:0,blue:1)
    let red=SpatialInkColor(red:1,green:0,blue:0)
    let green=SpatialInkColor(red:0,green:0,blue:0)
    let specs:[(String,Double,Double,SpatialInkColor)]=[
      ("selected-back",40,40,blue),("untouched-front",90,40,red),("selected-other",240,40,green)]
    for (id,x,y,color) in specs {
      let graphic=NotebookGraphic(shape:.rectangle,style:.init(stroke:color,strokeWidth:1,fill:color),label:id)
      let element=SpatialElement(id:id,surface:.board(boardID),kind:.graphic,
        frame:.init(x:x,y:y,width:100,height:100),worldOrigin:.zero,source:"",graphic:graphic,
        stamp:.init(counter:0,actor:model.actorID))
      XCTAssertTrue(after.upsertElement(element,in:boardID,expected:nil,actor:model.actorID))
    }
    _=try model.store.saveBoardEdits(before:before,after:after)
    await model.reloadExternalChanges()?.value
    let source=try XCTUnwrap(model.boardHierarchy?.board(boardID))
    let elements=specs.compactMap { id,_,_,_ in source.elements.first { $0.id == id } }
    XCTAssertEqual(elements.count,3)
    let plane=SceneCompositionPlane.board(boardID)
    let owners=specs.enumerated().map { index,spec in
      SceneCompositionLiveOwner(plane:plane,id:.element(spec.0),
        position:.init(layer:.elements,zIndex:Double(index),key:spec.0))
    }
    let run=SceneCompositionVectorRun(plane:plane,owners:owners)
    let refs=["selected-back","selected-other"].map {
      EditableElementReference.spatial(boardID:boardID,elementID:$0)
    }
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene)
    window.frame = .init(x:0,y:0,width:800,height:400)
    defer {window.isHidden=true;window.rootViewController=nil;model.compositionTiles.cancelPreparation()}
    func content() -> some View {
      let graph=model.authoredGraphicGraph(boardID:boardID)
      return HStack(spacing:0) {
        NotebookGraphicBatchView(run:run,elements:elements,graph:graph,scale:1,
          size:.init(width:400,height:400),projectOrigin:{_ in .zero})
        NotebookGraphicBatchView(run:run,elements:elements,graph:graph,scale:1,
          size:.init(width:400,height:400),projectOrigin:{_ in .zero},commitsState:false)
      }.frame(width:800,height:400).background(.white).environment(model).ignoresSafeArea()
    }
    window.rootViewController=UIHostingController(rootView:content())
    window.makeKeyAndVisible()
    XCTAssertTrue(model.selectElements(refs))
    let contact=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
    let frozen=try XCTUnwrap(model.selectionSession.manipulation?.selectionSource)
    let deadline=ContinuousClock.now + .seconds(2)
    while model.selectedGraphicHosts.hosts(frozen) == nil,ContinuousClock.now<deadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    let hosts=try XCTUnwrap(model.selectedGraphicHosts.hosts(frozen))
    XCTAssertEqual(hosts.count,2)
    XCTAssertTrue(hosts.values.allSatisfy { $0.view.convert(.zero,to:window).x<400 },
      "The passive portal cannot replace an active selected host")
    model.updateElementManipulation(contact,translation:.init(x:0,y:100))
    let moved=ContinuousClock.now + .seconds(2)
    while model.selectionSession.manipulation?.inkPresentation?.installed != true,ContinuousClock.now<moved {
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertTrue(model.selectionSession.manipulation?.inkPresentation?.installed == true)
    XCTAssertEqual(model.selectionSession.manipulation?.selectedEdits.map(\.frame.y),[140,140])
    try await Task.sleep(for:.milliseconds(30))
    // Red is above the selected blue in the original painter run; the portal
    // is a passive projection and must remain at the original location.
    let pixels=try NotebookUXObservation.Pixels(window:window)
    let image=XCTAttachment(image:pixels.image);image.name="board-selected-host-and-passive-portal"
    image.lifetime = .keepAlways;add(image)
    XCTAssertTrue(try pixels.matches([(.init(x:110,y:160),.blue),(.init(x:110,y:90),.red),
      (.init(x:510,y:90),.red),(.init(x:290,y:190),.black)]))
    let nativeHost=try XCTUnwrap(hosts["selected-back"]?.view.subviews.first)
    XCTAssertGreaterThan(nativeHost.accessibilityElementCount(),0,
      "The moving hosting view must retain its accessibility representation")
    XCTAssertEqual(nativeHost.convert(nativeHost.bounds,to:window).midY,190,accuracy:5,
      "Accessibility content and pixels must share the installed native pose")
    XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:0,y:100)))
    let next=try XCTUnwrap(model.beginSelectionManipulation(kind:.move),
      "A second gesture must not wait for the first command's canonical reload")
    model.updateElementManipulation(next,translation:.init(x:0,y:40))
    let nextDeadline=ContinuousClock.now + .seconds(2)
    while model.selectionSession.manipulation?.inkPresentation?.installed != true,ContinuousClock.now<nextDeadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertEqual(model.selectionSession.manipulation?.selectedEdits.map(\.frame.y),[180,180])
    XCTAssertTrue(model.selectionSession.manipulation?.inkPresentation?.installed == true,
      "The new native owner must rebase both hosts from the preceding installed pose")
    try await Task.sleep(for:.milliseconds(30))
    let repeated=try NotebookUXObservation.Pixels(window:window)
    XCTAssertTrue(try repeated.matches([(.init(x:110,y:260),.blue),(.init(x:290,y:260),.black),
      (.init(x:110,y:90),.red)]))
    model.cancelElementManipulation(next)
    let written=await model.finishPendingPersistence()
    XCTAssertTrue(written)
  }

  func testSelectionMovesAsOneContactPublishesBothIDsAndCancelsForPencil() async throws {
    try await fixture { model, pageID in
      let a = EditableElementReference.page(pageID:pageID,elementID:"a"), b = EditableElementReference.page(pageID:pageID,elementID:"b")
      model.selectElement(a); model.beginMultipleSelection(); model.toggleGraphicSelection(b)
      XCTAssertEqual(model.selectionSession.elements,[a,b])
      XCTAssertEqual(model.selectionForPublication?.kind,.elements)
      XCTAssertEqual(model.selectionForPublication?.elementIDs,["a","b"])
      let original = try XCTUnwrap(model.pages[pageID])
      let contact = try XCTUnwrap(model.beginElementManipulation(b,kind:.move))
      model.updateElementManipulation(contact,translation:.init(x:40,y:55))
      let desired=try XCTUnwrap(model.selectionSession.manipulation).selectedEdits
      XCTAssertEqual(desired.map(\.frame.x),[80,280])
      let graph = model.graphicGraph(page:original)
      XCTAssertEqual(graph.nodes["a"]?.frame.x,40); XCTAssertEqual(graph.nodes["b"]?.frame.x,240,
        "Without a mounted host, the read model retains the last shown pose instead of inventing a frame")
      XCTAssertEqual(try model.store.loadPage(pageID),original,"A movement sample cannot write SQLite")
      let pencil = UUID(); XCTAssertTrue(model.inputGate.beginPencilAction(source:pencil))
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertFalse(model.finishElementManipulation(contact,translation:.init(x:40,y:55)))
      model.inputGate.endPencilAction(source:pencil)
      XCTAssertEqual(try model.store.loadPage(pageID),original)
    }
  }

  func testAtomicMoveRetainsAcceptedPreviewThenCopyAndUndoAfterReopen() async throws {
    try await fixture { model, pageID in
      let refs = ["a","b","link"].map { EditableElementReference.page(pageID:pageID,elementID:$0) }
      model.selectElement(refs[0]); model.beginMultipleSelection(); model.toggleGraphicSelection(refs[1]); model.toggleGraphicSelection(refs[2])
      let before = try XCTUnwrap(model.pages[pageID])
      let contact = try XCTUnwrap(model.beginElementManipulation(refs[0],kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:30,y:40)))
      for ref in refs { XCTAssertNotNil(model.elementCommandDrafts[ref],"All accepted members survive Pencil/finger lift") }
      let written = await model.finishPendingPersistence(); XCTAssertTrue(written)
      await model.reloadExternalChanges()?.value
      let moved = try model.store.loadPage(pageID)
      XCTAssertEqual(moved.elements[0].frame.x,before.elements[0].frame.x+30)
      XCTAssertEqual(moved.elements[1].frame.y,before.elements[1].frame.y+40)
      XCTAssertEqual(moved.elements[2].graphic?.connection?.bindings.map(\.elementID),["a","b"])
      model.duplicateSelectedContent()
      let copied = await model.finishPendingPersistence(); XCTAssertTrue(copied)
      await model.reloadExternalChanges()?.value
      let result = try NotebookStore(root:model.store.root).loadPage(pageID)
      XCTAssertEqual(result.elements.count,6)
      let copies = Array(result.elements.suffix(3))
      XCTAssertTrue(copies.allSatisfy { $0.graphic?.sourceInkIDs.isEmpty == true })
      XCTAssertEqual(copies[2].graphic?.connection?.bindings.map(\.elementID),[copies[0].id,copies[1].id])
      let receipt = try XCTUnwrap(model.store.collaborationActions(afterID:nil).first { $0.action.summary == "Дублировать фигуры" })
      model.undoCollaboration(receipt.id)
      let undone = await model.finishPendingPersistence(); XCTAssertTrue(undone)
      await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(pageID).elements.count,3)
    }
  }

  func testSelectionClampsAsAWholeAndDoesNotAdoptAnotherPage() async throws {
    try await fixture { model, pageID in
      let a = EditableElementReference.page(pageID:pageID,elementID:"a"), b = EditableElementReference.page(pageID:pageID,elementID:"b")
      model.selectElement(a); model.beginMultipleSelection(); model.toggleGraphicSelection(b)
      let contact = try XCTUnwrap(model.beginElementManipulation(a,kind:.move))
      model.updateElementManipulation(contact,translation:.init(x:-10000,y:-10000))
      let edits = try XCTUnwrap(model.selectionSession.manipulation).selectedEdits
      XCTAssertEqual(edits[0].frame.x,0); XCTAssertEqual(edits[1].frame.x,200)
      XCTAssertEqual(edits[0].frame.y,0); XCTAssertEqual(edits[1].frame.y,80)
      model.cancelElementManipulation(contact)
      model.toggleGraphicSelection(.page(pageID:UUID(),elementID:"b"))
      XCTAssertEqual(model.selectionSession.elements,[a,b])
      model.alignGraphicSelection(.left)
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      let page = try model.store.loadPage(pageID)
      XCTAssertEqual(page.elements[0].frame.x,page.elements[1].frame.x)
    }
  }

  private func fixture(_ body: (NotebookAppModel,UUID) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    var page = try XCTUnwrap(model.activePage)
    let link = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
      end:.init(point:.init(x:200,y:80),binding:.init(elementID:"b")),bend:25))
    page.replaceElements([
      .init(id:"a",kind:.graphic,frame:.init(x:40,y:60,width:60,height:60),source:"",html:"",graphic:.init(label:"A")),
      .init(id:"b",kind:.graphic,frame:.init(x:240,y:140,width:80,height:80),source:"",html:"",graphic:.init(shape:.rectangle,label:"B")),
      .init(id:"link",kind:.graphic,frame:.init(x:40,y:60,width:200,height:80),source:"",html:"",graphic:link)],actor:model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    try await body(model,page.id)
  }
}
