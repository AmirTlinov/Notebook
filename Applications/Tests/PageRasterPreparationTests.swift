import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor final class PageRasterPreparationTests: XCTestCase {
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
