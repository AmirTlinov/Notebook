import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentCutOriginTests: XCTestCase {
  private let geometry = WorkspaceItemGeometry.document(.a4)

  private func region(page: Int, offset: Any = 0.0, scale: Double = 1) -> [String: Any] {
    ["id": "program", "pageIndex": page, "x": 20.0 / scale, "y": 20.0 / scale,
      "width": 600.0 / scale, "height": 900.0 / scale, "sourceOffset": offset]
  }

  private func receipt(_ regions: [[String: Any]], key: String = "source", scale: Double = 1,
    page: Int? = nil) -> NSDictionary {
    var value: [String: Any] = ["sourceKey": key, "layoutCanonical": true, "anchors": [], "pageCount": 2,
      "layoutScope": page == nil ? "source" : "page",
      "width": geometry.width / scale, "height": geometry.height / scale, "regions": regions]
    if let page { value["pageIndex"] = page }
    return value as NSDictionary
  }

  private func layout(_ receipt: NSDictionary) throws -> DocumentLayoutRecord {
    try DocumentLayoutRecord(receipt: receipt, sourceKey: "source", blockIDs: ["program"], geometry: geometry)
  }

  func testAContinuationNamesItsSourceCutNotOnlyThePaperRectangle() throws {
    let full = try layout(receipt([region(page: 0), region(page: 1, offset: 900.0)]))
    let correct = try layout(receipt([region(page: 1, offset: 900.0)], page: 1))
    XCTAssertTrue(full.matches(correct, pageIndex: 1))
    for wrongOffset in [0.0, 899.0, 901.0, 1800.0] {
      let wrong = try layout(receipt([region(page: 1, offset: wrongOffset)], page: 1))
      XCTAssertFalse(full.matches(wrong, pageIndex: 1),
        "The same paper rectangle cannot substitute another piece of the program")
    }
  }

  func testChangingOnlyTheSourceOriginChangesTheWholeLayoutIdentity() throws {
    let full = try layout(receipt([region(page: 0), region(page: 1, offset: 900.0)]))
    let shifted = try layout(receipt([region(page: 0), region(page: 1, offset: 910.0)]))
    XCTAssertFalse(full.matches(shifted))
    XCTAssertNotEqual(full.regions, shifted.regions)
  }

  func testSourceOriginUsesTheSamePhysicalUnitsAsItsPaperRectangle() throws {
    let physical = try layout(receipt([region(page: 1, offset: 900.0)], page: 1))
    let half = try layout(receipt([region(page: 1, offset: 450.0, scale: 2)], scale: 2, page: 1))
    XCTAssertTrue(physical.matches(half))
    XCTAssertEqual(physical.regions, half.regions)
    let unscaledOrigin = try layout(receipt([region(page: 1, offset: 900.0, scale: 2)], scale: 2, page: 1))
    XCTAssertFalse(physical.matches(unscaledOrigin))
  }

  func testAnOriginCannotBeMissingNegativeNonfiniteOrAnUnrepresentablePhysicalAddress() throws {
    var missing = region(page: 1); missing.removeValue(forKey: "sourceOffset")
    XCTAssertThrowsError(try layout(receipt([missing], page: 1)))
    let invalidOffsets: [Any] = [-1.0, Double.nan, Double.infinity, -Double.infinity, "900", NSNull(), true, false]
    for offset in invalidOffsets {
      XCTAssertThrowsError(try layout(receipt([region(page: 1, offset: offset)], page: 1)))
    }
    var impossibleScale = try XCTUnwrap(receipt([region(page: 1, offset: Double.greatestFiniteMagnitude)], page: 1) as? [String: Any])
    impossibleScale["height"] = geometry.height / 2
    var tiny = region(page: 1, offset: Double.greatestFiniteMagnitude)
    tiny["height"] = 100.0
    impossibleScale["regions"] = [tiny]
    XCTAssertThrowsError(try layout(impossibleScale as NSDictionary))
  }

  func testARejectedNeighborCannotReplaceTheAcceptedSourceLayout() throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program",
      html: "<div>Physical continuation</div>", height: 1800)])
    let source = DocumentSourceSnapshot(document), key = source.message.key
    let accepted = try source.acceptLayout(receipt([region(page: 0), region(page: 1, offset: 900.0)], key: key), geometry: geometry)
    XCTAssertThrowsError(try source.acceptLayout(receipt([region(page: 1, offset: 0.0)], key: key, page: 1), geometry: geometry))
    XCTAssertTrue(source.layout === accepted)
    let neighbor = try source.acceptLayout(receipt([region(page: 1, offset: 900.0)], key: key, page: 1), geometry: geometry)
    XCTAssertTrue(neighbor === accepted)
  }
}
