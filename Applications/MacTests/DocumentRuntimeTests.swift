import AppKit
import NotebookCore
import Observation
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentRuntimeTests: XCTestCase {
  @MainActor private struct Surface {
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    let window: NSWindow
    func close() { coordinator.invalidate(); window.orderOut(nil); window.close() }
  }

  private func surface(document: DocumentDocument, state: DocumentStateJournal,
    resources suppliedResources: SceneRenderResources? = nil, snapshotPixelWidth: Int? = nil,
    interactive: Bool = true, pageIndex: Int = 0,
    drafts: [DocumentEditingSession] = [],
    source: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status = { _ in .committed },
    draft: @escaping (DocumentEditingSession) -> Void = { _ in },
    commit: @escaping (String, JSONValue) -> Void = { _,_ in }) -> Surface {
    let resources = suppliedResources ?? SceneRenderResources(maximumWebSurfaces: 4)
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: source, onStateChange: commit)
    coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: snapshotPixelWidth != nil,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: source, onStateChange: commit,
      snapshotPixelWidth: snapshotPixelWidth, drafts: drafts, onDraftChange: draft)
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: interactive && snapshotPixelWidth == nil,
      priority: snapshotPixelWidth == nil ? (interactive ? .currentPage : .neighbor) : .visible)
    return .init(coordinator: coordinator, host: host, window: window)
  }

  func testHeadlessDocumentCompletesActualLayoutWithoutAnimationFrameSubstitution() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Настоящий WebKit\n\nТекст без таймера готовности.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let actual1 = try await js("String(window.notebookRenderer.pageReceipt().pageIndex)", web)
    XCTAssertEqual(actual1, "0")
    let actual2 = try await js("String(requestAnimationFrame).includes('[native code]') ? 'native' : 'replaced'", web)
    XCTAssertEqual(actual2, "native")
    XCTAssertNotNil(DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: 0))
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0),
      "An offscreen layout is not a human-visible frame")
  }

  func testBrowserPacketAnnouncementPinsExactBytesAndRefusesWrongOrUnreadAddresses() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      String(repeating: "👩🏽‍💻 Страница и её точный пакет.\n\n", count: 90))])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView), source = try XCTUnwrap(surface.coordinator.payload?.source)
    try await execute("""
      const source=JSON.parse(encoded), renderer=notebookRenderer, bytes=value=>new TextEncoder().encode(value).length;
      const refused=operation=>{let failed=false;try{operation()}catch{failed=true}if(!failed)throw Error('Packet address was accepted');};
      const layout=await renderer.beginSourcePreparation(source);
      try {
        if(layout.sourceKey!==source.key || layout.pageIndex!==null || bytes(JSON.stringify(layout))>512)throw Error('Invalid layout announcement');
        const json=renderer.readPreparedPacket(source.key,null);
        if(bytes(json)!==layout.utf8Bytes)throw Error('Layout byte count changed');
        refused(()=>renderer.readPreparedPacket('another source',null));
        const fragment=renderer.preparePagePacket(source.key,0);
        if(fragment.sourceKey!==source.key || fragment.pageIndex!==0 || bytes(JSON.stringify(fragment))>512)throw Error('Invalid page announcement');
        refused(()=>renderer.preparePagePacket(source.key,0));
        refused(()=>renderer.readPreparedPacket(source.key,1));
        refused(()=>renderer.readPreparedPacket('another source',0));
        const page=renderer.readPreparedPacket(source.key,0);
        if(bytes(page)!==fragment.utf8Bytes || JSON.parse(page).pageIndex!==0)throw Error('Fragment byte count changed');
        refused(()=>renderer.readPreparedPacket(source.key,0));
        renderer.preparePagePacket(source.key,0);
      } finally { renderer.finishSourcePreparation(source.key); }
      refused(()=>renderer.readPreparedPacket(source.key,0));
      refused(()=>renderer.readPreparedPacket(source.key,null));
      return true;
      """, arguments: ["encoded": try await source.encodedJSON()], in: web)
  }

  func testNativeReaderRejectsChangedLayoutAndPagePacketLengthsWithoutPublishingOrLeaking() async throws {
    for corruptLayout in [true, false] {
      let actor = UUID(), resources = SceneRenderResources(maximumWebSurfaces: 1)
      var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before")])
      let state = DocumentStateJournal(id: document.id, actor: actor)
      let surface = surface(document: document, state: state, resources: resources)
      defer { surface.close() }
      await waitUntil { surface.coordinator.renderIsReady }
      let web = try XCTUnwrap(surface.coordinator.webView)
      let prior = try XCTUnwrap(surface.coordinator.payload?.source), priorLayout = try XCTUnwrap(prior.layout)
      try await execute("""
        const read=notebookRenderer.readPreparedPacket;
        notebookRenderer.readPreparedPacket=(key,index)=>{
          const packet=read(key,index);
          return (index===null)===layout ? packet+' ' : packet;
        };
        return true;
        """, arguments: ["layout": corruptLayout], in: web)
      let retainedBytes = resources.reservedBytes
      XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After 👩🏽‍💻", actor: actor))
      surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
      await waitUntil { surface.coordinator.acquisitionError != nil }
      XCTAssertEqual(surface.coordinator.acquisitionError?.localizedDescription, "document_layout_invalid")
      XCTAssertFalse(surface.coordinator.renderIsReady)
      XCTAssertNil(surface.coordinator.payload?.source.layout)
      XCTAssertTrue(prior.layout === priorLayout)
      await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == retainedBytes }
      let remaining = try await js("String(document.querySelectorAll('.document-layout-preparation').length)", web)
      XCTAssertEqual(remaining, "0")
    }
  }

  func testRegistryBorrowsLayoutFromLiveSourceThenItsRasterAndReleasesAfterEviction() async throws {
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024, profile: .headless)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Measured source\n\nIts raster retains the same addresses.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    weak let layout = surface.coordinator.payload?.source.layout
    let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 320)
    surface.close()
    XCTAssertNotNil(layout)
    XCTAssertTrue(DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: 0)?.layout === layout)
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    raster.release()
    let replacement = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit, priority: .passive))
    XCTAssertNil(layout)
    XCTAssertNil(DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: 0))
    XCTAssertEqual(DocumentRenderRegistry.shared.layoutReferenceCount(documentID: document.id), 0,
      "Expired addresses and diagnostics must leave with their measured owner")
    XCTAssertEqual(resources.reservedBytes, resources.byteLimit)
    replacement.release()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testStateEchoAndUnrelatedSourceKeepTheSameInteractiveBrowsingContext() async throws {
    var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "До"),
      .interactive(id: "counter", html: "<button>Счётчик</button>", javaScript:
        "notebook.commit({boot:crypto.randomUUID(),count:notebook.state.count||0})", initialState: .object(["count": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    var commits: [JSONValue] = []
    let surface = surface(document: document, state: state, commit: { _, value in commits.append(value) })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady && commits.count == 1 }
    let web = try XCTUnwrap(surface.coordinator.webView), token = surface.coordinator.payload?.blockTokens["counter"]
    _ = try await js("window.originalFrame=document.querySelector('iframe'); 'stored'", web)
    XCTAssertTrue(state.commit(blockID: "counter", value: .object(["count": .number(42)]), actor: UUID()))
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "После", actor: UUID()))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed },
      onStateChange: { _, value in commits.append(value) })
    await waitUntil { surface.coordinator.renderIsReady }
    let actual3 = try await js("window.originalFrame===document.querySelector('iframe')?'same':'replaced'", web)
    XCTAssertEqual(actual3, "same")
    XCTAssertEqual(surface.coordinator.payload?.blockTokens["counter"], token)
    XCTAssertEqual(commits.count, 1, "Keeping an iframe node is insufficient: its boot must not execute a second time")
  }

  func testDraftSurvivesStateAndUnrelatedSourceAndCommitsItsCapturedBase() async throws {
    var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Исходный текст"),
      .markdown(id: "other", source: "Другой блок")])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    var drafts: [DocumentEditingSession] = [], edits: [DocumentSourceEdit] = []
    let onSource: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status = { edit in
      edits.append(edit); return .committed
    }
    let surface = surface(document: document, state: state, source: onSource, draft: { drafts.append($0) })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await js("document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true})); 'opened'", web)
    _ = try await js("document.querySelector('textarea').value='LOCAL UNSAVED DRAFT'; document.querySelector('textarea').dispatchEvent(new Event('input',{bubbles:true})); 'typed'", web)
    await waitUntil { drafts.last?.edit.source == "LOCAL UNSAVED DRAFT" }
    let sessionID = try XCTUnwrap(drafts.last?.id), baseVersion = document.sourceVersion(blockID: "body")
    XCTAssertTrue(document.replaceBlockSource(id: "other", source: "Внешняя правка", actor: UUID()))
    XCTAssertTrue(state.commit(blockID: "other", value: .number(3), actor: UUID()))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: onSource, onStateChange: { _,_ in },
      onDraftChange: { drafts.append($0) })
    await waitUntil { surface.coordinator.renderIsReady }
    let actual4 = try await js("document.querySelector('textarea').value", web)
    XCTAssertEqual(actual4, "LOCAL UNSAVED DRAFT")
    XCTAssertTrue(edits.isEmpty)
    _ = try await js("document.querySelector('textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',metaKey:true})); 'submitted'", web)
    await waitUntil { edits.count == 1 }
    XCTAssertEqual(edits.first?.sessionID, sessionID)
    XCTAssertEqual(edits.first?.baseSource, "Исходный текст")
    XCTAssertEqual(edits.first?.baseVersion, baseVersion)
    XCTAssertEqual(edits.first?.source, "LOCAL UNSAVED DRAFT")
  }

  func testConflictKeepsTheEditorAndItsText() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Исходник")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state, source: { _ in .conflict })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await js("document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true})); document.querySelector('textarea').value='Сохранить этот текст'; document.querySelector('textarea').dispatchEvent(new Event('input')); document.querySelector('textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',metaKey:true})); 'sent'", web)
    var result = ""
    for _ in 0..<100 {
      result = try await js("document.querySelector('.source-editor-status').textContent", web)
      if result.contains("черновик сохранён") { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(result.contains("черновик сохранён"))
    let actual5 = try await js("document.querySelector('textarea').value", web)
    XCTAssertEqual(actual5, "Сохранить этот текст")
    let actual6 = try await js("String(document.querySelector('textarea').readOnly)", web)
    XCTAssertEqual(actual6, "false")
  }

  func testPrewarmExecutesOnlyProgramsOnItsPhysicalPage() async throws {
    let blocks = (0..<16).map { index in DocumentBlock.interactive(id: "block-\(index)", html: "<p>\(index)</p>",
      javaScript: "notebook.commit({boot:\(index)})", initialState: .null, height: 280) }
    let document = DocumentDocument(actor: UUID(), blocks: blocks), state = DocumentStateJournal(id: document.id, actor: UUID())
    var booted = Set<String>()
    let surface = surface(document: document, state: state, commit: { block, _ in booted.insert(block) })
    defer { surface.close() }
    let deadline = ContinuousClock.now + .seconds(8)
    while !surface.coordinator.renderIsReady && surface.coordinator.acquisitionError == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if !surface.coordinator.renderIsReady {
      let detail = XCTAttachment(string: "error=\(String(describing: surface.coordinator.acquisitionError)) booted=\(booted.sorted())")
      detail.name = "Program-only source readiness"; detail.lifetime = .keepAlways; add(detail)
      throw surface.coordinator.acquisitionError ?? DocumentSessionError.invalidLayout
    }
    let expected = Set(DocumentRenderRegistry.shared.regions(document: document, state: state).filter { $0.pageIndex == 0 }.map(\.id))
    XCTAssertFalse(expected.isEmpty)
    XCTAssertLessThan(expected.count, blocks.count)
    XCTAssertEqual(booted, expected, "A page host must not run the rest of the document's programs")
    let web = try XCTUnwrap(surface.coordinator.webView)
    let actual7 = try await js("String(document.querySelectorAll('iframe').length)", web)
    XCTAssertEqual(actual7, String(expected.count))
  }

  func testTallProgramContinuesWithExactPixelsAndOneBrowsingContext() async throws {
    let html = "<div style='height:700px;background:#ff0000'>Beginning</div>"
      + "<div style='height:700px;background:#00ff00'>Middle</div>"
      + "<div style='height:648px;background:#0000ff'>End</div>"
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "tall", html: html,
      javaScript: "notebook.commit({boot:crypto.randomUUID()})", initialState: .null, height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots = 0
    let surface = surface(document: document, state: state, commit: { _,_ in boots += 1 })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let receipt = try await js("JSON.stringify(window.notebookRenderer.pageReceipt())", web)
    let evidence = XCTAttachment(string: receipt); evidence.name = "Tall program browser geometry"; evidence.lifetime = .keepAlways; add(evidence)
    let count = try await js("String(window.notebookRenderer.pageReceipt().pageCount)", web)
    let paper = WorkspaceItemGeometry.document(document.paperSize)
    let contentHeight = paper.height - 2 * document.paperSize.marginPoints * paper.width / document.paperSize.widthPoints
    let pageCount = Int(ceil(2048 / contentHeight))
    XCTAssertGreaterThan(pageCount, 1)
    XCTAssertEqual(count, String(pageCount), "Program height uses the document's physical content region")
    _ = try await js("window.tallFrame=document.querySelector('iframe');'retained'", web)
    for page in 0..<pageCount {
      if page > 0 {
        surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
          onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed },
          onStateChange: { _,_ in boots += 1 })
        await waitUntil { surface.coordinator.renderIsReady || surface.coordinator.acquisitionError != nil }
        XCTAssertNil(surface.coordinator.acquisitionError)
      }
      let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 640)
      defer { raster.release() }
      let picture = XCTAttachment(image: raster.image); picture.name = "Tall program page \(page + 1)"; picture.lifetime = .keepAlways; add(picture)
      let cg = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let color = try centerPixel(cg)
      let expectedChannel = min(2, Int((Double(page) + 0.5) * contentHeight / 700))
      for channel in 0..<3 {
        if channel == expectedChannel { XCTAssertGreaterThan(color[channel], 230, "Page \(page + 1) must show its own part of the program") }
        else { XCTAssertLessThan(color[channel], 25, "A clipped overflow or repeated first frame is not the next page") }
      }
      let identity = try await js("String(document.querySelector('iframe')===window.tallFrame)", web)
      XCTAssertEqual(identity, "true")
    }
    XCTAssertEqual(boots, 1, "Turning through one program cannot recreate its browsing context")
  }

  func testPhysicalPageFragmentsPreserveMeasuredGraphemesAndVectors() async throws {
    let cases: [(String, String)] = [
      ("paragraphs", (0..<80).map { "Абзац \($0). " + String(repeating: "Одна браузерная разметка и физический лист. ", count: 4) }.joined(separator: "\n\n")),
      ("long-paragraph", String(repeating: "Продолжение одного длинного абзаца сохраняет целые строки и их точную геометрию. ", count: 300)),
      ("ordered-list", (1...100).map { "\($0). " + String(repeating: "Номер пункта и перенос его строк принадлежат исходному списку. ", count: 3) }.joined(separator: "\n")),
      ("headings-math", (0..<30).map { "## Раздел \($0)\n\n**Начало** и *уточнение* $x^2 + y^2 = z^2$. " + String(repeating: "Формула и следующий текст остаются вместе. ", count: 5) }.joined(separator: "\n\n")),
      ("table", "| Номер | Содержание | Значение |\n| --- | --- | --- |\n" + (0..<100).map { "| \($0) | Одна строка таблицы сохраняет свою геометрию. | \($0 * 3) |" }.joined(separator: "\n"))
    ]
    var extended: [(String, [DocumentBlock])] = cases.map { ($0.0, [DocumentBlock.markdown(id: "body", source: "# Начало\n\n" + $0.1)]) }
    var list = "<ol start='120' reversed>"
    for index in 0..<55 {
      list += "<li value='\(120-index*2)'>Пункт с исходным номером \(index)<ol start='7'><li>Вложенный пункт сохраняет отступ и номер.</li><li>Продолжение внутреннего списка.</li></ol></li>"
    }
    list += "</ol>"
    extended.append(("nested-list", [.markdown(id: "body", source: list)]))
    extended.append(("rowspan", [.markdown(id: "body", source: spanningTableFixture())]))
    extended.append(("unicode", [.markdown(id: "body", source: String(repeating:
      "👩🏽‍💻 Семья 👨‍👩‍👧‍👦 и e\u{0301}. العربية تحفظ ترتيب النص. 中文文字保持完整。\n\n", count: 140))]))
    extended.append(("unicode-continuation", [.markdown(id: "body", source: String(repeating:
      "👩🏽‍💻 Семья 👨‍👩‍👧‍👦 и e\u{0301}. العربية تحفظ ترتيب النص. 中文文字保持完整。 ", count: 160))]))
    extended.append(("tall-cell", [.markdown(id: "body", source:
      "<table><tr><td rowspan='2'>Один владелец</td><td>" + String(repeating: "<p>Очень длинная ячейка сохраняет содержание на всех листах.</p>", count: 85)
        + "</td></tr><tr><td>Конец объединённой группы.</td></tr></table>")]))
    var separate: [DocumentBlock] = []
    for index in 0..<14 {
      separate.append(.markdown(id: "heading-\(index)", source: "## Отдельный блок \(index)\n\nНачало раздела."))
      separate.append(.latex(id: "formula-\(index)", source: #"\int_0^1 x^2\,dx=\frac13"#))
      separate.append(.markdown(id: "body-\(index)", source: String(repeating: "Текст соседствует с самостоятельной формулой. ", count: 12)))
    }
    extended.append(("separate-blocks", separate))
    var mismatches: [String] = []
    for paper in DocumentPaperSize.allCases {
    for (name, blocks) in extended {
      let document = DocumentDocument(actor: UUID(), paperSize: paper, blocks: blocks)
      let state = DocumentStateJournal(id: document.id, actor: UUID())
      let surface = surface(document: document, state: state)
      defer { surface.close() }
      let deadline = ContinuousClock.now + .seconds(8)
      while !surface.coordinator.renderIsReady && surface.coordinator.acquisitionError == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      let initial = XCTAttachment(string: "ready=\(surface.coordinator.renderIsReady) error=\(String(describing: surface.coordinator.acquisitionError))")
      initial.name = "Shared pixels \(name) readiness"; initial.lifetime = .keepAlways; add(initial)
      XCTAssertNil(surface.coordinator.acquisitionError); XCTAssertTrue(surface.coordinator.renderIsReady)
      let web = try XCTUnwrap(surface.coordinator.webView), source = try XCTUnwrap(surface.coordinator.payload?.source)
      let layout = try XCTUnwrap(source.layout)
      for page in 0..<layout.pageCount {
        surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
          onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
        let deadline = ContinuousClock.now + .seconds(8)
        while !surface.coordinator.renderIsReady && surface.coordinator.acquisitionError == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let sourceJSON = try await source.encodedJSON()
        var pixels: [Data] = []
        // These PNGs expose the complete native paint paths. The source
        // columns and a physical fragment can snap bitmap-font glyphs differently
        // even when their grapheme addresses are identical (the stock-WebKit
        // control records this too). The contract below compares every measured
        // grapheme and vector; a second physical WebKit must reproduce the same
        // prepared pixels in testPreparedMathKeepsItsPixelsInAnotherWebKitWithoutASecondTypeset.
        for mode in ["physical", "measured"] {
          if mode == "measured" {
            try await execute("""
              await notebookRenderer.beginSourcePreparation(JSON.parse(source));
              const host=document.querySelector('.document-layout-preparation');
              if(host?.firstElementChild.childElementCount!==JSON.parse(source).blocks.length)throw Error('Reference source was not measured');
              const width=parseFloat(host.style.width), gap=Math.max(18,Math.min(30,22*width/JSON.parse(source).paper.widthPoints));
              document.getElementById('document').style.visibility='hidden';
              host.style.visibility='visible';host.style.transform=`translate3d(${-page*(width+gap)}px,0,0)`;
              return true;
              """, arguments: ["source": sourceJSON, "page": page], in: web)
          }
          let raster = try await capturePixels(web)
          pixels.append(raster.bytes)
          let attachment = XCTAttachment(image: raster.image); attachment.name = "Shared pixels \(name) \(paper) page \(page) \(mode)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        if pixels[0] != pixels[1] {
          let description = try await js("""
            (()=>{
              const flow=document.querySelector('.document-layout-preparation main'),style=getComputedStyle(flow);
              const cells=[...flow.querySelectorAll('td')].filter(n=>['14','15'].includes(n.textContent));
              const range=document.createRange();
              return JSON.stringify({physical:document.getElementById('document').innerHTML,flowTop:style.top,flowHeight:style.height,
                math:[document.getElementById('document'),flow].map(root=>[...root.querySelectorAll('mjx-container')].map(node=>({
                  block:node.closest('section').dataset.blockId,box:node.getBoundingClientRect().toJSON(),
                  svg:node.querySelector('svg')?.getBoundingClientRect().toJSON(),margin:getComputedStyle(node).marginTop
                }))),
                flowBox:flow.getBoundingClientRect().toJSON(),cells:cells.map(node=>{
                  range.selectNodeContents(node);const container=[...range.getClientRects()].map(r=>r.toJSON());
                  range.selectNodeContents(node.firstChild);const text=[...range.getClientRects()].map(r=>r.toJSON());
                  range.setStart(node.firstChild,0);range.setEnd(node.firstChild,1);const prefix=range.getBoundingClientRect().toJSON();
                  return {value:node.textContent,container,text,prefix};
                })});
            })()
            """,web)
          let detail=XCTAttachment(string:description);detail.name="Fragment geometry \(name) \(paper) \(page)";detail.lifetime = .keepAlways;add(detail)
        }
        let geometry = try await fragmentGeometry(in: web)
        if !geometry[0].matches(geometry[1]) { mismatches.append("\(name)/\(paper)/page-\(page)") }
        // CSS list markers are not text nodes and expose no Range geometry.
        // These fixtures also compare actual native pixels, including every
        // ordinal, explicit reset, reversed list and continuation marker.
        if name == "ordered-list" || name == "nested-list", pixels[0] != pixels[1] {
          mismatches.append("\(name)/\(paper)/page-\(page)/list-marker-pixels")
        }
        try await execute("notebookRenderer.finishSourcePreparation(key);document.getElementById('document').style.visibility='';return true;", arguments: ["key": source.message.key], in: web)

      }
    }
    }
    guard mismatches.isEmpty else {
      throw NSError(domain: "NotebookDocumentPixelContract", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Physical graphemes or vectors differ from their measured source: " + mismatches.joined(separator: ", ")])
    }
  }

  private struct FragmentGeometry: Decodable {
    struct Glyph: Decodable {
      let text: String, block: String, font: String, color: String
      let rectangles: [[Double]]
    }
    struct Vector: Decodable { let block: String, source: String; let rectangle: [Double] }
    let glyphs: [Glyph], vectors: [Vector]
    func matches(_ other: Self) -> Bool {
      func same(_ left: [Double], _ right: [Double]) -> Bool {
        left.count == right.count && zip(left,right).allSatisfy { $0.isFinite && $1.isFinite && abs($0 - $1) <= 1 / 32 }
      }
      return glyphs.count == other.glyphs.count && vectors.count == other.vectors.count
        && zip(glyphs,other.glyphs).allSatisfy { a,b in
          a.text == b.text && a.block == b.block && a.font == b.font && a.color == b.color
            && a.rectangles.count == b.rectangles.count && zip(a.rectangles,b.rectangles).allSatisfy { same($0,$1) }
        } && zip(vectors,other.vectors).allSatisfy { a,b in
          a.block == b.block && a.source == b.source && same(a.rectangle,b.rectangle)
        }
    }
  }

  private func fragmentGeometry(in web: WKWebView) async throws -> [FragmentGeometry] {
    let raw = try await js("""
      (()=>{
        const physical=document.getElementById('document'), flow=document.querySelector('.document-layout-preparation main');
        const box=physical.getBoundingClientRect(), range=document.createRange(), segmenter=new Intl.Segmenter('und',{granularity:'grapheme'});
        const visible=r=>r.width>0&&r.height>0&&r.right>0&&r.x<innerWidth&&r.bottom>box.top&&r.y<box.bottom;
        const coordinates=r=>[r.x,r.y,r.width,r.height];
        // Compare the complete local definition/reference graph, not incidental
        // allocation IDs. Glyph paths and every reference remain in the oracle.
        const vectorNames=new WeakMap();
        const vectorSource=node=>{
          // MathJax may split one formula into several SVGs. A nested SVG's
          // <use> still belongs to the definitions of the whole formula.
          const owner=node.closest('mjx-container')||node;
          if(!vectorNames.has(owner)) {
            const names=new Map();
            for(const value of [owner,...owner.querySelectorAll('[id]')])if(value.id) {
              if(names.has(value.id))throw Error('Duplicate vector definition');
              names.set(value.id,`local-${names.size}`);
            }
            vectorNames.set(owner,names);
          }
          const clone=node.cloneNode(true),names=vectorNames.get(owner);
          for(const value of [clone,...clone.querySelectorAll('*')]) {
            if(names.has(value.id))value.id=names.get(value.id);
            for(const attribute of [...value.attributes]) {
              const next=attribute.value.startsWith('#')&&names.get(attribute.value.slice(1));
              if(next)value.setAttributeNS(attribute.namespaceURI,attribute.name,'#'+next);
            }
          }
          return clone.outerHTML;
        };
        return JSON.stringify([physical,flow].map(root=>{
          const glyphs=[],vectors=[],walk=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
          while(walk.nextNode()) {
            const text=walk.currentNode,parent=text.parentElement;
            if(parent.closest('mjx-container,svg,style'))continue;
            range.selectNodeContents(text);
            if(![...range.getClientRects()].some(visible))continue;
            const style=getComputedStyle(parent),block=parent.closest('section[data-block-id]').dataset.blockId;
            for(const item of segmenter.segment(text.data)) {
              range.setStart(text,item.index);range.setEnd(text,item.index+item.segment.length);
              const rectangles=[...range.getClientRects()].filter(visible).map(coordinates);
              if(rectangles.length)glyphs.push({text:item.segment,block,font:style.font,color:style.color,rectangles});
            }
          }
          for(const node of root.querySelectorAll('svg,img')) {
            const rectangle=node.getBoundingClientRect();if(!visible(rectangle))continue;
            vectors.push({block:node.closest('section[data-block-id]').dataset.blockId,
              source:vectorSource(node),rectangle:coordinates(rectangle)});
          }
          return {glyphs,vectors};
        }));
      })()
      """, web)
    let result = try JSONDecoder().decode([FragmentGeometry].self, from: Data(raw.utf8))
    guard result.count == 2 else { throw DocumentSessionError.invalidLayout }
    if !result[0].matches(result[1]) {
      let attachment=XCTAttachment(string:raw);attachment.name="Mismatched fragment grapheme addresses";attachment.lifetime = .keepAlways;add(attachment)
    }
    return result
  }

  private func spanningTableFixture() -> String {
    var table = "<table>"
    for index in 0..<45 {
      table += "<tr><td rowspan='2'>\(index)</td><td>"
      table += String(repeating: "Длинная ячейка продолжается на следующем листе. ", count: 4)
      table += "</td><td>Значение</td></tr><tr><td colspan='2'>Вторая строка объединяет два столбца.</td></tr>"
    }
    return table + "</table>"
  }

  func testContinuedTableOwnsOneUniformGridEdgeAndNoPrecedingPageBorder() async throws {
    var checked = 0
    for paper in DocumentPaperSize.allCases {
      let document = DocumentDocument(actor: UUID(), paperSize: paper, blocks: [.markdown(id: "body", source: spanningTableFixture())])
      let state = DocumentStateJournal(id: document.id, actor: UUID())
      let live = surface(document: document, state: state)
      defer { live.close() }
      await waitUntil { live.coordinator.renderIsReady || live.coordinator.acquisitionError != nil }
      let web = try XCTUnwrap(live.coordinator.webView), layout = try XCTUnwrap(live.coordinator.payload?.source.layout)
      for page in 0..<layout.pageCount {
        live.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
          onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
        await waitUntil { live.coordinator.renderIsReady || live.coordinator.acquisitionError != nil }
        XCTAssertNil(live.coordinator.acquisitionError)
        let raw = try await js("""
          (()=>{const rows=[...document.querySelector('table').rows];
          if(rows.length<3||rows[0].getBoundingClientRect().height!==0)return 'null';
          const a=rows[0].cells[0].getBoundingClientRect(), b=rows[1].cells[0].getBoundingClientRect();
          return JSON.stringify({x1:a.x+a.width/2,x2:b.x+b.width/2,y1:a.bottom,y2:b.bottom,next:rows[2].getBoundingClientRect().top})})()
          """, web)
        if raw == "null" { continue }
        let grid = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Double])
        let y = try XCTUnwrap(grid["next"])
        XCTAssertEqual(try XCTUnwrap(grid["y1"]), y, accuracy: 1 / 64)
        XCTAssertEqual(try XCTUnwrap(grid["y2"]), y, accuracy: 1 / 64)
        let raster = try await capturePixels(web)
        let scale = Double(raster.width) / web.bounds.width
        let x1 = Int(try XCTUnwrap(grid["x1"]) * scale), x2 = Int(try XCTUnwrap(grid["x2"]) * scale)
        let center = Int(y * scale), scan = (center - 4)...(center + 4)
        func pixel(_ x: Int, _ y: Int) -> Data { Data(raster.bytes[((y * raster.width + x) * 4)..<((y * raster.width + x) * 4 + 4)]) }
        let left = scan.map { pixel(x1, $0) }, right = scan.map { pixel(x2, $0) }
        XCTAssertEqual(left, right, "A rowspan continuation must not paint a second, darker border")
        let background = left[0], occupied = left.map { $0 != background }
        let starts = occupied.indices.filter { occupied[$0] && ($0 == 0 || !occupied[$0 - 1]) }.count
        XCTAssertEqual(starts, 1, "A cell edge cannot leave two separated lines at the continuation")
        XCTAssertLessThanOrEqual(occupied.filter { $0 }.count, 4)
        let attachment = XCTAttachment(image: raster.image); attachment.name = "Single table grid \(paper) \(page)"; attachment.lifetime = .keepAlways; add(attachment)
        checked += 1
      }
    }
    XCTAssertEqual(checked, 3, "The fixtures must exercise all three split rowspan owners")

    let table = "# Начало\n\n| Номер | Содержание | Значение |\n| --- | --- | --- |\n" + (0..<100).map { "| \($0) | Одна строка таблицы сохраняет свою геометрию. | \($0 * 3) |" }.joined(separator: "\n")
    let document = DocumentDocument(actor: UUID(), paperSize: .letter, blocks: [.markdown(id: "body", source: table)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let live = surface(document: document, state: state, pageIndex: 2)
    defer { live.close() }
    await waitUntil { live.coordinator.renderIsReady || live.coordinator.acquisitionError != nil }
    XCTAssertNil(live.coordinator.acquisitionError)
    let web = try XCTUnwrap(live.coordinator.webView)
    let raw = try await js("JSON.stringify({x:document.querySelector('table').getBoundingClientRect().left+5,y:document.getElementById('document').getBoundingClientRect().top})", web)
    let point = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Double])
    let raster = try await capturePixels(web), scale = Double(raster.width) / web.bounds.width
    let x = Int(try XCTUnwrap(point["x"]) * scale), y = Int(try XCTUnwrap(point["y"]) * scale)
    func pixel(_ y: Int) -> Data { Data(raster.bytes[((y * raster.width + x) * 4)..<((y * raster.width + x) * 4 + 4)]) }
    XCTAssertEqual(pixel(y), pixel(y - 2), "The paper edge must not repeat a border owned by the preceding page")
  }

  private func capturePixels(_ web: WKWebView) async throws -> (bytes: Data, width: Int, height: Int, image: NSImage) {
    let configuration = WKSnapshotConfiguration(); configuration.rect = web.bounds
    configuration.snapshotWidth = 640; configuration.afterScreenUpdates = true
    let image: NSImage = try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: configuration) { image, error in
        if let error { continuation.resume(throwing: error) }
        else if let image { continuation.resume(returning: image) }
        else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
      }
    }
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    return (Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4), cg.width, cg.height, image)
  }

  func testSharedPreparationOutlivesOnlyItsBorrowedWebKitWhenItsProducerUnmounts() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before")])
    let state = DocumentStateJournal(id: document.id, actor: actor), resources = SceneRenderResources(maximumWebSurfaces: 2)
    let pages = (0..<2).map { surface(document: document, state: state, resources: resources, interactive: $0 == 0) }
    defer { pages.forEach { $0.close() } }
    await waitUntil { pages.allSatisfy { $0.coordinator.renderIsReady } }
    let webs = try pages.map { try XCTUnwrap($0.coordinator.webView) }
    for web in webs {
      _ = try await js("window.sourceEntered=false;window.sourceGate=new Promise(resolve=>window.releaseSource=resolve);window.originalTypeset=MathJax.typesetPromise.bind(MathJax);MathJax.typesetPromise=async nodes=>{sourceEntered=true;await sourceGate;return originalTypeset(nodes)};'armed'", web)
    }
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After $x^2$", actor: actor))
    for page in pages {
      page.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    }
    var producer: Int?
    for _ in 0..<200 {
      for (index, web) in webs.enumerated() where try await js("String(sourceEntered)", web) == "true" { producer = index }
      if producer != nil { break }; try await Task.sleep(for: .milliseconds(10))
    }
    let index = try XCTUnwrap(producer), survivor = 1 - index
    let source = try XCTUnwrap(pages[survivor].coordinator.payload?.source)
    XCTAssertEqual(source.preparationCount, 1)
    pages[index].close()
    XCTAssertEqual(resources.activeWebSurfaceCount, 2, "The submitted source work still owns its original slot")
    _ = try await js("releaseSource();'released'", webs[index])
    await waitUntil { pages[survivor].coordinator.renderIsReady || pages[survivor].coordinator.acquisitionError != nil }
    XCTAssertNil(pages[survivor].coordinator.acquisitionError)
    XCTAssertTrue(pages[survivor].coordinator.renderIsReady)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    let text = try await js("document.getElementById('document').textContent", webs[survivor])
    XCTAssertTrue(text.contains("After")); XCTAssertFalse(text.contains("Before"))
    XCTAssertEqual(source.preparationCount, 1, "The survivor must not repeat the source's MathJax and pagination")
  }

  func testCancelledSourcePreparationHoldsItsSlotUntilActualMathJaxCompletion() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before")])
    let state = DocumentStateJournal(id: document.id, actor: actor), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document: document, state: state, resources: resources)
    await waitUntil { live.coordinator.renderIsReady }
    let web = try XCTUnwrap(live.coordinator.webView)
    _ = try await js("window.sourceEntered=false;window.sourceGate=new Promise(resolve=>window.releaseSource=resolve);window.originalTypeset=MathJax.typesetPromise.bind(MathJax);MathJax.typesetPromise=async nodes=>{sourceEntered=true;await sourceGate;return originalTypeset(nodes)};'armed'", web)
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "Cancelled $x^2$", actor: actor))
    live.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    var entered = false
    for _ in 0..<200 {
      entered = try await js("String(sourceEntered)", web) == "true"
      if entered { break }; try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(entered)
    live.close()
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    let waiter = Task { try await resources.acquireWebSurface(priority: .currentPage) }
    await waitUntil { resources.pendingWebRequestCount == 1 }
    _ = try await js("releaseSource();'released'", web)
    let next = try await waiter.value
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    next.release()
    await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == 0 }
    let abandoned = try await js("String(document.querySelectorAll('.document-layout-preparation').length)", web)
    XCTAssertEqual(abandoned, "0")
  }

  func testPreparationAdmissionFailureRetainsTheSourceUntilAnExplicitRetry() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before")])
    let state = DocumentStateJournal(id: document.id, actor: actor), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document: document, state: state, resources: resources)
    defer { live.close() }
    await waitUntil { live.coordinator.renderIsReady }
    let prior = try XCTUnwrap(live.coordinator.payload?.source), priorLayout = try XCTUnwrap(prior.layout)
    let sourceBytes = resources.reservedBytes
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - sourceBytes, priority: .passive))
    defer { blocker.release() }
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After $y^3$", actor: actor))
    live.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    await waitUntil { live.coordinator.acquisitionError != nil }
    XCTAssertFalse(live.coordinator.renderIsReady)
    XCTAssertNil(live.coordinator.payload?.source.layout)
    XCTAssertTrue(prior.layout === priorLayout)
    await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == sourceBytes + blocker.byteCount }
    blocker.release()
    live.coordinator.mount(in: live.host, physicalSize: .init(width: priorLayout.width, height: priorLayout.height), isInteractive: true, priority: .currentPage)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "A layout/update is not an implicit retry of a rejected preparation")
    func button(_ view: NSView) -> NSButton? {
      (view as? NSButton) ?? view.subviews.lazy.compactMap { button($0) }.first
    }
    try XCTUnwrap(button(live.host)).performClick(nil)
    await waitUntil { live.coordinator.renderIsReady || live.coordinator.acquisitionError != nil }
    XCTAssertTrue(live.coordinator.renderIsReady); XCTAssertNil(live.coordinator.acquisitionError)
    XCTAssertEqual(live.coordinator.payload?.source.preparationCount, 2)
    let text = try await js("document.getElementById('document').textContent", try XCTUnwrap(live.coordinator.webView))
    XCTAssertTrue(text.contains("After"))
  }

  private func centerPixel(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let index = ((image.height / 2) * image.width + image.width / 2) * 4
    return (0..<3).map { bytes[index + $0] }
  }

  func testTallProgramUsesMeasuredContinuationAfterTextWithoutResizingItsViewport() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "before", source: "# Перед программой\n\nЕё начало не совпадает с началом физического листа."),
      .interactive(id: "tall", html: "<input aria-label='Retained input'><div style='height:1900px'>Continuation</div>",
        javaScript: "notebook.commit({boot:crypto.randomUUID(),width:innerWidth,height:innerHeight})", height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots: [JSONValue] = []
    let surface = surface(document: document, state: state, commit: { _, value in boots.append(value) })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady && !boots.isEmpty }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let margin = document.paperSize.marginPoints * geometry.width / document.paperSize.widthPoints
    let boot = try XCTUnwrap(boots.first)
    XCTAssertEqual(try XCTUnwrap(boot["width"]).decode(Double.self), geometry.width - 2 * margin, accuracy: 1)
    XCTAssertEqual(boot["height"], .number(2048))
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    let count = try XCTUnwrap(source.layout).pageCount
    var regions: [[String: Any]] = []
    for page in 0..<count {
      surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed },
        onStateChange: { _, value in boots.append(value) })
      await waitUntil { surface.coordinator.renderIsReady }
      let raw = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().regions.filter(region=>region.id==='tall'))", web)
      regions += try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
    }
    XCTAssertGreaterThan(regions.count, 1)
    XCTAssertGreaterThan(try XCTUnwrap(regions.first?["y"] as? Double), margin)
    var offset = 0.0
    for region in regions {
      XCTAssertEqual(try XCTUnwrap(region["sourceOffset"] as? Double), offset, accuracy: 1.0 / 32)
      offset += try XCTUnwrap(region["height"] as? Double)
    }
    XCTAssertEqual(offset, 2048, accuracy: 1.0 / 32, "The measured fragments partition the full program, including a partial first page")
    _ = try await js("window.retainedTall=document.querySelector('iframe'); 'retained'", web)
    let before = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().work)", web)
    for region in regions + Array(regions.reversed()) {
      let page = try XCTUnwrap(region["pageIndex"] as? Int)
      surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed },
        onStateChange: { _, value in boots.append(value) })
      await waitUntil { surface.coordinator.renderIsReady || surface.coordinator.acquisitionError != nil }
      XCTAssertNil(surface.coordinator.acquisitionError)
      let rawFrame = try await js("""
        JSON.stringify({same:retainedTall===document.querySelector('iframe'),
          offset:-parseFloat(retainedTall.style.top),height:parseFloat(retainedTall.style.height),
          cutHeight:parseFloat(retainedTall.parentElement.style.height),
          cutWidth:parseFloat(retainedTall.parentElement.style.width)})
        """, web)
      let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawFrame.utf8)) as? [String: Any])
      XCTAssertEqual(frame["same"] as? Bool, true)
      XCTAssertEqual(frame["height"] as? Double, 2048)
      XCTAssertEqual(frame["offset"] as? Double, region["sourceOffset"] as? Double)
      XCTAssertEqual(frame["cutHeight"] as? Double, region["height"] as? Double)
      XCTAssertEqual(frame["cutWidth"] as? Double, region["width"] as? Double)
    }
    let after = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().work)", web)
    let firstWork = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Int])
    let lastWork = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Int])
    for key in ["sourceInstalls", "layoutPasses", "regionMeasurements", "typesetPasses"] {
      XCTAssertEqual(firstWork[key], lastWork[key], "Turning a continuation does not repeat \(key)")
    }
    XCTAssertEqual(boots.count, 1)
  }

  func testRestoredDraftSurvivesWebProcessRecoveryAndRecoveryIsBounded() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Исходник")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: document.id, blockID: "body", baseSource: "Исходник",
      baseVersion: document.sourceVersion(blockID: "body"), source: "Несохранённая мысль", sequence: 8)
    let surface = surface(document: document, state: state, drafts: [.init(edit: edit, selectionStart: 2, selectionEnd: 4)])
    defer { surface.close() }
    for _ in 0..<2 {
      await waitUntil { surface.coordinator.renderIsReady }
      let web = try XCTUnwrap(surface.coordinator.webView)
      let actual8 = try await js("document.querySelector('textarea').value", web)
      XCTAssertEqual(actual8, edit.source)
      surface.coordinator.webViewWebContentProcessDidTerminate(web)
    }
    await waitUntil { surface.coordinator.renderIsReady }
    surface.coordinator.webViewWebContentProcessDidTerminate(try XCTUnwrap(surface.coordinator.webView))
    XCTAssertNotNil(surface.coordinator.acquisitionError)
    XCTAssertNil(surface.coordinator.webView)
  }

  func testLayoutHistoryCannotSurviveAsAVisibleReceipt() async throws {
    let registry = DocumentRenderRegistry(), document = DocumentDocument(actor: UUID())
    let state = DocumentStateJournal(id: document.id, actor: UUID()), hostID = UUID()
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    registry.publishLive(documentID: document.id, token: token, pageIndex: 0, hostID: hostID, generation: 2, isAttached: { true })
    registry.revokeLive(hostID: hostID, through: 1)
    XCTAssertTrue(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
    registry.revokeLive(hostID: hostID, through: 2)
    XCTAssertFalse(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
  }

  func testThumbnailBorrowsTheLivePagePixelsWithoutStartingAnotherProgram() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program", html: "<p>Живой источник</p>",
      javaScript: "notebook.commit({boot:crypto.randomUUID()})", initialState: .null, height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var bootCount = 0
    let live = surface(document: document, state: state, resources: resources, commit: { _,_ in bootCount += 1 })
    defer { live.close() }
    await waitUntil { live.coordinator.renderIsReady && bootCount == 1 }
    let originalWeb = try XCTUnwrap(live.coordinator.webView)
    let paper = WorkspaceItemGeometry.document(document.paperSize)
    XCTAssertEqual(originalWeb.bounds.size, CGSize(width: paper.width, height: paper.height),
      "The helper window rounds its bounds; the physical WebKit viewport must not inherit that rounding")
    let thumbnail = surface(document: document, state: state, resources: resources, snapshotPixelWidth: 256)
    defer { thumbnail.close() }
    await waitUntil { thumbnail.host.hasSnapshot }
    XCTAssertNil(thumbnail.coordinator.acquisitionError)
    XCTAssertNil(thumbnail.coordinator.webView)
    XCTAssertTrue(live.coordinator.webView === originalWeb)
    XCTAssertTrue(live.coordinator.acceptsInput)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(bootCount, 1)
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    defer { raster.release() }
    XCTAssertLessThanOrEqual(try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil)).width, 256)
    XCTAssertLessThan(raster.pixelScale, 1)
    XCTAssertNil(resources.retainRaster(for: source, minimumScale: 2), "A borrowed thumbnail is not an exact export")
  }

  func testMacDocumentHostKeepsCanonicalPaperWhenTheHelperWindowChangesSize() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Один физический лист")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let paper = WorkspaceItemGeometry.document(document.paperSize), canonical = CGSize(width: paper.width, height: paper.height)
    XCTAssertEqual(web.bounds.size, canonical)
    surface.window.setContentSize(.init(width: canonical.width + 17, height: canonical.height + 29))
    surface.host.layoutSubtreeIfNeeded()
    XCTAssertEqual(web.bounds.size, canonical)
    let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 256)
    defer { raster.release() }
    let bitmap = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertLessThanOrEqual(bitmap.width, 256)
    XCTAssertGreaterThanOrEqual(bitmap.height, Int(floor(Double(bitmap.width) * canonical.height / canonical.width)))
    XCTAssertEqual(raster.image.size, canonical)
  }

  func testAgentStateAndPlacementKeepProgramFocusAndUncommittedInput() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false, commits: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { commits.append($0) })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let original = AgentElement(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "counter", html: "<input><button>Next</button>", javaScript: """
      window.boot=Math.random().toString();
      document.querySelector('button').onclick=()=>notebook.commit({count:(notebook.state.count||0)+1});
      """, state: .object(["count": .number(0)]))
    coordinator.load(original, in: web)
    await waitUntil { ready }
    let token = coordinator.loadToken, boot = try await js("window.boot", web)
    _ = try await js("document.querySelector('input').value='UNCOMMITTED INPUT'; document.querySelector('button').click(); 'clicked'", web)
    await waitUntil { commits.count == 1 }
    let echoed = original.updating(state: try XCTUnwrap(commits.last))
    ready = false; coordinator.load(echoed, in: web)
    await waitUntil { ready }
    let moved = echoed.updating(frame: .init(x: 100, y: 200, width: 240, height: 120))
    coordinator.load(moved, in: web)
    let sameBoot = try await js("window.boot", web)
    let input = try await js("document.querySelector('input').value", web)
    XCTAssertEqual(sameBoot, boot)
    XCTAssertEqual(input, "UNCOMMITTED INPUT")
    XCTAssertEqual(coordinator.loadToken, token)
    _ = try await js("document.querySelector('button').click(); 'clicked again'", web)
    await waitUntil { commits.count == 2 }
    XCTAssertEqual(commits.last, .object(["count": .number(2)]))
    XCTAssertNotNil(resources.image(for: moved))
  }

  func testRepeatedRendererMountDoesNotInvalidateObservation() async throws {
    let registry = DocumentRenderRegistry(), resources = SceneRenderResources()
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    defer { coordinator.invalidate() }
    let hostID = UUID(), documentID = UUID()
    let invalidation = expectation(description: "Transient renderer bookkeeping is not SwiftUI content")
    invalidation.isInverted = true
    withObservationTracking {
      registry.mountRenderer(coordinator, hostID: hostID)
      _ = registry.rasterProducer(documentID: documentID, token: "source", resources: resources, excluding: UUID())
    } onChange: { invalidation.fulfill() }
    for _ in 0..<100 {
      registry.mountRenderer(coordinator, hostID: hostID)
      registry.publishLive(documentID: documentID, token: "source", pageIndex: 0, hostID: hostID, generation: 1, isAttached: { false })
    }
    registry.unmountRenderer(hostID: hostID)
    await fulfillment(of: [invalidation], timeout: 0.05)
  }

  func testDraftHandoffDrainsOldEditorAndPassiveHostDoesNotPublishASecondWriter() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Исходный текст")])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources(maximumWebSurfaces: 2)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: document.id, blockID: "body", baseSource: document.blocks[0].source,
      baseVersion: document.sourceVersion(blockID: "body"), source: "Черновик", sequence: 5)
    let draft = DocumentEditingSession(edit: edit, selectionStart: 2, selectionEnd: 2)
    var oldWrites: [DocumentEditingSession] = [], nextWrites: [DocumentEditingSession] = []
    let current = surface(document: document, state: state, resources: resources, drafts: [draft], draft: { oldWrites.append($0) })
    defer { current.close() }
    let neighbor = surface(document: document, state: state, resources: resources, interactive: false, drafts: [draft], draft: { nextWrites.append($0) })
    defer { neighbor.close() }
    await waitUntil { current.coordinator.renderIsReady && neighbor.coordinator.renderIsReady }
    XCTAssertTrue(oldWrites.isEmpty); XCTAssertTrue(nextWrites.isEmpty)
    let oldWeb = try XCTUnwrap(current.coordinator.webView), nextWeb = try XCTUnwrap(neighbor.coordinator.webView)
    let passiveEditor = try await js("String(document.querySelectorAll('textarea').length)", nextWeb)
    XCTAssertEqual(passiveEditor, "0")
    _ = try await js("document.querySelector('textarea').value='Последние символы перед перелистыванием'; 'last input'", oldWeb)
    let size = WorkspaceItemGeometry.document(document.paperSize)
    neighbor.coordinator.mount(in: neighbor.host, physicalSize: .init(width: size.width, height: size.height), isInteractive: true, priority: .currentPage)
    await waitUntil { neighbor.coordinator.ownsEditing && oldWrites.last?.edit.source == "Последние символы перед перелистыванием" }
    let transferred = try await js("document.querySelector('textarea').value", nextWeb)
    XCTAssertEqual(transferred, "Последние символы перед перелистыванием")
    XCTAssertTrue(nextWrites.isEmpty, "Restoring a draft does not allocate another input sequence")
    XCTAssertFalse(current.coordinator.ownsEditing)
    DocumentRenderRegistry.shared.removeDraft(documentID: document.id, sessionID: edit.sessionID)
    XCTAssertFalse(DocumentRenderRegistry.shared.recordDraft(draft), "A late old host cannot reopen a finished editing session")
  }

  func testStateEchoDoesNoSourceDOMLayoutOrMathWorkAndKeepsTheComposingEditor() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "body", source: "# Источник $x^2$\n\nНе менять редактор при обновлении модели."),
      .interactive(id: "counter", html: "<input><output></output>", javaScript:
        "document.querySelector('input').value='uncommitted'; notebook.commit({boot:crypto.randomUUID()});", height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    var commits: [JSONValue] = [], drafts: [DocumentEditingSession] = []
    let surface = surface(document: document, state: state, draft: { drafts.append($0) }, commit: { _, value in commits.append(value) })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady && commits.count == 1 }
    let web = try XCTUnwrap(surface.coordinator.webView), source = try XCTUnwrap(surface.coordinator.payload?.source)
    _ = try await js("""
      document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.savedEditor=document.querySelector('textarea');window.savedFrame=document.querySelector('iframe');
      savedEditor.value='Незавершённый ввод 👩‍💻';savedEditor.setSelectionRange(3,7);
      savedEditor.dispatchEvent(new Event('compositionstart'));savedEditor.dispatchEvent(new Event('input'));
      window.flowMutations=0;window.flowObserver=new MutationObserver(changes=>window.flowMutations+=changes.length);
      flowObserver.observe(document.getElementById('document'),{subtree:true,childList:true,attributes:true,characterData:true});
      JSON.stringify(window.notebookRenderer.pageReceipt().work)
      """, web)
    let before = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().work)", web)
    let firstWork = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Int])
    for count in 1...12 {
      XCTAssertTrue(state.commit(blockID: "counter", value: .object(["count": .number(Double(count))]), actor: UUID()))
      surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed },
        onStateChange: { _, value in commits.append(value) }, onDraftChange: { drafts.append($0) })
      await waitUntil { surface.coordinator.renderIsReady }
    }
    let after = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().work)", web)
    let finalWork = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Int])
    for key in ["sourceInstalls", "layoutPasses", "regionMeasurements", "typesetPasses"] {
      XCTAssertEqual(finalWork[key], firstWork[key], "State delivery cannot repeat \(key)")
    }
    XCTAssertGreaterThan(try XCTUnwrap(finalWork["stateApplications"]), try XCTUnwrap(firstWork["stateApplications"]))
    let actual = try await js("JSON.stringify({sameEditor:savedEditor===document.querySelector('textarea'),sameFrame:savedFrame===document.querySelector('iframe'),text:savedEditor.value,start:savedEditor.selectionStart,end:savedEditor.selectionEnd,mutations:flowMutations})", web)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(actual.utf8)) as? [String: Any])
    XCTAssertEqual(value["sameEditor"] as? Bool, true); XCTAssertEqual(value["sameFrame"] as? Bool, true)
    XCTAssertEqual(value["text"] as? String, "Незавершённый ввод 👩‍💻")
    XCTAssertEqual(value["start"] as? Int, 3); XCTAssertEqual(value["end"] as? Int, 7)
    XCTAssertEqual(value["mutations"] as? Int, 0)
    XCTAssertEqual(drafts.last?.isComposing, true)
    XCTAssertEqual(commits.count, 1, "The iframe browsing context must not boot again")
    XCTAssertTrue(surface.coordinator.payload?.source === source); XCTAssertEqual(source.encodingCount, 1)
  }

  func testPreparedMathKeepsItsPixelsInAnotherWebKitWithoutASecondTypeset() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "inline", source: "# Общая формула $x^2+y^2=z^2$\n\nТекст с $\\frac{1}{n}$ и математическими символами.\n\n👩🏽‍💻 Семья 👨‍👩‍👧‍👦 и e\u{0301}. العربية تحفظ ترتيب النص. 中文文字保持完整。"),
      .latex(id: "display", source: #"\int_0^1 x^2\,dx=\frac13"#)
    ])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources(maximumWebSurfaces: 2)
    let producer = surface(document: document, state: state, resources: resources)
    defer { producer.close() }
    await waitUntil { producer.coordinator.renderIsReady || producer.coordinator.acquisitionError != nil }
    let neighbor = surface(document: document, state: state, resources: resources, interactive: false)
    defer { neighbor.close() }
    await waitUntil { neighbor.coordinator.renderIsReady || neighbor.coordinator.acquisitionError != nil }
    XCTAssertNil(producer.coordinator.acquisitionError); XCTAssertNil(neighbor.coordinator.acquisitionError)
    let source = try XCTUnwrap(producer.coordinator.payload?.source)
    XCTAssertTrue(neighbor.coordinator.payload?.source === source); XCTAssertEqual(source.preparationCount, 1)
    var pictures: [Data] = [], typesets = 0
    for (index, page) in [producer, neighbor].enumerated() {
      let web = try XCTUnwrap(page.coordinator.webView)
      let raw = try await js("JSON.stringify({work:notebookRenderer.pageReceipt().work,styles:[...document.querySelectorAll('style')].map(node=>({id:node.id,text:node.textContent})),math:[...document.querySelectorAll('mjx-container')].map(node=>({box:node.getBoundingClientRect().toJSON(),display:getComputedStyle(node).display}))})", web)
      let evidence = XCTAttachment(string: raw); evidence.name = "Shared math runtime \(index)"; evidence.lifetime = .keepAlways; add(evidence)
      let value = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      typesets += (value["work"] as? [String: Int])?["typesetPasses"] ?? -100
      let raster = try await capturePixels(web); pictures.append(raster.bytes)
      let image = XCTAttachment(image: raster.image); image.name = "Shared math pixels \(index)"; image.lifetime = .keepAlways; add(image)
    }
    XCTAssertEqual(typesets, 1)
    guard pictures[0] == pictures[1] else { throw NSError(domain: "NotebookSharedMathPixels", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "A physical neighbor lost the prepared mathematical styles or pixels"]) }
  }

  func testFourRealPageWebKitsShareInputsAndOneAcceptedLayoutWithoutAnotherWebSurface() async throws {
    let prose = (0..<80).map { "Абзац \($0). " + String(repeating: "Одна геометрия исходника и четыре физических листа. ", count: 4) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Общая сессия $x^2$\n\n" + prose)])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources(maximumWebSurfaces: 6)
    let pages = (0..<4).map { surface(document: document, state: state, resources: resources, interactive: $0 == 0, pageIndex: $0) }
    defer { pages.forEach { $0.close() } }
    await waitUntil { pages.allSatisfy { $0.coordinator.renderIsReady } || pages.contains { $0.coordinator.acquisitionError != nil } }
    let source = try XCTUnwrap(pages[0].coordinator.payload?.source), layout = try XCTUnwrap(source.layout)
    XCTAssertGreaterThanOrEqual(layout.pageCount, 4)
    var layoutPasses = 0, typesetPasses = 0
    for (index, page) in pages.enumerated() {
      XCTAssertNil(page.coordinator.acquisitionError)
      XCTAssertTrue(page.coordinator.renderIsReady)
      XCTAssertTrue(page.coordinator.payload?.source === source)
      XCTAssertTrue(page.coordinator.payload?.state === pages[0].coordinator.payload?.state)
      XCTAssertTrue(DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: index)?.layout === layout)
      let web = try XCTUnwrap(page.coordinator.webView)
      let pageNumber = try await js("String(window.notebookRenderer.pageReceipt().pageIndex)", web)
      XCTAssertEqual(pageNumber, String(index))
      let raw = try await js("JSON.stringify({work:notebookRenderer.pageReceipt().work,scope:notebookRenderer.pageReceipt().layoutScope,regions:notebookRenderer.pageReceipt().regions,domText:document.getElementById('document').textContent,preparations:document.querySelectorAll('.document-layout-preparation').length,sheets:document.querySelectorAll('.paper-sheet').length})", web)
      let measured = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      let work = try XCTUnwrap(measured["work"] as? [String: Int])
      layoutPasses += work["layoutPasses"] ?? -100; typesetPasses += work["typesetPasses"] ?? -100
      XCTAssertEqual(measured["scope"] as? String, "page")
      XCTAssertEqual(measured["preparations"] as? Int, 0, "The measured full DOM must retire after compilation")
      XCTAssertEqual(measured["sheets"] as? Int, 1)
      XCTAssertLessThan(try XCTUnwrap(measured["domText"] as? String).count, prose.count / 2)
      let regions = try XCTUnwrap(measured["regions"] as? [[String: Any]])
      XCTAssertTrue(regions.allSatisfy { $0["pageIndex"] as? Int == index })
    }
    XCTAssertEqual(layoutPasses, 1); XCTAssertEqual(typesetPasses, 1)
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertEqual(source.encodingCount, 1)
    XCTAssertEqual(pages[0].coordinator.payload?.state.encodingCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 4); XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testNewSourceAndStateWaitBehindAnActualTypesetWithoutChangingThePendingFrameInputs() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Original")])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    _ = try await js("""
      window.typesetEntered=false;
      window.typesetGate=new Promise(resolve=>window.releaseTypeset=resolve);
      window.originalTypeset=MathJax.typesetPromise.bind(MathJax);
      MathJax.typesetPromise=async nodes=>{window.typesetEntered=true;await typesetGate;return originalTypeset(nodes)};
      'typeset gate installed'
      """, web)
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "Intermediate $x^2$", actor: actor))
    func update() {
      surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    }
    update()
    var entered = false
    for _ in 0..<200 {
      if try await js("String(window.typesetEntered)", web) == "true" { entered = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(entered, "The first source must actually be awaiting MathJax before the next update")
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "Latest $y^3$", actor: actor))
    XCTAssertTrue(state.commit(blockID: "counter", value: .number(9), actor: actor))
    update()
    let expected = try XCTUnwrap(surface.coordinator.payload)
    _ = try await js("window.releaseTypeset(); 'released'", web)
    await waitUntil { surface.coordinator.renderIsReady }
    let text = try await js("document.getElementById('document').textContent", web)
    XCTAssertTrue(text.contains("Latest")); XCTAssertFalse(text.contains("Intermediate"))
    XCTAssertFalse(text.contains("Original"))
    let childIDs = try await js("JSON.stringify([...document.getElementById('document').children].map(node=>node.dataset.blockId))", web)
    XCTAssertEqual(childIDs, "[\"body\"]", "Replacing a block must remove its old flow node, not just its lookup entry")
    let sourceKey = try await js("window.notebookRenderer.pageReceipt().sourceKey", web)
    let stateKey = try await js("window.notebookRenderer.pageReceipt().stateKey", web)
    XCTAssertEqual(sourceKey, expected.source.message.key); XCTAssertEqual(stateKey, expected.state.message.key)
    XCTAssertEqual(surface.coordinator.renderedToken, expected.renderToken)
    XCTAssertNil(surface.coordinator.acquisitionError)
    var obsolete = ["Original", "Intermediate", "Latest"]
    for revision in 1...3 {
      let marker = "Replacement-\(revision)"
      XCTAssertTrue(document.replaceBlockSource(id: "body", source: "\(marker) $z^{\(revision)}$", actor: actor))
      update()
      await waitUntil { surface.coordinator.renderIsReady }
      let text = try await js("document.getElementById('document').textContent", web)
      XCTAssertTrue(text.contains(marker))
      for old in obsolete { XCTAssertFalse(text.contains(old), "The superseded source \(old) must leave the DOM") }
      let childIDs = try await js("JSON.stringify([...document.getElementById('document').children].map(node=>node.dataset.blockId))", web)
      XCTAssertEqual(childIDs, "[\"body\"]")
      let mathCount = try await js("String(document.querySelectorAll('#document mjx-container').length)", web)
      XCTAssertEqual(mathCount, "1", "MathJax must retain only the replacement's rendered expression")
      XCTAssertNil(surface.coordinator.acquisitionError)
      obsolete.append(marker)
    }
  }

  func testTwoSynchronousGenerationsKeepTheLatestUnfinishedProgramBounded() async throws {
    let actor = UUID(), resources = SceneRenderResources(maximumWebSurfaces: 1)
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Готовая страница")])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    XCTAssertTrue(document.replaceContent(blocks: document.blocks + [.interactive(id: "never-ready", html: "<p>Ожидание программы</p>",
      javaScript: "notebook.ready(new Promise(()=>{}));", height: 100)], actor: actor))
    func update() {
      surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    }
    // Both accepted generations precede the sender Task's first opportunity to
    // execute. Its first deadline cannot be left naming the superseded one.
    update()
    XCTAssertTrue(state.commit(blockID: "never-ready", value: .number(1), actor: actor))
    update()
    let web = try XCTUnwrap(surface.coordinator.webView)
    var started = false
    for _ in 0..<200 {
      if try await js("String(document.querySelectorAll('iframe').length)", web) == "1" { started = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(started, "The bounded failure must come from the real pending program, not a missing shell")
    // The production deadline remains eight seconds. This observation window
    // allows it to fire; it does not replace WebKit readiness with a test timer.
    await waitUntil(timeout: .seconds(10)) { surface.coordinator.acquisitionError != nil }
    XCTAssertEqual(surface.coordinator.acquisitionError as? SceneRenderError,
      .snapshotPending("document_preparation_timeout"))
    XCTAssertFalse(surface.coordinator.renderIsReady)
    XCTAssertNil(surface.coordinator.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  private func execute(_ script: String, arguments: [String: Any], in web: WKWebView) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value):
          if value as? Bool == true { continuation.resume() }
          else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }

  private func js(_ source: String, _ web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(source) { value, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value as? String ?? String(describing: value)) }
      }
    }
  }

  private func waitUntil(timeout: Duration = .seconds(8), file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The real WebKit surface did not complete its bounded preparation", file: file, line: line)
  }
}
