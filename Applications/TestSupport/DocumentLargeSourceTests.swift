import CoreGraphics
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class DocumentLargeSourceTests: XCTestCase {
  private func illustratedBook() -> DocumentDocument {
    let comments = String(repeating: "% Immutable source data retained alongside the publication.\n", count: 950)
    let sections: [DocumentTestFiles] = (0..<140).map { index in
      let formula = "\\(x_{\(index)}=\\frac{a^2+b^2}{1+e^{-t}}\\)"
      let text = "\\section{Chapter \(index)}\n" + String(repeating:
        "A measured paragraph describes a state transition, its physical address, and an immutable result. " + formula + "\\par\n", count: 8)
      let figure = index % 4 == 3 ? "\\begin{figure}[h]\\centering\\rule{200bp}{60bp}\\caption{Measured illustration \(index)}\\end{figure}\n" : ""
      return .tex(id: "part-\(index)", source: comments + text + figure)
    }
    return DocumentTestFiles.document(actor: UUID(), contents: sections)
  }


  func testLargeIllustratedBookKeepsOnePrintArtifactAndRastersOnlyRequestedPages() async throws {
    let document = illustratedBook()
    XCTAssertGreaterThan(document.files.reduce(0) { $0 + $1.source.utf8.count }, 6*1024*1024)
    let resources = SceneRenderResources(profile: .interactive)
    let source = DocumentSourceSnapshot(document), start = ContinuousClock.now
    let printed = try await source.printedSource(resources: resources)
    let elapsed = start.duration(to: .now)
    let layout = try XCTUnwrap(source.layout)
    XCTAssertGreaterThan(layout.pageCount, 30)
    XCTAssertLessThan(elapsed, .seconds(30))
    XCTAssertEqual(source.measurementCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Typesetting cannot borrow a page's live program executor")
    var first: Data?
    for index in [0, layout.pageCount-1, layout.pageCount/2, 0] {
      let page = DocumentPrintedPage(source: printed, pageIndex: index,
        width: printed.artifact.pages[index].width, height: printed.artifact.pages[index].height)
      let image = try await page.image(width: 360)
      let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
      XCTAssertTrue(pixels.contains { $0 < 100 }, "The requested physical page must contain actual printed ink")
      if index == 0 { if let first { XCTAssertEqual(pixels, first) } else { first = pixels } }
    }
    XCTAssertTrue(source.retainedPageIndices.isEmpty, "Reading PDF pages does not accumulate bridge packets or WebKits")
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.passiveByteLimit)
    let result = XCTAttachment(string: "canonicalReady=\(elapsed), pages=\(layout.pageCount), pdfBytes=\(printed.artifact.pdf.count), peakDerivedBytes=\(resources.peakAccountedBytes)")
    result.name = "Canonical illustrated book"; result.lifetime = .keepAlways; add(result)
  }
}
