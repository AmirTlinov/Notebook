import AppKit
import NotebookCore
import PDFKit
import XCTest
@testable import Notebook

@MainActor final class DocumentCanonicalExportTests: XCTestCase {
  func testStaticExportReusesTheExactPDFAndItsSourceMapWithoutTypesettingAgain() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let persistence = NotebookPersistenceQueue(store: store)
    let document = DocumentDocument(actor: UUID(), blocks: [.init(id: "body", kind: .tex,
      source: "\\section{Один печатный лист}\nТекст и $x^2$. \\href{https://example.com}{Ссылка}")])
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let publication = try await DocumentCanonicalExport.publication(cut: .init(document: document,
      state: .init(id: document.id, actor: UUID())), jobID: UUID(), store: store, persistence: persistence)
    let pdfBytes = try readExportBytes(publication.pdf, store: store)
    XCTAssertEqual(pdfBytes, artifact.pdf)
    XCTAssertEqual(publication.source, artifact.source)
    XCTAssertEqual(try readExportBytes(XCTUnwrap(publication.syncTeX), store: store), artifact.syncTeX)
    XCTAssertTrue(try DocumentPrintNavigation.read(pdfBytes).links.contains { $0.href == "https://example.com" })
  }

  func testProgramExportFreezesOnlyItsRegionAndKeepsVectorTextAndLinks() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let persistence = NotebookPersistenceQueue(store: store)
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "text", source: "# Vector heading\n\n[An external link](https://example.com)"),
      .interactive(id: "program", html: "<div style='width:100%;height:100px;background:rgb(255,0,0)'></div>", height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    // Deliberately install a later blue frame under the same saved journal
    // token. Exporting a saved cut must not borrow these uncommitted pixels.
    let poison = try XCTUnwrap(CGContext(data: nil, width: Int(ceil(geometry.width*2)), height: Int(ceil(geometry.height*2)),
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    poison.setFillColor(NSColor.blue.cgColor); poison.fill(CGRect(x: 0, y: 0, width: poison.width, height: poison.height))
    let laterImage = NSImage(cgImage: try XCTUnwrap(poison.makeImage()), size: .init(width: geometry.width, height: geometry.height))
    let source = SceneRasterSource.document(id: document.id, token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    XCTAssertTrue(SceneRenderResources.shared.store(laterImage, for: source))
    let publication = try await DocumentCanonicalExport.publication(cut: .init(document: document, state: state), jobID: UUID(), store: store, persistence: persistence)
    let pdfBytes = try readExportBytes(publication.pdf, store: store)
    XCTAssertEqual(publication.cut.state, state)
    XCTAssertTrue(SceneRenderResources.shared.image(for: source) === laterImage, "Saved export does not replace the live cache")
    let pdf = try XCTUnwrap(PDFDocument(data: pdfBytes)), page = try XCTUnwrap(pdf.page(at: 0))
    XCTAssertTrue(page.string?.contains("Vector heading") == true, "Text must remain selectable vector PDF, not a full-page screenshot")
    XCTAssertTrue(try DocumentPrintNavigation.read(pdfBytes).links.contains { $0.href == "https://example.com" })
    let image = page.thumbnail(of: .init(width: 595, height: 842), for: .mediaBox)
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width*4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let pixels = Data(bytes: try XCTUnwrap(context.data), count: cg.width*cg.height*4)
    XCTAssertGreaterThan(stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0+1] < 60 && pixels[$0+2] < 60 }.count, 500)
    let attachment = XCTAttachment(data: pdfBytes, uniformTypeIdentifier: "com.adobe.pdf")
    attachment.name = "saved-red-cut-with-vector-text-not-live-blue"; attachment.lifetime = .keepAlways; add(attachment)
  }
  func testLargeQuartzPDFStreamsThroughPartsAndPublishesWithoutBinaryIPC() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = NotebookPersistenceQueue(store: store)
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let item = try XCTUnwrap(index.createDocument(title: "Large streamed PDF", actor: actor))
    XCTAssertTrue(board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor))
    let document = DocumentDocument(id: item.id, actor: actor, blocks: [.markdown(id: "body", source: "Large PDF")])
    try store.saveDocumentWorkspaceBundle(index: index, document: document, state: .init(id: item.id, actor: actor), board: board)
    let cut = try NotebookExportCut(document: store.loadDocument(item.id), state: store.loadDocumentState(item.id))
    let inputURL = root.appendingPathComponent("input.pdf"), outputURL = root.appendingPathComponent("output.pdf")
    let bytes = try await Task.detached {
      var box = CGRect(x: 0, y: 0, width: 512, height: 512)
      let context = try XCTUnwrap(CGContext(inputURL as CFURL, mediaBox: &box, nil))
      for _ in 0..<12 { context.beginPDFPage(nil); context.endPDFPage() }
      context.closePDF(); return try Data(contentsOf: inputURL)
    }.value
    let composer = try await PrintedPDFComposer.open(bytes, outputURL: outputURL)
    for page in 0..<12 {
      // Incompressible deterministic pixels exercise the actual Quartz sink,
      // not fake PDF bytes or a test-only higher inline limit.
      let image = try await Task.detached {
        var seed = UInt64(page+1), pixels = Data(count: 1024*1024*4)
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
          for offset in stride(from: 0, to: buffer.count, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            buffer[offset] = UInt8(truncatingIfNeeded: seed); buffer[offset+1] = UInt8(truncatingIfNeeded: seed >> 8)
            buffer[offset+2] = UInt8(truncatingIfNeeded: seed >> 16); buffer[offset+3] = 255
          }
        }
        return try XCTUnwrap(CGImage(width: 1024, height: 1024, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
          provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      }.value
      try await composer.append(pageIndex: page, image: image, regions: [.init(x: 0, y: 0, width: 512, height: 512)])
    }
    try await composer.finish()
    let file = try await DocumentCanonicalExport.stage(outputURL, path: "document.pdf", persistence: persistence)
    XCTAssertGreaterThan(file.file.byteCount, 32*1024*1024)
    XCTAssertGreaterThan(file.file.parts.count, 8)
    let publication = NotebookExportPublication(cut: cut, source: "Large PDF", pdf: file, log: "", jobID: UUID())
    XCTAssertLessThan(try JSONEncoder().encode(publication).count, 16_384, "No PDF base64 in the publication")
    let prepared = try await Task.detached { try store.prepareDocumentExport(publication) }.value
    let receipt = try await persistence.submit { try $0.publishDocumentExport(prepared) }
    XCTAssertEqual(receipt.byteCount, Int(file.file.byteCount)); XCTAssertEqual(receipt.pdfSHA256, file.sha256)
    let reopened = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: receipt.pdfPath)))
    XCTAssertEqual(reopened.pageCount, 12)
    XCTAssertNotNil(reopened.page(at: 11)?.thumbnail(of: .init(width: 128, height: 128), for: .mediaBox))
    let actual = try await Task.detached { try NotebookExportFile.inspect(URL(fileURLWithPath: receipt.pdfPath), path: "document.pdf") }.value
    XCTAssertEqual(actual, file)
    print("GUI249 streamed Quartz PDF: \(receipt.byteCount) bytes; \(file.file.parts.count) parts; metadata \(try JSONEncoder().encode(publication).count) bytes")
  }

}
