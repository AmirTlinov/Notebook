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
    XCTAssertTrue(canvas.isPaused, "Construction does not admit a drawable timer")
    canvas.applySpatial(mesh(y: 30))
    canvas.finishSpatialPreparation()
    canvas.project(camera: .init(scale: 0.5), viewport: .init(x: 160, y: 160))
    XCTAssertTrue(canvas.isPaused, "Preparing an unmounted owner changes content, not display execution")

    let lateCompletion = Task { @MainActor in
      await Task.yield()
      canvas.finishSpatialPreparation()
    }
    await lateCompletion.value
    // A callback already queued by MetalKit must also respect the same gate.
    canvas.draw(in: canvas)
    XCTAssertTrue(canvas.isPaused)
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
    XCTAssertFalse(canvas.isPaused)
    canvas.removeFromSuperview()
    XCTAssertNil(canvas.window)
    XCTAssertTrue(canvas.isPaused, "Culling stops a pending display loop synchronously")
    canvas.applySpatial(mesh(y: 110))
    XCTAssertFalse(canvas.isStableFramePresented)
    let lateCompletion = Task { @MainActor in
      await Task.yield()
      canvas.finishSpatialPreparation()
    }
    await lateCompletion.value
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(canvas.isPaused, "Late work cannot restart a retained offscreen canvas")
    XCTAssertFalse(canvas.isStableFramePresented)

    controller.view.addSubview(canvas)
    XCTAssertNotNil(canvas.window)
    XCTAssertFalse(canvas.isPaused, "Remount resumes the same physical owner")
    try await waitForStableFrame(canvas)
    XCTAssertGreaterThan(canvas.committedVertexCount, 0)
    XCTAssertTrue(canvas.isPaused, "After presenting the replacement ink, the resting canvas stops again")
  }

  @MainActor
  private func waitForStableFrame(_ canvas: InkCanvasView) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !(canvas.isStableFramePresented && canvas.isPaused), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(canvas.isStableFramePresented, "The mounted canvas must complete a frame of its current ink")
    XCTAssertTrue(canvas.isPaused)
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
