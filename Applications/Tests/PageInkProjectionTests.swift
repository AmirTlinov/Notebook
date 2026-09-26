import NotebookCore
import PencilKit
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

@MainActor
final class PageInkProjectionTests: XCTestCase {
  func testSimulatorGPUReadinessCannotBecomeAnOSPresentationMeasurement() {
    let ready = NotebookMetalFrameReadiness.simulatorCommandCompletion(true)
    XCTAssertTrue(ready.isReady)
    XCTAssertNil(ready.presentedTime)
    XCTAssertFalse(NotebookMetalFrameReadiness.simulatorCommandCompletion(false).isReady)
    for time in [0, -1, Double.nan, Double.infinity] {
      let invalid=NotebookMetalFrameReadiness.osPresentation(time)
      XCTAssertFalse(invalid.isReady)
      XCTAssertNil(invalid.presentedTime,"Invalid presentation cannot become display timing evidence")
    }
    XCTAssertNil(NotebookMetalFrameReadiness.simulatorCommandCompletion(false).presentedTime)
    XCTAssertTrue(NotebookMetalFrameReadiness.osPresentation(42).isReady)
    XCTAssertEqual(NotebookMetalFrameReadiness.osPresentation(42).presentedTime, 42)
  }

  func testHeldZoomUsesScreenDensityAndKeepsInputAndSourceCoordinates() async throws {
    let (window, paper) = try makePaper()
    defer { paper.retireInput(); window.isHidden = true; window.rootViewController = nil }
    let projection = ScenePlaneProjection(.init(boardID: UUID(), mode: .page,
      camera: .init(), viewport: .init(x: window.bounds.width, y: window.bounds.height)))
    paper.inkProjection.observe(projection)
    paper.inkView.apply(PageInkDrawing(actions: [line()]))
    guard try await ready(paper.inkView) else { return }
    let builds = paper.inkView.pageMeshBuildCount, vertices = paper.inkView.committedSourceNodeCount
    for scale: CGFloat in [1, 2, 4, 8, 3, 1] {
      paper.transform = .init(scaleX: scale, y: scale)
      paper.center = .init(x: window.bounds.midX, y: window.bounds.midY)
      projection.didProject() // Native camera notification, without SwiftUI republishing the page.
      XCTAssertEqual((paper.inkView.layer as? CAMetalLayer)?.drawableSize, paper.inkView.drawableSize,
        "The actual Metal pool must follow projection without a MetalKit draw cycle")
      guard try await ready(paper.inkView) else { return }
      let canvas = paper.inkView
      XCTAssertEqual(canvas.drawableSize.width / canvas.bounds.width, scale * window.screen.scale, accuracy: 0.02)
      XCTAssertEqual(canvas.drawableSize.height / canvas.bounds.height, scale * window.screen.scale, accuracy: 0.02)
      let guardSize=InkCanvasView.sceneBackingSize(viewport:.init(
        x:window.bounds.width+4/window.screen.scale,y:window.bounds.height+4/window.screen.scale),
        displayScale:window.screen.scale)
      XCTAssertLessThanOrEqual(canvas.drawableSize.width,guardSize.x*window.screen.scale+2)
      XCTAssertLessThanOrEqual(canvas.drawableSize.height,guardSize.y*window.screen.scale+2)
      XCTAssertEqual(canvas.pageMeshBuildCount, builds)
      XCTAssertEqual(canvas.committedSourceNodeCount, vertices)
      XCTAssertEqual(paper.touchView.bounds.size, CGSize(width: 300, height: 300))
      let point = paper.touchView.convert(CGPoint(x: window.bounds.midX, y: window.bounds.midY), from: window)
      XCTAssertEqual(point.x, 150, accuracy: 0.001); XCTAssertEqual(point.y, 150, accuracy: 0.001)
      if scale == 8 {
        let image = capture(window)
        let samples = try centerRow(image)
        let center = samples.count/2
        XCTAssertLessThan(samples[center], 40, "The original diagonal crosses the crop center")
        let fringe = samples[(center-40)...(center+40)].filter { $0 > 16 && $0 < 239 }.count
        XCTAssertLessThanOrEqual(fringe, 4, "Zoom must regenerate edges, not magnify the original MSAA fringe")
        let proof = XCTAttachment(image: image); proof.name = "own-ink-native-8x-sharp"; proof.lifetime = .keepAlways; add(proof)
      }
    }
  }

