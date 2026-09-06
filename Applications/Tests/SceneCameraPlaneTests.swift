import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class SceneCameraPlaneTests: XCTestCase {
  func testOneMatrixPreservesWorldPointsAcrossFractionalCameraAndTiledCoordinates() {
    for center in [WorldPoint.zero, .init(tileX: 9_000_000_000_000, tileY: -9_000_000_000_000, localX: 91.3, localY: 107.6)] {
      let anchor = SessionPresence(mode: .board, camera: .init(center: center, scale: 0.371),
        viewport: .init(x: 1194, y: 834))
      for scale in [0.0125, 0.0371, 0.371, 0.6789, 1.39] {
        let current = SessionPresence(mode: .board,
          camera: .init(center: center.offsetBy(x: 531.3, y: -94.19), scale: scale),
          viewport: .init(x: 834, y: 1194))
        let matrix = SceneCameraProjection(anchor: anchor, current: current)
        for offset in [-514.2, -0.03, 0, 792.5] {
          let point = center.offsetBy(x: offset, y: offset * -0.72)
          let mapped = matrix.project(anchor.camera.worldToScreen(point, viewport: anchor.viewport))
          let expected = current.camera.worldToScreen(point, viewport: current.viewport)
          XCTAssertEqual(mapped.x, expected.x, accuracy: 0.000_000_1)
          XCTAssertEqual(mapped.y, expected.y, accuracy: 0.000_000_1)
        }
      }
    }
  }

  @MainActor
  func testCameraChangesOneNativeTransformWithoutReplacingContentOrBounds() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    let controller = SceneCameraPlaneController<Int>()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let initial = SessionPresence(mode: .board, camera: .init(scale: 0.05), viewport: .init(x: 1194, y: 834))
    var builds = 0
    var handlerProjection: ScenePlaneProjection?
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      builds += 1
      handlerProjection = projection
      return AnyView(Color.red.frame(width: 20, height: 30)
        .position(x: 391, y: 284).frame(width: anchor.viewport.x, height: anchor.viewport.y))
    }
    controller.update(presence: initial, revision: 1, content: content)
    let view = controller.contentView
    for i in 0..<400 {
      let scale = 0.05 + Double(i % 170) / 100
      let current = SessionPresence(mode: .board,
        camera: .init(center: .init(x: Double(i) * 0.31, y: Double(i) * -0.14), scale: scale),
        viewport: initial.viewport)
      controller.update(presence: current, revision: 1, isCameraActive: true, content: content)
      XCTAssertEqual(view.bounds, CGRect(x: 0, y: 0, width: 1194, height: 834))
      let screen = view.convert(CGPoint(x: 391, y: 284), to: controller.view)
      let expected = SceneCameraProjection(anchor: initial, current: current).project(.init(x: 391, y: 284))
      XCTAssertEqual(screen.x - controller.view.bounds.minX, expected.x, accuracy: 0.0001)
      XCTAssertEqual(screen.y - controller.view.bounds.minY, expected.y, accuracy: 0.0001)
      XCTAssertEqual(handlerProjection?.current, current)
    }
    XCTAssertEqual(builds, 1)
    XCTAssertEqual(controller.contentPublicationCount, 1)
    XCTAssertEqual(controller.cameraProjectionCount, 401)
    controller.update(presence: initial, revision: 2, content: content)
    XCTAssertEqual(builds, 2, "A content revision, not a camera sample, updates the root")
    XCTAssertTrue(view === controller.contentView)
  }

  @MainActor
  func testFarJumpRebasesBeforeSubtractingUnrelatedWorldTiles() {
    let controller = SceneCameraPlaneController<Int>()
    let viewport = SpatialPoint(x: 1194, y: 834)
    let first = SessionPresence(mode: .board,
      camera: .init(center: .init(tileX: Int64.min + 100, tileY: 0, localX: 0, localY: 0), scale: 0.4), viewport: viewport)
    let last = SessionPresence(mode: .board,
      camera: .init(center: .init(tileX: Int64.max - 100, tileY: 0, localX: 0, localY: 0), scale: 0.4), viewport: viewport)
    var anchors: [WorldPoint] = []
    for presence in [first, last] {
      controller.update(presence: presence, revision: 1, reanchorsOnRevision: false) { anchor, _ in
        anchors.append(anchor.camera.center)
        return AnyView(Color.clear)
      }
    }
    XCTAssertEqual(anchors, [first.camera.center, last.camera.center])
    let screen = controller.contentView.convert(CGPoint(x: viewport.x / 2, y: viewport.y / 2), to: controller.view)
    XCTAssertEqual(screen.x - controller.view.bounds.minX, viewport.x / 2, accuracy: 0.0001)
    XCTAssertEqual(screen.y - controller.view.bounds.minY, viewport.y / 2, accuracy: 0.0001)
  }
  @MainActor
  func testSettlingCameraRebasesInputOnceAndPreservesVisibleGeometry() {
    let controller = SceneCameraPlaneController<Int>()
    let initial = SessionPresence(mode: .board, camera: .init(scale: 1), viewport: .init(x: 1194, y: 834))
    let nearby = SessionPresence(mode: .board, camera: .init(center: .init(x: 1190, y: 0), scale: 1), viewport: initial.viewport)
    let outside = SessionPresence(mode: .board, camera: .init(center: .init(x: 1200, y: 0), scale: 1), viewport: initial.viewport)
    var anchors: [WorldPoint] = []
    for (presence, active) in [(initial, false), (nearby, true), (outside, true), (outside, false), (outside, false)] {
      controller.update(presence: presence, revision: 1, reanchorsOnRevision: false, isCameraActive: active) { anchor, _ in
        anchors.append(anchor.camera.center)
        return AnyView(Color.clear)
      }
    }
    XCTAssertEqual(anchors, [initial.camera.center, outside.camera.center])
    let preparedCenter = CGPoint(x: initial.viewport.x / 2, y: initial.viewport.y / 2)
    let screen = controller.contentView.convert(preparedCenter, to: controller.view)
    XCTAssertEqual(screen.x - controller.view.bounds.minX, initial.viewport.x / 2, accuracy: 0.0001)
    XCTAssertEqual(screen.y - controller.view.bounds.minY, initial.viewport.y / 2, accuracy: 0.0001)
  }

  @MainActor
  func testPreviouslyOffscreenNativeControlReceivesInputAfterCameraPan() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    let controller = SceneCameraPlaneController<Int>()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; oldKeyWindow?.makeKey() }
    let button = UIButton(type: .system)
    button.setTitle("Control", for: .normal)
    let initial = SessionPresence(mode: .board, camera: .init(scale: 1), viewport: .init(x: 1194, y: 834))
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      let position = anchor.camera.worldToScreen(.init(x: 693, y: 0), viewport: anchor.viewport)
      return AnyView(ScenePlaneProbeControl(button: button).frame(width: 100, height: 50)
        .position(x: position.x, y: position.y).frame(width: anchor.viewport.x, height: anchor.viewport.y))
    }
    controller.update(presence: initial, revision: 1, content: content)
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let current = SessionPresence(mode: .board, camera: .init(center: .init(x: 500, y: 0), scale: 1), viewport: initial.viewport)
    controller.update(presence: current, revision: 1, isCameraActive: true, content: content)
    XCTAssertEqual(controller.contentPublicationCount, 1)
    controller.update(presence: current, revision: 1, isCameraActive: false, content: content)
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let point = button.convert(CGPoint(x: 50, y: 25), to: controller.view)
    XCTAssertEqual(point.x - controller.view.bounds.minX, 790, accuracy: 1)
    XCTAssertTrue(controller.view.bounds.contains(point))
    let hit = controller.view.hitTest(point, with: nil)
    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
      "The visible control must own its native input, not the prepared viewport bounds: \(String(describing: hit))")
    XCTAssertEqual(controller.contentPublicationCount, 2)
  }

}


private struct ScenePlaneProbeControl: UIViewRepresentable {
  let button: UIButton
  func makeUIView(context: Context) -> UIButton { button }
  func updateUIView(_ view: UIButton, context: Context) {}
}
