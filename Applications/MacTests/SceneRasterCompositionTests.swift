import AppKit
import CryptoKit
import ImageIO
import NotebookCore
import UniformTypeIdentifiers
import XCTest
import SwiftUI
@testable import Notebook

final class SceneRasterCompositionTests: XCTestCase {
  @MainActor
  func testPageCompositionKeepsItsPNGIdentityAcrossOtherSizesAndScales() async throws {
    let page = PageDocument(size: .init(width: 834, height: 1194), actor: UUID())
    let reference = try await PageCompositionRenderer.render(page) { _ in throw CocoaError(.featureUnsupported) }
    for index in 0..<20 {
      let other = PageDocument(size: .init(width: 211.25 + Double(index), height: 307.75), actor: UUID())
      _ = try await PageCompositionRenderer.render(other, scale: [0.5, 1, 1.25, 3][index % 4]) { _ in
        throw CocoaError(.featureUnsupported)
      }
      let rendered = try await PageCompositionRenderer.render(page) { _ in throw CocoaError(.featureUnsupported) }
      if rendered.png != reference.png {
        for (name, data) in [("Reference page bytes", reference.png), ("Changed page bytes \(index)", rendered.png)] {
          let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
          attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTFail("A repeated page composition changed its certified PNG after another physical size or scale")
        return
      }
    }
  }

  @MainActor
  func testPageCompositionRetainsItsPNGIdentityDuringParallelVisionEncoding() async throws {
    let page = PageDocument(size: .init(width: 834, height: 1194), actor: UUID())
    let reference = try await PageCompositionRenderer.render(page) { _ in throw CocoaError(.featureUnsupported) }
    let proof = XCTAttachment(data: reference.png, uniformTypeIdentifier: "public.png")
    proof.name = "Physical page before parallel ink-map preparation"; proof.lifetime = .keepAlways; add(proof)
    for index in 0..<64 {
      let vision = Task.detached(priority: .utility) { try PageVisionRenderer.render(page) }
      let rendered = try await PageCompositionRenderer.render(page) { _ in throw CocoaError(.featureUnsupported) }
      _ = try await vision.value
      if rendered.png != reference.png {
        for (name, data) in [("Reference before parallel encoding", reference.png), ("Parallel page bytes \(index)", rendered.png)] {
          let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
          attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTFail("Independent ink-map encoding changed the certified physical page PNG")
        return
      }
    }
  }

  @MainActor
  func testArtworkContextPreservesFractionalPlacementAxesAndTransparency() async throws {
    let resources = SceneRenderResources(byteLimit: 4 * 1024 * 1024)
    let compositor = try await SceneRasterCompositor.create(size: .init(width: 100, height: 80), scale: 2, resources: resources)
    let artwork = VStack(spacing: 0) {
      HStack(spacing: 0) { Color(.sRGB, red: 1, green: 0, blue: 0); Color(.sRGB, red: 0, green: 1, blue: 0) }
      HStack(spacing: 0) { Color(.sRGB, red: 0, green: 0, blue: 1); Color(.sRGB, red: 1, green: 1, blue: 0, opacity: 0.5) }
    }
    try await compositor.drawView(artwork, size: .init(width: 80, height: 40),
      in: .init(x: 11.25, y: 13.75, width: 40, height: 20))
    let png = try await compositor.finishPNG()
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "Fractional artwork axes and alpha"; attachment.lifetime = .keepAlways; add(attachment)
    let bitmap = try pixels(png)
    let upperLeft = try XCTUnwrap(bitmap.colorAt(x: 30, y: 34))
    let upperRight = try XCTUnwrap(bitmap.colorAt(x: 86, y: 34))
    let lowerLeft = try XCTUnwrap(bitmap.colorAt(x: 30, y: 58))
    let lowerRight = try XCTUnwrap(bitmap.colorAt(x: 86, y: 58))
    XCTAssertGreaterThan(upperLeft.redComponent, 0.9)
    XCTAssertLessThan(upperLeft.blueComponent, 0.1)
    XCTAssertGreaterThan(upperRight.greenComponent, 0.4)
    XCTAssertLessThan(upperRight.blueComponent, 0.2)
    XCTAssertGreaterThan(lowerLeft.blueComponent, 0.9)
    XCTAssertLessThan(lowerLeft.redComponent, 0.1)
    XCTAssertEqual(lowerRight.alphaComponent, 0.5, accuracy: 1.0 / 255)
    XCTAssertEqual(bitmap.colorAt(x: 4, y: 4)?.alphaComponent, 0)
    XCTAssertEqual(bitmap.colorAt(x: 120, y: 34)?.alphaComponent, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

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
  func testInkTilesKeepTheWholeMetalRasterAtFractionalProjectionAndEraserSeams() async throws {
    let resources = SceneRenderResources(byteLimit: 24 * 1024 * 1024)
    let surface = SurfaceID.cover(UUID())
    let actor = UUID()
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    for (tool, width, points) in [
      (SpatialInkTool.pen, 35.0, [(0.0, 170.0), (640, 310)]),
      (.pen, 23.0, [(0.0, 270.0), (640, 270)]),
      (.eraser, 11.0, [(0.0, 210.0), (640, 240)])
    ] {
      let samples = points.enumerated().map { index, point in
        SpatialInkSample(point: .init(x: point.0, y: point.1), timeOffset: Double(index),
          width: width, opacity: 0.7, force: 1, azimuth: 0, altitude: 1)
      }
      _ = journal.append(tool: tool, spans: [.init(surface: surface, samples: samples)], actor: actor)
    }
    let size = CGSize(width: 640, height: 384)
    let fullScale = try await SceneRasterCompositor.create(size: size, scale: 2, resources: resources)
    try await fullScale.drawInk(surface: surface, journal: journal, camera: nil,
      size: size, in: .init(origin: .zero, size: size))
    let fullScalePNG = try await fullScale.finishPNG()
    let output = CGSize(width: 600, height: 400)
    let frame = CGRect(x: -87.35, y: 17.2, width: size.width * 0.731, height: size.height * 0.731)
    // A single MSAA render of this source would exceed the complete budget.
    XCTAssertGreaterThan(Int(size.width * 2 * size.height * 2 * 4 * 8), resources.byteLimit)
    let tiled = try await SceneRasterCompositor.create(size: output, scale: 2, resources: resources)
    try await tiled.drawInk(surface: surface, journal: journal, camera: nil, size: size, in: frame)
    let actualPNG = try await tiled.finishPNG()
    let actual = try rgba(actualPNG)
    XCTAssertEqual(resources.reservedBytes, 0)
    let reference = try XCTUnwrap(InkRasterRenderer.shared.render(
      layers: SpatialInkComposer.localLayers(for: surface, journal: journal), size: size, scale: 2))
    let source = element("whole-reference", size: size)
    XCTAssertTrue(resources.store(NSImage(cgImage: reference, size: size), for: source))
    let lease = try XCTUnwrap(resources.retainRaster(for: source))
    let whole = try await SceneRasterCompositor.create(size: output, scale: 2, resources: resources)
    try await whole.draw(lease, in: frame)
    lease.release()
    let expectedPNG = try await whole.finishPNG()
    let expected = try rgba(expectedPNG)
    let errors = zip(actual, expected).map { abs(Int($0) - Int($1)) }
    if (errors.max() ?? 0) > 3 {
      XCTContext.runActivity(named: "Tile edge differences") { activity in
        for (name, png) in [("Tiled ink", actualPNG), ("Whole ink", expectedPNG)] {
          let attachment = XCTAttachment(image: NSImage(data: png)!)
          attachment.name = name; attachment.lifetime = .keepAlways; activity.add(attachment)
        }
        let locations = errors.indices.filter { errors[$0] > 3 }.prefix(100).map { i in
          "x=\(i / 4 % 1200) y=\(i / 4 / 1200) c=\(i % 4) actual=\(actual[i]) expected=\(expected[i])"
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: "badChannels=\(errors.filter { $0 > 3 }.count)\n\(locations)")
        attachment.lifetime = .keepAlways; activity.add(attachment)
        let native = XCTAttachment(image: NSImage(data: fullScalePNG)!)
        native.name = "Unscaled tiles"; native.lifetime = .keepAlways; activity.add(native)
        let nativeReference = XCTAttachment(image: NSImage(cgImage: reference, size: size))
        nativeReference.name = "Unscaled whole"; nativeReference.lifetime = .keepAlways; activity.add(nativeReference)
      }
    }
    XCTAssertLessThanOrEqual(errors.max() ?? 0, 3, "No gaps or double alpha along a 512-pixel tile edge")
    XCTAssertGreaterThan(actual.filter { $0 != 0 }.count, 10_000)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testRegionalInkProofKeepsTheWholeRendererPNGIdentity() async throws {
    let actor = UUID()
    let boardID = UUID()
    let surface = SurfaceID.board(boardID)
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    for (tool, width) in [(SpatialInkTool.pen, 27.0), (.eraser, 10.0)] {
      let samples = [-90.0, 100].enumerated().map { index, x in
        SpatialInkSample(point: .zero, worldPoint: .init(x: x, y: 27), timeOffset: Double(index),
          width: width, opacity: 0.7, force: 1, azimuth: 0, altitude: 1)
      }
      _ = journal.append(tool: tool, spans: [.init(surface: surface, samples: samples)], actor: actor)
    }
    let size = CGSize(width: 300.25, height: 170.75)
    let camera = SpatialCamera(center: .init(x: 25.5, y: -17.25), scale: 0.731)
    let whole = try XCTUnwrap(InkRasterRenderer.shared.render(layers: SpatialInkComposer.boardLayers(
      board: surface, journal: journal, camera: camera, viewport: .init(x: size.width, y: size.height)),
      size: size, scale: 2))
    let encoded = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, whole,
      [kCGImagePropertyDPIWidth: 144.0, kCGImagePropertyDPIHeight: 144.0] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let prepared = try await SpatialInkRasterSnapshot.prepare(surface: surface, camera: camera,
      size: size, journal: journal, permitsPreparation: { true })
    let result = try XCTUnwrap(prepared)
    XCTAssertEqual(SHA256.hash(data: result.png).description, SHA256.hash(data: encoded as Data).description,
      "Changing preparation must not mark an unchanged historical source as edited")
    XCTAssertEqual(result.regions, try SpatialInkRasterSnapshot.occupiedRegions(whole, size: size))
  }

  @MainActor
  func testBoardCompositionStreamsMoreSourcePixelsThanItsBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 10_000, y: 0))
    let workspace = try XCTUnwrap(model.workspace)
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let actor = UUID()
    for index in 0..<8 {
      let source = SpatialElement(id: "unique-\(index)", surface: .board(workspace.rootBoardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 256, height: 256), worldOrigin: .init(x: -128, y: -128),
        source: "unique program \(index)",
        html: "<svg width='256' height='256'><rect width='256' height='256' fill='rgb(\(index * 30),0,0)'/></svg>",
        stamp: .init(counter: 0, actor: actor))
      XCTAssertTrue(hierarchy.upsertElement(source, in: workspace.rootBoardID, expected: nil, actor: actor))
    }
    let resources = SceneRenderResources(byteLimit: 6 * 1024 * 1024, maximumBackgroundWebSurfaces: 1)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: model.documents.mapValues(\.paperSize))
    let painter = SceneCompositionRenderer(source: SceneCompositionSource(index: index, hierarchy: hierarchy,
      journal: try XCTUnwrap(model.spatialInk)), resources: resources)
    let result = try await painter.render(presence: .init(boardID: workspace.rootBoardID,
      mode: .board, camera: .init(), viewport: .init(x: 256, y: 256)))
    let rendered = try pixels(result.png)
    XCTAssertEqual(rendered.colorAt(x: 256, y: 256)!.redComponent, 210.0 / 255, accuracy: 0.025)
    XCTAssertLessThanOrEqual(resources.residentBytes, resources.byteLimit)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    await model.finishPendingPersistence()
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

  private func rgba(_ png: Data) throws -> [UInt8] {
    let image = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: context.bytesPerRow * context.height))
  }
}
