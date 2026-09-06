import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class SceneRasterCompositionTests: XCTestCase {
  @MainActor
  func testManyUniqueSourcesExceedTheBudgetInTotalButNotWhileComposing() async throws {
    let resources = SceneRenderResources(byteLimit: 6 * 1024 * 1024, maximumRasterCount: 4)
    let size = CGSize(width: 256, height: 256)
    let compositor = try await SceneRasterCompositor.create(size: size, scale: 2, resources: resources)
    let heldSource = element("human", size: size)
    XCTAssertTrue(resources.store(bitmap(size: size, color: .green), for: heldSource))
    let human = try XCTUnwrap(resources.retainRaster(for: heldSource))
    defer { human.release() }
    // 200 MiB of distinct decoded source cannot fit the 6 MiB owner. Its input
    // surface and one output remain held while old passive sources are evicted.
    for index in 0..<100 {
      let source = element("source-\(index)", size: size)
      XCTAssertTrue(resources.store(bitmap(size: size, color: index == 99 ? .red : .blue), for: source))
      let raster = try XCTUnwrap(resources.retainRaster(for: source, minimumScale: 2))
      try await compositor.draw(raster, in: CGRect(origin: .zero, size: size))
      raster.release()
      XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
      XCTAssertNotNil(human.image(for: .agent(heldSource)), "Preparation must not revoke the input surface")
    }
    let result = try pixels(try await compositor.finishPNG())
    XCTAssertGreaterThan(result.colorAt(x: 256, y: 256)!.redComponent, 0.9)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testPainterOrderAlphaClippingAndTopLeftCoordinates() async throws {
    let resources = SceneRenderResources(byteLimit: 4 * 1024 * 1024)
    let size = CGSize(width: 100, height: 100)
    let compositor = try await SceneRasterCompositor.create(size: size, scale: 2, resources: resources)
    for (id, color, frame) in [
      ("base", NSColor.white, CGRect(x: 0, y: 0, width: 100, height: 100)),
      ("red", NSColor.red.withAlphaComponent(0.5), CGRect(x: -20, y: 10, width: 80, height: 40)),
      ("blue", NSColor.blue.withAlphaComponent(0.5), CGRect(x: 20, y: 20, width: 30, height: 60))
    ] {
      let source = element(id, size: size)
      XCTAssertTrue(resources.store(bitmap(size: size, color: color), for: source))
      let raster = try XCTUnwrap(resources.retainRaster(for: source))
      try await compositor.draw(raster, in: frame)
      raster.release()
    }
    let result = try pixels(try await compositor.finishPNG())
    let white = try XCTUnwrap(result.colorAt(x: 180, y: 180))
    XCTAssertGreaterThan(white.greenComponent, 0.99)
    let red = try XCTUnwrap(result.colorAt(x: 10, y: 30))
    XCTAssertEqual(red.redComponent, 1, accuracy: 0.02)
    XCTAssertEqual(red.greenComponent, 0.5, accuracy: 0.02)
    let overlap = try XCTUnwrap(result.colorAt(x: 60, y: 60))
    XCTAssertEqual(overlap.redComponent, 0.5, accuracy: 0.02)
    XCTAssertEqual(overlap.greenComponent, 0.25, accuracy: 0.02)
    XCTAssertEqual(overlap.blueComponent, 0.75, accuracy: 0.02)
    let bottom = try XCTUnwrap(result.colorAt(x: 10, y: 150))
    XCTAssertGreaterThan(bottom.greenComponent, 0.99, "A top-left source must not reappear at the bottom")
  }

  @MainActor
  func testActualWebSourcesReleaseEachExecutorBeforeTheNextSource() async throws {
    let resources = SceneRenderResources(byteLimit: 5 * 1024 * 1024, maximumBackgroundWebSurfaces: 1)
    let size = CGSize(width: 256, height: 256)
    let compositor = try await SceneRasterCompositor.create(size: size, scale: 2, resources: resources)
    for index in 0..<8 {
      let source = AgentElement(id: UUID().uuidString, kind: .web,
        frame: .init(x: 0, y: 0, width: 256, height: 256), source: "unique \(index)",
        html: "<svg width='256' height='256'><rect width='256' height='256' fill='rgb(\(index * 30),0,0)'/></svg>")
      let raster = try await resources.prepareRaster(source, requestedScale: 2)
      XCTAssertEqual(resources.activeWebSurfaceCount, 0)
      try await compositor.draw(raster, in: CGRect(origin: .zero, size: size))
      raster.release()
      XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    }
    let result = try pixels(try await compositor.finishPNG())
    XCTAssertEqual(result.colorAt(x: 256, y: 256)!.redComponent, 210.0 / 255, accuracy: 0.025)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testInputInterruptionCannotPublishPartialComposition() async throws {
    let resources = SceneRenderResources(byteLimit: 1024 * 1024)
    let permit = PreparationPermit()
    var compositor: SceneRasterCompositor? = try await .create(size: .init(width: 128, height: 128),
      scale: 2, resources: resources, permitsPreparation: { permit.allowed })
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    permit.allowed = false
    do { _ = try await compositor!.finishPNG(); XCTFail("A partial or interrupted output is not ready") }
    catch is CancellationError { }
    compositor = nil
    XCTAssertEqual(resources.reservedBytes, 0)
    do {
      _ = try await SceneRasterCompositor.create(size: .init(width: 8192, height: 8192), scale: 2, resources: resources)
      XCTFail("Oversized allocation must be rejected before allocating")
    } catch SceneRenderError.resourceLimit { }
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor private final class PreparationPermit { var allowed = true }

  private func element(_ id: String, size: CGSize) -> AgentElement {
    .init(id: id, kind: .web, frame: .init(x: 0, y: 0, width: size.width, height: size.height), source: id, html: "")
  }

  private func bitmap(size: CGSize, color: NSColor) -> NSImage {
    let width = Int(size.width * 2), height = Int(size.height * 2)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.usingColorSpace(.deviceRGB)!.cgColor)
    context.fill(.init(x: 0, y: 0, width: width, height: height))
    return NSImage(cgImage: context.makeImage()!, size: size)
  }

  private func pixels(_ png: Data) throws -> NSBitmapImageRep { try XCTUnwrap(NSBitmapImageRep(data: png)) }
}
