import Foundation
import CryptoKit
import NotebookCore
import WebKit
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor
final class DocumentLargeSourceTests: XCTestCase {
  @MainActor private struct Surface {
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    #if os(iOS)
    let window: UIWindow
    #else
    let window: NSWindow
    #endif
    func close() {
      coordinator.invalidate()
      #if os(iOS)
      window.isHidden = true; window.rootViewController = nil
      #else
      window.orderOut(nil); window.close()
      #endif
    }
  }

  /// Synthetic source, not a copy of the user's book: 140 blocks, 35 distinct
  /// embedded vector illustrations, 1680 formulas and more than six MiB of text.
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

  private func surface(_ document: DocumentDocument, _ state: DocumentStateJournal,
    resources: SceneRenderResources) throws -> Surface {
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    update(coordinator, document, state, page: 0)
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = NotebookPreparationWindow(windowScene: scene), controller = UIViewController()
    window.frame = .init(x: 0, y: 0, width: size.width, height: size.height)
    controller.view = host; window.rootViewController = controller; window.isHidden = false
    host.frame = window.bounds; host.layoutIfNeeded()
    #else
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    #endif
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: true, priority: .currentPage)
    return Surface(coordinator: coordinator, host: host, window: window)
  }

  private func update(_ coordinator: DocumentWebCoordinator, _ document: DocumentDocument,
    _ state: DocumentStateJournal, page: Int) {
    coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
  }

  func testLargeIllustratedMathBookColdMountsAndTurnsToDistantPhysicalPagesWithinTheExistingDeadline() async throws {
    let document = illustratedBook(), state = DocumentStateJournal(id: document.id, actor: UUID())
    XCTAssertEqual(document.blocks.count, 140)
    XCTAssertGreaterThan(document.blocks.reduce(0) { $0 + $1.source.utf8.count }, 6 * 1024 * 1024)
    let resources = SceneRenderResources(profile: .interactive), start = ContinuousClock.now
    let surface = try surface(document, state, resources: resources)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let elapsed = start.duration(to: .now)
    XCTAssertLessThan(elapsed, .seconds(8), "The production preparation deadline is not enlarged for a book")
    let source = try XCTUnwrap(surface.coordinator.payload?.source), layout = try XCTUnwrap(source.layout)
    XCTAssertGreaterThan(layout.pageCount, 30)
    let web = try XCTUnwrap(surface.coordinator.webView)
    var first: Data?
    for index in [0, layout.pageCount - 1, layout.pageCount / 2, 0] {
      update(surface.coordinator, document, state, page: index)
      try await ready(surface.coordinator)
      let value = try await evaluate("""
        const root=document.getElementById('document'), receipt=notebookRenderer.pageReceipt();
        if(receipt.pageIndex!==index || receipt.layoutScope!=='page')throw Error('Wrong physical page');
        if(document.querySelector('.document-layout-preparation'))throw Error('Whole book DOM retained');
        if(document.querySelectorAll('.paper-sheet').length!==1)throw Error('More than one physical paper');
        if(!root.textContent.trim() || !root.querySelector('img,mjx-container'))throw Error('Blank book page');
        if([...root.querySelectorAll('img')].some(image=>!image.complete||!image.naturalWidth))throw Error('Undecoded illustration');
        return JSON.stringify({index,characters:root.textContent.length,math:root.querySelectorAll('mjx-container').length,images:root.querySelectorAll('img').length,work:receipt.work});
        """, arguments: ["index": index], web: web)
      let details = XCTAttachment(string: value); details.name = "Large book page \(index)"; details.lifetime = .keepAlways; add(details)
      let pixels = try await capture(web, name: "Large book physical page \(index)")
      let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
      let characters = try XCTUnwrap(metadata["characters"] as? Int)
      // A sparse final illustration has less ink than a full text page. Tie
      // this blank-frame control to its content, not an arbitrary page quota.
      XCTAssertGreaterThanOrEqual(stride(from: 0, to: pixels.count, by: 4).filter {
        pixels[$0] < 150 && pixels[$0 + 1] < 150 && pixels[$0 + 2] < 150 && pixels[$0 + 3] > 200
      }.count, characters, "An accepted layout must paint actual text, formulas and illustrations")
      if index == 0 {
        if let first {
          guard pixels == first else { throw NSError(domain: "NotebookLargeBookPixels", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Returning to the same fragment changed its actual pixels"]) }
        }
        else { first = pixels }
      }
      XCTAssertTrue(surface.coordinator.webView === web)
      XCTAssertTrue(surface.coordinator.payload?.source === source)
      XCTAssertEqual(resources.activeWebSurfaceCount, 1)
      XCTAssertEqual(resources.pendingWebRequestCount, 0)
    }
    XCTAssertEqual(source.preparationCount, 1); XCTAssertEqual(source.encodingCount, 1)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit / 2,
      "Book preparation must leave the protected Pencil reserve intact")
    let measurement = XCTAttachment(string: "coldReady=\(elapsed), pages=\(layout.pageCount), peakAccountedBytes=\(resources.peakAccountedBytes)")
    measurement.name = "Large book native preparation"; measurement.lifetime = .keepAlways; add(measurement)
    surface.close()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testEachPhysicalFormulaOwnsItsGlyphDefinitionsBeforeAttachment() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "math", source:
      #"Local $x^2+\frac{a}{b}+x^2$ and $\int_0^1 t^2\,dt$."#)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = try surface(document, state, resources: SceneRenderResources())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), web = try XCTUnwrap(surface.coordinator.webView)
    let report = try await evaluate("""
      const source=JSON.parse(encoded), renderer=notebookRenderer;
      await renderer.beginSourcePreparation(source);
      try {
        renderer.readPreparedPacket(source.key,null);
        const measured=document.querySelector('.document-layout-preparation');
        const original=new Set([...measured.querySelectorAll('mjx-container [id]')].map(node=>node.id));
        if(original.size===0)throw Error('Fixture did not create a local MathJax cache');
        renderer.preparePagePacket(source.key,0);
        const packet=JSON.parse(renderer.readPreparedPacket(source.key,0)), template=document.createElement('template');
        template.innerHTML=packet.html;
        let definitions=0,references=0;
        const all=new Set();
        for(const formula of template.content.querySelectorAll('mjx-container')) {
          const local=new Map([...formula.querySelectorAll('[id]')].map(node=>[node.id,node]));
          for(const [id,node] of local) {
            if(original.has(id)||all.has(id))throw Error('Physical glyph aliases source or neighboring formula: '+id);
            all.add(id);definitions++;
          }
          for(const use of formula.querySelectorAll('use')) {
            const href=use.getAttribute('href')||use.getAttributeNS('http://www.w3.org/1999/xlink','href');
            if(!href?.startsWith('#')||!local.has(href.slice(1)))throw Error('Physical formula borrows an external glyph');
            const path=local.get(href.slice(1));
            if(!path.getAttribute('d'))throw Error('Glyph geometry was lost');
            references++;
          }
        }
        if(definitions<4||references<10)throw Error('Insufficient glyph ownership coverage');
        return JSON.stringify({definitions,references});
      } finally { renderer.finishSourcePreparation(source.key); }
      """, arguments: ["encoded": try await source.encodedJSON()], web: web)
    let evidence = XCTAttachment(string: report); evidence.name = "Physical MathJax ownership"; evidence.lifetime = .keepAlways; add(evidence)
  }

  #if os(macOS)
  func testAddressedLargeBookPublishesReadablePhysicalPagesAndStableReceiptsWithoutOpeningTheWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), source = illustratedBook()
    _ = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
    try store.saveDocument(source)
    try store.saveDocumentState(.init(id: source.id, actor: actor))
    let document = try store.loadDocument(source.id), state = try store.loadDocumentState(source.id)
    let target = CollaborationTarget(kind: .document, id: document.id)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let started = ContinuousClock.now
    let first = try store.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision)
    try await CurrentViewPreviewWriter.writeTarget(first, model: model)
    let coldDuration = started.duration(to: .now)
    let layout = try XCTUnwrap(DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: 0)?.layout)
    XCTAssertGreaterThan(layout.pageCount, 30)
    var firstPixels: Data?
    for index in [0, layout.pageCount - 1, layout.pageCount / 2, 0] {
      let request = try store.requestTargetRender(target: target,
        expectedRevision: document.contentStamp.revision, pageIndex: index)
      if index != 0 { try await CurrentViewPreviewWriter.writeTarget(request, model: model) }
      let receiptBytes = try Data(contentsOf: store.targetReceiptURL(request.id))
      let receipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: receiptBytes)
      let png = try Data(contentsOf: store.targetPNGURL(request.id))
      XCTAssertEqual(receipt.request, request); XCTAssertEqual(receipt.status, "ready")
      XCTAssertTrue(receipt.diagnostics.isEmpty, "\(receipt.diagnostics)")
      XCTAssertEqual(receipt.pngSHA256, SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png)), cg = try XCTUnwrap(bitmap.cgImage)
      let pixels = try rgba(cg)
      XCTAssertEqual(receipt.pixelSize?.x, Double(cg.width)); XCTAssertEqual(receipt.pixelSize?.y, Double(cg.height))
      XCTAssertGreaterThan(stride(from: 0, to: pixels.count, by: 4).filter {
        pixels[$0] < 150 && pixels[$0 + 1] < 150 && pixels[$0 + 2] < 150 && pixels[$0 + 3] > 200
      }.count, 100, "The saved PNG must contain actual ink, not only a successful layout")
      let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
      attachment.name = "Addressed large book page \(index)"; attachment.lifetime = .keepAlways; add(attachment)
      let reopened = NotebookStore(root: root)
      XCTAssertEqual(try reopened.requestTargetRender(target: target,
        expectedRevision: document.contentStamp.revision, pageIndex: index), request)
      XCTAssertEqual(try Data(contentsOf: reopened.targetReceiptURL(request.id)), receiptBytes)
      if index == 0 {
        if let firstPixels { XCTAssertTrue(pixels == firstPixels, "Repeated addressing preserves the saved first-page pixels") }
        else { firstPixels = pixels }
      }
    }
    XCTAssertEqual(try store.loadDocument(document.id), document)
    XCTAssertEqual(try store.loadDocumentState(document.id), state)
    XCTAssertTrue(model.documents.isEmpty); XCTAssertTrue(model.pages.isEmpty)
    XCTAssertNil(model.workspace); XCTAssertNil(model.presence)
    let measurement = XCTAttachment(string: "coldAddressedReady=\(coldDuration), pages=\(layout.pageCount)")
    measurement.name = "Large book addressed preparation"; measurement.lifetime = .keepAlways; add(measurement)
  }
  #endif

  func testFragmentIndexOwnsAndClosesOneTaskChannelOnCompletionAndCancellation() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "seed", source: "Ready")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = try surface(document, state, resources: SceneRenderResources())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await evaluate("""
      const NativeChannel=MessageChannel, nativeTimeout=window.setTimeout;
      const root=document.createElement('div');root.style.cssText='position:absolute;left:0;top:0;width:500px';
      root.innerHTML='<span>Indexed value</span>'.repeat(600);document.body.append(root);
      try {
        for(const mode of ['complete','cancel-before','cancel-after-task']) {
          let created=0,closed=0,posted=0,timers=0,cancelled=mode==='cancel-before';
          window.MessageChannel=function(){
            created++;const channel=new NativeChannel();
            for(const port of [channel.port1,channel.port2]) {
              const close=port.close.bind(port);port.close=()=>{closed++;close()};
            }
            const post=channel.port2.postMessage.bind(channel.port2);
            channel.port2.postMessage=(...args)=>{posted++;if(mode==='cancel-after-task')cancelled=true;post(...args)};
            return channel;
          };
          window.setTimeout=(...args)=>{timers++;return nativeTimeout(...args)};
          let failure;
          try { await notebookDocumentFragments.create(root,{sourceKey:mode,pageCount:1,width:500,height:2000,
            stride:520,originX:0,originY:0,contentTop:0,contentBottom:2000,regions:[]},()=>cancelled); }
          catch(error){failure=error.message}
          if(mode==='complete' ? failure : failure!=='document_source_preparation_cancelled')throw Error('Wrong index completion: '+failure);
          if(created!==1||closed!==2||timers!==0)throw Error(JSON.stringify({mode,created,closed,posted,timers}));
          if(mode!=='cancel-before'&&posted<1)throw Error('Index did not yield a real browser task');
        }
        return 'closed';
      } finally { window.MessageChannel=NativeChannel;window.setTimeout=nativeTimeout;root.remove(); }
      """, web: web)
  }

  private func ready(_ coordinator: DocumentWebCoordinator) async throws {
    // Observe the existing eight-second native deadline, including its failure;
    // never retry, substitute a frame, or alter production timing for this test.
    let deadline = ContinuousClock.now + .seconds(10)
    while !coordinator.renderIsReady && coordinator.acquisitionError == nil && .now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if let error = coordinator.acquisitionError { throw error }
    guard coordinator.renderIsReady else { throw DocumentSessionError.invalidLayout }
  }

  private func evaluate(_ script: String, arguments: [String: Any] = [:], web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value): continuation.resume(returning: value as? String ?? String(describing: value))
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }

  private func capture(_ web: WKWebView, name: String) async throws -> Data {
    let configuration = WKSnapshotConfiguration(); configuration.rect = web.bounds
    configuration.snapshotWidth = 640; configuration.afterScreenUpdates = true
    let image: AgentSnapshotImage = try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: configuration) { image, error in
        if let error { continuation.resume(throwing: error) }
        else if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
      }
    }
    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    #if os(iOS)
    let cg = try XCTUnwrap(image.cgImage)
    #else
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #endif
    return try rgba(cg)
  }

  private func rgba(_ cg: CGImage) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
  }
}
