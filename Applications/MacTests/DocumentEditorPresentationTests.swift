import AppKit
import NotebookCore
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentEditorPresentationTests: XCTestCase {
  @MainActor private final class Surface {
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    let window: NSWindow
    private var closed = false
    init(coordinator: DocumentWebCoordinator, host: DocumentWebHost, window: NSWindow) {
      self.coordinator = coordinator; self.host = host; self.window = window
    }
    func close() {
      guard !closed else { return }; closed = true
      coordinator.invalidate(); window.orderOut(nil); window.close()
    }
  }

  private func surface(_ document: DocumentDocument, _ state: DocumentStateJournal,
    resources: SceneRenderResources, thumbnail: Bool = false,
    sourceCommit: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status = { _ in .targetMissing },
    draftChanged: @escaping (DocumentEditingSession) -> Void = { _ in },
    commit: @escaping (String, JSONValue) -> ContentFieldVersion? = { _,_ in nil }) -> Surface {
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: sourceCommit, onStateChange: commit)
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: thumbnail,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: sourceCommit,
      onStateChange: commit, snapshotPixelWidth: thumbnail ? 256 : nil, onDraftChange: draftChanged)
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: !thumbnail, priority: thumbnail ? .visible : .currentPage)
    return .init(coordinator: coordinator, host: host, window: window)
  }

  private func document() -> DocumentDocument {
    DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Канонический текст $x^2$"),
      .markdown(id: "other", source: "Соседний блок"),
      .interactive(id: "program", html: "<input>", javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve())", height: 80)])
  }

  func testExplicitFenceAndRetirementReadTheFinalEditorWithoutLosingSelectionOrScroll() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Original")])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources(maximumWebSurfaces: 1)
    var drafts: [DocumentEditingSession] = []
    let live = surface(document, state, resources: resources, draftChanged: { drafts.append($0) })
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(live.coordinator.webView)
    _ = try await js("""
      document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.editor=document.querySelector('textarea');editor.value='Line of the pending draft.\\n'.repeat(100);
      editor.dispatchEvent(new Event('input'));editor.setSelectionRange(2,11);editor.scrollTop=200;
      editor.dispatchEvent(new Event('compositionstart'));'ready'
      """, web)
    let captured = await live.coordinator.checkpointEditingDraft(); XCTAssertTrue(captured)
    XCTAssertEqual(drafts.last?.selectionStart, 2); XCTAssertEqual(drafts.last?.selectionEnd, 11)
    XCTAssertEqual(drafts.last?.scrollTop, 200)
    let stillEditing = try await js("String(editor===document.querySelector('textarea'))", web)
    XCTAssertEqual(stillEditing, "true", "A background/write fence does not finish editing")
    // No synthetic input message publishes these last values. The retiring
    // executor must read its actual DOM before returning the borrowed slot.
    _ = try await js("editor.value='The final accepted draft.\\n'.repeat(100);editor.setSelectionRange(3,12);editor.scrollTop=250;'final'", web)
    live.close()
    let drained = await DocumentRenderRegistry.shared.finishEditing(documentID: document.id)
    XCTAssertTrue(drained)
    XCTAssertEqual(drafts.last?.selectionStart, 3); XCTAssertEqual(drafts.last?.selectionEnd, 12)
    XCTAssertEqual(drafts.last?.scrollTop, 250)
    XCTAssertTrue(drafts.last?.edit.source.hasPrefix("The final accepted draft.") == true)
    await wait { resources.activeWebSurfaceCount == 0 }
  }

  func testCommitKeepsSavedTextUntilItsExactSourceIsActuallyInstalled() async throws {
    var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Before saving")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var submitted: DocumentSourceEdit?
    let commit: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status = { submitted = $0; return .committed }
    let live = surface(document, state, resources: SceneRenderResources(maximumWebSurfaces: 1), sourceCommit: commit)
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(live.coordinator.webView)
    _ = try await js("""
      document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.savedEditor=document.querySelector('textarea');savedEditor.value='# Saved text remains accessible';
      savedEditor.dispatchEvent(new Event('input'));
      document.querySelector('[data-editor-action=save]').click();'submitted'
      """, web)
    await wait { submitted != nil }
    var saved = false
    for _ in 0..<200 {
      saved = try await js("String(document.querySelector('.source-editor-status')?.textContent.startsWith('Сохранено.'))", web) == "true"
      if saved { break }; try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(saved)
    XCTAssertFalse(live.coordinator.hasCanonicalPixels)
    let pending = try await js("String(savedEditor===document.querySelector('textarea')&&savedEditor.readOnly&&savedEditor.value.includes('Saved text'))", web)
    XCTAssertEqual(pending, "true", "The write acknowledgement is not a presentation acknowledgement")
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: try XCTUnwrap(submitted).source, actor: UUID()))
    live.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: commit, onStateChange: { _, _ in nil })
    await wait { live.coordinator.hasCanonicalPixels }
    let installed = try await js("String(!document.querySelector('textarea')&&document.getElementById('document').textContent.includes('Saved text remains accessible'))", web)
    XCTAssertEqual(installed, "true")
    XCTAssertTrue(live.coordinator.webView === web)
  }

  func testComposingEditorKeepsInputButCannotCreateACanonicalRaster() async throws {
    let document = document(), state = DocumentStateJournal(id: document.id, actor: UUID())
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    var boots = 0
    let live = surface(document, state, resources: resources, commit: { _,_ in boots += 1; return nil })
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels && boots == 1 }
    let web = try XCTUnwrap(live.coordinator.webView)
    _ = try await js("window.originalFrame=document.querySelector('iframe'); 'stored'", web)
    let sourceBytes = resources.reservedBytes
    XCTAssertGreaterThan(sourceBytes, 0, "The shared DOM fragments are charged to the existing resource pool")
    try await openEditor(web, composing: true)
    await wait { !live.coordinator.hasCanonicalPixels }
    XCTAssertTrue(live.coordinator.renderIsReady); XCTAssertTrue(live.coordinator.ownsEditing)
    XCTAssertTrue(live.coordinator.webView === web)
    do {
      _ = try await live.coordinator.retainPreparedSnapshot(pixelWidth: 256)
      XCTFail("An editor is not a canonical-source raster")
    } catch { XCTAssertEqual(error as? DocumentSnapshotWait, .editorActive) }
    XCTAssertEqual(resources.rasterCount, 0); XCTAssertEqual(resources.reservedBytes, sourceBytes)
    let identity = try await js("String(savedEditor===document.querySelector('textarea') && originalFrame===document.querySelector('iframe'))", web)
    XCTAssertEqual(identity, "true")
    let value = try await js("savedEditor.value", web)
    XCTAssertEqual(value, "Незавершённый ввод 👩‍💻")
    XCTAssertEqual(boots, 1)
    try await closeEditor(web, composing: true)
    await wait { live.coordinator.hasCanonicalPixels }
    XCTAssertTrue(live.coordinator.webView === web)
  }

  func testActualSnapshotIsRejectedWhenEditorOpensAndClosesBeforeTheSecondReceipt() async throws {
    let document = document(), state = DocumentStateJournal(id: document.id, actor: UUID())
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document, state, resources: resources)
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(live.coordinator.webView)
    let sourceBytes = resources.reservedBytes
    _ = try await js("""
      window.pixelReads=0;window.originalPresentation=notebookRenderer.presentationReceipt;
      notebookRenderer.presentationReceipt=()=>{
        pixelReads++;
        if(pixelReads===2){
          document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
          const editor=document.querySelector('textarea');editor.value='Temporary overlay';
          editor.dispatchEvent(new Event('input'));editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}));
        }
        return originalPresentation();
      }; 'armed'
      """, web)
    do {
      _ = try await live.coordinator.retainPreparedSnapshot(pixelWidth: 256)
      XCTFail("The image between different presentation epochs cannot enter the canonical cache")
    } catch { XCTAssertTrue(error is DocumentSnapshotWait, String(describing: error)) }
    let reads = try await js("String(pixelReads)", web)
    XCTAssertEqual(reads, "2", "The second real JS query runs after WebKit has returned its actual snapshot")
    XCTAssertEqual(resources.rasterCount, 0); XCTAssertEqual(resources.reservedBytes, sourceBytes)
    _ = try await js("notebookRenderer.presentationReceipt=originalPresentation; 'restored'", web)
    await wait { live.coordinator.hasCanonicalPixels }
    let raster = try await live.coordinator.retainPreparedSnapshot(pixelWidth: 256)
    defer { raster.release() }
    XCTAssertEqual(resources.rasterCount, 1)
  }

  func testPeerChangeAndDeletionKeepDraftButNeverCertifyItsOverlay() async throws {
    let actor = UUID()
    var document = document()
    let state = DocumentStateJournal(id: document.id, actor: actor), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document, state, resources: resources)
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(live.coordinator.webView)
    try await openEditor(web)
    func update() {
      live.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil })
    }
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "Внешний источник", actor: actor)); update()
    await wait { live.coordinator.renderIsReady }
    XCTAssertFalse(live.coordinator.hasCanonicalPixels)
    XCTAssertTrue(document.replaceContent(blocks: document.blocks.filter { $0.id != "body" }, actor: actor)); update()
    await wait { live.coordinator.renderIsReady }
    XCTAssertFalse(live.coordinator.hasCanonicalPixels)
    let draft = try await js("document.querySelector('textarea').value", web)
    XCTAssertEqual(draft, "Незавершённый ввод 👩‍💻")
    _ = try await js("savedEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',metaKey:true})); 'submitted'", web)
    var missing = false
    for _ in 0..<200 {
      if try await js("document.querySelector('.source-editor-status').textContent", web).contains("Блок удалён") { missing = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(missing)
    XCTAssertFalse(live.coordinator.hasCanonicalPixels)
    try await closeEditor(web)
    await wait { live.coordinator.hasCanonicalPixels }
    let ids = try await js("JSON.stringify([...document.getElementById('document').children].map(n=>n.dataset.blockId))", web)
    XCTAssertEqual(ids, "[\"other\",\"program\"]")
    let raster = try await live.coordinator.retainPreparedSnapshot(pixelWidth: 256)
    defer { raster.release() }
    XCTAssertEqual(resources.rasterCount, 1)
  }

  func testCanonicalCacheHitIsAPreviewAndDoesNotRestoreLivePixelReadiness() async throws {
    let document = document(), state = DocumentStateJournal(id: document.id, actor: UUID())
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document, state, resources: resources)
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels }
    let first = try await live.coordinator.retainPreparedSnapshot(pixelWidth: 256)
    defer { first.release() }
    let web = try XCTUnwrap(live.coordinator.webView)
    try await openEditor(web)
    await wait { !live.coordinator.hasCanonicalPixels }
    _ = try await js("window.pixelReads=0;window.originalPresentation=notebookRenderer.presentationReceipt;notebookRenderer.presentationReceipt=()=>{pixelReads++;return originalPresentation()};'armed'", web)
    let preview = try await live.coordinator.retainPreparedSnapshot(pixelWidth: 256)
    defer { preview.release() }
    XCTAssertTrue(preview.image === first.image)
    XCTAssertFalse(live.coordinator.hasCanonicalPixels)
    let reads = try await js("String(pixelReads)", web)
    XCTAssertEqual(reads, "0", "A previously proven canonical cache entry need not photograph the editor")
  }

  func testWaitingThumbnailWakesOnCloseWithoutAnotherProgramOrWebKitAndUnregistersOnRemoval() async throws {
    let document = document(), state = DocumentStateJournal(id: document.id, actor: UUID())
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    var boots = 0
    let live = surface(document, state, resources: resources, commit: { _,_ in boots += 1; return nil })
    defer { live.close() }
    await wait { live.coordinator.hasCanonicalPixels && boots == 1 }
    let web = try XCTUnwrap(live.coordinator.webView)
    try await openEditor(web)
    await wait { !live.coordinator.hasCanonicalPixels }
    let thumbnail = surface(document, state, resources: resources, thumbnail: true)
    defer { thumbnail.close() }
    let removed = surface(document, state, resources: resources, thumbnail: true)
    defer { removed.close() }
    await wait { thumbnail.coordinator.waitingForCanonicalSnapshot && removed.coordinator.waitingForCanonicalSnapshot }
    XCTAssertNil(thumbnail.coordinator.acquisitionError)
    XCTAssertFalse(thumbnail.coordinator.canShareSnapshot)
    XCTAssertFalse(removed.coordinator.canShareSnapshot)
    XCTAssertTrue(live.coordinator.canShareSnapshot)
    XCTAssertNil(thumbnail.coordinator.webView); XCTAssertNil(removed.coordinator.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1); XCTAssertEqual(resources.pendingWebRequestCount, 0)
    removed.close()
    XCTAssertFalse(removed.coordinator.waitingForCanonicalSnapshot)
    try await closeEditor(web)
    await wait { thumbnail.host.hasSnapshot }
    XCTAssertNil(thumbnail.coordinator.acquisitionError)
    XCTAssertFalse(thumbnail.coordinator.waitingForCanonicalSnapshot)
    XCTAssertNil(thumbnail.coordinator.webView); XCTAssertNil(removed.coordinator.webView)
    XCTAssertTrue(live.coordinator.webView === web); XCTAssertTrue(live.coordinator.ownsEditing)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1); XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(boots, 1)
  }

  func testSubmittedCaptureKeepsItsReservationAfterCancellationAndOwnerRemovalUntilTheCallback() throws {
    for image: NSImage? in [NSImage(size: .init(width: 64, height: 64)), nil] {
      let resources = SceneRenderResources(byteLimit: 64 * 64 * 8)
      let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 64, pixelHeight: 64))
      var capture: DocumentSnapshotCapture? = DocumentSnapshotCapture(reservation: reservation)
      weak let submitted = capture
      capture?.submit()
      var callback: (() -> Void)? = { [capture = try XCTUnwrap(capture)] in
        // Both a late image and a late WebKit error terminate the submitted
        // allocation, even though its coordinator no longer exists.
        XCTAssertFalse(capture.receive(image))
        XCTAssertNil(capture.image); XCTAssertNil(capture.reservation)
      }
      capture?.cancel(); capture?.cancel()
      capture = nil
      XCTAssertNotNil(submitted)
      XCTAssertFalse(reservation.isReleased)
      XCTAssertEqual(resources.reservedBytes, reservation.byteCount)
      XCTAssertNil(resources.reserveRaster(pixelWidth: 1, pixelHeight: 1),
        "A cancelled reader cannot lend the still-submitted capture's budget to another image")
      callback?(); callback = nil
      XCTAssertNil(submitted)
      XCTAssertTrue(reservation.isReleased)
      XCTAssertEqual(resources.reservedBytes, 0)
    }
  }

  func testCaptureCancellationReleasesBeforeSubmissionOrAfterReturnAndDeinitReleasesAbandonedPreparation() throws {
    let resources = SceneRenderResources(byteLimit: 64 * 64 * 8)
    let before = DocumentSnapshotCapture(reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 64, pixelHeight: 64)))
    before.cancel()
    XCTAssertEqual(resources.reservedBytes, 0)
    let returned = DocumentSnapshotCapture(reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 64, pixelHeight: 64)))
    returned.submit()
    XCTAssertTrue(returned.receive(NSImage(size: .init(width: 64, height: 64))))
    XCTAssertNotNil(returned.image)
    XCTAssertEqual(resources.reservedBytes, 64 * 64 * 8,
      "The real returned image remains accounted while its second receipt is outstanding")
    returned.cancel() // The reader's receipt deadline and invalidation use this same boundary.
    XCTAssertNil(returned.image)
    XCTAssertEqual(resources.reservedBytes, 0)
    var abandoned: DocumentSnapshotCapture? = DocumentSnapshotCapture(
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 64, pixelHeight: 64)))
    weak let pending = abandoned
    XCTAssertNotNil(pending)
    abandoned = nil
    XCTAssertNil(pending)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  private func openEditor(_ web: WKWebView, composing: Bool = false) async throws {
    _ = try await js("""
      document.querySelector('[data-block-id=body]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.savedEditor=document.querySelector('textarea');savedEditor.value='Незавершённый ввод 👩‍💻';
      \(composing ? "savedEditor.dispatchEvent(new Event('compositionstart'));" : "")
      savedEditor.dispatchEvent(new Event('input'));'opened'
      """, web)
  }
  private func closeEditor(_ web: WKWebView, composing: Bool = false) async throws {
    _ = try await js("\(composing ? "savedEditor.dispatchEvent(new Event('compositionend'));" : "") savedEditor.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'})); 'closed'", web)
  }
  private func js(_ source: String, _ web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(source) { value, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value as? String ?? String(describing: value)) }
      }
    }
  }
  private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The real document presentation did not reach its bounded state", file: file, line: line)
  }
}
