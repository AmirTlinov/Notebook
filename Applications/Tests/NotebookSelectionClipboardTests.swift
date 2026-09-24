import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookSelectionClipboardTests: XCTestCase {
  func testNativeFragmentAtPaperEdgeStaysOnItsCapturedPageAfterCut() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let element=AgentElement(id:"edge",kind:.graphic,frame:.init(x:80,y:240,width:200,height:160),
      source:"Узел +",html:"",graphic:.init(shape:.rectangle))
    XCTAssertTrue(page.replaceElements([element],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    model.selectElement(.page(pageID:page.id,elementID:element.id))
    let fragment=try model.clipboardSelectionFragment().reidentified()
    model.deleteSelectedContent()
    let cut=await model.finishPendingPersistence();XCTAssertTrue(cut)
    XCTAssertEqual(try model.store.loadPage(page.id).element(id:element.id)?.graphic?.visible,false,"Native removal retains its causal source but hides all its material")
    let destination=NotebookPasteDestination(target:.init(kind:.page,id:page.id),title:"Лист",
      center:.init(x:page.size.width*0.94,y:page.size.height*0.8),
      availableSize:.init(x:page.size.width,y:page.size.height),worldOrigin:nil)
    let inserted=await model.insertClipboardFragment(fragment,at:destination)
    XCTAssertTrue(inserted,model.actionCue ?? model.persistenceFailure ?? "Paste failed")
    let saved=try model.store.loadPage(page.id)
    let visible=saved.elements.filter { $0.graphic?.visible != false }
    XCTAssertEqual(visible.count,1)
    let frame=try XCTUnwrap(visible.first).frame
    XCTAssertGreaterThanOrEqual(frame.x,0);XCTAssertGreaterThanOrEqual(frame.y,0)
    XCTAssertLessThanOrEqual(frame.x+frame.width,page.size.width)
    XCTAssertLessThanOrEqual(frame.y+frame.height,page.size.height)
    XCTAssertNotEqual(visible.first?.id,element.id)
  }

  func testExportWholeAndIndividualMemberKeepsShapeTextAndDetachedPlacement() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:100,y:120,width:400,height:300),source:"",html:"",basis:.init(size:.init(x:400,y:300)))
    let child=AgentElement(id:"child",kind:.graphic,frame:.init(x:20,y:30,width:100,height:80),source:"",html:"",graphic:.init(shape:.rectangle),parentID:whole.id)
    let text=AgentElement(id:"text",kind:.nativeText,frame:.init(x:160,y:40,width:180,height:70),source:"Оригинальный текст",html:"",parentID:whole.id)
    XCTAssertTrue(page.replaceElements([whole,child,text],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    model.selectElement(.page(pageID:page.id,elementID:whole.id))
    let copied=try model.clipboardSelectionFragment()
    XCTAssertEqual(copied.elements.count,3)
    XCTAssertEqual(copied.elements[1].frame,child.frame)
    XCTAssertEqual(copied.elements[1].parentID,whole.id)
    XCTAssertEqual(copied.elements[2].source,text.source)
    model.selectElement(.page(pageID:page.id,elementID:child.id))
    let member=try model.clipboardSelectionFragment()
    XCTAssertEqual(member.elements.count,1);XCTAssertNil(member.elements[0].parentID)
    XCTAssertEqual(member.elements[0].frame.x,0,accuracy:1e-9);XCTAssertEqual(member.elements[0].frame.y,0,accuracy:1e-9)
    XCTAssertEqual(try model.store.loadPage(page.id).elements,[whole,child,text],"Copy never mutates source membership")
    let fragment=try copied.reidentified()
    let destination=NotebookPasteDestination(target:.init(kind:.page,id:page.id),title:"Лист",center:.init(x:450,y:650),
      availableSize:.init(x:page.size.width,y:page.size.height),worldOrigin:nil)
    let inserted=await model.insertClipboardFragment(fragment,at:destination);XCTAssertTrue(inserted)
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPage(page.id).elements.count,6)
    await model.reloadExternalChanges()?.value
    model.selectElement(.page(pageID:page.id,elementID:whole.id))
    model.duplicateSelectedContent()
    let duplicated=await model.finishPendingPersistence();XCTAssertTrue(duplicated)
    await model.reloadExternalChanges()?.value
    let duplicatePage=try NotebookStore(root:root).loadPage(page.id)
    XCTAssertEqual(duplicatePage.elements.count,9)
    let clones=Array(duplicatePage.elements.suffix(3))
    XCTAssertEqual(clones[0].frame.x,whole.frame.x+24)
    XCTAssertEqual(clones[0].frame.y,whole.frame.y+24)
    XCTAssertEqual(clones[1].parentID,clones[0].id)
    XCTAssertEqual(clones[2].parentID,clones[0].id)
    XCTAssertEqual(clones[2].source,text.source)
    let receipt=try XCTUnwrap(model.store.collaborationActions(afterID:nil).first { $0.action.summary == "Дублировать содержимое" })
    model.undoCollaboration(receipt.id)
    let undone=await model.finishPendingPersistence();XCTAssertTrue(undone)
    XCTAssertEqual(try NotebookStore(root:root).loadPage(page.id).elements.count,6)
  }
}
