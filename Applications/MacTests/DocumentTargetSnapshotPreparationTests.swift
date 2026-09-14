import AppKit
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentTargetSnapshotPreparationTests: XCTestCase {
  func testActualNewDocumentPreparesItsOwnRequestedRasterWithoutASeededCache() async throws {
    try await check(blocks: [.markdown(id: "body", source: "# A fresh source\n\nIts real image must become available.")], name: "fresh-text")
  }

  func testPublicCollaborationCounterSourcePreparesItsOwnRaster() async throws {
    // Exact block content of the failed isolated v15 public request. A fresh
    // document identity keeps the reproduction separate from saved user data.
    let blocks = try JSONDecoder().decode([DocumentBlock].self, from: Data(Self.publicBlocks.utf8))
    try await check(blocks: blocks, name: "public-collaboration-counter")
  }

  func testQueuedDocumentPreparationSurvivesRealBackgroundCapacityRelease() async throws {
    let resources = SceneRenderResources.shared
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    let blockers = (0..<resources.maximumBackgroundWebSurfaces).map { _ in BackgroundPaper() }
    defer { blockers.forEach { $0.close() } }
    try await waitUntil { blockers.allSatisfy { $0.coordinator.hasCanonicalPixels } }
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, resources.maximumBackgroundWebSurfaces)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Waiting for physical capacity")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let started = ProcessInfo.processInfo.systemUptime
    var completedAt: Double?, releasedAt: Double?, failure: Error?, result: RasterLease?
    let preparation = Task { @MainActor in
      do { result = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0) }
      catch { failure = error }
      completedAt = ProcessInfo.processInfo.systemUptime
    }
    defer { preparation.cancel(); result?.release() }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    let queuedAt = ProcessInfo.processInfo.systemUptime
    // The actual producer is intentionally unavailable longer than the old
    // reader's eight-second deadline. Capacity release, not a seeded cache or
    // readiness callback, permits the first real WebKit for this document.
    try await Task.sleep(for: .milliseconds(8_250))
    let completedBeforeCapacityRelease = completedAt != nil
    blockers.forEach { $0.close() }; releasedAt = ProcessInfo.processInfo.systemUptime
    await preparation.value
    let proof: [String: Any] = ["fixture": "actual-background-capacity", "physicalBlockers": blockers.count,
      "queuedAtMS": (queuedAt - started) * 1000,
      "capacityReleasedAtMS": (releasedAt! - started) * 1000,
      "completedAtMS": (completedAt! - started) * 1000,
      "completedBeforeCapacityRelease": completedBeforeCapacityRelease,
      "error": failure.map { String(describing: $0) } ?? "none", "returned": result != nil,
      "pendingAfterCompletion": resources.pendingWebRequestCount]
    try attach(proof, name: "actual-background-capacity-result")
    XCTAssertFalse(completedBeforeCapacityRelease, "A queued source has not failed to render before it owns any WebKit")
    XCTAssertNil(failure)
    XCTAssertNotNil(result, "The same accepted preparation must finish after its admission is released")
  }

  func testCancellationRetiresQueuedPreparationWithoutAWebKitOrLateImage() async throws {
    let resources = SceneRenderResources.shared
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    let blockers = (0..<resources.maximumBackgroundWebSurfaces).map { _ in BackgroundPaper() }
    defer { blockers.forEach { $0.close() } }
    try await waitUntil { blockers.allSatisfy { $0.coordinator.hasCanonicalPixels } }
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Never admitted")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    let preparation = Task { try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0) }
    defer { preparation.cancel() }
    try await waitUntil { resources.pendingWebRequestCount == 1 }
    preparation.cancel()
    do { let unexpected = try await preparation.value; unexpected.release(); XCTFail("Cancelled request returned pixels") }
    catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)") }
    try await waitUntil { resources.pendingWebRequestCount == 0 }
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, blockers.count)
    blockers.forEach { $0.close() }
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 }
    XCTAssertNil(resources.retainRaster(for: source))
    try attach(["fixture": "cancelled-background-request", "pending": resources.pendingWebRequestCount,
      "activeBackground": resources.activeBackgroundWebSurfaceCount,
      "lateImage": resources.image(for: source) != nil], name: "cancelled-background-request-result")
  }

  func testAccessoryWithoutAnOwnVisibleWindowPreparesThePublicCounter() async throws {
    let application = NSApplication.shared
    let policy = application.activationPolicy()
    let visible = application.windows.filter(\.isVisible)
    _ = application.setActivationPolicy(.accessory)
    XCTAssertEqual(application.activationPolicy(), .accessory)
    visible.forEach { $0.orderOut(nil) }
    defer {
      _ = application.setActivationPolicy(policy)
      visible.forEach { $0.orderBack(nil) }
    }
    XCTAssertTrue(application.windows.allSatisfy { !$0.isVisible })
    let blocks = try JSONDecoder().decode([DocumentBlock].self, from: Data(Self.publicBlocks.utf8))
    try await check(blocks: blocks, name: "accessory-no-own-visible-window")
  }

  func testCapturePressureKeepsTheSameProducerUntilItsWholeRasterFits() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = BackgroundPaper(resources: resources)
    defer { paper.close() }
    try await waitUntil { paper.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(paper.coordinator.webView)
    _ = try await web.evaluateJavaScript("window.snapshotContinuity='kept-before-admission'")
    let measurements = try XCTUnwrap(paper.coordinator.payload).source.measurementCount
    let held = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - resources.reservedBytes - 1_000_000, priority: .passive))
    let small = try XCTUnwrap(resources.reserveDerivedBytes(100_000, priority: .passive))
    defer { held.release(); small.release() }
    let capture = Task { try await paper.coordinator.retainPreparedSnapshot(pixelWidth: 512,
      force: true, waitsForRasterAdmission: true) }
    defer { capture.cancel() }
    try await waitUntil { paper.coordinator.pendingRasterSnapshot != nil }
    let demand = try XCTUnwrap(paper.coordinator.pendingRasterSnapshot)
    XCTAssertGreaterThan(demand.bytes, 1_000_000)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 1)
    XCTAssertTrue(paper.coordinator.webView === web)
    small.release()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNotNil(paper.coordinator.pendingRasterSnapshot, "A partial improvement does not admit the whole raster")
    XCTAssertTrue(paper.coordinator.hasCanonicalPixels)
    XCTAssertTrue(paper.coordinator.webView === web)
    XCTAssertEqual(resources.rasterCount, 0)
    held.release()
    let lease = try await capture.value
    defer { lease.release() }
    XCTAssertEqual(lease.source, demand.source)
    XCTAssertNil(paper.coordinator.pendingRasterSnapshot)
    XCTAssertTrue(paper.coordinator.webView === web)
    XCTAssertEqual(paper.coordinator.payload?.source.measurementCount, measurements)
    let continuity = try await web.evaluateJavaScript("window.snapshotContinuity") as? String
    XCTAssertEqual(continuity, "kept-before-admission")
    let proof = XCTAttachment(image: lease.image); proof.name = "same-producer-after-raster-admission"
    proof.lifetime = .keepAlways; add(proof)
  }

  func testStoppingAProducerCancelsItsPendingCaptureBeforeCapacityReturns() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = BackgroundPaper(resources: resources)
    defer { paper.close() }
    try await waitUntil { paper.coordinator.hasCanonicalPixels }
    let held = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - resources.reservedBytes - 1_000_000, priority: .passive))
    defer { held.release() }
    let capture = Task { try await paper.coordinator.retainPreparedSnapshot(pixelWidth: 512,
      force: true, waitsForRasterAdmission: true) }
    try await waitUntil { paper.coordinator.pendingRasterSnapshot != nil }
    let demand = try XCTUnwrap(paper.coordinator.pendingRasterSnapshot)
    paper.close()
    do { let unexpected = try await capture.value; unexpected.release(); XCTFail("Stopped producer returned an image") }
    catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    XCTAssertNil(paper.coordinator.pendingRasterSnapshot)
    held.release()
    try await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == 0 }
    XCTAssertNil(resources.retainRaster(for: demand.source))
  }

  func testImpossibleCaptureDoesNotCreateAPermanentAdmissionWaiter() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = BackgroundPaper(resources: resources)
    defer { paper.close() }
    try await waitUntil { paper.coordinator.hasCanonicalPixels }
    do {
      let unexpected = try await paper.coordinator.retainPreparedSnapshot(pixelWidth: 8192,
        force: true, waitsForRasterAdmission: true)
      unexpected.release(); XCTFail("An impossible capture exceeded its fixed budget")
    } catch { XCTAssertEqual(error as? SceneRenderError, .resourceLimit) }
    XCTAssertNil(paper.coordinator.pendingRasterSnapshot)
    XCTAssertTrue(paper.coordinator.hasCanonicalPixels)
    XCTAssertEqual(resources.rasterCount, 0)
  }

  func testTerminalWebFailureDuringCaptureAdmissionKeepsItsActualError() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let paper = BackgroundPaper(resources: resources)
    defer { paper.close() }
    try await waitUntil { paper.coordinator.hasCanonicalPixels }
    let held = try XCTUnwrap(resources.reserveDerivedBytes(resources.byteLimit - resources.reservedBytes - 1_000_000, priority: .passive))
    defer { held.release() }
    let capture = Task { try await paper.coordinator.retainPreparedSnapshot(pixelWidth: 512,
      force: true, waitsForRasterAdmission: true) }
    try await waitUntil { paper.coordinator.pendingRasterSnapshot != nil }
    let demand = try XCTUnwrap(paper.coordinator.pendingRasterSnapshot)
    let error = NSError(domain: "NotebookSnapshotTerminalFailure", code: 71,
      userInfo: [NSLocalizedDescriptionKey: "Terminal source failure during capture admission"])
    // A public delegate seam on a real, already-ready WK. This does not claim
    // that the OS killed a process or that navigation itself was reproduced.
    paper.coordinator.webView(try XCTUnwrap(paper.coordinator.webView),
      didFailProvisionalNavigation: nil, withError: error)
    do { let unexpected = try await capture.value; unexpected.release(); XCTFail("A failed source returned pixels") }
    catch let observed as NSError {
      XCTAssertEqual(observed.domain, error.domain)
      XCTAssertEqual(observed.code, error.code)
    }
    XCTAssertNil(paper.coordinator.pendingRasterSnapshot)
    XCTAssertNil(paper.coordinator.webView)
    XCTAssertFalse(paper.coordinator.hasCanonicalPixels)
    held.release()
    paper.close()
    try await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == 0 }
    XCTAssertNil(resources.retainRaster(for: demand.source))
  }

  func testActualBrokenImageReturnsItsRenderFailureRatherThanReaderCancellation() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "broken-image", source:
      "<img width='451' height='158' src='data:image/png;base64,bm90LWFuLWltYWdl'>")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    do {
      let unexpected = try await DocumentSnapshotCache.shared.prepare(document: document, state: state,
        pageIndex: 0, resources: resources)
      unexpected.release(); XCTFail("An undecodable physical image was reported as a prepared page")
    } catch {
      XCTAssertFalse(error is CancellationError, "Internal reader retirement must retain the actual renderer failure")
      XCTAssertTrue(String(describing: error).contains("document_image_decode_failed"), "\(error)")
      try attach(["actualBrokenImageError": String(describing: error)], name: "actual-broken-image-render-error")
    }
    try await waitUntil { resources.activeWebSurfaceCount == 0 && resources.reservedBytes == 0 }
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(resources.rasterCount, 0)
  }

  func testQueuedTargetRequestHasNoTerminalReceiptAndPublishesAfterCapacityReturns() async throws {
    let resources = SceneRenderResources.shared
    var phase = "await_empty_background_pool"
    var events: [[String: Any]] = []
    let started = ProcessInfo.processInfo.systemUptime
    func mark(_ next: String) {
      phase = next
      events.append(["phase": next, "elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000])
    }
    defer { try? attach(["events": events, "lastPhase": phase], name: "queued-target-owner-boundaries") }
    try await waitUntil { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    let blockers = (0..<resources.maximumBackgroundWebSurfaces).map { _ in BackgroundPaper() }
    defer { blockers.forEach { $0.close() } }
    do {
      mark("await_actual_blocker_pixels")
      try await waitUntil { blockers.allSatisfy { $0.coordinator.hasCanonicalPixels } }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = NotebookStore(root: directory), actor = UUID()
      mark("create_store")
      var (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 100, height: 140))
      mark("load_board")
      var board = try store.loadBoard(items: workspace.items)
      mark("create_document")
      let item = try XCTUnwrap(workspace.createDocument(title: "Queued target", actor: actor))
      let document = DocumentDocument(id: item.id, actor: actor, blocks: [.markdown(id: "body", source: "# A real queued target")])
      XCTAssertTrue(board.addItem(item.id, to: workspace.rootBoardID, near: .zero, actor: actor))
      mark("publish_document_bundle")
      try store.saveDocumentWorkspaceBundle(index: workspace, document: document,
        state: .init(id: document.id, actor: actor), board: board)
      mark("prepare_spatial_ink")
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      let target = CollaborationTarget(kind: .document, id: document.id)
      let revision = document.contentStamp.revision
      mark("accept_target_request")
      let request = try store.requestTargetRender(target: target, expectedRevision: revision)
      mark("create_preview_owner")
      let model = NotebookAppModel(store: store, startsNearbySync: false)
      let publisher = MacPreviewPublisher(model: model)
      addTeardownBlock { @MainActor in
        await publisher.stop()
        let stopped = await model.shutdown(); XCTAssertTrue(stopped)
        if stopped { try FileManager.default.removeItem(at: directory) }
      }
      mark("start_preview_owner")
      publisher.start()
      mark("await_request_in_real_queue")
      try await waitUntil { resources.pendingWebRequestCount == 1 }
      mark("hold_capacity_past_previous_deadline")
      try await Task.sleep(for: .milliseconds(8_250))
      mark("verify_pending_has_no_terminal_receipt")
      XCTAssertNil(try store.loadTargetRenderReceipt(request.id), "Waiting for admission is not an immutable rendering error")
      let repeated = try store.requestTargetRender(target: target, expectedRevision: revision)
      XCTAssertEqual(repeated, request, "A retry reads the accepted request; it does not manufacture another identity")
      mark("release_background_capacity")
      blockers.forEach { $0.close() }
      mark("await_actual_terminal_receipt")
      try await waitUntil { (try? store.loadTargetRenderReceipt(request.id)) != nil }
      let receipt = try XCTUnwrap(store.loadTargetRenderReceipt(request.id))
      XCTAssertEqual(receipt.status, "ready", "\(receipt.diagnostics)")
      XCTAssertEqual(receipt.request, request)
      XCTAssertNotNil(NSImage(contentsOf: store.targetPNGURL(request.id)))
      mark("stop_preview_owner")
      await publisher.stop()
      mark("completed")
    } catch {
      let actual = error as NSError
      try? attach(["phase": phase, "error": String(describing: error),
        "errorType": String(reflecting: type(of: error)), "domain": actual.domain, "code": actual.code,
        "events": events], name: "queued-target-primary-error-before-cleanup")
      XCTFail("Queued target failed at \(phase): \(error)")
      throw error
    }
  }

  @MainActor private final class BackgroundPaper {
    let coordinator: DocumentWebCoordinator
    let host = DocumentWebHost()
    let window: NSWindow
    private var closed = false
    init(resources: SceneRenderResources = .shared) {
      let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# An actual retained background paper")])
      let state = DocumentStateJournal(id: document.id, actor: UUID())
      let ready = PageTurnReadiness { _ in }
      coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: ready, onPageLayout: { _ in },
        onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil })
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
      coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil })
      coordinator.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: false, priority: .background)
    }
    func close() {
      guard !closed else { return }
      closed = true
      coordinator.invalidate(); window.orderOut(nil); window.close()
    }
  }

  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Actual owner state did not arrive", file: file, line: line)
    if !condition() { throw NSError(domain: "DocumentTargetPreparationTests", code: 1) }
  }

  private func attach(_ value: [String: Any], name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    proof.name = name; proof.lifetime = .keepAlways; add(proof)
  }

  private func check(blocks: [DocumentBlock], name: String) async throws {
    let actor = UUID(), document = DocumentDocument(actor: UUID(), blocks: blocks)
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    XCTAssertNil(SceneRenderResources.shared.retainRaster(for: source))
    let screenScaleBeforePreparation = NSScreen.main?.backingScaleFactor
    let keyWindowBeforePreparation = NSApplication.shared.keyWindow != nil
    let visibleWindowsBeforePreparation = NSApplication.shared.windows.filter(\.isVisible).count
    let policyBeforePreparation = NSApplication.shared.activationPolicy().rawValue
    let started = ProcessInfo.processInfo.systemUptime
    var failure: Error?, result: RasterLease?
    do { result = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: 0) }
    catch { failure = error }
    defer { result?.release() }
    let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    // The probe runs only after the real call. It must not manufacture an own
    // window before NSScreen.main is sampled by the production owner.
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let probe = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    probe.isReleasedWhenClosed = false; probe.orderBack(nil)
    let probeScale = probe.backingScaleFactor
    probe.orderOut(nil); probe.close()
    let cached = SceneRenderResources.shared.retainRaster(for: source)
    defer { cached?.release() }
    let evidence: [String: Any] = ["fixture": name, "documentID": document.id.uuidString,
      "elapsedMS": elapsedMS,
      "screenScaleBeforePreparation": screenScaleBeforePreparation.map { $0 as Any } ?? NSNull(),
      "hadKeyWindowBeforePreparation": keyWindowBeforePreparation,
      "visibleOwnWindowsBeforePreparation": visibleWindowsBeforePreparation,
      "activationPolicyBeforePreparation": policyBeforePreparation,
      "screenRequiredScale": Double(NSScreen.main?.backingScaleFactor ?? 2),
      "sameGeometryProbeWindowScale": probeScale, "returned": result != nil,
      "actualCacheScale": cached?.pixelScale ?? 0, "actualCachePresent": cached != nil,
      "sourceToken": DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0),
      "error": failure.map { String(describing: $0) } ?? "none",
      "activeWebSurfacesAfterReturn": SceneRenderResources.shared.activeWebSurfaceCount]
    let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
    let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    proof.name = name + "-actual-preview-result"; proof.lifetime = .keepAlways; add(proof)
    if let result {
      let image = XCTAttachment(image: result.image)
      image.name = name + "-actual-preview-image"; image.lifetime = .keepAlways; add(image)
    }
    XCTAssertNil(failure, String(decoding: data, as: UTF8.self))
    XCTAssertNotNil(result, "The live preparation path must return its own actual raster")
  }

  private static let publicBlocks = #"""
