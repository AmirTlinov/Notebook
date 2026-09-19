import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicSelectionTests: XCTestCase {
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
      let graph = model.graphicGraph(page:original)
      XCTAssertEqual(graph.nodes["a"]?.frame.x,80); XCTAssertEqual(graph.nodes["b"]?.frame.x,280)
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
      model.duplicateGraphicSelection()
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
