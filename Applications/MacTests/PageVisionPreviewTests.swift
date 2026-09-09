import AppKit
import NotebookCore
import PencilKit
import XCTest

@testable import Notebook

final class PageVisionPreviewTests: XCTestCase {
  @MainActor
  func testReadingContrastMakesLightNativeInkVisibleAndKeepsTheMap() throws {
    let samples = [30.0, 220.0].map { x in
      SpatialInkSample(
        point: .init(x: x, y: 100), timeOffset: 0, width: 4,
        opacity: 0.18, force: 0, azimuth: 0, altitude: 1)
    }
    let drawing = PageInkDrawing(actions: [PageInkAction(tool: .pen, samples: samples)])
    var page = PageDocument(size: .init(width: 260, height: 260), actor: UUID())
    page.replaceDrawing(try drawing.dataRepresentation(), actor: UUID())
    let render = try PageVisionRenderer.render(page)
    func minimumChannel(_ data: Data) throws -> UInt8 {
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      let bytes = try XCTUnwrap(bitmap.bitmapData)
      var minimum: UInt8 = 255
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          minimum = min(minimum, bytes[y * bitmap.bytesPerRow + x * 4])
        }
      }
      return minimum
    }
    XCTAssertLessThan(try minimumChannel(render.inkPNG), try minimumChannel(render.faithfulPNG))
    XCTAssertEqual(render.regions.count, 1)
    XCTAssertNotNil(render.visibleInkBounds)
  }

  @MainActor
  func testReceiptBindsVisibleRegionsToExactPNGs() throws {
    let fixture = try makeFixture(
      drawing: PKDrawing(strokes: [
        stroke(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 92, y: 40))
      ]))
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try PagePreviewWriter.write(fixture.page, store: fixture.store)

    let receipt = try readReceipt(fixture)
    XCTAssertEqual(receipt.pageID, fixture.page.id)
    XCTAssertEqual(receipt.drawingStamp, fixture.page.drawingStamp)
    XCTAssertTrue(receipt.isValid)
    XCTAssertFalse(receipt.occupiedCells.isEmpty)
    XCTAssertEqual(receipt.regions.count, 1)
    XCTAssertEqual(
      receipt.previewPNG_SHA256,
      try PageVisionRenderer.sha256(
        Data(contentsOf: fixture.store.previewURL(fixture.page.id))
      )
    )
    XCTAssertEqual(
      receipt.inkPNG_SHA256,
      try PageVisionRenderer.sha256(
        Data(contentsOf: fixture.store.previewInkURL(fixture.page.id))
      )
    )

    let region = try XCTUnwrap(receipt.regions.first)
    XCTAssertEqual(region.contentCells.row, 1)
    for mode in ["faithful", "ink"] {
      let url = fixture.store.previewRegionsURL(fixture.page.id)
        .appendingPathComponent("\(region.id).\(mode).png")
      let representation = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
      XCTAssertEqual(representation.pixelsWide, region.cropPixels.width)
      XCTAssertEqual(representation.pixelsHigh, region.cropPixels.height)
      if mode == "ink" {
        XCTAssertTrue(containsNonWhitePixel(representation))
      }
    }
  }

  @MainActor
  func testErasedPixelsDoNotCreateGhostRegions() throws {
    let source = PKDrawing(strokes: [
      stroke(from: CGPoint(x: 12, y: 130), to: CGPoint(x: 248, y: 130))
    ])
    let eraser = PKStrokePath(
      controlPoints: [point(x: 130, y: 130, width: 88)],
      creationDate: Date()
    )
    let erased = source.erasingPath(eraser)
    let fixture = try makeFixture(drawing: erased)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try PagePreviewWriter.write(fixture.page, store: fixture.store)

    let receipt = try readReceipt(fixture)
    let centerColumn = Int(130 / PhysicalPaper.gridSpacing)
    let occupiedCenterColumns = receipt.occupiedCells.filter {
      abs($0.column - centerColumn) <= 1
    }
    XCTAssertTrue(
      occupiedCenterColumns.isEmpty,
      "Стёртая середина не должна возвращаться из исходного PKStroke.path"
    )
    XCTAssertEqual(receipt.regions.count, 2)
  }

  @MainActor
  func testBlankRevisionRemovesPreviousRegionArtifacts() throws {
    var fixture = try makeFixture(
      drawing: PKDrawing(strokes: [
        stroke(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 92, y: 40))
      ]))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try PagePreviewWriter.write(fixture.page, store: fixture.store)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.store.previewRegionsURL(fixture.page.id).path
      ).isEmpty
    )

    XCTAssertTrue(fixture.page.replaceDrawing(Data(), actor: UUID()))
    try PagePreviewWriter.write(fixture.page, store: fixture.store)

    let receipt = try readReceipt(fixture)
    XCTAssertNil(receipt.visibleInkBounds)
    XCTAssertTrue(receipt.occupiedCells.isEmpty)
    XCTAssertTrue(receipt.regions.isEmpty)
    let archived = try FileManager.default.contentsOfDirectory(
      at: fixture.store.previewVisionHistoryURL(fixture.page.id),
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(archived.count, 1)
    let archivedReceipt = try JSONDecoder().decode(
      PageVisionReceipt.self,
      from: Data(contentsOf: XCTUnwrap(archived.first))
    )
    XCTAssertEqual(archivedReceipt.drawingStamp.counter, 1)
    XCTAssertEqual(archivedReceipt.regions.count, 1)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.store.previewRegionsURL(fixture.page.id).path
      ).isEmpty
    )
  }

  @MainActor
  func testLargeConnectedSketchBecomesReadableDetailWindows() throws {
    let fixture = try makeFixture(
      drawing: PKDrawing(strokes: [
        stroke(from: CGPoint(x: 10, y: 100), to: CGPoint(x: 824, y: 100))
      ]),
      size: PageSize(width: 834, height: 300)
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    try PagePreviewWriter.write(fixture.page, store: fixture.store)

    let receipt = try readReceipt(fixture)
    XCTAssertGreaterThan(receipt.regions.count, 1)
    XCTAssertTrue(
      receipt.regions.allSatisfy {
        $0.contentCells.width <= 12 && $0.contentCells.height <= 12
      })
    XCTAssertTrue(
      receipt.occupiedCells.allSatisfy { cell in
        receipt.regions.contains { $0.contentCells.contains(cell) }
      })
  }

  @MainActor
  func testCorruptedArtifactCannotHideBehindAValidatedRevision() throws {
    let fixture = try makeFixture(
      drawing: PKDrawing(strokes: [
        stroke(from: CGPoint(x: 30, y: 40), to: CGPoint(x: 92, y: 40))
      ]))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try PagePreviewWriter.write(fixture.page, store: fixture.store)
    XCTAssertTrue(
      fixture.store.hasCurrentPageVision(fixture.page)
    )

    try Data("corrupted".utf8).write(
      to: fixture.store.previewURL(fixture.page.id),
      options: [.atomic]
    )

    XCTAssertFalse(
      fixture.store.hasCurrentPageVision(fixture.page)
    )
  }

  private struct Fixture {
    let root: URL
    let store: NotebookStore
    var page: PageDocument
  }

  @MainActor
  private func makeFixture(
    drawing: PKDrawing,
    size: PageSize = PageSize(width: 260, height: 260)
  ) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = NotebookStore(root: root)
    try store.prepare()
    let actor = UUID()
    var page = PageDocument(
      size: size,
      actor: actor
    )
    XCTAssertTrue(
      page.replaceDrawing(
        try LegacyPencilFixture.importDrawing(drawing.dataRepresentation(), size: size)
          .dataRepresentation(), actor: actor))
    return Fixture(root: root, store: store, page: page)
  }

  private func readReceipt(_ fixture: Fixture) throws -> PageVisionReceipt {
    try JSONDecoder().decode(
      PageVisionReceipt.self,
      from: Data(
        contentsOf: fixture.store.previewVisionReceiptURL(fixture.page.id)
      )
    )
  }

  private func stroke(from start: CGPoint, to end: CGPoint) -> PKStroke {
    let points = stride(from: 0.0, through: 1.0, by: 0.05).map { progress in
      point(
        x: start.x + (end.x - start.x) * progress,
        y: start.y + (end.y - start.y) * progress,
        width: 4
      )
    }
    return PKStroke(
      ink: PKInk(.monoline, color: .black),
      path: PKStrokePath(controlPoints: points, creationDate: Date())
    )
  }

  private func point(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: CGPoint(x: x, y: y),
      timeOffset: 0,
      size: CGSize(width: width, height: width),
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

  private func containsNonWhitePixel(_ bitmap: NSBitmapImageRep) -> Bool {
    guard let bytes = bitmap.bitmapData,
      bitmap.bitsPerSample == 8,
      bitmap.samplesPerPixel >= 3,
      !bitmap.isPlanar
    else { return false }
    for y in 0..<bitmap.pixelsHigh {
      let rowStart = y * bitmap.bytesPerRow
      for x in 0..<bitmap.pixelsWide {
        let pixel = rowStart + x * bitmap.samplesPerPixel
        if bytes[pixel] < 245 || bytes[pixel + 1] < 245 || bytes[pixel + 2] < 245 {
          return true
        }
      }
    }
    return false
  }
}
