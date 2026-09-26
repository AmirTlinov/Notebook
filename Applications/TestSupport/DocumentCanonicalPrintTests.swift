import CoreGraphics
import NotebookCore
import NotebookTypesetter
import XCTest
@testable import Notebook

@MainActor
final class DocumentCanonicalPrintTests: XCTestCase {
  func testPrintCacheDirectoryBelongsToTheRunningApplicationBundle() throws {
    let userCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let bundle = try XCTUnwrap(Bundle.main.bundleIdentifier)
    XCTAssertEqual(DocumentCanonicalPrint.cacheDirectory,
      userCaches.appendingPathComponent(bundle, isDirectory: true)
        .appendingPathComponent("NotebookPrintedPages", isDirectory: true))
    let identities = ["com.amirtlinov.notebook", "com.amirtlinov.notebook.mac",
      "com.amirtlinov.notebook.architecture-tests", "com.amirtlinov.notebook.mac.architecture-tests",
      "com.amirtlinov.notebook.acceptance", "com.amirtlinov.notebook.mac.acceptance.0123456789ab",
      "com.amirtlinov.notebook.mac.acceptance.abcdef012345"]
    XCTAssertTrue(NotebookAcceptanceConfiguration.isAcceptanceBundle(identities[5], role: .mac))
    XCTAssertTrue(NotebookAcceptanceConfiguration.isAcceptanceBundle(identities[6], role: .mac))
    let paths = identities.map { DocumentCanonicalPrint.cacheDirectory(bundleIdentifier: $0, under: userCaches) }
    XCTAssertEqual(Set(paths).count, identities.count,
      "Production, native QA and separate admitted acceptance bundles cannot share an eviction root")
    XCTAssertFalse(paths.contains(userCaches.appendingPathComponent("NotebookPrintedPages", isDirectory: true)))
  }

