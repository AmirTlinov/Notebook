import NotebookCore
import UIKit
import WebKit
import XCTest

@testable import Notebook

final class AgentWebLeaseTests: XCTestCase {
  @MainActor
  func testPreviousSourceCannotCommitStateOrDiagnosticsIntoTheCurrentSource() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .input)
    var states: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { states.append($0) })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let previous = element(source: "first")
    let current = element(source: "second")
    coordinator.load(previous, in: web)
    let previousToken = try XCTUnwrap(coordinator.loadToken)
    coordinator.load(current, in: web)
    let currentToken = try XCTUnwrap(coordinator.loadToken)
    XCTAssertNotEqual(previousToken, currentToken)

    coordinator.receive(["token": previousToken, "kind": "state", "value": "late previous state"])
    coordinator.receive(["token": previousToken, "kind": "diagnostic", "category": "javascript_error", "message": "late previous error"])
    coordinator.receive(["kind": "state", "value": "unaddressed state"])
    XCTAssertTrue(states.isEmpty)
    XCTAssertTrue(resources.diagnostics(for: [previous, current]).isEmpty)

    coordinator.receive(["token": currentToken, "kind": "state", "value": ["current": true]])
    coordinator.receive(["token": currentToken, "kind": "diagnostic", "category": "overflow", "message": "current frame"])
    XCTAssertEqual(states, [.object(["current": .bool(true)])])
    XCTAssertEqual(resources.diagnostics(for: [current]).map(\.kind), ["overflow"])
    XCTAssertTrue(resources.diagnostics(for: [previous]).isEmpty)
  }

  @MainActor
  func testSnapshotAndQueuedReadinessCannotPublishAfterInvalidation() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    var ready: [Bool] = []
    var states: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onRenderReady: { ready.append($0) }, onState: { states.append($0) })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let source = element(source: "current")
    coordinator.load(source, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.invalidate()
    coordinator.completeSnapshot(raster(), error: nil, token: token, element: source, reservation: reservation)
    coordinator.receive(["token": token, "kind": "state", "value": 42])
    coordinator.receive(["token": token, "kind": "diagnostic", "category": "javascript_error", "message": "too late"])
    await Task.yield()
    XCTAssertNil(resources.image(for: source))
    XCTAssertTrue(resources.diagnostics(for: [source]).isEmpty)
    XCTAssertTrue(states.isEmpty)
    XCTAssertTrue(ready.isEmpty)
    XCTAssertNil(coordinator.loadToken)
    XCTAssertNil(web.navigationDelegate)
  }

  @MainActor
  func testSnapshotFromPreviousLoadDoesNotReplaceCurrentSourceRaster() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let previous = element(source: "previous")
    let current = element(source: "current")
    coordinator.load(previous, in: web)
    let previousToken = try XCTUnwrap(coordinator.loadToken)
    let previousReservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.load(current, in: web)
    coordinator.completeSnapshot(raster(), error: nil, token: previousToken, element: previous,
      reservation: previousReservation)
    XCTAssertNil(resources.image(for: previous))
    XCTAssertNil(resources.image(for: current))

    let currentReservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.completeSnapshot(raster(), error: nil, token: try XCTUnwrap(coordinator.loadToken),
      element: current, reservation: currentReservation)
    XCTAssertNotNil(resources.image(for: current))
    XCTAssertNil(resources.image(for: previous))
  }

  @MainActor
  func testReleasedLeaseRejectsCallbacksBeforeTheViewIsDismantled() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    var states: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { states.append($0) })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate() }
    let source = element(source: "old owner")
    coordinator.load(source, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    lease.release()
    coordinator.receive(["token": token, "kind": "state", "value": 42])
    XCTAssertTrue(states.isEmpty)
    coordinator.load(element(source: "new owner"), in: web)
    XCTAssertEqual(coordinator.loadToken, token, "An expired coordinator cannot acquire another owner's source.")
  }

  @MainActor
  func testOriginOnlyMoveReusesRasterAndAcceptsAnAlreadyRunningSnapshot() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let original = element(source: "one physical surface")
    let moved = original.updating(frame: .init(x: 100, y: -50, width: 32, height: 32))
    coordinator.load(original, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    coordinator.load(moved, in: web)
    XCTAssertEqual(coordinator.loadToken, token)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.completeSnapshot(raster(), error: nil, token: token, element: original, reservation: reservation)
    let retained = try XCTUnwrap(resources.retainRaster(for: moved))
    defer { retained.release() }
    XCTAssertNotNil(retained.image(for: .agent(original)))
    XCTAssertNotNil(resources.image(for: moved))
    XCTAssertNil(resources.image(for: moved.updating(state: .number(2))))
    XCTAssertNil(resources.image(for: moved.updating(frame: .init(x: 100, y: -50, width: 64, height: 32))))
    XCTAssertNil(resources.image(for: element(source: "changed program")))
  }

  @MainActor
  func testCurrentSnapshotErrorIsReportedButInvalidatedErrorIsDiscarded() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let source = element(source: "current")
    coordinator.load(source, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    let failure = NSError(domain: "NotebookSnapshotTest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Snapshot failed"])
    coordinator.completeSnapshot(nil, error: failure, token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32)))
    XCTAssertEqual(resources.diagnostics(for: [source]).map(\.kind), ["snapshot_error"])
    coordinator.invalidate()
    coordinator.completeSnapshot(nil, error: NSError(domain: "late", code: 2), token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32)))
    XCTAssertEqual(resources.diagnostics(for: [source]).count, 1)
  }

  @MainActor
  func testSnapshotSamplingCapsAllocationWithoutResizingPhysicalContent() throws {
    let source = element(source: "large", width: 10_000, height: 8_000)
    let display = try XCTUnwrap(AgentSnapshotPolicy.display(scale: 3).pixelSize(for: source))
    XCTAssertLessThanOrEqual(max(display.width, display.height), 2048)
    XCTAssertLessThanOrEqual(display.width * display.height, 4_194_304)
    let configuration = try XCTUnwrap(AgentWebCoordinator.snapshotConfiguration(for: source,
      policy: .display(scale: 3), backingScale: 3))
    XCTAssertEqual(configuration.rect.size, CGSize(width: 10_000, height: 8_000))
    XCTAssertEqual(try XCTUnwrap(configuration.snapshotWidth).doubleValue * 3, display.width, accuracy: 0.001)
    XCTAssertEqual(AgentSnapshotPolicy.exact(scale: 2).pixelSize(for: source), CGSize(width: 20_000, height: 16_000))
    let fractional = element(source: "fractional", width: 10_000.1, height: 100.1)
    let exact = try XCTUnwrap(AgentSnapshotPolicy.exact(scale: 2).pixelSize(for: fractional))
    XCTAssertGreaterThanOrEqual(exact.width / fractional.frame.width, 2)
    XCTAssertGreaterThanOrEqual(floor(exact.width * fractional.frame.height / fractional.frame.width) / fractional.frame.height, 2,
      "WebKit's rounded height must still satisfy the declared exact sampling density.")
    XCTAssertNil(AgentSnapshotPolicy.display(scale: 2).pixelSize(for: element(source: "thin", width: 1, height: 1_000_000)),
      "A one-pixel width cannot silently inflate a capped, extremely tall raster.")
  }

  @MainActor
  func testRasterBackingIsBoundedByPreparedPixelsAndDoesNotFollowCameraZoom() throws {
    let source = element(source: "large physical surface", width: 10_000, height: 8_000)
    let policy = AgentSnapshotPolicy.display(scale: 3)
    let pixels = try XCTUnwrap(policy.pixelSize(for: source))
    let density = policy.rasterizationScale(for: source, displayScale: 3)
    XCTAssertLessThanOrEqual(source.frame.width * density, 2048)
    XCTAssertLessThanOrEqual(source.frame.height * density, 2048)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
      UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: pixels))
    }
    let resources = SceneRenderResources()
    XCTAssertTrue(resources.store(image, for: source))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    let view = AgentSnapshotRasterView()
    defer { view.removeRaster(); raster.release() }
    view.bounds = CGRect(x: 0, y: 0, width: source.frame.width, height: source.frame.height)
    view.updateRaster(raster, displayScale: 3)
    view.layoutIfNeeded()
    let rasterScale = view.layer.rasterizationScale
    XCTAssertTrue(view.layer.shouldRasterize)
    XCTAssertEqual(view.layer.minificationFilter, .trilinear)
    XCTAssertLessThanOrEqual(view.bounds.width * rasterScale, 2048)
    XCTAssertLessThanOrEqual(view.bounds.height * rasterScale, 2048)
    for zoom in [0.01, 0.1, 0.8, 2, 4] {
      view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
      view.setNeedsLayout(); view.layoutIfNeeded()
      XCTAssertEqual(view.layer.rasterizationScale, rasterScale,
        "The camera changes projection, not the physical surface's raster density.")
    }
  }

  @MainActor
  func testNativeSnapshotPresenterKeepsItsRasterAccountedUntilContentsAreCleared() throws {
    let source = element(source: "retained by native presenter")
    let resources = SceneRenderResources(byteLimit: 8_192)
    XCTAssertTrue(resources.store(raster(), for: source))
    var lease: RasterLease? = try XCTUnwrap(resources.retainRaster(for: source))
    weak let nativeRetainedLease = lease
    let view = AgentSnapshotRasterView()
    view.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
    view.updateRaster(try XCTUnwrap(lease), displayScale: 2)
    lease = nil
    XCTAssertNotNil(nativeRetainedLease, "Dropping SwiftUI state must not release pixels still owned by a native layer.")
    XCTAssertNil(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32),
      "The native presenter pins its source against eviction.")
    view.removeRaster()
    XCTAssertNil(view.layer.contents)
    XCTAssertNil(nativeRetainedLease)
    let admitted = resources.reserveRaster(pixelWidth: 32, pixelHeight: 32)
    XCTAssertNotNil(admitted)
    admitted?.release()
  }

  func testOverlayReadinessRequiresCurrentSourceAndIgnoresPreviousSourceTeardown() {
    let previous = element(source: "previous")
    let current = element(source: "current")
    var readiness = AgentOverlayReadiness()
    readiness.record(previous, ready: true)
    XCTAssertTrue(readiness.isReady(for: [previous]))
    XCTAssertFalse(readiness.isReady(for: [current]), "Reusing an element ID does not confirm its new source.")
    readiness.retain([current])
    XCTAssertFalse(readiness.isReady(for: [current]))
    readiness.record(current, ready: true)
    readiness.record(previous, ready: false)
    XCTAssertTrue(readiness.isReady(for: [current]), "An old view's teardown cannot invalidate the current raster.")
    readiness.record(current, ready: false)
    XCTAssertFalse(readiness.isReady(for: [current]))
    XCTAssertTrue(readiness.isReady(for: []))
  }

  private func element(source: String, width: Double = 32, height: Double = 32) -> AgentElement {
    AgentElement(id: "same-element", kind: .web, frame: PageRect(x: 0, y: 0, width: width, height: height),
      source: source, html: "<p>\(source)</p>")
  }

  @MainActor
  private func raster() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
  }
}
