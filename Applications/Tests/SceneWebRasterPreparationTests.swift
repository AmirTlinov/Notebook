import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class SceneWebRasterPreparationTests: XCTestCase {
  @MainActor
  func testTransparentSVGSnapshotContainsOnlyItsAuthoredCross() async throws {
    let resources = SceneRenderResources()
    let preparation = try await SceneWebRasterPreparation.create(resources: resources, permitsPreparation: { true })
    defer { preparation.close() }
    let element = AgentElement(id: "transparent-svg", kind: .web,
      frame: .init(x: 0, y: 0, width: 180, height: 160), source: "Transparent crossed lines",
      html: "<svg viewBox='0 0 180 160'><path d='M20 20L160 140M160 20L20 140' stroke='black'/></svg>")
    let raster = try await preparation.prepare(element, requestedScale: 2, permitsPreparation: { true })
    defer { raster.release() }
    let image = try XCTUnwrap(raster.image.cgImage)
    let picture = XCTAttachment(image: raster.image)
    picture.name = "Exact transparent SVG source raster before native placement"; picture.lifetime = .keepAlways
    add(picture)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var opaque = 0
    for index in 0..<(image.width * image.height) where bytes[index * 4 + 3] > 127 { opaque += 1 }
    if opaque >= image.width * image.height / 20,
      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .flatMap(\.windows).compactMap({ $0 as? NotebookPreparationWindow }).last,
      let web = window.rootViewController?.view.subviews.compactMap({ $0 as? WKWebView }).first {
      let dom = try await web.evaluateJavaScript("""
        JSON.stringify({body:document.body.getBoundingClientRect(),svg:document.querySelector('svg')?.getBoundingClientRect(),
          viewport:[innerWidth,innerHeight], background:getComputedStyle(document.body).backgroundColor,
          svgFill:getComputedStyle(document.querySelector('svg')).fill})
        """)
      let diagnostic = XCTAttachment(string: "window=\(window.frame) web=\(web.frame) safe=\(web.safeAreaInsets) scrollInset=\(web.scrollView.adjustedContentInset) edgeHidden=\(web.scrollView.topEdgeEffect.isHidden) DOM=\(dom)")
      diagnostic.name = "Transparent source native and DOM geometry"; diagnostic.lifetime = .keepAlways
      add(diagnostic)
    }
    XCTAssertGreaterThan(opaque, 200)
    XCTAssertLessThan(opaque, image.width * image.height / 20,
      "A one-point transparent cross cannot contain a filled rectangular strip")
  }

  @MainActor
  func testCameraCaptureChangesKeepTheSamePendingProgramAndReturnTheLatestCrop() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let preparation = try await SceneWebRasterPreparation.create(resources: resources, permitsPreparation: { true })
    defer { preparation.close() }
    let element = AgentElement(id: "moving-pending-source", kind: .web,
      frame: .init(x: 0, y: 0, width: 512, height: 512), source: "One readiness promise",
      html: "<div style='position:absolute;inset:0;background:red'></div><script>window.notebook.ready(new Promise(resolve => setTimeout(resolve,1800)))</script>")
    var policy = AgentSnapshotPolicy.region(.init(x: 0, y: 0, width: 128, height: 128), scale: 1)
    let job = Task { try await preparation.prepare(element, requestedScale: 1,
      currentPolicy: { policy }, permitsPreparation: { true }) }
    defer { job.cancel() }
    let start = ContinuousClock.now
    while preparation.loadToken == nil, ContinuousClock.now - start < .seconds(2) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let token = try XCTUnwrap(preparation.loadToken)
    let identity = preparation.webIdentity
    for index in 0..<12 {
      policy = .region(.init(x: Double(index * 8), y: Double(index * 4), width: 128, height: 128),
        scale: 1 + Double(index) / 16)
      try await Task.sleep(for: .milliseconds(80))
      XCTAssertEqual(preparation.loadToken, token, "Pinch and pan cannot restart a pending readiness promise")
      XCTAssertEqual(preparation.webIdentity, identity)
    }
    let raster = try await job.value
    defer { raster.release() }
    XCTAssertEqual(raster.source, policy.rasterSource(for: element))
    XCTAssertGreaterThanOrEqual(raster.pixelScale + 0.000_001, policy.minimumScale(for: element))
    XCTAssertEqual(preparation.loadToken, token)
    let pixel = try centerPixel(try XCTUnwrap(raster.image.cgImage))
    XCTAssertGreaterThan(pixel[0], 240); XCTAssertLessThan(pixel[2], 10)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testEightSequentialJobsUseOneExecutorAndFreshProgramGlobals() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024, maximumBackgroundWebSurfaces: 1)
    let keyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
    let preparation = try await SceneWebRasterPreparation.create(resources: resources, permitsPreparation: { true })
    defer { preparation.close() }
    let identity = preparation.webIdentity
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.windows.compactMap { $0 as? NotebookPreparationWindow }.last)
    XCTAssertFalse(window.canBecomeKey)
    XCTAssertFalse(window.isUserInteractionEnabled)
    XCTAssertTrue(window.accessibilityElementsHidden)
    for index in 0..<8 {
      let element = AgentElement(id: "sequential-\(index)", kind: .web,
        frame: .init(x: 0, y: 0, width: 2689.263, height: 3943.43), source: "Distinct program \(index)",
        html: "<div id='paint' style='position:absolute;inset:0'></div>", javaScript: """
        document.getElementById('paint').style.background = window.previousJob ? 'blue' : 'red';
        window.previousJob = true;
        """)
      let raster = try await preparation.prepare(element, requestedScale: 0.125, permitsPreparation: { true })
      XCTAssertEqual(preparation.webIdentity, identity)
      XCTAssertEqual(resources.activeWebSurfaceCount, 1)
      XCTAssertNil(resources.retainRaster(for: element, minimumScale: 2), "A coarse tile source cannot certify a full-resolution export")
      let image = try XCTUnwrap(raster.image.cgImage)
      XCTAssertGreaterThanOrEqual(Double(image.width), element.frame.width * 0.125)
      XCTAssertLessThan(image.width, 340)
      let pixel = try centerPixel(image)
      XCTAssertGreaterThan(pixel[0], 240, "A new program must not see globals from the prior raster job")
      XCTAssertLessThan(pixel[2], 10)
      raster.release()
      XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    }
    XCTAssertEqual(preparation.completedJobCount, 8)
    XCTAssertTrue(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow === keyWindow)
    preparation.close()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testCancelledJobClosesItsExecutorAndCannotPublishLatePixels() async throws {
    let resources = SceneRenderResources()
    let preparation = try await SceneWebRasterPreparation.create(resources: resources, permitsPreparation: { true })
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 64, height: 64), source: "delayed job",
      html: "<div style='width:64px;height:64px;background:red'></div>",
      javaScript: "await new Promise(resolve => setTimeout(resolve, 300));")
    let task = Task { try await preparation.prepare(element, requestedScale: 1, permitsPreparation: { true }) }
    await Task.yield()
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation cannot return a completed raster") }
    catch is CancellationError { }
    preparation.close()
    let generation = resources.rasterGeneration
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(resources.rasterGeneration, generation)
    XCTAssertNil(resources.image(for: element))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testExactFractionalDensityIsNotClampedToAWholePhysicalPoint() throws {
    let element = AgentElement(id: "fractional-density", kind: .web,
      frame: .init(x: 0, y: 0, width: 10_000, height: 8_000), source: "scale", html: "")
    let coarse = try XCTUnwrap(AgentSnapshotPolicy.exact(scale: 0.125).pixelSize(for: element))
    XCTAssertEqual(coarse, CGSize(width: 1250, height: 1000))
    XCTAssertEqual(AgentSnapshotPolicy.exact(scale: 2).pixelSize(for: element), CGSize(width: 20_000, height: 16_000))
    XCTAssertNil(AgentSnapshotPolicy.exact(scale: 0).pixelSize(for: element))
  }

  private func centerPixel(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: 4))
  }
}
