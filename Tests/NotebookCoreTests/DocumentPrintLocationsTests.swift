import XCTest
@testable import NotebookCore

final class DocumentPrintLocationsTests: XCTestCase {
  func testPhysicalPointsAndBlockAddressExcludePageEnvelopeAndPackages() throws {
    let text = "SyncTeX Version:1\nUnit:1\nMagnification:1000\nX Offset:0\nY Offset:0\nContent:\n{1\n[1,9:0,0:20000000,40000000,0\n(1,3:655360,1310720:1966080,655360,327680\n(2,3:655360,1310720:1966080,655360,327680\n}1\n"
    let locations = try DocumentPrintLocations.decode(text, ranges: [.init(blockID: "p", firstLine: 2, lastLine: 5)])
    XCTAssertEqual(locations.count, 1)
    XCTAssertEqual(locations[0].blockID, "p"); XCTAssertEqual(locations[0].generatedLine, 3)
    XCTAssertEqual(locations[0].x, 10 * 72 / 72.27, accuracy: 0.000001)
    XCTAssertEqual(locations[0].y, 10 * 72 / 72.27, accuracy: 0.000001)
    XCTAssertEqual(locations[0].height, 15 * 72 / 72.27, accuracy: 0.000001)
  }
  func testAuthoredParagraphOffsetsDoNotTreatInsertedTeXLinesAsSourceLines() {
    let source = "# 😀 Title\n\nFirst.\n\nSecond."
    let second = (source as NSString).range(of: "Second.").location
    let range = DocumentPrintSourceRange(blockID: "body", firstLine: 20, lastLine: 26,
      sourceOffsets: [0, 0, 0, 13, 13, second, second])
    XCTAssertEqual(DocumentPrintLocations.sourceOffset(line: 26, range: range, source: source), second)
    XCTAssertEqual(DocumentPrintLocations.generatedLine(sourceOffset: second+3, range: range, source: source), 25)
  }
  func testImpossiblePageAndNonFiniteScaleAreRejected() {
    XCTAssertThrowsError(try DocumentPrintLocations.decode("SyncTeX Version:1\n{9000\n", ranges: []))
    XCTAssertThrowsError(try DocumentPrintLocations.decode("SyncTeX Version:1\nUnit:nan\n{1\n(1,1:0,0:10,10,0\n", ranges: [.init(blockID: "a", firstLine: 1, lastLine: 1)]))
  }
  func testGlyphSourceLineOverridesTheFollowingParagraphTerminatorWithoutInventingCharacterBounds() throws {
    let text = "SyncTeX Version:1\nUnit:1\nMagnification:1000\n{2\n(1,24:655360,1310720:1966080,655360,327680\ng1,23:700000,1310720\ng1,23:900000,1310720\n)\n}2\n"
    let result = try DocumentPrintLocations.decode(text, ranges: [.init(blockID: "body", firstLine: 19, lastLine: 24)])
    XCTAssertEqual(result.map(\.generatedLine), [24, 23], "A line does not allocate another location for every glyph")
    let line = try XCTUnwrap(DocumentPrintLocations.nearest(in: result, blockID: "body", pageIndex: 1, x: 12, y: 12))
    XCTAssertEqual(line.generatedLine, 23)
    XCTAssertEqual(line.width, result[0].width)
  }
}
