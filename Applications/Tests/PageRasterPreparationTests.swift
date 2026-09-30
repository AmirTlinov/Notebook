import NotebookCore
import UIKit
import SwiftUI
import XCTest
@testable import Notebook

@MainActor final class PageRasterPreparationTests: XCTestCase {
  func testVisibleSourcesWinTheQueueAndAcceptedTurnStillPreparesTheWholeSheet() async throws {
    let resources = SceneRenderResources(maximumBackgroundWebSurfaces: 1)
    let preparation = PageRasterPreparation(resources: resources), page = UUID()
    let sources = Array(NotebookNavigationLoadFixture.elements(leaf: 0, programs: false).prefix(3))
      .map(agentElementSnapshotSource)
    preparation.prioritize(displayed: -1, target: nil, displayedContentReady: false)
    preparation.updateViewport(pageID: page, pageIndex: 0, sources: sources, visible: [sources[2].id])
    var started: [String] = []
    let jobs = sources.map { source in Task { @MainActor in
      try await preparation.prepare(source, policy: .exact(scale: 1), pageIndex: 0, pageID: page,
        permits: { if !started.contains(source.id) { started.append(source.id) }; return true })
    } }
    defer { jobs.forEach { $0.cancel() } }
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(started.isEmpty)
    preparation.prioritize(displayed: 0, target: nil)
    for job in jobs { let raster = try await job.value; raster.release() }
    XCTAssertEqual(started.first, sources[2].id, "The first page source is not necessarily in the current viewport")
    XCTAssertEqual(Set(started), Set(sources.map(\.id)), "Offscreen material remains available for a complete curl")
    preparation.moveViewport(pageID: page, pageIndex: 4)
    preparation.prioritize(displayed: 0, target: 4, displayedContentReady: false)
    let successor = AgentElement(id: "landing-offscreen", kind: .web,
      frame: .init(x: 0, y: 0, width: 20, height: 20), source: "",
      html: "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><rect width='20' height='20' fill='red'/></svg>")
    let raster = try await preparation.prepare(successor, policy: .exact(scale: 1), pageIndex: 0,
      pageID: page, permits: { true })
    XCTAssertEqual(raster.source, .agent(successor)); raster.release()
  }

