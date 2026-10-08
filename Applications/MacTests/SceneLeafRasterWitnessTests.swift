import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class SceneLeafRasterWitnessTests: XCTestCase {
  @MainActor
  func testOnlyNewPixelsOfTheUsedLeafInvalidateAfterCompositionAndEviction() throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024, profile: .headless)
    let source = SceneRasterSource.agent(element("used"))
    XCTAssertTrue(resources.store(image(), for: source))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    let used = raster.leafRasters
    raster.release()

    let materialKey = try SceneMaterialKey(workspaceID: UUID(), target: .init(kind: .board, id: UUID()),
      revision: "fixed", role: "leaf-witness", frame: .init(x: 0, y: 0, width: 16, height: 16), density: 1)
    let tileKey = SceneCompositionTileKey(workspaceID: UUID(), revision: 0, plane: .board(UUID()),
      tile: try XCTUnwrap(CompositionTile(containing: .zero, level: 0)), range: .whole(.elements),
      presentationScale: 1, viewportWidth: 16, viewportHeight: 16, focusedItemID: nil, mode: "board")
    XCTAssertTrue(resources.store(image(), for: .material(materialKey)))
    XCTAssertTrue(resources.store(image(), for: .composition(tileKey)))
    XCTAssertTrue(resources.store(image(), for: .agent(element("unrelated"))))
    XCTAssertTrue(resources.leafRastersAreCurrent(used))

    // The proof owns no pixels. Reclamation alone keeps a delivered frame valid.
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    XCTAssertEqual(resources.rasterCount, 0)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertTrue(resources.leafRastersAreCurrent(used))
    pressure.release()

    XCTAssertTrue(resources.store(image(color: .systemRed), for: source))
    XCTAssertFalse(resources.leafRastersAreCurrent(used))
  }

  @MainActor
  func testFallbackWaitsForTheExactSourceCropAndRequiredDensity() throws {
    let resources = SceneRenderResources(byteLimit: 128 * 1024, profile: .headless)
    let old = element("program")
    let current = AgentElement(id: old.id, kind: old.kind, frame: old.frame, source: old.source,
      html: "<svg viewBox='0 0 16 16'><rect width='16' height='16'/></svg>")
    let region = PageRect(x: 0, y: 0, width: 8, height: 8)
    let demand = SceneRasterSource.agentRegion(current, region)
    XCTAssertTrue(resources.store(image(), for: .agent(old)))
    let fallback = try XCTUnwrap(resources.retainRaster(for: .agent(old)))
    let witnesses = resources.leafRasterWitnesses(for: demand, minimumScale: 2, using: fallback)
    fallback.release()
    XCTAssertEqual(witnesses.count, 2)
    XCTAssertTrue(resources.store(image(), for: .agent(current)))
    XCTAssertTrue(resources.store(image(size: 8, scale: 2), for: .agentRegion(current,
      .init(x: 8, y: 8, width: 8, height: 8))))
    XCTAssertTrue(resources.store(image(size: 8), for: demand))
    XCTAssertTrue(resources.leafRastersAreCurrent(witnesses))
    XCTAssertTrue(resources.store(image(size: 8, scale: 2), for: demand))
    XCTAssertFalse(resources.leafRastersAreCurrent(witnesses))

    // The exact capture is already resident before a later fallback borrow.
    // Its publication therefore precedes this missing proof's event boundary.
    let lateFallback = try XCTUnwrap(resources.retainRaster(for: .agent(old)))
    let lateProof = resources.leafRasterWitnesses(for: demand, minimumScale: 2, using: lateFallback)
    lateFallback.release()
    XCTAssertFalse(resources.leafRastersAreCurrent(lateProof))
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    pressure.release()
    XCTAssertEqual(resources.rasterCount, 0)
    XCTAssertTrue(resources.leafRastersAreCurrent(lateProof))
  }

  private func element(_ id: String) -> AgentElement {
    .init(id: id, kind: .web, frame: .init(x: 0, y: 0, width: 16, height: 16),
      source: "Leaf fixture", html: "<svg viewBox='0 0 16 16'/>")
  }

  @MainActor
  private func image(size: Int = 16, scale: Int = 1, color: NSColor = .systemBlue) -> NSImage {
    let pixels = size * scale
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return NSImage(cgImage: context.makeImage()!, size: .init(width: size, height: size))
  }
}
