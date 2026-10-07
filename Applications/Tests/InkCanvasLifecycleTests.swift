import NotebookCore
import PencilKit
import UIKit
import XCTest

@testable import Notebook

final class InkCanvasLifecycleTests: XCTestCase {
  @MainActor
  func testPreparedPageAndMaterialKeepTheOldPixelsUntilTheirCommonInstall() async throws {
    try await withPreparedSelectionCanvas { canvas,window,action,plan in
      let count=canvas.committedSourceNodeCount,builds=canvas.pageMeshBuildCount
      let geometry=try await canvas.prepareOrderedPlan(plan)
      XCTAssertNotNil(geometry)
      XCTAssertEqual(canvas.committedSourceNodeCount,count)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:40),to:window),.black),
        (canvas.convert(.init(x:80,y:110),to:window),.paper)]))
      let began=ContinuousClock.now
      try await canvas.presentOrderedPlan(geometry,plan:plan)
      XCTAssertEqual(canvas.layer.opacity,1,"Installing visibility cannot revoke its own prepared drawable")
      XCTAssertEqual(canvas.orderedInkPlan,plan)
      try await assertUX("whole-contact-native-handoff",since:began,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:110),to:window),.black)])
      }
      XCTAssertEqual(canvas.pageMeshBuildCount,builds)
      let restored=try await canvas.prepareOrderedPlan(.init())
      let restoreBegan=ContinuousClock.now
      try await canvas.presentOrderedPlan(restored,plan:.init(),canonical:true)
      XCTAssertEqual(canvas.layer.opacity,1,"Rollback must retain its prepared returning raw drawable")
      try await assertUX("whole-contact-native-cancel",since:restoreBegan,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.paper)])
      }
      XCTAssertEqual(canvas.pageMeshBuildCount,builds)
      XCTAssertEqual(canvas.committedSourceNodeCount,count)
      let stroke=self.handoffPencil()
      canvas.displayActiveStroke(stroke);canvas.commitActiveStroke()
      try await self.waitForStableFrame(canvas)
      try await assertUX("handoff-preserves-page-input",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(canvas.convert(.init(x:80,y:145),to:window),.black)])
      }
    }
  }

  @MainActor
  func testOrderedContactPreservesCrossingRankAndScopesHistoricalCuts() async throws {
    try await withPreparedSelectionCanvas { canvas,window,_,_ in
      func stroke(_ a:SpatialPoint,_ b:SpatialPoint,color:SpatialInkColor,sequence:UInt64,tool:SpatialInkTool = .pen)->PageInkAction {
        .init(tool:tool,color:color,samples:[a,b].enumerated().map { i,p in
          .init(point:p,timeOffset:Double(i)/60,width:10,opacity:1,force:1,azimuth:0,altitude:1)
        },sequence:sequence)
      }
      let a=stroke(.init(x:20,y:60),.init(x:140,y:60),color:.init(red:1,green:0,blue:0),sequence:1)
      let b=stroke(.init(x:80,y:20),.init(x:80,y:140),color:.init(red:0,green:0,blue:1),sequence:2)
      let c=stroke(.init(x:20,y:100),.init(x:140,y:100),color:.black,sequence:3)
      let cut=stroke(.init(x:76,y:40),.init(x:84,y:40),color:.black,sequence:4,tool:.eraser)
      let future=stroke(.init(x:106,y:70),.init(x:114,y:70),color:.black,sequence:5,tool:.eraser)
      canvas.apply(.init(actions:[a,b,c,cut,future]));try await self.waitForStableFrame(canvas)
      let frameRect=PageRect(x:0,y:0,width:160,height:160)
      let ink=NotebookFreehand(layers:[b,cut].map { action in
        .init(tool:action.tool,color:action.color,measured:.init(sourceID:action.id,measurements:action.samples,frame:frameRect))
      })
      let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[b.id],freehand:ink,transform:.init(a:1,b:0,c:0,d:1,tx:30.0/160,ty:0))
      let plan=try self.handoffPlan(action:b,graphic:graphic)
      let before:[(CGPoint,NotebookUXObservation.Color)]=[
        (.init(x:80,y:60),.blue),(.init(x:110,y:60),.red),(.init(x:80,y:100),.black)]
      let candidate=try await canvas.prepareOrderedPlan(plan)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(before.map{(canvas.convert($0.0,to:window),$0.1)}))
      try await canvas.presentOrderedPlan(candidate,plan:plan)
      try await assertUX("ordered-contact-crossing-and-cuts",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:60),to:window),.red),
          (canvas.convert(.init(x:110,y:60),to:window),.blue),
          (canvas.convert(.init(x:110,y:100),to:window),.black),
          (canvas.convert(.init(x:110,y:40),to:window),.paper),
          (canvas.convert(.init(x:110,y:70),to:window),.blue)])
      }
    }
  }

  @MainActor
  func testRetainedEraserRepairsItsOldTailAndPreservesBorrowedOrderedPixels() async throws {
    try await withPreparedSelectionCanvas { canvas,window,action,preparedPlan in
      var graphic=try XCTUnwrap(preparedPlan.bodies.first).graphic
      // Keep the captured basis inside its physical frame; source y=40 still
      // lands at y=110 after this nonidentity transform.
      graphic.transform = .init(a:1,b:0,c:0,d:0.25,tx:0,ty:0.625)
      let plan=try self.handoffPlan(action:action,graphic:graphic)
      let raw=PageInkAction(tool:.pen,color:.init(red:1,green:0,blue:0),samples:[20.0,140].map {x in
        .init(point:.init(x:x,y:110),timeOffset:0,width:10,opacity:1,force:1,azimuth:0,altitude:1)
      },sequence:2)
      canvas.apply(.init(actions:[action,raw]));try await self.waitForStableFrame(canvas)
      let geometry=try await canvas.prepareOrderedPlan(plan)
      try await canvas.presentOrderedPlan(geometry,plan:plan,canonical:true)
      canvas.projectPage(region:.init(x:10,y:10,width:140,height:140),
        sourceSize:.init(width:160,height:160),pixelDensity:2)
      try await self.waitForStableFrame(canvas,accepted:true)
      let borrowed=try XCTUnwrap(canvas.acquireAcceptedFrameLease())
      defer {borrowed.release()}
      let allocations=canvas.pageRetainedAllocationCount,pools=canvas.pageDrawableAllocationCount
      func location(_ x:Double)->CGPoint {canvas.convert(.init(x:x-10,y:100),to:window)}
      func sample(_ x:Double,width:Double = 18)->SpatialInkSample {
        .init(point:.init(x:x,y:110),timeOffset:0,width:width,opacity:1,force:1,azimuth:0,altitude:1)
      }
      let body=try XCTUnwrap(plan.bodies.first)
      let target=InkElementTarget(elementID:body.elementID,frame:body.layout.frame,
        graphicTransform:body.graphic.transform,elementTransform:body.layout.elementTransform)
      let eraser=ActiveEraserStroke()
      @MainActor func addressed(_ stroke:ActiveEraserStroke) {
        let cut=NotebookElementErasing(id:stroke.measured.sourceID,surface:.page(UUID()),
          samples:stroke.measured.frozen().measurements,targets:[target])
        canvas.updateOrderedErasing([cut],id:cut.id)
      }
      eraser.replaceMeasuredTail(from:0,with:[sample(80)])
      canvas.displayActiveEraser(eraser)
      try await assertUX("retained-raw-eraser-reveals-untargeted-body",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(80),.black),(location(120),.red)])
      }
      XCTAssertEqual(canvas.pageRetainedAllocationCount,allocations+1,"Only the borrowed accepted cut requires a replacement")
      XCTAssertFalse(canvas.acceptedMaterialIsReady)
      XCTAssertNil(canvas.acquireAcceptedFrameLease(),"Live erased pixels cannot be lent as a canonical cut")
      addressed(eraser)
      try await assertUX("retained-addressed-eraser-cuts-its-body",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(80),.paper),(location(120),.red)])
      }
      // Prime the displayed mask after many raw samples have collapsed to one
      // node. A later width correction must replace that cached node's pixels.
      eraser.replaceMeasuredTail(from:1,with:Array(repeating:sample(80),count:9_999))
      let primedRevision=eraser.revision,previousReceipt=canvas.onContactFrameResolved
      var primed=false
      canvas.onContactFrameResolved={ receipt in
        previousReceipt?(receipt)
        if receipt.contact.sourceID == eraser.measured.sourceID,
          receipt.contact.revision == primedRevision,receipt.completion.isReady {primed=true}
      }
      defer {canvas.onContactFrameResolved=previousReceipt}
      canvas.displayActiveEraser(eraser);addressed(eraser)
      try await NotebookPersistenceFenceContract.until {primed && canvas.isFrameLoopPaused}
      canvas.onContactFrameResolved=previousReceipt
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([(location(92),.red)]))
      eraser.replaceMeasuredTail(from:9_999,with:[sample(80,width:30)])
      canvas.displayActiveEraser(eraser);addressed(eraser)
      try await assertUX("stationary-eraser-width-replaces-normalized-mask-pixels",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(92),.paper),(location(120),.red)])
      }
      eraser.replaceMeasuredTail(from:0,with:[sample(120)])
      canvas.displayActiveEraser(eraser);addressed(eraser)
      try await assertUX("retained-erasure-correction-restores-vacated-pixels",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(80),.red),(location(120),.paper)])
      }
      // Switch contacts before an empty frame: the predecessor's retained
      // footprint must be restored in the successor's first drawable.
      canvas.updateOrderedErasing([],id:eraser.measured.sourceID);canvas.clearActiveAction()
      let next=ActiveEraserStroke();next.replaceMeasuredTail(from:0,with:[sample(40)])
      canvas.displayActiveEraser(next);addressed(next)
      try await assertUX("retained-eraser-switch-restores-predecessor",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(40),.paper),(location(80),.red),(location(120),.red)])
      }
      canvas.updateOrderedErasing([],id:next.measured.sourceID);canvas.clearActiveAction()
      try await self.waitForStableFrame(canvas,accepted:true)
      try await assertUX("retained-erasure-cancel-restores-canonical-cut",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(40),.red),(location(80),.red),(location(120),.red)])
      }
      let restored=try XCTUnwrap(canvas.acquireAcceptedFrameLease());defer {restored.release()}
      XCTAssertFalse(restored.texture === borrowed.texture)
      XCTAssertEqual(canvas.pageRetainedAllocationCount,allocations+1)
      XCTAssertEqual(canvas.pageDrawableAllocationCount,pools,"The patch reuses the existing drawable pool")
      restored.release()
      let lifted=ActiveEraserStroke();lifted.replaceMeasuredTail(from:0,with:[sample(80)])
      canvas.displayActiveEraser(lifted)
      try await assertUX("retained-eraser-before-lift",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(80),.black)])
      }
      let accepted=PageInkAction(id:lifted.measured.sourceID,tool:.eraser,
        measurements:lifted.measured.frozen().measurements,sequence:3)
      canvas.commitActiveEraser(accepted);try await self.waitForStableFrame(canvas,accepted:true)
      try await assertUX("retained-lift-reconstructs-the-same-canonical-order",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(location(80),.black),(location(120),.red)])
      }
      XCTAssertEqual(canvas.pageRetainedAllocationCount,allocations+1)
    }
  }

  @MainActor
  func testRetainedEraserDamageFollowsTheCapturedMaskThroughShearAndScale() async throws {
    try await withPreparedSelectionCanvas { canvas,window,action,_ in
      let frame=PageRect(x:0,y:0,width:160,height:160)
      let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,
        measured:.init(sourceID:action.id,measurements:action.samples,frame:frame))])
      let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[action.id],freehand:ink,
        transform:.init(a:1,b:0.3,c:0.25,d:0.75,tx:0,ty:0.2))
      let plan=try self.handoffPlan(action:action,graphic:graphic)
      let geometry=try await canvas.prepareOrderedPlan(plan)
      try await canvas.presentOrderedPlan(geometry,plan:plan,canonical:true)
      canvas.projectPage(region:.init(x:10,y:10,width:140,height:140),
        sourceSize:.init(width:160,height:160),pixelDensity:2)
      try await self.waitForStableFrame(canvas,accepted:true)
      let first=canvas.convert(CGPoint(x:80,y:76),to:window)
      let second=canvas.convert(CGPoint(x:120,y:88),to:window)
      let stroke=ActiveEraserStroke()
      @MainActor func move(_ x:Double) {
        stroke.replaceMeasuredTail(from:0,with:[.init(point:.init(x:x,y:40),timeOffset:0,
          width:18,opacity:1,force:1,azimuth:0,altitude:1)])
        canvas.displayActiveEraser(stroke)
        let cut=NotebookElementErasing(id:stroke.measured.sourceID,surface:.page(UUID()),
          samples:stroke.measured.frozen().measurements,
          targets:[.init(elementID:"moved-contact",frame:frame)])
        canvas.updateOrderedErasing([cut],id:cut.id)
      }
      move(80)
      try await assertUX("retained-captured-mask-uses-current-body-basis",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(first,.paper),(second,.black)])
      }
      move(120)
      try await assertUX("retained-captured-mask-restores-old-transformed-tail",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([(first,.black),(second,.paper)])
      }
      canvas.updateOrderedErasing([],id:stroke.measured.sourceID);canvas.clearActiveAction()
      try await self.waitForStableFrame(canvas,accepted:true)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([(first,.black),(second,.black)]))
    }
  }

  @MainActor
  func testReturningTheRawSourceJoinsTheNextPencilFrameWithoutDroppingTheContact() async throws {
    let resources=SceneRenderResources(byteLimit:8 * 1024 * 1024)
    try await withPreparedSelectionCanvas(resources:resources) { canvas,window,action,moved in
      // A canonical erased representation still owns its source claim even
      // when the ordered plane has no visible body to retain.
      let hidden=self.handoffStroke(y:75)
      canvas.apply(.init(actions:[action,hidden]));try await self.waitForStableFrame(canvas)
      let hiddenPlan=NotebookOrderedInkPlan(suppressedInkIDs:[hidden.id])
      let hiddenGeometry=try await canvas.prepareOrderedPlan(hiddenPlan)
      try await canvas.presentOrderedPlan(hiddenGeometry,plan:hiddenPlan,canonical:true);try await self.waitForStableFrame(canvas)
      let plan=NotebookOrderedInkPlan(bodies:moved.bodies,suppressedInkIDs:moved.suppressedInkIDs.union([hidden.id]))
      let restoration=try XCTUnwrap(canvas.captureSourceRestoration(for:Set(moved.bodies.map(\.sourceID))))
      let geometry=try await canvas.prepareOrderedPlan(plan)
      try await canvas.presentOrderedPlan(geometry,plan:plan);restoration.installed()
      try await self.waitForStableFrame(canvas)
      let selectedPixels=try NotebookUXObservation.Pixels(window:window)
      XCTAssertTrue(try selectedPixels.matches([
        (canvas.convert(.init(x:80,y:40),to:window),.paper),
        (canvas.convert(.init(x:80,y:110),to:window),.black)]))
      var retired=0,abandoned=0
      let installedAt=NotebookPersistenceFenceContract.Signal<ContinuousClock.Instant>()
      let shown=NotebookPersistenceFenceContract.Signal<NotebookMetalFrameReadiness>()
      let receiveVisible=canvas.onVisibleFrame
      canvas.onVisibleFrame = {
        receiveVisible?()
        if installedAt.value != nil,let receipt=canvas.frameReadiness,receipt.isReady {shown.set(receipt)}
      }
      defer {canvas.onVisibleFrame=receiveVisible}
      let began=ContinuousClock.now
      restoration.restore(install:{installedAt.set(.now);retired += 1},abandon:{abandoned += 1})
      XCTAssertEqual(retired,0);XCTAssertEqual(abandoned,0)
      // The new contact joins the next ordinary frame while the complete old
      // cut remains shown; cancellation does not drain preceding GPU work.
      let pencil=self.handoffPencil();canvas.displayActiveStroke(pencil)
      let contact=try XCTUnwrap(canvas.activeContactFrame)
      try await NotebookPersistenceFenceContract.until {installedAt.value != nil || abandoned>0}
      let installed=try XCTUnwrap(installedAt.value,"The raw source must join the canvas installation transaction")
      let installationTime=began.duration(to:installed)
      XCTAssertLessThanOrEqual(installationTime,NotebookUXObservation.correctnessTimeout,
        "The original 100 ms ceiling measures raw-source installation; it is not an OS presentation or screenshot deadline")
      // Wait for the owner's visible-frame receipt before reading pixels. The
      // source timestamp above precedes this waiter and all window observation.
      try await NotebookPersistenceFenceContract.until {shown.value != nil}
      let captureBegan=ContinuousClock.now,pixels=try NotebookUXObservation.Pixels(window:window)
      let correct=try pixels.matches([
        (canvas.convert(.init(x:80,y:40),to:window),.black),
        (canvas.convert(.init(x:80,y:110),to:window),.paper),
        (canvas.convert(.init(x:80,y:145),to:window),.black),
        (canvas.convert(.init(x:80,y:75),to:window),.paper)])
      XCTAssertTrue(correct,"The restored raw source and held Pencil must appear together")
      let timing=XCTAttachment(string:"rawSourceInstallation=\(installationTime); visibleReceipt=\(String(describing:shown.value)); independentCaptureAndCheck=\(captureBegan.duration(to:.now)); correct=\(correct). Capture cost is not application latency and is not subtracted.")
      timing.name="raw-return-with-active-pencil";timing.lifetime = .keepAlways;self.add(timing)
      let image=XCTAttachment(image:pixels.image);image.name="raw-return-active-pencil-pixels"
      image.lifetime = .keepAlways;self.add(image)
      XCTAssertEqual(retired,1);XCTAssertEqual(abandoned,0);XCTAssertEqual(canvas.activeContactFrame,contact)
      XCTAssertEqual(canvas.orderedInkPlan.suppressedInkIDs,[hidden.id],"Rollback removes only this edit, not an already erased canonical contact")
      canvas.commitActiveStroke();try await self.waitForStableFrame(canvas)
    }
  }

  @MainActor
  func testRefusedSourceRestorationFinishesOnceAndCanonicalDemandRecovers() async throws {
    let resources=SceneRenderResources(byteLimit:8 * 1024 * 1024)
    try await withPreparedSelectionCanvas(resources:resources) { canvas,window,action,plan in
      for needsNewPool in [true,false] {
        let restoration=try XCTUnwrap(canvas.captureSourceRestoration(for:[action.id]))
        let geometry=try await canvas.prepareOrderedPlan(plan)
        try await canvas.presentOrderedPlan(geometry,plan:plan,canonical:true)
        restoration.installed()
        try await self.waitForStableFrame(canvas,accepted:true)
        var cut:InkCanvasView.AcceptedFrameLease?
        var pressure:RasterReservation?
        if needsNewPool {
          // Refusal happens before the page clock can deliver a drawable.
          canvas.projectPage(region:.init(x:0,y:0,width:2_000,height:2_000),
            sourceSize:.init(width:160,height:160),pixelDensity:2)
        } else {
          // This pool already exists. The borrowed accepted cut forces a new
          // retained texture only after the restoration owns its frame slot.
          cut=try XCTUnwrap(canvas.acquireAcceptedFrameLease())
          pressure=try XCTUnwrap(resources.reserveDerivedBytes(
            resources.byteLimit-resources.reservedBytes,priority:.input))
        }
        defer {pressure?.release();cut?.release()}
        var installed=0,abandoned=0
        restoration.restore(install:{installed += 1},abandon:{abandoned += 1})
        try await NotebookPersistenceFenceContract.until {installed>0 || abandoned>0}
        XCTAssertEqual(installed,0);XCTAssertEqual(abandoned,1)
        XCTAssertEqual(canvas.renderFailure,.resourceLimit)
        XCTAssertEqual(canvas.orderedInkPlan,plan,"Refusal keeps the last complete cut")
        XCTAssertFalse(canvas.framePublicationState.pendingOrderedCut)
        XCTAssertEqual(canvas.framePublicationState.queuedOrderedCuts,0)
        pressure?.release();cut?.release()
        if needsNewPool {
          canvas.projectPage(region:.init(x:0,y:0,width:160,height:160),
            sourceSize:.init(width:160,height:160),pixelDensity:2)
        }
        // The failed private operation is terminal. The normal current source
        // owns recovery after admission returns, with no retained retry waiter.
        canvas.updateOrderedInk(.init())
        try await self.waitForStableFrame(canvas,accepted:true)
        XCTAssertEqual(installed,0);XCTAssertEqual(abandoned,1)
        try await assertUX("failed-restoration-canonical-recovery-\(needsNewPool)",since:.now,window:window) {
          try NotebookUXObservation.Pixels(window:window).matches([
            (canvas.convert(.init(x:80,y:40),to:window),.black),
            (canvas.convert(.init(x:80,y:110),to:window),.paper)])
        }
      }
    }
  }

  @MainActor
  func testRejectedScheduledOrderedFrameCannotOverwriteNewerDesiredPlan() async throws {
    try await withPreparedSelectionCanvas { canvas, window, action, oldPlan in
      var graphic = try XCTUnwrap(oldPlan.bodies.first).graphic
      graphic.transform = .init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 35.0 / 160)
      let latest = try self.handoffPlan(action: action, graphic: graphic)
      let prepared = try await canvas.prepareOrderedPlan(oldPlan)
      var advanced = false, installations = 0
      do {
        try await canvas.presentOrderedPlan(prepared, plan: oldPlan, canonical: true, validate: {
          // This callback runs both before submission and at the scheduled
          // receipt. Supersede A only after it owns the physical frame slot.
          guard canvas.framePublicationState.pendingPresentation != nil else { return true }
          if !advanced { advanced = true; canvas.updateOrderedInk(latest) }
          return false
        }, install: { installations += 1 })
        XCTFail("The stale scheduled candidate must be rejected")
      } catch is CancellationError {}
      XCTAssertTrue(advanced)
      XCTAssertEqual(installations, 0)
      try await self.waitForStableFrame(canvas, accepted: true)
      XCTAssertEqual(canvas.orderedInkPlan, latest)
      XCTAssertFalse(canvas.framePublicationState.pendingOrderedCut)
      XCTAssertEqual(canvas.framePublicationState.queuedOrderedCuts, 0)
      try await assertUX("stale-frame-cannot-restore-older-desire", since: .now, window: window) {
        try NotebookUXObservation.Pixels(window: window).matches([
          (canvas.convert(.init(x: 80, y: 40), to: window), .paper),
          (canvas.convert(.init(x: 80, y: 75), to: window), .black),
          (canvas.convert(.init(x: 80, y: 110), to: window), .paper)])
      }
    }
  }

  @MainActor
  func testAbandonedAndSourceChangedPreparedPageFramesCannotSuppressCurrentInk() async throws {
    try await withPreparedSelectionCanvas { canvas,window,action,plan in
      let count=canvas.committedSourceNodeCount
      var abandoned:InkOrderedGeometry?=try await canvas.prepareOrderedPlan(plan)
      XCTAssertNotNil(abandoned);abandoned=nil
      XCTAssertEqual(canvas.committedSourceNodeCount,count)
      let prepared=try await canvas.prepareOrderedPlan(plan)
      let cancelled=Task {try await canvas.presentOrderedPlan(prepared,plan:plan)}
      cancelled.cancel()
      do {try await cancelled.value;XCTFail("Cancelled publication must leave the accepted ink visible")} catch {}
      canvas.apply(.init(actions:[action,self.handoffStroke(y:75)]))
      try await self.waitForStableFrame(canvas)
      try await assertUX("cancelled-handoff-retains-current-source",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.black),
          (canvas.convert(.init(x:80,y:75),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.paper)])
      }
      let restoration=try XCTUnwrap(canvas.captureSourceRestoration(for:[action.id]))
      let latest=try await canvas.prepareOrderedPlan(plan)
      try await canvas.presentOrderedPlan(latest,plan:plan)
      restoration.installed()
      try await assertUX("new-source-handoff-stays-addressed",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:75),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.black)])
      }
      var restorationInstalled=0,restorationAbandoned=0
      restoration.restore(install:{restorationInstalled += 1},abandon:{restorationAbandoned += 1})
      // The real page owner can replace this canvas before the queued Task
      // starts. A fresh basis must not authorize the old page's restoration.
      canvas.resetPagePresentation()
      canvas.apply(.init(actions:[self.handoffStroke(y:75)]))
      try await NotebookPersistenceFenceContract.until {restorationInstalled>0 || restorationAbandoned>0}
      XCTAssertEqual(restorationInstalled,0);XCTAssertEqual(restorationAbandoned,1)
      try await self.waitForStableFrame(canvas)
      XCTAssertTrue(canvas.orderedInkPlan.isEmpty)
      try await assertUX("queued-restoration-does-not-adopt-replacement-page",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:75),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.paper)])
      }
    }
  }

  @MainActor
  private func withPreparedSelectionCanvas(resources:SceneRenderResources = .init(),_ test:@MainActor (InkCanvasView,UIWindow,PageInkAction,NotebookOrderedInkPlan) async throws -> Void) async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .white
    let canvas=InkCanvasView(frame:.zero,resources:resources)
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    defer {canvas.removeFromSuperview();window.isHidden=true;window.rootViewController=nil;Task {await canvas.finishSpatialHandoffFrames()}}
    canvas.projectPage(region:.init(x:0,y:0,width:160,height:160),sourceSize:.init(width:160,height:160),pixelDensity:2)
    let action=handoffStroke(y:40)
    canvas.apply(.init(actions:[action]));try await waitForStableFrame(canvas)
    try await assertUX("handoff-source-is-on-screen",since:.now,window:window) {
      try NotebookUXObservation.Pixels(window:window).matches([(canvas.convert(.init(x:80,y:40),to:window),.black)])
    }
    let ink=NotebookFreehand(layers:[.init(tool:.pen,color:.black,measured:.init(sourceID:action.id,
      measurements:action.samples,frame:.init(x:0,y:0,width:160,height:160)))])
    let graphic=NotebookGraphic(shape:.freehand,sourceInkIDs:[action.id],freehand:ink,transform:.init(a:1,b:0,c:0,d:1,tx:0,ty:70.0/160))
    try await test(canvas,window,action,handoffPlan(action:action,graphic:graphic))
  }
  private func handoffPlan(action:PageInkAction,graphic:NotebookGraphic) throws -> NotebookOrderedInkPlan {
    let id="moved-contact",node=NotebookGraphicGraph.Node(id:id,graphic:graphic,frame:.init(x:0,y:0,width:160,height:160),surface:.page(UUID()),shown:true)
    let layout=try XCTUnwrap(NotebookGraphicGraph([node]).resolve(id).layout)
    return .init(bodies:[.init(elementID:id,key:.page(sequence:action.sequence,id:action.id),graphic:graphic,layout:layout,erasures:[])],suppressedInkIDs:[action.id])
  }
  @MainActor private func handoffPencil()->ActiveInkStroke {
    let stroke=ActiveInkStroke(style:.standard)
    stroke.replaceMeasuredTail(from:0,with:[CGFloat(20),140].map { x in
      PKStrokePoint(location:.init(x:x,y:145),timeOffset:0,size:.init(width:8,height:8),opacity:1,force:1,azimuth:0,altitude:.pi/2)
    });return stroke
  }
  private func handoffStroke(y:Double)->PageInkAction {
    .init(tool:.pen,samples:[20.0,140].enumerated().map { i,x in
      .init(point:.init(x:x,y:y),timeOffset:Double(i)/60,width:10,opacity:1,force:1,azimuth:0,altitude:1)
    },sequence:1)
  }

  @MainActor
  func testDetachedCanvasCannotStartItsDisplayLoopFromLateFrameRequests() async {
    let canvas = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
    XCTAssertNil(canvas.window)
    XCTAssertTrue(canvas.isFrameLoopPaused, "Construction does not admit a drawable timer")
    canvas.applySpatial(mesh(y: 30))
    canvas.finishSpatialPreparation()
    canvas.project(camera: .init(scale: 0.5), viewport: .init(x: 160, y: 160))
    XCTAssertTrue(canvas.isFrameLoopPaused, "Preparing an unmounted owner changes content, not display execution")

    let lateCompletion = Task { @MainActor in
      await Task.yield()
      canvas.finishSpatialPreparation()
    }
    await lateCompletion.value
    // A callback already queued by MetalKit must also respect the same gate.
    canvas.draw(in: canvas)
    XCTAssertTrue(canvas.isFrameLoopPaused)
    XCTAssertFalse(canvas.isStableFramePresented,
      "A detached live canvas is not the offscreen snapshot publication route")
  }

  @MainActor
  func testRetainedCulledCanvasStopsImmediatelyAndPresentsNewContentAfterRemount() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.backgroundColor = .white
    let canvas = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
    controller.view.addSubview(canvas)
    window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    canvas.applySpatial(mesh(y: 30))
    try await waitForStableFrame(canvas)

    // Retain the exact canvas as UIKit may do. Removing it before the requested
    // draw executes must stop the loop without relying on deallocation.
    canvas.finishSpatialPreparation()
    XCTAssertFalse(canvas.isFrameLoopPaused)
    canvas.removeFromSuperview()
    XCTAssertNil(canvas.window)
    XCTAssertTrue(canvas.isFrameLoopPaused, "Culling stops a pending display loop synchronously")
    canvas.applySpatial(mesh(y: 110))
    XCTAssertFalse(canvas.isStableFramePresented)
    let lateCompletion = Task { @MainActor in
      await Task.yield()
      canvas.finishSpatialPreparation()
    }
    await lateCompletion.value
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(canvas.isFrameLoopPaused, "Late work cannot restart a retained offscreen canvas")
    XCTAssertFalse(canvas.isStableFramePresented)

    controller.view.addSubview(canvas)
    XCTAssertNotNil(canvas.window)
    XCTAssertFalse(canvas.isFrameLoopPaused, "Remount resumes the same physical owner")
    try await waitForStableFrame(canvas)
    XCTAssertGreaterThan(canvas.committedSourceNodeCount, 0)
    XCTAssertTrue(canvas.isFrameLoopPaused, "After presenting the replacement ink, the resting canvas stops again")
  }

  @MainActor
  func testPageLiftKeepsThePendingFirstRevealUntilItsOwnResolution() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where: \.isKeyWindow)
    let window=UIWindow(windowScene:scene),controller=UIViewController()
    window.rootViewController=controller;controller.view.backgroundColor = .white
    let canvas=InkCanvasView(frame:.zero)
    defer {
      canvas.onFirstFrameEvent=nil;canvas.onContactFrameResolved=nil
      canvas.removeFromSuperview();window.isHidden=true;window.rootViewController=nil
      previous?.makeKey()
    }
    canvas.projectPage(region:.init(x:0,y:0,width:160,height:160),
      sourceSize:.init(width:160,height:160),pixelDensity:2)
    let actor=UUID(),page=PageDocument(size:.init(width:160,height:160),actor:actor)
    try page.prepareInkForPresentation()
    canvas.apply(try page.inkDrawing())
    let preparationDeadline=ContinuousClock.now + .seconds(2)
    while !canvas.pageGeometryIsReady,ContinuousClock.now < preparationDeadline {
      try await Task.sleep(for:.milliseconds(1))
    }
    XCTAssertTrue(canvas.pageGeometryIsReady)
    let stroke=handoffPencil(),action=stroke.measured.frozen().restoredAction()
    let change=try page.prepareLiveInkChange(.append(action),stamp:.init(counter:1,actor:actor))
    var first:UUID?,firstCount:Int?,published=Set<UUID>(),resolved:[UUID:NotebookMetalFrameReadiness]=[:]
    var trace:[String]=[],firstResolutionCount:Int?,previousReveal:UUID?
    var acceptedRevision:UInt64?
    canvas.onContactFrameResolved={ receipt in
      trace.append("contact \(receipt.frameID) \(receipt.completion); timing=\(String(describing:receipt.timing))")
    }
    canvas.onFirstFrameEvent={ event in
      trace.append("owner \(event); clock=\(CACurrentMediaTime()); drawables=\(canvas.drawableRequestCount); opacity=\(canvas.layer.opacity)")
      switch event {
      case .willPublish(let submission):
        if let previous=previousReveal {
          XCTAssertNotNil(resolved[previous],
            "Each reveal must resolve before its successor is scheduled")
          if previous != first {
            XCTAssertEqual(resolved[previous]?.isReady,false,
              "Only a discarded accepted reveal may schedule another retry")
          }
        }
        previousReveal=submission
        guard first == nil else {return}
        first=submission;firstCount=canvas.drawableRequestCount
        XCTAssertEqual(canvas.pendingFirstPresentationID,submission)
        let submitted=canvas.drawableRequestCount
        // Actual GPU scheduling precedes this actor turn. Lift and accepted
        // binding change the content revision here, before its real publication.
        canvas.commitActiveStroke(action);canvas.settle(change);canvas.draw()
        acceptedRevision=canvas.framePublicationState.revision
        XCTAssertEqual(canvas.pendingFirstPresentationID,submission)
        XCTAssertEqual(canvas.drawableRequestCount,submitted)
        XCTAssertFalse(canvas.isStableFramePresented,"The old reveal cannot acknowledge the accepted revision")
      case .published(let submission):published.insert(submission)
      case .rejected:break
      case .resolved(let submission,let readiness):
        resolved[submission]=readiness
        if submission == first {firstResolutionCount=canvas.drawableRequestCount}
      }
    }
    canvas.displayActiveStroke(stroke)
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    try await waitForStableFrame(canvas,accepted:true)
    let firstSubmission=try XCTUnwrap(first)
    let evidence=trace.joined(separator:"\n"),attachment=XCTAttachment(string:evidence)
    attachment.name="first-lift-publication-and-OS-outcome";attachment.lifetime = .keepAlways;add(attachment)
    XCTAssertTrue(published.contains(firstSubmission),
      "Binding the same measured material must publish the original reveal without another clock: \(evidence)")
    XCTAssertNotNil(resolved[firstSubmission],"The original reveal must finish through its own real OS outcome: \(evidence)")
    XCTAssertEqual(firstResolutionCount,firstCount,
      "No successor drawable may replace the reveal before its OS presentation/discard: \(evidence)")
    XCTAssertGreaterThan(canvas.drawableRequestCount,try XCTUnwrap(firstCount),
      "The accepted revision follows the original OS outcome, retrying discarded drawables: \(evidence)")
    let accepted=try XCTUnwrap(acceptedRevision),publication=canvas.framePublicationState
    XCTAssertEqual(publication.revision,accepted)
    XCTAssertEqual(publication.preparedRevision,accepted)
    XCTAssertEqual(publication.presentedRevision,accepted)
    XCTAssertNil(publication.pendingPresentation)
    XCTAssertTrue(canvas.acceptedFrameIsReady)
    canvas.onFirstFrameEvent=nil;canvas.onContactFrameResolved=nil
    XCTAssertNil(canvas.pendingFirstPresentationID)
    XCTAssertEqual(canvas.layer.opacity,1)
    XCTAssertTrue(canvas.frameReadiness?.isReady == true)
    let settledDrawables=canvas.drawableRequestCount
    try await Task.sleep(for:.milliseconds(50))
    XCTAssertEqual(canvas.drawableRequestCount,settledDrawables,
      "An accepted, presented revision must retire its frame demand")
    try await assertUX("first-reveal-survives-lift",since:.now,window:window) {
      try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:145),to:window),.black),
        (canvas.convert(.init(x:80,y:40),to:window),.paper)])
    }
    let pools=canvas.pageDrawableAllocationCount
    canvas.apply(.init())
    try await waitForStableFrame(canvas,accepted:true)
    XCTAssertTrue(canvas.acceptedInkIsEmpty)
    XCTAssertEqual(canvas.layer.opacity,1,"Current empty paper is an actually presented transparent frame")
    XCTAssertTrue(canvas.frameReadiness?.isReady == true)
    XCTAssertEqual(canvas.pageDrawableAllocationCount,pools,"Repeated empty material retains its admitted pool")
    canvas.setPageInputEnabled(false)
    canvas.setPageBackingRequired(false,priority:.passive)
    let neighborFrames=canvas.drawableRequestCount
    canvas.apply(.init())
    try await waitForStableFrame(canvas,accepted:true)
    XCTAssertFalse(canvas.hasPageRetainedTexture)
    XCTAssertEqual(canvas.drawableRequestCount,neighborFrames,"Empty neighbors use no drawable")
    var revokedEmptyPaper=false
    canvas.onRenderReadinessChange={ ready in if !ready {revokedEmptyPaper=true} }
    canvas.setPageBackingRequired(true,priority:.input)
    canvas.setPageInputEnabled(true)
    XCTAssertTrue(canvas.acceptedMaterialIsEmpty)
    XCTAssertTrue(canvas.isStableFramePresented,
      "Promoting already transparent paper does not revoke the accepted landing while its native pool warms")
    XCTAssertFalse(revokedEmptyPaper)
    canvas.onRenderReadinessChange=nil
    let blankDeadline=ContinuousClock.now + .seconds(2)
    while canvas.pendingFirstPresentationID == nil,ContinuousClock.now < blankDeadline {
      try await Task.sleep(for:.milliseconds(1))
    }
    let blank=try XCTUnwrap(canvas.pendingFirstPresentationID)
    canvas.displayActiveStroke(handoffPencil())
    XCTAssertNotEqual(canvas.pendingFirstPresentationID,blank,
      "Early Pencil supersedes only the unpresented transparent cut without waiting for its OS receipt")
    canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    XCTAssertTrue(canvas.frameReadiness?.isReady == true)
    try await assertUX("early-pencil-replaces-pending-empty-reveal",since:.now,window:window) {
      try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:145),to:window),.black)])
    }
    canvas.removeFromSuperview()
    for invalidation in ["undo","crop","source","eraser","reset"] {
      try await firstRevealRejectsChangedPixels(invalidation,window:window,controller:controller)
    }
  }

  @MainActor
  private func firstRevealRejectsChangedPixels(_ invalidation:String,window:UIWindow,controller:UIViewController) async throws {
    let canvas=InkCanvasView(frame:.zero),actor=UUID()
    defer {
      canvas.onFirstFrameEvent=nil;canvas.onContactFrameResolved=nil
      canvas.removeFromSuperview()
    }
    canvas.projectPage(region:.init(x:0,y:0,width:160,height:160),sourceSize:.init(width:210,height:160),pixelDensity:2)
    let page=PageDocument(size:.init(width:210,height:160),actor:actor)
    try page.prepareInkForPresentation()
    let base=try page.inkDrawing(),stroke=handoffPencil(),action=stroke.measured.frozen().restoredAction()
    let change=try page.prepareLiveInkChange(.append(action),stamp:.init(counter:1,actor:actor))
    XCTAssertTrue(page.publishLiveInkChange(change))
    let undo=try page.prepareLiveInkChange(.setActive([action.id],false),stamp:.init(counter:2,actor:actor))
    canvas.apply(base)
    let deadline=ContinuousClock.now + .seconds(2)
    while !canvas.pageGeometryIsReady,ContinuousClock.now < deadline {try await Task.sleep(for:.milliseconds(1))}
    XCTAssertTrue(canvas.pageGeometryIsReady)
    var first:UUID?,shown=Set<UUID>(),published=Set<UUID>(),rejected=Set<UUID>()
    canvas.onContactFrameResolved={ receipt in if receipt.completion.isReady {shown.insert(receipt.frameID)} }
    canvas.onFirstFrameEvent={ event in
      switch event {
      case .published(let submission):published.insert(submission);return
      case .rejected(let submission):rejected.insert(submission);return
      case .resolved:return
      case .willPublish(let submission):guard first == nil else {return};first=submission
      }
      canvas.commitActiveStroke(action);canvas.settle(change)
      switch invalidation {
      case "undo":canvas.settle(undo)
      case "crop":canvas.projectPage(region:.init(x:50,y:0,width:160,height:160),
        sourceSize:.init(width:210,height:160),pixelDensity:2)
      case "source":canvas.apply(base)
      case "eraser":
        let eraser=ActiveEraserStroke()
        eraser.replaceMeasuredTail(from:0,with:[20.0,140].map {x in
          .init(point:.init(x:x,y:145),timeOffset:0,width:20,opacity:1,force:1,azimuth:0,altitude:1)
        })
        canvas.displayActiveEraser(eraser);canvas.commitActiveEraser()
      case "reset":canvas.resetPagePresentation();canvas.apply(base)
      default:preconditionFailure("Unknown first-reveal invalidation")
      }
    }
    canvas.displayActiveStroke(stroke);controller.view.addSubview(canvas)
    try await waitForStableFrame(canvas)
    let original=try XCTUnwrap(first)
    XCTAssertTrue(rejected.contains(original),"\(invalidation) must retire the original reveal at publication")
    XCTAssertFalse(published.contains(original),"\(invalidation) must reject obsolete material before exposing its layer")
    XCTAssertFalse(shown.contains(original),
      "\(invalidation) changed pixels: the lifted first contact cannot reveal its obsolete drawable")
    let probe=CGPoint(x:invalidation == "crop" ? 120:80,y:145)
    XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
      (canvas.convert(probe,to:window),.paper)]),"\(invalidation): the current source must show the replacement pixels")
  }

  @MainActor
  func testPageContactKeepsItsUpdateThroughCommitThenParksWhileHeld() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let canvas = InkCanvasView(frame: .zero), observer = UIUpdateLink(view: window)
    defer {
      observer.isEnabled = false; canvas.onContactFrameResolved = nil
      canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil
      previous?.makeKey()
    }
    canvas.projectPage(region: .init(x: 0, y: 0, width: 160, height: 160),
      sourceSize: .init(width: 160, height: 160), pixelDensity: 2)
    canvas.apply(.init()); controller.view.addSubview(canvas); window.makeKeyAndVisible()
    try await waitForStableFrame(canvas)
    var observedCount = canvas.drawableRequestCount
    var participationAtCommit: Bool?
    observer.addAction(to: .afterCATransactionCommit) { _, _ in
      guard canvas.drawableRequestCount > observedCount else { return }
      observedCount = canvas.drawableRequestCount
      participationAtCommit = !canvas.isFrameLoopPaused
    }
    observer.isEnabled = true
    var shown = false
    let stroke = handoffPencil()
    canvas.onContactFrameResolved = { receipt in
      if receipt.contact.sourceID == stroke.measured.sourceID, receipt.completion.isReady { shown = true }
    }
    canvas.displayActiveStroke(stroke)
    let deadline = ContinuousClock.now + .seconds(2)
    while (!shown || !canvas.isFrameLoopPaused), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(participationAtCommit, true,
      "Submitting Metal work must keep the contact's UIKit participation through the same update's CA phase")
    XCTAssertTrue(shown)
    XCTAssertTrue(canvas.isFrameLoopPaused, "An unchanged held contact parks at the final update phase")
    let submitted = canvas.drawableRequestCount
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(canvas.drawableRequestCount, submitted, "A held contact must not submit idle GPU frames")
    canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
  }

  @MainActor
  func testPageCoalescesNewMaterialUntilTheSystemSuppliesADrawable() async throws {
    // Isolate drawable scheduling from the renderer's asynchronous first-use preparation.
    try await InkRasterRenderer.shared.prepareInk()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let canvas = InkCanvasView(frame: .zero)
    controller.view.addSubview(canvas); window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    canvas.projectPage(region: .init(x: 0, y: 0, width: 160, height: 160),
      sourceSize: .init(width: 160, height: 160), pixelDensity: 2)
    var stroke = ActiveInkStroke(style: .standard)
    func move(to y: CGFloat) {
      stroke.replaceMeasuredTail(from: 0, with: [CGFloat(20), 140].map { x in
        PKStrokePoint(location: .init(x: x, y: y), timeOffset: 0,
          size: .init(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
      })
      canvas.displayActiveStroke(stroke)
    }
    move(to: 30); canvas.draw()
    let first = canvas.drawableRequestCount
    XCTAssertEqual(first, 0, "Input cannot synchronously request a page drawable")
    XCTAssertTrue(canvas.isPaused, "The MetalKit timer is not a competing page clock")
    XCTAssertFalse(canvas.isFrameLoopPaused)
    // Remain in the same main-actor turn: the system has not supplied a frame.
    // Newer tails coalesce without blocking this turn to acquire a drawable.
    move(to: 70); canvas.draw()
    move(to: 110); canvas.draw()
    XCTAssertEqual(canvas.drawableRequestCount, first)
    canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    // Simulator readiness is GPU completion, not UIKit window presentation.
    let windowObservationStart = ContinuousClock.now
    XCTAssertGreaterThan(canvas.drawableRequestCount, first)
    let probes: [(CGPoint, NotebookUXObservation.Color)] = [
      (.init(x: 80, y: 30), .paper), (.init(x: 80, y: 70), .paper), (.init(x: 80, y: 110), .black)]
    // Presentation must show the latest material, not replay queued stale tails.
    try await assertUX("page-coalesced-current-material", since: windowObservationStart, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches(
        probes.map { (canvas.convert($0.0, to: window), $0.1) })
    }

    canvas.removeFromSuperview()
    XCTAssertTrue(canvas.isFrameLoopPaused, "A retained page must retire its system clock on cull")
    stroke = ActiveInkStroke(style: .standard)
    move(to: 70)
    canvas.commitActiveStroke()
    canvas.draw()
    XCTAssertTrue(canvas.isFrameLoopPaused, "Offscreen source updates cannot resume the clock")
    controller.view.addSubview(canvas)
    try await waitForStableFrame(canvas)
    try await assertUX("page-remount-keeps-accepted-material", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([
        (canvas.convert(.init(x: 80, y: 70), to: window), .black),
        (canvas.convert(.init(x: 80, y: 110), to: window), .black)])
    }
  }

  @MainActor
  func testPageStopsDrawableProductionWhenAResizedPoolCannotBeAdmitted() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let resources = SceneRenderResources(byteLimit: 512 * 1024)
    let canvas = InkCanvasView(frame: .zero, resources: resources)
    controller.view.addSubview(canvas); window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    func project(_ side: CGFloat) {
      canvas.projectPage(region: .init(x: 0, y: 0, width: side, height: side),
        sourceSize: .init(width: side, height: side), pixelDensity: 1)
    }
    func draw(_ y: CGFloat) {
      let stroke = ActiveInkStroke(style: .standard)
      stroke.replaceMeasuredTail(from: 0, with: [CGFloat(20), 140].map { x in
        PKStrokePoint(location: .init(x: x, y: y), timeOffset: 0,
          size: .init(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
      })
      canvas.displayActiveStroke(stroke)
    }
    project(160)
    draw(30); canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    let frames = canvas.drawableRequestCount
    draw(70)
    project(2_000)
    XCTAssertEqual(canvas.renderFailure, .resourceLimit)
    // Let the final UIKit phase drain; it must not keep an unadmitted Metal
    // clock producing system drawables, even while the contact is retained.
    let deadline = ContinuousClock.now + .seconds(2)
    while !canvas.isFrameLoopPaused, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(canvas.isFrameLoopPaused)
    XCTAssertEqual(canvas.drawableRequestCount, frames)
    XCTAssertLessThanOrEqual(resources.reservedBytes, resources.byteLimit)
    project(160); canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    // Observe UIKit convergence separately from the completed GPU submission.
    let windowObservationStart = ContinuousClock.now
    XCTAssertNil(canvas.renderFailure)
    XCTAssertEqual((canvas.layer as? CAMetalLayer)?.maximumDrawableCount, 2)
    // A failed allocation must retain both the accepted source and live contact.
    try await assertUX("page-restored-pool-keeps-source-and-contact", since: windowObservationStart, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([
        (canvas.convert(.init(x: 80, y: 30), to: window), .black),
        (canvas.convert(.init(x: 80, y: 70), to: window), .black)])
    }
  }

  @MainActor
  func testBorrowedPageCutSurvivesARefusedReplacementAndRecoversOnTheNextRequest() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let resources = SceneRenderResources(byteLimit: 2 * 1024 * 1024)
    let canvas = InkCanvasView(frame: .zero, resources: resources)
    controller.view.addSubview(canvas); window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    canvas.projectPage(region: .init(x: 0, y: 0, width: 160, height: 160),
      sourceSize: .init(width: 200, height: 200), pixelDensity: 1)
    let stroke = ActiveInkStroke(style: .standard)
    stroke.replaceMeasuredTail(from: 0, with: [CGFloat(20), 140].map { x in
      PKStrokePoint(location: .init(x: x, y: 70), timeOffset: 0,
        size: .init(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    })
    canvas.displayActiveStroke(stroke); canvas.commitActiveStroke()
    try await waitForStableFrame(canvas,accepted:true)
    XCTAssertTrue(canvas.hasPageRetainedTexture)
    let cut=try XCTUnwrap(canvas.acquireAcceptedFrameLease())
    defer {cut.release()}
    let pools = canvas.pageDrawableAllocationCount
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(
      resources.byteLimit - resources.reservedBytes, priority: .input))
    defer { pressure.release() }
    // A shifted crop of the same dimensions needs a different accepted cut.
    // Its prior GPU borrower keeps the old texture immutable and charged.
    canvas.projectPage(region:.init(x:1,y:1,width:160,height:160),
      sourceSize:.init(width:200,height:200),pixelDensity:1)
    let deadline = ContinuousClock.now + .seconds(2)
    while !(canvas.renderFailure == .resourceLimit && canvas.isFrameLoopPaused), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(canvas.renderFailure, .resourceLimit)
    XCTAssertTrue(canvas.isFrameLoopPaused, "A rejected static frame cannot demand continuous UIKit updates")
    XCTAssertEqual(canvas.pageDrawableAllocationCount, pools)
    XCTAssertFalse(canvas.acceptedFrameIsReady)
    // A later ordinary input-demand update, not a timer, retries after space
    // returns. It must retain the exact accepted material and existing pool.
    pressure.release()
    canvas.setPageInputEnabled(false); canvas.setPageInputEnabled(true)
    let recoveryDeadline = ContinuousClock.now + .seconds(2)
    while canvas.renderFailure != nil, ContinuousClock.now < recoveryDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForStableFrame(canvas,accepted:true)
    XCTAssertNil(canvas.renderFailure)
    XCTAssertTrue(canvas.hasPageRetainedTexture)
    let replacement=try XCTUnwrap(canvas.acquireAcceptedFrameLease())
    defer {replacement.release()}
    XCTAssertFalse(replacement.texture === cut.texture,"A borrower never observes the subsequent write")
    XCTAssertEqual(canvas.pageDrawableAllocationCount, pools)
    try await assertUX("page-retained-pressure-recovers-accepted-ink", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([
        (canvas.convert(.init(x: 80, y: 70), to: window), .black)])
    }
  }

  @MainActor
  private func waitForStableFrame(_ canvas: InkCanvasView,accepted:Bool = false) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(canvas.isStableFramePresented && canvas.isFrameLoopPaused && (!accepted || canvas.acceptedFrameIsReady)), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(canvas.isStableFramePresented, "The mounted canvas must complete a frame of its current ink")
    XCTAssertTrue(canvas.isFrameLoopPaused)
  }

  private func mesh(y: CGFloat) -> SpatialInkMesh {
    let points = [CGFloat(20), 140].map { x in
      PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: 0,
        size: CGSize(width: 5, height: 5), opacity: 1, force: 1,
        azimuth: 0, altitude: .pi / 2)
    }
    return .local([.ink(points: points, color: .black)])
  }
}
