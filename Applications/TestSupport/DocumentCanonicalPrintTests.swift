import CoreGraphics
import NotebookCore
import NotebookTypesetter
import XCTest
@testable import Notebook

@MainActor
final class DocumentCanonicalPrintTests: XCTestCase {
  func testPaperRasterUsesTheWholePhysicalPageAtEveryPixelDensity() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "text", source: "# Печатный лист\n\nТочный размер текста на бумаге.")])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let resources = SceneRenderResources(profile: .interactive)
    let charge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
    let source = DocumentPrintedSource(artifact: artifact, reservation: charge)
    let page = DocumentPrintedPage(source: source, pageIndex: 0, width: document.paperSize.widthPoints, height: document.paperSize.heightPoints)
    let locations = try artifact.locations()
    let first = try XCTUnwrap(locations.filter { $0.blockID == "text" && $0.width > 20 && $0.height > 5 }.min { $0.y < $1.y })
    for width in [320, 1668] {
      let image = try await page.image(width: width)
      XCTAssertEqual(image.width, width)
      let pixelScale = Double(width) / page.width
      // The first typeset line is at the physical margin, not a miniature PDF
      // centered inside a larger raster. Read the actual Quartz output pixels.
      let rect = CGRect(x: max(0, first.x*pixelScale), y: max(0, first.y*pixelScale),
        width: min(Double(width)-first.x*pixelScale, first.width*pixelScale), height: first.height*pixelScale).integral
      let crop = try XCTUnwrap(image.cropping(to: rect))
      let pixels = try XCTUnwrap(crop.dataProvider?.data) as Data
      XCTAssertTrue(pixels.contains { $0 < 100 }, "Printed line missing at its physical coordinates for density \(width)")
    }
    let cached = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertEqual(artifact.pdf, cached.pdf)
  }

  func testFormulaAndArbitraryLaTeXKeepDistinctSourceContracts() async throws {
    let actor = UUID()
    let formula = DocumentBlock(id: "equation", kind: .latex, source: "x^2+1")
    let tex = DocumentBlock(id: "body", kind: .tex, source: "\\section{Исходник}\nТекст и $x^2$ в одном блоке.")
    let document = DocumentDocument(actor: actor, blocks: [tex, formula])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertTrue(artifact.source.contains("\\section{Исходник}"))
    XCTAssertTrue(artifact.source.contains("\\[x^2+1\\]"))
    XCTAssertEqual(Set(try artifact.locations().map(\.blockID)), ["equation", "body"])
    try artifact.sourceMap.validate(document: document, source: artifact.source, pdf: artifact.pdf)
    XCTAssertLessThanOrEqual(artifact.guestMemoryBytes, 320*1024*1024)
  }

  func testSourceAndPrintedLineUseOnePhysicalReferenceOnBothPaperSizes() async throws {
    for paper: DocumentPaperSize in [.a4, .letter] {
      let text = "\\section{Первый раздел}\nНачальная строка.\n\\newpage\n\\section{Второй раздел}\nПоследняя строка."
      let document = DocumentDocument(actor: UUID(), paperSize: paper, blocks: [.init(id: "body", kind: .tex, source: text)])
      let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
      let resources = SceneRenderResources(profile: .interactive)
      let charge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
      let source = DocumentPrintedSource(artifact: artifact, locations: try artifact.locations(), reservation: charge)
      let offset = (text as NSString).range(of: "Последняя строка").location
      let reference = try XCTUnwrap(source.reference(blockID: "body", sourceOffset: offset))
      XCTAssertEqual(reference.pageIndex, 1)
      XCTAssertNil(reference.elementID, "A block reference would replace the selected line with the whole block")
      XCTAssertEqual(reference.revision, document.contentStamp.revision)
      let region = try XCTUnwrap(reference.region)
      let scale = WorkspaceItemGeometry.document(paper).width / paper.widthPoints
      let mapped = try XCTUnwrap(source.sourceOffset(blockID: "body", pageIndex: 1,
        x: (region.x+region.width/2)/scale, y: (region.y+region.height/2)/scale))
      XCTAssertEqual(mapped, offset)
    }
  }

  func testCancellingTheLastSourceReaderReleasesActualAdmissionWithoutAWebKit() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Лист ждёт памяти.")])
    let resources = SceneRenderResources(profile: .interactive)
    let block = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit-1024, priority: .passive))
    defer { block.release() }
    let source = DocumentSourceSnapshot(document)
    let reader = Task { try await source.printedSource(resources: resources) }
    let deadline = ContinuousClock.now + .seconds(15)
    while resources.pendingDerivedRequestCount == 0, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1)
    reader.cancel()
    do { _ = try await reader.value; XCTFail("Cancelled source returned a printed artifact") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    block.release()
    let recovered = try await source.printedSource(resources: resources)
    XCTAssertFalse(recovered.locations.isEmpty)
  }
}
