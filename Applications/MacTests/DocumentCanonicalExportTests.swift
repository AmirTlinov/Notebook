import AppKit
import NotebookCore
import PDFKit
import XCTest
@testable import Notebook

@MainActor final class DocumentCanonicalExportTests: XCTestCase {
  func testStaticExportReusesTheExactPDFAndItsSourceMapWithoutTypesettingAgain() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.init(id: "body", kind: .tex,
      source: "\\section{Один печатный лист}\nТекст и $x^2$. \\href{https://example.com}{Ссылка}")])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let publication = try await DocumentCanonicalExport.publication(document: document,
      state: .init(id: document.id, actor: UUID()), jobID: UUID())
    XCTAssertEqual(publication.pdf, artifact.pdf)
    XCTAssertEqual(publication.source, artifact.source)
    XCTAssertEqual(publication.syncTeX, artifact.syncTeX)
    XCTAssertTrue(try DocumentPrintNavigation.read(publication.pdf).links.contains { $0.href == "https://example.com" })
  }

  func testProgramExportFreezesOnlyItsRegionAndKeepsVectorTextAndLinks() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "text", source: "# Vector heading\n\n[An external link](https://example.com)"),
      .interactive(id: "program", html: "<div style='width:100%;height:100px;background:rgb(255,0,0)'></div>", height: 100)])
    let publication = try await DocumentCanonicalExport.publication(document: document,
      state: .init(id: document.id, actor: UUID()), jobID: UUID())
    let pdf = try XCTUnwrap(PDFDocument(data: publication.pdf)), page = try XCTUnwrap(pdf.page(at: 0))
    XCTAssertTrue(page.string?.contains("Vector heading") == true, "Text must remain selectable vector PDF, not a full-page screenshot")
    XCTAssertTrue(try DocumentPrintNavigation.read(publication.pdf).links.contains { $0.href == "https://example.com" })
    let image = page.thumbnail(of: .init(width: 595, height: 842), for: .mediaBox)
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width*4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let pixels = Data(bytes: try XCTUnwrap(context.data), count: cg.width*cg.height*4)
    XCTAssertGreaterThan(stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0+1] < 60 && pixels[$0+2] < 60 }.count, 500)
  }
}
