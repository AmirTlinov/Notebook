import AppKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicRenderingTests: XCTestCase {
  func testNativeCompositeAndInkMapShareReversiblePresentationWithoutWebKit() async throws {
    let actor = UUID()
    let stroke = PageInkAction(tool: .pen, samples: [20.0, 110.0].map {
      .init(point: .init(x: $0, y: 30), timeOffset: 0, width: 5, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
    let drawing = try PageInkDrawing(actions: [stroke]).dataRepresentation()
    func page(_ representation: NotebookGraphic.Representation, visible: Bool = true) -> PageDocument {
      .init(size: .init(width: 260, height: 260), actor: actor, drawingData: drawing, elements: [
        .init(id: "circle", kind: .graphic, frame: .init(x: 100, y: 100, width: 120, height: 120),
          source: "", html: "", graphic: .init(label: "+", representation: representation,
            visible: visible, sourceInkIDs: [stroke.id]))
      ])
    }
    func pixels(_ page: PageDocument) async throws -> Data {
      try await PageCompositionRenderer.render(page) { _ in
        XCTFail("A native shape must not request a web source")
        throw CocoaError(.featureUnsupported)
      }.png
    }
    let raw = page(.ink), geometry = page(.geometry), hidden = page(.geometry, visible: false)
    let original = try await pixels(raw), converted = try await pixels(geometry), deleted = try await pixels(hidden)
    XCTAssertNotEqual(original, converted); XCTAssertNotEqual(converted, deleted)
    let restoredGeometry = try await pixels(page(.geometry)), restoredInk = try await pixels(page(.ink))
    XCTAssertEqual(restoredGeometry, converted); XCTAssertEqual(restoredInk, original)
    XCTAssertFalse(try PageVisionRenderer.render(raw).regions.isEmpty)
    XCTAssertTrue(try PageVisionRenderer.render(geometry).regions.isEmpty)
    XCTAssertTrue(try PageVisionRenderer.render(hidden).regions.isEmpty)
    XCTAssertEqual(raw.drawingData, geometry.drawingData); XCTAssertEqual(hidden.drawingData, drawing)
  }

  func testInkRasterIdentityIncludesPresentationWithoutChangingTheMeasurementVersion() async throws {
    let actor = UUID(), id = UUID()
    let stroke = PageInkAction(tool: .pen, samples: [20.0, 100.0].map {
      .init(point: .init(x: $0, y: 30), timeOffset: 0, width: 5, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
    let raw = PageDocument(id: id, size: .init(width: 180, height: 180), actor: actor,
      drawingData: try PageInkDrawing(actions: [stroke]).dataRepresentation())
    var converted = raw
    converted.replaceElements([.init(id: "circle", kind: .graphic,
      frame: .init(x: 20, y: 20, width: 100, height: 100), source: "", html: "",
      graphic: .init(sourceInkIDs: [stroke.id]))], actor: actor)
    let cache = PageInkRasterCache()
    await cache.prepare(raw)
    let original = try XCTUnwrap(cache.image(for: raw))
    XCTAssertNil(cache.image(for: converted))
    await cache.prepare(converted)
    XCTAssertFalse(try XCTUnwrap(cache.image(for: converted)) === original)
    XCTAssertTrue(cache.image(for: raw) === original)
    XCTAssertEqual(raw.drawingStamp, converted.drawingStamp)
  }
}
