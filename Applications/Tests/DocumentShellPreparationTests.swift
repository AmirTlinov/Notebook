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
      await window.MathJax.startup.promise;
      return typeof window.MathJax.typesetPromise === 'function' &&
        typeof window.notebookRenderer.beginSourcePreparation === 'function';
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

  func testCurrentPageAdoptsTheSameReadyCoordinatorWebAndAdmission() async throws {
    try await assertActualAdoption(waitForCommonRuntime: true)
  }

  func testCurrentPageCanAdoptBeforeTheCommonRuntimeHasFinishedLoading() async throws {
    try await assertActualAdoption(waitForCommonRuntime: false)
  }

  func testForegroundAdmissionReclaimsUnusedShellBeforeRefusingItsSlot() async throws {
    try await assertForegroundReclaim(waitForCommonRuntime: true)
  }

  func testForegroundAdmissionReclaimsLoadingShellWithoutAQueuePosition() async throws {
    try await assertForegroundReclaim(waitForCommonRuntime: false)
  }

  private func assertForegroundReclaim(waitForCommonRuntime: Bool) async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, maximumPendingWebRequests: 0)
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
      fixture.ready || !fixture.errors.isEmpty
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
  let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body",
    source: "# Adopted physical document\n\nA real canonical page with \\(x^2 + y^2\\).")])
  private let coordinator = DocumentPhysicalPageCoordinator()
  private let host = DocumentWebHost()
  private let window: UIWindow
  private weak var previousKeyWindow: UIWindow?
  private(set) var ready = false
  private(set) var errors: [String] = []
  var paper: WKWebView? {
    func descendants(_ view: UIView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
    }
    return descendants(host).first
  }
  init(resources: SceneRenderResources) throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    window = UIWindow(windowScene: scene)
    let controller = UIViewController(); window.rootViewController = controller
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    host.frame = .init(x: 20, y: 20, width: 340, height: 340 * geometry.height / geometry.width)
    controller.view.addSubview(host); window.makeKeyAndVisible()
    coordinator.update(.init(document: document, state: .init(id: document.id, actor: UUID()), pageIndex: 0,
      isCurrent: true, isVisible: true, isInteractive: true, pageTurnActive: false,
      onRenderReady: .init { [weak self] in self?.ready = $0 }, onPageLayout: { _ in },
      onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil }, drafts: [],
      onDraftChange: { _ in }, onDraftDiscard: { _ in }, onLinkActivation: { _ in },
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
