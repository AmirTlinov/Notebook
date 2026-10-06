import XCTest
import Testing
import Foundation
@testable import NotebookCore

final class DocumentPrintLocationsTests: XCTestCase {
  private func file(_ id: String, _ path: String, lines: Int = 100) -> DocumentPrintSourceFile {
    .init(fileID: id, path: path, sha256: String(repeating: "a", count: 64), lineCount: lines)
  }
  func testPhysicalPointsUseRealFileTagsAndExcludeDistribution() throws {
    let text = "SyncTeX Version:1\nNotebook Shipout:1\nInput:1:/input/main.tex\nInput:2:/input/chapters/one.tex\nInput:3:/bundle/article.cls\nUnit:1\nMagnification:1000\nX Offset:0\nY Offset:0\nContent:\n{1\n[1,9:0,0:20000000,40000000,0\n(2,3:655360,1310720:1966080,655360,327680\n)\n(3,3:655360,1310720:1966080,655360,327680\n}1\n"
    let locations = try DocumentPrintLocations.decode(text, files: [file("main", "main.tex"), file("chapter", "chapters/one.tex")], pages: [.init(width: 300, height: 400), .init(width: 300, height: 400)]).locations
    XCTAssertEqual(locations.count, 1)
    XCTAssertEqual(locations[0].fileID, "chapter"); XCTAssertEqual(locations[0].path, "chapters/one.tex"); XCTAssertEqual(locations[0].line, 3)
    XCTAssertEqual(locations[0].x, 10*72/72.27, accuracy: 0.000001)
    XCTAssertEqual(locations[0].y, 10*72/72.27, accuracy: 0.000001)
    XCTAssertEqual(locations[0].height, 15*72/72.27, accuracy: 0.000001)
  }
  func testAuthoredUTF16OffsetsAreExactWithoutGeneratedParagraphs() {
    let source = "Title 😀\n\nFirst.\n\nSecond."
    let offset = (source as NSString).range(of: "Second.").location
    let index = DocumentPrintLineIndex(source)
    XCTAssertEqual(index.sourceOffset(line: 5), offset)
    XCTAssertEqual(index.line(sourceOffset: offset+3), 5)
    XCTAssertEqual(index.range(line: 1), NSRange(location: 0, length: "Title 😀".utf16.count))
    XCTAssertEqual(index.sourceOffset(line: 0), 0)
    XCTAssertEqual(index.sourceOffset(line: 99), offset)
    let trailing = DocumentPrintLineIndex("a😀\n\n")
    XCTAssertEqual(trailing.starts, [0, 4, 5])
    XCTAssertEqual(trailing.range(line: 3), NSRange(location: 5, length: 0))
    XCTAssertEqual(trailing.line(sourceOffset: 50), 3)

  }
  func testImpossiblePagesAndNonFiniteScaleAreRejected() {
    XCTAssertThrowsError(try DocumentPrintLocations.decode("SyncTeX Version:1\nNotebook Shipout:1\n{9000\n", files: [], pages: [.init(width: 300, height: 400)]))
    XCTAssertThrowsError(try DocumentPrintLocations.decode("SyncTeX Version:1\nNotebook Shipout:1\nInput:1:main.tex\nUnit:nan\n{1\n(1,1:0,0:10,10,0\n", files: [file("a", "main.tex")], pages: [.init(width: 300, height: 400)]))
    XCTAssertThrowsError(try DocumentPrintLocations.decode("SyncTeX Version:1\nNotebook Shipout:1\n", files: [file("a", "same.tex"), file("b", "same.tex")], pages: [.init(width: 300, height: 400)]))
  }
  func testGlyphsRetainTheirActualFileAndLineWithoutInventingCharacterBounds() throws {
    let text = "SyncTeX Version:1\nNotebook Shipout:1\nInput:1:main.tex\nInput:2:chapters/one.tex\nUnit:1\nMagnification:1000\n{2\n(1,24:655360,1310720:1966080,655360,327680\ng2,23:700000,1310720\ng2,23:900000,1310720\n)\n}2\n"
    let result = try DocumentPrintLocations.decode(text, files: [file("main", "main.tex"), file("chapter", "chapters/one.tex")], pages: [.init(width: 300, height: 400), .init(width: 300, height: 400)]).locations
    XCTAssertEqual(result.map(\.line), [24, 23]); XCTAssertEqual(result.map(\.fileID), ["main", "chapter"])
    let line = try XCTUnwrap(DocumentPrintLocations.nearest(in: result, fileID: "chapter", pageIndex: 1, x: 12, y: 12))
    XCTAssertEqual(line.line, 23)
  }
  func testShipoutRegionsUseFinalPageGeometryAndOneContinuousViewport() throws {
    let text = "SyncTeX Version:1\nNotebook Shipout:1\n{2\nN=655360,1310720:osc|programs/oscillator|1966080|655360|0|1310720\n}2\n{3\nN=655360,1310720:osc|programs/oscillator|1966080|655360|655360|1310720\n}3\n"
    let pages = [DocumentPrintPage(width: 300, height: 400), .init(width: 400, height: 500), .init(width: 400, height: 600)]
    let regions = try DocumentPrintLocations.decode(text, files: [], pages: pages).interactiveRegions
    XCTAssertEqual(regions.map(\.pageIndex), [1, 2]); XCTAssertEqual(regions.map(\.instanceID), ["osc", "osc"])
    XCTAssertEqual(regions[0].y, 10*72/72.27, accuracy: 0.000001)
    XCTAssertEqual(regions[1].y, 10*72/72.27, accuracy: 0.000001)
    XCTAssertEqual(regions[1].viewportY, regions[0].height, accuracy: 0.000001)
    XCTAssertEqual(regions[0].viewportHeight, regions.reduce(0) { $0+$1.height }, accuracy: 0.000001)
  }
  func testShipoutMapRejectsDuplicateAndBrokenContinuations() throws {
    let row = "N=0,0:osc|programs/oscillator|655360|655360|0|655360\n"
    let pages = [DocumentPrintPage(width: 300, height: 400)]
    func stream(_ rows: String) -> String { "SyncTeX Version:1\nNotebook Shipout:1\n{1\n"+rows+"}1\n" }
    XCTAssertThrowsError(try DocumentPrintLocations.decode(stream(row+row), files: [], pages: pages))
    XCTAssertThrowsError(try DocumentPrintLocations.decode(stream(row.replacingOccurrences(of: "|0|655360\n", with: "|655360|1310720\n")), files: [], pages: pages))
    XCTAssertThrowsError(try DocumentPrintLocations.decode(stream(row), files: [], pages: []))
  }
  func testContentCounterRotationAndPDFRotateProjectSourcesAndProgramsTogether() throws {
    func sp(_ value: Double) -> Int { Int((value*65536*72.27/72).rounded()) }
    let text = """
    SyncTeX Version:1
    Notebook Shipout:1
    Input:1:main.tex
    {1
    N+\(sp(150)),\(sp(200)):rotate 90
    (1,3:\(sp(150)),\(sp(250)):\(sp(100)),\(sp(60)),0
    N=\(sp(150)),\(sp(250)):rotated|programs/plot|\(sp(100))|\(sp(60))|0|\(sp(60))
    )
    N-0,0:
    }1
    """
    let page = DocumentPrintPage(mediaBoxWidth: 300, mediaBoxHeight: 400, rotation: 90)
    let result = try DocumentPrintLocations.decode(text, files: [file("main", "main.tex")], pages: [page])
    let source = try XCTUnwrap(result.locations.first), program = try XCTUnwrap(result.interactiveRegions.first)
    XCTAssertEqual(page.width, 400); XCTAssertEqual(page.height, 300)
    XCTAssertEqual(source.x, 200, accuracy: 0.001); XCTAssertEqual(source.y, 140, accuracy: 0.001)
    XCTAssertEqual(source.x, program.x, accuracy: 0.001); XCTAssertEqual(source.y, program.y, accuracy: 0.001)
    XCTAssertEqual(program.width, 100, accuracy: 0.001); XCTAssertEqual(program.height, 60, accuracy: 0.001)
    XCTAssertEqual(DocumentPrintLocations.nearest(in: result.locations, fileID: "main", pageIndex: 0, x: 250, y: 170)?.line, 3)
    let annotation = page.projectPDF(x: 140, y: 200, width: 60, height: 100)
    XCTAssertEqual(annotation.x, source.x, accuracy: 0.001); XCTAssertEqual(annotation.y, source.y, accuracy: 0.001)
    XCTAssertThrowsError(try DocumentPrintLocations.decode(text.replacingOccurrences(of: "rotate 90", with: "unsupported 90"), files: [], pages: [page]))
    XCTAssertThrowsError(try DocumentPrintLocations.decode(text, files: [], pages: [.init(width: 300, height: 400)]))
  }
  func testAllPageRotationsUseTheSameNonzeroMediaOrigin() {
    for rotation in [0, 90, 180, 270] {
      let page = DocumentPrintPage(mediaBoxX: 10, mediaBoxY: 20, mediaBoxWidth: 300, mediaBoxHeight: 400, rotation: rotation)
      let bounds = page.projectPDF(x: 10, y: 20, width: 300, height: 400)
      XCTAssertEqual(bounds.x, 0); XCTAssertEqual(bounds.y, 0)
      XCTAssertEqual(bounds.width, page.width); XCTAssertEqual(bounds.height, page.height)
    }
  }
}

