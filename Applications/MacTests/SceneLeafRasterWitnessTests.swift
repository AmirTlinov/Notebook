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
    let collector = SceneLeafRasterWitnessCollector(resources: resources)
    defer { collector.close() }
    collector.record(used)
    raster.release()

    let materialKey = try SceneMaterialKey(workspaceID: UUID(), target: .init(kind: .board, id: UUID()),
      revision: "fixed", role: "leaf-witness", frame: .init(x: 0, y: 0, width: 16, height: 16), density: 1)
    let tileKey = SceneCompositionTileKey(workspaceID: UUID(), revision: 0, plane: .board(UUID()),
      tile: try XCTUnwrap(CompositionTile(containing: .zero, level: 0)), range: .whole(.elements),
      presentationScale: 1, viewportWidth: 16, viewportHeight: 16, focusedItemID: nil, mode: "board")
    // Enough own publications to overflow the collector if material or tile
    // installation incorrectly entered the leaf event channel.
    for _ in 0...SceneLeafRasterWitnessCollector.maximumPendingPublications {
      XCTAssertTrue(resources.store(image(), for: .material(materialKey)))
      XCTAssertTrue(resources.store(image(), for: .composition(tileKey)))
    }
    XCTAssertTrue(resources.store(image(), for: .agent(element("unrelated"))))
    XCTAssertTrue(collector.isCurrent)

    // The proof owns no pixels. Reclamation alone keeps a delivered frame valid.
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    XCTAssertEqual(resources.rasterCount, 0)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertTrue(collector.isCurrent)
    XCTAssertTrue(resources.leafRastersAreCurrent(used))
    pressure.release()

    XCTAssertTrue(resources.store(image(color: .systemRed), for: source))
    XCTAssertFalse(collector.isCurrent)
    XCTAssertFalse(resources.leafRastersAreCurrent(used))
  }

  @MainActor
  func testPublicationBeforeBorrowRemainsVisibleAfterEvictionAndJournalOverflowRejects() throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024, profile: .headless)
    let source = SceneRasterSource.document(id: UUID(), token: "same-source")
    XCTAssertTrue(resources.store(image(), for: source))
    let old = try XCTUnwrap(resources.retainRaster(for: source))
    let oldPixels = old.leafRasters
    old.release()
    let collector = SceneLeafRasterWitnessCollector(resources: resources)
    defer { collector.close() }
    XCTAssertTrue(resources.store(image(color: .systemRed), for: source))
    let current = try XCTUnwrap(resources.retainRaster(for: source))
    collector.record(current.leafRasters)
    XCTAssertTrue(collector.isCurrent, "A publication preceding its actual borrow is the current frame")
    current.release()
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    pressure.release()
    XCTAssertTrue(resources.leafRastersAreCurrent(oldPixels), "The pool intentionally retains no eviction history")
    collector.record(oldPixels)
    XCTAssertFalse(collector.isCurrent, "An awaited cache borrow cannot lose a publication that was already evicted")

    let bounded = SceneLeafRasterWitnessCollector(resources: resources)
    defer { bounded.close() }
    for _ in 0..<SceneLeafRasterWitnessCollector.maximumPendingPublications {
      XCTAssertTrue(resources.store(image(), for: source))
    }
    XCTAssertTrue(bounded.isCurrent)
    XCTAssertTrue(resources.store(image(), for: source))
    XCTAssertFalse(bounded.isCurrent, "Incomplete pre-borrow evidence must reject the checkpoint")
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
    let collector = SceneLeafRasterWitnessCollector(resources: resources)
    defer { collector.close() }
    collector.record(witnesses)
    XCTAssertTrue(resources.store(image(), for: .agent(current)))
    XCTAssertTrue(resources.store(image(size: 8, scale: 2), for: .agentRegion(current,
      .init(x: 8, y: 8, width: 8, height: 8))))
    XCTAssertTrue(resources.store(image(size: 8), for: demand))
    XCTAssertTrue(collector.isCurrent)
    XCTAssertTrue(resources.store(image(size: 8, scale: 2), for: demand))
    XCTAssertFalse(collector.isCurrent)
    XCTAssertFalse(resources.leafRastersAreCurrent(witnesses))

    // The exact capture is already resident before a later fallback borrow.
    // Its publication therefore precedes this missing proof's event boundary.
    let lateFallback = try XCTUnwrap(resources.retainRaster(for: .agent(old)))
    let lateProof = resources.leafRasterWitnesses(for: demand, minimumScale: 2, using: lateFallback)
    lateFallback.release()
    XCTAssertFalse(resources.leafRastersAreCurrent(lateProof))
    let lateCollector = SceneLeafRasterWitnessCollector(resources: resources)
    defer { lateCollector.close() }
    lateCollector.record(lateProof)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    pressure.release()
    XCTAssertEqual(resources.rasterCount, 0)
    XCTAssertTrue(resources.leafRastersAreCurrent(lateProof))
    XCTAssertFalse(lateCollector.isCurrent, "Availability at borrow remains latched after subsequent eviction")
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
