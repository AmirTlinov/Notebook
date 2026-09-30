import CoreGraphics
import CryptoKit
import NotebookCore
import NotebookTypesetter
import XCTest
@testable import Notebook

@MainActor
final class DocumentCanonicalPrintTests: XCTestCase {
  private func document(_ body: String, geometry: String = "paperwidth=210mm,paperheight=297mm,margin=25mm") -> DocumentDocument {
    let source = "\\documentclass{article}\n\\usepackage{fontspec}\n\\setmainfont{Libertinus Serif}\n\\usepackage[\(geometry)]{geometry}\n\\begin{document}\n\(body)\n\\end{document}\n"
    return .init(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: source)])
  }
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
    let document = document("Isolated printed cache.")
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

  func testCancelledQueuedRasterDoesNotCancelItsSourceOrLeakTheParserAndAdmission() async throws {
    let document=document("Retained PDF")
    let artifact=try await DocumentCanonicalPrint.store.artifact(for:document)
    let resources=SceneRenderResources(),baseline=resources.reservedBytes
    weak var observedSource:DocumentPrintedSource?
    weak var observedPDF:DocumentPrintedPDF?
    func operation() async throws {
      let charge=try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count,priority:.passive))
      let source=DocumentPrintedSource(artifact:artifact,pdf:.init(artifact.pdf),reservation:charge,
        lineIndices: Dictionary(uniqueKeysWithValues: artifact.document.files.filter { $0.resource == nil }.map { ($0.id, DocumentPrintLineIndex($0.source)) }),
        slots: Dictionary(grouping: artifact.interactiveRegions, by: \.pageIndex))
      observedSource=source;observedPDF=source.pdf
      let page=DocumentPrintedPage(source:source,pageIndex:0,width:artifact.pages[0].width,height:artifact.pages[0].height)
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

  func testPaperRasterUsesTheWholePhysicalPageAtEveryPixelDensity() async throws {
    let document = document("\\section{Печатный лист}\nТочный размер текста на бумаге.")
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let resources = SceneRenderResources(profile: .interactive)
    let charge = try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive))
    let source = DocumentPrintedSource(artifact: artifact, pdf: .init(artifact.pdf), reservation: charge,
        lineIndices: Dictionary(uniqueKeysWithValues: artifact.document.files.filter { $0.resource == nil }.map { ($0.id, DocumentPrintLineIndex($0.source)) }),
        slots: Dictionary(grouping: artifact.interactiveRegions, by: \.pageIndex))
    let page = DocumentPrintedPage(source: source, pageIndex: 0, width: artifact.pages[0].width, height: artifact.pages[0].height)
    let first = try XCTUnwrap(try artifact.locations().filter { $0.fileID == "main" && $0.width > 20 && $0.height > 5 }.min { $0.y < $1.y })
    for width in [320, 1668] {
      let image = try await page.image(width: width)
      XCTAssertEqual(image.width, width)
      let scale = Double(width)/page.width
      let rect = CGRect(x: max(0, first.x*scale), y: max(0, first.y*scale),
        width: min(Double(width)-first.x*scale, first.width*scale), height: first.height*scale).integral
      let crop = try XCTUnwrap(image.cropping(to: rect)), pixels = try XCTUnwrap(crop.dataProvider?.data) as Data
      XCTAssertTrue(pixels.contains { $0 < 100 }, "Printed line missing at its physical coordinates at density \(width)")
    }
    let openings = await source.pdf.openedDocumentCount()
    XCTAssertEqual(openings, 1, "Changing raster density cannot reopen the whole source PDF")
    let cached = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertEqual(artifact.pdf, cached.pdf); XCTAssertEqual(artifact.buildID, cached.buildID)
  }
  func testExactAuthoredSourcesAndFileAwareSyncTeXSurviveCompilationAndCache() async throws {
    let main = "\\documentclass{article}\n\\begin{document}\n\\input{chapters/body}\n\\end{document}\n"
    let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: main),
      .init(id: "chapter", path: "chapters/body.tex", source: "\\section{Source}\nText and $x^2$.\n\\[x^2+1\\]\n")])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertEqual(artifact.source, main)
    XCTAssertTrue(try artifact.locations().contains { $0.fileID == "chapter" && $0.path == "chapters/body.tex" })
    try artifact.sourceMap.validate(document: document, source: artifact.source, pdf: artifact.pdf)
    XCTAssertEqual(Set(artifact.sourceMap.files.map(\.fileID)), ["main", "chapter"])
    XCTAssertLessThanOrEqual(artifact.guestMemoryBytes, 320*1024*1024)
  }
  func testSourceAndPrintedLineUseExactAddressesOnUserDefinedPaper() async throws {
    for geometry in ["paperwidth=210mm,paperheight=297mm,margin=25mm", "paperwidth=180mm,paperheight=240mm,margin=18mm"] {
      let document = document("\\section{Первый раздел}\nНачальная строка.\n\\newpage\n\\section{Второй раздел}\nПоследняя строка.", geometry: geometry)
      let text = try XCTUnwrap(document.files.first).source
      let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
      let resources = SceneRenderResources(profile: .interactive)
      let source = DocumentPrintedSource(artifact: artifact, locations: try artifact.locations(), pdf: .init(artifact.pdf),
        reservation: try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive)),
        lineIndices: Dictionary(uniqueKeysWithValues: artifact.document.files.filter { $0.resource == nil }.map { ($0.id, DocumentPrintLineIndex($0.source)) }),
        slots: Dictionary(grouping: artifact.interactiveRegions, by: \.pageIndex))
      let offset = (text as NSString).range(of: "Последняя строка").location
      let reference = try XCTUnwrap(source.reference(fileID: "main", sourceOffset: offset))
      XCTAssertEqual(reference.pageIndex, 1); XCTAssertNil(reference.elementID)
      XCTAssertEqual(reference.revision, document.contentStamp.revision)
      let region = try XCTUnwrap(reference.region), scale = PhysicalPaper.pointsPerCentimeter*2.54/72
      let mapped = try XCTUnwrap(source.sourceOffset(fileID: "main", pageIndex: 1,
        x: (region.x+region.width/2)/scale, y: (region.y+region.height/2)/scale))
      XCTAssertEqual(mapped, offset)
    }
  }
  func testIndividualPDFPageGeometryIsNotReplacedByA4() async throws {
    let document = document("First.\\clearpage\n\\special{papersize=400bp,300bp}\nSecond.", geometry: "paperwidth=300bp,paperheight=400bp,margin=20bp")
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertEqual(artifact.pages.count, 2)
    XCTAssertEqual(artifact.pages[0].width, 300, accuracy: 0.1); XCTAssertEqual(artifact.pages[0].height, 400, accuracy: 0.1)
    XCTAssertEqual(artifact.pages[1].width, 400, accuracy: 0.1); XCTAssertEqual(artifact.pages[1].height, 300, accuracy: 0.1)
  }
  func testAllEditableStarterTemplatesCompileWithTheirIncludedFiles() async throws {
    for template in DocumentTemplate.allCases {
      let value = DocumentDocument(actor: UUID(), entrypoint: template.entrypoint, files: template.files)
      let printed = try await DocumentCanonicalPrint.store.artifact(for: value)
      XCTAssertFalse(printed.pdf.isEmpty, template.rawValue)
      XCTAssertFalse(printed.pages.isEmpty, template.rawValue)
      XCTAssertFalse(printed.diagnostics.contains { $0.severity == "error" }, template.rawValue)
    }
  }
  func testPDFLandscapeProjectsSourceAndProgramToTheVisiblePixels() async throws {
    let tex = #"""
      \documentclass{article}
      \usepackage[paperwidth=300bp,paperheight=400bp,margin=25bp]{geometry}
      \usepackage{pdflscape}
      \usepackage{xcolor}
      \usepackage{notebook}
      \begin{document}
      Portrait before.
      \newpage
      \begin{landscape}
      \section{Landscape source}
      \noindent\color{red}\fbox{\NotebookInteractive[id=rotated,width=100bp,height=60bp]{programs/probe}}
      \par\color{black}After the live region.
      \end{landscape}
      \end{document}
      """#
    let document = DocumentDocument(actor: UUID(), files: [.init(id: "main", path: "main.tex", source: tex)] +
      DocumentTestFiles.program(id: "probe", html: "<p>Probe</p>").files)
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    XCTAssertEqual(artifact.pages[1].rotation, 90)
    XCTAssertEqual(artifact.pages[1].width, 400); XCTAssertEqual(artifact.pages[1].height, 300)
    let region = try XCTUnwrap(artifact.interactiveRegions.first)
    XCTAssertEqual(region.pageIndex, 1); XCTAssertEqual(region.x, 28.387, accuracy: 0.02)
    XCTAssertEqual(region.y, 52.005, accuracy: 0.02); XCTAssertEqual(region.width, 100, accuracy: 0.001)
    let locations = try artifact.locations()
    let exact = try XCTUnwrap(locations.first { $0.line == 11 && abs($0.x-region.x) < 0.001 && abs($0.width-region.width) < 0.001 })
    XCTAssertEqual(exact.y, region.y, accuracy: 0.001); XCTAssertEqual(exact.height, region.height, accuracy: 0.001)
    let resources = SceneRenderResources(profile: .interactive)
    let source = DocumentPrintedSource(artifact: artifact, locations: locations, pdf: .init(artifact.pdf),
      reservation: try XCTUnwrap(resources.reserveDerivedBytes(artifact.pdf.count, priority: .passive)),
        lineIndices: Dictionary(uniqueKeysWithValues: artifact.document.files.filter { $0.resource == nil }.map { ($0.id, DocumentPrintLineIndex($0.source)) }),
        slots: Dictionary(grouping: artifact.interactiveRegions, by: \.pageIndex))
    let after = (tex as NSString).range(of: "\\par\\color{black}After").location
    let reference = try XCTUnwrap(source.reference(fileID: "main", sourceOffset: after)), selection = try XCTUnwrap(reference.region)
    let scale = PhysicalPaper.pointsPerCentimeter*2.54/72
    XCTAssertEqual(reference.pageIndex, 1)
    XCTAssertEqual(source.sourceOffset(fileID: "main", pageIndex: 1, x: (selection.x+selection.width/2)/scale,
      y: (selection.y+selection.height/2)/scale), after)
    let blue = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    blue.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); blue.fill(.init(x: 0, y: 0, width: 1, height: 1))
    let page = DocumentPrintedPage(source: source, pageIndex: 1, width: 400, height: 300)
    let image = try await page.image(width: 400, overlay: XCTUnwrap(blue.makeImage()))
    XCTAssertEqual(image.width, 400); XCTAssertEqual(image.height, 300)
    func pixel(_ x: Int, _ y: Int) throws -> [UInt8] {
      let crop = try XCTUnwrap(image.cropping(to: .init(x: x, y: y, width: 1, height: 1)))
      let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(crop, in: .init(x: 0, y: 0, width: 1, height: 1))
      return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }
    let inside = try pixel(Int(region.x+region.width/2), Int(region.y+region.height/2))
    let outside = try pixel(Int(region.x+region.width+10), Int(region.y+region.height/2))
    XCTAssertLessThan(inside[0], 10); XCTAssertGreaterThan(inside[2], 245)
    XCTAssertGreaterThan(outside[0], 245, "The overlay must not cover the rest of the rotated page")
  }
  func testImportedPrecompiledDocumentReopensWithoutTeXResourcesOrProgramExecution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-compiled-" + UUID().uuidString)
    let store = NotebookStore(root: root.appendingPathComponent("workspace")), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0, 128, 255]), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try store.stageBlob(data: bytes, expectedHash: hash)
    let resource = NotebookProgramPackage.File(path: "assets/probe.bin", mimeType: "application/octet-stream", byteCount: Int64(bytes.count),
      parts: [.init(sha256: hash, byteCount: bytes.count)])
    var document = DocumentTestFiles.document(actor: actor, contents: [.tex(id: "body", source: "Prepared before transfer."),
      .program(id: "control", html: "<p>Saved illustration</p>", javaScript: "throw Error('Reading an imported PDF cannot execute a program')", height: 120)])
    XCTAssertTrue(document.replaceContent(files: document.files + [.init(id: "binary", path: resource.path, resource: resource)], actor: actor))
    let input = try NotebookTypesetterInput(document: document, readResource: { try store.readDocumentFileBytes($0) })
    let original = try await DocumentCanonicalPrint.store.artifact(for: document, input: input)
    var state = DocumentStateJournal(id: document.id, actor: actor)
    XCTAssertTrue(state.commit(instanceID: "control", value: .object(["phase": .number(0.75)]), actor: actor))
    let cut = try NotebookExportCut(document: document, state: state)
    let data = try store.exportPortableDocument(cut: cut, derived: .init(pdf: original.pdf, syncTeX: original.syncTeX,
      interactiveMap: original.interactiveMap, sourceMap: original.sourceMap))
    let imported = try store.importPortableDocument(data: data, targetBoardID: store.loadIndex().rootBoardID,
      center: .zero, actor: actor, compilerRevision: original.sourceMap.compilerRevision)
    let received = try store.loadDocument(imported.documentID), derived = try XCTUnwrap(imported.derived)
    let resources = root.appendingPathComponent("compiler-identity-only"), cache = root.appendingPathComponent("pages")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data(original.sourceMap.compilerRevision.utf8).write(to: resources.appendingPathComponent("revision.txt"))
    let receiver = NotebookPrintedDocumentStore(resources: resources, directory: cache)
    try await receiver.adopt(derived, for: received, input: .init(document: received, readResource: { try store.readDocumentFileBytes($0) }))
    // A second store proves disk reuse. There is no TeX distribution/format and
    // no binary resolver on this request: recompilation cannot succeed here.
    let reopened = try await NotebookPrintedDocumentStore(resources: resources, directory: cache).artifact(for: received)
    XCTAssertEqual(reopened.pdf, original.pdf); XCTAssertEqual(reopened.syncTeX, original.syncTeX)
    XCTAssertEqual(reopened.pages, original.pages); XCTAssertEqual(reopened.interactiveRegions, original.interactiveRegions)
    XCTAssertEqual(reopened.guestMemoryBytes, 0); XCTAssertEqual(reopened.log, "portable_document_precompiled")
    XCTAssertEqual(reopened.sourceMap.documentID, imported.documentID); XCTAssertNotEqual(reopened.buildID, original.buildID)
    XCTAssertFalse(try reopened.locations().isEmpty)
    XCTAssertEqual(try store.loadDocumentState(imported.documentID).value(for: "control"), state.value(for: "control"))
  }
  func testReadingBookmarksUseAuthoredFileOffsets() async throws {
    let body = (0..<70).map { "\\section{Section \($0)}\nParagraph \($0) with $x^2$. " + String(repeating: "Printed reading positions follow their source. ", count: 7) }.joined(separator: "\n\n")
    let document = document(body), text = try XCTUnwrap(document.files.first).source
    let resources = SceneRenderResources(profile: .interactive), snapshot = DocumentSourceSnapshot(document)
    let printed = try await snapshot.printedSource(resources: resources), layout = try XCTUnwrap(snapshot.layout)
    XCTAssertGreaterThan(layout.pageCount, 3)
    for segment in layout.reading.segments {
      let line = try XCTUnwrap(printed.locations.filter { $0.fileID == segment.fileID && $0.pageIndex == segment.pageIndex }.map(\.line).min())
      let expected = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(line-1).reduce(0) { $0+$1.utf16.count+1 }
      XCTAssertEqual(segment.textOffset, expected)
    }
    XCTAssertGreaterThan(Set(layout.reading.segments.map(\.textOffset)).count, 3)
  }
  func testUnchangedPrintReusesItsParsedMaterialAndRebindsTheCausalReceipt() async throws {
    var document = document("One immutable printed page.")
    let actor = UUID()
    document.replaceContent(files: document.files + [.init(id: "program", path: "programs/control/main.js", source: "let value=1;")], actor: actor)
    let session = DocumentRenderSession(documentID: document.id), resources = SceneRenderResources(profile: .interactive)
    let first = session.source(document), original = try await first.printedSource(resources: resources)
    let charge = resources.reservedBytes
    document.replaceContent(files: document.files.map { $0.id == "program" ? $0.replacingSource("let value=2;") : $0 }, actor: actor)
    let next = session.source(document), rebound = try await next.printedSource(resources: resources)
    XCTAssertTrue(original.pdf === rebound.pdf, "An unrelated program edit cannot reopen and re-index the PDF")
    XCTAssertEqual(original.artifact.pixelIdentity, rebound.artifact.pixelIdentity)
    XCTAssertNotEqual(original.artifact.buildID, rebound.artifact.buildID)
    XCTAssertEqual(resources.reservedBytes, charge, "Shared physical material has one allocation owner")
    try rebound.artifact.sourceMap.validate(document: document, source: rebound.artifact.source, pdf: rebound.artifact.pdf)
  }

  func testCancelledSourceSubscriberLeavesSharedPreparationWithoutWaitingForItsOtherReader() async throws {
    let source = DocumentSourceSnapshot(document("Shared source subscription"))
    let resources = SceneRenderResources(profile: .interactive)
    let held = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit-1024, priority: .passive))
    defer { held.release() }
    let first = Task { try await source.printedSource(resources: resources) }
    let second = Task { try await source.printedSource(resources: resources) }
    defer { first.cancel(); second.cancel() }
    let deadline = ContinuousClock.now + .seconds(15)
    while resources.pendingDerivedRequestCount == 0, .now < deadline { await Task.yield() }
    XCTAssertEqual(source.pendingPreparationReaderCount, 2)
    first.cancel()
    do { _ = try await first.value; XCTFail("Cancelled subscriber returned another reader's artifact") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(source.pendingPreparationReaderCount, 1)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1, "The remaining reader still owns the same admission")
    held.release()
    let printed = try await second.value
    XCTAssertFalse(printed.locations.isEmpty)
    XCTAssertEqual(source.measurementCount, 1)
  }

  func testCancellingLastSourceReaderReleasesAdmissionWithoutAWebKit() async throws {
    let document = document("Лист ждёт памяти."), resources = SceneRenderResources(profile: .interactive)
    let charge = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit-1024, priority: .passive))
    defer { charge.release() }
    let source = DocumentSourceSnapshot(document), reader = Task { try await source.printedSource(resources: resources) }
    let deadline = ContinuousClock.now + .seconds(15)
    while resources.pendingDerivedRequestCount == 0, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1); reader.cancel()
    do { _ = try await reader.value; XCTFail("Cancelled source returned a printed artifact") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0); XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    charge.release()
    let recovered = try await source.printedSource(resources: resources)
    XCTAssertFalse(recovered.locations.isEmpty)
  }
}