@Suite("Print-map allocation and lazy input ownership", .serialized)
struct DocumentPrintLocationsBudgetTests {
  private let header = "SyncTeX Version:1\nNotebook Shipout:1\n"
  private let page = DocumentPrintPage(width: 300, height: 400)

  @Test func aSingleExtendedGraphemeCannotBypassTheWireLineBound() throws {
    let grapheme = "e" + String(repeating: "\u{301}", count: 5_000)
    #expect(grapheme.count == 1 && grapheme.utf8.count > 8_192)
    // Unknown records still pay their real wire-line scan. Counting Characters
    // would mistake this entire oversized record for one harmless glyph.
    do {
      _ = try DocumentPrintLocations.decode(header + "ignored:" + grapheme + "\n", files: [], pages: [page])
      Issue.record("An ignored long grapheme bypassed the finite line parser")
    } catch let error as CollaborationError { #expect(error.code == "resource_limit") }
  }

  @Test func actualLocationsShareTheOuterCreditAndKeepUnicodeAddressesAndUTF16SourceOffsets() throws {
    let id = "selected/a~😀", path = "chapters/Текст e\u{301}😀.tex", count = 7_000
    let file = DocumentPrintSourceFile(fileID: id, path: path, sha256: String(repeating: "a", count: 64), lineCount: count)
    let records = (1...count).map { "h1,\($0):655360,1310720:1966080,655360,327680\n" }.joined()
    let stream = header + "Input:1:/input/" + path + "\nUnit:1\n{1\n" + records + "}1\n"
    let admitted = try DocumentPrintLocations.decode(stream, files: [file], pages: [page])
    #expect(admitted.locations.count == count)
    #expect(admitted.locations.first?.fileID == id && admitted.locations.last?.path == path)
    #expect(admitted.locations.last?.line == count)
    do {
      _ = try DocumentPrintLocations.decode(stream, files: [file], pages: [page], allocationBytes: 2 * 1_048_576)
      Issue.record("Real retained locations renewed their caller's smaller allocation credit")
    } catch let error as CollaborationError { #expect(error.code == "resource_limit") }
    let source = "A😀e\u{301}\n\n尾🖋️\n"
    let index = DocumentPrintLineIndex(source), exact = (source as NSString).range(of: "尾🖋️").location
    #expect(index.sourceOffset(line: 3) == exact && index.line(sourceOffset: exact) == 3)
  }

  @Test func cancellationBeforeParsingDoesNotFirstMaterializeMillionsOfIgnoredLines() async throws {
    let stream = header + String(repeating: "x\n", count: 4_000_000)
    let page = page
    let elapsed = try await Task.detached { () throws -> Duration in
      withUnsafeCurrentTask { $0?.cancel() }
      let start = ContinuousClock.now
      do {
        _ = try DocumentPrintLocations.decode(stream, files: [], pages: [page])
        Issue.record("A withdrawn parser returned its ignored-line projection")
      } catch is CancellationError { }
      return start.duration(to: .now)
    }.value
    // The old eager split walked and retained four million Substrings before
    // reaching its first cancellation point. This is the actual joined body.
    #expect(elapsed < .milliseconds(500), "The cancelled observer must stop before building the whole line directory")
    print("PRINT_MAP_CANCEL ignored_lines=4000000 actual_join=\(elapsed)")
  }
}
