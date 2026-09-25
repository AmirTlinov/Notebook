import NotebookCore
import PencilKit
import UIKit
import XCTest

@testable import Notebook

final class InkCanvasLifecycleTests: XCTestCase {
  @MainActor
  func testDetachedCanvasCannotStartItsDisplayLoopFromLateFrameRequests() async {
    let canvas = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
    XCTAssertNil(canvas.window)
    XCTAssertTrue(canvas.isFrameLoopPaused, "Construction does not admit a drawable timer")
    canvas.applySpatial(mesh(y: 30))
    canvas.finishSpatialPreparation()
    canvas.project(camera: .init(scale: 0.5), viewport: .init(x: 160, y: 160))
    XCTAssertTrue(canvas.isFrameLoopPaused, "Preparing an unmounted owner changes content, not display execution")

    let lateCompletion = Task { @MainActor in
      await Task.yield()
      canvas.finishSpatialPreparation()
    }
    await lateCompletion.value
    // A callback already queued by MetalKit must also respect the same gate.
    canvas.draw(in: canvas)
    XCTAssertTrue(canvas.isFrameLoopPaused)
    XCTAssertFalse(canvas.isStableFramePresented,
      "A detached live canvas is not the offscreen snapshot publication route")
  }

  @MainActor
  func testRetainedCulledCanvasStopsImmediatelyAndPresentsNewContentAfterRemount() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.backgroundColor = .white
    let canvas = InkCanvasView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))
    controller.view.addSubview(canvas)
    window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    canvas.applySpatial(mesh(y: 30))
    try await waitForStableFrame(canvas)

    // Retain the exact canvas as UIKit may do. Removing it before the requested
    // draw executes must stop the loop without relying on deallocation.
    canvas.finishSpatialPreparation()
    XCTAssertFalse(canvas.isFrameLoopPaused)
    canvas.removeFromSuperview()
    XCTAssertNil(canvas.window)
    XCTAssertTrue(canvas.isFrameLoopPaused, "Culling stops a pending display loop synchronously")
    canvas.applySpatial(mesh(y: 110))
    XCTAssertFalse(canvas.isStableFramePresented)
    let lateCompletion = Task { @MainActor in
      await Task.yield()
      canvas.finishSpatialPreparation()
    }
    await lateCompletion.value
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(canvas.isFrameLoopPaused, "Late work cannot restart a retained offscreen canvas")
    XCTAssertFalse(canvas.isStableFramePresented)

    controller.view.addSubview(canvas)
    XCTAssertNotNil(canvas.window)
    XCTAssertFalse(canvas.isFrameLoopPaused, "Remount resumes the same physical owner")
    try await waitForStableFrame(canvas)
    XCTAssertGreaterThan(canvas.committedSourceNodeCount, 0)
    XCTAssertTrue(canvas.isFrameLoopPaused, "After presenting the replacement ink, the resting canvas stops again")
  }

  @MainActor
  func testPageCoalescesNewMaterialUntilTheSystemSuppliesADrawable() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let canvas = InkCanvasView(frame: .zero)
    controller.view.addSubview(canvas); window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    canvas.projectPage(region: .init(x: 0, y: 0, width: 160, height: 160),
      sourceSize: .init(width: 160, height: 160), pixelDensity: 2)
    var stroke = ActiveInkStroke(style: .standard)
    func move(to y: CGFloat) {
      stroke.replaceMeasuredTail(from: 0, with: [CGFloat(20), 140].map { x in
        PKStrokePoint(location: .init(x: x, y: y), timeOffset: 0,
          size: .init(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
      })
      canvas.displayActiveStroke(stroke)
    }
    move(to: 30); canvas.draw()
    let first = canvas.drawableRequestCount
    XCTAssertEqual(first, 0, "Input cannot synchronously request a page drawable")
    XCTAssertTrue(canvas.isPaused, "The MetalKit timer is not a competing page clock")
    XCTAssertFalse(canvas.isFrameLoopPaused)
    // Remain in the same main-actor turn: the system has not supplied a frame.
    // Newer tails coalesce without blocking this turn to acquire a drawable.
    move(to: 70); canvas.draw()
    move(to: 110); canvas.draw()
    XCTAssertEqual(canvas.drawableRequestCount, first)
    canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    // Simulator readiness is GPU completion, not UIKit window presentation.
    let windowObservationStart = ContinuousClock.now
    XCTAssertGreaterThan(canvas.drawableRequestCount, first)
    let probes: [(CGPoint, NotebookUXObservation.Color)] = [
      (.init(x: 80, y: 30), .paper), (.init(x: 80, y: 70), .paper), (.init(x: 80, y: 110), .black)]
    // Presentation must show the latest material, not replay queued stale tails.
    try await assertUX("page-coalesced-current-material", since: windowObservationStart, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches(
        probes.map { (canvas.convert($0.0, to: window), $0.1) })
    }

    canvas.removeFromSuperview()
    XCTAssertTrue(canvas.isFrameLoopPaused, "A retained page must retire its system clock on cull")
    stroke = ActiveInkStroke(style: .standard)
    move(to: 70)
    canvas.commitActiveStroke()
    canvas.draw()
    XCTAssertTrue(canvas.isFrameLoopPaused, "Offscreen source updates cannot resume the clock")
    controller.view.addSubview(canvas)
    try await waitForStableFrame(canvas)
    try await assertUX("page-remount-keeps-accepted-material", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([
        (canvas.convert(.init(x: 80, y: 70), to: window), .black),
        (canvas.convert(.init(x: 80, y: 110), to: window), .black)])
    }
  }

  @MainActor
  func testPageStopsDrawableProductionWhenAResizedPoolCannotBeAdmitted() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.backgroundColor = .white
    let resources = SceneRenderResources(byteLimit: 512 * 1024)
    let canvas = InkCanvasView(frame: .zero, resources: resources)
    controller.view.addSubview(canvas); window.makeKeyAndVisible()
    defer { canvas.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    func project(_ side: CGFloat) {
      canvas.projectPage(region: .init(x: 0, y: 0, width: side, height: side),
        sourceSize: .init(width: side, height: side), pixelDensity: 1)
    }
    func draw(_ y: CGFloat) {
      let stroke = ActiveInkStroke(style: .standard)
      stroke.replaceMeasuredTail(from: 0, with: [CGFloat(20), 140].map { x in
        PKStrokePoint(location: .init(x: x, y: y), timeOffset: 0,
          size: .init(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
      })
      canvas.displayActiveStroke(stroke)
    }
    project(160)
    draw(30); canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    let frames = canvas.drawableRequestCount
    draw(70)
    project(2_000)
    XCTAssertEqual(canvas.renderFailure, .resourceLimit)
    // Let the final UIKit phase drain; it must not keep an unadmitted Metal
    // clock producing system drawables, even while the contact is retained.
    let deadline = ContinuousClock.now + .seconds(2)
    while !canvas.isFrameLoopPaused, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(canvas.isFrameLoopPaused)
    XCTAssertEqual(canvas.drawableRequestCount, frames)
    XCTAssertLessThanOrEqual(resources.reservedBytes, resources.byteLimit)
    project(160); canvas.commitActiveStroke()
    try await waitForStableFrame(canvas)
    // Observe UIKit convergence separately from the completed GPU submission.
    let windowObservationStart = ContinuousClock.now
    XCTAssertNil(canvas.renderFailure)
    XCTAssertEqual((canvas.layer as? CAMetalLayer)?.maximumDrawableCount, 2)
    // A failed allocation must retain both the accepted source and live contact.
    try await assertUX("page-restored-pool-keeps-source-and-contact", since: windowObservationStart, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([
        (canvas.convert(.init(x: 80, y: 30), to: window), .black),
        (canvas.convert(.init(x: 80, y: 70), to: window), .black)])
    }
  }

  @MainActor
  private func waitForStableFrame(_ canvas: InkCanvasView) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(canvas.isStableFramePresented && canvas.isFrameLoopPaused), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(canvas.isStableFramePresented, "The mounted canvas must complete a frame of its current ink")
    XCTAssertTrue(canvas.isFrameLoopPaused)
  }

  private func mesh(y: CGFloat) -> SpatialInkMesh {
    let points = [CGFloat(20), 140].map { x in
      PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: 0,
        size: CGSize(width: 5, height: 5), opacity: 1, force: 1,
        azimuth: 0, altitude: .pi / 2)
    }
    return .local([.ink(points: points, color: .black)])
  }
}