  func testZoomedLiveStrokeAndEraserShareTheCroppedProjection() async throws {
    let (window, paper) = try makePaper()
    defer { paper.retireInput(); window.isHidden = true; window.rootViewController = nil }
    paper.transform = .init(scaleX: 8, y: 8)
    paper.center = .init(x: window.bounds.midX, y: window.bounds.midY)
    paper.inkProjection.refresh()
    let pen = ActiveInkStroke(style: .standard)
    pen.replaceMeasuredTail(from: 0, with: [point(80,150,width:4),point(220,150,width:4)])
    paper.inkView.displayActiveStroke(pen)
    paper.inkView.commitActiveStroke()
    guard try await ready(paper.inkView) else { return }
    let before = try centerRow(capture(window))
    XCTAssertLessThan(before[before.count/2], 40)
    let eraser = ActiveEraserStroke()
    eraser.replaceMeasuredTail(from:0,with:[point(150,100,width:12),point(150,200,width:12)])
    paper.inkView.displayActiveEraser(eraser)
    paper.inkView.commitActiveEraser()
    guard try await ready(paper.inkView) else { return }
    let after = try centerRow(capture(window))
    XCTAssertGreaterThan(after[after.count/2], 240, "The eraser must remove the center in canonical page coordinates")
    XCTAssertLessThan(after[after.count/2+150], 40, "Ink outside the eraser remains in the same place")
  }

  func testPreparedPagesKeepMSAAInTileMemoryAndEmptyPagesReleaseBacking() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    // Three 600px canvases own drawables plus the accepted-page composite.
    // MSAA stays tile-local; the retained history is separately accounted.
    let resources = SceneRenderResources(byteLimit: 24 * 1024 * 1024)
    var pages: [InkCanvasView] = []
    for _ in 0..<3 {
      let canvas = InkCanvasView(frame: .zero, resources: resources)
      controller.view.addSubview(canvas)
      canvas.projectPage(region: .init(x: 0, y: 0, width: 300, height: 300),
        sourceSize: .init(width: 300, height: 300), pixelDensity: 2)
      canvas.apply(PageInkDrawing(actions: [line()]))
      guard try await ready(canvas) else { return }
      XCTAssertEqual(canvas.sampleCount, 1, "MTKView must not allocate duplicate MSAA storage")
      XCTAssertTrue(canvas.hasPageRetainedTexture)
      pages.append(canvas)
    }
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    XCTAssertLessThanOrEqual(resources.reservedBytes, resources.byteLimit)
    for page in pages { page.apply(PageInkDrawing()); guard try await ready(page) else { return } }
    XCTAssertEqual(resources.reservedBytes, 0, "Empty pages retain routing, not fictitious backing")

    let erase = PageInkAction(tool: .eraser, points: [point(50, 70), point(250, 230)])
    for page in pages {
      page.apply(PageInkDrawing(actions: [erase])); guard try await ready(page) else { return }
      XCTAssertGreaterThan(page.committedEraserSourceNodeCount, 0,
        "Reclaim the backing, not the accepted measurements or history")
    }
    XCTAssertEqual(resources.reservedBytes, 0,
      "An eraser without earlier ink contributes no visible material")
    let last = try XCTUnwrap(pages.last)
    last.apply(PageInkDrawing(actions: [erase, line()])); guard try await ready(last) else { return }
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    XCTAssertTrue(try NotebookUXObservation.Pixels(window: window).matches([
      (last.convert(.init(x: 150, y: 150), to: window), .black)]),
      "A later pen remains visible: the earlier absence must not erase future material")
    last.apply(PageInkDrawing(actions: [erase])); guard try await ready(last) else { return }
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testActiveSamplesDoNotQueryTheUnchangedHundredThousandPointBaseline() async throws {
    let (window,paper)=try makePaper()
    defer { paper.retireInput();window.isHidden=true;window.rootViewController=nil }
    let samples=(0..<100_000).map { i in SpatialInkSample(point:.init(x:Double(i%1000)/4+20,y:Double(i/1000)*2+20),
      timeOffset:Double(i)/240,width:2,opacity:1,force:1,azimuth:0,altitude:1) }
    paper.inkView.apply(PageInkDrawing(actions:[.init(tool:.pen,samples:samples)]))
    guard try await ready(paper.inkView) else { return }
    let visits=paper.inkView.committedIndexVisitCount
    XCTAssertGreaterThan(visits,0)
    let pen=ActiveInkStroke(style:.standard)
    for i in 0..<20 {
      pen.replaceMeasuredTail(from:i,with:[point(CGFloat(30+i*5),150,width:4)])
      paper.inkView.displayActiveStroke(pen)
      try await Task.sleep(for:.milliseconds(20))
    }
    XCTAssertEqual(paper.inkView.committedIndexVisitCount,visits,"Only the active tail changes at a fixed camera")
    paper.inkView.commitActiveStroke();guard try await ready(paper.inkView) else { return }
  }

