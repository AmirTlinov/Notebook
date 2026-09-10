import Metal
import NotebookCore
import PencilKit
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SpatialInkTilePoolTests: XCTestCase {
  func testNearFullRotationReusesPoolsAndKeepsRetinaPixelsAcrossTenPresentations() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.canvas, resources = fixture.resources
    let pools = canvas.spatialTilePoolIDs, bytes = resources.reservedBytes
    XCTAssertEqual(pools.count, 6)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - bytes - 4096, priority: .input))
    defer { pressure.release() }
    let held = resources.reservedBytes
    XCTAssertGreaterThan(canvas.spatialDrawableAccountedBytes, resources.byteLimit - held,
      "A second complete target cannot fit; this is the near-full replacement boundary")
    for index in 0..<10 {
      let size = index.isMultiple(of: 2) ? SpatialPoint(x: 768, y: 512) : .init(x: 512, y: 768)
      let before = try pixels(canvas), bounds = canvas.bounds
      let frame = try await canvas.prepareSpatialFrame(nil, size: size, displayScale: 2)
      XCTAssertEqual(canvas.bounds, bounds)
      XCTAssertEqual(try pixels(canvas), before, "Private GPU work has not presented or moved any tile")
      XCTAssertEqual(resources.reservedBytes, held, "A transpose reuses every existing physical pool")
      canvas.installSpatialFrame(frame, journal: fixture.journal, surface: fixture.surface)
      canvas.frame.origin = .zero
      await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
      XCTAssertEqual(canvas.spatialTilePoolIDs, pools)
      XCTAssertEqual(canvas.drawableSize, CGSize(width: size.x * 2, height: size.y * 2))
      XCTAssertTrue(canvas.isStableFramePresented)
      XCTAssertEqual(resources.reservedBytes, held)
      XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), try fixture.reference)
      XCTAssertGreaterThan(try blackPixels(canvas), 300, "Retained UUIDs must also have real displayed pixels")
      try assertContinuousCenterLine(canvas)
    }
    let attachment = XCTAttachment(image: capture(canvas)); attachment.name = "near-full-retina-tile-rotation"
    attachment.lifetime = .keepAlways; add(attachment)
    let bounds = canvas.bounds, before = try pixels(canvas)
    do {
      _ = try await canvas.prepareSpatialFrame(nil, size: .init(x: 768, y: 768), displayScale: 2)
      XCTFail("Real growth cannot allocate past the shared byte ceiling")
    } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    XCTAssertEqual(canvas.bounds, bounds); XCTAssertEqual(try pixels(canvas), before)
    XCTAssertEqual(canvas.spatialTilePoolIDs, pools); XCTAssertEqual(resources.reservedBytes, held)
  }

  func testGrowthCancellationAndRetainedPresentationReceiptsDoNotKeepRetiredPools() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.canvas, resources = fixture.resources
    let before = resources.reservedBytes, oldIDs = canvas.spatialTilePoolIDs
    var cancelled: InkCanvasView.PreparedSpatialFrame? = try await canvas.prepareSpatialFrame(nil,
      size: .init(x: 768, y: 768), displayScale: 2)
    XCTAssertTrue(try XCTUnwrap(cancelled).isValid)
    XCTAssertGreaterThan(resources.reservedBytes, before)
    cancelled = nil
    XCTAssertEqual(resources.reservedBytes, before)
    XCTAssertEqual(canvas.spatialTilePoolIDs, oldIDs)
    let grown = try await canvas.prepareSpatialFrame(nil, size: .init(x: 768, y: 768), displayScale: 2)
    canvas.installSpatialFrame(grown, journal: fixture.journal, surface: fixture.surface)
    await withCheckedContinuation { continuation in grown.afterPresentationTransaction { continuation.resume() } }
    XCTAssertEqual(canvas.spatialTilePoolIDs.count, 9)
    let shrunk = try await canvas.prepareSpatialFrame(nil, size: .init(x: 512, y: 768), displayScale: 2)
    canvas.installSpatialFrame(shrunk, journal: fixture.journal, surface: fixture.surface)
    await withCheckedContinuation { continuation in shrunk.afterPresentationTransaction { continuation.resume() } }
    XCTAssertEqual(canvas.spatialTilePoolIDs, oldIDs)
    XCTAssertEqual(resources.reservedBytes, before,
      "Keeping both presentation receipts does not retain their drawable slots or discarded pools")
    withExtendedLifetime((grown, shrunk)) {}
  }

  func testInvalidOrUnrepresentableBackingRefusesBeforeLayoutEvenForEmptyContent() async throws {
    let resources = SceneRenderResources(), canvas = InkCanvasView(frame: .init(x: 0, y: 0, width: 128, height: 128), resources: resources)
    let bounds = canvas.bounds
    for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1] {
      do {
        _ = try await canvas.prepareSpatialFrame(.init(batches: []), size: .init(x: 128, y: 128), displayScale: value)
        XCTFail("An invalid extent cannot install an empty successful target")
      } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
      XCTAssertEqual(canvas.bounds, bounds); XCTAssertEqual(resources.reservedBytes, 0)
    }
    do {
      _ = try await canvas.prepareSpatialFrame(.init(batches: []), size: .init(x: .greatestFiniteMagnitude, y: 128), displayScale: 2)
      XCTFail("Finite logical coordinates still cannot overflow the pixel extent")
    } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    await canvas.finishSpatialHandoffFrames()
  }

  func testWideBackingKeepsExactDensityBeyondTheFormer4096PixelClamp() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let frame = try await fixture.canvas.prepareSpatialFrame(nil, size: .init(x: 2200, y: 128), displayScale: 2)
    fixture.canvas.installSpatialFrame(frame, journal: fixture.journal, surface: fixture.surface)
    await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
    XCTAssertEqual(fixture.canvas.drawableSize, CGSize(width: 4400, height: 256))
    XCTAssertEqual(fixture.canvas.spatialTilePoolIDs.count, 9)
    XCTAssertEqual(try fixture.canvas.installedSpatialSource?.referenceInk(), try fixture.reference)
  }

  private func assertContinuousCenterLine(_ canvas: UIView) throws {
    let image = try XCTUnwrap(capture(canvas).cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    for x in (image.width / 2 - 200)...(image.width / 2 + 200) {
      let offset = ((image.height / 2) * image.width + x) * 4
      XCTAssertLessThan(max(bytes[offset], bytes[offset + 1], bytes[offset + 2]), 64,
        "A tile seam cannot cut the opaque center of one native stroke at x=\(x)")
    }
  }

  private func capture(_ canvas: UIView) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(canvas.bounds)
      canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true)
    }
  }
  private func pixels(_ canvas: UIView) throws -> Data {
    let image = try XCTUnwrap(capture(canvas).cgImage)
    return try XCTUnwrap(image.dataProvider?.data) as Data
  }
  private func blackPixels(_ canvas: UIView) throws -> Int {
    let image = try XCTUnwrap(capture(canvas).cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return stride(from: 0, to: image.width * image.height * 4, by: 4).filter {
      bytes[$0] < 160 && bytes[$0 + 1] < 160 && bytes[$0 + 2] < 160
    }.count
  }

  @MainActor
  private final class Fixture {
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let surface = SurfaceID.board(UUID()), actor = UUID()
    let journal: SpatialInkJournal
    let window: UIWindow, host = Host(), canvas: InkCanvasView
    private var retention: SpatialInkCanvasRetention?
    private weak var oldKeyWindow: UIWindow?
    var reference: NotebookReferenceInk { get throws { try .init(surface: surface, actions: journal.actions) } }

    static func make() async throws -> Fixture {
      let fixture = try Fixture()
      fixture.window.rootViewController = fixture.host
      fixture.host.view.addSubview(fixture.canvas); fixture.window.makeKeyAndVisible()
      let deadline = ContinuousClock.now + .seconds(5)
      while !fixture.host.appeared, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
      XCTAssertTrue(fixture.host.appeared)
      fixture.retention = fixture.canvas.retainForSpatialHandoff(displayScale: 2)
      fixture.canvas.project(camera: .init(scale: 1), viewport: .init(x: 512, y: 768))
      let mesh = try SpatialInkMesh.prepare(surface: fixture.surface, journal: fixture.journal)
      let frame = try await fixture.canvas.prepareSpatialFrame(mesh, size: .init(x: 512, y: 768), displayScale: 2)
      fixture.canvas.installSpatialFrame(frame, journal: fixture.journal, surface: fixture.surface)
      await withCheckedContinuation { continuation in frame.afterPresentationTransaction { continuation.resume() } }
      return fixture
    }
    private init() throws {
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene); oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
      canvas = .init(frame: .init(x: 0, y: 0, width: 512, height: 768), resources: resources)
      var drawing = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
      _ = drawing.append(tool: .pen, spans: [.init(surface: surface, samples: [-220.0, 0, 220].enumerated().map { index, x in
        .init(point: .zero, worldPoint: .init(x: x, y: 0), timeOffset: Double(index) / 10,
          width: 12, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor)
      journal = drawing
    }
    func close() async {
      await canvas.finishSpatialHandoffFrames()
      retention = nil; canvas.removeFromSuperview(); window.isHidden = true
      window.rootViewController = nil; oldKeyWindow?.makeKey()
    }
  }

  private final class Host: UIViewController {
    private(set) var appeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false }
  }
}