  func testPrintCacheSaveAndEvictionCannotReachAnotherApplicationOrTheLegacyDirectory() async throws {
    let fm = FileManager.default
    let userCaches = fm.temporaryDirectory.appendingPathComponent("print-isolation-" + UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: userCaches) }
    let identities = ["com.amirtlinov.notebook.mac", "com.amirtlinov.notebook.mac.architecture-tests",
      "com.amirtlinov.notebook.mac.acceptance.0123456789ab"]
    let directories = identities.map { DocumentCanonicalPrint.cacheDirectory(bundleIdentifier: $0, under: userCaches) }
    let legacy = userCaches.appendingPathComponent("NotebookPrintedPages", isDirectory: true)
    // One old sparse entry exceeds the unchanged 128 MiB budget. This exercises
    // the real save/evict route with three compilations, not 100 large documents.
    func oldEntry(in directory: URL) throws -> URL {
      let folder = directory.appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("pressure.bin")
      XCTAssertTrue(fm.createFile(atPath: file.path, contents: nil))
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      try handle.truncate(atOffset: 129 * 1024 * 1024)
      try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: folder.path)
      return file
    }
    let oldFiles = try directories.map(oldEntry)
    let legacyFile = try oldEntry(in: legacy)
    let resources = Bundle.main.resourceURL!.appendingPathComponent("NotebookTypesetter", isDirectory: true)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Isolated printed cache.")])
    var saved: [(URL, Data)] = []
    for (index, directory) in directories.enumerated() {
      let store = NotebookPrintedDocumentStore(resources: resources, directory: directory)
      let artifact = try await store.artifact(for: document)
      XCTAssertTrue(artifact.pdf.starts(with: Data("%PDF-".utf8)))
      XCTAssertFalse(fm.fileExists(atPath: oldFiles[index].path), "This application's actual eviction ran")
      for other in oldFiles.dropFirst(index + 1) {
        XCTAssertTrue(fm.fileExists(atPath: other.path), "A sibling's older entry was not evicted")
      }
      XCTAssertTrue(fm.fileExists(atPath: legacyFile.path), "No migration, eviction or deletion of the old shared cache")
      let folder = try XCTUnwrap(fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
      let pdf = folder.appendingPathComponent("document.pdf")
      XCTAssertEqual(try Data(contentsOf: pdf), artifact.pdf)
      saved.append((pdf, artifact.pdf))
      let cached = try await store.artifact(for: document)
      XCTAssertEqual(cached.pdf, artifact.pdf)
      XCTAssertEqual(cached.syncTeX, artifact.syncTeX)
    }
    for (path, expected) in saved { XCTAssertEqual(try Data(contentsOf: path), expected) }
    XCTAssertTrue(fm.fileExists(atPath: legacyFile.path))
  }

  func testPaperRasterUsesTheWholePhysicalPageAtEveryPixelDensity() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "text", source: "# Печатный лист\n\nТочный размер текста на бумаге.")])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let resources = SceneRenderResources(profile: .interactive)
    let charge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
    let source = DocumentPrintedSource(artifact: artifact, pdf: .init(artifact.pdf), reservation: charge)
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
    let openings=await source.pdf.openedDocumentCount()
    XCTAssertEqual(openings,1,"Changing raster density cannot reopen the whole source PDF")
    let cached = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertEqual(artifact.pdf, cached.pdf)
  }

  func testCancelledQueuedRasterDoesNotCancelItsSourceOrLeakTheParserAndAdmission() async throws {
    let document=DocumentDocument(actor:UUID(),blocks:[.markdown(id:"body",source:"Retained PDF")])
    let artifact=try await DocumentCanonicalPrint.store.artifact(for:document)
    let resources=SceneRenderResources(),baseline=resources.reservedBytes
    weak var observedSource:DocumentPrintedSource?
    weak var observedPDF:DocumentPrintedPDF?
    func operation() async throws {
      let charge=try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count,priority:.passive))
      let source=DocumentPrintedSource(artifact:artifact,pdf:.init(artifact.pdf),reservation:charge)
      observedSource=source;observedPDF=source.pdf
      let page=DocumentPrintedPage(source:source,pageIndex:0,width:document.paperSize.widthPoints,height:document.paperSize.heightPoints)
      let entered=expectation(description:"The source Quartz executor is occupied"),release=DispatchSemaphore(value:0)
      let blocker=Task { try await source.pdf.perform { _,_ in
        entered.fulfill();release.wait()
      } }
      defer { release.signal() }
      await fulfillment(of:[entered],timeout:2)
      let cancelled=Task { try await page.image(width:160) }
      let deadline=ContinuousClock.now + .seconds(2)
      while source.pdf.pendingOperationCount < 2,ContinuousClock.now < deadline { await Task.yield() }
      XCTAssertEqual(source.pdf.pendingOperationCount,2,"The cancelled raster is queued behind the active Quartz operation")
      cancelled.cancel();release.signal()
      try await blocker.value
      do { _ = try await cancelled.value;XCTFail("Revoked raster returned pixels") }
      catch { XCTAssertTrue(error is CancellationError,"\(error)") }
      let image=try await page.image(width:160)
      XCTAssertEqual(image.width,160,"Cancelling one reader cannot cancel the retained source")
      let openings=await source.pdf.openedDocumentCount()
      XCTAssertEqual(openings,1)
    }
    try await operation()
    let deadline=ContinuousClock.now + .seconds(2)
    while (observedSource != nil || observedPDF != nil),ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertNil(observedSource,"No global print-source cache retains the export")
    XCTAssertNil(observedPDF,"The Quartz executor and parsed PDF end with their last operation owner")
    XCTAssertEqual(resources.reservedBytes,baseline)
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
      let source = DocumentPrintedSource(artifact: artifact, locations: try artifact.locations(), pdf: .init(artifact.pdf), reservation: charge)
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

  func testMarkdownParagraphMapsToItsAuthoredOffsetNotTheGeneratedTeXLine() async throws {
    let text = "# Heading\n\nFirst $x^2$.\n\nRepeated paragraph.\n\nRepeated paragraph.\n\nLast paragraph."
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: text)])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let resources = SceneRenderResources(profile: .interactive)
    let source = DocumentPrintedSource(artifact: artifact, locations: try artifact.locations(), pdf: .init(artifact.pdf),
      reservation: try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive)))
    let offset = (text as NSString).range(of: "Last paragraph").location
    let reference = try XCTUnwrap(source.reference(blockID: "body", sourceOffset: offset))
    let region = try XCTUnwrap(reference.region), scale = WorkspaceItemGeometry.document(.a4).width / DocumentPaperSize.a4.widthPoints
    XCTAssertEqual(source.sourceOffset(blockID: "body", pageIndex: 0,
      x: (region.x+region.width/2)/scale, y: (region.y+region.height/2)/scale), offset)
  }

  func testReadingBookmarksUseTheSameAuthoredParagraphOffsetsAsTheEditor() async throws {
    let text = (0..<70).map { "## Section \($0)\n\nParagraph \($0) with $x^2$. " + String(repeating: "Printed reading positions follow their source. ", count: 7) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: text)])
    let resources = SceneRenderResources(profile: .interactive)
    let snapshot = DocumentSourceSnapshot(document)
    let printed = try await snapshot.printedSource(resources: resources)
    let layout = try XCTUnwrap(snapshot.layout)
    let range = try XCTUnwrap(printed.artifact.sourceMap.ranges.first)
    XCTAssertGreaterThan(layout.pageCount, 3)
    for segment in layout.reading.segments {
      let line = try XCTUnwrap(printed.locations.filter { $0.blockID == segment.blockID && $0.pageIndex == segment.pageIndex }.map(\.generatedLine).min())
      let offset = DocumentPrintLocations.sourceOffset(line: line, range: range, source: text)
      XCTAssertEqual(segment.textOffset, offset, "A bookmark must not interpret a generated TeX line as a Markdown line")
    }
    XCTAssertGreaterThan(Set(layout.reading.segments.map(\.textOffset)).count, 3)
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
