import XCTest
@testable import Notebook

final class SceneRasterPreparationTests: XCTestCase {
  @MainActor
  func testCancelledSubmittedCaptureKeepsItsBudgetUntilTheActualCallback() async throws {
    let resources = SceneRenderResources(byteLimit: 4096, profile: .headless)
    let reservation = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive))
    let lease = try await resources.acquireWebSurface(priority: .input)
    defer { lease.release() }
    let capture = AgentSnapshotCapture(reservation: reservation, lease: lease)
    capture.cancel()
    XCTAssertTrue(capture.isCancelled)
    XCTAssertFalse(capture.isComplete)
    XCTAssertEqual(resources.reservedBytes, 4096)
    XCTAssertNil(resources.reserveDerivedBytes(1, priority: .passive))
    let waiting = Task { try await capture.waitForCompletion(deadline: .now + .seconds(2)) }
    capture.finish()
    try await waiting.value
    XCTAssertTrue(capture.isComplete)
    XCTAssertEqual(resources.reservedBytes, 0)
    let next = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive))
    capture.finish()
    XCTAssertEqual(resources.reservedBytes, 4096, "A late duplicate callback cannot release the next allocation")
    next.release()
  }

  @MainActor
  func testDismantledLiveCoordinatorKeepsTheSameWebKitGrantUntilItsHeldCallbackReturns() async throws {
    let resources = SceneRenderResources(byteLimit: 4096, profile: .headless, maximumWebSurfaces: 1)
    var lease: WebSurfaceLease? = try await resources.acquireWebSurface(priority: .input)
    var coordinator: AgentWebCoordinator? = AgentWebCoordinator(lease: try XCTUnwrap(lease),
      resources: resources, onState: { _ in })
    weak let retired = coordinator
    let web = AgentWebCoordinator.makeWebView(coordinator: try XCTUnwrap(coordinator))
    let reservation = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive))
    // This is the production submission boundary. The held callback is the
    // only lifetime after ordinary representable invalidation and deinit.
    let heldCallback = try XCTUnwrap(coordinator).holdSubmittedSnapshot(reservation)
    coordinator?.invalidate(); coordinator = nil; lease = nil
    XCTAssertNil(retired)
    XCTAssertNil(web.navigationDelegate)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.reservedBytes, 4096)
    heldCallback.finish()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testCaptureDrainDeadlineDoesNotPretendSubmittedWorkWasReleased() async throws {
    let resources = SceneRenderResources(byteLimit: 4096, profile: .headless)
    let reservation = try XCTUnwrap(resources.reserveDerivedBytes(4096, priority: .passive))
    let lease = try await resources.acquireWebSurface(priority: .input)
    defer { lease.release() }
    var reader: AgentSnapshotCapture? = AgentSnapshotCapture(reservation: reservation, lease: lease)
    let submittedCallback = try XCTUnwrap(reader)
    reader?.cancel(); reader = nil
    do {
      try await submittedCallback.waitForCompletion(deadline: .now)
      XCTFail("A deadline is a failed drain, not a completed snapshot")
    } catch {
      XCTAssertEqual(error as? SceneRenderError, .snapshotPending("agent_capture_drain"))
    }
    XCTAssertEqual(resources.reservedBytes, 4096, "The callback retains allocation after reader teardown and timeout")
    submittedCallback.finish()
    try await submittedCallback.waitForCompletion(deadline: .now)
    XCTAssertEqual(resources.reservedBytes, 0)
  }
}
