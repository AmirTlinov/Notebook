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
    interactive: Bool = true,
    drafts: [DocumentEditingSession] = [],
    source: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status = { _ in .committed },
    draft: @escaping (DocumentEditingSession) -> Void = { _ in },
    commit: @escaping (String, JSONValue) -> Void = { _,_ in }) -> Surface {
    let resources = suppliedResources ?? SceneRenderResources(maximumWebSurfaces: 4)
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: source, onStateChange: commit)
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: snapshotPixelWidth != nil,
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
    await waitUntil { surface.coordinator.renderIsReady }
    let expected = Set(DocumentRenderRegistry.shared.regions(document: document, state: state).filter { $0.pageIndex == 0 }.map(\.id))
    XCTAssertFalse(expected.isEmpty)
    XCTAssertLessThan(expected.count, blocks.count)
    XCTAssertEqual(booted, expected, "A page host must not run the rest of the document's programs")
    let web = try XCTUnwrap(surface.coordinator.webView)
    let actual7 = try await js("String(document.querySelectorAll('iframe').length)", web)
    XCTAssertEqual(actual7, String(expected.count))
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
