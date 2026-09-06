import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class SnapshotLeaseBindingTests: XCTestCase {
  @MainActor
  func testPageCompositionReadsTheBorrowedEntryAfterALateSameSourceCapture() async throws {
    let resources = SceneRenderResources(byteLimit: 6 * 1024 * 1024)
    let size = CGSize(width: 256, height: 256)
    let compositor = try await SceneRasterCompositor.create(size: size, scale: 2, resources: resources)
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 256, height: 256), source: "same source", html: "")
    let red = bitmap(size: size, color: .red), blue = bitmap(size: size, color: .blue)
    XCTAssertTrue(resources.store(red, for: element))
    let raster = try XCTUnwrap(resources.retainRaster(for: element, minimumScale: 2))
    defer { raster.release() }
    XCTAssertTrue(resources.store(blue, for: element))
    XCTAssertTrue(resources.image(for: element) === blue)
    try await compositor.draw(raster, in: CGRect(origin: .zero, size: size))
    try assertRed(try await compositor.finishPNG())
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testDocumentCompositionReadsItsLeaseAfterALateSameSourceCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .a4))
    let document = try XCTUnwrap(model.documents[id])
    let state = try XCTUnwrap(model.documentStates[id])
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let size = NSSize(width: geometry.width, height: geometry.height)
    let source = SceneRasterSource.document(id: id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    let resources = SceneRenderResources.shared
    let red = bitmap(size: size, color: .red)
    let blue = bitmap(size: size, color: .blue)
    XCTAssertTrue(resources.store(red, for: source))
    let lease = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0)
    defer { lease.release() }
    XCTAssertTrue(resources.store(blue, for: source))
    XCTAssertTrue(resources.image(for: source) === blue)
    XCTAssertTrue(lease.image(for: source) === red)
    XCTAssertNil(lease.image(for: .document(id: id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 1))),
      "A retained page cannot stand in for a different physical page")
    model.updatePresence(.init(mode: .document, camera: .init(),
      viewport: .init(x: 256, y: 256), focusedItemID: id, openProgress: 1), settled: true)

    try assertRed(try await publish(model, documentRaster: lease))
    await model.finishPendingPersistence()
  }

  @MainActor
  func testRetainedSourceDoesNotFollowANewerOrEvictedAlias() async throws {
    let resources = SceneRenderResources(byteLimit: 4_096, maximumRasterCount: 2)
    let element = AgentElement(id: "retained", kind: .web,
      frame: .init(x: 0, y: 0, width: 8, height: 8), source: "same", html: "")
    let red = bitmap(size: .init(width: 8, height: 8), color: .red)
    let blue = bitmap(size: red.size, color: .blue)
    XCTAssertTrue(resources.store(red, for: element))
    let raster = try XCTUnwrap(resources.retainRaster(for: element))
    XCTAssertTrue(resources.store(blue, for: element))
    XCTAssertTrue(resources.image(for: element) === blue)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 16, pixelHeight: 16))
    XCTAssertEqual(resources.rasterCount, 1, "Only the unretained replacement can be evicted")
    XCTAssertTrue(raster.image(for: .agent(element)) === red)
    XCTAssertTrue(resources.image(for: element) === red)
    reservation.release()
    raster.release()
    XCTAssertNil(raster.image(for: .agent(element)))
  }

  @MainActor
  private func publish(_ model: NotebookAppModel,
    documentRaster: RasterLease? = nil) async throws -> Data {
    let presence = try XCTUnwrap(model.presence)
    let document = presence.mode == .document ? model.activeDocument : nil
    let pngURL = model.store.root.appendingPathComponent("lease-bound.png")
    try await CurrentViewPreviewWriter.write(model: model,
      viewport: .init(width: presence.viewport.x, height: presence.viewport.y),
      workspace: try XCTUnwrap(model.workspace), board: try XCTUnwrap(model.boardHierarchy),
      spatialInk: try XCTUnwrap(model.spatialInk), presence: presence,
      page: presence.mode == .page ? model.activePage : nil,
      document: document, documentState: document.flatMap { model.documentStates[$0.id] },
      documentRaster: documentRaster,
      pngURL: pngURL, receiptURL: model.store.root.appendingPathComponent("lease-bound.json"))
    return try Data(contentsOf: pngURL)
  }

  private func bitmap(size: NSSize, color: NSColor) -> NSImage {
    let width = Int(ceil(size.width * 2)), height = Int(ceil(size.height * 2))
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(.init(x: 0, y: 0, width: width, height: height))
    return NSImage(cgImage: context.makeImage()!, size: size)
  }

  private func assertRed(_ png: Data, file: StaticString = #filePath, line: UInt = #line) throws {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png), file: file, line: line)
    let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
      .usingColorSpace(.deviceRGB), file: file, line: line)
    XCTAssertGreaterThan(color.redComponent, 0.9, file: file, line: line)
    XCTAssertLessThan(color.blueComponent, 0.1,
      "The PNG must use the red retained entry, not the later blue cache alias", file: file, line: line)
  }
}
