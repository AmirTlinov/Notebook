import NotebookCore
import Observation
import UIKit
import SwiftUI
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentResourceLeaseTests: XCTestCase {
  func testDocumentAdmitsActualPacketsBesideSixtyMiBOfRetainedSceneWithoutBorrowingPencilReserve() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let sceneBytes = 60 * 1024 * 1024
    let scene = try XCTUnwrap(resources.reserveDerivedBytes(sceneBytes, priority: .passive))
    defer { scene.release() }
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<50).map { "Абзац \($0). " + String(repeating: "Содержание остаётся на своём физическом листе. ", count: 12) }.joined(separator: "\n\n"))])
    var pageCount = 0
    let fixture = fixture(resources: resources, interactive: true, document: document, layout: { pageCount = $0.pageCount })
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8), message: {
      "ready=\(fixture.coordinator.renderIsReady) error=\(String(describing: fixture.coordinator.acquisitionError)) peak=\(resources.peakAccountedBytes)"
    }) { fixture.coordinator.renderIsReady || fixture.coordinator.acquisitionError != nil }
    XCTAssertNil(fixture.coordinator.acquisitionError)
    XCTAssertTrue(fixture.coordinator.renderIsReady)
    XCTAssertGreaterThan(pageCount, 1)
    XCTAssertEqual(fixture.coordinator.payload?.source.preparationCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertLessThan(resources.peakAccountedBytes, sceneBytes + 16 * 1024 * 1024,
      "A small source must not reserve maximum-sized 48/24 MiB packets")
    XCTAssertEqual(scene.byteCount, sceneBytes)
    XCTAssertFalse(scene.isReleased, "Preparation cannot evict the shown scene")
  }

  func testASeventhDocumentWaitsWithoutCreatingWebKitAndCancellationReleasesItsRequest() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    var held: [WebSurfaceLease] = []
    for _ in 0..<6 { held.append(try await resources.acquireWebSurface(priority: .currentPage)) }
    defer { held.forEach { $0.release() } }
    let fixture = fixture(resources: resources, interactive: true)
    await waitUntil { resources.pendingWebRequestCount == 1 }
    XCTAssertNil(fixture.coordinator.webView)
    XCTAssertFalse(fixture.coordinator.renderIsReady)
    XCTAssertEqual(resources.activeWebSurfaceCount, 6)
    fixture.coordinator.invalidate()
    fixture.coordinator.invalidate()
    await waitUntil { resources.pendingWebRequestCount == 0 }
    held.removeLast().release()
    await Task.yield()
    XCTAssertEqual(resources.activeWebSurfaceCount, 5)
    XCTAssertNil(fixture.coordinator.webView, "An abandoned queue entry cannot create a late document surface")
  }

  func testCurrentPageReceivesTheReleasedSlotBeforeQueuedNeighbour() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let blocker = try await resources.acquireWebSurface(priority: .background)
    let neighbor = fixture(resources: resources, interactive: false)
    await waitUntil { resources.pendingWebRequestCount == 1 }
    let current = fixture(resources: resources, interactive: true)
    await waitUntil { resources.pendingWebRequestCount == 2 }
    blocker.release()
    await waitUntil { current.coordinator.webView != nil }
    XCTAssertNil(neighbor.coordinator.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    current.coordinator.invalidate()
    await waitUntil { neighbor.coordinator.webView != nil }
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    neighbor.coordinator.invalidate()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testReadyDocumentKeepsItsLeasedWebKitWhenItBecomesTheNeighbourInTheCurl() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let fixture = fixture(resources: resources, interactive: true)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.renderIsReady }
    let original = try XCTUnwrap(fixture.coordinator.webView)
    let paper = WorkspaceItemGeometry.document(fixture.document.paperSize)
    fixture.coordinator.mount(in: fixture.host, physicalSize: .init(width: paper.width, height: paper.height),
      isInteractive: false, priority: .neighbor)
    XCTAssertTrue(fixture.coordinator.webView === original)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertFalse(fixture.coordinator.acceptsInput)
    XCTAssertTrue(fixture.coordinator.renderIsReady)
  }

  func testLateMessagesCannotPublishOrWriteAfterDismantleAndOldSourceTokenIsRejected() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    var sources: [String] = [], states: [JSONValue] = [], readies: [Bool] = []
    let fixture = fixture(resources: resources, interactive: true,
      ready: { readies.append($0) }, source: { edit in sources.append(edit.source); return .committed }, state: { _, value in states.append(value) })
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.renderIsReady }
    let web = try XCTUnwrap(fixture.coordinator.webView)
    let token = try XCTUnwrap(fixture.coordinator.payload?.runtimeID.uuidString)
    func source(_ token: String, _ value: String) -> [String: Any] {
      let edit = DocumentSourceEdit(sessionID: UUID(), documentID: fixture.document.id, blockID: "body",
        baseSource: fixture.document.blocks[0].source, baseVersion: fixture.document.sourceVersion(blockID: "body"), source: value, sequence: 1)
      return ["kind": "source", "documentID": fixture.document.id.uuidString, "runtimeID": token, "blockID": "body",
        "edit": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(edit))]
    }
    fixture.coordinator.receive(body: source("old-token", "stale"), from: web)
    XCTAssertTrue(sources.isEmpty)
    fixture.coordinator.receive(body: source(token, "accepted"), from: web)
    await waitUntil { sources == ["accepted"] }
    fixture.coordinator.invalidate()
    let readyCount = readies.count
    fixture.coordinator.receive(body: source(token, "after teardown"), from: web)
    fixture.coordinator.receive(body: ["kind": "state", "documentID": fixture.document.id.uuidString,
      "renderToken": token, "blockID": "body", "value": ["step": 2]], from: web)
    fixture.coordinator.receive(body: ["kind": "rendered", "documentID": fixture.document.id.uuidString,
      "renderToken": token, "pageCount": 999], from: web)
    fixture.coordinator.webView(web, didFinish: nil)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(sources, ["accepted"])
    XCTAssertTrue(states.isEmpty)
    XCTAssertEqual(readies.count, readyCount)
    XCTAssertFalse(fixture.coordinator.renderIsReady)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertNil(fixture.coordinator.webView)
  }

  func testChangingDocumentOwnerWithEqualVersionStampsReplacesItsPayload() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let fixture = fixture(resources: resources, interactive: true)
    defer { fixture.coordinator.invalidate() }
    let other = DocumentDocument(actor: fixture.document.contentStamp.actor,
      blocks: [.markdown(id: "body", source: "A different physical owner")])
    let state = DocumentStateJournal(id: other.id, actor: fixture.state.stamp.actor)
    fixture.coordinator.update(document: other, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in })
    XCTAssertEqual(fixture.coordinator.payload?.documentID, other.id)
    XCTAssertEqual(fixture.coordinator.payload?.blocks.first?.source, "A different physical owner")
  }

  func testRepeatedActualPageCurlLandingsDoNotExhaustTheDocumentPool() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let paragraphs = (0..<160).map { "Paragraph \($0). " + String(repeating: "The physical page keeps its own content. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController()
    window.rootViewController = controller
    var committed = 0
    func configure() {
      controller.update(ownerID: document.id, sequenceRevision: "fixture-order", pageCount: 8, selectedIndex: committed,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, current, readiness in
          AnyView(DocumentWebView(document: document, state: state, isInteractive: current,
            selectedPageIndex: index, capturesSnapshot: false, onRenderReady: readiness,
            onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in }, resources: resources))
        }, onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    configure(); window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    // Keep old shells alive as UIKit is allowed to do; releasing their content
    // must not depend on the framework immediately deallocating a controller.
    var retainedShells: [Int: UIViewController] = [:]
    for expected in Array(1...7) + Array((0...6).reversed()) {
      let previous = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
      retainedShells[controller.displayedIndex] = previous
      let forward = expected > controller.displayedIndex
      var destination: UIViewController?
      await waitUntil(timeout: .seconds(10), message: {
        "Landing \(expected) from \(controller.displayedIndex); active WebKit \(resources.activeWebSurfaceCount), passive \(resources.activePassiveWebSurfaceCount), queued \(resources.pendingWebRequestCount), live pages \(controller.cachedPageIdentities.keys.sorted())"
      }) {
        destination = forward
          ? controller.pageViewController(controller.pageViewController, viewControllerAfter: previous)
          : controller.pageViewController(controller.pageViewController, viewControllerBefore: previous)
        return destination != nil
      }
      let next = try XCTUnwrap(destination, "Landing \(expected) requires its prepared physical page")
      if let retained = retainedShells[expected] {
        XCTAssertTrue(next === retained, "A retained UIKit shell must be restored rather than replaced by another identity")
      }
      controller.pageViewController(controller.pageViewController, willTransitionTo: [next])
      controller.pageViewController.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
      controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
        previousViewControllers: [previous], transitionCompleted: true)
      configure()
      XCTAssertEqual(controller.displayedIndex, expected)
      XCTAssertEqual(committed, expected)
      XCTAssertLessThanOrEqual(resources.activeWebSurfaceCount, 6)
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4,
        "Settled live pages are the current page, its neighbours and one directional prewarm, not traversal history")
      let web = try XCTUnwrap(descendants(next.view).first)
      let receipt = try await web.evaluateJavaScript("window.notebookRenderer.pageReceipt()") as? [String: Any]
      XCTAssertEqual(receipt?["pageIndex"] as? Int, expected,
        "The prepared next controller contains its own physical document page, not page zero")
    }
  }

  func testDistantSelectionsDuringARealDocumentCurlNeverAcquireAFifthWebSurface() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let peak = DocumentWebSurfacePeak(resources: resources)
    let paragraphs = (0..<160).map {
      "Paragraph \($0). " + String(repeating: "The physical page keeps its own content. ", count: 12)
    }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController()
    var commits: [Int] = []
    func configure(_ selected: Int) {
      controller.update(ownerID: document.id, sequenceRevision: "fixture-order", pageCount: 16, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, current, readiness in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          return AnyView(DocumentWebView(document: document, state: state, isInteractive: current,
            selectedPageIndex: index, capturesSnapshot: false, onRenderReady: readiness,
            onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in }, resources: resources))
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    }
    configure(0); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    var destination: UIViewController?
    await waitUntil(timeout: .seconds(10)) {
      destination = controller.pageViewController(controller.pageViewController, viewControllerAfter: source)
      return destination != nil && resources.activeWebSurfaceCount == 4
    }
    let landing = try XCTUnwrap(destination)
    let preparedWeb = try XCTUnwrap(descendants(landing.view).first)
    controller.pageViewController(controller.pageViewController, willTransitionTo: [landing])
    let frozenWindow = controller.cachedPageIdentities
    for target in [7, 12, 9] {
      configure(target)
      await Task.yield()
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
      XCTAssertLessThanOrEqual(resources.activeWebSurfaceCount, 4)
      XCTAssertLessThanOrEqual(peak.maximum, 4)
    }
    controller.pageViewController.setViewControllers([landing], direction: .forward, animated: false)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [source], transitionCompleted: true)
    XCTAssertTrue(descendants(landing.view).first === preparedWeb)
    XCTAssertEqual(commits, [1])
    configure(1)
    await waitUntil(timeout: .seconds(10), message: {
      "Latest target 9, actual \(controller.displayedIndex); web \(resources.activeWebSurfaceCount), peak \(peak.maximum), contents \(controller.cachedPageIdentities.keys.sorted())"
    }) { controller.displayedIndex == 9 }
    XCTAssertEqual(commits, [1, 9])
    configure(9)
    let visible = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let web = try XCTUnwrap(descendants(visible.view).first)
    let receipt = try await web.evaluateJavaScript("window.notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["pageIndex"] as? Int, 9)
    peak.sample()
    XCTAssertLessThanOrEqual(peak.maximum, 4,
      "Release-before-create must hold for actual WebKit leases throughout the handoff, not only the final dictionary")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  func testSixThumbnailsFinishBesideThreeLivePagesThenReleaseAllPreviewWebKit() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6, maximumBackgroundWebSurfaces: 2)
    let paragraphs = (0..<120).map { "Paragraph \($0). " + String(repeating: "A preview preserves the physical page. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    var liveReady: Set<Int> = [], previewReady: Set<Int> = []
    func content(previews: Bool) -> AnyView {
      AnyView(ZStack {
        ForEach(0..<3, id: \.self) { index in
          DocumentWebView(document: document, state: state, isInteractive: index == 0,
            selectedPageIndex: index, capturesSnapshot: false,
            onRenderReady: .init { if $0 { liveReady.insert(index) } else { liveReady.remove(index) } },
            onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _,_ in }, resources: resources)
            .frame(width: geometry.width, height: geometry.height)
        }
        if previews {
          ForEach(0..<6, id: \.self) { index in
            DocumentThumbnailView(document: document, state: state, pageIndex: index,
              onRenderReady: .init { if $0 { previewReady.insert(index) } else { previewReady.remove(index) } }, resources: resources)
              .frame(width: geometry.width, height: geometry.height)
              .scaleEffect(0.1)
          }
        }
      })
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIHostingController(rootView: content(previews: false))
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await waitUntil(timeout: .seconds(10)) { liveReady.count == 3 }
    XCTAssertEqual(resources.activeWebSurfaceCount, 3)
    let sourceBytes = resources.reservedBytes
    XCTAssertGreaterThan(sourceBytes, 0)
    controller.rootView = content(previews: true)
    var peakWeb = 0, peakPreparation = 0
    await waitUntil(timeout: .seconds(20), message: {
      "Ready previews \(previewReady.sorted()), web \(resources.activeWebSurfaceCount), preparation \(resources.activeBackgroundWebSurfaceCount), queue \(resources.pendingWebRequestCount)"
    }) {
      peakWeb = max(peakWeb, resources.activeWebSurfaceCount)
      peakPreparation = max(peakPreparation, resources.activeBackgroundWebSurfaceCount)
      return previewReady.count == 6 && resources.activeWebSurfaceCount == 3 && resources.pendingWebRequestCount == 0
    }
    XCTAssertLessThanOrEqual(peakWeb, 6)
    XCTAssertLessThanOrEqual(peakPreparation, 2)
    XCTAssertEqual(descendants(controller.view).count, 3, "Only the actual current and neighbour pages remain WebKit-backed")
    XCTAssertEqual(liveReady.count, 3)
    for index in 0..<6 {
      let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: index)
      let source = SceneRasterSource.document(id: document.id, token: token)
      let raster = try XCTUnwrap(resources.retainRaster(for: source))
      XCTAssertLessThanOrEqual(try XCTUnwrap(raster.image.cgImage).width, 256)
      XCTAssertNil(resources.retainRaster(for: source, minimumScale: 1), "A preview cannot certify exact paper-resolution export")
      XCTAssertEqual(DocumentRenderRegistry.shared.entry(document: document, state: state, pageIndex: index)?.token, token)
      raster.release()
    }
    controller.rootView = content(previews: false)
    await waitUntil { resources.activeWebSurfaceCount == 3 && resources.pendingWebRequestCount == 0 }
    XCTAssertEqual(resources.reservedBytes, sourceBytes, "Previews release their captures while the live source retains its shared fragments")
  }

  func testInitialInteractiveCommitBelongsToTheActiveRuntimeBeforeItsFirstFrame() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 2)
    let document = DocumentDocument(actor: UUID(), blocks: [
      .interactive(id: "initial", html: "<p>Initial state</p>", css: "",
        javaScript: "notebook.commit({ready:true})", initialState: .null, height: 100)
    ])
    var activeStates: [JSONValue] = [], passiveStates: [JSONValue] = [], readyAtCommit: [Bool] = []
    var activeCoordinator: DocumentWebCoordinator?
    let active = fixture(resources: resources, interactive: true, document: document,
      state: { _, value in
        activeStates.append(value)
        readyAtCommit.append(activeCoordinator?.renderIsReady ?? true)
      })
    activeCoordinator = active.coordinator
    let passive = fixture(resources: resources, interactive: false, document: document,
      state: { _, value in passiveStates.append(value) })
    let window = try show(active.host)
    let container = try XCTUnwrap(window.rootViewController?.view)
    container.addSubview(passive.host); passive.host.frame = container.bounds
    defer { active.coordinator.invalidate(); passive.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) {
      active.coordinator.renderIsReady && passive.coordinator.renderIsReady && activeStates.count == 1
    }
    XCTAssertEqual(activeStates, [.object(["ready": .bool(true)])])
    XCTAssertEqual(readyAtCommit, [false], "Initial execution can commit before a finished frame exists")
    XCTAssertTrue(passiveStates.isEmpty, "A neighbour or preview cannot publish autonomous state into the document")
  }

  func testFailedThumbnailPreparationReleasesSlotsAndDoesNotRetryOnViewUpdates() async throws {
    let resources = SceneRenderResources(byteLimit: 0, maximumWebSurfaces: 6, maximumBackgroundWebSurfaces: 2)
    let documents = (0..<6).map { index in
      DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Preview \(index)")])
    }
    let states = documents.map { DocumentStateJournal(id: $0.id, actor: UUID()) }
    var failures: Set<Int> = [], ready: Set<Int> = []
    func content() -> AnyView {
      AnyView(ZStack {
        ForEach(0..<6, id: \.self) { index in
          let geometry = WorkspaceItemGeometry.document(documents[index].paperSize)
          DocumentThumbnailView(document: documents[index], state: states[index], pageIndex: 0,
            onRenderReady: .init { if $0 { ready.insert(index) } }, resources: resources,
            onFailure: { _ in failures.insert(index) })
            .frame(width: geometry.width, height: geometry.height).scaleEffect(0.1)
        }
      })
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIHostingController(rootView: content())
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await waitUntil(timeout: .seconds(12), message: {
      "Failed previews \(failures.sorted()), web \(resources.activeWebSurfaceCount), queue \(resources.pendingWebRequestCount)"
    }) {
      failures.count == 6 && resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
    }
    XCTAssertTrue(ready.isEmpty)
    XCTAssertEqual(descendants(controller.view).count, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
    controller.rootView = content()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "A terminal failure cannot start a render loop when SwiftUI redraws the failure marker")
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  private func descendants(_ view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
  }

  private func fixture(resources: SceneRenderResources, interactive: Bool, document suppliedDocument: DocumentDocument? = nil,
    layout: @escaping (DocumentPageLayout) -> Void = { _ in },
    ready: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }, source: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status = { _ in .committed },
    state stateChange: @escaping (String, JSONValue) -> Void = { _,_ in })
      -> (document: DocumentDocument, state: DocumentStateJournal, coordinator: DocumentWebCoordinator, host: DocumentWebHost) {
    let document = suppliedDocument ?? DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# A real document page\n\nA bounded WebKit owner.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init(ready),
      onPageLayout: layout, onSourceChange: source, onStateChange: stateChange)
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init(ready), onPageLayout: layout, onSourceChange: source, onStateChange: stateChange)
    let host = DocumentWebHost(), paper = WorkspaceItemGeometry.document(document.paperSize)
    coordinator.mount(in: host, physicalSize: .init(width: paper.width, height: paper.height),
      isInteractive: interactive, priority: interactive ? .currentPage : .neighbor)
    return (document, state, coordinator, host)
  }

  private func show(_ host: DocumentWebHost) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(host); host.frame = controller.view.bounds
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.makeKeyAndVisible()
    return window
  }

  private func waitUntil(timeout: Duration = .seconds(2),
    message: () -> String = { "The bounded document resource transition did not complete" },
    _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message())
  }
}

/// Observation reports before each assignment. Re-arm synchronously so the
/// following release also records a transient peak between two run-loop turns.
@MainActor
private final class DocumentWebSurfacePeak {
  private weak var resources: SceneRenderResources?
  private(set) var maximum = 0
  init(resources: SceneRenderResources) { self.resources = resources; observe() }
  func sample() {
    if let resources { maximum = max(maximum, resources.activeWebSurfaceCount) }
  }
  private func observe() {
    withObservationTracking { sample() } onChange: { [weak self] in
      MainActor.assumeIsolated { self?.observe() }
    }
  }
}
