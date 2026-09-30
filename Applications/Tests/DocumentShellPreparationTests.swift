import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentShellPreparationTests: XCTestCase {
  func testCommonStartupHasOneBodyFreeRuntimeAndPublishesNoDocumentReadiness() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop() }
    var observations: [DocumentShellPreparation.Observation] = []
    preparation.onTransition = { observations.append($0) }
    preparation.prepareIfIdle()
    let renderer = try XCTUnwrap(preparation.unusedCoordinator)
    let web = try XCTUnwrap(renderer.webView)
    for _ in 0..<10 { preparation.prepareIfIdle() }
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertTrue(preparation.unusedCoordinator === renderer)
    XCTAssertTrue(renderer.webView === web)
    await waitUntil { renderer.commonRuntimeReady }
    XCTAssertNil(renderer.payload)
    XCTAssertNil(renderer.renderSession)
    XCTAssertFalse(renderer.renderIsReady)
    XCTAssertFalse(renderer.hasCanonicalPixels)
    XCTAssertEqual(observations.map(\.event), ["started", "ready"])
    XCTAssertEqual(Set(observations.map(\.shellID)).count, 1)
    XCTAssertEqual(Set(observations.map(\.leaseID)).count, 1)
    let runtime = try await web.callAsyncJavaScript("""
      return typeof window.notebookRenderer.installPageSource === 'function' &&
        typeof window.notebookRenderer.presentPage === 'function' && typeof window.MathJax === 'undefined';
      """, arguments: [:], in: nil, contentWorld: .page)
    XCTAssertEqual(runtime as? Bool, true)
  }

  func testOptionalPreparationCannotQueueAheadOfAnActualDocument() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let blocker = try await resources.acquireWebSurface(priority: .currentPage)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop(); blocker.release() }
    for _ in 0..<10 { preparation.prepareIfIdle() }
    XCTAssertNil(preparation.unusedCoordinator)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    let current = Task { try await resources.acquireWebSurface(priority: .currentPage) }
    await waitUntil { resources.pendingWebRequestCount == 1 }
    blocker.release()
    preparation.prepareIfIdle()
    let foreground = try await current.value
    XCTAssertNil(preparation.unusedCoordinator)
    XCTAssertEqual(foreground.priority, .currentPage)
    foreground.release()
    preparation.prepareIfIdle()
    XCTAssertNotNil(preparation.unusedCoordinator?.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testOptionalShellWaitsForTheSameConstructorAllowanceAsVisibleContent() async throws {
    let resources = SceneRenderResources(profile: .headless, maximumWebSurfaces: 4)
    let first = try await resources.acquireWebSurface(priority: .liveProgram, constructsView: true)
    let second = try await resources.acquireWebSurface(priority: .liveProgram, constructsView: true)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop(); first.release(); second.release() }
    XCTAssertEqual(resources.activeWebConstructionCount, 2)
    preparation.prepareIfIdle()
    XCTAssertNil(preparation.unusedCoordinator, "Optional work cannot create a third WebKit before the admitted constructors finish")
    XCTAssertEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertEqual(resources.pendingWebRequestCount, 0, "An optional shell never queues ahead of accepted content")

    first.finishConstruction()
    await waitUntil { resources.activeWebConstructionCount == 1 }
    XCTAssertEqual(resources.activeWebSurfaceCount, 2, "Constructor completion preserves both running leases")
    preparation.prepareIfIdle()
    XCTAssertNotNil(preparation.unusedCoordinator?.webView, "The real capacity edge admits the same optional preparation")
    XCTAssertEqual(resources.activeWebConstructionCount, 2, "The shell reserves its constructor before the factory runs")
    preparation.stop(); first.release(); second.release()
    await waitUntil { resources.activeWebConstructionCount == 0 && resources.activeWebSurfaceCount == 0 }
  }

  func testCurrentPageAdoptsTheSameReadyCoordinatorWebAndAdmission() async throws {
    try await assertActualAdoption(waitForCommonRuntime: true)
  }

  func testCurrentPageCanAdoptBeforeTheCommonRuntimeHasFinishedLoading() async throws {
    try await assertActualAdoption(waitForCommonRuntime: false)
  }

  func testNativePaperInstallsBeforeHeldShellFrameAndSurvivesItsFailure() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop() }
    preparation.prepareIfIdle()
    await waitUntil { preparation.unusedCoordinator?.commonRuntimeReady == true }
    let renderer = try XCTUnwrap(preparation.unusedCoordinator), web = try XCTUnwrap(renderer.webView)
    _ = try await web.evaluateJavaScript("window.notebookRenderer.presentPage=async()=>await new Promise(resolve=>{window.releaseHeldFrame=resolve;});true")
    let fixture = try PreparedShellPageFixture(resources: resources)
    defer { fixture.close() }
    await waitUntil { renderer.paperIsReady || !fixture.errors.isEmpty }
    let paper = try XCTUnwrap(renderer.installedPaper)
    XCTAssertTrue(fixture.visiblePaper === paper)
    XCTAssertTrue(fixture.ready, "Native paper is published while its transparent shell still waits")
    XCTAssertFalse(renderer.interactionIsReady)
    XCTAssertFalse(renderer.hasCanonicalPixels, "Paper alone cannot authorize a composite capture or old DOM links")
    renderer.webView(web, didFail: nil, withError: URLError(.cannotLoadFromNetwork))
    XCTAssertNil(renderer.webView)
    XCTAssertTrue(renderer.installedPaper === paper)
    XCTAssertTrue(fixture.visiblePaper === paper, "The same physical page retains its single accepted raster")
    XCTAssertFalse(renderer.interactionIsReady)
    // Drain the deliberately held WebKit call through its real completion;
    // failure revokes publication but cannot pretend that IPC has completed.
    _ = try await web.evaluateJavaScript("window.releaseHeldFrame?.();true")
    await waitUntil { resources.activeWebSurfaceCount == 0 }
  }

  func testNativePaperInstallsWhileWebAdmissionWaitsAndKeepsItsSourceForInput() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let blocker = try await resources.acquireWebSurface(priority: .currentPage)
    defer { blocker.release() }
    let fixture = try PreparedShellPageFixture(resources: resources)
    defer { fixture.close() }
    await waitUntil { fixture.visiblePaper != nil || !fixture.errors.isEmpty }
    let paper = try XCTUnwrap(fixture.visiblePaper)
    XCTAssertTrue(fixture.errors.isEmpty)
    XCTAssertTrue(fixture.ready, "The accepted native paper does not wait for the transparent interaction slot")
    XCTAssertNil(fixture.paper)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 1)

    let previousHost = fixture.replaceHost()
    await waitUntil { fixture.visiblePaper === paper }
    previousHost.onSizeChange(); previousHost.onWindowChange()
    previousHost.layoutIfNeeded(); previousHost.removeSurface(); previousHost.removeFromSuperview()
    XCTAssertTrue(fixture.visiblePaper === paper, "The departed host cannot project or remove its successor's paper")

    blocker.release()
    await waitUntil { fixture.hasCanonicalInput || !fixture.errors.isEmpty }
    let web = try XCTUnwrap(fixture.paper)
    let renderer = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    XCTAssertTrue(fixture.hasCanonicalInput)
    XCTAssertTrue(renderer.installedPaper === paper, "The sender borrows the already installed native source")
    XCTAssertEqual(renderer.payload?.source.preparationCount, 1)
    XCTAssertEqual(renderer.payload?.source.message.key, paper.sourceKey)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    let activated = try await web.callAsyncJavaScript("document.querySelector('a[href]')?.click();return true;",
      arguments: [:], in: nil, contentWorld: .page)
    XCTAssertEqual(activated as? Bool, true)
    await waitUntil { fixture.linkActivations == 1 }
    XCTAssertTrue(fixture.errors.isEmpty)
    fixture.close()
    await waitUntil { resources.activeWebSurfaceCount == 0 }
  }

  func testClosingNativePaperBeforeWebAdmissionCannotMountItsQueuedExecutor() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let blocker = try await resources.acquireWebSurface(priority: .currentPage)
    defer { blocker.release() }
    let fixture = try PreparedShellPageFixture(resources: resources)
    defer { fixture.close() }
    await waitUntil { fixture.visiblePaper != nil || !fixture.errors.isEmpty }
    XCTAssertNotNil(fixture.visiblePaper)
    XCTAssertTrue(fixture.errors.isEmpty)
    XCTAssertEqual(resources.pendingWebRequestCount, 1)
    fixture.close()
    await waitUntil { resources.pendingWebRequestCount == 0 }
    XCTAssertNil(fixture.visiblePaper)
    blocker.release()
    await waitUntil { resources.activeWebSurfaceCount == 0 }
    XCTAssertNil(fixture.paper)
  }

  func testWebAdmissionRefusalBeforeNativeCompletionKeepsPaperAndItsWaiter() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, maximumBackgroundWebSurfaces: 0)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), host = DocumentWebHost()
    let controller = UIViewController(); window.rootViewController = controller
    let geometry = WorkspaceItemGeometry.uncompiledDocument
    host.frame = .init(x: 20, y: 20, width: 340, height: 340 * geometry.height / geometry.width)
    controller.view.addSubview(host); window.makeKeyAndVisible()
    let renderer = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    renderer.externallyHostedPrograms = true
    defer {
      renderer.invalidate(); window.isHidden = true; window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    let actor = UUID(), document = DocumentTestFiles.document(actor: actor,
      contents: [.tex(id: "body", source: "Paper survives a refused transparent executor.")])
    var refusedBeforePaper = false
    renderer.update(document: document, state: .init(id: document.id, actor: actor), selectedPageIndex: 0,
      capturesSnapshot: false, onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, _ in nil }, onPreparationFailure: { error in
        if error as? SceneWebAdmissionError == .preparationDisabled { refusedBeforePaper = !renderer.paperIsReady }
      })
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    let nativeWait = Task { try await renderer.awaitPaperReady(token: token) }
    defer { nativeWait.cancel() }
    renderer.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
      isInteractive: false, priority: .visible)
    await waitUntil { renderer.acquisitionError != nil }
    XCTAssertEqual(renderer.acquisitionError as? SceneWebAdmissionError, .preparationDisabled)
    XCTAssertTrue(refusedBeforePaper, "Admission must actually fail before the native producer completes")
    try await nativeWait.value
    let paper = try XCTUnwrap(renderer.installedPaper)
    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    XCTAssertTrue(descendants(host).compactMap { $0 as? DocumentPaperView }.contains { $0.raster === paper })
    XCTAssertTrue(descendants(host).contains { $0 is UIButton }, "Native success preserves the interaction Retry")
    XCTAssertEqual(renderer.payload?.source.preparationCount, 1)
    XCTAssertEqual(renderer.payload?.source.message.key, paper.sourceKey)
    XCTAssertNil(renderer.webView)
    XCTAssertFalse(renderer.hasCanonicalPixels)
    do {
      try await renderer.awaitPresentation(token: token)
      XCTFail("Refused interaction cannot publish canonical input")
    } catch { XCTAssertEqual(error as? SceneWebAdmissionError, .preparationDisabled) }
    XCTAssertEqual(renderer.pendingPresentationRequestCount, 0)
    renderer.invalidate()
    XCTAssertFalse(descendants(host).contains { ($0 as? DocumentPaperView)?.raster != nil })
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testForegroundAdmissionReclaimsUnusedShellBeforeRefusingItsSlot() async throws {
    try await assertForegroundReclaim(waitForCommonRuntime: true)
  }

  func testForegroundAdmissionReclaimsLoadingShellWithoutAQueuePosition() async throws {
    try await assertForegroundReclaim(waitForCommonRuntime: false)
  }

  private func assertForegroundReclaim(waitForCommonRuntime: Bool) async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, maximumPendingPreparationRequests: 0)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop() }
    preparation.prepareIfIdle()
    if waitForCommonRuntime { await waitUntil { preparation.unusedCoordinator?.commonRuntimeReady == true } }
    let previous = WeakPreparedDocumentWeb(preparation.unusedCoordinator?.webView)
    let lease = try await resources.acquireWebSurface(priority: .currentPage)
    defer { lease.release() }
    XCTAssertNil(preparation.unusedCoordinator)
    await waitUntil { previous.value == nil }
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testFailureRetiresEmptyWebAndDoesNotRetryOnItsOwnReleasedCapacity() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop() }
    preparation.prepareIfIdle()
    await waitUntil { preparation.unusedCoordinator?.commonRuntimeReady == true }
    let previous = WeakPreparedDocumentWeb(preparation.unusedCoordinator?.webView)
    // A public navigation-delegate failure seam, after actual common startup.
    // This verifies retirement ownership, not an operating-system process kill.
    if let renderer = preparation.unusedCoordinator, let web = renderer.webView {
      renderer.webView(web, didFail: nil, withError: URLError(.cannotLoadFromNetwork))
    }
    await waitUntil { resources.activeWebSurfaceCount == 0 && previous.value == nil }
    for _ in 0..<10 { preparation.prepareIfIdle() }
    XCTAssertNil(preparation.unusedCoordinator)
    preparation.allowPreparationAfterForeground()
    preparation.prepareIfIdle()
    XCTAssertNotNil(preparation.unusedCoordinator?.webView)
  }

  func testStoppingDuringStartupCannotResurrectItsHostOrAdmission() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let preparation = DocumentShellPreparation(resources: resources)
    preparation.prepareIfIdle()
    let previous = WeakPreparedDocumentWeb(preparation.unusedCoordinator?.webView)
    preparation.stop(); preparation.stop()
    for _ in 0..<10 { preparation.prepareIfIdle(); await Task.yield() }
    await waitUntil { resources.activeWebSurfaceCount == 0 && previous.value == nil }
    XCTAssertNil(preparation.unusedCoordinator)
    XCTAssertNil(resources.documentShellPreparation)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  private func assertActualAdoption(waitForCommonRuntime: Bool) async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let preparation = DocumentShellPreparation(resources: resources)
    defer { preparation.stop() }
    preparation.prepareIfIdle()
    let renderer = try XCTUnwrap(preparation.unusedCoordinator)
    let original = try XCTUnwrap(renderer.webView)
    if waitForCommonRuntime { await waitUntil { renderer.commonRuntimeReady } }
    else { XCTAssertFalse(renderer.commonRuntimeReady, "No run-loop turn has admitted a bridge callback yet") }
    let fixture = try PreparedShellPageFixture(resources: resources)
    defer { fixture.close() }
    await waitUntil(message: { "ready=\(fixture.ready), errors=\(fixture.errors), web=\(resources.activeWebSurfaceCount)" }) {
      renderer.hasCanonicalPixels || !fixture.errors.isEmpty
    }
    let diagnostic = "ready=\(fixture.ready)\nerrors=\(fixture.errors)\nacquisitionError=\(String(describing: renderer.acquisitionError))\noriginalBounds=\(original.bounds)\noriginalFrame=\(original.frame)\noriginalAttached=\(original.window != nil)\ncurrentWeb=\(String(describing: renderer.webView))\ncommonReady=\(renderer.commonRuntimeReady)\npreparationCount=\(String(describing: renderer.payload?.source.preparationCount))\n"
    let attachment = XCTAttachment(string: diagnostic)
    attachment.name = waitForCommonRuntime ? "ready-shell-adoption-owner" : "loading-shell-adoption-owner"
    attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertTrue(fixture.errors.isEmpty, diagnostic)
    XCTAssertTrue(fixture.ready, diagnostic)
    XCTAssertTrue(fixture.paper === original, "The actual installed native host must receive the original WebKit")
    XCTAssertTrue(renderer.webView === original)
    XCTAssertEqual(renderer.payload?.documentID, fixture.document.id)
    XCTAssertEqual(renderer.payload?.source.preparationCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertNil(preparation.unusedCoordinator)
    preparation.retireUnused()
    XCTAssertTrue(fixture.paper === original, "Reclamation cannot touch the adopted document")
    XCTAssertTrue(renderer.hasCanonicalPixels)
    fixture.close()
    await waitUntil { resources.activeWebSurfaceCount == 0 }
    XCTAssertNil(preparation.unusedCoordinator, "A used runtime never returns to preparation")
    preparation.prepareIfIdle()
    XCTAssertFalse(preparation.unusedCoordinator === renderer)
    XCTAssertFalse(preparation.unusedCoordinator?.webView === original)
  }

  private func waitUntil(timeout: Duration = .seconds(8),
    message: () -> String = { "The actual common document runtime did not reach its expected state" },
    _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message())
  }
}

