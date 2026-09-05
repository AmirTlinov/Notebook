import NotebookCore
import XCTest
@testable import Notebook

final class SharedAttentionTests: XCTestCase {
  @MainActor
  func testReceivedCatalogKeepsThePhysicalReadersSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    model.start(pageSize:NotebookAppModel.defaultPageSize)
    let original = try XCTUnwrap(model.workspace)
    let presence = SessionPresence(boardID:original.rootBoardID,mode:.page,
      camera:.init(center:try XCTUnwrap(model.board?.focusedCenter(of:original.selectedItemID)),scale:1),
      viewport:.init(x:834,y:1194),focusedItemID:original.selectedItemID,openProgress:1)
    model.updatePresence(presence,settled:true)
    let newItem = try XCTUnwrap(model.createNotebook(at:.init(x:1600,y:0)))
    model.selectItem(original.selectedItemID)
    var remote = try XCTUnwrap(model.collaborationContent)
    XCTAssertTrue(remote.workspace.selectItem(newItem,actor:UUID()))
    model.receivePeerMessage(.collaboration(.init(content:remote)))
    XCTAssertEqual(model.workspace?.selectedItemID,original.selectedItemID)
    XCTAssertEqual(model.workspace?.selectedPageID,original.selectedPageID)
    XCTAssertEqual(model.presence,presence)
  }

  @MainActor
  func testReferenceTracksItsPageWhenNotebookMovesAndSourceChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    model.start(pageSize:NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace), page = try XCTUnwrap(model.activePage)
    let center = try XCTUnwrap(model.board?.focusedCenter(of:workspace.selectedItemID))
    let presence = SessionPresence(boardID:workspace.rootBoardID,mode:.page,camera:.init(center:center,scale:1),
      viewport:.init(x:834,y:1194),focusedItemID:workspace.selectedItemID,openProgress:1)
    model.updatePresence(presence,settled:true)
    let reference = try XCTUnwrap(NotebookAttentionProjection.reference(start:.init(x:100,y:100),end:.init(x:220,y:200),model:model,presence:presence))
    XCTAssertEqual(reference.target,.init(kind:.page,id:page.id))
    model.isPointing = true
    model.publishHumanAttention(reference)
    XCTAssertFalse(model.isPointing)
    XCTAssertFalse(model.referenceChanged(reference))
    model.moveItem(workspace.selectedItemID,to:center.offsetBy(x:100,y:50))
    XCTAssertFalse(model.referenceChanged(reference))
    let moved = try XCTUnwrap(NotebookAttentionProjection.frame(reference,model:model,presence:presence))
    XCTAssertEqual(moved.minX,200,accuracy:1)
    XCTAssertEqual(moved.minY,150,accuracy:1)
    let action = CollaborationAction(summary:"Подпись",expected:[.init(target:reference.target,revision:page.agentStamp.revision)],operations:[
      .init(kind:.insertElement,target:reference.target,id:"caption",values:["kind":.string("markdown"),"source":.string("Мысль"),"frame":.object(["x":.number(300),"y":.number(80),"width":.number(200),"height":.number(80)])])])
    _ = try model.store.applyCollaborationAction(action,actor:UUID()); model.reloadExternalChanges()
    XCTAssertTrue(model.referenceChanged(reference))
  }

  @MainActor
  func testDeliveryAndDisplayRequireDifferentEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    model.start(pageSize:NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage), workspace = try XCTUnwrap(model.workspace)
    let target = CollaborationTarget(kind:.page,id:page.id)
    let action = CollaborationAction(summary:"Подпись",expected:[.init(target:target,revision:page.agentStamp.revision)],operations:[
      .init(kind:.insertElement,target:target,id:"caption",values:["kind":.string("web"),"source":.string("<p>Meaning</p>"),"frame":.object(["x":.number(300),"y":.number(80),"width":.number(200),"height":.number(80)])])])
    let receipt = try model.store.applyCollaborationAction(action,actor:UUID())
    model.receivePeerMessage(.collaboration(.init(content:try model.store.collaborationContent(),actions:[receipt])))
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete)
    let presence = SessionPresence(boardID:workspace.rootBoardID,mode:.page,camera:.init(center:try XCTUnwrap(model.board?.focusedCenter(of:workspace.selectedItemID)),scale:1),viewport:.init(x:834,y:1194),focusedItemID:workspace.selectedItemID,openProgress:1)
    model.updatePresence(presence,settled:true)
    model.confirmVisibleActions(presence:presence)
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete)
    model.pagePresented(try XCTUnwrap(model.activePage),ready:true)
    model.confirmVisibleActions(presence:presence)
    XCTAssertTrue(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete)
  }
}
