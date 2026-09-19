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
    commit: @escaping (String, JSONValue) -> ContentFieldVersion? = { _,_ in nil }) -> Surface {
    let resources = suppliedResources ?? SceneRenderResources(maximumWebSurfaces: 4)
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: commit)
    coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: snapshotPixelWidth != nil,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: commit,
      snapshotPixelWidth: snapshotPixelWidth)
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: interactive && snapshotPixelWidth == nil,
      priority: snapshotPixelWidth == nil ? (interactive ? .currentPage : .neighbor) : .visible)
    return .init(coordinator: coordinator, host: host, window: window)
  }

  func testDocumentBoundarySavesTheAnimatedModelAndResumesTheSamePrograms() async throws {
    let actor = UUID()
    let document = DocumentDocument(actor: actor, blocks: [.interactive(id: "clock", html: "<output></output>", javaScript: """
      let phase=0,timer;const start=()=>{timer=setInterval(()=>{phase++;document.querySelector('output').textContent=phase},10)};
      notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume:start,dispose(){clearInterval(timer)}});
      notebook.ready(Promise.resolve().then(start));
      """, initialState: .object(["phase": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    surface.coordinator.onStateCheckpoint = { id, value, source, basis in
      guard source == document.sourceVersion(blockID: id), state.records.first(where: { $0.id == id })?.valueVersion == basis else { return nil }
      _ = state.commit(blockID: id, value: value, actor: actor)
      return state.records.first { $0.id == id }?.valueVersion
    }
    await waitUntil { surface.coordinator.renderIsReady }
    try await Task.sleep(for: .milliseconds(120))
    let saved = await surface.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(saved)
    let first = try XCTUnwrap(state.value(for: "clock"))
    guard case .number(let phase) = first["phase"] else { return XCTFail("The actual model must reach the writer") }
    XCTAssertGreaterThan(phase, 0)
    // Do not provide a SwiftUI echo: the durable receipt itself must advance
    // the iframe's basis and prevent resume from restoring its previous value.
    let frozen = await surface.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(frozen)
    XCTAssertEqual(state.value(for: "clock"), first)
    let web = surface.coordinator.webView
    await surface.coordinator.resumePrograms()
    try await Task.sleep(for: .milliseconds(120))
    let next = await surface.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(next)
    guard case .number(let later) = state.value(for: "clock")?["phase"] else { return XCTFail("Missing resumed checkpoint") }
    XCTAssertGreaterThan(later, phase)
    XCTAssertTrue(surface.coordinator.webView === web)
  }

  func testCodeModeStopsTheSameProgramUntilItsCheckpointIsDurable() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before"),
      .interactive(id: "clock", html: "<output></output>", javaScript: """
      let phase=0,timer;const start=()=>{timer=setInterval(()=>{phase++;document.querySelector('output').textContent=phase},10)};
      notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume:start,dispose(){clearInterval(timer)}});
      notebook.ready(Promise.resolve().then(start));
      """, initialState: .object(["phase": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    surface.coordinator.ownsProgramState = true
    var entered = false, release = false, refuse = false
    surface.coordinator.onStateCheckpoint = { id, value, _, _ in
      if refuse { throw CocoaError(.fileWriteUnknown) }
      entered = true
      while !release { try await Task.sleep(for: .milliseconds(5)) }
      _ = state.commit(blockID: id, value: value, actor: actor)
      return state.records.first { $0.id == id }?.valueVersion
    }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    func phase() async throws -> Int {
      let value = try await web.callAsyncJavaScript("return (await notebookRenderer.checkpointPrograms())[0].state.phase;", arguments: [:], in: nil, contentWorld: .page)
      return try XCTUnwrap(value as? Int)
    }
    try await Task.sleep(for: .milliseconds(80))
    surface.coordinator.setProgramsVisible(false)
    await waitUntil { entered }
    surface.coordinator.setProgramsVisible(true) // return while disk is still busy
    let frozen = try await phase()
    try await Task.sleep(for: .milliseconds(100))
    let stillFrozen = try await phase()
    XCTAssertEqual(frozen, stillFrozen)
    release = true
    await waitUntil { state.value(for: "clock") != nil }
    try await Task.sleep(for: .milliseconds(120))
    let resumed = try await phase()
    XCTAssertGreaterThan(resumed, frozen)
    surface.coordinator.setProgramsVisible(false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After", actor: actor))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    await waitUntil { surface.coordinator.renderIsReady }
    let after = try await phase()
    try await Task.sleep(for: .milliseconds(100))
    let unchanged = try await phase()
    XCTAssertEqual(after, unchanged, "An unrelated source edit cannot start hidden programs")
    refuse = true
    surface.coordinator.setProgramsVisible(true)
    try await Task.sleep(for: .milliseconds(120))
    let refused = try await phase()
    XCTAssertEqual(refused, unchanged, "Writer failure cannot resume or reset a frozen heap")
    refuse = false
    surface.coordinator.setProgramsVisible(false)
    surface.coordinator.setProgramsVisible(true)
    try await Task.sleep(for: .milliseconds(120))
    let retried = try await phase()
    XCTAssertGreaterThan(retried, refused)
    XCTAssertTrue(surface.coordinator.webView === web)
  }

  func testDocumentDismantleKeepsItsBrowserUntilTheWriterAcceptsCheckpoint() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "clock", html: "<output>0.75</output>",
      javaScript: "notebook.lifecycle({checkpoint:()=>({phase:0.75})});notebook.ready(Promise.resolve());",
      initialState: .object(["phase": .number(0)]), height: 100)])
    let resources = SceneRenderResources(maximumWebSurfaces: 2), actor = UUID()
    var state = DocumentStateJournal(id: document.id, actor: actor), entered = false, release = false
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    surface.coordinator.onStateCheckpoint = { id, value, _, _ in
      entered = true
      while !release { try await Task.sleep(for: .milliseconds(5)) }
      _ = state.commit(blockID: id, value: value, actor: actor)
      return state.records.first { $0.id == id }?.valueVersion
    }
    await waitUntil { surface.coordinator.renderIsReady }
    surface.coordinator.retireAfterProgramCheckpoint()
    await waitUntil { entered }
    XCTAssertFalse(surface.coordinator.isInvalidated)
    XCTAssertGreaterThan(resources.activeWebSurfaceCount, 0)
    release = true
    await waitUntil { surface.coordinator.isInvalidated }
    XCTAssertEqual(state.value(for: "clock"), .object(["phase": .number(0.75)]))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
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
    XCTAssertNotNil(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0))
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0),
      "An offscreen layout is not a human-visible frame")
  }

  func testRegistryBorrowsLayoutFromLiveSourceThenItsRasterAndReleasesAfterEviction() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Measured source\n\nIts raster retains the same addresses.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    weak let layout = surface.coordinator.payload?.source.layout
    let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 320)
    surface.close()
    XCTAssertNotNil(layout)
    XCTAssertTrue(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0)?.layout === layout)
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    raster.release()
    await waitUntil { resources.activeWebSurfaceCount == 0 }
    let replacement = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit, priority: .passive))
    XCTAssertNil(layout)
    XCTAssertNil(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0))
    XCTAssertEqual(DocumentRenderRegistry.shared.layoutReferenceCount(documentID: document.id), 0,
      "Expired addresses and diagnostics must leave with their measured owner")
    XCTAssertEqual(resources.reservedBytes, resources.passiveByteLimit)
    replacement.release()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testStateEchoAndUnrelatedSourceKeepTheSameInteractiveBrowsingContext() async throws {
    var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "До"),
      .interactive(id: "counter", html: "<button>Счётчик</button>", javaScript: "notebook.commit({boot:crypto.randomUUID(),count:notebook.state.count||0});notebook.ready(Promise.resolve());", initialState: .object(["count": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    var commits: [JSONValue] = []
    let surface = surface(document: document, state: state, commit: { _, value in commits.append(value); return nil })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady && commits.count == 1 }
    let web = try XCTUnwrap(surface.coordinator.webView), token = surface.coordinator.payload?.blockTokens["counter"]
    _ = try await js("window.originalFrame=document.querySelector('iframe'); 'stored'", web)
    XCTAssertTrue(state.commit(blockID: "counter", value: .object(["count": .number(42)]), actor: UUID()))
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "После", actor: UUID()))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, value in commits.append(value); return nil })
    await waitUntil { surface.coordinator.renderIsReady }
    let actual3 = try await js("window.originalFrame===document.querySelector('iframe')?'same':'replaced'", web)
    XCTAssertEqual(actual3, "same")
    XCTAssertEqual(surface.coordinator.payload?.blockTokens["counter"], token)
    XCTAssertEqual(commits.count, 1, "Keeping an iframe node is insufficient: its boot must not execute a second time")
  }

  func testCoalescedSourceReplacementCannotReuseThePreviousProgramContext() async throws {
    let html = "<button>Original source</button>"
    var document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program", html: html,
      javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve());", height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots: [JSONValue] = []
    let mounted = surface(document: document, state: state, commit: { _, value in boots.append(value); return nil })
    defer { mounted.close() }
    await waitUntil { mounted.coordinator.renderIsReady && boots.count == 1 }
    let web = try XCTUnwrap(mounted.coordinator.webView), previousVersion = document.sourceVersion(blockID: "program")
    _ = try await js("window.previousProgram=document.querySelector('iframe');'stored'", web)
    XCTAssertTrue(document.replaceBlockSource(id: "program", source: "<button>Replaced source</button>", actor: UUID()))
    XCTAssertTrue(document.replaceBlockSource(id: "program", source: html, actor: UUID()))
    XCTAssertNotEqual(document.sourceVersion(blockID: "program"), previousVersion)
    mounted.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, value in boots.append(value); return nil })
    await waitUntil { mounted.coordinator.renderIsReady && boots.count == 2 }
    let replaced = try await js("previousProgram!==document.querySelector('iframe')?'replaced':'same'", web)
    XCTAssertEqual(replaced, "replaced", "Byte equality after coalesced edits cannot revive an obsolete source identity")
    XCTAssertNotEqual(boots.first, boots.last)
  }



  func testPrewarmExecutesOnlyProgramsOnItsPhysicalPage() async throws {
    let blocks = (0..<16).map { index in DocumentBlock.interactive(id: "block-\(index)", html: "<p>\(index)</p>",
      javaScript: "notebook.commit({boot:\(index)});notebook.ready(Promise.resolve());", initialState: .null, height: 280) }
    let document = DocumentDocument(actor: UUID(), blocks: blocks), state = DocumentStateJournal(id: document.id, actor: UUID())
    var booted = Set<String>()
    let surface = surface(document: document, state: state, commit: { block, _ in booted.insert(block); return nil })
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
    let expected = Set(DocumentRenderRegistry.shared.regions(document: document).filter { $0.pageIndex == 0 }.map(\.id))
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
      javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve());", initialState: .null, height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots = 0
    let surface = surface(document: document, state: state, commit: { _,_ in boots += 1; return nil })
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
          onRenderReady: .init { _ in }, onPageLayout: { _ in },
          onStateChange: { _,_ in boots += 1; return nil })
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

  func testQueuedPreparationKeepsItsSourceBeyondTheExecutionDeadline() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before")])
    let state = DocumentStateJournal(id: document.id, actor: actor), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document: document, state: state, resources: resources)
    defer { live.close() }
    await waitUntil { live.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(live.coordinator.webView)
    let prior = try XCTUnwrap(live.coordinator.payload?.source), priorLayout = try XCTUnwrap(prior.layout)
    await prior.discardIdlePreparation()
    let sourceBytes = resources.reservedBytes
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - sourceBytes, priority: .passive))
    defer { blocker.release() }
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After $y^3$", actor: actor))
    live.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    await waitUntil { resources.pendingDerivedRequestCount == 1 }
    try await Task.sleep(for: .milliseconds(8_250))
    XCTAssertNil(live.coordinator.acquisitionError, "Waiting for actual bytes is not failed WebKit execution")
    XCTAssertFalse(live.coordinator.renderIsReady)
    XCTAssertNil(live.coordinator.payload?.source.layout)
    XCTAssertTrue(prior.layout === priorLayout)
    XCTAssertTrue(live.coordinator.webView === web)
    blocker.release()
    await waitUntil { live.coordinator.hasCanonicalPixels || live.coordinator.acquisitionError != nil }
    XCTAssertTrue(live.coordinator.hasCanonicalPixels); XCTAssertNil(live.coordinator.acquisitionError)
    XCTAssertTrue(live.coordinator.webView === web, "Admission resumes the same request without a hidden retry")
    XCTAssertEqual(live.coordinator.payload?.source.preparationCount, 1)
    XCTAssertEqual(live.coordinator.payload?.source.measurementCount, 1)
    let text = try await js("document.getElementById('document').textContent", web)
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
        javaScript: "notebook.commit({boot:crypto.randomUUID(),width:innerWidth,height:innerHeight});notebook.ready(Promise.resolve());", height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots: [JSONValue] = []
    let surface = surface(document: document, state: state, commit: { _, value in boots.append(value); return nil })
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
        onRenderReady: .init { _ in }, onPageLayout: { _ in },
        onStateChange: { _, value in boots.append(value); return nil })
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
        onRenderReady: .init { _ in }, onPageLayout: { _ in },
        onStateChange: { _, value in boots.append(value); return nil })
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


  func testLayoutHistoryCannotSurviveAsAVisibleReceipt() async throws {
    let registry = DocumentRenderRegistry(), document = DocumentDocument(actor: UUID())
    let state = DocumentStateJournal(id: document.id, actor: UUID()), hostID = UUID()
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    registry.publishLive(documentID: document.id, token: token, pageIndex: 0, hostID: hostID, generation: 2, isAttached: { _ in true })
    registry.revokeLive(hostID: hostID, through: 1)
    XCTAssertTrue(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
    registry.revokeLive(hostID: hostID, through: 2)
    XCTAssertFalse(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
  }

  func testThumbnailBorrowsTheLivePagePixelsWithoutStartingAnotherProgram() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program", html: "<p>Живой источник</p>",
      javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve());", initialState: .null, height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var bootCount = 0
    let live = surface(document: document, state: state, resources: resources, commit: { _,_ in bootCount += 1; return nil })
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

  func testCausalSourceABAReplacesTheRuntimeEvenWhenBytesReturnToOriginal() async throws {
    let actor = UUID(), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { _ in true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let original = AgentElement(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "program", html: "<output>same bytes</output>",
      javaScript: "window.boot=Math.random().toString();notebook.ready(Promise.resolve());")
    var page = PageDocument(size: .init(width: 400, height: 400), actor: actor, elements: [original])
    coordinator.load(original, basis: page.programStateBasis(original.id), in: web)
    await waitUntil { ready && coordinator.hasLiveSource(original) }
    let first = try await js("window.boot", web)
    let other = AgentElement(id: original.id, kind: .web, frame: original.frame, source: "other", html: original.html,
      javaScript: original.javaScript)
    XCTAssertTrue(page.replaceElements([other], actor: actor))
    XCTAssertTrue(page.replaceElements([original], actor: actor))
    coordinator.load(original, basis: page.programStateBasis(original.id), in: web)
    await waitUntil { ready && coordinator.hasLiveSource(original) }
    let second = try await js("window.boot", web)
    XCTAssertNotEqual(first, second, "Source equality must not give an obsolete heap new write authority")
  }

  func testSpatialCheckpointKeepsItsOwnerOnWriterRefusalAndCapturesTheAcceptedState() async throws {
    let resources = SceneRenderResources(), focus = InteractiveElementReference.page(pageID: UUID(), elementID: "phase")
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { _ in true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let source = AgentElement(id: "phase", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "phase", html: "<output>0.5</output>", javaScript: """
      notebook.lifecycle({pause:()=>{},checkpoint:()=>({phase:0.5})});
      notebook.semantic(()=>({objectID:'gear-a',label:'Gear',anchor:{x:.5,y:.5},values:[],model:{phase:.5}}));
      notebook.ready(Promise.resolve());
      """, state: .object(["phase": .number(0)]))
    let actor = UUID()
    var page = PageDocument(size: .init(width: 240, height: 120), actor: actor, elements: [source])
    let originalBasis = try XCTUnwrap(page.programStateBasis(source.id))
    coordinator.bindPresentation(to: focus); coordinator.load(source, basis: originalBasis, in: web)
    await waitUntil { ready }
    do {
      _ = try await AgentWebCoordinator.checkpointCurrent(focus: focus, element: source, persist: { _ in nil }, resources: resources)
      XCTFail("Writer refusal is not saved")
    } catch { XCTAssertTrue(String(describing:error).contains("checkpoint_not_accepted")) }
    XCTAssertTrue(coordinator.hasLiveSource(source))
    let suspended = try await js("String(notebookProgram.suspended)", web)
    XCTAssertEqual(suspended, "false")
    var persisted: JSONValue?
    let (accepted, picture) = try await AgentWebCoordinator.checkpointCurrent(focus: focus, element: source, persist: { value in
      persisted = value
      page.replaceElements([source.updating(state: value)], actor: actor)
      return page.programStateBasis(source.id)
    }, resources: resources)
    defer { picture.release() }
    XCTAssertEqual(persisted, .object(["phase": .number(0.5)]))
    XCTAssertEqual(accepted.state, persisted)
    XCTAssertEqual(picture.semanticSelection?.objectID, "gear-a")
    XCTAssertEqual(picture.semanticSelection?.model["phase"], .number(0.5))
    let retained = try XCTUnwrap(picture.retainedCopy()); defer { retained.release() }
    XCTAssertEqual(retained.semanticSelection, picture.semanticSelection)
    XCTAssertTrue(coordinator.hasLiveSource(accepted))
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    coordinator.load(source, basis: originalBasis, in: web)
    XCTAssertTrue(coordinator.hasLiveSource(accepted), "A stale SwiftUI echo cannot roll back the checkpoint receipt")
    let savedModel = try await js("JSON.stringify(notebook.state)", web)
    XCTAssertEqual(savedModel, "{\"phase\":0.5}")
  }

  func testAgentStateAndPlacementKeepProgramFocusAndUncommittedInput() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false, commits: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { commits.append($0); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let original = AgentElement(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "counter", html: "<input><button>Next</button>", javaScript: """
      window.boot=Math.random().toString();
      document.querySelector('button').onclick=()=>notebook.commit({count:(notebook.state.count||0)+1});
      notebook.ready(Promise.resolve());
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
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
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
      registry.publishLive(documentID: documentID, token: "source", pageIndex: 0, hostID: hostID, generation: 1, isAttached: { _ in false })
    }
    registry.unmountRenderer(hostID: hostID)
    await fulfillment(of: [invalidation], timeout: 0.05)
  }




  func testAnOffPageStateChangeKeepsTheActualPaperFrameAndItsCompositeKey() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "body", source: String(repeating: "Independent paper and formulas $x^2$.\n\n", count: 160)),
      .interactive(id: "far", html: "<button>Far</button>", height: 100)])
    let actor = UUID()
    var state = DocumentStateJournal(id: document.id, actor: actor)
    XCTAssertTrue(state.commit(blockID: "far", value: .number(1), actor: actor))
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let before = try await js("JSON.stringify(notebookRenderer.pageReceipt().work)", web)
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    let packet = try XCTUnwrap(surface.coordinator.payload?.state)
    XCTAssertFalse(surface.coordinator.payload?.source.layout?.blockIDs(on: [0]).contains("far") ?? true)
    XCTAssertTrue(state.commit(blockID: "far", value: .number(2), actor: actor))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _,_ in nil })
    XCTAssertTrue(surface.coordinator.hasCanonicalPixels)
    XCTAssertTrue(surface.coordinator.payload?.state === packet)
    XCTAssertEqual(DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0), token)
    XCTAssertEqual(surface.coordinator.payload?.rasterToken, token)
    let after = try await js("JSON.stringify(notebookRenderer.pageReceipt().work)", web)
    XCTAssertEqual(after, before)
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
    var layoutPasses = 0, typesetPasses = 0, preparationRoots = 0
    for (index, page) in pages.enumerated() {
      XCTAssertNil(page.coordinator.acquisitionError)
      XCTAssertTrue(page.coordinator.renderIsReady)
      XCTAssertTrue(page.coordinator.payload?.source === source)
      XCTAssertTrue(page.coordinator.payload?.state === pages[0].coordinator.payload?.state)
      XCTAssertTrue(DocumentRenderRegistry.shared.entry(document: document, pageIndex: index)?.layout === layout)
      let web = try XCTUnwrap(page.coordinator.webView)
      let pageNumber = try await js("String(window.notebookRenderer.pageReceipt().pageIndex)", web)
      XCTAssertEqual(pageNumber, String(index))
      let raw = try await js("JSON.stringify({work:notebookRenderer.pageReceipt().work,scope:notebookRenderer.pageReceipt().layoutScope,regions:notebookRenderer.pageReceipt().regions,domText:document.getElementById('document').textContent,preparations:document.querySelectorAll('.document-layout-preparation').length,sheets:document.querySelectorAll('.paper-sheet').length})", web)
      let measured = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      let work = try XCTUnwrap(measured["work"] as? [String: Int])
      layoutPasses += work["layoutPasses"] ?? -100; typesetPasses += work["typesetPasses"] ?? -100
      XCTAssertEqual(measured["scope"] as? String, "page")
      preparationRoots += try XCTUnwrap(measured["preparations"] as? Int)
      XCTAssertEqual(measured["sheets"] as? Int, 1)
      XCTAssertLessThan(try XCTUnwrap(measured["domText"] as? String).count, prose.count / 2)
      let regions = try XCTUnwrap(measured["regions"] as? [[String: Any]])
      XCTAssertTrue(regions.allSatisfy { $0["pageIndex"] as? Int == index })
    }
    XCTAssertEqual(preparationRoots, 1, "One admitted page owns the inert source index; neighbors own only their physical page")
    XCTAssertEqual(layoutPasses, 1); XCTAssertEqual(typesetPasses, 1)
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertEqual(pages[0].coordinator.payload?.state.encodingCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 4); XCTAssertEqual(resources.pendingWebRequestCount, 0)
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
        onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
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
    await waitUntil { resources.activeWebSurfaceCount == 0 }
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
    XCTAssertTrue(condition(), "The real WebKit surface did not complete its bounded preparation at \(file):\(line)", file: file, line: line)
  }
}
