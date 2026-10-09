import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentCutOriginTests: XCTestCase {
  private func region(page: Int, offset: Double = 0) -> DocumentBlockRegion {
    .init(kind: .program, id: "program", pageIndex: page,
      frame: .init(x: 20, y: 20, width: 600, height: 900), sourceOffset: offset)
  }

  private func layout(offset: Double = 900, papers: [DocumentPaperLayout]? = nil) throws -> DocumentLayoutRecord {
    try DocumentLayoutFixture.make(pages: papers ?? Array(repeating: .uncompiled, count: 2),
      regions: [region(page: 0), region(page: 1, offset: offset)])
  }

  func testAContinuationNamesItsSourceCutNotOnlyThePaperRectangle() throws {
    let full = try layout()
    XCTAssertEqual(full.regions(on: 1).first?.sourceOffset, 900)
    XCTAssertEqual(full.programSize("program"), .init(width: 600, height: 1800))
    XCTAssertTrue(full.matches(try layout()))
    for wrongOffset in [0.0, 899.0, 901.0, 1800.0] {
      let wrong = try layout(offset: wrongOffset)
      XCTAssertFalse(full.matches(wrong), "The same paper rectangle cannot substitute another program cut")
      XCTAssertNotEqual(full.regions, wrong.regions)
    }
  }

  func testPhysicalPDFGeometryRemainsPartOfTheAcceptedSource() throws {
    let physical = try layout(), paper = DocumentPaperLayout.uncompiled
    let differentPaper = DocumentPaperLayout(widthPoints: paper.widthPoints.nextUp, heightPoints: paper.heightPoints)
    let other = try layout(papers: [paper, differentPaper])
    XCTAssertFalse(physical.matches(other), "Exact PDF dimensions remain independent of camera projection")
  }

  func testNativeLayoutRejectsInvalidCutOriginsBeforeTheyReachAProgram() throws {
    for offset in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
      XCTAssertThrowsError(try layout(offset: offset))
    }
    XCTAssertThrowsError(try DocumentLayoutFixture.make(pages: [.uncompiled, .uncompiled],
      regions: [region(page: 1, offset: 900), region(page: 0)]), "A page range cannot contain a different page")
  }

  func testARejectedNeighborCannotReplaceTheAcceptedSourceLayout() throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "program", source: "Physical continuation")])
    let source = DocumentSourceSnapshot(document), accepted = try layout()
    try source.acceptPreparedLayout(accepted)
    XCTAssertThrowsError(try source.acceptPreparedLayout(layout(offset: 0)))
    XCTAssertTrue(source.layout === accepted)
    try source.acceptPreparedLayout(layout())
    XCTAssertTrue(source.layout === accepted)
  }
}
