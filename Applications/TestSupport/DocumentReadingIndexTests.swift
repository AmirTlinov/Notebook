import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentReadingIndexTests: XCTestCase {
  func testContentAddressSurvivesInsertionReflowAndDefinedDeletionFallback() throws {
    let original = try DocumentReadingIndex(segments: [
      .init(fileID: "a", nodeID: "1111111111111111", textOffset: 0, start: 0, end: 10, pageIndex: 0, y: 30.0),
      .init(fileID: "b", nodeID: "2222222222222222", textOffset: 40, start: 0, end: 10, pageIndex: 1, y: 30.0),
      .init(fileID: "b", nodeID: "2222222222222222", textOffset: 40, start: 10, end: 80, pageIndex: 2, y: 30.0),
      .init(fileID: "c", nodeID: "3333333333333333", textOffset: 0, start: 0, end: 10, pageIndex: 3, y: 30.0)
    ], fileIDs: ["a", "b", "c"], pageCount: 4)
    let anchor = try XCTUnwrap(original.anchor(page: 2, fileOrder: ["a", "b", "c"]))
    XCTAssertEqual(anchor.fileID, "b"); XCTAssertEqual(anchor.offset, 10)
    let changed = try DocumentReadingIndex(segments: [
      .init(fileID: "a", nodeID: "1111111111111111", textOffset: 0, start: 0, end: 10, pageIndex: 0, y: 30.0),
      .init(fileID: "b", nodeID: "aaaaaaaaaaaaaaaa", textOffset: 0, start: 0, end: 400, pageIndex: 1, y: 30.0),
      .init(fileID: "b", nodeID: "2222222222222222", textOffset: 440, start: 0, end: 20, pageIndex: 4, y: 30.0),
      .init(fileID: "b", nodeID: "2222222222222222", textOffset: 440, start: 20, end: 80, pageIndex: 5, y: 30.0),
      .init(fileID: "c", nodeID: "3333333333333333", textOffset: 0, start: 0, end: 10, pageIndex: 6, y: 30.0)
    ], fileIDs: ["a", "b", "c"], pageCount: 7)
    XCTAssertEqual(changed.page(for: anchor, survivingFileOrder: ["a", "b", "c"], regions: []), 4)
    XCTAssertEqual(changed.page(for: anchor, survivingFileOrder: ["a", "c"], regions: []), 6,
      "The following block wins an equal-distance deleted-anchor fallback")
    let edited = DocumentReadingAnchor(fileID: "b", nodeID: "ffffffffffffffff", textOffset: 445,
      offset: 10, fileOrder: ["a", "b", "c"])
    XCTAssertEqual(changed.page(for: edited, survivingFileOrder: ["a", "b", "c"], regions: []), 4)
    XCTAssertThrowsError(try DocumentReadingIndex(segments: [
      .init(fileID: "b", nodeID: "2222222222222222", textOffset: -1, start: 0, end: 1, pageIndex: 0, y: 3)
    ], fileIDs: ["b"], pageCount: 1))
    XCTAssertThrowsError(try DocumentReadingIndex(segments: [
      .init(fileID: "b", nodeID: "2222222222222222", textOffset: 0, start: 0, end: 1, pageIndex: 0, y: .nan)
    ], fileIDs: ["b"], pageCount: 1))
    let shifted = try DocumentReadingIndex(segments: [.init(fileID: "b", nodeID: "2222222222222222", textOffset: 0, start: 0, end: 1, pageIndex: 0, y: 3.02)],
      fileIDs: ["b"], pageCount: 1)
    let measured = try DocumentReadingIndex(segments: [.init(fileID: "b", nodeID: "2222222222222222", textOffset: 0, start: 0, end: 1, pageIndex: 0, y: 3.0)],
      fileIDs: ["b"], pageCount: 1)
    XCTAssertTrue(measured.matches(shifted, tolerance: 1 / 32))
  }
}
