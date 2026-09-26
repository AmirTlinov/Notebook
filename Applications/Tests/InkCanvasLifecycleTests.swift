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
      let frame=try await canvas.prepareFrame(.ordered(plan))
      XCTAssertTrue(frame.isValid)
      XCTAssertEqual(canvas.committedSourceNodeCount,count)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:40),to:window),.black),
        (canvas.convert(.init(x:80,y:110),to:window),.paper)]))
      let began=ContinuousClock.now
      canvas.installPreparedFrame(frame)
      XCTAssertEqual(canvas.layer.opacity,1,"Installing visibility cannot revoke its own prepared drawable")
      XCTAssertEqual(canvas.orderedInkPlan,plan)
      try await assertUX("whole-contact-native-handoff",since:began,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:110),to:window),.black)])
      }
      XCTAssertEqual(canvas.pageMeshBuildCount,builds)
      let restored=try await canvas.prepareFrame(.ordered(.init()))
      let restoreBegan=ContinuousClock.now
      canvas.installPreparedFrame(restored)
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
      let candidate=try await canvas.prepareFrame(.ordered(plan))
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(before.map{(canvas.convert($0.0,to:window),$0.1)}))
      canvas.installPreparedFrame(candidate)
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
      let hiddenFrame=try await canvas.prepareFrame(.ordered(.init(suppressedInkIDs:[hidden.id])))
      canvas.installPreparedFrame(hiddenFrame);try await self.waitForStableFrame(canvas)
      let plan=NotebookOrderedInkPlan(bodies:moved.bodies,suppressedInkIDs:moved.suppressedInkIDs.union([hidden.id]))
      let restoration=try XCTUnwrap(canvas.captureSourceRestoration(for:Set(moved.bodies.map(\.sourceID))))
      let frame=try await canvas.prepareFrame(.ordered(plan))
      canvas.installPreparedFrame(frame);restoration.installed()
      try await assertUX("selection-before-pencil-cancel",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:110),to:window),.black)])
      }
      canvas.setPageInputEnabled(false);try await self.waitForStableFrame(canvas)
      let pressure=try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit-resources.reservedBytes,priority:.input))
      defer {pressure.release()}
      var retired=0,abandoned=0
      restoration.restore(install:{retired += 1},abandon:{abandoned += 1})
      canvas.setPageInputEnabled(true)
      let deadline=ContinuousClock.now + .seconds(2)
      while !(canvas.renderFailure == .resourceLimit && canvas.isFrameLoopPaused),ContinuousClock.now<deadline {
        try await Task.sleep(for:.milliseconds(10))
      }
      XCTAssertEqual(canvas.renderFailure,.resourceLimit);XCTAssertEqual(retired,0);XCTAssertEqual(abandoned,0)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:40),to:window),.paper),
        (canvas.convert(.init(x:80,y:110),to:window),.black)]))
      pressure.release()
      let began=ContinuousClock.now
      canvas.setPageInputEnabled(false);canvas.setPageInputEnabled(true)
      let pencil=self.handoffPencil();canvas.displayActiveStroke(pencil)
      let contact=try XCTUnwrap(canvas.activeContactFrame)
      try await assertUX("raw-return-with-active-pencil",since:began,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.paper),
          (canvas.convert(.init(x:80,y:145),to:window),.black)])
      }
      XCTAssertEqual(retired,1);XCTAssertEqual(abandoned,0);XCTAssertEqual(canvas.activeContactFrame,contact)
      XCTAssertEqual(canvas.orderedInkPlan.suppressedInkIDs,[hidden.id],"Rollback removes only this edit, not an already erased canonical contact")
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (canvas.convert(.init(x:80,y:75),to:window),.paper)]))
      canvas.commitActiveStroke();try await self.waitForStableFrame(canvas)
    }
  }

  @MainActor
  func testAbandonedAndSourceChangedPreparedPageFramesCannotSuppressCurrentInk() async throws {
    try await withPreparedSelectionCanvas { canvas,window,action,plan in
      let count=canvas.committedSourceNodeCount
      var abandoned:InkCanvasView.PreparedFrame?=try await canvas.prepareFrame(.ordered(plan))
      XCTAssertTrue(abandoned?.isValid == true);abandoned=nil
      XCTAssertEqual(canvas.committedSourceNodeCount,count)
      let stale=try await canvas.prepareFrame(.ordered(plan))
      canvas.apply(.init(actions:[action,self.handoffStroke(y:75)]))
      XCTAssertFalse(stale.isValid)
      try await self.waitForStableFrame(canvas)
      try await assertUX("cancelled-handoff-retains-current-source",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.black),
          (canvas.convert(.init(x:80,y:75),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.paper)])
      }
      let latest=try await canvas.prepareFrame(.ordered(plan));XCTAssertTrue(latest.isValid)
      canvas.installPreparedFrame(latest)
      try await assertUX("new-source-handoff-stays-addressed",since:.now,window:window) {
        try NotebookUXObservation.Pixels(window:window).matches([
          (canvas.convert(.init(x:80,y:40),to:window),.paper),
          (canvas.convert(.init(x:80,y:75),to:window),.black),
          (canvas.convert(.init(x:80,y:110),to:window),.black)])
      }
    }
  }

  @MainActor
  private func withPreparedSelectionCanvas(resources:SceneRenderResources = .init(),_ test:(InkCanvasView,UIWindow,PageInkAction,NotebookOrderedInkPlan) async throws -> Void) async throws {
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
  func testPageRetainedTextureFailureDrainsBothClocksAndRecoversOnTheNextRequest() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let resources = SceneRenderResources(byteLimit: 2 * 1024 * 1024)
    let canvas = InkCanvasView(frame: .zero, resources: resources)
    controller.view.addSubview(canvas); window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    canvas.projectPage(region: .init(x: 0, y: 0, width: 160, height: 160),
      sourceSize: .init(width: 160, height: 160), pixelDensity: 1)
    let stroke = ActiveInkStroke(style: .standard)
    stroke.replaceMeasuredTail(from: 0, with: [CGFloat(20), 140].map { x in
      PKStrokePoint(location: .init(x: x, y: 70), timeOffset: 0,
        size: .init(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    })
    canvas.displayActiveStroke(stroke); canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    XCTAssertTrue(canvas.hasPageRetainedTexture)
    // Keep the admitted drawable pool and accepted source. Only the optional
    // input history texture is withdrawn; the next request is not a resize.
    canvas.setPageInputEnabled(false)
    try await waitForStableFrame(canvas)
    XCTAssertFalse(canvas.hasPageRetainedTexture)
    let frames = canvas.drawableRequestCount, pools = canvas.pageDrawableAllocationCount
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(
      resources.byteLimit - resources.reservedBytes, priority: .input))
    defer { pressure.release() }
    canvas.setPageInputEnabled(true)
    let deadline = ContinuousClock.now + .seconds(2)
    while !(canvas.renderFailure == .resourceLimit && canvas.isFrameLoopPaused), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(canvas.renderFailure, .resourceLimit)
    XCTAssertTrue(canvas.isFrameLoopPaused, "A rejected static frame cannot demand continuous UIKit updates")
    XCTAssertEqual(canvas.drawableRequestCount, frames)
    XCTAssertEqual(canvas.pageDrawableAllocationCount, pools)
    // A later ordinary input-demand update, not a timer, retries after space
    // returns. It must retain the exact accepted material and existing pool.
    pressure.release()
    canvas.setPageInputEnabled(false); canvas.setPageInputEnabled(true)
    let recoveryDeadline = ContinuousClock.now + .seconds(2)
    while canvas.renderFailure != nil, ContinuousClock.now < recoveryDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForStableFrame(canvas)
    XCTAssertNil(canvas.renderFailure)
    XCTAssertTrue(canvas.hasPageRetainedTexture)
    XCTAssertEqual(canvas.pageDrawableAllocationCount, pools)
    try await assertUX("page-retained-pressure-recovers-accepted-ink", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([
        (canvas.convert(.init(x: 80, y: 70), to: window), .black)])
    }
  }

  @MainActor
  private func waitForStableFrame(_ canvas: InkCanvasView) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(canvas.isStableFramePresented && canvas.isFrameLoopPaused), ContinuousClock.now < deadline {
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
