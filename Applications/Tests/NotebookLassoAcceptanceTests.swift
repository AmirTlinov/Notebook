import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookLassoAcceptanceTests:XCTestCase {
  private actor Gate {
    private var open=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    var waitingCount:Int {waiters.count}
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open=true;let pending=waiters;waiters=[];for waiter in pending { waiter.resume() } }
  }

  func testPreparationWaitsOnlyForAcceptedMaterialOnItsOwnSurface() async throws {
    try await fixture { model,page,_,address,_ in
      let gate=Gate(),board=try XCTUnwrap(model.workspace?.rootBoardID)
      let pending=Task { await gate.wait() }
      defer { model.pendingMaterialAdmissions.removeAll();Task { await gate.release() } }
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      model.pendingMaterialAdmissions[.board(board)] = .init(id:UUID(),task:pending)
      let polygon=[SpatialPoint(x:110,y:110),.init(x:170,y:110),.init(x:170,y:190),.init(x:110,y:190)]
      @MainActor func cut() throws -> NotebookRegionPreparation {
        XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
        for p in polygon.dropFirst() { model.drawingTools.move(to:p) }
        model.drawingTools.finish()
        return try XCTUnwrap(model.selectionSession.region?.preparation)
      }
      _ = try cut()
      let deadline=ContinuousClock.now + .milliseconds(100)
      while model.selectionSession.region?.materialization == nil,ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(1))
      }
      XCTAssertNotNil(model.selectionSession.region?.materialization,
        "The board's accepted tail cannot hold a read of an independent page")
      model.clearSelection()
      model.pendingMaterialAdmissions[.page(page.id)] = .init(id:UUID(),task:pending)
      let same=try cut()
      try await Task.sleep(for:.milliseconds(20))
      XCTAssertNil(model.selectionSession.region?.materialization,"A same-surface predecessor remains causal")
      await gate.release()
      let ready=try await same.task.value
      XCTAssertNotNil(ready?.materialization)
    }
  }

  func testLiftBeforePreparationSurvivesNewFocusToolAndInkWithoutOvertaking() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      try delayed(ready,gate:gate,model:model)
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

  func testDeleteBeforePreparationSurvivesNewFocusAndInkAndKeepsUndoOrder() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      try delayed(ready,gate:gate,model:model)
      model.deleteSelectedContent()
      XCTAssertNil(model.selectionSession.target)
      XCTAssertNotNil(model.graphicCommandTask,"Delete must enter the writer before its material finishes")
      model.selectElement(address.reference(shape.id));model.selectDrawingTool(.pen)
      let later=PageInkAction(tool:.pen,samples:[.init(point:.init(x:500,y:500),timeOffset:0,
        width:4,opacity:0.6,force:0.7,azimuth:1,altitude:1)])
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(later,pageID:page.id,stamp:stamp))
      await Task.yield()
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
      XCTAssertTrue(try model.store.loadPage(page.id).inkDrawing().actions.isEmpty)
      await gate.release()
      let finished=await model.finishPendingPersistence();XCTAssertTrue(finished,model.actionCue ?? "")
      let saved=try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.map(\.id),[shape.id])
      XCTAssertEqual(saved.element(id:shape.id)?.graphic?.mask?.operations.count,1)
      XCTAssertEqual(try saved.inkDrawing().activeActions.map(\.id),[later.id])
      XCTAssertEqual(model.collaborationActions.filter { $0.action.summary == "Удалить область лассо" }.count,1)
      XCTAssertNil(model.selectionSession.target,"Completing Delete must not restore the old contour")
      model.undoLastSurfaceAction();let penUndone=await model.finishPendingPersistence();XCTAssertTrue(penUndone)
      XCTAssertTrue(try model.store.loadPage(page.id).inkDrawing().activeActions.isEmpty)
      XCTAssertNotNil(try model.store.loadPage(page.id).element(id:shape.id)?.graphic?.mask)
      model.undoLastSurfaceAction();let deleteUndone=await model.finishPendingPersistence();XCTAssertTrue(deleteUndone)
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
    }
  }

  func testDeleteAfterEarlyMoveAddressesTheAcceptedFragmentBeforeEitherPreparationFinishes() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      try delayed(ready,gate:gate,model:model)
      let contact=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:40,y:20)))
      XCTAssertNotNil(model.selectionSession.region?.preparation)
      model.deleteSelectedContent();model.selectDrawingTool(.pen)
      await gate.release()
      let finished=await model.finishPendingPersistence();XCTAssertTrue(finished,model.actionCue ?? "")
      let saved=try model.store.loadPage(page.id)
      let moves=model.collaborationActions.filter { $0.action.summary == "Переместить область лассо" }
      let deletions=model.collaborationActions.filter { $0.action.summary == "Удалить область лассо" }
      XCTAssertEqual(moves.count,1);XCTAssertEqual(deletions.count,1)
      let created=try XCTUnwrap(moves.first).action.operations.filter { $0.kind == .insertElement }
      XCTAssertEqual(created.count,1)
      let fragmentID=try XCTUnwrap(created.first?.id),deleted=try XCTUnwrap(deletions.first)
      let hidden=try XCTUnwrap(saved.element(id:fragmentID))
      // Graphic deletion retains its causal identity and changes visibility.
      // The accepted Delete must name the preceding Move's exact fragment.
      XCTAssertEqual(deleted.action.operations.map(\.kind),[.removeElement])
      XCTAssertEqual(deleted.action.operations.map(\.id),[fragmentID])
      XCTAssertEqual(deleted.action.operations.first?.target,address.target)
      XCTAssertEqual(saved.elements.map(\.id),[shape.id,fragmentID])
      XCTAssertEqual(saved.graphicPresentation.geometryIDs,[shape.id])
      XCTAssertEqual(hidden.graphic?.visible,false)
      XCTAssertEqual(saved.element(id:shape.id)?.graphic?.visible,true)
      XCTAssertEqual(saved.element(id:shape.id)?.graphic?.mask?.operations.count,1)
      model.undoLastSurfaceAction();let deleteUndone=await model.finishPendingPersistence();XCTAssertTrue(deleteUndone)
      let restored=try model.store.loadPage(page.id)
      let fragment=try XCTUnwrap(restored.element(id:fragmentID))
      XCTAssertEqual(restored.elements.map(\.id),[shape.id,fragmentID])
      XCTAssertEqual(restored.graphicPresentation.geometryIDs,[shape.id,fragmentID])
      var shownGraphic=try XCTUnwrap(hidden.graphic);shownGraphic.visible=true
      XCTAssertEqual(fragment.graphic,shownGraphic,"Undo restores that same fragment's visibility without replacing its geometry")
      XCTAssertEqual(fragment.frame.x,shape.frame.x+40,accuracy:1e-8)
      XCTAssertEqual(fragment.frame.y,shape.frame.y+20,accuracy:1e-8)
      model.undoLastSurfaceAction();let moveUndone=await model.finishPendingPersistence();XCTAssertTrue(moveUndone)
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
    }
  }

  func testAcceptedPendingDeleteCannotBorrowAForeignReplacement() async throws {
    try await fixture { model,page,shape,_,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      try delayed(ready,gate:gate,model:model)
      model.deleteSelectedContent();model.selectDrawingTool(.pen)
      var changed=try model.store.loadPage(page.id)
      let replacement=shape.updating(frame:.init(x:120,y:100,width:200,height:100))
      XCTAssertTrue(changed.replaceElements([replacement],actor:UUID()));try model.store.savePage(changed)
      await gate.release();_ = await model.finishPendingPersistence()
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[replacement])
      XCTAssertFalse(model.collaborationActions.contains { $0.action.summary == "Удалить область лассо" })
      XCTAssertFalse(model.workingGraphics.contains { $0.surface == ready.address.surface })
      XCTAssertNil(model.selectionSession.target)
      XCTAssertNotNil(model.actionCue)
    }
  }

  func testTwoEarlyLiftsAndNextLassoChainAcceptedMaterialWithoutWaitingForSave() async throws {
    try await fixture { model,page,shape,address,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      try delayed(ready,gate:gate,model:model)
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
      // Use the actual installed iPad adapter, not the shared helper that
      // previously hid its separate stale agent-snapshot selection route.
      let receiver=try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SceneSelectionRecognizer }.first)
      receiver.onPoint?(point,1)
      XCTAssertEqual(model.selectionSession.element,fragment,"A fresh tap reaches the accepted insertion before SQL")
      model.clearSelection()
      let lift=try XCTUnwrap(receiver.onLift?(point),"A fresh body drag must not require a saved agent capture")
      lift.begin()
      XCTAssertEqual(model.selectionSession.manipulation?.reference,fragment)
      let delta=CGPoint(x:30*presence.camera.scale,y:10*presence.camera.scale)
      lift.change(delta);lift.end(delta)
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
      try delayed(ready,gate:gate,model:model)
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
      try delayed(ready,gate:gate,model:model)
      let contact=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:40,y:200)))
      model.selectDrawingTool(.pen)
      let later=PageInkAction(tool:.pen,color:.init(red:0.9,green:0.1,blue:0.2),samples:[sample(150,150,5,0.5)],sequence:3)
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(later,pageID:page.id,stamp:stamp))
      await gate.release()
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved,model.actionCue ?? "")
      let reopened=try NotebookStore(root:model.store.root).loadPage(page.id)
      let acceptedLater=PageInkAction(id:later.id,tool:later.tool,color:later.color,
        measurements:later.samples,sequence:later.sequence,elementTargets:later.elementTargets,stateStamp:stamp)
      XCTAssertEqual(try reopened.inkDrawing().activeActions,[ink,eraser,acceptedLater])
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

  func testCapturedAllowanceCoversTheReadyPlanAndRejectsKnownOverflow() async throws {
    try await fixture { model,page,_,address,ready in
      let material=try XCTUnwrap(ready.materialization)
      XCTAssertNotNil(material.sources[address.reference("source")]?.versions,
        "The compact material keeps the causal frontier used by the writer's early guard")
      let edits=try material.encodedEdits()
      var plan=try XCTUnwrap(model.prepareElementOperations(edits,summary:"Переместить область лассо",
        readSources:Array(material.sources.keys),insertionTarget:address.target,
        expectedInkRevision:ready.expectedInkRevision,previews:false,
        frozenSources:material.commandSources(at:address),frozenDependencies:material.dependencies))
      plan.working=material.working
      let measured=try NotebookElementWriteAllowance.cost(plan)
      let pending=try capturedAllowance(ready,model:model).cost()
      let prepared=try model.regionWriteAllowance(ready).cost()
      XCTAssertGreaterThanOrEqual(pending.bytes,measured.bytes)
      XCTAssertGreaterThanOrEqual(prepared.bytes,measured.bytes)
      XCTAssertLessThan(pending.bytes+prepared.bytes,128*1_024*1_024,
        "A small pending cut leaves the next Pencil contact's existing reserve available")
      let captured=try capturedAllowance(ready,model:model)
      XCTAssertNoThrow(try captured.validateReplacement(captured))
      XCTAssertThrowsError(try captured.validateReplacement(.init(retainedBytes:1_024*1_024,
        bodyBytes:1_024*1_024,causalBytes:0,elementCount:1,contourCount:4)),
        "A later live publication cannot borrow the already accepted cut's credit")
      XCTAssertThrowsError(try NotebookRegionWriteAllowance(retainedBytes:0,
        bodyBytes:NotebookElementWriteAllowance.maximumCost.bytes,causalBytes:0,elementCount:1,contourCount:4).cost()) {
        XCTAssertEqual(($0 as? CollaborationError)?.code,"resource_limit")
      }
      XCTAssertEqual(try model.store.loadPage(page.id).elements,page.elements)
    }
  }

  func testColdFirstLassoAcceptsMoveDeleteAndPencilWhileExactInkPreparationIsSuspended() async throws {
    try await assertColdFirstLassoAcceptsMoveDeleteAndPencil(contactCount:1)
  }

  func testColdFirstLassoWithOneHundredThousandContactsAcceptsMoveDeleteAndPencil() async throws {
    try await assertColdFirstLassoAcceptsMoveDeleteAndPencil(contactCount:100_000)
  }

  private func assertColdFirstLassoAcceptsMoveDeleteAndPencil(contactCount:Int) async throws {
    try await fixture { model,page,shape,address,_ in
      let (original,archive,ids)=try await Task.detached(priority:.userInitiated) {
        let original=PageInkAction(tool:.pen,samples:[110.0,170,280].map {
          .init(point:.init(x:$0,y:150),timeOffset:$0/1000,width:5,opacity:0.6,force:0.7,azimuth:0.4,altitude:1)
        },sequence:1)
        let foreign=(1..<contactCount).map {i in PageInkAction(tool:.pen,samples:[
          .init(point:.init(x:700,y:1000),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)
        ],sequence:UInt64(i+1))}
        let actions=[original]+foreign
        return (original,try PageInkDrawing(actions:actions).dataRepresentation(),actions.map(\.id))
      }.value
      var page=page
      XCTAssertTrue(page.replaceDrawing(archive,actor:model.actorID))
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      XCTAssertNotNil(model.pages[page.id]?.preparedInkDrawing,"The normal scene read publishes its input-ready root")
      let gate=Gate()
      defer {model.drawingTools.beforeInkPreparation=nil;Task {await gate.release()}}
      model.drawingTools.beforeInkPreparation = {await gate.wait()}
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      let points=[SpatialPoint(x:90,y:90),.init(x:180,y:90),.init(x:180,y:210),.init(x:90,y:210)]
      let downStart=ContinuousClock.now
      XCTAssertTrue(model.drawingTools.begin(at:points[0],address:address,screenScale:1))
      let downTime=downStart.duration(to:.now)
      for point in points.dropFirst() {model.drawingTools.move(to:point)}
      let liftStart=ContinuousClock.now
      model.drawingTools.finish()
      let liftTime=liftStart.duration(to:.now)
      let pending=try XCTUnwrap(model.selectionSession.region),preparation=try XCTUnwrap(pending.preparation)
      XCTAssertNil(model.drawingTools.pendingLasso?.ink,"Pending presentation releases the pointer-down journal")
      XCTAssertNil(model.drawingTools.pendingLasso?.spatialSelection)
      XCTAssertNil(pending.materialization)
      let deadline=ContinuousClock.now + .seconds(1)
      while await gate.waitingCount == 0,ContinuousClock.now < deadline {await Task.yield()}
      let waiting=await gate.waitingCount;XCTAssertEqual(waiting,1)
      let admittedBytes=try preparation.allowance.cost().bytes
      XCTAssertLessThan(admittedBytes,128*1_024*1_024,
        "Admission comes from the ready ink owner, while the first exact lasso task remains suspended")
      let commandStart=ContinuousClock.now
      let contact=try XCTUnwrap(model.beginElementManipulation(pending.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:40,y:200)))
      model.deleteSelectedContent()
      let commandTime=commandStart.duration(to:.now)
      print("LASSO_COLD_CONTROLLER contacts=\(contactCount) down=\(downTime) lift=\(liftTime) move_delete=\(commandTime) admitted_bytes=\(admittedBytes)")
      XCTAssertNotNil(model.graphicCommandTask)
      model.selectDrawingTool(.pen)
      let later=PageInkAction(tool:.pen,samples:[.init(point:.init(x:50,y:50),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)])
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(later,pageID:page.id,stamp:stamp))
      await gate.release()
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved,model.actionCue ?? "")
      XCTAssertEqual(model.collaborationActions.filter {$0.action.summary == "Переместить область лассо"}.count,1)
      XCTAssertEqual(model.collaborationActions.filter {$0.action.summary == "Удалить область лассо"}.count,1)
      let after=try model.store.loadPage(page.id)
      XCTAssertEqual(try after.inkDrawing().action(id:original.id)?.samples,original.samples)
      XCTAssertNotNil(try after.inkDrawing().action(id:later.id))
      for _ in 0..<3 {model.undoLastSurfaceAction();let undone=await model.finishPendingPersistence();XCTAssertTrue(undone)}
      let restored=try model.store.loadPage(page.id)
      XCTAssertEqual(restored.graphicPresentation.geometryIDs,[shape.id])
      XCTAssertEqual(restored.element(id:shape.id),shape)
      XCTAssertEqual(try restored.inkDrawing().activeActions.map(\.id),ids)
      XCTAssertEqual(try restored.inkDrawing().action(id:original.id),original)
    }
  }

  func testPendingLassoRefusesTheSameFullWriterBudgetAndCanBeRetried() async throws {
    try await fixture { model,page,shape,_,ready in
      let gate=Gate();defer { Task { await gate.release() } }
      try delayed(ready,gate:gate,model:model)
      let preparation=try XCTUnwrap(model.selectionSession.region?.preparation)
      let occupied=try XCTUnwrap(model.reserveElementPreparation(cost:.init(
        payloadBytes:NotebookPersistenceAdmission.Limits().maximumBytes)))
      let refused=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertFalse(model.finishElementManipulation(refused,translation:.init(x:40,y:20)))
      XCTAssertFalse(preparation.claimed)
      XCTAssertNil(model.graphicCommandTask)
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape])
      model.releaseElementPreparation(occupied)
      let retry=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(retry,translation:.init(x:40,y:20)))
      XCTAssertTrue(preparation.claimed)
      await gate.release()
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved,model.actionCue ?? "")
      XCTAssertEqual(model.collaborationActions.filter { $0.action.summary == "Переместить область лассо" }.count,1)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,2)
    }
  }

  func testColdSmallLassoAdmissionDoesNotGrowWithOneHundredThousandForeignBodies() async throws {
    let scenes=try await Task.detached(priority:.userInitiated) {
      struct Clock:Encodable { let stamp:VersionStamp,human=true,observed:[String:UInt64] }
      struct Metadata:Encodable { let fields:[String:Clock] }
      struct Archive:Encodable {
        let format=PageDocument.formatVersion,id=UUID(),size=PageSize(width:2048,height:2048),drawingData=Data()
        let drawingStamp:VersionStamp,agentStamp:VersionStamp,elements:[AgentElement],collaboration:Metadata
      }
      let stamp=VersionStamp(counter:1,actor:UUID())
      let version=Clock(stamp:stamp,observed:[stamp.actor.uuidString.lowercased():stamp.counter])
      return try [1,100_000].map { count in
        let elements=(0..<count).map { i in AgentElement(id:"part-\(i)",kind:.graphic,
          frame:.init(x:i == 0 ? 10 : 1500,y:i == 0 ? 10 : 1500,width:10,height:10),source:"",html:"",
          graphic:.init(shape:.rectangle,style:.init(fill:.black))) }
        let metadata=Metadata(fields:Dictionary(uniqueKeysWithValues:elements.map {
          ("elements/\($0.id)/id",version)
        }))
        let page=try JSONDecoder().decode(PageDocument.self,from:JSONEncoder().encode(
          Archive(drawingStamp:stamp,agentStamp:stamp,elements:elements,collaboration:metadata)))
        // Scene publication owns these existing indices. The new capture and
        // its first causal/payload measurement are deliberately left cold.
        let start=ContinuousClock.now,graph=page.graphicGraph()
        graph.prepareVisibility(on:.page(page.id))
        try page.prepareInkForPresentation()
        return (page,graph,NotebookLassoInkSource.page(page),start.duration(to:.now))
      }
    }.value
    let polygon=[SpatialPoint(x:5,y:5),.init(x:25,y:5),.init(x:25,y:25),.init(x:5,y:25)]
    let admission=NotebookPersistenceAdmission(limits:.init())
    var admitted:[Int]=[]
    for (page,graph,ink,indexTime) in scenes {
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let start=ContinuousClock.now
      let ids=try NotebookLassoQuery.regionCandidates(polygon,at:address,graph:graph,spatial:nil)
      let cut=try graph.capturing(ids,maximumCount:NotebookLassoQuery.maximumCandidates)
      let snapshot=NotebookRegionSourceSnapshot(page:page,board:nil).capturing(cut.ids)
      let captured=try XCTUnwrap(try ink.regionCapture(polygon:polygon,surface:address.surface,origin:nil,elements:ids,excluding:[]))
      let cost=try snapshot.writeAllowance(graph:cut.graph,inkBytes:captured.retainedPayloadBytes,
        inkMaterialBytes:captured.materialBytes,
        erasureBytes:(128,128),contourCount:polygon.count).cost()
      let reservation=try XCTUnwrap(admission.reserve(cost))
      let charge=try admission.transfer(reservation)
      let elapsed=start.duration(to:.now)
      XCTAssertEqual(cut.ids,["part-0"])
      XCTAssertEqual(admission.occupiedBytes,cost.bytes)
      XCTAssertEqual(admission.acceptedPayloadBytes+admission.acceptedCompletionBytes,cost.bytes)
      XCTAssertLessThan(cost.bytes,128*1_024*1_024)
      XCTAssertLessThan(elapsed,.milliseconds(20),"First addressed admission stays on the input path's budget")
      admitted.append(admission.occupiedBytes)
      print("LASSO_COLD_ADMISSION bodies=\(page.elements.count) causal_fields=\(page.collaboration!.fields.count) scene_index=\(indexTime) cold_capture=\(elapsed) admitted_bytes=\(cost.bytes)")
      admission.releaseCharge(charge)
      XCTAssertEqual(admission.occupiedBytes,0)
    }
    XCTAssertEqual(admitted[0],admitted[1],"A small contour's credit cannot depend on foreign bodies or causal clocks")
  }

  func testSmallPendingInkCutExcludesOneHundredThousandForeignMeasurementsFromTheResultCredit() async throws {
    try await fixture { model,page,shape,address,_ in
      let material=try await Task.detached(priority:.userInitiated) {
        func sample(_ x:Double,_ y:Double,_ i:Int)->SpatialInkSample {
          .init(point:.init(x:x,y:y),timeOffset:Double(i)/240,width:3+Double(i%7)/8,
            opacity:0.7,force:0.5,azimuth:0.7,altitude:1)
        }
        let chosen=PageInkAction(tool:.pen,samples:[sample(110,150,0),sample(170,150,1),sample(280,150,2)],sequence:1)
        // This cut is outside the contour, inside the complete chosen pen.
        let outsideCut=PageInkAction(tool:.eraser,samples:[sample(250,145,0),sample(250,155,1)],sequence:2)
        let targetCut=PageInkAction(tool:.eraser,samples:[sample(140,145,0),sample(140,155,1)],sequence:3,
          elementTargets:[.init(elementID:shape.id,frame:shape.frame)])
        let foreign=(0..<100).map { action in
          PageInkAction(tool:action.isMultiple(of:2) ? .pen : .eraser,
            samples:(0..<1_000).map { i in sample(700+sin(Double(i)*0.731),1000+cos(Double(i)*0.513),i) },
            sequence:UInt64(action+4),elementTargets:action.isMultiple(of:2) ? nil :
              [.init(elementID:"foreign",frame:.init(x:680,y:980,width:40,height:40))])
        }
        return (try PageInkDrawing(actions:[chosen,outsideCut,targetCut]+foreign).dataRepresentation(),chosen,outsideCut,
          try PageInkDrawing(actions:[chosen,outsideCut,targetCut]).dataRepresentation())
      }.value
      var page=page
      XCTAssertTrue(page.replaceDrawing(material.0,actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let polygon=[SpatialPoint(x:90,y:90),.init(x:180,y:90),.init(x:180,y:210),.init(x:90,y:210)]
      let current=try XCTUnwrap(model.pages[page.id])
      let actor=model.actorID
      let small=try await Task.detached(priority:.userInitiated) {
        var small=current
        _ = small.replaceDrawing(material.3,actor:actor)
        try small.prepareInkForPresentation()
        return NotebookLassoInkSource.page(small)
      }.value
      let retained=try XCTUnwrap(current.inkSource.retainedPayloadBytes)
      let start=ContinuousClock.now
      let capture=try XCTUnwrap(try NotebookLassoInkSource.page(current).regionCapture(polygon:polygon,
        surface:address.surface,origin:nil,elements:[shape.id],excluding:[]))
      let elapsed=start.duration(to:.now)
      let smallCapture=try XCTUnwrap(try small.regionCapture(polygon:polygon,surface:address.surface,origin:nil,elements:[shape.id],excluding:[]))
      XCTAssertEqual(capture.materialBytes,smallCapture.materialBytes)
      XCTAssertEqual(capture.retainedPayloadBytes,smallCapture.retainedPayloadBytes)
      XCTAssertLessThan(elapsed,.milliseconds(20),"The first bounded query does not visit foreign measurements")
      XCTAssertGreaterThan(retained,512*1_024,"The previous whole-journal multiplier would reject this tiny cut")
      XCTAssertLessThan(capture.retainedPayloadBytes,retained/16)
      let prepared=try NotebookLassoInkSource.Prepared(capture:capture,revision:current.drawingStamp.revision,
        surface:address.surface,origin:nil,excluding:[])
      XCTAssertTrue(prepared.candidateActionIDs(intersecting:polygon,surface:address.surface,origin:nil).contains(material.2.id))
      let cuts=capture.erasures
      XCTAssertEqual(cuts[shape.id]?.count,1);XCTAssertNil(cuts["foreign"])
      let raw=try XCTUnwrap(prepared.selection(polygon:polygon,surface:address.surface,origin:nil,bounds:nil))
      var ready=NotebookRegionSelection(id:UUID(),address:address,polygon:polygon,
        frame:.init(x:90,y:90,width:90,height:120),rawInk:raw,
        expectedInkRevision:current.drawingStamp.revision,graphics:[address.reference(shape.id)])
      ready.materialization=try NotebookRegionMaterialization.prepare(ready,graph:model.graphicGraph(page:current),
        snapshot:model.regionSourceSnapshot(address),erasures:cuts)
      let cost=try capturedAllowance(ready,model:model).cost()
      XCTAssertLessThan(cost.bytes,128*1_024*1_024)
      let gate=Gate();defer {Task {await gate.release()}}
      try delayed(ready,gate:gate,model:model)
      let first=try XCTUnwrap(model.beginElementManipulation(ready.reference,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:40,y:20)))
      model.deleteSelectedContent()
      XCTAssertNotNil(model.graphicCommandTask)
      model.selectDrawingTool(.pen)
      let later=PageInkAction(tool:.pen,samples:[.init(point:.init(x:50,y:50),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)])
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(later,pageID:page.id,stamp:stamp))
      await gate.release()
      let saved=await model.finishPendingPersistence();XCTAssertTrue(saved,model.actionCue ?? "")
      XCTAssertEqual(model.collaborationActions.filter {$0.action.summary == "Переместить область лассо"}.count,1)
      XCTAssertEqual(model.collaborationActions.filter {$0.action.summary == "Удалить область лассо"}.count,1)
      let ink=try model.store.loadPage(page.id).inkDrawing()
      XCTAssertEqual(ink.action(id:material.1.id)?.samples,material.1.samples)
      XCTAssertNotNil(ink.action(id:later.id))
      print("LASSO_INK_ADMISSION foreign_samples=100000 journal_bytes=\(retained) candidate_body_bytes=\(capture.materialBytes) cold_query=\(elapsed) first_action_bytes=\(cost.bytes)")
    }
  }

  private func capturedAllowance(_ region:NotebookRegionSelection,model:NotebookAppModel) throws ->NotebookRegionWriteAllowance {
    guard let id=region.address.surface.ownerID,let page=model.pages[id] else { return .maximum }
    let graph=model.graphicGraph(page:page)
    let ids=try NotebookLassoQuery.regionCandidates(region.polygon,at:region.address,graph:graph,spatial:nil)
    let cut=try graph.capturing(ids,maximumCount:NotebookLassoQuery.maximumCandidates)
    let ink=try XCTUnwrap(try NotebookLassoInkSource.page(page).regionCapture(polygon:region.polygon,
      surface:region.address.surface,origin:region.address.worldOrigin,elements:ids,excluding:[]))
    return model.regionSourceSnapshot(region.address).capturing(cut.ids).writeAllowance(graph:cut.graph,
      inkBytes:ink.retainedPayloadBytes,inkMaterialBytes:ink.materialBytes,
      erasureBytes:(128,NotebookRegionWriteAllowance.erasureBytes(ink.erasures)),contourCount:region.polygon.count)
  }

  private func delayed(_ ready:NotebookRegionSelection,gate:Gate,model:NotebookAppModel) throws {
    var pending=ready;pending.materialization=nil
    pending.preparation=NotebookRegionPreparation(Task { await gate.wait();return ready },
      allowance:try capturedAllowance(ready,model:model))
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
