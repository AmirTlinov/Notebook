import CoreGraphics
import Foundation
import NotebookCore
import NotebookTypesetter
import XCTest

@MainActor
final class DocumentTypesetterBoundaryTests: XCTestCase {
  private var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("NotebookTypesetter") }
  private func document(_ source: String) -> DocumentDocument {
    .init(actor: UUID(), blocks: [.init(id: "body", kind: .tex, source: source)])
  }

  // PDF metadata records compilation time; compare the actual typeset page,
  // not the byte-level creation date or trailer ID of separate compilations.
  private func assertSamePrintedPage(_ left: NotebookPrintedDocument, _ right: NotebookPrintedDocument,
    file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(try left.locations(), try right.locations(), file: file, line: line)
    func pixels(_ data: Data) throws -> Data {
      let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
      let document = try XCTUnwrap(CGPDFDocument(provider)), page = try XCTUnwrap(document.page(at: 1))
      let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 850, bitsPerComponent: 8, bytesPerRow: 2400,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 850))
      context.drawPDFPage(page)
      return Data(bytes: try XCTUnwrap(context.data), count: 2400*850)
    }
    XCTAssertEqual(try pixels(left.pdf), try pixels(right.pdf), file: file, line: line)
  }

  func testPathOnlySVGDoesNotOpenTheTeXDistributionOrFormat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vector-only-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // The unchanged image kernel still has its pinned font metadata. No TeX
    // format or archive exists: opening either one makes this conversion fail.
    for name in ["fonts.tsv", "notebook-markup.js"] {
      try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: root.appendingPathComponent(name))
    }
    let compiler = NotebookTypesetter(resources: root)
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='120' height='80'><path d='M10 10H100V70H10Z' fill='red' opacity='.5'/></svg>".utf8)
    for _ in 0..<2 {
      let pdf = try await compiler.convertSVG(svg)
      let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData)), document = try XCTUnwrap(CGPDFDocument(provider))
      XCTAssertEqual(document.numberOfPages, 1)
      XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 120, height: 80))
      await compiler.trimIdle()
    }
    do { _ = try await compiler.compile(document("A real document still requires TeX resources.")); XCTFail("Missing TeX was silently substituted") }
    catch { XCTAssertFalse(error is CancellationError) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("texlive.zip").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("latex.fmt").path))
    // A failed document cannot poison the independent data-only image job.
    let recovered = try await compiler.convertSVG(svg)
    XCTAssertTrue(recovered.starts(with: Data("%PDF-".utf8)))
  }

  func testSVGTextStillUsesPinnedFontsRatherThanSilentlyOmittingThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-svg-fonts-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.copyItem(at: resources.appendingPathComponent("fonts.tsv"), to: root.appendingPathComponent("fonts.tsv"))
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='240' height='60'><text x='5' y='40' font-family='Libertinus Sans' font-size='28'>Жёлтый лист</text></svg>".utf8)
    do { _ = try await NotebookTypesetter(resources: root).convertSVG(svg); XCTFail("Missing pinned font was silently omitted") }
    catch { XCTAssertFalse(error is CancellationError) }
    let pdf = try await NotebookTypesetter(resources: resources).convertSVG(svg)
    let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
    let document = try XCTUnwrap(CGPDFDocument(provider)), page = try XCTUnwrap(document.page(at: 1))
    let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 60, bitsPerComponent: 8, bytesPerRow: 240*4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.drawPDFPage(page)
    let bytes = UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 240*60*4)
    XCTAssertGreaterThan(stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 100 }.count, 300,
      "The produced PDF must contain painted Cyrillic text, not merely a page")
  }

  func testTenCancelledCompilationsRecoverWithoutRestartOrASecondEngine() async throws {
    let compiler = NotebookTypesetter(resources: resources)
    let valid = document("\\section{Восстановление}\nТекст и $x^2$ остаются векторными.")
    let initial = try await compiler.compile(valid)
    for _ in 0..<10 {
      let task = Task { try await compiler.compile(document("\\loop\\iftrue\\repeat")) }
      try await Task.sleep(for: .milliseconds(250))
      let start = ContinuousClock.now
      task.cancel()
      do { _ = try await task.value; XCTFail("An infinite TeX loop completed") }
      catch { XCTAssertTrue(error is CancellationError || error.localizedDescription.contains("cancelled"), error.localizedDescription) }
      XCTAssertLessThan(start.duration(to: .now), .seconds(2), "Cancellation must join the actual VM, not just hide its result")
      let next = try await compiler.compile(valid)
      try assertSamePrintedPage(next, initial)
      XCTAssertLessThanOrEqual(next.guestMemoryBytes, 320*1024*1024)
    }
    await compiler.trimIdle()
    let cold = try await compiler.compile(valid)
    try assertSamePrintedPage(cold, initial)
  }

  func testMalformedSourceKeepsTheLastSuccessfulArtifactAndReportsItsBlock() async throws {
    let compiler = NotebookTypesetter(resources: resources)
    let valid = try await compiler.compile(document("Исходный текст."))
    do { _ = try await compiler.compile(document("\\NotebookUnknownCommand")); XCTFail("Invalid TeX was accepted") }
    catch let error as NotebookTypesetterError {
      XCTAssertTrue(error.diagnostics.contains { $0.blockID == "body" }, error.localizedDescription)
    }
    XCTAssertTrue(valid.pdf.starts(with: Data("%PDF-".utf8)))
    let next = try await compiler.compile(document("Следующая корректная версия."))
    XCTAssertFalse(next.pdf.isEmpty)
  }

  func testCorruptedSourceMapCacheIsRecompiledRatherThanUsedForEditing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let source = document("\\section{Кеш}\nАдреса принадлежат точной версии.")
    let original = try await store.artifact(for: source)
    let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    let map = folder.appendingPathComponent("document.synctex.gz")
    try Data("foreign mapping".utf8).write(to: map)
    let repaired = try await store.artifact(for: source)
    try assertSamePrintedPage(repaired, original)
    XCTAssertEqual(repaired.syncTeX, original.syncTeX)
    XCTAssertEqual(try Data(contentsOf: map), original.syncTeX)
  }

  func testQuartzPDFSinkRefusesWritesBeyondItsAdmittedBudget() throws {
    let sink = NotebookPDFBuffer(limit: 32), consumer = try XCTUnwrap(sink.consumer())
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(box)
    context.endPDFPage(); context.closePDF()
    XCTAssertThrowsError(try sink.result())
  }

  func testCompilerCannotReadHostFilesOrSilentlyDropExternalSVGContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("outside.tex"), marker = "PRIVATE"+UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try Data("\\typeout{\(marker)}".utf8).write(to: path)
    let compiler = NotebookTypesetter(resources: resources)
    do { _ = try await compiler.compile(document("Probe. \\input{\(path.path)}")); XCTFail("TeX read outside its virtual filesystem") }
    catch { XCTAssertFalse(error.localizedDescription.contains(marker)) }
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "\\typeout{\(marker)}")
    for body in ["<foreignObject width='20' height='20'><div xmlns='http://www.w3.org/1999/xhtml'>Cannot vanish</div></foreignObject>",
      "<style>@import url(https://example.org/print.css);</style>", "<image href='\(path.absoluteString)'/>"] {
      let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'>\(body)</svg>"
      let source = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "image", source:
        "<img src='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'>")])
      do { _ = try await compiler.compile(source); XCTFail("Unsupported image was silently accepted: \(body)") }
      catch { XCTAssertFalse(error.localizedDescription.contains(marker)) }
    }
  }
}
