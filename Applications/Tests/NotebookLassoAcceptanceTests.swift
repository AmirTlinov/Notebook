import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookLassoAcceptanceTests:XCTestCase {
  private actor Gate {
    private var open=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open=true;let pending=waiters;waiters=[];for waiter in pending { waiter.resume() } }
  }

  func testLiftBeforePreparationSurvivesNewFocusToolAndInkWithoutOvertaking() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      delayed(ready,gate:gate,model:model)
      let contact=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:40,y:20)))
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertNotNil(model.graphicCommandTask,"Lift, not eventual preparation, admits the action")
      model.selectElement(address.reference(shape.id));model.selectDrawingTool(.pen)
      let stroke=PageInkAction(tool:.pen,samples:[.init(point:.init(x:500,y:500),timeOffset:0,width:4,opacity:0.6,force:0.7,azimuth:1,altitude:1)])
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(stroke,pageID:page.id,stamp:stamp))
      await Task.yield()
      XCTAssertTrue(try model.store.loadPage(page.id).inkDrawing().actions.isEmpty,"New ink stays live but cannot overtake the earlier accepted cut")
      await gate.release()
      let finished=await model.finishPendingPersistence();XCTAssertTrue(finished,model.actionCue ?? "")
      let saved=try model.store.loadPage(page.id)
      let fragment=try XCTUnwrap(saved.elements.first { $0.id != shape.id },model.actionCue ?? "Missing accepted lasso fragment")
      XCTAssertEqual(fragment.frame.x,shape.frame.x+40,accuracy:1e-8)
      XCTAssertEqual(fragment.frame.y,shape.frame.y+20,accuracy:1e-8)
      XCTAssertEqual(try saved.inkDrawing().actions.map(\.id),[stroke.id])
      XCTAssertEqual(model.drawingTool,.pen);XCTAssertNil(model.selectionSession.target,"A late worker cannot steal the next focus")
      XCTAssertEqual(model.collaborationActions.filter { $0.action.summary == "Переместить область лассо" }.count,1)
      model.undoLastSurfaceAction();let inkUndone=await model.finishPendingPersistence();XCTAssertTrue(inkUndone)
      XCTAssertTrue(try model.store.loadPage(page.id).inkDrawing().activeActions.isEmpty)
      XCTAssertNotNil(try model.store.loadPage(page.id).element(id:fragment.id),"Undo respects lift order, not worker completion order")
      model.undoLastSurfaceAction();let moveUndone=await model.finishPendingPersistence();XCTAssertTrue(moveUndone)
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
    }
  }

  func testTwoEarlyLiftsAndNextLassoChainAcceptedMaterialWithoutWaitingForSave() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      delayed(ready,gate:gate,model:model)
      let first=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:40,y:20)))
      let next=try XCTUnwrap(model.selectionSession.region)
      let second=try XCTUnwrap(model.beginElementManipulation(next.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(second,translation:.init(x:30,y:-10)))
      model.selectDrawingTool(.lasso)
      let polygon=[SpatialPoint(x:270,y:110),.init(x:300,y:110),.init(x:300,y:190),.init(x:270,y:190)]
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      for point in polygon.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
      let thirdRegion=try XCTUnwrap(model.selectionSession.region)
      let third=try XCTUnwrap(model.beginElementManipulation(thirdRegion.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(third,translation:.init(x:0,y:120)))
      model.clearSelection();model.selectDrawingTool(.pen)
      let later=PageInkAction(tool:.pen,samples:[.init(point:.init(x:280,y:150),timeOffset:0,width:5,opacity:0.4,force:0.6,azimuth:0,altitude:1)])
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(later,pageID:page.id,stamp:stamp))
      let laterCut=PageInkAction(tool:.eraser,samples:[.init(point:.init(x:285,y:150),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:1)],
        elementTargets:[.init(elementID:shape.id,frame:shape.frame)])
      let cutStamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(laterCut,pageID:page.id,stamp:cutStamp))
      await gate.release()
      let finished=await model.finishPendingPersistence();XCTAssertTrue(finished,model.actionCue ?? "")
      let saved=try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.count,3,model.actionCue ?? "")
      let moved=try XCTUnwrap(saved.elements.first { abs($0.frame.x-170)<1e-8 })
      XCTAssertEqual(moved.frame.y,110,accuracy:1e-8)
      XCTAssertEqual(saved.element(id:shape.id)?.graphic?.mask?.operations.count,2,"The next lasso cuts the accepted remainder, not the old whole")
      XCTAssertEqual(model.collaborationActions.filter { $0.action.summary == "Переместить область лассо" }.count,3)
      XCTAssertEqual(try saved.inkDrawing().activeActions.map(\.id),[later.id,laterCut.id])
      let lastFragment=try XCTUnwrap(saved.elements.first { abs($0.frame.y-220)<1e-8 })
      XCTAssertTrue(lastFragment.graphic?.mask?.operations.allSatisfy { $0.erasures == nil } == true,
        "An earlier accepted cut must not borrow the later eraser from the live page cache")
      XCTAssertNil(model.selectionSession.target)
      for _ in 0..<2 { model.undoLastSurfaceAction();let inkUndone=await model.finishPendingPersistence();XCTAssertTrue(inkUndone) }
      for _ in 0..<3 { model.undoLastSurfaceAction();let saved=await model.finishPendingPersistence();XCTAssertTrue(saved) }
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
    }
  }

  func testAcceptedFragmentRemainsHittableAndLassoableAfterFocusChangesWhileStorageWaits() async throws {
    try await fixture { model,page,shape,address,ready in
      let workspace=try XCTUnwrap(model.workspace),viewport=SpatialPoint(x:834,y:1194)
      let center=model.boardHierarchy?.focusedCenter(of:workspace.selectedItemID,in:workspace.rootBoardID) ?? .zero
      model.updatePresence(.init(boardID:workspace.rootBoardID,mode:.page,
        camera:.init(center:center,scale:WorkspaceItemGeometry.notebook.fitScale(viewport:viewport)),viewport:viewport,
        focusedItemID:workspace.selectedItemID,openProgress:1),settled:true)
      let window=try await mountNotebookScene(model)
      let initial=await model.finishPendingPersistence();XCTAssertTrue(initial)
      let writer=try NotebookSQLWriteBlocker(store:model.store);defer { try? writer.release() }
      model.selectRegion(ready)
      let first=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:80,y:200)))
      let fragment=try XCTUnwrap(model.selectionSession.element)
      model.selectDrawingTool(.pen)
      XCTAssertNil(model.selectionSession.target)
      window.layoutIfNeeded()
      let presence=try XCTUnwrap(model.presence)
      let paper=try XCTUnwrap(NotebookAttentionProjection.frame(.init(target:address.target,revision:""),model:model,presence:presence))
      let point=CGPoint(x:paper.minX+220*presence.camera.scale,y:paper.minY+350*presence.camera.scale)
      let hit=try XCTUnwrap(NotebookAttentionProjection.pointContact(at:point,model:model,presence:presence,cohort:model.compositionTiles.published))
      XCTAssertEqual(hit.elementID,fragment.elementID,"Fresh taps use accepted material, not the last selection or saved page")
      model.selectElement(fragment)
      let second=try XCTUnwrap(model.beginElementManipulation(fragment,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(second,translation:.init(x:30,y:10)))
      model.selectDrawingTool(.lasso)
      let polygon=[SpatialPoint(x:225,y:305),.init(x:275,y:305),.init(x:275,y:405),.init(x:225,y:405)]
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      for p in polygon.dropFirst() { model.drawingTools.move(to:p) };model.drawingTools.finish()
      let deadline=ContinuousClock.now + .seconds(5)
      while model.selectionSession.region?.materialization == nil,model.drawingTools.pendingLasso != nil,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(5)) }
      let selected=try XCTUnwrap(model.selectionSession.region,model.actionCue ?? "")
      XCTAssertEqual(selected.graphics,[fragment],"The next lasso sees a moved insertion before SQLite acknowledges it")
      XCTAssertNotNil(selected.materialization)
      let third=try XCTUnwrap(model.beginElementManipulation(selected.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(third,translation:.init(x:0,y:150)))
      model.selectDrawingTool(.pen)
      XCTAssertTrue(model.workingGraphics.allSatisfy { $0.publicationCursor == nil })
      try writer.release()
      let finished=await model.finishPendingPersistence();XCTAssertTrue(finished,model.actionCue ?? "")
      let saved=try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.count,3,model.actionCue ?? "")
      XCTAssertEqual(try XCTUnwrap(saved.element(id:fragment.elementID)).frame.x,210,accuracy:1e-8)
      XCTAssertEqual(saved.element(id:shape.id)?.frame,shape.frame)
      XCTAssertEqual(model.collaborationActions.filter { $0.action.summary.contains("область лассо") || $0.action.summary == "Изменить положение объекта" }.count,3)
      for _ in 0..<3 { model.undoLastSurfaceAction();let saved=await model.finishPendingPersistence();XCTAssertTrue(saved) }
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
    }
  }

  func testUnclaimedPreparationCanCancelButAcceptedForeignConflictRemainsAtomic() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      delayed(ready,gate:gate,model:model)
      let cancelled=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      model.updateElementManipulation(cancelled,translation:.init(x:30,y:20));model.cancelElementManipulation(cancelled)
      XCTAssertNil(model.graphicCommandTask);XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
      let accepted=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(accepted,translation:.init(x:40,y:20)))
      model.selectDrawingTool(.pen)
      var foreign=try model.store.loadPage(page.id)
      let replacement=shape.updating(frame:.init(x:120,y:100,width:200,height:100))
      XCTAssertTrue(foreign.replaceElements([replacement],actor:UUID()));try model.store.savePage(foreign)
      await gate.release()
      _ = await model.finishPendingPersistence()
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[replacement])
      XCTAssertFalse(model.collaborationActions.contains { $0.action.summary == "Переместить область лассо" })
      XCTAssertFalse(model.workingGraphics.contains { $0.surface == address.surface })
      XCTAssertNotNil(model.actionCue)
      XCTAssertNil(model.selectionSession.target)
    }
  }

  func testEarlyMixedInkCutKeepsMeasurementsTransparencyErasureAndLaterStrokeThroughUndo() async throws {
    try await fixture { model,page,shape,address,_ in
      func sample(_ x:Double,_ y:Double,_ width:Double,_ opacity:Double)->SpatialInkSample {
        .init(point:.init(x:x,y:y),timeOffset:x/1000,width:width,opacity:opacity,force:opacity,azimuth:0.7,altitude:1)
      }
      let ink=PageInkAction(tool:.pen,color:.init(red:0.1,green:0.2,blue:0.9),
        samples:[sample(110,150,8,0.2),sample(170,150,10,0.9),sample(280,150,12,0.6)],sequence:1)
      let eraser=PageInkAction(tool:.eraser,samples:[sample(145,120,12,1),sample(145,180,12,1)],sequence:2)
      var page=page
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions:[ink,eraser]).dataRepresentation(),actor:model.actorID))
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      let polygon=[SpatialPoint(x:90,y:90),.init(x:180,y:90),.init(x:180,y:210),.init(x:90,y:210)]
      let raw=try XCTUnwrap(NotebookLassoInkSource.page(page).selection(polygon:polygon,surface:address.surface,origin:nil,bounds:nil))
      var ready=NotebookRegionSelection(id:UUID(),address:address,polygon:polygon,
        frame:.init(x:90,y:90,width:90,height:120),rawInk:raw,
        expectedInkRevision:page.drawingStamp.revision,graphics:[address.reference(shape.id)])
      ready.materialization=try NotebookRegionMaterialization.prepare(ready,graph:model.graphicGraph(page:page),snapshot:model.regionSourceSnapshot(address))
      let gate=Gate();defer { Task { await gate.release() } }
      delayed(ready,gate:gate,model:model)
      let contact=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:40,y:200)))
      model.selectDrawingTool(.pen)
      let later=PageInkAction(tool:.pen,color:.init(red:0.9,green:0.1,blue:0.2),samples:[sample(150,150,5,0.5)],sequence:3)
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(later,pageID:page.id,stamp:stamp))
      await gate.release()
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved,model.actionCue ?? "")
      let reopened=try NotebookStore(root:model.store.root).loadPage(page.id)
      XCTAssertEqual(try reopened.inkDrawing().activeActions,[ink,eraser,later])
      let converted=try XCTUnwrap(reopened.element(id:ready.id.uuidString.lowercased()),model.actionCue ?? "")
      let prepared=try XCTUnwrap(ready.materialization?.working.first { $0.id == converted.id })
      XCTAssertEqual(converted.graphic,prepared.graphic,"Lift cannot alter measurements, colors, alpha, pressure or captured cuts")
      XCTAssertEqual(converted.frame.x,prepared.frame.x+40,accuracy:1e-8)
      XCTAssertEqual(converted.frame.y,prepared.frame.y+200,accuracy:1e-8)
      XCTAssertEqual(converted.graphic?.sourceInkIDs,[ink.id])
      XCTAssertFalse(reopened.elements.contains { $0.graphic?.sourceInkIDs.contains(later.id) == true })
      model.undoLastSurfaceAction();let inkUndone=await model.finishPendingPersistence();XCTAssertTrue(inkUndone)
      model.undoLastSurfaceAction();let cutUndone=await model.finishPendingPersistence();XCTAssertTrue(cutUndone)
      let restored=try model.store.loadPage(page.id)
      XCTAssertEqual(try restored.inkDrawing().activeActions,[ink,eraser])
      XCTAssertEqual(restored.graphicPresentation.geometryIDs,[shape.id])
      XCTAssertEqual(restored.element(id:shape.id),shape)
    }
  }

  private func delayed(_ ready:NotebookRegionSelection,gate:Gate,model:NotebookAppModel) {
    var pending=ready;pending.materialization=nil
    pending.preparation=NotebookRegionPreparation(Task { await gate.wait();return ready })
    model.selectRegion(pending)
  }

  private func fixture(_ run:(NotebookAppModel,PageDocument,AgentElement,NotebookToolAddress,NotebookRegionSelection) async throws -> Void) async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("lasso-acceptance-\(UUID())")
    let model=NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:UserDefaults(suiteName:UUID().uuidString)!)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize);_ = await model.finishPendingPersistence()
    var page=try XCTUnwrap(model.activePage)
    let shape=AgentElement(id:"source",kind:.graphic,frame:.init(x:100,y:100,width:200,height:100),source:"",html:"",
      graphic:.init(shape:.rectangle,style:.init(strokeWidth:4,fill:.init(red:0.9,green:0.3,blue:0.1))))
    XCTAssertTrue(page.replaceElements([shape],actor:model.actorID));try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
    var ready=NotebookRegionSelection(id:UUID(),address:address,
      polygon:[.init(x:90,y:90),.init(x:180,y:90),.init(x:180,y:210),.init(x:90,y:210)],
      frame:.init(x:90,y:90,width:90,height:120),rawInk:nil,expectedInkRevision:page.drawingStamp.revision,graphics:[address.reference(shape.id)])
    ready.materialization=try NotebookRegionMaterialization.prepare(ready,graph:model.graphicGraph(page:page),snapshot:model.regionSourceSnapshot(address))
    try await run(model,page,shape,address,ready)
  }
}