[
  {
    "source": "На отправленном изображении видно **Acceptance count: 8**. После вашего нажатия публичное состояние исходного блока показало **9**. SHA-256 замороженного изображения при повторном чтении остался прежним.\n\nНиже — отдельный счётчик с начальным значением 0. Кнопка прибавляет 1; notebook.commit передаёт состояние на сохранение, notebookstate восстанавливает отображение, notebook.ready сообщает о готовности.",
    "id": "collaboration-explanation",
    "kind": "markdown",
    "html": "",
    "javaScript": "",
    "height": 320,
    "initialState": {},
    "css": ""
  },
  {
    "source": "<main><button type=\"button\" id=\"increment\" aria-label=\"Collaboration increment 2c047f99-97ed-4108-a072-19d4b28b1427\">Прибавить один</button><output id=\"count\" aria-live=\"polite\">Collaboration count 2c047f99-97ed-4108-a072-19d4b28b1427: 0</output></main>",
    "id": "collaboration-counter-2c047f99-97ed-4108-a072-19d4b28b1427",
    "kind": "interactive",
    "html": "<main><button type=\"button\" id=\"increment\" aria-label=\"Collaboration increment 2c047f99-97ed-4108-a072-19d4b28b1427\">Прибавить один</button><output id=\"count\" aria-live=\"polite\">Collaboration count 2c047f99-97ed-4108-a072-19d4b28b1427: 0</output></main>",
    "javaScript": "const button=document.getElementById(\"increment\");\nconst output=document.getElementById(\"count\");\nconst count=()=>notebook.state?.count ?? 0;\nconst draw=()=>{output.textContent=\"Collaboration count 2c047f99-97ed-4108-a072-19d4b28b1427: \"+count();};\nbutton.addEventListener(\"click\",()=>{notebook.commit({count:count()+1});draw();});\naddEventListener(\"notebookstate\",draw);\nnotebook.ready(Promise.resolve().then(draw));",
    "initialState": {
      "count": 0
    },
    "height": 180,
    "css": "*{box-sizing:border-box}html,body{margin:0;background:#fff;color:#172733;font:18px -apple-system,sans-serif}main{display:grid;gap:18px;padding:12px}button{font:inherit;min-height:52px;padding:12px 18px;background:#1675a9;color:white;border:0;border-radius:12px;cursor:pointer}button:focus-visible{outline:3px solid #172733;outline-offset:3px}output{display:block;overflow-wrap:anywhere;line-height:1.45;font-variant-numeric:tabular-nums}"
  }
]
"""#
}