  func testColdPageDefersSpeculationUntilContentInstalledAndStillAdmitsRequestedLanding() async throws {
    try await WorkspaceInkFixture.waitForForegroundWindow()
    let controller = IPadPageTurnController(), navigation = NotebookPageNavigation(), owner = UUID()
    var pageIDs = [0: UUID(), 1: UUID(), 2: UUID()], receipts: [Int: PageTurnReadiness] = [:]
    func configure(_ revision: String) {
      controller.update(ownerID: owner, sequenceRevision: revision, pageCount: 3,
        selectedIndex: 0, navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in receipts[index] = ready; return AnyView(Color.white) },
        onCommit: { _, _ in }, onTransitioningChange: { _ in }, notebookNavigation: navigation,
        pageIdentities: pageIDs)
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    configure("initial"); window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
    defer { controller.uninstall(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let preparation = controller.pageTurnActivity.rasters
    let sources = NotebookNavigationLoadFixture.elements(leaf: 1, programs: false)
    let neighbour = Task { try await preparation.prepare(sources[1], policy: .exact(scale: 1), pageIndex: 1, permits: { true }) }
    let cancelled = Task { try await preparation.prepare(sources[2], policy: .exact(scale: 1), pageIndex: 2, permits: { true }) }
    defer { neighbour.cancel(); cancelled.cancel() }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(preparation.executorCount, 0, "Unseen authors cannot compete with the current page's first content")
    cancelled.cancel()
    do { let raster = try await cancelled.value; raster.release(); XCTFail("A withdrawn neighbour must complete cancellation") }
    catch is CancellationError { }
    XCTAssertTrue(navigation.send(.jump(1), ownerID: owner, source: "initial"))
    let landing = try await neighbour.value
    XCTAssertEqual(landing.source, .agent(sources[1])); landing.release()
    XCTAssertEqual(preparation.completedCount, 1, "An accepted landing bypasses the cold current-page fence")

    let original = try XCTUnwrap(receipts[0])
    original(true, capturable: false)
    original(false, capturable: false) // A local program revision, on the same mounted host.
    var distantStarted = false
    let distant = Task { try await preparation.prepare(sources[3], policy: .exact(scale: 1), pageIndex: 2,
      permits: { distantStarted = true; return true }) }
    defer { distant.cancel() }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(distantStarted, "An accepted target must prevent dispatch of unrelated speculation")
    XCTAssertEqual(preparation.completedCount, 1, "The accepted target owns preparation ahead of an unrelated distant page")
    XCTAssertTrue(navigation.send(.cancel, ownerID: owner, source: "initial"))
    let prepared = try await distant.value
    XCTAssertEqual(prepared.source, .agent(sources[3])); prepared.release()
    XCTAssertEqual(preparation.completedCount, 2, "A local content revision cannot close the host's completed initial barrier")

    pageIDs[0] = UUID(); configure("replacement")
    let replacement = try XCTUnwrap(receipts[0])
    XCTAssertFalse(replacement === original)
    var replacementStarted = false
    let next = Task { try await preparation.prepare(sources[4], policy: .exact(scale: 1), pageIndex: 1,
      permits: { replacementStarted = true; return true }) }
    defer { next.cancel() }
    original(true) // A retired predecessor cannot open its successor's barrier.
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(replacementStarted, "The predecessor's receipt cannot dispatch work for the cold successor")
    XCTAssertEqual(preparation.completedCount, 2, "A different page UUID/native host starts with its own cold barrier")
    replacement(true, capturable: false)
    let renewed = try await next.value
    XCTAssertEqual(renewed.source, .agent(sources[4])); renewed.release()
    XCTAssertEqual(preparation.completedCount, 3)
  }

  func testTwentyFourPassiveProgramsDoNotWaitForAnOffscreenAnimationClock() async throws {
    try await WorkspaceInkFixture.waitForForegroundWindow()
    let resources = SceneRenderResources(), preparation = PageRasterPreparation(resources: resources)
    let sources = NotebookNavigationLoadFixture.elements(leaf: 1, programs: true)
    let start = ContinuousClock.now
    let tasks = sources.map { source in Task {
      try await preparation.prepare(source, policy: .exact(scale: 1), pageIndex: 1, permits: { true })
    } }
    defer { tasks.forEach { $0.cancel() } }
    for (source, task) in zip(sources, tasks) {
      let raster = try await task.value
      XCTAssertEqual(raster.source, .agent(source))
      XCTAssertNotNil(raster.image.cgImage)
      raster.release()
    }
    XCTAssertLessThan(start.duration(to: .now), .seconds(2), "A neighbour must prepare while the current page remains interactive")
    XCTAssertLessThanOrEqual(preparation.executorCount, 2)
    XCTAssertEqual(preparation.completedCount, 24)
  }

  func testThirteenStaticSourcesShareTwoBoundedExecutorsAndRetainTheirExactPixels() async throws {
    try await WorkspaceInkFixture.waitForForegroundWindow()
    let resources = SceneRenderResources(), preparation = PageRasterPreparation(resources: resources)
    let sources = NotebookNavigationLoadFixture.elements(leaf: 0, programs: false)
    XCTAssertTrue(sources.allSatisfy { !$0.requiresLiveRuntime })
    let tasks = sources.map { source in Task {
      try await preparation.prepare(source, policy: .exact(scale: 1), pageIndex: 0, permits: { true })
    } }
    defer { tasks.forEach { $0.cancel() } }
    for (source, task) in zip(sources, tasks) {
      let raster = try await task.value
      XCTAssertEqual(raster.source, .agent(source))
      XCTAssertNotNil(raster.image.cgImage)
      raster.release()
    }
    XCTAssertLessThanOrEqual(preparation.executorCount, 2, "Cold elements must reuse the existing two transient slots, not create one process each")
    XCTAssertEqual(preparation.completedCount, 13)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testCancelingAQueuedSourceDoesNotDiscardTheRequestedLanding() async throws {
    try await WorkspaceInkFixture.waitForForegroundWindow()
    let resources = SceneRenderResources(maximumBackgroundWebSurfaces: 1)
    let held = try await resources.acquireWebSurface(priority: .background)
    let preparation = PageRasterPreparation(resources: resources)
    preparation.prioritize(displayed: 0, target: 1)
    let sources = NotebookNavigationLoadFixture.elements(leaf: 0, programs: false)
    let first = Task { try await preparation.prepare(sources[0], policy: .exact(scale: 1), pageIndex: 0, permits: { true }) }
    let obsolete = Task { try await preparation.prepare(sources[1], policy: .exact(scale: 1), pageIndex: 3, permits: { true }) }
    let target = Task { try await preparation.prepare(sources[2], policy: .exact(scale: 1), pageIndex: 1, permits: { true }) }
    defer { first.cancel(); obsolete.cancel(); target.cancel(); held.release() }
    for _ in 0..<20 { await Task.yield() }
    obsolete.cancel(); held.release()
    do { let raster = try await obsolete.value; raster.release(); XCTFail("Canceled consumer must not receive a ready image") }
    catch is CancellationError { }
    let current = try await first.value, landing = try await target.value
    defer { current.release(); landing.release() }
    XCTAssertEqual(landing.source, .agent(sources[2]))
    XCTAssertEqual(preparation.executorCount, 1)
  }
}
