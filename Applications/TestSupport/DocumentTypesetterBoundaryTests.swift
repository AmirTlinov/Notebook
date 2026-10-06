import CoreGraphics
import Foundation
import CZlib
import NotebookCore
@testable import NotebookTypesetter
import XCTest

@MainActor
final class DocumentTypesetterBoundaryTests: XCTestCase {
  private var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("NotebookTypesetter") }
  private func document(_ source: String) -> DocumentDocument {
    .init(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: "\\documentclass{article}\n\\usepackage{fontspec}\n\\setmainfont{Libertinus Serif}\n\\begin{document}\n" + source + "\n\\end{document}\n")])
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
    for name in ["fonts.tsv"] {
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
    var cancellationsMS: [Double] = []
    for attempt in 0..<10 {
      // Enter computation without spending the cancellation window loading
      // fontspec. Exercise both short loops and loops with a long straight body.
      let body = attempt.isMultiple(of: 2) ? "" : String(repeating: "\\advance\\count255 by1 ", count: 512)
      let looping = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex",
        source: "\\count255=0\\relax\\loop " + body + "\\count255=0\\relax\\iftrue\\repeat")])
      let task = Task { try await compiler.compile(looping) }
      try await Task.sleep(for: .milliseconds(250))
      let start = ContinuousClock.now
      task.cancel()
      do { _ = try await task.value; XCTFail("An infinite TeX loop completed") }
      catch { XCTAssertTrue(error is CancellationError || error.localizedDescription.contains("cancelled"), error.localizedDescription) }
      let elapsed = start.duration(to: .now)
      XCTAssertLessThan(elapsed, .seconds(2), "Cancellation must join the actual VM, not just hide its result")
      cancellationsMS.append(Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15)
      let next = try await compiler.compile(valid)
      try assertSamePrintedPage(next, initial)
      XCTAssertLessThanOrEqual(next.guestMemoryBytes, 320*1024*1024)
    }
    let measurement = XCTAttachment(string: "Native compiler cancellation and join, alternating short/512-operation loop, milliseconds: \(cancellationsMS)")
    measurement.name = "Ten cancellation joins"; measurement.lifetime = .keepAlways; add(measurement)
    await compiler.trimIdle()
    let cold = try await compiler.compile(valid)
    try assertSamePrintedPage(cold, initial)
  }

  func testMalformedSourceKeepsTheLastSuccessfulArtifactAndReportsItsFile() async throws {
    let compiler = NotebookTypesetter(resources: resources)
    let valid = try await compiler.compile(document("Исходный текст."))
    do { _ = try await compiler.compile(document("\\NotebookUnknownCommand")); XCTFail("Invalid TeX was accepted") }
    catch let error as NotebookTypesetterError {
      XCTAssertTrue(error.diagnostics.contains { $0.fileID == "main" && $0.path == "main.tex" && $0.line >= 5 }, error.localizedDescription)
    }
    XCTAssertTrue(valid.pdf.starts(with: Data("%PDF-".utf8)))
    let next = try await compiler.compile(document("Следующая корректная версия."))
    XCTAssertFalse(next.pdf.isEmpty)
  }

  func testBreakableRequiresSingleColumnFlowButWholeAndBoxedProgramsRemainValid() async throws {
    let compiler = NotebookTypesetter(resources: resources)
    func source(_ body: String, columns: Bool) -> DocumentDocument {
      let main = """
        \\documentclass[\(columns ? "twocolumn" : "onecolumn")]{article}
        \\usepackage[paperwidth=400bp,paperheight=400bp,margin=25bp]{geometry}
        \\usepackage{notebook}
        \\usepackage{multicol}
        \\begin{document}
        \\input{sections/content.tex}
        \\end{document}
        """
      return .init(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: main),
        .init(id: "content", path: "sections/content.tex", source: body)] +
        DocumentTestFiles.program(id: "probe", html: "<p>One executor</p>").files)
    }
    let command = "\\NotebookInteractive[id=probe,width=\\linewidth,height=600bp,breakable]{programs/probe}"
    for (body, columns, line) in [(command, true, 1),
      ("\\begin{multicols}{2}\n" + command + "\n\\end{multicols}", false, 2)] {
      do { _ = try await compiler.compile(source(body, columns: columns)); XCTFail("A second same-page fragment would be lost") }
      catch let error as NotebookTypesetterError {
        XCTAssertTrue(error.diagnostics.contains { $0.fileID == "content" && $0.path == "sections/content.tex" && $0.line == line
          && $0.message.contains("probe: breakable requires single-column flow") }, error.localizedDescription)
      }
    }
    let ordinary = try await compiler.compile(source(command, columns: false))
    XCTAssertGreaterThan(ordinary.interactiveRegions.count, 1)
    XCTAssertEqual(Set(ordinary.interactiveRegions.map(\.pageIndex)).count, ordinary.interactiveRegions.count)
    XCTAssertEqual(ordinary.interactiveRegions.reduce(0) { $0 + $1.height }, 600, accuracy: 0.001)
    let columns = try await compiler.compile(source(#"""
      \NotebookInteractive[id=whole,width=\linewidth,height=50bp]{programs/probe}
      \begin{figure}[ht]
      \NotebookInteractive[id=float,width=\linewidth,height=50bp,breakable]{programs/probe}
      \end{figure}
      \begin{minipage}{\linewidth}
      \NotebookInteractive[id=boxed,width=\linewidth,height=50bp,breakable]{programs/probe}
      \end{minipage}
      """#, columns: true))
    XCTAssertEqual(Set(columns.interactiveRegions.map(\.instanceID)), ["whole", "float", "boxed"])
    XCTAssertEqual(columns.interactiveRegions.count, 3)
    for region in columns.interactiveRegions { XCTAssertEqual(region.height, 50, accuracy: 0.001) }
    XCTAssertFalse(columns.diagnostics.contains { $0.severity == "error" })
  }

  func testPrintReadSetReusesUnchangedPaperAndInvalidatesNegativeProbes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let main = "\\documentclass{article}\n\\begin{document}\n\\input{actual.js}\n\\IfFileExists{optional.tex}{\\input{optional.tex}}{Missing optional input}\n\\end{document}\n"
    let actor = UUID()
    var source = DocumentDocument(actor: actor, files: [
      .init(id: "main", path: "main.tex", source: main),
      .init(id: "actual", path: "actual.js", source: "Actual typeset input."),
      .init(id: "unused", path: "programs/unused/main.js", source: "console.log('one');")])
    let first = try await store.artifact(for: source)
    XCTAssertTrue(first.dependencies.lookups.contains { $0.path == "actual.js" })
    XCTAssertTrue(first.dependencies.lookups.contains { $0.path == "optional.tex" && $0.digest == "missing" })
    source.replaceContent(files: source.files.map { $0.id == "unused" ? $0.replacingSource("console.log('two');") : $0 }, actor: actor)
    let cached = try await NotebookPrintedDocumentStore(resources: resources, directory: directory).artifact(for: source, inputFactory: {
      throw NotebookTypesetterError("A cache hit must not materialize the full compiler namespace")
    })
    XCTAssertEqual(cached.pdf, first.pdf)
    XCTAssertEqual(cached.pixelIdentity, first.pixelIdentity)
    XCTAssertNotEqual(cached.buildID, first.buildID, "The causal editing receipt is rebound to the new source")
    try cached.sourceMap.validate(document: source, source: cached.source, pdf: cached.pdf)
    source.replaceContent(files: source.files.map { $0.id == "actual" ? $0.replacingSource("Changed typeset content, despite its JavaScript extension.") : $0 }, actor: actor)
    var changedSource = DocumentPrintDependencies.Source(source)
    XCTAssertFalse(try first.dependencies.matches(&changedSource, compilerRevision: first.sourceMap.compilerRevision))
    let changed = try await store.artifact(for: source)
    XCTAssertNotEqual(changed.pdf, first.pdf)
    source.replaceContent(files: source.files + [.init(id: "optional", path: "optional.tex", source: "The previously absent branch now exists.")], actor: actor)
    changedSource = .init(source)
    XCTAssertFalse(try changed.dependencies.matches(&changedSource, compilerRevision: changed.sourceMap.compilerRevision))
    let appeared = try await store.artifact(for: source)
    XCTAssertNotEqual(appeared.pdf, changed.pdf)
    XCTAssertTrue(try appeared.locations().contains { $0.fileID == "optional" })
  }

  func testCorruptedSourceMapCacheIsRecompiledRatherThanUsedForEditing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let source = document("\\section{Кеш}\nАдреса принадлежат точной версии.")
    let original = try await store.artifact(for: source)
    let identity = try original.dependencies.identity
    try DocumentPrintCacheFixture.execute(directory, "UPDATE payloads SET synctex=X'666f726569676e206d617070696e67' WHERE identity='\(identity)'")
    let repaired = try await NotebookPrintedDocumentStore(resources: resources, directory: directory).artifact(for: source)
    try assertSamePrintedPage(repaired, original)
    XCTAssertEqual(repaired.syncTeX, original.syncTeX)
    XCTAssertEqual(try DocumentPrintCacheFixture.bytes(directory, "SELECT synctex FROM payloads WHERE identity='\(identity)'"), original.syncTeX)

    let broken = directory.appendingPathComponent("broken-database", isDirectory: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("Interrupted derived database".utf8).write(to: broken.appendingPathComponent("artifacts.sqlite3"))
    let recovered = try await NotebookPrintedDocumentStore(resources: resources, directory: broken).artifact(for: source)
    try assertSamePrintedPage(recovered, original)
    let reopened = try await NotebookPrintedDocumentStore(resources: resources, directory: broken).artifact(for: source, inputFactory: {
      throw NotebookTypesetterError("A damaged cache must repair itself rather than compile on every reopen")
    })
    XCTAssertEqual(reopened.pdf, recovered.pdf)
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
      do { _ = try await compiler.convertSVG(Data(svg.utf8)); XCTFail("Unsupported image was silently accepted: \(body)") }
      catch { XCTAssertFalse(error.localizedDescription.contains(marker)) }
    }
  }

  func testMalformedTinyGzipWithSixteenMiBISIZERefusesCreditBeforeInputOrInflate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("print-adopt-credit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("resources"), revision = String(repeating: "a", count: 64)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data((revision + "\n").utf8).write(to: resources.appendingPathComponent("revision.txt"))
    let source = document("Source stays authored. Жёлтый 😀 e\u{301}.")
    let text = try XCTUnwrap(source.files.first?.source)
    // The PDF/map are valid. The inner gzip is deliberately unusable: a credit
    // failure must dominate inflate, which would allocate its claimed16MiB first.
    let pdf = try blankPDF()
    var gzip = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 0xff, 0xff])
    gzip.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // CRC0; little-endian ISIZE0x01000000.
    let map = try DocumentPrintSourceMap(document: source, source: text, pdf: pdf, compilerRevision: revision)
    let derived = NotebookPortableDocument.Derived(pdf: pdf, syncTeX: gzip, interactiveMap: Data("[]".utf8), sourceMap: map)
    let directory = root.appendingPathComponent("cache")
    let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
    let allowance = NotebookPrintedDocument.CacheAdoptionCost(decodedBytes: 32, projectionBytes: 2 * 1_048_576)
    do {
      try await store.adopt(derived, for: source, input: NotebookTypesetterInput(document: source), allowance: allowance)
      XCTFail("The gzip's claimed16MiB must be refused before allocating its decode buffer")
    } catch let error as NotebookTypesetterError {
      XCTAssertTrue(error.localizedDescription.contains("print_cache_admission_limit"), error.localizedDescription)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Refusal must not initialize the compiler/cache or alter the source")
    XCTAssertEqual(source.files.first?.source, text)
  }

  func testARealTinyGzipWithManyIgnoredLinesUsesSmallProjectionCreditAndPreservesUnicodeSource() throws {
    let source = DocumentDocument(actor: UUID(), files: [.init(id: "selected/a~😀", path: "main.tex", source: "Жёлтый 😀\ne\u{301} source\n尾🖋️\n")])
    let file = try XCTUnwrap(source.files.first)
    let pdf = Data("%PDF-1.7\nfixture".utf8)
    let map = try DocumentPrintSourceMap(document: source, source: file.source, pdf: pdf, compilerRevision: String(repeating: "a", count: 64))
    let text = "SyncTeX Version:1\nNotebook Shipout:1\n" + String(repeating: "x\n", count: 1_000_000)
      + "Input:1:/input/main.tex\nUnit:1\n{1\nh1,3:655360,1310720:1966080,655360,327680\n}1\n"
    let packed = try gzip(Data(text.utf8))
    XCTAssertLessThan(packed.count, 65_536, "The real inner gzip must exercise compression, not a large raw input")
    let projection = try NotebookPrintedDocument.projection(syncTeX: packed, files: map.files,
      pages: [.init(width: 300, height: 400)], allocationBytes: 2 * 1_048_576)
    XCTAssertEqual(projection.locations.count, 1)
    XCTAssertEqual(projection.locations.first?.fileID, file.id)
    XCTAssertEqual(projection.locations.first?.path, file.path)
    XCTAssertEqual(projection.locations.first?.line, 3)
    XCTAssertEqual(source.files.first?.source, "Жёлтый 😀\ne\u{301} source\n尾🖋️\n")
    XCTAssertTrue(projection.interactiveRegions.isEmpty)
  }

  private func gzip(_ input: Data) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY,
      zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NotebookTypesetterError("fixture_gzip_init") }
    defer { deflateEnd(&stream) }
    var output = Data(count: Int(compressBound(uLong(input.count))) + 64)
    let status = output.withUnsafeMutableBytes { destination in
      input.withUnsafeBytes { source in
        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
        stream.avail_in = uInt(source.count)
        stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(destination.count)
        return CZlib.deflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { throw NotebookTypesetterError("fixture_gzip_finish") }
    output.count = Int(stream.total_out)
    return output
  }

  private func blankPDF() throws -> Data {
    let sink = NotebookPDFBuffer(limit: 1_048_576), consumer = try XCTUnwrap(sink.consumer())
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
    return try sink.result()
  }
}
