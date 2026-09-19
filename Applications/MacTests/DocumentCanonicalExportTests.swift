import AppKit
import NotebookCore
import PDFKit
import XCTest
import WebKit
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
    let pdfBytes = try readExportBytes(publication.artifact, store: store)
    XCTAssertEqual(pdfBytes, artifact.pdf)
    XCTAssertEqual(publication.source, artifact.source)
    XCTAssertEqual(try readExportBytes(XCTUnwrap(publication.syncTeX), store: store), artifact.syncTeX)
    XCTAssertTrue(try DocumentPrintNavigation.read(pdfBytes).links.contains { $0.href == "https://example.com" })
  }

  func testStaticPNGKeepsCanonicalInkAndRejectsAMissingPage() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let persistence = NotebookPersistenceQueue(store: store)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "text", source: "# Static image\n\nA real paper with $x^2$.")])
    let cut = try NotebookExportCut(document: document, state: .init(id: document.id, actor: UUID()))
    let publication = try await DocumentCanonicalExport.publication(cut: cut, options: .init(format: .png, pixelWidth: 800),
      jobID: UUID(), store: store, persistence: persistence)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: readExportBytes(publication.artifact, store: store)))
    XCTAssertEqual(bitmap.pixelsWide, 800)
    var dark = 0
    for y in stride(from: 50, to: 220, by: 3) { for x in stride(from: 70, to: 730, by: 3) {
      if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.6 { dark += 1 }
    } }
    XCTAssertGreaterThan(dark, 40, "An empty program overlay cannot hide the typeset page")
    do {
      _ = try await DocumentCanonicalExport.publication(cut: cut, options: .init(format: .png, pageIndex: 9999), jobID: UUID(), store: store, persistence: persistence)
      XCTFail("A missing page cannot be silently clamped")
    } catch let error as CollaborationError { XCTAssertEqual(error.code, "export_page_missing") }
  }

  func testProgramExportFreezesOnlyItsRegionAndKeepsVectorTextAndLinks() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let persistence = NotebookPersistenceQueue(store: store)
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "text", source: "# Vector heading\n\n[An external link](https://example.com)"),
      .interactive(id: "program", html: "<div style='width:100%;height:100px;background:rgb(255,0,0)'></div>", javaScript: "notebook.ready(Promise.resolve());notebook.exportFrame(()=>null)", height: 100)])
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
    let pdfBytes = try readExportBytes(publication.artifact, store: store)
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
  func testRasterExportWaitsForTheExactAuthoredStateAndRefusesUnknownFrames() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let persistence = NotebookPersistenceQueue(store: store)
    let script = """
      const canvas=document.querySelector('canvas'),ctx=canvas.getContext('2d');
      canvas.width=10;canvas.height=10;ctx.fillStyle='blue';ctx.fillRect(0,0,10,10);
      notebook.ready(Promise.resolve());
      notebook.lifecycle({pause(){},checkpoint(){throw Error('No late checkpoint');}});
      notebook.exportFrame(async ({format,state,pixelRatio})=>{
        if(format!=='raster'||!(pixelRatio>0))throw Error('Wrong export extent');
        await new Promise(resolve=>setTimeout(resolve,30));
        const {width,height}=canvas.getBoundingClientRect();canvas.width=Math.round(width*pixelRatio);canvas.height=Math.round(height*pixelRatio);
        if(state.phase!==.625)throw Error('Wrong saved phase '+JSON.stringify(state));
        ctx.fillStyle='red';ctx.fillRect(0,0,canvas.width,canvas.height);
        if(notebook.commit({phase:99}))throw Error('Export must not commit');return null;
      });
      """
    var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "text", source: "# Exact saved phase"),
      .interactive(id: "frame", html: "<canvas style='width:100%;height:100px'></canvas>", javaScript: script, height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    XCTAssertTrue(state.commit(blockID: "frame", value: .object(["phase": .number(0.625)]), actor: UUID()))
    let cut = try NotebookExportCut(document: document, state: state)
    let first = try await DocumentCanonicalExport.publication(cut: cut, options: .init(format: .png, pixelWidth: 1600), jobID: UUID(), store: store, persistence: persistence)
    let bytes = try readExportBytes(first.artifact, store: store), bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
    let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png"); attachment.name = "authored-canvas-frame"; attachment.lifetime = .keepAlways; add(attachment)
    // AppKit converts calibrated PNG red to display RGB (green can be ~0.15);
    // require red dominance, not an untagged byte-space identity.
    var red = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
      if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent > 0.8 && c.blueComponent < 0.3 && c.greenComponent < 0.3 { red += 1 }
    } }
    XCTAssertGreaterThan(red, 500, "Await author completion, not its blue startup frame")
    let repeated = try await DocumentCanonicalExport.publication(cut: cut, options: .init(format: .png, pixelWidth: 1600), jobID: UUID(), store: store, persistence: persistence)
    XCTAssertEqual(repeated.artifact.sha256, first.artifact.sha256, "Same saved frame renders reproducibly")
    document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "unknown", html: "<p>Not an export-ready program</p>", javaScript: "notebook.ready(Promise.resolve())", height: 100)])
    do {
      _ = try await DocumentCanonicalExport.publication(cut: .init(document: document, state: .init(id: document.id, actor: UUID())), options: .init(format: .png), jobID: UUID(), store: store, persistence: persistence)
      XCTFail("A running frame with no author export contract cannot be called the saved state")
    } catch { XCTAssertTrue(String(describing: error).contains("program_export_unavailable"), "\(error)") }
  }

  func testStandaloneHTMLReopensTheRealSoundModelOfflineAtItsSavedPhase() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    defer { try? FileManager.default.removeItem(at: store.root) }
    func source(_ name: String, _ ext: String) throws -> String {
      try String(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "science")), encoding: .utf8)
    }
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let item = try XCTUnwrap(index.createDocument(title: "Standalone sound", actor: actor))
    XCTAssertTrue(board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor))
    let document = DocumentDocument(id: item.id, actor: actor, blocks: [.interactive(id: "sound", html: try source("sound", "html"),
      css: try source("common", "css"), javaScript: try source("models", "js") + "\n" + source("runtime", "js") + "\n" + source("sound", "js"), height: 1000)])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    XCTAssertTrue(state.commit(blockID: "sound", value: .object(["phase": .number(0.625)]), actor: actor))
    try store.saveDocumentWorkspaceBundle(index: index, document: document, state: state, board: board)
    let cut = try store.readTransaction { try NotebookExportCut(document: $0.loadDocument(item.id), state: $0.loadDocumentState(item.id)) }
    let receipt = try await DocumentCanonicalExport.publish(cut: cut, options: .init(format: .html, blockID: "sound"), jobID: UUID(), store: store, persistence: NotebookPersistenceQueue(store: store))
    let url = URL(fileURLWithPath: receipt.artifact.path), bytes = try Data(contentsOf: url)
    XCTAssertEqual(receipt.artifact.mimeType, "text/html"); XCTAssertEqual(receipt.cutSHA256, try cut.sha256)
    let probe = StandaloneProbe(), configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(probe, name: "probe")
    configuration.userContentController.addUserScript(.init(source: """
      if(window!==top)addEventListener('load',async()=>{try{
        await window.notebookProgram.start();const before=notebook.state.phase;
        document.getElementById('quarter').click();const after=notebook.state.phase;
        let isolated=false,offline=false;try{parent.document.body}catch{isolated=true}
        try{await fetch('https://example.com/notebook-export-forbidden')}catch{offline=true}
        webkit.messageHandlers.probe.postMessage({before,after,isolated,offline,paths:document.querySelectorAll('svg path,circle').length});
      }catch(error){webkit.messageHandlers.probe.postMessage({error:String(error)})}});
      """, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 1100), configuration: configuration)
    let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { configuration.userContentController.removeScriptMessageHandler(forName: "probe"); window.orderOut(nil); window.close() }
    web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    let deadline = ContinuousClock.now + .seconds(10)
    while probe.result == nil && .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let result = try XCTUnwrap(probe.result, "Standalone file must really execute inside the offline frame")
    XCTAssertNil(result["error"]); XCTAssertEqual(result["before"] as? Double, 0.625); XCTAssertEqual(result["after"] as? Double, 0.875)
    XCTAssertEqual(result["isolated"] as? Bool, true); XCTAssertEqual(result["offline"] as? Bool, true)
    XCTAssertGreaterThan(result["paths"] as? Int ?? 0, 20)
    XCTAssertEqual(try store.loadDocumentState(item.id), cut.state, "Standalone edits have no Notebook writer capability")
    let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.html"); attachment.name = "offline-sound-saved-phase"; attachment.lifetime = .keepAlways; add(attachment)
    let image = try await web.takeSnapshot(configuration: nil)
    let visual = XCTAttachment(image: image); visual.name = "offline-sound-after-quarter"; visual.lifetime = .keepAlways; add(visual)
    let packaged = DocumentBlock.interactive(id: "package", html: "", programPackage: String(repeating: "a", count: 64), height: 100)
    XCTAssertThrowsError(try NotebookStandaloneExport.document(block: packaged, state: .null)) { error in
      XCTAssertEqual((error as? CollaborationError)?.code, "export_portable_required")
    }
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
    let publication = NotebookExportPublication(cut: cut, source: "Large PDF", artifact: file, log: "", jobID: UUID())
    XCTAssertLessThan(try JSONEncoder().encode(publication).count, 16_384, "No PDF base64 in the publication")
    let prepared = try await Task.detached { try store.prepareDocumentExport(publication) }.value
    let receipt = try await persistence.submit { try $0.publishDocumentExport(prepared) }
    XCTAssertEqual(receipt.artifact.byteCount, Int(file.file.byteCount)); XCTAssertEqual(receipt.artifact.sha256, file.sha256)
    let reopened = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: receipt.artifact.path)))
    XCTAssertEqual(reopened.pageCount, 12)
    XCTAssertNotNil(reopened.page(at: 11)?.thumbnail(of: .init(width: 128, height: 128), for: .mediaBox))
    let actual = try await Task.detached { try NotebookExportFile.inspect(URL(fileURLWithPath: receipt.artifact.path), path: "document.pdf") }.value
    XCTAssertEqual(actual, file)
    print("GUI249 streamed Quartz PDF: \(receipt.artifact.byteCount) bytes; \(file.file.parts.count) parts; metadata \(try JSONEncoder().encode(publication).count) bytes")
  }

}

@MainActor private final class StandaloneProbe: NSObject, WKScriptMessageHandler {
  var result: [String: Any]?
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { result = message.body as? [String: Any] }
}
