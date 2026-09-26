import NotebookCore
import XCTest
import UIKit
import SwiftUI
@testable import Notebook

@MainActor final class NotebookDrawingToolsTests: XCTestCase {
  func testTapSelectsAndMovesTheWholeMeasuredContactWithoutCreatingARemainder() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let samples=(0..<4_097).map { i in
        SpatialInkSample(point:.init(x:100+600*Double(i)/4_096,y:200),timeOffset:Double(i)/240,
          width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)
      }
      let pen=PageInkAction(tool:.pen,samples:samples)
      let cut=PageInkAction(tool:.eraser,samples:[180.0,220].map { y in
        .init(point:.init(x:500,y:y),timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:.pi/2)
      })
      let drawing=try PageInkDrawing(actions:[pen,cut]).dataRepresentation()
      XCTAssertTrue(page.replaceDrawing(drawing,actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let presence=try XCTUnwrap(model.presence),itemID=try XCTUnwrap(model.workspace?.selectedItemID)
      model.updatePresence(.init(boardID:presence.boardID,mode:.page,camera:presence.camera,
        viewport:presence.viewport,focusedItemID:itemID,openProgress:1,
        selectedItemID:itemID,notebookPageID:page.id),settled:true)
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,
        bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .elements
      model.drawingTools.selectInk(at:.init(x:200,y:200),address:address,screenScale:1)
      let deadline=ContinuousClock.now + .seconds(5)
      while model.drawingTools.pendingLasso != nil,ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(5))
      }
      XCTAssertNil(model.selectionSession.region)
      XCTAssertTrue(model.selectionSession.elements.isEmpty,"Accepted raw contacts are not fake canonical elements")
      let selected=try XCTUnwrap(model.selectionSession.ink.first),raw=selected.material
      XCTAssertEqual(model.selectionSession.count,1)
      XCTAssertLessThan(raw.frame.x,100);XCTAssertGreaterThan(raw.frame.x+raw.frame.width,700)
      XCTAssertEqual(raw.graphic.sourceInkIDs,[pen.id])
      XCTAssertEqual(raw.graphic.freehand?.layers.first?.measured?.measurements,pen.samples)
      XCTAssertEqual(raw.graphic.freehand?.layers.last?.measured?.measurements,cut.samples,
        "Whole picking retains later erasure even outside the hit tolerance")
      XCTAssertNil(raw.graphic.mask,"Hit tolerance is not an authored clipping polygon")
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,drawing)
      XCTAssertTrue(try model.store.loadPage(page.id).elements.isEmpty,"Selection is read-only")

      try await self.withMountedWholePage(model,pageID:page.id) { _,_ in
      let movement=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
      XCTAssertTrue(model.finishElementManipulation(movement,translation:.init(x:0,y:40)))
      await assertSaved(model)
      let moved=try model.store.loadPage(page.id),element=try XCTUnwrap(moved.elements.first)
      XCTAssertEqual(moved.elements.count,1)
      XCTAssertEqual(element.frame.y,raw.selectionFrame.y+40,accuracy:1e-8)
      XCTAssertEqual(element.graphic?.sourceInkIDs,[pen.id])
      XCTAssertNil(element.graphic?.mask)
      XCTAssertEqual(moved.drawingData,drawing,"Moving a whole retains the immutable measured journal")
      model.undoLastSurfaceAction();await assertSaved(model)
      let restored=try model.store.loadPage(page.id)
      XCTAssertEqual(restored.elements.map(\.id),[element.id],"Undo retains the conversion's durable identity")
      XCTAssertTrue(restored.graphicPresentation.geometryIDs.isEmpty)
      XCTAssertTrue(restored.graphicPresentation.suppressedInkIDs.isEmpty,"The same complete measured contact becomes visible again")
      XCTAssertEqual(restored.drawingData,drawing)
      }
    }
  }

  func testWholeElementsKeepsTwoContactsAndTheirAuthoredPeerThroughOneMoveAndCopy() async throws {
    try await withWholeSelection { model,page,strokes,address in
      try await self.selectWholeContour(model,address:address)
      XCTAssertEqual(model.selectionSession.elements,[address.reference("whole-peer")])
      XCTAssertEqual(model.selectionSession.ink.map(\.actionID),strokes.map(\.id))
      XCTAssertEqual(model.selectionSession.count,3)
      XCTAssertNil(model.selectionSession.region)
      for (selected,stroke) in zip(model.selectionSession.ink,strokes) {
        XCTAssertEqual(selected.material.graphic.freehand?.layers.first?.measured?.measurements,stroke.samples)
        XCTAssertLessThan(selected.material.frame.x,100);XCTAssertGreaterThan(selected.material.frame.x+selected.material.frame.width,700)
        XCTAssertNil(selected.material.graphic.mask)
      }
      XCTAssertEqual(try model.store.loadPage(page.id).elements.map(\.id),["whole-peer"])
      let selection=model.selectionSession
      let snapshot=try model.clipboardSelectionSnapshot()
      XCTAssertEqual(Set(snapshot.sourceChecks.keys),[address.reference("whole-peer")],"Raw member IDs must not be read as authored elements")
      let copied=try await Task.detached { try snapshot.prepare() }.value
      XCTAssertEqual(copied.fragment.elements.count,3)
      XCTAssertTrue(copied.fragment.elements.allSatisfy { $0.graphic?.sourceInkIDs.isEmpty == true })
      XCTAssertEqual(copied.fragment.elements.compactMap { $0.graphic?.freehand?.layers.first?.measured?.measurements },strokes.map(\.samples))
      XCTAssertEqual(model.selectionSession,selection,"Copy preparation neither converts contacts nor changes the choice")
      XCTAssertFalse(model.canGroupSelectedElements);XCTAssertTrue(model.availableLayerMoves.isEmpty)
      let before=Set(try model.store.actionReadModels().map(\.id))
      model.groupSelectedElements();model.arrangeSelection(.toFront)
      model.setGraphicStyle(reference:address.reference("whole-peer")) { $0.strokeWidth=30 }
      await self.assertSaved(model)
      XCTAssertEqual(Set(try model.store.actionReadModels().map(\.id)),before,"Disabled whole-set commands cannot edit only the authored subset")
      let raw=try XCTUnwrap(model.pageInkPublication.currentCanvas(on:page.id))
      let paper=try XCTUnwrap(raw.superview as? PaperCanvasContainerView),window=try XCTUnwrap(paper.window)
      @MainActor func point(_ x:Double,_ y:Double)->CGPoint { paper.convert(.init(x:x,y:y),to:window) }
      let beforePixels=[(point(180,200),NotebookUXObservation.Color.black),(point(180,260),.black),
        (point(390,225),.black),(point(180,240),.paper),(point(180,300),.paper),(point(390,270),.paper)]
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(beforePixels))
      let began=ContinuousClock.now
      let contact=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
      let original=try XCTUnwrap(model.selectionSession.manipulation).presentedFrame
      model.updateElementManipulation(contact,translation:.init(x:0,y:40))
      let pending=try XCTUnwrap(model.selectionSession.manipulation)
      XCTAssertEqual(pending.presentedFrame,original,"Control geometry cannot lead the raw/material exchange")
      XCTAssertEqual(model.graphicGraph(page:page).source("whole-peer")?.frame.y,210)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(beforePixels),"The current producer has not yielded to prepare any new native material")
      let presentation=try XCTUnwrap(pending.inkPresentation)
      try await assertUX("whole-contacts-and-authored-peer-move",since:began,budget:NotebookUXObservation.selection,window:window) {
        guard presentation.installed,model.selectionSession.manipulation?.presentedFrame == original.offsetBy(dx:0,dy:40) else { return false }
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),.paper),(point(180,260),.paper),(point(390,225),.paper),
          (point(180,240),.black),(point(180,300),.black),(point(390,270),.black)])
      }
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:0,y:40)))
      await self.assertSaved(model)
      let actions=try model.store.actionReadModels().filter { !before.contains($0.id) }
      XCTAssertEqual(actions.count,1)
      XCTAssertEqual(actions.first?.action.operations.filter { $0.kind == .convertInkToElement }.count,2)
      XCTAssertEqual(actions.first?.action.operations.filter { $0.kind == .updateElement }.map(\.id),["whole-peer"])
      let moved=try model.store.loadPage(page.id)
      XCTAssertEqual(moved.elements.count,3)
      XCTAssertEqual(moved.element(id:"whole-peer")?.frame.y,250)
      for raw in selection.ink {
        let element=try XCTUnwrap(moved.element(id:raw.memberID))
        XCTAssertEqual(element.graphic?.sourceInkIDs,[raw.actionID])
        XCTAssertEqual(element.graphic?.freehand,raw.material.graphic.freehand)
        XCTAssertEqual(element.frame.y,raw.material.frame.y+40,accuracy:1e-8)
      }
      XCTAssertEqual(moved.drawingData,page.drawingData)
    }
  }

  func testClaimedWholeMoveKeepsItsPictureUntilTheCanonicalPlanActuallyInstalls() async throws {
    try await withWholeSelection { model,page,strokes,address in
      try await self.selectWholeContour(model,address:address)
      let canvas=try XCTUnwrap(model.pageInkPublication.currentCanvas(on:page.id))
      let paper=try XCTUnwrap(canvas.superview as? PaperCanvasContainerView),window=try XCTUnwrap(paper.window)
      let oldElementSource=try XCTUnwrap(model.pages[page.id]).elementSourceIdentity
      let oldInput=model.pageOrderedInk(page,display:model.pageGraphicDisplay(page,in:nil))
      XCTAssertTrue(oldInput.matches(canvas.orderedInkPlan))
      @MainActor func point(_ x:Double,_ y:Double)->CGPoint { paper.convert(.init(x:x,y:y),to:window) }
      let originalPixels=[(point(180,200),NotebookUXObservation.Color.black),(point(180,260),.black),
        (point(390,225),.black),(point(180,240),.paper),(point(180,300),.paper),(point(390,270),.paper)]
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(originalPixels))
      // Hold the existing writer FIFO, not the main actor or a fake publication.
      // The private GPU stage must fail after the command has been claimed.
      let (entered,start)=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
      let writer=Task {
        try await model.performStoreCommand { _ in
          start.yield();start.finish();_ = release.wait(timeout:.now()+5)
        }
      }
      defer {release.signal()}
      for await _ in entered {break}
      let resources=SceneRenderResources.shared
      let pressure=try XCTUnwrap(resources.reserveDerivedBytes(
        resources.byteLimit-resources.residentBytes-resources.reservedBytes,priority:.input))
      defer {pressure.release()}
      let contact=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
      let owner=try XCTUnwrap(model.selectionSession.manipulation?.inkPresentation)
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:0,y:40)))
      let failureDeadline=ContinuousClock.now + .seconds(2)
      while model.actionCue != "Не удалось подготовить всё выделение. Повторите действие.",ContinuousClock.now<failureDeadline {
        try await Task.sleep(for:.milliseconds(5))
      }
      XCTAssertEqual(model.actionCue,"Не удалось подготовить всё выделение. Повторите действие.")
      XCTAssertTrue(owner.holdsPresentation);XCTAssertFalse(owner.installed)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(originalPixels),"A refused private frame cannot remove the complete raw picture")
      XCTAssertEqual(model.graphicGraph(page:try XCTUnwrap(model.pages[page.id])).source("whole-peer")?.frame.y,210,
        "Authored controls/material cannot lead the raw members of the same command")
      release.signal();try await writer.value;await self.assertSaved(model)
      let publicationDeadline=ContinuousClock.now + .seconds(2)
      while model.pages[page.id]?.elements.count != 3,ContinuousClock.now<publicationDeadline {
        try await Task.sleep(for:.milliseconds(5))
      }
      let accepted=try XCTUnwrap(model.pages[page.id])
      XCTAssertEqual(accepted.drawingStamp,page.drawingStamp,"Conversion changes element source, not the raw root")
      XCTAssertNotEqual(accepted.elementSourceIdentity,oldElementSource)
      XCTAssertTrue(owner.needsCanonicalSource);XCTAssertTrue(owner.holdsPresentation)
      XCTAssertEqual(model.workingGraphics.filter{$0.inkPresentation === owner}.count,2)
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:"whole-peer")?.frame.y,250)
      // A late callback from the old SwiftUI body has the same raw stamp. It
      // must not acknowledge the new canonical element source or drop controls.
      model.canonicalPageInkInstalled(.init(pageID:page.id,stamp:page.drawingStamp),
        elementSource:oldElementSource,input:oldInput)
      XCTAssertTrue(owner.holdsPresentation)
      XCTAssertEqual(model.workingGraphics.filter{$0.inkPresentation === owner}.count,2)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(originalPixels))
      pressure.release()
      // Ordinary demand retries the already captured canonical source. No
      // synthetic ready callback, replayed writer or second source is supplied.
      let resumed=ContinuousClock.now
      canvas.setPageInputEnabled(false);canvas.setPageInputEnabled(true)
      try await self.assertUX("claimed-whole-move-canonical-handoff",since:resumed,
        budget:NotebookUXObservation.selection,window:window) {
        guard !owner.holdsPresentation,model.workingGraphics.allSatisfy({$0.inkPresentation !== owner}),
          canvas.isStableFramePresented,canvas.orderedInkPlan.suppressedInkIDs == Set(strokes.map(\.id)) else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),.paper),(point(180,260),.paper),(point(390,225),.paper),
          (point(180,240),.black),(point(180,300),.black),(point(390,270),.black)])
      }
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,page.drawingData)
    }
  }

  func testSecondWholeMoveKeepsControlsWithPixelsAndCancelPreservesNewAcceptedContact() async throws {
    try await withWholeSelection { model,page,strokes,address in
      try await self.selectWholeContour(model,address:address)
      let canvas=try XCTUnwrap(model.pageInkPublication.currentCanvas(on:page.id))
      let paper=try XCTUnwrap(canvas.superview as? PaperCanvasContainerView),window=try XCTUnwrap(paper.window)
      @MainActor func point(_ x:Double,_ y:Double)->CGPoint {paper.convert(.init(x:x,y:y),to:window)}
      let first=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
      XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:0,y:40)))
      await self.assertSaved(model)
      try await self.assertUX("first-whole-move-canonical-installed",since:ContinuousClock.now,
        budget:NotebookUXObservation.selection,window:window) {
        guard model.workingGraphics.isEmpty,canvas.isStableFramePresented,
          canvas.orderedInkPlan.bodies.count == 2 else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),.paper),(point(180,240),.black),(point(180,300),.black)])
      }
      let before=canvas.orderedInkPlan
      let original=try XCTUnwrap(before.bodies.first(where:{$0.sourceID == strokes[0].id}))
      let reference=address.reference(original.elementID)
      let acceptedFrame=try XCTUnwrap(model.store.loadPage(page.id).element(id:original.elementID)).frame
      XCTAssertTrue(model.selectElements([reference]));XCTAssertTrue(model.selectionSession.ink.isEmpty)
      // Use the ordinary single-authored-element entry point on the second
      // contact; it must not bypass the installed-picture owner after conversion.
      let second=try XCTUnwrap(model.beginElementManipulation(reference,kind:.move))
      let oldFrame=try XCTUnwrap(model.selectionSession.manipulation).presentedFrame
      let owner=try XCTUnwrap(model.selectionSession.manipulation?.inkPresentation)
      let began=ContinuousClock.now
      model.updateElementManipulation(second,translation:.init(x:0,y:40))
      XCTAssertEqual(model.selectionSession.manipulation?.presentedFrame,oldFrame)
      XCTAssertEqual(canvas.orderedInkPlan,before,"No yield: neither controls nor pixels may advance alone")
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (point(180,240),.black),(point(180,280),.paper)]))
      try await self.assertUX("second-whole-move-picture-and-controls",since:began,
        budget:NotebookUXObservation.selection,window:window) {
        guard owner.installed,model.selectionSession.manipulation?.presentedFrame == oldFrame.offsetBy(dx:0,dy:40) else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,240),.paper),(point(180,280),.black),(point(180,300),.black)])
      }
      XCTAssertEqual(canvas.orderedInkPlan.bodies.first(where:{$0.elementID == original.elementID})?.key,original.key)
      // Deliver a real new accepted raw delta through the page owner before
      // cancelling the unaccepted move. Rollback owns only the old body's pose.
      let added=PageInkAction(tool:.pen,samples:[200.0,280].enumerated().map { index,x in
        .init(point:.init(x:x,y:360),timeOffset:Double(index)/60,width:8,opacity:1,force:1,azimuth:0,altitude:1)
      })
      let stamp=try XCTUnwrap(model.reserveDrawingAction(pageID:page.id))
      XCTAssertNotNil(model.acceptDrawingAction(added,pageID:page.id,stamp:stamp))
      await self.assertSaved(model)
      let acceptedDeadline=ContinuousClock.now + .seconds(2)
      while !canvas.isStableFramePresented,ContinuousClock.now<acceptedDeadline {
        try await Task.sleep(for:.milliseconds(5))
      }
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([(point(240,360),.black)]))
      let cancelled=ContinuousClock.now
      model.cancelElementManipulation(second)
      try await self.assertUX("second-whole-move-cancel-keeps-new-raw",since:cancelled,
        budget:NotebookUXObservation.selection,window:window) {
        guard model.workingGraphics.allSatisfy({$0.inkPresentation !== owner}),
          canvas.orderedInkPlan == before,canvas.isStableFramePresented else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,240),.black),(point(180,280),.paper),(point(180,300),.black),(point(240,360),.black)])
      }
      let saved=try model.store.loadPage(page.id)
      XCTAssertEqual(saved.element(id:original.elementID)?.frame,acceptedFrame)
      XCTAssertTrue(try saved.inkSource.drawing().actions.contains(where:{$0.id == added.id && $0.isActive}))
      XCTAssertEqual(saved.elements.count,3,"Cancelling the second move neither reconverts nor duplicates a contact")
    }
  }

  func testCopyAndDuplicatePreserveRawPlaneOrderAfterReverseContactConversion() async throws {
    try await withWholeSelection { model,page,strokes,address in
      try await self.selectWholeContour(model,address:address)
      let rawA=try XCTUnwrap(model.selectionSession.ink.first(where:{$0.actionID == strokes[0].id}))
      let rawB=try XCTUnwrap(model.selectionSession.ink.first(where:{$0.actionID == strokes[1].id}))
      let canvas=try XCTUnwrap(model.pageInkPublication.currentCanvas(on:page.id))
      let window=try XCTUnwrap(canvas.window)
      for (step,raw) in [rawB,rawA].enumerated() {
        XCTAssertTrue(model.selectElements([],ink:[raw]))
        let movement=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
        XCTAssertTrue(model.finishElementManipulation(movement,translation:.init(x:0,y:40)))
        await self.assertSaved(model)
        try await self.assertUX("copy-order-conversion-\(step)",since:ContinuousClock.now,
          budget:NotebookUXObservation.selection,window:window) {
          canvas.isStableFramePresented && model.workingGraphics.isEmpty
            && canvas.orderedInkPlan.bodies.contains(where:{$0.elementID == raw.memberID})
        }
        if step == 0 {
          XCTAssertTrue(model.selectElements([address.reference(rawB.memberID),address.reference("whole-peer")],ink:[rawA]))
          let mixed=try model.clipboardSelectionSnapshot()
          let fragment=try await Task.detached{try mixed.prepare().fragment}.value
          XCTAssertEqual(fragment.elements.map(\.id),["whole-peer",rawA.memberID,rawB.memberID],
            "Raw A is below converted B, not appended on top of all authored references")
        }
      }
      XCTAssertEqual(try model.store.loadPage(page.id).elements.map(\.id),["whole-peer",rawB.memberID,rawA.memberID])
      XCTAssertTrue(model.selectElements([address.reference(rawB.memberID),address.reference("whole-peer"),address.reference(rawA.memberID)]))
      let snapshot=try model.clipboardSelectionSnapshot()
      let copied=try await Task.detached{try snapshot.prepare().fragment}.value
      XCTAssertEqual(copied.elements.map(\.id),["whole-peer",rawA.memberID,rawB.memberID])
      XCTAssertTrue(copied.elements.allSatisfy{$0.graphic?.sourceInkIDs.isEmpty == true})
      XCTAssertEqual(copied.elements.compactMap{$0.graphic?.freehand?.layers.first?.measured?.sourceID},strokes.map(\.id))
      let originalIDs=Set(try model.store.loadPage(page.id).elements.map(\.id))
      model.duplicateSelectedContent();await self.assertSaved(model)
      let duplicate=try model.store.loadPage(page.id).elements.filter{!originalIDs.contains($0.id)}
      XCTAssertEqual(duplicate.count,3)
      XCTAssertEqual(duplicate.first?.graphic?.shape,.rectangle)
      XCTAssertEqual(duplicate.compactMap{$0.graphic?.freehand?.layers.first?.measured?.sourceID},strokes.map(\.id))
      XCTAssertTrue(duplicate.allSatisfy{$0.graphic?.sourceInkIDs.isEmpty == true})
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,page.drawingData)
    }
  }

  func testDeletingRawAndCanonicalContactsInstallsOneWholeFrameAndUndoRedoRetainsBothSources() async throws {
    try await deletingWholeContacts(canonicalOnly:false)
  }

  func testDeletingCanonicalContactAndAuthoredPeerUsesOneInstalledFrameBeforeWriterAndUndoRedo() async throws {
    try await deletingWholeContacts(canonicalOnly:true)
  }

  private func deletingWholeContacts(canonicalOnly:Bool) async throws {
    try await withWholeSelection { model,page,strokes,address in
      try await self.selectWholeContour(model,address:address)
      let rawA=try XCTUnwrap(model.selectionSession.ink.first(where:{$0.actionID == strokes[0].id}))
      let rawB=try XCTUnwrap(model.selectionSession.ink.first(where:{$0.actionID == strokes[1].id}))
      let canvas=try XCTUnwrap(model.pageInkPublication.currentCanvas(on:page.id))
      let paper=try XCTUnwrap(canvas.superview as? PaperCanvasContainerView),window=try XCTUnwrap(paper.window)
      @MainActor func point(_ x:Double,_ y:Double)->CGPoint {paper.convert(.init(x:x,y:y),to:window)}
      XCTAssertTrue(model.selectElements([],ink:[rawB]))
      let movement=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
      XCTAssertTrue(model.finishElementManipulation(movement,translation:.init(x:0,y:40)))
      await self.assertSaved(model)
      try await self.assertUX("mixed-delete-setup-canonical-contact",since:ContinuousClock.now,
        budget:NotebookUXObservation.selection,window:window) {
        guard canvas.isStableFramePresented,model.workingGraphics.isEmpty,
          canvas.orderedInkPlan.bodies.contains(where:{$0.elementID == rawB.memberID}) else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),.black),(point(180,260),.paper),(point(180,300),.black),(point(390,225),.black)])
      }
      let before=Set(try model.store.actionReadModels().map(\.id))
      let oldCanonicalSource=try XCTUnwrap(model.pages[page.id]).elementSourceIdentity
      let selected=canonicalOnly ? [address.reference(rawB.memberID),address.reference("whole-peer")] : [address.reference(rawB.memberID)]
      XCTAssertTrue(model.selectElements(selected,ink:canonicalOnly ? [] : [rawA]))
      XCTAssertEqual(model.selectionSession.ink.isEmpty,canonicalOnly)
      let remainingA:NotebookUXObservation.Color=canonicalOnly ? .black : .paper
      let remainingPeer:NotebookUXObservation.Color=canonicalOnly ? .paper : .black
      // The writer cannot replace this proof with a later canonical repair:
      // inspect the actual first installed private delete frame while SQL is held.
      let (entered,start)=AsyncStream<Void>.makeStream(),release=DispatchSemaphore(value:0)
      let writer=Task {
        try await model.performStoreCommand { _ in
          start.yield();start.finish();_ = release.wait(timeout:.now()+5)
        }
      }
      defer {release.signal()}
      for await _ in entered {break}
      let deletedAt=ContinuousClock.now
      model.deleteSelectedContent()
      let owner=try XCTUnwrap(model.workingGraphics.first(where:{$0.id == (canonicalOnly ? rawB.memberID : rawA.memberID)})?.inkPresentation)
      XCTAssertEqual(owner.source.orderedMembers.map(\.id),[rawB.memberID])
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (point(180,200),.black),(point(180,300),.black),(point(390,225),.black)]),
        "Before the common frame is installed neither the authored peer nor the ordered body disappears")
      try await self.assertUX("mixed-raw-canonical-private-delete",since:deletedAt,
        budget:NotebookUXObservation.selection,window:window) {
        guard owner.installed,!canvas.orderedInkPlan.bodies.contains(where:{$0.elementID == rawB.memberID}),
          !model.workingGraphics.contains(where:{$0.id == rawB.memberID}) else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),remainingA),(point(180,260),.paper),(point(180,300),.paper),(point(390,225),remainingPeer)])
      }
      XCTAssertEqual(model.pages[page.id]?.elementSourceIdentity,oldCanonicalSource,
        "The private frame, not a newer canonical publication, removed B")
      release.signal();try await writer.value;await self.assertSaved(model)
      let actions=try model.store.actionReadModels().filter{!before.contains($0.id)}
      XCTAssertEqual(actions.count,1)
      XCTAssertEqual(actions.first?.action.operations.filter{$0.kind == .convertInkToElement}.count,canonicalOnly ? 0 : 1)
      XCTAssertEqual(Set(actions.first?.action.operations.filter{$0.kind == .removeElement}.compactMap(\.id) ?? []),Set(selected.map(\.elementID)))
      let deleted=try model.store.loadPage(page.id)
      let deletedSuppression:Set<UUID>=canonicalOnly ? [rawB.actionID] : Set(strokes.map(\.id))
      XCTAssertEqual(deleted.graphicPresentation.suppressedInkIDs,deletedSuppression)
      XCTAssertFalse(deleted.graphicPresentation.geometryIDs.contains(rawB.memberID))
      XCTAssertEqual(deleted.drawingData,page.drawingData)
      let undoneAt=ContinuousClock.now
      model.undoLastSurfaceAction();await self.assertSaved(model)
      try await self.assertUX("mixed-raw-canonical-delete-undo",since:undoneAt,
        budget:NotebookUXObservation.selection,window:window) {
        guard model.workingGraphics.isEmpty,canvas.isStableFramePresented,
          canvas.orderedInkPlan.bodies.contains(where:{$0.elementID == rawB.memberID}),
          !canvas.orderedInkPlan.suppressedInkIDs.contains(rawA.actionID) else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),.black),(point(180,260),.paper),(point(180,300),.black),(point(390,225),.black)])
      }
      let restored=try model.store.loadPage(page.id)
      XCTAssertEqual(restored.graphicPresentation.suppressedInkIDs,[rawB.actionID])
      XCTAssertEqual(restored.drawingData,page.drawingData)
      let repeatedAt=ContinuousClock.now
      model.redoLastSurfaceAction();await self.assertSaved(model)
      try await self.assertUX("mixed-raw-canonical-delete-redo",since:repeatedAt,
        budget:NotebookUXObservation.selection,window:window) {
        guard model.workingGraphics.isEmpty,canvas.isStableFramePresented,
          !canvas.orderedInkPlan.bodies.contains(where:{$0.elementID == rawB.memberID}),
          canvas.orderedInkPlan.suppressedInkIDs == deletedSuppression else {return false}
        return try NotebookUXObservation.Pixels(window:window).matches([
          (point(180,200),remainingA),(point(180,260),.paper),(point(180,300),.paper),(point(390,225),remainingPeer)])
      }
      let repeated=try model.store.loadPage(page.id)
      XCTAssertEqual(repeated.drawingData,page.drawingData)
      XCTAssertFalse(repeated.graphicPresentation.geometryIDs.contains(rawB.memberID))
      XCTAssertFalse(owner.holdsPresentation)
    }
  }

  func testRawAndNativeTextRemainWholeAndOnlySupportedOperationsAreAdmitted() async throws {
    try await withWholeSelection { model,page,_,address in
      try await self.selectWholeContour(model,address:address)
      let raw=model.selectionSession.ink
      var updated=try model.store.loadPage(page.id)
      let text=AgentElement(id:"whole-text",kind:.nativeText,frame:.init(x:360,y:200,width:80,height:60),source:"whole text",html:"")
      XCTAssertTrue(updated.replaceElements(updated.elements+[text],actor:model.actorID));try model.store.savePage(updated)
      await model.reloadExternalChanges()?.value
      XCTAssertTrue(model.selectElements([address.reference(text.id)],ink:raw))
      XCTAssertEqual(model.selectionSession.count,3)
      XCTAssertFalse(model.canTransformSelection)
      XCTAssertNil(model.beginSelectionManipulation(kind:.move))
      XCTAssertTrue(model.canDeleteSelection);XCTAssertTrue(model.canExportSelection)
      let snapshot=try model.clipboardSelectionSnapshot()
      let exported=try await Task.detached { try snapshot.prepare() }.value
      XCTAssertEqual(exported.fragment.elements.map(\.id),[text.id]+raw.map(\.memberID))
      let before=Set(try model.store.actionReadModels().map(\.id))
      model.deleteSelectedContent();await self.assertSaved(model)
      let actions=try model.store.actionReadModels().filter { !before.contains($0.id) }
      XCTAssertEqual(actions.count,1)
      XCTAssertEqual(actions.first?.action.operations.filter { $0.kind == .convertInkToElement }.count,2)
      XCTAssertEqual(actions.first?.action.operations.filter { $0.kind == .removeElement }.map(\.id),[text.id])
      let deleted=try model.store.loadPage(page.id)
      XCTAssertNil(deleted.element(id:text.id))
      XCTAssertEqual(deleted.graphicPresentation.suppressedInkIDs,Set(raw.map(\.actionID)))
      XCTAssertEqual(deleted.drawingData,page.drawingData)
    }
  }

  func testWholeContactEditRejectsAChangedInkBasisWithoutTouchingTheAuthoredPeer() async throws {
    try await withWholeSelection { model,page,_,address in
      try await self.selectWholeContour(model,address:address)
      let selection=model.selectionSession
      let contact=try XCTUnwrap(model.beginSelectionManipulation(kind:.move))
      model.cancelElementManipulation(contact)
      XCTAssertEqual(model.selectionSession.id,selection.id)
      XCTAssertTrue(model.workingGraphics.isEmpty,"A cancelled read-only pick leaves no optimistic conversion")
      let before=Set(try model.store.actionReadModels().map(\.id))
      var next=try model.store.loadPage(page.id)
      let added=PageInkAction(tool:.pen,samples:[20.0,40].map { x in
        .init(point:.init(x:x,y:20),timeOffset:0,width:3,opacity:1,force:1,azimuth:0,altitude:1)
      })
      XCTAssertTrue(next.replaceDrawing(try PageInkDrawing(actions:next.inkSource.drawing().actions+[added]).dataRepresentation(),actor:model.actorID))
      try model.store.savePage(next);await model.reloadExternalChanges()?.value
      XCTAssertNil(model.beginSelectionManipulation(kind:.move),"A new source cannot be silently grafted onto the captured whole contacts")
      model.transformGraphicSelection(scale:1.2);await self.assertSaved(model)
      XCTAssertEqual(Set(try model.store.actionReadModels().map(\.id)),before)
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:"whole-peer")?.frame,page.element(id:"whole-peer")?.frame)
    }
  }

  private func withWholeSelection(_ body:(NotebookAppModel,PageDocument,[PageInkAction],NotebookToolAddress) async throws -> Void) async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let strokes=[200.0,260].map { y in PageInkAction(tool:.pen,samples:[100.0,700].enumerated().map { index,x in
        .init(point:.init(x:x,y:y),timeOffset:Double(index)/60,width:8,opacity:1,force:1,azimuth:0,altitude:1)
      }) }
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions:strokes).dataRepresentation(),actor:model.actorID))
      XCTAssertTrue(page.replaceElements([.init(id:"whole-peer",kind:.graphic,frame:.init(x:370,y:210,width:50,height:30),
        source:"",html:"",graphic:.init(shape:.rectangle,style:.init(strokeWidth:3,fill:.black)))],actor:model.actorID))
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      let presence=try XCTUnwrap(model.presence),item=try XCTUnwrap(model.workspace?.selectedItemID)
      model.updatePresence(.init(boardID:presence.boardID,mode:.page,camera:presence.camera,viewport:presence.viewport,
        focusedItemID:item,openProgress:1,selectedItemID:item,notebookPageID:page.id),settled:true)
      await self.assertSaved(model)
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,
        bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      try await self.withMountedWholePage(model,pageID:page.id) { _,_ in
        try await body(model,page,strokes,address)
      }
    }
  }

  private func showFixturePage(_ model:NotebookAppModel,_ pageID:UUID) async throws {
    let presence=try XCTUnwrap(model.presence),item=try XCTUnwrap(model.notebookPageOwner(pageID))
    model.updatePresence(.init(boardID:presence.boardID,mode:.page,camera:presence.camera,viewport:presence.viewport,
      focusedItemID:item,openProgress:1,selectedItemID:item,notebookPageID:pageID),settled:true)
    await assertSaved(model)
  }

  private func withMountedWholePage(_ model:NotebookAppModel,pageID:UUID,
    _ body:(UIView,UIWindow) async throws -> Void) async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where: \.isKeyWindow),window=UIWindow(windowScene:scene)
    let host=UIHostingController(rootView:WholeSelectionTestPage(pageID:pageID).environment(model))
    window.rootViewController=host;window.makeKeyAndVisible();host.view.layoutIfNeeded()
    defer { window.isHidden=true;window.rootViewController=nil;previous?.makeKey() }
    let deadline=ContinuousClock.now + .seconds(5)
    while model.pageInkPublication.currentCanvas(on:pageID)?.isStableFramePresented != true,
      ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(5)) }
    XCTAssertTrue(model.pageInkPublication.currentCanvas(on:pageID)?.isStableFramePresented == true)
    try await body(host.view,window)
  }

  private func selectWholeContour(_ model:NotebookAppModel,address:NotebookToolAddress) async throws {
    let polygon=[SpatialPoint(x:340,y:180),.init(x:460,y:180),.init(x:460,y:280),.init(x:340,y:280)]
    model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .elements
    XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
    for point in polygon.dropFirst() { model.drawingTools.move(to:point) }
    model.drawingTools.finish()
    let deadline=ContinuousClock.now + .seconds(5)
    while model.drawingTools.pendingLasso != nil,ContinuousClock.now<deadline { try await Task.sleep(for:.milliseconds(5)) }
    XCTAssertNil(model.drawingTools.pendingLasso)
    XCTAssertEqual(model.selectionSession.count,3)
  }

  func testWholeContactSelectionIncludesAllSpansButRegionSelectionKeepsItsContour() throws {
    let surface=SurfaceID.board(UUID()),id=UUID()
    func samples(_ x:Double)->InkMeasurements {
      .init([x,x+80].map { x in .init(point:.init(x:x,y:100),timeOffset:0,
        width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2) })
    }
    let spans=[samples(100),samples(500)]
    let source=try NotebookLassoInkSource.Prepared(revision:"whole-contact",
      entries:[.init(id:id,tool:.pen,color:.black,sources:spans.enumerated().map { index,values in
        .init(sourceID:id,span:index,measurements:values,header:.init(tool:.pen,color:.black))
      })],surface:surface,origin:nil,excluding:[])
    let polygon=[SpatialPoint(x:125,y:94),.init(x:137,y:94),.init(x:137,y:106),.init(x:125,y:106)]
    let whole=try XCTUnwrap(source.wholeContacts(polygon:polygon,surface:surface,origin:nil,bounds:nil).first?.material)
    XCTAssertEqual(whole.graphic.sourceInkIDs,[id])
    XCTAssertEqual(whole.graphic.freehand?.layers.compactMap(\.measured?.span),[0,1])
    XCTAssertLessThan(whole.selectionFrame.x,100)
    XCTAssertGreaterThan(whole.selectionFrame.x+whole.selectionFrame.width,580)
    XCTAssertEqual(whole.graphic.freehand?.layers.compactMap(\.measured?.measurements),spans)
    let region=try XCTUnwrap(source.selection(polygon:polygon,surface:surface,origin:nil,bounds:nil))
    XCTAssertEqual(region.polygon,polygon)
    XCTAssertEqual(region.selectionFrame.width,12,accuracy:1e-8)
  }

  func testWholeContactQueryKeepsPainterOrderCutsAndRejectsAnUnsupportedContact() throws {
    let surface=SurfaceID.page(UUID())
    func action(_ tool:SpatialInkTool,_ y:Double,_ width:Double) -> PageInkAction {
      .init(tool:tool,samples:[100.0,700].map { x in .init(point:.init(x:x,y:y),timeOffset:0,
        width:width,opacity:1,force:1,azimuth:0,altitude:.pi/2) })
    }
    let erased=action(.pen,200,8),eraser=action(.eraser,200,30),top=action(.pen,200,8)
    let page=PageInkDrawing(actions:[erased,eraser,top])
    let source=try NotebookLassoInkSource.Prepared(revision:"painter",
      entries:page.actions.map { .init(id:$0.id,tool:$0.tool,color:$0.color,sources:[.init($0)]) },
      surface:surface,origin:nil,excluding:[])
    let polygon=[SpatialPoint(x:180,y:190),.init(x:220,y:190),.init(x:220,y:210),.init(x:180,y:210)]
    let whole=try source.wholeContacts(polygon:polygon,surface:surface,origin:nil,bounds:nil)
    XCTAssertEqual(whole.map(\.actionID),[top.id],"A surviving neighbour does not revive a fully erased contact")
    XCTAssertEqual(whole.first?.material.graphic.freehand?.layers.compactMap(\.measured?.sourceID),[top.id],
      "An earlier eraser cannot cut a later pen")
    XCTAssertEqual(try source.wholeContacts(polygon:polygon,surface:surface,origin:nil,bounds:nil,topmostOnly:true).map(\.actionID),[top.id])
    let other=action(.pen,200,8)
    let unsupported=try NotebookLassoInkSource.Prepared(revision:"cross-surface",
      entries:[.init(id:other.id,tool:.pen,color:other.color,sources:[.init(other)],allowsWholeContact:false)],
      surface:surface,origin:nil,excluding:[])
    XCTAssertThrowsError(try unsupported.wholeContacts(polygon:polygon,surface:surface,origin:nil,bounds:nil)) {
      XCTAssertEqual(($0 as? CollaborationError)?.code,"unsupported_selection")
    }
  }

  func testWholeContactQueryRejectsThirtyThreeMembersRatherThanAggregatingThem() throws {
    let surface=SurfaceID.page(UUID())
    let actions=(0..<33).map { index in PageInkAction(tool:.pen,samples:[100.0,700].map { x in
      .init(point:.init(x:x,y:Double(index)*10+100),timeOffset:0,width:4,opacity:1,force:1,azimuth:0,altitude:.pi/2)
    }) }
    let source=try NotebookLassoInkSource.Prepared(revision:"33-members",
      entries:actions.map { .init(id:$0.id,tool:$0.tool,color:$0.color,sources:[.init($0)]) },
      surface:surface,origin:nil,excluding:[])
    let polygon=[SpatialPoint(x:190,y:90),.init(x:210,y:90),.init(x:210,y:450),.init(x:190,y:450)]
    XCTAssertThrowsError(try source.wholeContacts(polygon:polygon,surface:surface,origin:nil,bounds:nil)) {
      XCTAssertEqual(($0 as? CollaborationError)?.code,"selection_limit")
    }
    let first=try XCTUnwrap(source.wholeContacts(polygon:polygon,surface:surface,origin:nil,bounds:nil,topmostOnly:true).first)
    XCTAssertEqual(first.actionID,actions.last?.id)
    XCTAssertEqual(first.material.graphic.sourceInkIDs,[first.actionID])
  }

  func testLassoKeepsAll8192AdmittedPointsAndRejectsOverflowWithoutLosingSelection() async throws {
    try await fixture { model in
      let page=try XCTUnwrap(model.activePage)
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let polygon=(0..<NotebookGraphicMask.maximumPolygonPoints).map {
        SpatialPoint(x:100+Double($0)/32,y:$0.isMultiple(of:2) ? 100 : 200)
      }
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      let buffer=try XCTUnwrap(model.drawingTools.contact?.contour)
      for point in polygon.dropFirst() { XCTAssertEqual(model.drawingTools.move(to:point),point) }
      XCTAssertTrue(model.drawingTools.contact?.contour === buffer,"Every sample appends to one owner")
      XCTAssertEqual(model.drawingTools.contact?.points,polygon)
      model.drawingTools.finish()
      XCTAssertEqual(model.selectionSession.region?.polygon,polygon,"Lift must not simplify or truncate topology")
      model.drawingTools.cancel()
      // An already materialized selection is not owned by the next contact.
      let previous=NotebookRegionSelection(id:UUID(),address:address,
        polygon:[.zero,.init(x:10,y:0),.init(x:10,y:10)],frame:.init(x:0,y:0,width:10,height:10),
        rawInk:nil,expectedInkRevision:nil,graphics:[])
      model.selectRegion(previous)
      let selection=model.selectionSession.id
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      for point in polygon.dropFirst() { model.drawingTools.move(to:point) }
      XCTAssertNil(model.drawingTools.move(to:.init(x:400,y:400)))
      XCTAssertNil(model.drawingTools.contact)
      model.drawingTools.finish()
      XCTAssertEqual(model.selectionSession.id,selection)
      XCTAssertEqual(model.selectionSession.region?.id,previous.id)
      XCTAssertTrue(model.actionCue?.contains("Контур слишком длинный") == true)
    }
  }

  func test8192PointLassoBoundsRejectUnrelated100000ObjectDeltaBeforeExactGeometry() async throws {
    let result=try await Task.detached(priority:.userInitiated) {
      let actor=UUID(),board=WorkspaceRoot.boardID,stamp=VersionStamp(counter:1,actor:actor)
      let item=WorkspaceItem.notebook(title:"Lasso bounds",pageIDs:[UUID()])
      let elements=(0..<100_000).map { i in
        SpatialElement(id:"object-\(i)",surface:.board(board),kind:.graphic,
          frame:.init(x:0,y:0,width:10,height:10),worldOrigin:.zero.offsetBy(x:Double(i)*100,y:0),
          source:"",graphic:.init(shape:.rectangle,style:.init(fill:.black)),stamp:stamp)
      }
      let document=BoardDocument(freeItems:[],elements:elements,stamp:stamp)
      let workspace=WorkspaceIndex(items:[item],selectedItemID:item.id,selectedPageID:item.pageIDs[0],stamp:stamp)
      let hierarchy=BoardHierarchy(rootBoardID:board,boards:[.init(id:board,board:document)],stamp:stamp)
      let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
      let graph=document.graphicGraph()
      let source=NotebookDrawingToolController.SpatialSelectionSource(index:index,
        delta:.init(ids:Set(elements.map(\.id)),elements:[:],excluded:[]),
        presence:.init(boardID:board,mode:.board,camera:.init(),viewport:.init(x:834,y:1194)))
      let polygon=(0..<NotebookGraphicMask.maximumPolygonPoints).map { i in
        let angle=Double(i)*2*Double.pi/Double(NotebookGraphicMask.maximumPolygonPoints)
        return SpatialPoint(x:5+20*cos(angle),y:5+20*sin(angle))
      }
      let address=NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil)
      let candidates=try NotebookLassoQuery.spatialCandidates(polygon,address:address,source:source,graph:graph)
      let references=try NotebookLassoQuery.references(intersecting:polygon,at:address,graph:graph,spatial:source,erasures:[:])
      return (candidates,references)
    }.value
    XCTAssertEqual(result.0,["object-0"],"Delta union is spatially bounded, not 8192 × 100000 exact tests")
    XCTAssertEqual(result.1.map(\.elementID),["object-0"])
  }

  func testLassoAdmitsTheCombinedBoardCoverAndItemCandidatesBeforeExactGeometry() async throws {
    let result=try await Task.detached(priority:.userInitiated) {
      let board=WorkspaceRoot.boardID,actor=UUID(),stamp=VersionStamp(counter:1,actor:actor)
      let item=WorkspaceItem.notebook(title:"Combined lasso",pageIDs:[UUID()])
      let geometry=WorkspaceItemGeometry.notebook
      func prepare(_ coverCount:Int) throws -> NotebookLassoQuery.ObjectCandidates {
        let boardElements=(0..<3_000).map { i in
          SpatialElement(id:"board-\(i)",surface:.board(board),kind:.graphic,
            frame:.init(x:0,y:0,width:10,height:10),worldOrigin:.zero,source:"",
            graphic:.init(shape:.rectangle,style:.init(fill:.black)),stamp:stamp)
        }
        let coverElements=(0..<coverCount).map { i in
          SpatialElement(id:"cover-\(i)",surface:.cover(item.id),kind:.graphic,
            frame:.init(x:geometry.width/2,y:geometry.height/2,width:10,height:10),worldOrigin:nil,source:"",
            graphic:.init(shape:.rectangle,style:.init(fill:.black)),stamp:stamp)
        }
        let document=BoardDocument(freeItems:[.init(itemID:item.id,center:.zero,zIndex:0,stamp:stamp)],
          elements:boardElements+coverElements,stamp:stamp)
        let workspace=WorkspaceIndex(items:[item],selectedItemID:item.id,selectedPageID:item.pageIDs[0],stamp:stamp)
        let hierarchy=BoardHierarchy(rootBoardID:board,boards:[.init(id:board,board:document)],stamp:stamp)
        let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
        let source=NotebookDrawingToolController.SpatialSelectionSource(index:index,
          // The same IDs in SQL and the accepted delta count only once.
          delta:.init(ids:Set(boardElements.map(\.id)),elements:[:],excluded:[]),
          presence:.init(boardID:board,mode:.board,camera:.init(),viewport:.init(x:834,y:1194)))
        return try NotebookLassoQuery.objectCandidates(intersecting:[.init(x:-20,y:-20),.init(x:30,y:-20),
          .init(x:30,y:30),.init(x:-20,y:30)],
          at:.init(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil),
          graph:document.graphicGraph(),spatial:source)
      }
      let admitted=try prepare(1_095) // 3,000 board + 1,095 cover + the notebook itself.
      do { _=try prepare(1_096);return (admitted,false) }
      catch let error as CollaborationError { return (admitted,error.code == "selection_limit") }
    }.value
    XCTAssertEqual(result.0.surfaces.map { $0.ids.count }.sorted(),[1_095,3_000])
    XCTAssertEqual(result.0.items.count,1)
    XCTAssertTrue(result.1,"The complete broad phase must throw before returning any candidates to the exact worker")
  }

  func testLassoCountsRawContactsTogetherWithGraphicCandidatesBeforeExactGeometry() async throws {
    let rejected=try await Task.detached(priority:.userInitiated) {
      let actor=UUID(),pageID=UUID(),surface=SurfaceID.page(pageID)
      let elements=(0..<4_096).map { i in
        AgentElement(id:"graphic-\(i)",kind:.graphic,frame:.init(x:100,y:100,width:10,height:10),
          source:"",html:"",graphic:.init(shape:.rectangle,style:.init(fill:.black)))
      }
      let page=PageDocument(id:pageID,size:.init(width:834,height:1194),actor:actor,elements:elements)
      let stroke=PageInkAction(tool:.pen,samples:[100.0,110].enumerated().map { i,x in
        .init(point:.init(x:x,y:100),timeOffset:Double(i),width:3,opacity:1,force:1,azimuth:0,altitude:1)
      })
      let source=try NotebookLassoInkSource.Prepared(revision:"candidate-budget",
        entries:[.init(id:stroke.id,tool:.pen,color:stroke.color,sources:[.init(stroke)])],
        surface:surface,origin:nil,excluding:[])
      let polygon=[SpatialPoint(x:90,y:90),.init(x:130,y:90),.init(x:130,y:130),.init(x:90,y:130)]
      let ink=source.candidateActionIDs(intersecting:polygon,surface:surface,origin:nil)
      guard ink == [stroke.id] else { return false }
      do {
        _=try NotebookLassoQuery.references(intersecting:polygon,
          at:.init(surface:surface,boardID:nil,worldOrigin:nil,bounds:nil),
          graph:page.graphicGraph(),spatial:nil,erasures:[:],inkCandidates:ink)
        return false
      } catch let error as CollaborationError { return error.code == "selection_limit" }
    }.value
    XCTAssertTrue(rejected,"4,096 graphic candidates plus a distinct measured contact exceed the one gesture budget")
  }

  func testLassoCandidateOverflowKeepsPreviousSelectionInBothModes() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let elements=(0..<4_097).map { i in
        AgentElement(id:"overflow-\(i)",kind:.graphic,frame:.init(x:100,y:100,width:10,height:10),
          source:"",html:"",graphic:.init(shape:.rectangle,style:.init(fill:.black)))
      }
      XCTAssertTrue(page.replaceElements(elements,actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      for mode in [NotebookLassoMode.elements,.region] {
        model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode=mode
        model.selectElement(address.reference(elements[0].id))
        let previous=model.selectionSession
        XCTAssertTrue(model.drawingTools.begin(at:.init(x:90,y:90),address:address,screenScale:1))
        for point in [SpatialPoint(x:130,y:90),.init(x:130,y:130),.init(x:90,y:130)] {
          model.drawingTools.move(to:point)
        }
        model.drawingTools.finish()
        let deadline=ContinuousClock.now + .seconds(5)
        while model.drawingTools.pendingLasso != nil,ContinuousClock.now < deadline {
          try await Task.sleep(for:.milliseconds(5))
        }
        XCTAssertNil(model.drawingTools.pendingLasso)
        XCTAssertEqual(model.selectionSession,previous,"A rejected \(mode) contour cannot erase the previous selection")
        XCTAssertTrue(model.actionCue?.contains("слишком много объектов") == true)
      }
    }
  }

  func testLassoFragmentsRetainPainterOrderInsteadOfQueryOrderOnEverySurface() throws {
    let actor=UUID(),owner=UUID(),stamp=VersionStamp(counter:0,actor:actor)
    let elements=["back","middle","front"].enumerated().map { index,id in
      AgentElement(id:id,kind:.graphic,frame:.init(x:100,y:100,width:200,height:200),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.init(red:Double(index)/3,green:0.5,blue:0.7))))
    }
    let page=PageDocument(size:.init(width:834,height:1194),actor:actor,elements:elements)
    for surface in [SurfaceID.page(page.id),.board(owner),.cover(UUID())] {
      let isPage=surface.kind == .page
      let address=NotebookToolAddress(surface:surface,boardID:isPage ? nil : owner,worldOrigin:nil,bounds:nil)
      let board=isPage ? nil : BoardDocument(freeItems:[],elements:elements.map {
        .init(id:$0.id,surface:surface,kind:.graphic,
          frame:.init(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height),
          worldOrigin:surface.kind == .board ? .zero : nil,source:"",graphic:$0.graphic,stamp:stamp)
      },stamp:stamp)
      let region=NotebookRegionSelection(id:UUID(),address:address,
        polygon:[.init(x:120,y:120),.init(x:220,y:120),.init(x:220,y:220),.init(x:120,y:220)],
        frame:.init(x:120,y:120,width:100,height:100),rawInk:nil,expectedInkRevision:nil,
        graphics:elements.reversed().map { address.reference($0.id) })
      let prepared=try XCTUnwrap(NotebookRegionMaterialization.prepare(region,
        graph:isPage ? page.graphicGraph() : XCTUnwrap(board).graphicGraph(),
        snapshot:.init(page:isPage ? page : nil,board:board)))
      XCTAssertEqual(prepared.working.map(\.graphic.style),elements.compactMap(\.graphic?.style))
      XCTAssertEqual(prepared.edits.filter { $0.kind == .updateElement }.map(\.reference.elementID),elements.map(\.id))
      let copy=try prepared.copying(offset:.init(x:10,y:20),address:address)
      XCTAssertEqual(copy.working.map(\.graphic.style),prepared.working.map(\.graphic.style))
    }
  }

  func testRegionLassoClipsNativeShapeWhileObjectModeSelectsItsWhole() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let shape=AgentElement(id:"shape-region",kind:.graphic,
        frame:.init(x:100,y:100,width:200,height:100),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(strokeWidth:8,
          fill:.init(red:1,green:0.8,blue:0))))
      XCTAssertTrue(page.replaceElements([shape],actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let polygon=[SpatialPoint(x:90,y:90),.init(x:150,y:90),.init(x:150,y:210),.init(x:90,y:210)]
      @MainActor func lasso(_ mode:NotebookLassoMode) async throws {
        try await self.showFixturePage(model,page.id)
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode=mode
        XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
        for point in polygon.dropFirst() { model.drawingTools.move(to:point) }
        model.drawingTools.finish()
        let deadline=ContinuousClock.now + .seconds(2)
        if mode == .region {
          while model.selectionSession.region?.materialization == nil,ContinuousClock.now < deadline {
            try await Task.sleep(for:.milliseconds(10))
          }
          XCTAssertNotNil(model.selectionSession.region?.materialization)
        } else {
          while model.selectionSession.elements.isEmpty,ContinuousClock.now < deadline {
            try await Task.sleep(for:.milliseconds(10))
          }
        }
      }

      try await lasso(.region)
      XCTAssertEqual(model.selectionSession.region?.graphics,[address.reference(shape.id)])
      XCTAssertNil(model.selectionSession.element)
      XCTAssertNil(try model.store.loadPage(page.id).element(id:shape.id)?.graphic?.mask,
        "Drawing a lasso is still a read-only selection")

      model.clearSelection();try await lasso(.elements)
      XCTAssertTrue(model.selectionSession.contains(address.reference(shape.id)))
      XCTAssertNil(model.selectionSession.region,"Object mode selects the whole object instead of authoring a clip")

      model.clearSelection();try await lasso(.region)
      let chosen=try XCTUnwrap(model.selectionSession.region)
      XCTAssertTrue(model.commitRegion(chosen,prepared:try XCTUnwrap(chosen.materialization),summary:"Проверить геометрию области"))
      let selected=try XCTUnwrap(model.selectionSession.elements.first)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let saved=try model.store.loadPage(page.id)
      let outside=try XCTUnwrap(saved.element(id:shape.id)?.graphic?.mask)
      let inside=try XCTUnwrap(saved.element(id:selected.elementID)?.graphic?.mask)
      XCTAssertFalse(outside.contains(.init(x:0.1,y:0.5)));XCTAssertTrue(outside.contains(.init(x:0.75,y:0.5)))
      XCTAssertTrue(inside.contains(.init(x:0.1,y:0.5)));XCTAssertFalse(inside.contains(.init(x:0.75,y:0.5)))
    }
  }

  func testRegionResizeIsOneActionCancelIsReadOnlyAndStaleSourceIsRejected() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let shape=AgentElement(id:"region-source",kind:.graphic,frame:.init(x:100,y:100,width:200,height:100),
        source:"",html:"",graphic:.init(shape:.rectangle,style:.init(strokeWidth:2,fill:.init(red:1,green:0,blue:0))))
      XCTAssertTrue(page.replaceElements([shape],actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let polygon=[SpatialPoint(x:90,y:90),.init(x:200,y:90),.init(x:200,y:210),.init(x:90,y:210)]
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      for point in polygon.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
      XCTAssertNotNil(model.drawingTools.pendingLasso)
      let deadline=ContinuousClock.now + .seconds(3)
      while model.selectionSession.region?.materialization == nil,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
      let region=try XCTUnwrap(model.selectionSession.region)
      guard case .region = model.selectionSession.target else { return XCTFail("The region is the one selection target") }
      let cancelled=try XCTUnwrap(model.beginElementManipulation(region.reference,kind:.move))
      model.updateElementManipulation(cancelled,translation:.init(x:60,y:30))
      XCTAssertEqual(try model.store.loadPage(page.id).elements,[shape],"A preview does not split content")
      model.cancelElementManipulation(cancelled)
      XCTAssertEqual(model.selectionSession.region?.id,region.id)
      XCTAssertFalse(model.workingGraphics.contains { !$0.accepted })
      let before=Set(model.collaborationActions.map(\.id))
      let contact=try XCTUnwrap(model.beginElementManipulation(region.reference,kind:.resize(.bottomTrailing)))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:110,y:120)))
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let actions=model.collaborationActions.filter { !before.contains($0.id) && $0.action.operations.contains { $0.kind == .insertElement } }
      XCTAssertEqual(actions.count,1,"Split and resize are one causal command")
      let selected=try XCTUnwrap(model.selectionSession.elements.first)
      let saved=try model.store.loadPage(page.id)
      let fragment=try XCTUnwrap(saved.element(id:selected.elementID))
      XCTAssertNotNil(fragment.basis)
      XCTAssertEqual(fragment.frame.x,110,accuracy:0.000001)
      XCTAssertEqual(fragment.frame.y,110,accuracy:0.000001)
      XCTAssertEqual(fragment.frame.width,400,accuracy:0.000001)
      XCTAssertEqual(fragment.frame.height,200,accuracy:0.000001)
      let action=try XCTUnwrap(actions.first)
      model.undoCollaboration(action.id);await assertSaved(model);await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:shape.id)?.graphic,shape.graphic)
      model.selectRegion(region)
      model.transformGraphicSelection(radians:.pi/2)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let rotated=try model.store.loadPage(page.id)
      let rotatedRef=try XCTUnwrap(model.selectionSession.elements.first)
      let rotatedPiece=try XCTUnwrap(rotated.element(id:rotatedRef.elementID))
      XCTAssertNotNil(rotatedPiece.basis);XCTAssertEqual(rotatedPiece.graphic?.style,shape.graphic?.style)
      XCTAssertEqual(rotated.element(id:shape.id)?.frame,shape.frame)
      let rotation=try XCTUnwrap(model.collaborationActions.first { $0.action.summary == "Повернуть область лассо" })
      model.undoCollaboration(rotation.id);await assertSaved(model);await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(page.id).element(id:shape.id)?.graphic,shape.graphic)
      model.selectRegion(region)
      var changed=try model.store.loadPage(page.id)
      var graphic=try XCTUnwrap(shape.graphic);graphic.style.strokeWidth=7
      let altered=AgentElement(id:shape.id,kind:shape.kind,frame:shape.frame,source:shape.source,html:shape.html,graphic:graphic)
      XCTAssertTrue(changed.replaceElements([altered],actor:model.actorID));try model.store.savePage(changed)
      await model.reloadExternalChanges()?.value
      XCTAssertNil(model.beginElementManipulation(region.reference,kind:.move),"Old selection cannot rebase onto a new source")
    }
  }

  func testRegionAndDuplicatePreserveErasedMaterialAfterSaveAndReopen() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let frame=PageRect(x:100,y:100,width:200,height:100)
      let shape=AgentElement(id:"cut-shape",kind:.graphic,frame:frame,source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.black)))
      XCTAssertTrue(page.replaceElements([shape],actor:model.actorID))
      let cut=PageInkAction(tool:.eraser,samples:[110.0,190.0].map {
        .init(point:.init(x:140,y:$0),timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)
      }).erasingElements([.init(elementID:shape.id,frame:frame)])
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions:[cut]).dataRepresentation(),actor:model.actorID))
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      model.selectElement(address.reference(shape.id));model.duplicateSelectedContent()
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let duplicate=try XCTUnwrap(try model.store.loadPage(page.id).elements.first { $0.id != shape.id })
      XCTAssertFalse(try XCTUnwrap(duplicate.graphic?.mask).contains(.init(x:0.2,y:0.5)))
      model.clearSelection();model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      let polygon=[SpatialPoint(x:95,y:95),.init(x:190,y:95),.init(x:190,y:200),.init(x:95,y:200)]
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      for point in polygon.dropFirst() { model.drawingTools.move(to:point) }
      model.drawingTools.finish()
      let deadline=ContinuousClock.now + .seconds(3)
      while model.selectionSession.region?.materialization == nil,ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      let chosen=try XCTUnwrap(model.selectionSession.region)
      XCTAssertTrue(model.commitRegion(chosen,prepared:try XCTUnwrap(chosen.materialization),summary:"Проверить геометрию области"))
      let refs=model.selectionSession.elements
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let reopened=try model.store.loadPage(page.id)
      let fragment=try XCTUnwrap(refs.compactMap { reopened.element(id:$0.elementID) }
        .first { $0.frame == frame })
      let mask=try XCTUnwrap(fragment.graphic?.mask)
      XCTAssertFalse(mask.contains(.init(x:0.2,y:0.5)),"Changing ID must not restore the removed strip")
      XCTAssertTrue(mask.contains(.init(x:0.35,y:0.5)))
      XCTAssertFalse(mask.contains(.init(x:0.75,y:0.5)))
    }
  }

  func testRegionLassoClipsAConnectorInsteadOfDroppingOrSelectingItsWhole() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let left=AgentElement(id:"arrow-left",kind:.graphic,
        frame:.init(x:50,y:100,width:50,height:100),source:"",html:"",graphic:.init(shape:.rectangle))
      let right=AgentElement(id:"arrow-right",kind:.graphic,
        frame:.init(x:300,y:100,width:50,height:100),source:"",html:"",graphic:.init(shape:.rectangle))
      let connection=NotebookGraphicConnection(
        start:.init(point:.zero,binding:.init(elementID:left.id)),
        end:.init(point:.zero,binding:.init(elementID:right.id)),endArrowhead:.arrow)
      let arrow=AgentElement(id:"arrow-region",kind:.graphic,
        frame:.init(x:0,y:0,width:400,height:300),source:"",html:"",
        graphic:.init(shape:.connector,style:.init(strokeWidth:8),connection:connection))
      XCTAssertTrue(page.replaceElements([left,right,arrow],actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let originalLayout=try XCTUnwrap(model.graphicGraph(page:try XCTUnwrap(model.activePage))
        .resolve(arrow.id).layout)
      let polygon=[SpatialPoint(x:140,y:130),.init(x:200,y:130),.init(x:200,y:170),.init(x:140,y:170)]

      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
      for point in polygon.dropFirst() { model.drawingTools.move(to:point) }
      model.drawingTools.finish()
      let deadline=ContinuousClock.now + .seconds(2)
      while model.selectionSession.region?.materialization == nil,ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      let region=try XCTUnwrap(model.selectionSession.region)
      XCTAssertEqual(region.graphics,[address.reference(arrow.id)])
      XCTAssertNil(try model.store.loadPage(page.id).element(id:arrow.id)?.graphic?.mask,
        "The lasso descriptor remains read-only until an edit")

      let chosen=try XCTUnwrap(model.selectionSession.region)
      XCTAssertTrue(model.commitRegion(chosen,prepared:try XCTUnwrap(chosen.materialization),summary:"Проверить геометрию области"))
      let selected=try XCTUnwrap(model.selectionSession.elements.first)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let saved=try model.store.loadPage(page.id)
      let outside=try XCTUnwrap(saved.element(id:arrow.id)?.graphic)
      let inside=try XCTUnwrap(saved.element(id:selected.elementID)?.graphic)
      XCTAssertEqual(inside.shape,.connector);XCTAssertTrue(inside.connection?.bindings.isEmpty == true,
        "The movable fragment owns no duplicate endpoint bindings")
      XCTAssertEqual(outside.connection?.bindings.count,2,
        "The untouched connector keeps the authored relation")
      XCTAssertFalse(try XCTUnwrap(outside.mask).contains(.init(x:0.3,y:0.5)))
      XCTAssertTrue(try XCTUnwrap(outside.mask).contains(.init(x:0.8,y:0.5)))
      XCTAssertTrue(try XCTUnwrap(inside.mask).contains(.init(x:0.3,y:0.5)))
      XCTAssertFalse(try XCTUnwrap(inside.mask).contains(.init(x:0.8,y:0.5)))
      let selectedLayout=try XCTUnwrap(model.graphicGraph(page:saved,preview:false).resolve(selected.elementID).layout)
      XCTAssertEqual(selectedLayout.frame.x,originalLayout.frame.x,accuracy:0.000001)
      XCTAssertEqual(selectedLayout.frame.y,originalLayout.frame.y,accuracy:0.000001)
      XCTAssertEqual(selectedLayout.frame.width,originalLayout.frame.width,accuracy:0.000001)
      XCTAssertEqual(selectedLayout.frame.height,originalLayout.frame.height,accuracy:0.000001)
    }
  }

  func testObjectLassoReadsAuthoredCutsWithoutDependingOnPaintCache() async throws {
    try await fixture { model in
      var page = try XCTUnwrap(model.activePage)
      let frame = PageRect(x: 100, y: 200, width: 200, height: 120)
      let graphic = NotebookGraphic(shape: .rectangle, style: .init(strokeWidth: 4, fill: .black))
      let element = AgentElement(id: "cold-cut", kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)
      XCTAssertTrue(page.replaceElements([element], actor: model.actorID))
      let cut = PageInkAction(tool: .eraser, samples: [200.0, 320.0].map {
        .init(point: .init(x: 100, y: $0), timeOffset: 0, width: 40, opacity: 1,
          force: 1, azimuth: 0, altitude: .pi / 2)
      }).erasingElements([.init(elementID: element.id, frame: frame)])
      XCTAssertTrue(page.replaceDrawing(try PageInkDrawing(actions: [cut]).dataRepresentation(), actor: model.actorID))
      try model.store.savePage(page); await model.reloadExternalChanges()?.value
      let address = NotebookToolAddress(surface: .page(page.id), boardID: nil, worldOrigin: nil, bounds: nil)
      try await self.showFixturePage(model,page.id)
      model.selectDrawingTool(.lasso)
      model.drawingToolSettings.lassoMode = .elements
      let polygon = [SpatialPoint(x: 90, y: 190), .init(x: 310, y: 190), .init(x: 310, y: 330), .init(x: 90, y: 330)]
      let preparations = model.elementErasureCache.preparationCount
      XCTAssertTrue(model.drawingTools.begin(at: polygon[0], address: address, screenScale: 1))
      for point in polygon.dropFirst() { model.drawingTools.move(to: point) }
      model.drawingTools.finish()
      let deadline = ContinuousClock.now + .seconds(2)
      while !model.selectionSession.contains(address.reference(element.id)), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(model.elementErasureCache.preparationCount, preparations)
      XCTAssertTrue(model.selectionSession.contains(address.reference(element.id)),
        "Selection reads authored geometry directly, before any paint cache exists")

      // Only the removed strip intersects this second polygon.
      let removed = [SpatialPoint(x: 101, y: 230), .init(x: 110, y: 230), .init(x: 110, y: 270), .init(x: 101, y: 270)]
      XCTAssertTrue(model.drawingTools.begin(at: removed[0], address: address, screenScale: 1))
      for point in removed.dropFirst() { model.drawingTools.move(to: point) }
      model.drawingTools.finish()
      try await Task.sleep(for:.milliseconds(100))
      XCTAssertTrue(model.selectionSession.elements.isEmpty)

      // Evicting derived paint paths emulates reopening. Selection remains a
      // geometry query and never schedules a paint-cache preparation.
      model.elementErasureCache.retain(pages: [:])
      XCTAssertTrue(model.drawingTools.begin(at: polygon[0], address: address, screenScale: 1))
      for point in polygon.dropFirst() { model.drawingTools.move(to: point) }
      model.drawingTools.finish()
      let reopenDeadline=ContinuousClock.now + .seconds(2)
      while !model.selectionSession.contains(address.reference(element.id)),
        ContinuousClock.now < reopenDeadline { try await Task.sleep(for:.milliseconds(10)) }
      XCTAssertTrue(model.selectionSession.contains(address.reference(element.id)))
    }
  }

  func testTextEditorIsAdmittedBeforeInsertPublicationAndKeepsEarlyStyledTyping() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,
        bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      var settings = model.drawingToolSettings; settings.textFontName = "Georgia"
      model.drawingToolSettings = settings
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:80,y:120),address:address,screenScale:1))
      let target = try XCTUnwrap(model.selectionSession.nativeText)
      XCTAssertTrue(model.selectionSession.isInteractive)
      XCTAssertEqual(target.reference,address.reference(id)); XCTAssertEqual(target.frame.x,80)
      XCTAssertEqual(target.frame.y,120); XCTAssertEqual(target.style.format?.fontName,"Georgia")
      XCTAssertFalse(model.activePage?.elements.contains { $0.id == id } ?? false,
        "The editable target exists synchronously before the addressed insert publishes")
      var style = target.style
      style.runs = [.init(location:0,length:5,format:.init(fontName:"Georgia",bold:true,italic:true,link:"https://example.com"))]
      model.commitNativeText(reference:target.reference,text:"Hello",finish:true,style:style,draftTarget:target)
      model.clearSelection()
      await assertSaved(model)
      let saved = try XCTUnwrap(model.store.loadPage(page.id).elements.first { $0.id == id })
      XCTAssertEqual(saved.source,"Hello"); XCTAssertEqual(saved.textStyle,style)
    }
  }
  func testEmptyTextNeverPersistsAndQueuedTypingThenDeleteHasOneOwner() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let empty = try XCTUnwrap(model.beginToolText(at:.init(x:40,y:40),address:address,screenScale:1))
      let abandoned = try XCTUnwrap(model.selectionSession.nativeText)
      model.clearSelection()
      model.commitNativeText(reference:address.reference(empty),text:"",finish:true,draftTarget:abandoned)
      await assertSaved(model)
      XCTAssertTrue(try model.store.loadPage(page.id).elements.isEmpty)
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:40,y:40),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(id),text:"First",finish:false)
      model.commitNativeText(reference:address.reference(id),text:"Second",finish:true)
      model.deleteElement(address.reference(id))
      await assertSaved(model)
      XCTAssertTrue(try model.store.loadPage(page.id).elements.isEmpty,"Deletion follows accepted typing, never a competing page snapshot")
    }
  }

  func testTextToolSelectsExistingTextAndWholeObjectFormattingUsesSameContent() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:100,y:100),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(id),text:"Styled",finish:true)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      model.clearSelection()
      XCTAssertNil(model.beginToolText(at:.init(x:110,y:110),address:address,screenScale:1))
      XCTAssertEqual(model.selectionSession.element,address.reference(id))
      XCTAssertFalse(model.selectionSession.isInteractive)
      model.formatNativeText(address.reference(id)) { $0.bold = true }
      model.formatNativeText(address.reference(id)) { $0.italic = true }
      await assertSaved(model)
      let saved = try XCTUnwrap(model.store.loadPage(page.id).elements.first)
      XCTAssertEqual(saved.source,"Styled"); XCTAssertEqual(saved.textStyle?.format?.bold,true)
      XCTAssertEqual(saved.textStyle?.format?.italic,true)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,1)
    }
  }

  func testLassoSelectionIsReadOnlyUntilEditAndCanCutTheRemainderAgain() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      func sample(_ x:Double,_ y:Double)->SpatialInkSample {
        .init(point:.init(x:x,y:y),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)
      }
      let pen=PageInkAction(tool:.pen,samples:[sample(100,100),sample(220,100)])
      let drawing=try PageInkDrawing(actions:[pen]).dataRepresentation()
      XCTAssertTrue(page.replaceDrawing(drawing,actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let text=try XCTUnwrap(model.beginToolText(at:.init(x:120,y:120),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(text),text:"Object",finish:true)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      try await self.showFixturePage(model,page.id)
      model.selectDrawingTool(.lasso);model.drawingToolSettings.lassoMode = .region
      @MainActor func lasso(_ polygon:[SpatialPoint]) {
        XCTAssertTrue(model.drawingTools.begin(at:polygon[0],address:address,screenScale:1))
        for point in polygon.dropFirst() { model.drawingTools.move(to:point) };model.drawingTools.finish()
      }
      let left=[SpatialPoint(x:90,y:90),.init(x:150,y:90),.init(x:150,y:110),.init(x:90,y:110)]
      lasso(left)
      let deadline = ContinuousClock.now + .seconds(5)
      while model.selectionSession.region?.materialization == nil,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
      let region=try XCTUnwrap(model.selectionSession.region)
      XCTAssertNotNil(region.materialization)
      XCTAssertEqual(region.rawInk?.graphic.sourceInkIDs,[pen.id])
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,drawing)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,1,"Selection itself must not author content")
      model.deleteElement(region.reference)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let saved=try model.store.loadPage(page.id)
      XCTAssertEqual(saved.drawingData,drawing)
      XCTAssertEqual(saved.elements.filter { $0.graphic?.visible == true }.count,1,"Only the compact outside relation remains visible")

      let right=[SpatialPoint(x:180,y:90),.init(x:230,y:90),.init(x:230,y:110),.init(x:180,y:110)]
      lasso(right)
      let secondDeadline = ContinuousClock.now + .seconds(5)
      while model.selectionSession.region?.materialization == nil,ContinuousClock.now < secondDeadline { try await Task.sleep(for:.milliseconds(10)) }
      let second=try XCTUnwrap(model.selectionSession.region)
      XCTAssertNil(second.rawInk,"The original journal is already claimed")
      XCTAssertFalse(second.graphics.isEmpty,"A retained remainder must be lassoable again")

      model.drawingToolSettings.lassoMode = .elements
      let object=[SpatialPoint(x:115,y:115),.init(x:145,y:115),.init(x:145,y:150),.init(x:115,y:150)]
      lasso(object)
      let objectDeadline=ContinuousClock.now + .seconds(3)
      while model.drawingTools.pendingLasso != nil,ContinuousClock.now < objectDeadline { try await Task.sleep(for:.milliseconds(10)) }
      XCTAssertTrue(model.selectionSession.contains(address.reference(text)),"Whole-object selection is a separate mode")

      var next=try model.store.loadPage(page.id)
      let raw=PageInkAction(tool:.pen,samples:[sample(350,200),sample(450,200)])
      let ink=try PageInkDrawing.decode(next.drawingData).appending(raw)
      XCTAssertTrue(next.replaceDrawing(try ink.dataRepresentation(),actor:model.actorID));try model.store.savePage(next)
      await model.reloadExternalChanges()?.value
      model.drawingTools.selectInk(at:.init(x:400,y:200),address:address,screenScale:1)
      let tapDeadline = ContinuousClock.now + .seconds(5)
      while model.drawingTools.pendingLasso != nil,ContinuousClock.now < tapDeadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      XCTAssertNil(model.selectionSession.region)
      XCTAssertEqual(model.selectionSession.ink.map(\.actionID),[raw.id])
      XCTAssertEqual(model.selectionSession.ink.first?.material.graphic.freehand?.layers.first?.measured?.measurements,raw.samples)
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,try ink.dataRepresentation())
    }
  }


  func testLassoMaterializesAGroupedRegionInPlaceWithItsTightFrame() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let group=AgentElement(id:"rotated-group",kind:.group,
        frame:.init(x:200,y:200,width:200,height:100),source:"",html:"",
        basis:.init(size:.init(x:200,y:100),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))
      let measurements=InkMeasurements([
        .init(point:.init(x:10,y:30),timeOffset:0,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2),
        .init(point:.init(x:150,y:30),timeOffset:1,width:8,opacity:1,force:1,azimuth:0,altitude:.pi/2)])
      let freehand=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(
        sourceID:UUID(),measurements:measurements,frame:.init(x:0,y:0,width:160,height:60)))])
      let child=AgentElement(id:"grouped-ink",kind:.graphic,frame:.init(x:20,y:20,width:160,height:60),
        source:"",html:"",graphic:.init(shape:.freehand,freehand:freehand),parentID:group.id)
      XCTAssertTrue(page.replaceElements([group,child],actor:model.actorID));try model.store.savePage(page)
      await model.reloadExternalChanges()?.value
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let source=address.reference(child.id),layout=try XCTUnwrap(model.graphicLayout(source))
      let f=layout.frame,polygon=[SpatialPoint(x:f.x,y:f.y),.init(x:f.x+f.width/2,y:f.y),
        .init(x:f.x+f.width/2,y:f.y+f.height),.init(x:f.x,y:f.y+f.height)]
      func placed(_ point:SpatialPoint,_ layout:NotebookGraphicLayout)->CGPoint {
        let p=layout.displayedPoint(point)
        return .init(x:layout.frame.x+p.x,y:layout.frame.y+p.y)
      }
      let probes=[SpatialPoint.zero,.init(x:160,y:0),.init(x:0,y:60),.init(x:160,y:60)]
      let expected=probes.map { placed($0,layout) }
      var region=NotebookRegionSelection(id:UUID(),address:address,polygon:polygon,
        frame:.init(x:f.x,y:f.y,width:f.width/2,height:f.height),rawInk:nil,
        expectedInkRevision:nil,graphics:[source])
      region.materialization=try NotebookRegionMaterialization.prepare(region,graph:model.graphicGraph(page:page),snapshot:model.regionSourceSnapshot(address))
      model.selectRegion(region)
      let chosen=try XCTUnwrap(model.selectionSession.region)
      XCTAssertTrue(model.commitRegion(chosen,prepared:try XCTUnwrap(chosen.materialization),summary:"Проверить геометрию области"))
      let selected=try XCTUnwrap(model.selectionSession.elements.first)
      let live=try XCTUnwrap(model.acceptedWorkingGraphic(selected))
      XCTAssertNotNil(live.basis,"The accepted preview owns the same detached basis as durable content")
      XCTAssertEqual(live.frame.width,f.width,accuracy:0.000001)
      await assertSaved(model);await model.reloadExternalChanges()?.value
      let savedPage=try model.store.loadPage(page.id)
      let saved=try XCTUnwrap(savedPage.element(id:selected.elementID))
      XCTAssertNil(saved.parentID);XCTAssertNotNil(saved.basis)
      let placedLayout=try XCTUnwrap(model.graphicGraph(page:savedPage,preview:false).resolve(selected.elementID).layout)
      let visible=try XCTUnwrap(placedLayout.selectionFrame(mask:try XCTUnwrap(saved.graphic?.mask)))
      XCTAssertEqual(visible.width,f.width/2,accuracy:0.000001)
      for (actual,wanted) in zip(probes.map { placed($0,placedLayout) },expected) {
        XCTAssertEqual(actual.x,wanted.x,accuracy:0.000001)
        XCTAssertEqual(actual.y,wanted.y,accuracy:0.000001)
      }
    }
  }

  func testMarkerUsesConstantOpacityAndKeepsIndependentStyle() {
    let settings = NotebookDrawingToolSettings(), marker = settings.marker
    XCTAssertEqual(marker.width,18)
    for force in [0.0,0.1,0.5,1,2] { XCTAssertEqual(marker.opacity(force:force),0.3) }
    XCTAssertNotEqual(PenStyle.standard.opacity(force:0),PenStyle.standard.opacity(force:1))
    XCTAssertTrue(DrawingTool.marker.usesInkJournal)
    for tool in [DrawingTool.lasso,.shape,.text,.connector,.laser] { XCTAssertFalse(tool.usesInkJournal) }
  }

  func testShapesAndRulerSharePhysicalGeometryInEveryDragDirection() throws {
    for (x,y) in [(-1.0,-1.0),(-1,1),(1,-1),(1,1)] {
      let fit = try XCTUnwrap(NotebookToolGeometry.figure(from:.init(x:100,y:100),to:.init(x:100+x*80,y:100+y*50),
        shape:.rectangle,preservesAspect:true,width:2))
      XCTAssertEqual(fit.frame.width,80); XCTAssertEqual(fit.frame.height,80)
      XCTAssertEqual(fit.frame.x,x < 0 ? 20 : 100); XCTAssertEqual(fit.frame.y,y < 0 ? 20 : 100)
    }
    let line = try XCTUnwrap(NotebookToolGeometry.connection(from:.init(x:80,y:70),to:.init(x:10,y:20),width:2))
    XCTAssertEqual(line.connection?.start.point,.init(x:70,y:50)); XCTAssertEqual(line.connection?.end.point,.zero)
    XCTAssertEqual(line.connection?.endArrowhead,.arrow)
    let address = NotebookToolAddress(surface:.page(UUID()),boardID:nil,worldOrigin:nil,bounds:nil)
    var ruler = NotebookDrawingGuide(address:address,start:.init(x:10,y:20),angle:90,length:PhysicalPaper.pointsPerCentimeter*10)
    ruler.snapToGrid = true
    let constraint = try XCTUnwrap(ruler.constraint(at:.init(x:11,y:20+PhysicalPaper.pointsPerCentimeter),from:address,screenScale:1))
    let point = constraint.project(SpatialPoint(x:87,y:20+PhysicalPaper.pointsPerCentimeter))
    XCTAssertEqual(point.x,10,accuracy:0.000001)
    XCTAssertEqual(point.y,20+PhysicalPaper.gridSpacing*2,accuracy:0.000001)
  }

  func testTemporaryToolsDoNotCreateInkOrAuthoredObjectsAndCancellationDropsPreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults = UserDefaults(suiteName:UUID().uuidString)!
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:defaults)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    let address = NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil)
    let before = model.spatialInk
    model.selectDrawingTool(.laser)
    XCTAssertTrue(model.drawingTools.begin(at:.zero,address:address,screenScale:1))
    model.drawingTools.move(to:.init(x:50,y:80)); model.drawingTools.finish()
    XCTAssertEqual(model.spatialInk,before); XCTAssertTrue(model.workingGraphics.isEmpty)
    model.selectDrawingTool(.shape)
    XCTAssertTrue(model.drawingTools.begin(at:.zero,address:address,screenScale:1))
    model.drawingTools.move(to:.init(x:150,y:80)); XCTAssertEqual(model.workingGraphics.count,1)
    model.selectDrawingTool(.pen)
    XCTAssertNil(model.drawingTools.contact); XCTAssertTrue(model.workingGraphics.isEmpty)
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    if stopped { try FileManager.default.removeItem(at:root) }
  }
  func testMarkerRunsThroughMeasuredPageInputWithoutPressureOrQuickShape() async throws {
    try await fixture { model in
      let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
      paper.toolController = model.drawingTools
      paper.quickShapePageID = model.activePage?.id
      // No intervening SwiftUI update: the receiving native view still carries
      // the previous pen, but the newly admitted contact must use the marker.
      paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.pen)
      model.selectDrawingTool(.marker)
      let touch = DrawingToolPencilTouch()
      var accepted: PageInkAction?
      paper.onDrawingMutation = { accepted = $0 }
      touch.point = .init(x:50,y:80); touch.pressure = 0.1
      paper.touchesBegan([touch],with:nil)
      for i in 1...20 {
        touch.point.x += 5; touch.sampleTime += 0.01; touch.pressure = CGFloat(i)/20
        paper.touchesMoved([touch],with:nil)
      }
      try await Task.sleep(for:.milliseconds(600))
      XCTAssertNil(paper.completedQuickShape)
      paper.touchesEnded([touch],with:nil)
      let ink = try XCTUnwrap(accepted)
      XCTAssertEqual(ink.tool,.pen); XCTAssertEqual(ink.color.red,1)
      let opacities = ink.samples.map(\.opacity)
      XCTAssertEqual(opacities.min()!,opacities.max()!,accuracy:0.000001,"Marker ignores pressure over the whole contact")
      XCTAssertEqual(opacities[0],0.3,accuracy:1.0/255,"PKStrokePoint quantizes opacity")
      XCTAssertTrue(ink.samples.allSatisfy { abs($0.width-18) < 0.000001 },"Widths: \(ink.samples.map(\.width))")
      XCTAssertFalse(paper.hasActiveAction)
    }
  }

  func testNonInkPageContactUsesNoInkReservationAndCancellationReleasesGate() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let paper = PaperInputView(frame:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      paper.toolController = model.drawingTools; paper.toolInputGate = model.inputGate; paper.quickShapePageID = page.id
      var reservations = 0, inkActions = 0
      paper.onActionWillBegin = { reservations += 1; return true }
      paper.onDrawingMutation = { _ in inkActions += 1 }
      paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.pen)
      let touch = DrawingToolPencilTouch()
      for tool in [DrawingTool.shape,.connector,.text,.laser,.lasso] {
        model.selectDrawingTool(tool)
        touch.point = .init(x:100,y:100); paper.touchesBegan([touch],with:nil)
        XCTAssertTrue(model.inputGate.hasActivePencil)
        touch.point = .init(x:230,y:190); touch.sampleTime += 0.1; paper.touchesMoved([touch],with:nil)
        model.selectDrawingTool(.pen)
        XCTAssertFalse(model.inputGate.hasActivePencil,"Changing a tool cancels its admitted non-ink contact")
        paper.touchesCancelled([touch],with:nil)
        XCTAssertTrue(model.workingGraphics.isEmpty)
      }
      model.selectDrawingTool(.shape)
      paper.configure(penStyle:.standard,eraserStyle:.standard,drawingTool:.shape)
      for offset in [0.0,40] {
        touch.point = .init(x:100+offset,y:100); paper.touchesBegan([touch],with:nil)
        touch.point = .init(x:230+offset,y:190); touch.sampleTime += 0.1
        paper.touchesMoved([touch],with:nil); paper.touchesEnded([touch],with:nil)
        XCTAssertFalse(model.inputGate.hasActivePencil); XCTAssertFalse(paper.hasActiveAction)
      }
      await assertSaved(model)
      XCTAssertEqual(try model.store.loadPage(page.id).elements.count,2,"Lift commits each native contact exactly once; a stale adapter cannot swallow the next one")
      XCTAssertEqual(reservations,0); XCTAssertEqual(inkActions,0)
      XCTAssertEqual(try model.store.loadPage(page.id).drawingData,page.drawingData)
    }
  }

  func testLassoFeedbackStaysAboveCoversAndReleasesItsWindowLayer() async throws {
    try await fixture { model in
      let window = UIWindow(frame:.init(x:0,y:0,width:600,height:800))
      let ink = UIView(frame:.init(x:20,y:40,width:500,height:700))
      window.addSubview(ink)
      let cover = UIView(frame:window.bounds); window.addSubview(cover)
      let page = try XCTUnwrap(model.activePage)
      model.selectDrawingTool(.lasso)
      let contact = try XCTUnwrap(NotebookToolInputContact(controller:model.drawingTools,gate:model.inputGate,view:ink,
        address:.init(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil),
        point:.init(x:10,y:20),screenScale:2,toOwner:{ .init(x:$0.x,y:$0.y) }))
      let layer = try XCTUnwrap(window.layer.sublayers?.last as? CAShapeLayer)
      XCTAssertEqual(layer.name,"notebook-tool-feedback")
      contact.move(to:.init(x:110,y:120))
      XCTAssertEqual(layer.path?.boundingBoxOfPath,.init(x:30,y:60,width:100,height:100))
      XCTAssertTrue(model.inputGate.hasActivePencil)
      contact.finish(cancelled:true)
      XCTAssertNil(layer.superlayer); XCTAssertFalse(model.inputGate.hasActivePencil)
    }
  }

  func testInlineTextKeepsItsTappedOriginAndScreenSizeAtDeepZoom() async throws {
    try await fixture { model in
      let board = try XCTUnwrap(model.presence?.boardID)
      let origin = WorldPoint.zero.offsetBy(x:2000,y:-8000)
      let address = NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:origin,bounds:nil)
      let id = try XCTUnwrap(model.beginToolText(at:.init(x:0,y:0),address:address,screenScale:0.03787425024543671))
      XCTAssertTrue(model.selectionSession.isInteractive)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      XCTAssertNil(try model.store.readSpatialElement(boardID:board,elementID:id),"Empty drafts never enter the store")
      let target = try XCTUnwrap(model.selectionSession.nativeText)
      XCTAssertEqual(target.address.worldOrigin,origin)
      XCTAssertEqual(target.frame.x,0); XCTAssertEqual(target.frame.y,0)
      XCTAssertEqual(target.style.fontSize*0.03787425024543671,24,accuracy:0.000001)
      let fitted = PageRect(x:0,y:0,width:target.frame.width,height:target.style.fontSize*2.5)
      model.commitNativeText(reference:address.reference(id),text:"Plain **text**",finish:false,height:fitted.height)
      await assertSaved(model)
      let saved = try XCTUnwrap(model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.first { $0.id == id })
      XCTAssertEqual(saved.source,"Plain **text**"); XCTAssertEqual(saved.kind,.nativeText)
      XCTAssertEqual(saved.frame.height,fitted.height)
      model.commitNativeText(reference:address.reference(id),text:"",finish:true)
      await assertSaved(model)
      XCTAssertFalse(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.contains { $0.id == id } ?? true)
    }
  }

  func testAuthoredToolsPersistOnPageBoardAndCoverThroughOneUndoQueue() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage), board = try XCTUnwrap(model.presence?.boardID)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      let addresses: [NotebookToolAddress] = [
        .init(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height)),
        .init(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil),
        .init(surface:.cover(item),boardID:board,worldOrigin:nil,bounds:.init(x:0,y:0,width:600,height:800))]
      for address in addresses {
        for tool in [DrawingTool.shape,.connector] {
          model.selectDrawingTool(tool)
          XCTAssertTrue(model.drawingTools.begin(at:.init(x:80,y:100),address:address,screenScale:1))
          model.drawingTools.move(to:.init(x:260,y:210)); model.drawingTools.finish()
          await assertSaved(model)
          await model.reloadExternalChanges()?.value
        }
        model.selectDrawingTool(.text)
        XCTAssertTrue(model.drawingTools.begin(at:.init(x:160,y:280),address:address,screenScale:1))
        model.drawingTools.finish()
        let reference = try XCTUnwrap(model.selectionSession.element)
        XCTAssertTrue(model.selectionSession.isInteractive)
        await assertSaved(model); await model.reloadExternalChanges()?.value
        model.commitNativeText(reference:reference,text:"Текст на своей поверхности",finish:true)
        await assertSaved(model); await model.reloadExternalChanges()?.value
      }
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(saved.elements.count,3); XCTAssertEqual(saved.elements.last?.kind,.nativeText)
      XCTAssertEqual(saved.elements.last?.textStyle?.fontSize,24)
      XCTAssertEqual(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.count,6)
      let actions = try model.store.collaborationActions(afterID:nil)
      let action = try XCTUnwrap(actions.first { $0.action.summary == "Добавить текст" })
      model.undoCollaboration(action.id); await assertSaved(model)
      XCTAssertEqual(try model.store.loadBoard(items:model.store.loadIndex().items).board(board)?.elements.count,5)
    }
  }

  func testLassoRetainsPressureCutsCopyRotationAndOriginalJournal() async throws {
    try await fixture { model in
      var page = try XCTUnwrap(model.activePage)
      func sample(_ x:Double,_ y:Double,_ width:Double = 8,_ opacity:Double = 1) -> SpatialInkSample {
        .init(point:.init(x:x,y:y),timeOffset:0,width:width,opacity:opacity,force:opacity,azimuth:0,altitude:.pi/2)
      }
      let stroke = PageInkAction(tool:.pen,color:.init(red:0,green:0.2,blue:0.8),samples:[sample(100,100,8,0.2),sample(200,100,8,0.9)])
      let eraser = PageInkAction(tool:.eraser,samples:[sample(150,80,18),sample(150,120,18)])
      let drawing = PageInkDrawing(actions:[stroke,eraser])
      let data = try drawing.dataRepresentation(); XCTAssertTrue(page.replaceDrawing(data,actor:model.actorID))
      try model.store.savePage(page); await model.reloadExternalChanges()?.value
      let polygon = [SpatialPoint(x:80,y:60),.init(x:220,y:60),.init(x:220,y:140),.init(x:80,y:140)]
      let selection = try XCTUnwrap(NotebookLassoInkSource.page(page).selection(polygon:polygon,surface:.page(page.id),origin:nil,bounds:nil))
      let ink = try XCTUnwrap(selection.graphic.freehand)
      XCTAssertFalse(ink.layers.filter { $0.tool == .eraser }.isEmpty)
      let opacity=try XCTUnwrap(ink.layers[0].measured).measurements.materialized().map(\.opacity)
      XCTAssertLessThan(try XCTUnwrap(opacity.min()),0.3)
      XCTAssertGreaterThan(try XCTUnwrap(opacity.max()),0.8)
      let size = CGSize(width:selection.frame.width,height:selection.frame.height)
      let paint = ink.paintPath(size:size,transform:nil)
      XCTAssertTrue(paint.contains(.init(x:110-selection.frame.x,y:100-selection.frame.y)))
      XCTAssertFalse(paint.contains(.init(x:150-selection.frame.x,y:100-selection.frame.y)))
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let object = NotebookWorkingGraphic(id:UUID(),surface:address.surface,frame:selection.frame,worldOrigin:nil,graphic:selection.graphic)
      XCTAssertTrue(model.acceptAuthoredGraphic(object,at:address,expectedInkRevision:page.drawingStamp.revision))
      await assertSaved(model); await model.reloadExternalChanges()?.value
      model.selectElements([address.reference(object.id)])
      model.transformGraphicSelection(radians:.pi/2)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      model.duplicateSelectedContent()
      await assertSaved(model); await model.reloadExternalChanges()?.value
      let saved = try model.store.loadPage(page.id)
      XCTAssertEqual(saved.drawingData,data,"Manipulation never rewrites immutable measured samples")
      XCTAssertEqual(saved.elements.count,2)
      XCTAssertEqual(saved.elements[0].graphic?.sourceInkIDs,[stroke.id])
      XCTAssertTrue(saved.elements[1].graphic?.sourceInkIDs.isEmpty == true)
      XCTAssertEqual(saved.elements[0].graphic?.freehand,saved.elements[1].graphic?.freehand)
      XCTAssertNotNil(saved.elements[0].basis)
      let actualFrame = saved.elements[0].frame
      let layout=try XCTUnwrap(saved.graphicGraph().resolve(saved.elements[0].id).layout)
      let actual=NotebookElementAppearance(graphic:saved.elements[0].graphic,layout:layout,size:.init(width:actualFrame.width,height:actualFrame.height),erasures:[]).remaining
      XCTAssertFalse(actual.contains(.init(x:actualFrame.width/2,y:actualFrame.height/2)),"The cut rotates with ink")
      // Ordinary undo owns all three accepted actions: copy, first rotation,
      // then conversion. Returning an optional basis to nil is not adoption.
      for _ in 0..<3 {
        model.undoLastSurfaceAction();await assertSaved(model);await model.reloadExternalChanges()?.value
      }
      let restored=try NotebookStore(root:model.store.root).loadPage(page.id)
      XCTAssertTrue(restored.graphicPresentation.suppressedInkIDs.isEmpty)
      XCTAssertEqual(restored.drawingData,data)
      XCTAssertEqual(restored.elements.first?.graphic?.freehand,ink)
      for _ in 0..<3 {
        model.redoLastSurfaceAction();await assertSaved(model);await model.reloadExternalChanges()?.value
      }
      let repeated=try NotebookStore(root:model.store.root).loadPage(page.id)
      XCTAssertEqual(repeated.drawingData,data)
      XCTAssertEqual(repeated.elements.count,2)
      XCTAssertEqual(repeated.graphicPresentation.suppressedInkIDs,[stroke.id])
      XCTAssertEqual(repeated.elements[0].graphic?.freehand,repeated.elements[1].graphic?.freehand)
    }
  }

  func testElementSelectionUsesVisibleGeometryInItsSeparateMode() async throws {
    let polygon = [SpatialPoint(x:90,y:90),.init(x:110,y:90),.init(x:110,y:110),.init(x:90,y:110)]
    XCTAssertTrue(NotebookToolGeometry.intersects(.init(x:100,y:100,width:200,height:200),polygon:polygon))
    XCTAssertTrue(NotebookToolGeometry.intersects(.init(x:0,y:0,width:200,height:200),polygon:polygon))
    XCTAssertTrue(NotebookToolGeometry.intersects(from:.init(x:0,y:100),to:.init(x:200,y:100),polygon:polygon))
    XCTAssertFalse(NotebookToolGeometry.intersects(.init(x:120,y:120,width:20,height:20),polygon:polygon))
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let text = try XCTUnwrap(model.beginToolText(at:.init(x:100,y:100),address:address,screenScale:1))
      model.commitNativeText(reference:address.reference(text),text:"Lasso",finish:true)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      let enclosing = [SpatialPoint(x:80,y:80),.init(x:500,y:80),.init(x:500,y:200),.init(x:80,y:200)]
      let graph=model.graphicGraph(page:try XCTUnwrap(model.activePage))
      let refs = try model.elementsIntersecting(enclosing,at:address,graph:graph)
      XCTAssertTrue(refs.contains(address.reference(text)))
      try await self.showFixturePage(model,page.id)
      model.selectDrawingTool(.lasso)
      model.drawingToolSettings.lassoMode = .elements
      XCTAssertTrue(model.drawingTools.begin(at:enclosing[0],address:address,screenScale:1))
      for point in enclosing.dropFirst() { model.drawingTools.move(to:point) }
      model.drawingTools.finish()
      let deadline=ContinuousClock.now + .seconds(3)
      while model.drawingTools.pendingLasso != nil,ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
      XCTAssertTrue(model.selectionSession.contains(address.reference(text)))
    }
  }

  func testPageNativeSelectionUsesIndexedTransformedBodyNotItsAABB() async throws {
    try await fixture { model in
      var page=try XCTUnwrap(model.activePage)
      let basis=NotebookElementBasis(size:.init(x:100,y:100),transform:.init(
        a:0.5,b:0.5,c:-0.5,d:0.5,tx:0.5,ty:0))
      let element=AgentElement(id:"rotated-body",kind:.markdown,
        frame:.init(x:220,y:260,width:100,height:100),source:"body",html:"",basis:basis)
      XCTAssertTrue(page.replaceElements([element],actor:model.actorID))
      try model.store.savePage(page);await model.reloadExternalChanges()?.value
      page=try XCTUnwrap(model.activePage)
      let address=NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let graph=model.graphicGraph(page:page)
      let placement=try XCTUnwrap(graph.placement(element.id))
      let shown=NotebookElementPresentation(element,placement:placement)
      let corner=[SpatialPoint(x:shown.bounds.minX+1,y:shown.bounds.minY+1),
        .init(x:shown.bounds.minX+5,y:shown.bounds.minY+1),
        .init(x:shown.bounds.minX+5,y:shown.bounds.minY+5),
        .init(x:shown.bounds.minX+1,y:shown.bounds.minY+5)]
      XCTAssertTrue(NotebookToolGeometry.intersects(shown.bounds,polygon:corner),
        "The broad AABB deliberately admits this blank rotated corner")
      XCTAssertFalse(try model.elementsIntersecting(corner,at:address,graph:graph)
        .contains(address.reference(element.id)))
      let center=CGPoint(x:50,y:50).applying(placement.transform)
      let body=[SpatialPoint(x:center.x-3,y:center.y-3),.init(x:center.x+3,y:center.y-3),
        .init(x:center.x+3,y:center.y+3),.init(x:center.x-3,y:center.y+3)]
      XCTAssertTrue(try model.elementsIntersecting(body,at:address,graph:graph)
        .contains(address.reference(element.id)))
    }
  }

  func testWorkspaceObjectLassoQueriesCoverElementsWithoutRetargetingContact() async throws {
    try await fixture { model in
      let workspace=try XCTUnwrap(model.workspace),boardID=workspace.rootBoardID
      let itemID=try XCTUnwrap(workspace.selectedItemID)
      var hierarchy=try model.store.loadBoard(items:workspace.items)
      let element=SpatialElement(id:"cover-text",surface:.cover(itemID),kind:.nativeText,
        frame:.init(x:300,y:580,width:240,height:64),source:"Cover text",
        stamp:.init(counter:0,actor:model.actorID))
      XCTAssertTrue(hierarchy.upsertElement(element,in:boardID,expected:nil,actor:model.actorID))
      let presence=SessionPresence(boardID:boardID,mode:.board,camera:.init(scale:0.5),
        viewport:.init(x:834,y:1194))
      let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
      let item=try XCTUnwrap(index.renderedItem(id:itemID,presence:presence))
      let center=WorldPoint.zero.delta(to:item.center),size=item.geometry
      let x=center.x-size.width/2+element.frame.x,y=center.y-size.height/2+element.frame.y
      let polygon=[SpatialPoint(x:x-4,y:y-4),.init(x:x+element.frame.width+4,y:y-4),
        .init(x:x+element.frame.width+4,y:y+element.frame.height+4),.init(x:x-4,y:y+element.frame.height+4)]
      let address=NotebookToolAddress(surface:.board(boardID),boardID:boardID,worldOrigin:.zero,bounds:nil)
      let graph=try XCTUnwrap(index.graphicGraph(boardID:boardID))
      let source=NotebookDrawingToolController.SpatialSelectionSource(index:index,
        delta:.init(ids:[],elements:[:],excluded:[]),presence:presence)
      let selected=try model.elementsIntersecting(polygon,at:address,graph:graph,spatial:source)
      XCTAssertTrue(selected.contains(.spatial(boardID:boardID,elementID:element.id)),
        "A board-owned Pencil lasso queries the intersected cover instead of losing its visible elements")
    }
  }

  func testLaserExpiresFromOldestToNewestAndRetainsWorldWidth() {
    let address = NotebookToolAddress(surface:.board(UUID()),boardID:nil,worldOrigin:.zero,bounds:nil)
    let trace = NotebookLaserTrace(id:UUID(),address:address,color:.red,width:40,lifetime:0.6,
      samples:[.init(point:.init(x:0,y:0),time:0),.init(point:.init(x:100,y:0),time:0.2),.init(point:.init(x:200,y:0),time:0.4)])
    let visible = trace.points(at:0.7)
    XCTAssertEqual(visible.first!.x,50,accuracy:0.00001)
    XCTAssertEqual(visible.last!.x,200)
    XCTAssertTrue(trace.points(at:1.01).isEmpty)
    XCTAssertEqual(trace.width*0.1,4); XCTAssertEqual(trace.width*0.05,2)
  }

  func testPencilEraserDiameterDoesNotPumpWithPressure() {
    let paper = PaperInputView(frame:.init(x:0,y:0,width:500,height:500))
    paper.configure(penStyle:.standard,eraserStyle:.init(maximumWidth:80),drawingTool:.eraser)
    let touch = DrawingToolPencilTouch()
    var accepted: PageInkAction?
    paper.onDrawingMutation = { accepted = $0 }
    touch.pressure = 0.01; paper.touchesBegan([touch],with:nil)
    for force in [0.9,0.03,1,0.05,0.5] {
      touch.pressure = force; touch.sampleTime += 0.02; touch.point.x += 10
      paper.touchesMoved([touch],with:nil)
    }
    paper.touchesEnded([touch],with:nil)
    XCTAssertNotNil(accepted)
    XCTAssertTrue(accepted?.samples.allSatisfy { abs($0.width-80) < 0.001 } == true)
  }

  func testShapeSubtractionPersistsOneEditableContourAndUndoRestoresRectangle() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage)
      let address = NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil)
      let original = NotebookWorkingGraphic(id:UUID(),surface:address.surface,frame:.init(x:80,y:80,width:240,height:220),worldOrigin:nil,
        graphic:.init(shape:.rectangle,style:.init(strokeWidth:2,fill:.black)))
      XCTAssertTrue(model.acceptAuthoredGraphic(original,at:address)); await assertSaved(model); await model.reloadExternalChanges()?.value
      let cutter = NotebookWorkingGraphic(id:UUID(),surface:address.surface,frame:.init(x:140,y:140,width:80,height:70),worldOrigin:nil,
        graphic:.init(shape:.ellipse,style:.init(stroke:.init(red:1,green:0,blue:0),strokeWidth:2,fill:.init(red:1,green:1,blue:0))))
      model.combineAuthoredShape(cutter,at:address,graph:model.graphicGraph(page:try XCTUnwrap(model.activePage),preview:false),operation:.subtract)
      await assertSaved(model); await model.reloadExternalChanges()?.value
      let edited = try XCTUnwrap(model.store.loadPage(page.id).elements.first { $0.id == original.id })
      XCTAssertEqual(edited.graphic?.shape,.path)
      XCTAssertNotEqual(edited.graphic?.style.stroke,edited.graphic?.style.fill)
      let paint = NotebookGraphicGeometry.paintPath(try XCTUnwrap(edited.graphic),layout:nil,size:.init(width:edited.frame.width,height:edited.frame.height))
      XCTAssertFalse(paint.contains(.init(x:180-edited.frame.x,y:170-edited.frame.y)))
      model.undoLastSurfaceAction(); await assertSaved(model); await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(page.id).elements.first { $0.id == original.id }?.graphic?.shape,.rectangle)
      model.redoLastSurfaceAction(); await assertSaved(model); await model.reloadExternalChanges()?.value
      XCTAssertEqual(try model.store.loadPage(page.id).elements.first { $0.id == original.id }?.graphic?.shape,.path)
    }
  }

  func testImmediateBooleanContactsUseAcceptedGeometryBeforePublication() async throws {
    try await fixture { model in
      let page = try XCTUnwrap(model.activePage), board = try XCTUnwrap(model.presence?.boardID)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      for address in [NotebookToolAddress(surface:.page(page.id),boardID:nil,worldOrigin:nil,bounds:nil),
        .init(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil),
        .init(surface:.cover(item),boardID:board,worldOrigin:nil,bounds:nil)] {
        model.selectDrawingTool(.shape)
        model.drawingToolSettings.shapeFilled = true
        @MainActor func draw(_ operation: NotebookShapeOperation, _ start: SpatialPoint, _ end: SpatialPoint) {
          model.drawingToolSettings.shapeOperation = operation
          XCTAssertTrue(model.drawingTools.begin(at:start,address:address,screenScale:1))
          model.drawingTools.move(to:end); model.drawingTools.finish()
        }
        @MainActor func graph() -> NotebookGraphicGraph {
          address.surface.kind == .page ? model.graphicGraph(page:model.pages[page.id]!) : model.authoredGraphicGraph(boardID:board)
        }
        draw(.normal,.init(x:80,y:80),.init(x:300,y:300))
        let original = try XCTUnwrap(graph().nodes.values.first { $0.surface == address.surface && $0.shown && $0.graphic.showsGeometry })
        for (operation,start,end) in [(NotebookShapeOperation.union,SpatialPoint(x:260,y:100),SpatialPoint(x:420,y:260)),
          (.subtract,.init(x:130,y:130),.init(x:170,y:170)),
          (.intersect,.init(x:180,y:100),.init(x:380,y:280)),
          (.exclude,.init(x:300,y:140),.init(x:440,y:240))] {
          draw(operation,start,end)
          XCTAssertEqual(graph().nodes.values.filter { $0.surface == address.surface && $0.shown && $0.graphic.showsGeometry }.count,1)
          XCTAssertEqual(graph().nodes[original.id]?.graphic.shape,.path)
        }
        let expected = try XCTUnwrap(graph().nodes[original.id])
        await assertSaved(model); await model.reloadExternalChanges()?.value
        let saved = address.surface.kind == .page ? try model.store.loadPage(page.id).elements.first { $0.id == original.id }?.graphic
          : try model.store.readSpatialElement(boardID:board,elementID:original.id)?.graphic
        XCTAssertEqual(saved,expected.graphic,"Quick contacts chain accepted predecessors, not whichever raster happened to publish")
        XCTAssertEqual(graph().nodes[original.id]?.graphic,expected.graphic,"An old working insertion retained for raster handoff cannot replace a newer admitted boolean result")
        XCTAssertEqual(model.graphicElement(address.reference(original.id)),expected.graphic)
        draw(.subtract,.init(x:600,y:600),.init(x:700,y:700))
        XCTAssertEqual(graph().nodes.values.filter { $0.surface == address.surface && $0.shown && $0.graphic.showsGeometry }.count,2,"No intersection establishes a new base instead of dropping the drawn shape")
        await assertSaved(model); await model.reloadExternalChanges()?.value
      }
    }
  }

  func testPrimaryColorHasOnePreferenceOwnerAndDoesNotSwitchTools() async throws {
    try await fixture { model in
      for tool in [DrawingTool.pen,.marker,.shape,.text,.connector,.laser] {
        model.selectDrawingTool(tool); model.selectDrawingColor(.green)
        XCTAssertEqual(model.drawingTool,tool); XCTAssertEqual(model.drawingColor,.green)
      }
      XCTAssertNotEqual(model.drawingToolSettings.shapeFillColor ?? .yellow,.green)
    }
  }

  private func assertSaved(_ model: NotebookAppModel, file: StaticString = #filePath, line: UInt = #line) async {
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved,model.persistenceFailure ?? "",file:file,line:line)
  }

  private func fixture(_ body: (NotebookAppModel) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-tools-\(UUID())")
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false,preferences:UserDefaults(suiteName:UUID().uuidString)!)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize); await model.finishPendingPersistence()
    try await body(model)
  }

}

@MainActor private final class DrawingToolPencilTouch: UITouch {
  var point = CGPoint(x:100,y:100)
  var sampleTime: TimeInterval = 1
  var pressure: CGFloat = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { pressure }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi/2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func location(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}


/// Production page composition and its real input/publication consumer; this
/// fixture does not impersonate an ink receiver or pre-convert a selection.
private struct WholeSelectionTestPage:View {
  @Environment(NotebookAppModel.self) private var model
  let pageID:UUID
  var body:some View {
    if let page=model.pages[pageID] {
      PageSurface(page:page,isCurrent:true,isInteractive:true,isVisible:true,
        onRenderReady:.init { _ in }).ignoresSafeArea()
    }
  }
}
