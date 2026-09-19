import CoreGraphics
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class DocumentLargeSourceTests: XCTestCase {
  private func illustratedBook() -> DocumentDocument {
    let path = (0..<12_000).map { "L\($0 % 451).\($0 % 10),\($0 % 157).\(($0 + 3) % 10)" }.joined(separator: " ")
    let blocks: [DocumentBlock] = (0..<140).map { index in
      let source: String
      if index % 4 == 3 {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='451' height='158' viewBox='0 0 451 158'><path d='M0,0 \(path)' fill='none' stroke='#173d69' stroke-width='0.02'/><text x='20' y='40'>Figure \(index)</text></svg>"
        source = "<div><h2>Figure \(index)</h2><img width='451' height='158' src='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'><p>Measured illustration \(index).</p></div>"
      } else {
        let formulas = (0..<4).map { "\\(x_{\(index),\($0)}=\\frac{a^2+b^2}{1+e^{-t}}\\)" }.joined(separator: " ")
        let paragraph = "<p>Source \(index): A measured paragraph describes a state transition, its physical address, and an immutable result. \(formulas)</p>"
        source = "<div><h2>Chapter \(index)</h2>" + String(repeating: paragraph, count: 4) + "</div>"
      }
      return .markdown(id: "part-\(index)", source: source)
    }
    return DocumentDocument(actor: UUID(), blocks: blocks)
  }


  func testLargeIllustratedBookKeepsOnePrintArtifactAndRastersOnlyRequestedPages() async throws {
    let document = illustratedBook()
    XCTAssertGreaterThan(document.blocks.reduce(0) { $0 + $1.source.utf8.count }, 6*1024*1024)
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
        width: document.paperSize.widthPoints, height: document.paperSize.heightPoints)
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
