import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class ScenePreparationTests: XCTestCase {
  @MainActor
  func testOffscreenPreparationUsesTheBudgetWithoutTakingTheHumanWindow() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let keyWindow = scene.keyWindow
    let resources = SceneRenderResources(byteLimit: 8 * 1024 * 1024, maximumBackgroundWebSurfaces: 1)
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 512, height: 512), source: "red triangle",
      html: "<svg width='512' height='512'><path fill='red' d='M 20 490 L 256 20 L 490 490 Z'/></svg>")
    let raster = try await resources.prepareRaster(element, requestedScale: 1)
    XCTAssertTrue(scene.keyWindow === keyWindow)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    let cg = try XCTUnwrap(raster.image.cgImage)
    XCTAssertEqual(cg.width, 512)
    XCTAssertEqual(cg.height, 512)
    let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
      bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: 512, height: 512))
    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let center = 256 * context.bytesPerRow + 256 * 4
    XCTAssertGreaterThan(pixels[center], 240)
    XCTAssertLessThan(pixels[center + 1], 10)
    XCTAssertGreaterThan(pixels[center + 3], 240, "Ready means actual pixels, not a transparent pending WebKit")
    raster.release()
  }

  @MainActor
  func testActiveInputCancelsGrantedPreparationAndLateCompletionCannotPublish() async throws {
    let resources = SceneRenderResources()
    var allowed = true
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 512, height: 512), source: "slow resource",
      html: "<div>content</div>", javaScript: "await new Promise(r => setTimeout(r, 1000));")
    let task = Task { try await resources.prepareRaster(element, requestedScale: 1, permitsPreparation: { allowed }) }
    let deadline = ContinuousClock.now + .seconds(3)
    while resources.activeWebSurfaceCount == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    allowed = false
    do { _ = try await task.value; XCTFail("Active input must interrupt background preparation") }
    catch is CancellationError { }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    let generation = resources.rasterGeneration
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertEqual(resources.rasterGeneration, generation)
  }
}
