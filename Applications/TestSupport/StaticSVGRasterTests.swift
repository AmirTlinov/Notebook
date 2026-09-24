import CoreGraphics
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class StaticSVGRasterTests: XCTestCase {
  private func element(_ content: String? = nil) -> AgentElement {
    .init(id: "vector-source", kind: .web, frame: .init(x: 0, y: 0, width: 120, height: 80), source: "",
      html: content ?? """
      <svg xmlns='http://www.w3.org/2000/svg' width='100%' height='100%' viewBox='0 0 120 80'>
        <defs><path id='paint' d='M0 0H40V20H0Z'/>
          <clipPath id='clip'><circle cx='60' cy='40' r='9'/></clipPath>
          <linearGradient id='tone'><stop stop-color='red'/><stop offset='1' stop-color='lime'/></linearGradient></defs>
        <use href='#paint' transform='translate(10 10)' fill='red' opacity='.5'/>
        <rect x='50' y='30' width='20' height='20' fill='url(#tone)' clip-path='url(#clip)'/>
        <rect x='80' y='50' width='20' height='20' fill='blue'/>
      </svg>
      """)
  }

  func testNativeVectorsDoNotBorrowBrowserLayoutOrFontSemantics() {
    XCTAssertTrue(element().usesNativeSVGRaster)
    XCTAssertFalse(element().requiresLiveRuntime)
    let text = element("<svg width='100%' height='100%'><text y='30'>Original system font</text></svg>")
    XCTAssertFalse(text.usesNativeSVGRaster)
    XCTAssertFalse(text.requiresLiveRuntime)
    XCTAssertFalse(element("<svg viewBox='0 0 120 80'><path d='M0 0H20V20Z'/></svg>").usesNativeSVGRaster)
    XCTAssertTrue(element("<svg width='100%' height='100%' onclick='alert(1)'/>").requiresLiveRuntime)
  }

  func testVectorPaintAndCropRemainExactWithoutAnyWebExecutor() async throws {
    let resources = SceneRenderResources(maximumBackgroundWebSurfaces: 1)
    let held = try await resources.acquireWebSurface(priority: .background)
    defer { held.release() }
    let source = element(), start = ContinuousClock.now
    let full = try await resources.prepareRaster(source, requestedScale: 2)
    defer { full.release() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 1, "Only the deliberately occupied browser slot exists")
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(full.pixelScale, 2, accuracy: 0.0001)
    let rgba = try pixels(full)
    XCTAssertEqual(rgba.width, 240); XCTAssertEqual(rgba.height, 160)
    let opaque = stride(from: 3, to: rgba.bytes.count, by: 4).filter { rgba.bytes[$0] > 250 }.count
    let partial = stride(from: 3, to: rgba.bytes.count, by: 4).filter { (120...136).contains(rgba.bytes[$0]) }.count
    XCTAssertGreaterThan(opaque, 2_300); XCTAssertLessThan(opaque, 2_800)
    XCTAssertGreaterThan(partial, 3_000); XCTAssertLessThan(partial, 3_400)
    let crop = PageRect(x: 80, y: 50, width: 20, height: 20)
    let cropped = try await resources.prepareRaster(source, requestedScale: 3, region: crop)
    defer { cropped.release() }
    XCTAssertEqual(cropped.source, .agentRegion(source, crop))
    let pixel = try pixels(cropped)
    XCTAssertEqual(pixel.width, 60); XCTAssertEqual(pixel.height, 60)
    XCTAssertEqual(Array(pixel.bytes[((30 * 60 + 30) * 4)..<((30 * 60 + 30) * 4 + 4)]), [0, 0, 255, 255])
    let evidence = XCTAttachment(string: "native full + crop: \(start.duration(to: .now)); web requests=\(resources.pendingWebRequestCount)")
    evidence.name = "Native SVG source and crop"; evidence.lifetime = .keepAlways; add(evidence)
  }

  func testNativeVectorPixelsMatchThePreviousBrowserProjection() async throws {
    #if os(iOS)
    try await WorkspaceInkFixture.waitForForegroundWindow()
    #endif
    let source = element(), resources = SceneRenderResources()
    let start = ContinuousClock.now
    let native = try await resources.prepareRaster(source, requestedScale: 2)
    defer { native.release() }
    let nativeTime = start.duration(to: .now)
    let browserResources = SceneRenderResources()
    let web = try await SceneWebRasterPreparation.create(resources: browserResources, permitsPreparation: { true })
    defer { web.close() }
    let browserStart = ContinuousClock.now
    let browser = try await web.prepare(source, requestedScale: 2, permitsPreparation: { true })
    defer { browser.release() }
    let a = try pixels(native), b = try pixels(browser)
    XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
    guard a.bytes.count == b.bytes.count else { return XCTFail("Different native and browser extents") }
    let difference = zip(a.bytes, b.bytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    XCTAssertLessThan(Double(difference) / Double(a.bytes.count * 255), 0.015,
      "Paint, alpha, gradient, referenced paths and clipping must survive the renderer change")
    let evidence = XCTAttachment(string: "native=\(nativeTime); browser=\(browserStart.duration(to: .now)); mean RGBA difference=\(Double(difference) / Double(a.bytes.count * 255))")
    evidence.name = "Native versus browser SVG pixels"; evidence.lifetime = .keepAlways; add(evidence)
  }

  private func pixels(_ raster: RasterLease) throws -> (width: Int, height: Int, bytes: [UInt8]) {
    #if os(iOS)
    let cg = try XCTUnwrap(raster.image.cgImage)
    #else
    let cg = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #endif
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    return (cg.width, cg.height, Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: cg.width * cg.height * 4)))
  }
}