@MainActor
private final class PreparedShellPageFixture {
  let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body",
    source: "\\section{Adopted physical document}\\hypertarget{adopted-physical-document}{}\n\nA real canonical page with \\(x^2 + y^2\\). \\hyperlink{adopted-physical-document}{Jump to this page}.")])
  private let coordinator = DocumentPhysicalPageCoordinator()
  private let resources: SceneRenderResources
  private var host = DocumentWebHost()
  private let window: UIWindow
  private weak var previousKeyWindow: UIWindow?
  private(set) var ready = false
  private(set) var errors: [String] = []
  private(set) var linkActivations = 0
  var hasCanonicalInput: Bool {
    guard let web = paper, let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
    return renderer.nativeInputIsReady(in: host)
  }
  var visiblePaper: DocumentPaperRaster? {
    func find(_ view: UIView) -> DocumentPaperRaster? {
      if let paper = view as? DocumentPaperView { return paper.raster }
      for child in view.subviews { if let result = find(child) { return result } }
      return nil
    }
    return find(host)
  }
  var paper: WKWebView? {
    func descendants(_ view: UIView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
    }
    return descendants(host).first
  }
  init(resources: SceneRenderResources) throws {
    self.resources = resources
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    window = UIWindow(windowScene: scene)
    let controller = UIViewController(); window.rootViewController = controller
    let geometry = WorkspaceItemGeometry.uncompiledDocument
    host.frame = .init(x: 20, y: 20, width: 340, height: 340 * geometry.height / geometry.width)
    controller.view.addSubview(host); window.makeKeyAndVisible()
    update()
  }
  func replaceHost() -> DocumentWebHost {
    let previous = host
    host = DocumentWebHost(); host.frame = previous.frame
    previous.superview?.addSubview(host)
    update()
    return previous
  }
  private func update() {
    coordinator.update(.init(document: document, state: .init(id: document.id, actor: UUID()), pageIndex: 0,
      isCurrent: true, isVisible: true, isInteractive: true, pageTurnActive: false,
      onRenderReady: .init { [weak self] in self?.ready = $0 }, onPageLayout: { _ in },
       onStateChange: { _, _ in nil },
        onLinkActivation: { [weak self] _ in self?.linkActivations += 1 },
      snapshotPixelWidth: nil, onPreparationFailure: { [weak self] in self?.errors.append(String(describing: $0)) }),
      in: host, resources: resources)
  }
  func close() {
    coordinator.invalidate(); window.isHidden = true; window.rootViewController = nil
    previousKeyWindow?.makeKey()
  }
}

@MainActor
private final class WeakPreparedDocumentWeb {
  weak var value: WKWebView?
  init(_ value: WKWebView?) { self.value = value }
}
