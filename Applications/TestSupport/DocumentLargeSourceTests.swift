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
    let window: UIWindow?
    let preparation: NotebookPreparationHost?
    let previousKeyWindow: UIWindow?
    #else
    let window: NSWindow
    #endif
    func close() {
      coordinator.invalidate()
      #if os(iOS)
      window?.isHidden = true; window?.rootViewController = nil
      preparation?.close()
      previousKeyWindow?.makeKey()
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
    resources: SceneRenderResources, acceptsInput: Bool = false, priority: WebPriority = .currentPage) throws -> Surface {
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    update(coordinator, document, state, page: 0)
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = acceptsInput ? scene.windows.first { $0.isKeyWindow } : nil
    let window: UIWindow?, preparation: NotebookPreparationHost?
    if acceptsInput {
      let input = UIWindow(windowScene: scene), controller = UIViewController()
      input.frame = .init(x: 0, y: 0, width: size.width, height: size.height)
      controller.view = host; input.rootViewController = controller
      input.makeKeyAndVisible(); host.frame = input.bounds
      window = input; preparation = nil
    } else {
      let offscreen = try NotebookPreparationHost(windowScene: scene)
      offscreen.resize(to: .init(width: size.width, height: size.height))
      offscreen.view.addSubview(host); host.frame = offscreen.view.bounds
      window = nil; preparation = offscreen
    }
    host.layoutIfNeeded()
    #else
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    #endif
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: priority == .currentPage, priority: priority)
    #if os(iOS)
    return Surface(coordinator: coordinator, host: host, window: window, preparation: preparation, previousKeyWindow: previousKeyWindow)
    #else
    return Surface(coordinator: coordinator, host: host, window: window)
    #endif
  }

  private func update(_ coordinator: DocumentWebCoordinator, _ document: DocumentDocument,
    _ state: DocumentStateJournal, page: Int) {
    coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
  }

  func testLargeIllustratedMathBookColdMountsAndTurnsToDistantPhysicalPagesWithinTheExistingDeadline() async throws {
    let document = illustratedBook(), state = DocumentStateJournal(id: document.id, actor: UUID())
    XCTAssertEqual(document.blocks.count, 140)
    XCTAssertGreaterThan(document.blocks.reduce(0) { $0 + $1.source.utf8.count }, 6 * 1024 * 1024)
    let resources = SceneRenderResources(profile: .interactive), start = ContinuousClock.now
    let surface = try surface(document, state, resources: resources, acceptsInput: true)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let elapsed = start.duration(to: .now)
    XCTAssertLessThan(elapsed, .seconds(8), "The production preparation deadline is not enlarged for a book")
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    try await complete(source, requestedBy: surface.coordinator)
    let layout = try XCTUnwrap(source.layout)
    XCTAssertGreaterThan(layout.pageCount, 30)
    let web = try XCTUnwrap(surface.coordinator.webView)
    XCTAssertLessThan(source.compiledPageCount, layout.pageCount, "The first physical page cannot wait for all page packets")
    XCTAssertTrue(source.retainedPageIndices.isSubset(of: [0, 1]))
    var first: Data?
    for index in [0, layout.pageCount - 1, layout.pageCount / 2, 0] {
      update(surface.coordinator, document, state, page: index)
      try await ready(surface.coordinator)
      let value = try await evaluate("""
        const root=document.getElementById('document'), receipt=notebookRenderer.pageReceipt();
        if(receipt.pageIndex!==index || receipt.layoutScope!=='page')throw Error('Wrong physical page');
        if(document.querySelectorAll('.document-layout-preparation').length!==1)throw Error('Missing sole inert measurement owner');
        if(document.querySelector('.document-layout-preparation main'))throw Error('Measured source remained in the live layout tree');
        if(document.querySelectorAll('.paper-sheet').length!==1)throw Error('More than one physical paper');
        if(!root.textContent.trim() || !root.querySelector('img,mjx-container'))throw Error('Blank book page');
        if([...root.querySelectorAll('img')].some(image=>!image.complete||!image.naturalWidth))throw Error('Undecoded illustration');
        for(const heading of root.querySelectorAll('h2'))if(heading.textContent.startsWith('Figure ')
          && !heading.closest('[data-block-id]').querySelector('img'))throw Error('Orphaned figure heading');
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
      XCTAssertTrue(source.retainedPageIndices.isSubset(of: Set(max(0, index - 1)...min(layout.pageCount - 1, index + 1))),
        "The fragment cache belongs to the current working window, not visited pages")
    }
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit / 2,
      "Book preparation must leave the protected Pencil reserve intact")
    let measurement = XCTAttachment(string: "coldReady=\(elapsed), pages=\(layout.pageCount), peakAccountedBytes=\(resources.peakAccountedBytes)")
    measurement.name = "Large book native preparation"; measurement.lifetime = .keepAlways; add(measurement)
    surface.close()
    let drained = ContinuousClock.now + .seconds(2)
    while resources.activeWebSurfaceCount != 0, .now < drained { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testFirstUsefulPageDoesNotWaitForDistantTypesetting() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "initial", source: "Initial page")])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = try surface(document, state, resources: SceneRenderResources(profile: .interactive), acceptsInput: true)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await evaluate("""
      const original=MathJax.typesetPromise.bind(MathJax);
      window.tailStarted=false;
      const gate=new Promise(resolve=>window.releaseTail=resolve);
      MathJax.typesetPromise=async nodes=>{
        if(nodes.some(node=>node.dataset.blockId==='distant')){window.tailStarted=true;await gate;}
        return original(nodes);
      };
      return 'installed';
      """, arguments: [:], web: web)
    document = DocumentDocument(id: document.id, actor: actor, blocks: [
      .markdown(id: "visible", source: "# Useful first page\n\n[Far section](#distant)\n\n" +
        String(repeating: "A visible measured paragraph with $x^2+1$ stays at its physical address.\n\n", count: 65)),
      .markdown(id: "distant", source: "<h1 id='distant'>Distant section</h1>\n\n$\\int_0^1 t^2 dt$")
    ])
    update(surface.coordinator, document, state, page: 0)
    let started = ContinuousClock.now
    let deadline = ContinuousClock.now + .seconds(2)
    while !surface.coordinator.hasCanonicalPixels, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let shownBeforeTail = surface.coordinator.hasCanonicalPixels
    let firstDuration = started.duration(to: .now)
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    let prefix = source.layout
    var firstPixels: Data?
    var links: [DocumentLinkDestination] = []
    surface.coordinator.onLinkActivation = { links.append($0.destination) }
    if shownBeforeTail {
      XCTAssertEqual(prefix?.isComplete, false)
      XCTAssertEqual(source.preparedSourceBlockCount, 1, "Only the useful block and its editing source have crossed the bridge")
      let actual = try await evaluate("""
        const root=document.querySelector('#document');
        if(!root.textContent.includes('Useful first page') || !root.querySelector('mjx-container'))throw Error('Not useful paper');
        root.querySelector('a').click();
        return 'visible';
        """, arguments: [:], web: web)
      XCTAssertEqual(actual, "visible")
      firstPixels = try await capture(web, name: "Useful page while distant typesetting is blocked")
      XCTAssertTrue(links.isEmpty, "An unresolved far section is pending, not missing or activated twice")
    }
    // Always release the diagnostic gate, including the negative baseline.
    _ = try await evaluate("window.releaseTail();return 'released';", arguments: [:], web: web)
    XCTAssertTrue(shownBeforeTail, "Visible text/formulas must be canonical while distant typesetting is still blocked")
    try await ready(surface.coordinator)
    try await complete(source)
    XCTAssertTrue(source.layout === prefix, "The canonical owner extends; it does not swap pagination")
    let far = try XCTUnwrap(source.layout?.anchorPages["distant"])
    let linked = ContinuousClock.now + .seconds(2)
    while links.isEmpty, .now < linked { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(links, [.page(far)])
    for page in [far, 0] {
      update(surface.coordinator, document, state, page: page)
      try await ready(surface.coordinator)
    }
    let returned = try await capture(web, name: "Same useful page after full index and far-link return")
    XCTAssertEqual(firstPixels, returned, "Appending the tail cannot move already shown text or formulas")
    XCTAssertEqual(source.measurementCount, 1)
    let measurement = XCTAttachment(string: "firstUseful=\(firstDuration), fullPages=\(source.layout?.pageCount ?? 0)")
    measurement.name = "Incremental canonical source"; measurement.lifetime = .keepAlways; add(measurement)
  }

  func testFarLinkWaitsForTailAdmissionWithoutPoisoningTheShownPage() async throws {
    try await assertTailAdmission(closesWhileWaiting: false)
  }

  func testClosingTheReaderCancelsTailAdmissionWithoutLateLinkDelivery() async throws {
    try await assertTailAdmission(closesWhileWaiting: true)
  }

  private func assertTailAdmission(closesWhileWaiting: Bool) async throws {
    let resources = SceneRenderResources(byteLimit: 8 * 1024 * 1024, profile: .interactive)
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "initial", source: "Initial page")])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = try surface(document, state, resources: resources, acceptsInput: true)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await evaluate("""
      const original=MathJax.typesetPromise.bind(MathJax);
      window.tailStarted=false;
      const gate=new Promise(resolve=>window.releaseTail=resolve);
      MathJax.typesetPromise=async nodes=>{
        if(nodes.some(node=>node.dataset.blockId==='distant')){window.tailStarted=true;await gate;}
        return original(nodes);
      };
      return 'installed';
      """, web: web)
    document = DocumentDocument(id: document.id, actor: actor, blocks: [
      .markdown(id: "visible", source: "# Useful page\n\n[Far section](#distant)\n\n" +
        String(repeating: "A visible measured paragraph stays at its physical address.\n\n", count: 120)),
      .markdown(id: "distant", source: "<h1 id='distant'>Distant section</h1>\n\n" +
        String(repeating: "The distant navigation index also owns its resource admission.\n\n", count: 500))
    ])
    update(surface.coordinator, document, state, page: 0)
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), prefix = try XCTUnwrap(source.layout)
    XCTAssertFalse(prefix.isComplete)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(
      resources.passiveByteLimit - resources.passiveReservedBytes - resources.residentBytes - 8_192, priority: .passive))
    defer { blocker.release() }
    var links: [DocumentLinkDestination] = []
    surface.coordinator.onLinkActivation = { links.append($0.destination) }
    _ = try await evaluate("document.querySelector('#document a').click();releaseTail();return 'requested';", web: web)
    let refused = ContinuousClock.now + .seconds(3)
    while resources.lastRasterRefusal == nil, .now < refused { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(resources.lastRasterRefusal)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(links.isEmpty, "A temporary tail allocation refusal is not a missing link or source failure")
    XCTAssertEqual(resources.pendingDerivedRequestCount, 1, "The same source owner waits for capacity even with no page-packet waiter")
    XCTAssertTrue(surface.coordinator.hasCanonicalPixels)
    let refusals = resources.lastRasterRefusal?.generation
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusals, "Own cleanup must not spin remeasurement")
    if closesWhileWaiting {
      surface.coordinator.invalidate()
      let drained = ContinuousClock.now + .seconds(3)
      while resources.pendingDerivedRequestCount != 0 || resources.activeWebSurfaceCount != 0 {
        guard .now < drained else { XCTFail("Closing the last reader did not release its admission and browser"); return }
        try await Task.sleep(for: .milliseconds(10))
      }
      blocker.release()
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertTrue(links.isEmpty, "Cancelled navigation cannot be delivered after resource release")
      XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
      XCTAssertEqual(resources.activeWebSurfaceCount, 0)
      return
    }
    blocker.release()
    try await complete(source)
    let deadline = ContinuousClock.now + .seconds(3)
    while links.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let far = try XCTUnwrap(prefix.anchorPages["distant"])
    XCTAssertEqual(links, [.page(far)])
    XCTAssertTrue(source.layout === prefix)
    XCTAssertTrue(surface.coordinator.webView === web)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    update(surface.coordinator, document, state, page: far)
    try await ready(surface.coordinator)
  }

  private func complete(_ source: DocumentSourceSnapshot, requestedBy coordinator: DocumentWebCoordinator? = nil) async throws {
    if let coordinator, source.layout?.isComplete != true {
      coordinator.resolveLink("#explicit-full-index-request", origin: try XCTUnwrap(coordinator.currentLinkOrigin), deliver: { _ in })
    }
    let deadline = ContinuousClock.now + .seconds(8)
    while source.layout?.isComplete != true, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(source.layout?.isComplete, true, source.lastPreparationLayoutMismatch ?? "Navigation index did not finish")
  }

  func testNeitherPassiveNorCurrentPageStartsTheWholeBookWithoutAnIndexRequest() async throws {
    let actor = UUID(), resources = SceneRenderResources(profile: .interactive)
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "initial", source: "Initial page")])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = try surface(document, state, resources: resources, acceptsInput: true, priority: .background)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await evaluate("""
      const original=MathJax.typesetPromise.bind(MathJax);
      window.tailStarts=0;
      const gate=new Promise(resolve=>window.releaseTail=resolve);
      MathJax.typesetPromise=async nodes=>{
        if(nodes.some(node=>node.dataset.blockId==='distant')){window.tailStarts++;await gate;}
        return original(nodes);
      };
      return 'installed';
      """, arguments: [:], web: web)
    document = DocumentDocument(id: document.id, actor: actor, blocks: [
      .markdown(id: "visible", source: "# Passive useful page\n\n" +
        String(repeating: "A visible measured paragraph with $x^2+1$ stays at its physical address.\n\n", count: 120)),
      .markdown(id: "distant", source: "# Distant section\n\n$\\int_0^1 t^2 dt$")
    ])
    update(surface.coordinator, document, state, page: 0)
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    let first = try await capture(web, name: "Passive page without unrequested whole-book work")
    // Give the completion task the same chance to run as an ordinary snapshot
    // request. The actual gate records entry; elapsed time is not readiness.
    try await Task.sleep(for: .milliseconds(200))
    let unrequested = try await evaluate("return String(window.tailStarts);", arguments: [:], web: web)
    XCTAssertEqual(unrequested, "0", "A background page image must not start the entire book's navigation index")
    XCTAssertEqual(source.layout?.isComplete, false)
    let size = WorkspaceItemGeometry.document(document.paperSize)
    surface.coordinator.mount(in: surface.host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: true, priority: .currentPage)
    // The current reader extends only its nearby page window, not the tail.
    await Task.yield()
    let starts = try await evaluate("return String(window.tailStarts);", arguments: [:], web: web)
    XCTAssertEqual(starts, "0")
    XCTAssertEqual(source.preparedSourceBlockCount, 1)
    _ = try await evaluate("window.releaseTail();return 'released';", arguments: [:], web: web)
    try await ready(surface.coordinator)
    try await complete(source, requestedBy: surface.coordinator)
    XCTAssertTrue(surface.coordinator.webView === web)
    XCTAssertEqual(source.measurementCount, 1)
    let returned = try await capture(web, name: "Same passive pixels after adoption into the reader")
    XCTAssertEqual(first, returned)
    surface.close()
    let drained = ContinuousClock.now + .seconds(2)
    while resources.activeWebSurfaceCount != 0, .now < drained { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testIncrementalBookAgreesWithFullRemeasureAfterIndexReclamation() async throws {
    let document = illustratedBook(), state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = try surface(document, state, resources: SceneRenderResources(profile: .interactive), acceptsInput: true)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    try await complete(source, requestedBy: surface.coordinator)
    let layout = try XCTUnwrap(source.layout), web = try XCTUnwrap(surface.coordinator.webView)
    let first = try await capture(web, name: "Incremental mixed book first page")
    await source.discardIdlePreparation()
    update(surface.coordinator, document, state, page: layout.pageCount - 1)
    try await ready(surface.coordinator)
    XCTAssertEqual(source.measurementCount, 2, source.lastPreparationLayoutMismatch ?? "")
    XCTAssertTrue(source.layout === layout)
    update(surface.coordinator, document, state, page: 0)
    try await ready(surface.coordinator)
    let restored = try await capture(web, name: "Remeasured mixed book first page")
    XCTAssertEqual(first, restored)
  }

  func testAnIllustrationThatFitsOnePageKeepsItsHeadingOnItsPhysicalSheet() async throws {
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='450' height='158'><rect x='1' y='1' width='448' height='156' fill='#dce9f6'/></svg>"
    let image = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    let document = DocumentDocument(actor: UUID(), blocks: (0..<12).map { index in
      .markdown(id: "figure-\(index)", source: "<div><p>" + String(repeating: "Measured introductory prose. ", count: 24)
        + "</p><h2>Figure \(index)</h2><img width='450' height='158' src='\(image)'><p>Figure caption \(index).</p></div>")
    })
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = try surface(document, state, resources: SceneRenderResources())
    defer { surface.close() }
    try await ready(surface.coordinator)
    try await complete(try XCTUnwrap(surface.coordinator.payload?.source), requestedBy: surface.coordinator)
    let layout = try XCTUnwrap(surface.coordinator.payload?.source.layout)
    XCTAssertGreaterThan(layout.pageCount, 3)
    var headings = 0
    let web = try XCTUnwrap(surface.coordinator.webView)
    for index in 0..<layout.pageCount {
      update(surface.coordinator, document, state, page: index)
      try await ready(surface.coordinator)
      let count = try await evaluate("""
        const root=document.getElementById('document'), headings=[...root.querySelectorAll('h2')];
        for(const heading of headings) {
          const image=heading.closest('[data-block-id]').querySelector('img');
          if(!image || !image.complete || !image.naturalWidth)throw Error('Illustration heading was stranded on preceding page');
          if(image.getBoundingClientRect().top < heading.getBoundingClientRect().bottom)throw Error('Heading and image overlap');
        }
        return String(headings.length);
        """, web: web)
      headings += try XCTUnwrap(Int(count))
    }
    XCTAssertEqual(headings, 12, "No heading may be dropped or duplicated while keeping its illustration")
  }

  func testFirstPageIsUsableBeforeFarPacketsAndPhysicalWindowDropsTraversalHistory() async throws {
    let actor = UUID(), resources = SceneRenderResources()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Ready seed")])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = try surface(document, state, resources: resources)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await evaluate("""
      const prepare=notebookRenderer.preparePagePacket;
      window.allowDistantPage=false;window.compiledPages=[];
      notebookRenderer.preparePagePacket=(key,index)=>{
        if(index>1&&!allowDistantPage)throw Error('Far page compiled before first page was usable');
        compiledPages.push(index);return prepare(key,index);
      };
      return 'armed';
      """, web: web)
    let paragraphs = (0..<150).map { "Paragraph \($0). " + String(repeating: "The requested physical sheet is available independently. ", count: 12) }.joined(separator: "\n\n")
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: paragraphs, actor: actor))
    update(surface.coordinator, document, state, page: 0)
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), layout = try XCTUnwrap(source.layout)
    XCTAssertGreaterThan(layout.pageCount, 8)
    XCTAssertLessThanOrEqual(source.compiledPageCount, 2)
    let first = try await evaluate("""
      if(!document.getElementById('document').textContent.includes('Paragraph 0'))throw Error('First page is empty');
      if(compiledPages.some(index=>index>1))throw Error('Unrequested distant page');
      allowDistantPage=true;return JSON.stringify(compiledPages);
      """, web: web)
    let attachment = XCTAttachment(string: first); attachment.name = "First usable page compiled only requested window"; attachment.lifetime = .keepAlways; add(attachment)
    for index in [layout.pageCount - 1, layout.pageCount / 2, 0] {
      update(surface.coordinator, document, state, page: index)
      try await ready(surface.coordinator)
      XCTAssertTrue(source.retainedPageIndices.isSubset(of: Set(max(0, index - 1)...min(layout.pageCount - 1, index + 1))))
      XCTAssertEqual(source.measurementCount, 1, "A live producer keeps the one canonical measurement/index")
      XCTAssertEqual(source.preparationCount, 1)
    }
    await source.discardIdlePreparation()
    XCTAssertTrue(source.retainedPageIndices.isEmpty)
    let discarded = try await evaluate("return String(document.querySelectorAll('.document-layout-preparation').length);", web: web)
    XCTAssertEqual(discarded, "0")
    update(surface.coordinator, document, state, page: layout.pageCount - 1)
    try await ready(surface.coordinator)
    XCTAssertEqual(source.measurementCount, 2, "After explicit reclamation the same owner remeasures")
    XCTAssertTrue(source.layout === layout, "Reclamation must preserve accepted link and page geometry")
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
  }

  func testSpeculativePacketAdmissionWaitsForActuallyAvailableCapacity() async throws {
    let resources = SceneRenderResources(byteLimit: 96 * 1024 * 1024, profile: .interactive)
    let occupied = try XCTUnwrap(resources.reserveDerivedBytes(32 * 1024 * 1024, priority: .passive))
    defer { occupied.release() }
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Prepared seed")])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = try surface(document, state, resources: resources)
    defer { surface.close() }
    try await ready(surface.coordinator)
    let previous = try XCTUnwrap(surface.coordinator.payload?.source)
    await previous.discardIdlePreparation()
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await evaluate("""
      const prepare=notebookRenderer.preparePagePacket;
      window.neighborAttempts=0;window.allowNeighborPacket=false;
      notebookRenderer.preparePagePacket=(key,index)=>{
        const packet=prepare(key,index);
        if(index===1){neighborAttempts++;if(!allowNeighborPacket)return {...packet,utf8Bytes:8*1024*1024};}
        return packet;
      };
      return 'armed';
      """, web: web)
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: (0..<30).map {
      "Paragraph \($0). " + String(repeating: "Only available capacity can resume speculative work. ", count: 12)
    }.joined(separator: "\n\n"), actor: actor))
    update(surface.coordinator, document, state, page: 0)
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    // The native scene, not the fragment compiler, owns neighbour expansion.
    let neighbourConsumer = UUID()
    source.retainPage(1, hostID: neighbourConsumer)
    defer { source.releasePage(hostID: neighbourConsumer, in: nil) }
    let neighbourDeadline = ContinuousClock.now + .seconds(3)
    while try await evaluate("return String(neighborAttempts);", web: web) == "0", ContinuousClock.now < neighbourDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let before = try await evaluate("return String(neighborAttempts);", web: web)
    XCTAssertGreaterThan(try XCTUnwrap(Int(before)), 0)
    try await Task.sleep(for: .milliseconds(200))
    let after = try await evaluate("return String(neighborAttempts);", web: web)
    XCTAssertEqual(after, before, "Releasing a failed packet's own staging must not spin the same preparation")
    XCTAssertEqual(source.retainedPageIndices, [0])
    _ = try await evaluate("allowNeighborPacket=true;return 'released';", web: web)
    occupied.release()
    let deadline = ContinuousClock.now + .seconds(3)
    while !source.retainedPageIndices.contains(1), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(source.retainedPageIndices.contains(1), "Actual resource release refines the stationary working window")
    withExtendedLifetime(previous) {}
  }

  #if os(iOS)
  func testLargeBookOpensBesideDrawnPaperInTheSameSceneBudget() async throws {
    let document = illustratedBook(), state = DocumentStateJournal(id: document.id, actor: UUID())
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let notebook = WorkspaceItem.notebook(title: "Neighbor", pageIDs: [UUID()])
    let item = WorkspaceItem.document(id: document.id, title: "Illustrated book")
    let workspace = WorkspaceIndex(items: [notebook, item], selectedItemID: item.id, selectedPageID: nil, stamp: stamp)
    let board = BoardDocument(freeItems: [
      .init(itemID: notebook.id, center: .zero, zIndex: 0, stamp: stamp),
      .init(itemID: item.id, center: .init(x: 1016, y: 792), zIndex: 1, stamp: stamp)
    ], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [item.id: .a4])
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .document,
      camera: .init(center: .init(x: 640, y: -1890), scale: 0.1425), viewport: .init(x: 1194, y: 834),
      focusedItemID: item.id, openProgress: 1)
    var journal = SpatialInkJournal(stamp: stamp)
    for surface in [SurfaceID.board(workspace.rootBoardID), .cover(notebook.id), .cover(item.id)] {
      XCTAssertNotNil(journal.append(tool: .pen, spans: [.init(surface: surface, samples: [100.0, 200].enumerated().map { n, x in
        .init(point: .init(x: x, y: 100), worldPoint: surface.kind == .board ? .init(x: x, y: 100) : nil,
          timeOffset: Double(n) / 10, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor))
    }
    let resources = SceneRenderResources(), tiles = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await tiles.stop() }
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: journal)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
    let deadline = ContinuousClock.now + .seconds(5)
    while tiles.published == nil, tiles.failure == nil, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let cohort = try XCTUnwrap(tiles.published, tiles.failure ?? "The drawn scene must publish before opening its book")
    XCTAssertEqual(cohort.nativeInk.owners.count, 3)
    XCTAssertGreaterThan(resources.reservedBytes, 170 * 1024 * 1024)
    let surface = try surface(document, state, resources: resources)
    defer { surface.close() }
    do { try await ready(surface.coordinator) }
    catch {
      XCTFail("Preparation: \(error); refusal=\(String(describing: resources.lastRasterRefusal))")
      throw error
    }
    let snapshot = try XCTUnwrap(surface.coordinator.payload?.source), layout = try XCTUnwrap(snapshot.layout)
    for page in [layout.pageCount - 1, layout.pageCount / 2, 0] {
      update(surface.coordinator, document, state, page: page)
      try await ready(surface.coordinator)
      let web = try XCTUnwrap(surface.coordinator.webView)
      _ = try await evaluate("""
        const receipt=notebookRenderer.pageReceipt(), root=document.getElementById('document');
        if(receipt.pageIndex!==index || receipt.layoutScope!=='page' || !root.textContent.trim())throw Error('Missing physical page');
        if(document.querySelectorAll('.document-layout-preparation').length!==1)throw Error('Missing sole inert measurement owner');
        return 'shown';
        """, arguments: ["index": page], web: web)
    }
    XCTAssertEqual(snapshot.preparationCount, 1)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, 256 * 1024 * 1024)
    let measurement = XCTAttachment(string: "peakAccountedBytes=\(resources.peakAccountedBytes), passiveReservedBytes=\(resources.passiveReservedBytes), pages=\(layout.pageCount)")
    measurement.name = "Large book beside drawn paper"; measurement.lifetime = .keepAlways; add(measurement)
    withExtendedLifetime(cohort) { XCTAssertEqual(cohort.nativeInk.owners.count, 3) }
  }
  #endif

  func testEachPhysicalFormulaOwnsItsGlyphDefinitionsBeforeAttachment() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "math", source:
      #"Local $x^2+\frac{a}{b}+x^2$ and $\int_0^1 t^2\,dt$."#)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = try surface(document, state, resources: SceneRenderResources())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), web = try XCTUnwrap(surface.coordinator.webView)
    await source.discardIdlePreparation()
    let report = try await evaluate("""
      async function prepareFixtureSource(source,page=null) {
        const renderer=window.notebookRenderer;
        let packet=await renderer.beginSourcePreparation({key:source.key,documentID:source.documentID,
          paper:source.paper,blockCount:source.blocks.length},page);
        while(Number.isInteger(packet.nextBlockIndex)) {
          const offset=packet.nextBlockIndex;
          packet=await renderer.extendSourcePreparation(source.key,page,{offset,blocks:source.blocks.slice(offset,offset+4)});
        }
        return packet;
      }
      const source=JSON.parse(encoded), renderer=notebookRenderer;
      const fragments=notebookDocumentFragments;let original;
      window.notebookDocumentFragments={...fragments,create:async (...args)=>{
        const compiler=await fragments.create(...args);
        original=new Set([...args[0].querySelectorAll('mjx-container [id]')].map(node=>node.id));
        return compiler;
      }};
      try {
        await prepareFixtureSource(source);
        renderer.readPreparedPacket(source.key,null);
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
      } finally { window.notebookDocumentFragments=fragments;renderer.finishSourcePreparation(source.key); }
      """, arguments: ["encoded": try canonicalDocumentJSON(source.message)], web: web)
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
    let layout = try XCTUnwrap(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0)?.layout)
    XCTAssertGreaterThanOrEqual(layout.pageCount, 1)
    var firstPixels: Data?
    // A one-page export owns no open document/navigation session. Its prefix
    // is not a final page count; request real distant physical pages directly.
    for index in [0, 30, 15, 0] {
      let request = try store.requestTargetRender(target: target,
        expectedRevision: document.contentStamp.revision, pageIndex: index)
      if index != 0 { try await CurrentViewPreviewWriter.writeTarget(request, model: model) }
      let receiptBytes = try Data(contentsOf: store.targetReceiptURL(request.id))
      let receipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: receiptBytes)
      let png = try Data(contentsOf: store.targetPNGURL(request.id))
      XCTAssertEqual(receipt.request, request); XCTAssertEqual(receipt.status, "ready")
      XCTAssertTrue(receipt.diagnostics.isEmpty, "\(receipt.diagnostics)")
      XCTAssertGreaterThan(try XCTUnwrap(DocumentRenderRegistry.shared.entry(document: document, pageIndex: index)?.layout).pageCount, index)
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

  func testMeasuredSourceLeavesLayoutTreeAndPageCutsDoNotReadItsGeometryAgain() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "<div style='padding-top:13px;border-top:2px solid black'>" + String(repeating:
        "<p>👩🏽‍💻 é A measured paragraph keeps its actual baseline across page cuts. "
          + String(repeating: "Continued text العربية 中文. ", count: 12) + "</p>", count: 40) + "</div>")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = try surface(document, state, resources: SceneRenderResources())
    defer { surface.close() }
    try await ready(surface.coordinator)
    let source = try XCTUnwrap(surface.coordinator.payload?.source), web = try XCTUnwrap(surface.coordinator.webView)
    await source.discardIdlePreparation()
    let report = try await evaluate("""
      async function prepareFixtureSource(source,page=null) {
        const renderer=window.notebookRenderer;
        let packet=await renderer.beginSourcePreparation({key:source.key,documentID:source.documentID,
          paper:source.paper,blockCount:source.blocks.length},page);
        while(Number.isInteger(packet.nextBlockIndex)) {
          const offset=packet.nextBlockIndex;
          packet=await renderer.extendSourcePreparation(source.key,page,{offset,blocks:source.blocks.slice(offset,offset+4)});
        }
        return packet;
      }
      const source=JSON.parse(encoded),fragments=notebookDocumentFragments;
      const getStyle=window.getComputedStyle,getRects=Range.prototype.getClientRects,getBox=Range.prototype.getBoundingClientRect;
      let measured,host,expected,pages;
      window.notebookDocumentFragments={...fragments,create:async (...args)=>{
        const compiler=await fragments.create(...args);measured=args[0];host=measured.parentElement;
        pages=[0,args[1].pageCount-1];
        if(pages[1]<2)throw Error('Missing continued page coverage');
        expected=pages.map(page=>compiler.compile(page));return compiler;
      }};
      try {
        await prepareFixtureSource(source);
        if(measured.isConnected||!host.isConnected||host.querySelector('main'))throw Error('Source still participates in live layout');
        const check=node=>{if(node===measured||measured.contains(node))throw Error('Re-read measured source geometry')};
        window.getComputedStyle=(node,...args)=>{check(node);return getStyle(node,...args)};
        Range.prototype.getClientRects=function(){check(this.startContainer);return getRects.call(this)};
        Range.prototype.getBoundingClientRect=function(){check(this.startContainer);return getBox.call(this)};
        for(let index=0;index<pages.length;index++) {
          notebookRenderer.preparePagePacket(source.key,pages[index]);
          const actual=JSON.parse(notebookRenderer.readPreparedPacket(source.key,pages[index]));
          if(JSON.stringify(actual)!==JSON.stringify(expected[index]))throw Error('Detached cut changed its real measured fragment');
        }
        return JSON.stringify({pages,detached:!measured.isConnected});
      } finally {
        window.notebookDocumentFragments=fragments;window.getComputedStyle=getStyle;
        Range.prototype.getClientRects=getRects;Range.prototype.getBoundingClientRect=getBox;
        notebookRenderer.finishSourcePreparation(source.key);
      }
      """, arguments: ["encoded": try canonicalDocumentJSON(source.message)], web: web)
    let evidence = XCTAttachment(string: report); evidence.name = "Detached measured source cuts"; evidence.lifetime = .keepAlways; add(evidence)
  }

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
    if let error = coordinator.acquisitionError {
      if let mismatch = coordinator.payload?.source.lastPreparationLayoutMismatch {
        let attachment = XCTAttachment(string: mismatch); attachment.name = "Canonical preparation mismatch"; attachment.lifetime = .keepAlways; add(attachment)
      }
      throw error
    }
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