  func testFourRetinaCurlPagesFitWithoutDuplicatingInactiveHistory() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),host=UIViewController()
    window.rootViewController=host;window.makeKeyAndVisible()
    defer { window.isHidden=true;window.rootViewController=nil }
    let resources=SceneRenderResources(byteLimit:192 * 1024 * 1024)
    var pages:[InkCanvasView]=[]
    for index in 0..<PageTurnPrewarmWindow.capacity {
      let canvas=InkCanvasView(frame:.zero,resources:resources)
      canvas.setPageInputEnabled(index == 0)
      host.view.addSubview(canvas)
      canvas.projectPage(region:.init(x:0,y:0,width:834,height:1194),
        sourceSize:.init(width:834,height:1194),pixelDensity:2)
      canvas.apply(PageInkDrawing(actions:[line()]))
      guard try await ready(canvas) else { return }
      XCTAssertEqual(canvas.hasPageRetainedTexture,index == 0)
      pages.append(canvas)
    }
    // Transfer input ownership without retaining a second history backing.
    pages[0].setPageInputEnabled(false)
    pages[1].setPageInputEnabled(true)
    guard try await ready(pages[1]) else { return }
    XCTAssertFalse(pages[0].hasPageRetainedTexture)
    XCTAssertTrue(pages[1].hasPageRetainedTexture)
    XCTAssertLessThanOrEqual(resources.reservedBytes,resources.byteLimit)
  }

  func testCameraSweepReportsPageBackingWork() async throws {
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene),host=UIViewController()
    window.rootViewController=host;window.makeKeyAndVisible()
    var papers:[PaperCanvasContainerView]=[]
    let activity=PageTurnActivity()
    var readiness:[PageTurnReadiness]=[],invalidations:[Int]=[]
    defer { for paper in papers { paper.retireInput() };window.isHidden=true;window.rootViewController=nil }
    for index in 0..<PageTurnPrewarmWindow.capacity {
      let paper=PaperCanvasContainerView(frame:.init(x:0,y:0,width:300,height:300))
      host.view.addSubview(paper);paper.inkView.setPageInputEnabled(index == PageTurnPrewarmWindow.capacity-1)
      paper.center = .init(x:window.bounds.midX,y:window.bounds.midY)
      let pageReady=PageTurnReadiness(activity:activity,pageIndex:index) { ready in
        if !ready { invalidations.append(index) }
      }
      readiness.append(pageReady)
      // The ordinary stack leaves all sheets mounted/visible. Only the native
      // current/demand role can distinguish passive neighbours from this page.
      paper.inkProjection.observePage(pageReady,isCurrent:index == PageTurnPrewarmWindow.capacity-1,isVisible:true)
      paper.inkProjection.setRefinesDetails(false)
      paper.inkView.apply(PageInkDrawing(actions:[line()]));paper.inkProjection.refresh()
      guard try await ready(paper.inkView) else { return };papers.append(paper)
    }
    let before=papers.map { ($0.inkView.pageProjectionChangeCount,$0.inkView.pageDrawableResizeCount,
      $0.inkView.pageDrawableAllocationCount,$0.inkView.pageRetainedAllocationCount,$0.inkView.pageMeshBuildCount) }
    for step in 1...30 {
      let scale=CGFloat(1+Double(step)/100)
      for paper in papers {
        paper.transform = .init(scaleX:scale,y:scale)
        paper.center = .init(x:window.bounds.midX+CGFloat(step%3),y:window.bounds.midY)
        paper.inkProjection.refresh()
      }
      for paper in papers { guard try await ready(paper.inkView) else { return } }
    }
    for (index,paper) in papers.enumerated() {
      XCTAssertEqual(paper.inkView.pageProjectionChangeCount,before[index].0,
        "Thirty covered camera samples stay within the existing movement-density allowance")
    }
    let current=try XCTUnwrap(papers.last)
    invalidations.removeAll()
    activity.refinePresentation(at:PageTurnPrewarmWindow.capacity-1)
    XCTAssertEqual(invalidations,[PageTurnPrewarmWindow.capacity-1],
      "Only the stationary installed page revokes its movement-quality receipt")
    guard try await ready(current.inkView) else { return }
    current.inkProjection.setRefinesDetails(true)
    XCTAssertEqual(current.inkView.drawableSize.width/current.inkView.bounds.width,
      1.3*window.screen.scale,accuracy:0.02,"Stationary refinement restores exact detail")
    let counts=papers.enumerated().map { index,paper in
      let canvas=paper.inkView,initial=before[index]
      XCTAssertEqual(canvas.pageMeshBuildCount,initial.4,"Camera reuses canonical geometry")
      if index < PageTurnPrewarmWindow.capacity-1 {
        XCTAssertEqual(canvas.pageProjectionChangeCount,initial.0,"Hidden prewarm does not chase another sheet's camera")
        XCTAssertEqual(canvas.pageDrawableAllocationCount,initial.2)
      } else {
        XCTAssertEqual(canvas.pageProjectionChangeCount-initial.0,1,"One stationary refinement, not thirty per-sample resizes")
        XCTAssertEqual(canvas.pageDrawableAllocationCount-initial.2,1,"One atomic resize admits only the final drawable size")
        XCTAssertEqual(canvas.pageRetainedAllocationCount-initial.3,1)
      }
      return ["page":index,"projectionChanges":canvas.pageProjectionChangeCount-initial.0,
        "drawableResizes":canvas.pageDrawableResizeCount-initial.1,
        "drawableAllocations":canvas.pageDrawableAllocationCount-initial.2,
        "retainedAllocations":canvas.pageRetainedAllocationCount-initial.3]
    }
    let data=try JSONSerialization.data(withJSONObject:counts,options:[.sortedKeys])
    print("PAGE_CAMERA_ALLOCATION_TRACE "+String(decoding:data,as:UTF8.self))
    let trace=XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
    trace.name="page-camera-allocation-counters-not-FPS";trace.lifetime = .keepAlways;add(trace)
    let promoted=try XCTUnwrap(papers.first)
    invalidations.removeAll()
    activity.prepare(0)
    XCTAssertEqual(invalidations,[0],"Demand synchronously revokes only the target's cached readiness before capture")
    guard try await ready(promoted.inkView) else { return }
    XCTAssertGreaterThan(promoted.inkView.pageProjectionChangeCount,before[0].0)
    for index in 1..<(PageTurnPrewarmWindow.capacity-1) {
      XCTAssertEqual(papers[index].inkView.pageProjectionChangeCount,before[index].0)
    }
    activity.didInstall(activity.preparationDemand);activity.prepare(nil)
    for (index,paper) in papers.enumerated() {
      paper.inkProjection.observePage(readiness[index],isCurrent:index == 0,isVisible:true)
    }
    XCTAssertEqual(promoted.inkView.drawableSize.width/promoted.inkView.bounds.width,
      1.3*window.screen.scale,accuracy:0.02,"A newly visible sheet immediately regains exact screen density")
  }

  func testStationaryOpeningRefinesTheInstalledNativePoseBeforeReadingReady() async throws {
    let controller=IPadPageTurnController()
    let window=UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let paper=PaperCanvasContainerView(frame:.init(x:0,y:0,width:300,height:300))
    controller.update(ownerID:UUID(),sequenceRevision:"stationary-page",pageCount:1,
      selectedIndex:0,navigationIsEnabled:false,pageIsInteractive:false,canBeginNavigation:{false},
      page:{_,_,ready in AnyView(StationaryProjectionPaper(paper:paper,readiness:ready).frame(width:300,height:300))},
      onCommit:{_,_ in XCTFail("Refinement is not a page turn")},onTransitioningChange:{_ in})
    window.rootViewController=controller;window.makeKeyAndVisible();window.layoutIfNeeded()
    defer { paper.retireInput();window.isHidden=true;window.rootViewController=nil }
    paper.inkView.apply(PageInkDrawing(actions:[line()]));paper.inkProjection.refresh()
    guard try await ready(paper.inkView) else { return }
    XCTAssertTrue(controller.currentPagePreparation.isReady)
    let initial=paper.inkView.pageProjectionChangeCount
    paper.transform = .init(scaleX:1.1,y:1.1)
    paper.inkProjection.refresh()
    XCTAssertEqual(paper.inkView.pageProjectionChangeCount,initial)
    XCTAssertTrue(controller.prepareCurrentPage(refinesDetails:false).isReady,
      "A human moving-camera probe preserves the admitted movement quality")
    XCTAssertFalse(controller.prepareCurrentPage(refinesDetails:true).isReady,
      "Stationary preparation must revoke the old crop synchronously, before consuming cached readiness")
    XCTAssertEqual(paper.inkView.pageProjectionChangeCount,initial+1)
    XCTAssertFalse(controller.currentPagePreparation.isReady)
    guard try await ready(paper.inkView) else { return }
    XCTAssertTrue(controller.prepareCurrentPage(refinesDetails:true).isReady)
    XCTAssertEqual(paper.inkView.drawableSize.width/paper.inkView.bounds.width,
      1.1*window.screen.scale,accuracy:0.02)
    let prepared=paper.inkView.pageProjectionChangeCount
    // The later ordinary SwiftUI update must not create another backing.
    paper.inkProjection.setRefinesDetails(true)
    XCTAssertEqual(paper.inkView.pageProjectionChangeCount,prepared)
    XCTAssertTrue(controller.currentPagePreparation.isReady)
  }

  private func makePaper() throws -> (UIWindow, PaperCanvasContainerView) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene:scene), controller = UIViewController()
    window.rootViewController = controller
    controller.view.backgroundColor = .white
    let paper = PaperCanvasContainerView(frame:.init(x:0,y:0,width:300,height:300))
    controller.view.addSubview(paper); window.makeKeyAndVisible(); window.layoutIfNeeded()
    paper.center = .init(x:window.bounds.midX,y:window.bounds.midY)
    paper.inkProjection.refresh()
    return (window,paper)
  }
  private func point(_ x:CGFloat,_ y:CGFloat,width:CGFloat=1) -> PKStrokePoint {
    .init(location:.init(x:x,y:y),timeOffset:0,size:.init(width:width,height:width),opacity:1,force:1,azimuth:0,altitude:.pi/2)
  }
  private func line() -> PageInkAction { .init(tool:.pen,points:[point(50,70),point(250,230)]) }
  private func ready(_ view: InkCanvasView, file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
    let until = ContinuousClock.now + .seconds(5), frames = view.drawableRequestCount
    while !view.isStableFramePresented {
      if view.renderFailure != nil || ContinuousClock.now >= until {
        // A known failed readiness check is an assertion, not an unexpected
        // thrown error. XCTest's error symbolication otherwise obscures the
        // original failure and can stall this physical-device run for minutes.
        XCTFail("Page frame not ready: failure=\(String(describing: view.renderFailure)), "
          + "prepared=\(view.isStableFramePrepared), geometry=\(view.pageGeometryIsReady), "
          + "newFrames=\(view.drawableRequestCount - frames), paused=\(view.isFrameLoopPaused), "
          + "window=\(view.window != nil), opacity=\(view.layer.opacity), "
          + "frame=\(view.frame), pixels=\(view.drawableSize), layerPixels=\(String(describing: (view.layer as? CAMetalLayer)?.drawableSize)), "
          + "visible=\(SceneSourceVisibility.visibleRect(view))", file: file, line: line)
        return false
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(60))
    return true
  }
  private func capture(_ window:UIWindow) -> UIImage {
    let format = UIGraphicsImageRendererFormat();format.scale = window.screen.scale;format.opaque = true
    return UIGraphicsImageRenderer(bounds:window.bounds,format:format).image { _ in
      window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
    }
  }
  private func centerRow(_ image:UIImage) throws -> [UInt8] {
    let cg = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating:0,count:cg.width*cg.height*4)
    let context = try XCTUnwrap(CGContext(data:&bytes,width:cg.width,height:cg.height,bitsPerComponent:8,
      bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
    return (0..<cg.width).map { bytes[(cg.height/2*cg.width+$0)*4] }
  }
}

/// Native paper mounted by the same hosting contract as a real notebook page.
private struct StationaryProjectionPaper: UIViewRepresentable {
  let paper: PaperCanvasContainerView
  let readiness: PageTurnReadiness
  func makeUIView(context: Context) -> PaperCanvasContainerView { paper }
  func updateUIView(_ view: PaperCanvasContainerView, context: Context) {
    view.inkProjection.observePage(readiness,isCurrent:true,isVisible:true)
    view.inkProjection.setRefinesDetails(false)
    view.inkView.onRenderReadinessChange = { readiness($0) }
  }
  static func dismantleUIView(_ view: PaperCanvasContainerView, coordinator: ()) {
    view.inkView.onRenderReadinessChange = nil
    view.retireInput()
  }
}
