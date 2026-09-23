import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

@MainActor
final class PageInkProjectionTests: XCTestCase {
  func testPagePoolResizesWithoutRunningTheMetalKitDrawCycle() {
    let canvas = InkCanvasView(frame: .zero)
    for density: CGFloat in [1, 2, 4, 1] {
      canvas.projectPage(region: .init(x: 0, y: 0, width: 160, height: 120),
        sourceSize: .init(width: 160, height: 120), pixelDensity: density)
      XCTAssertEqual((canvas.layer as? CAMetalLayer)?.drawableSize,
        CGSize(width: 160 * density, height: 120 * density))
      XCTAssertEqual(canvas.drawableRequestCount, 0, "Projection must not synchronously draw")
    }
  }

  func testNativeCameraNotifiesThePageWithoutRepublishingItsContent() {
    let plane = SceneCameraPlaneView<Int>()
    plane.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
    let initial = SessionPresence(mode: .page, camera: .init(scale: 1), viewport: .init(x: 500, y: 400))
    let observer = ProjectionObserver()
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      projection.register(observer)
      return AnyView(Color.clear)
    }
    plane.update(presence: initial, revision: 0, content: content)
    let publications = plane.contentPublicationCount, notifications = observer.count
    plane.update(presence: initial.replacingCamera(.init(scale: 1.2)), revision: 0,
      isCameraActive: true, content: content)
    XCTAssertEqual(plane.contentPublicationCount, publications)
    XCTAssertGreaterThan(observer.count, notifications)
    plane.uninstall()
  }

  func testPageCropTracksPhysicalScaleWithoutGrowingWholePageBacking() throws {
    let window = NSWindow(contentRect:.init(x:0,y:0,width:500,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    let root = NSView(frame:.init(x:0,y:0,width:500,height:400))
    window.contentView = root;window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil);window.contentView = nil }
    let host = NSView(frame:.init(x:0,y:0,width:500,height:400))
    let canvas = InkCanvasView(frame:.zero)
    root.addSubview(host);host.addSubview(canvas)
    let projection = PageInkProjection(host:host,canvas:canvas)
    defer { projection.stop() }
    for scale:CGFloat in [1,2,8] {
      host.bounds = CGRect(x:0,y:0,width:500/scale,height:400/scale)
      projection.refresh()
      XCTAssertEqual((canvas.layer as? CAMetalLayer)?.drawableSize, canvas.drawableSize,
        "The page clock owns the actual Metal pool, not MetalKit's deferred resize")
      XCTAssertEqual(canvas.drawableSize.width,500*window.backingScaleFactor,accuracy:1)
      XCTAssertEqual(canvas.drawableSize.width/canvas.bounds.width,scale*window.backingScaleFactor,accuracy:0.01)
      XCTAssertEqual(try XCTUnwrap(canvas.pageRenderRegion).width,500/scale,accuracy:0.01)
    }
  }
}

@MainActor
private final class ProjectionObserver: ScenePlaneProjectionObserver {
  var count = 0
  func scenePlaneDidProject() { count += 1 }
}
