import NotebookCore
import PencilKit
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class PageInkProjectionTests: XCTestCase {
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
      XCTAssertLessThanOrEqual(canvas.drawableSize.width, window.bounds.width * window.screen.scale + 6)
      XCTAssertLessThanOrEqual(canvas.drawableSize.height, window.bounds.height * window.screen.scale + 6)
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
