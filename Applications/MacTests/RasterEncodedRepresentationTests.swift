import AppKit
import CryptoKit
import ImageIO
import NotebookCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Notebook

final class RasterEncodedRepresentationTests: XCTestCase {
  @MainActor
  func testImmutableEntryMemoizesPNGAndSHAWithColdWarmMeasurements() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    let raster = try await fixture(size: 1024, resources: resources)
    defer { raster.release() }
    let image = try XCTUnwrap(raster.sampledImage(for: .init(width: Double.greatestFiniteMagnitude, height: Double.greatestFiniteMagnitude)))
    let clock = ContinuousClock()
    var directMS: [Double] = [], direct = Data()
    for _ in 0..<3 {
      let start = clock.now
      direct = try await NotebookPNGEncodingFixture.encode(image)
      directMS.append(milliseconds(start.duration(to: clock.now)))
    }
    var boundedMS: [Double] = []
    for _ in 0..<3 {
      let charge = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive))
      let start = clock.now
      var bounded: RasterEncodedBytes? = try await CompositionPixels.encodePNG(image, maximumBytes: 9 * 1024 * 1024) {
        resources.resizePassiveDerivedReservation(charge, to: $0)
      }
      boundedMS.append(milliseconds(start.duration(to: clock.now)))
      XCTAssertEqual(bounded?.png, direct)
      bounded = nil
      charge.release()
    }
    let start = clock.now
    let first = try await raster.encodedPNG()
    let coldMS = milliseconds(start.duration(to: clock.now))
    var warmMS: [Double] = []
    for _ in 0..<3 {
      let start = clock.now
      let repeated = try await raster.encodedPNG()
      warmMS.append(milliseconds(start.duration(to: clock.now)))
      XCTAssertTrue(first.value === repeated.value, "Unknown client assets reuse the exact immutable entry's PNG and SHA")
    }
    XCTAssertEqual(first.value.png, direct)
    XCTAssertEqual(first.value.sha256, SHA256.hash(data: direct).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(first.value.entryID, raster.entryID)
    let known = try await NotebookPanelRasterLayer.completed(id: "known", order: 0, worldOrigin: .zero,
      frame: .init(x: 0, y: 0, width: 1024, height: 1024), raster: raster, knownAssets: [raster.entryID])
    XCTAssertNil(known.png)
    let replacement = try await fixture(size: 1024, resources: resources, source: raster.source, tint: .orange)
    defer { replacement.release() }
    let next = try await replacement.encodedPNG()
    XCTAssertNotEqual(next.value.entryID, first.value.entryID)
    XCTAssertNotEqual(next.value.sha256, first.value.sha256)
    let old = try await raster.encodedPNG()
    XCTAssertTrue(old.value === first.value, "A newer publication cannot replace an older lease's pixels")
    let measurement: [String: Any] = ["fixture": "native_grid_and_card_1024", "directEncodeMS": directMS, "boundedPNGAndSHAMS": boundedMS,
      "coldPNGAndSHAMS": coldMS, "warmBorrowMS": warmMS, "pngBytes": first.value.png.count,
      "encodedAllocationBytes": first.value.accountedByteCount, "peakAccountedBytes": resources.peakAccountedBytes]
    let data = try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "Immutable PNG cold and warm encoding"; attachment.lifetime = .keepAlways; add(attachment)
    print("PNG_ENCODING_MEASUREMENTS \(String(decoding: data, as: UTF8.self))")
  }

  @MainActor
  func testLayerBorrowTransfersChargeThroughEvictionAndWithOrder() async throws {
    let resources = SceneRenderResources(byteLimit: 8 * 1024 * 1024, profile: .headless)
    let raster = try await fixture(size: 256, resources: resources)
    let pixels = raster.accountedByteCount
    var layer: NotebookPanelRasterLayer? = try await NotebookPanelRasterLayer.completed(id: "one", order: 0,
      worldOrigin: .zero, frame: .init(x: 0, y: 0, width: 256, height: 256), raster: raster, knownAssets: [])
    var reordered = layer?.withOrder(7)
    let pngCost = resources.residentBytes - pixels
    XCTAssertGreaterThan(pngCost, 0)
    raster.release()
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0, "PNG delivery must not pin unused source pixels")
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - pngCost, priority: .passive))
    XCTAssertEqual(resources.rasterCount, 0)
    XCTAssertEqual(resources.residentBytes, 0)
    XCTAssertEqual(resources.reservedBytes, resources.byteLimit, "Eviction transfers the exact PNG charge while the response lives")
    layer = nil
    XCTAssertEqual(try reordered?.encoded["order"], .number(7))
    XCTAssertNotNil(try reordered?.encoded["pngBase64"]?.stringValue)
    XCTAssertEqual(resources.reservedBytes, resources.byteLimit)
    pressure.release()
    XCTAssertEqual(resources.reservedBytes, pngCost)
    reordered = nil
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)

    var temporaryPool: SceneRenderResources? = SceneRenderResources(byteLimit: 8 * 1024 * 1024, profile: .headless)
    weak let borrowedPool = temporaryPool
    let temporaryRaster = try await fixture(size: 256, resources: XCTUnwrap(temporaryPool))
    var escaped: NotebookPanelRasterLayer? = try await NotebookPanelRasterLayer.completed(id: "escaped", order: 0,
      worldOrigin: .zero, frame: .init(x: 0, y: 0, width: 256, height: 256), raster: temporaryRaster, knownAssets: [])
    temporaryRaster.release(); temporaryPool = nil
    XCTAssertNotNil(borrowedPool, "An escaped response keeps its accounting owner alive")
    XCTAssertNotNil(try escaped?.encoded["pngBase64"]?.stringValue)
    escaped = nil
    XCTAssertNil(borrowedPool, "An entry's cached representation must not create a pool cycle")
  }

  @MainActor
  func testCompetingBorrowersCoalesceAndCancellationPreservesTheirPeer() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    let raster = try await fixture(size: 2048, resources: resources)
    defer { raster.release() }
    let cancelled = Task { @MainActor in try await raster.encodedPNG() }
    let peer = Task { @MainActor in try await raster.encodedPNG() }
    try await waitForEncoding(resources)
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("A cancelled request must not receive encoded pixels") }
    catch is CancellationError {}
    let value = try await peer.value
    let repeated = try await raster.encodedPNG()
    XCTAssertTrue(value.value === repeated.value)
    XCTAssertEqual(value.value.entryID, raster.entryID)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testLastCancelledBorrowerReturnsItsChargeAfterEncoderCompletion() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    let raster = try await fixture(size: 2048, resources: resources)
    let pixels = raster.accountedByteCount
    let request = Task { @MainActor in try await raster.encodedPNG() }
    try await waitForEncoding(resources)
    request.cancel()
    do { _ = try await request.value; XCTFail("Cancelled encoding must not publish") }
    catch is CancellationError {}
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.residentBytes, pixels)
    raster.release()
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    XCTAssertEqual(resources.rasterCount, 0)
    pressure.release()
  }

  @MainActor
  func testImmediateReborrowRetiresTheLastCancelledFlightBeforeEncodingAgain() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    let raster = try await fixture(size: 2048, resources: resources)
    defer { raster.release() }
    let abandoned = Task { @MainActor in try await raster.encodedPNG() }
    try await waitForEncoding(resources)
    abandoned.cancel()
    // Enter synchronously before the queued cancellation bookkeeping. A new
    // reader must not join the old flight once its output callback can refuse.
    let fresh = try await raster.encodedPNG()
    do { _ = try await abandoned.value; XCTFail("The old caller remains cancelled") }
    catch is CancellationError {}
    XCTAssertEqual(fresh.value.entryID, raster.entryID)
    XCTAssertFalse(fresh.value.png.isEmpty)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testNearPixelLimitCompressibleCohortStillDeliversAll2048Layers() async throws {
    let resources = SceneRenderResources(profile: .headless)
    var cohort = NotebookPanelRasterSet()
    for index in 0..<8 {
      let raster = try await fixture(size: 2048, resources: resources)
      let layer = try await NotebookPanelRasterLayer.completed(id: "layer-\(index)", order: index,
        worldOrigin: .zero, frame: .init(x: 0, y: 0, width: 2048, height: 2048), raster: raster, knownAssets: [])
      raster.release()
      try cohort.append(layer)
    }
    XCTAssertEqual(cohort.layers.reduce(0) { $0 + $1.pixelWidth * $1.pixelHeight }, NotebookPanelRenderProjection.maximumDecodedPixels)
    XCTAssertEqual(cohort.layers.map(\.order), Array(0..<8))
    XCTAssertLessThan(resources.rasterCount, 8, "Old image backing must be evictable while accepted PNG layers remain charged")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    for layer in cohort.layers {
      let png = try XCTUnwrap(layer.png)
      let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
      let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
      XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 2048)
      XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 2048)
      XCTAssertNotNil(try layer.encoded["sha256"]?.stringValue)
    }
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testOutputAdmissionRefusalLeaksNothingAndRetryPreservesPixels() async throws {
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024, profile: .headless)
    let raster = try await fixture(size: 1024, resources: resources)
    defer { raster.release() }
    let pixels = raster.accountedByteCount
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - pixels - 4096, priority: .passive))
    do { _ = try await raster.encodedPNG(); XCTFail("No output allocation may start without admission") }
    catch SceneRenderError.resourceLimit {}
    XCTAssertEqual(resources.reservedBytes, pressure.byteCount)
    XCTAssertEqual(resources.residentBytes, pixels)
    pressure.release()
    let delivered = try await raster.encodedPNG()
    XCTAssertEqual(delivered.value.entryID, raster.entryID)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  private func waitForEncoding(_ resources: SceneRenderResources) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while resources.reservedBytes == 0 {
      guard ContinuousClock.now < deadline else { throw SceneRenderError.snapshotPending("test_encoding_start") }
      await Task.yield()
    }
  }

  @MainActor
  private func fixture(size: Int, resources: SceneRenderResources, source: SceneRasterSource? = nil,
    tint: Color = .blue) async throws -> RasterLease {
    let extent = CGSize(width: size, height: size)
    let canvas = try await SceneRasterCompositor.create(size: extent, scale: 1, resources: resources)
    try await canvas.drawBoardGrid(camera: .init(center: .zero, scale: 1), size: extent, in: .init(origin: .zero, size: extent))
    try await canvas.drawView(VStack(spacing: 12) {
      Text("Immutable Notebook pixels").font(.system(size: 36)).foregroundStyle(.black)
      RoundedRectangle(cornerRadius: 18).fill(tint.gradient)
      Text("Source, order and density stay unchanged").font(.system(size: 20)).foregroundStyle(.black)
    }.padding(24).background(Color.white), size: .init(width: 420, height: 240),
      in: .init(x: 32, y: 32, width: 420, height: 240))
    return try await canvas.finishRaster(for: source ?? .document(id: UUID(), token: "immutable_png_fixture"))
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
}

/// Direct ImageIO reference for isolated raster and cold-encoding comparisons.
enum NotebookPNGEncodingFixture {
  static func encode(_ image: CGImage) async throws -> Data {
    try Task.checkCancellation()
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw SceneRenderError.snapshotPending("png_encoding") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw SceneRenderError.snapshotPending("png_encoding") }
    return data as Data
  }
}
