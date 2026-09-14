import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentReadingIndexTests: XCTestCase {
  func testContentAddressSurvivesInsertionReflowAndDefinedDeletionFallback() throws {
    let original = try DocumentReadingIndex(rows: [
      ["a", "1111111111111111", 0, 0, 10, 0, 30.0],
      ["b", "2222222222222222", 40, 0, 10, 1, 30.0],
      ["b", "2222222222222222", 40, 10, 80, 2, 30.0],
      ["c", "3333333333333333", 0, 0, 10, 3, 30.0]
    ], blockIDs: ["a", "b", "c"], pageCount: 4, scale: 1)
    let anchor = try XCTUnwrap(original.anchor(page: 2, blockOrder: ["a", "b", "c"]))
    XCTAssertEqual(anchor.blockID, "b"); XCTAssertEqual(anchor.offset, 10)
    let changed = try DocumentReadingIndex(rows: [
      ["a", "1111111111111111", 0, 0, 10, 0, 30.0],
      ["b", "aaaaaaaaaaaaaaaa", 0, 0, 400, 1, 30.0],
      ["b", "2222222222222222", 440, 0, 20, 4, 30.0],
      ["b", "2222222222222222", 440, 20, 80, 5, 30.0],
      ["c", "3333333333333333", 0, 0, 10, 6, 30.0]
    ], blockIDs: ["a", "b", "c"], pageCount: 7, scale: 1)
    XCTAssertEqual(changed.page(for: anchor, survivingBlockOrder: ["a", "b", "c"], regions: []), 4)
    XCTAssertEqual(changed.page(for: anchor, survivingBlockOrder: ["a", "c"], regions: []), 6,
      "The following block wins an equal-distance deleted-anchor fallback")
    let edited = DocumentReadingAnchor(blockID: "b", nodeID: "ffffffffffffffff", textOffset: 445,
      offset: 10, blockOrder: ["a", "b", "c"])
    XCTAssertEqual(changed.page(for: edited, survivingBlockOrder: ["a", "b", "c"], regions: []), 4)
    XCTAssertThrowsError(try DocumentReadingIndex(rows: [["b", "2222222222222222", true, 0, 1, 0, 3]],
      blockIDs: ["b"], pageCount: 1, scale: 1))
    XCTAssertThrowsError(try DocumentReadingIndex(rows: [["b", "2222222222222222", 0, 0, 1, 0, true]],
      blockIDs: ["b"], pageCount: 1, scale: 1))
    let shifted = try DocumentReadingIndex(rows: [["b", "2222222222222222", 0, 0, 1, 0, 3.02]],
      blockIDs: ["b"], pageCount: 1, scale: 1)
    let measured = try DocumentReadingIndex(rows: [["b", "2222222222222222", 0, 0, 1, 0, 3.0]],
      blockIDs: ["b"], pageCount: 1, scale: 1)
    XCTAssertTrue(measured.matches(shifted, tolerance: 1 / 32))
  }
}
