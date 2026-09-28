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
      let latest=try await canvas.prepareOrderedPlan(plan)
      try await canvas.presentOrderedPlan(latest,plan:plan)
      try await assertUX("new-source-handoff-stays-addressed",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:75),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.black)])
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
    controller.view.addSubview(canvas);window.makeKeyAndVisible()
    defer {
      canvas.removeFromSuperview();window.isHidden=true;window.rootViewController=nil
      previous?.makeKey()
    }
    canvas.projectPage(region:.init(x:0,y:0,width:160,height:160),
      sourceSize:.init(width:160,height:160),pixelDensity:2)
    canvas.displayActiveStroke(handoffPencil())
    let deadline=ContinuousClock.now + .seconds(2)
    while canvas.pendingFirstPresentationID == nil,ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(1))
    }
    let first=try XCTUnwrap(canvas.pendingFirstPresentationID,
      "The cold drawable must own an observable transaction until its own resolution")
    let submitted=canvas.drawableRequestCount
    // Lift changes accepted content while the first real drawable is pending.
    // It cannot relinquish that drawable's reveal or admit a competing one in
    // this actor turn. No fake frame/receipt or forced CA transaction is used.
    canvas.commitActiveStroke()
    canvas.draw()
    XCTAssertEqual(canvas.pendingFirstPresentationID,first)
    XCTAssertEqual(canvas.drawableRequestCount,submitted)
    try await waitForStableFrame(canvas)
    XCTAssertNil(canvas.pendingFirstPresentationID)
    XCTAssertEqual(canvas.layer.opacity,1)
    XCTAssertTrue(canvas.frameReadiness?.isReady == true)
    try await assertUX("first-reveal-survives-lift",since:.now,window:window) {
      try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:145),to:window),.black),
        (canvas.convert(.init(x:80,y:40),to:window),.paper)])
    }
  }

  @MainActor
  func testPageCoalescesNewMaterialUntilTheSystemSuppliesADrawable() async throws {
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
