import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

final class SceneCameraPlaneTests: XCTestCase {
  @MainActor
  func testRebasePublishesMountedBodyBeforeNewBounds() {
    let container = SceneCameraPlaneView<Int>()
    container.frame = .init(x: 0, y: 0, width: 1194, height: 834)
    let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = container; window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    let button = NSButton(title: "Body", target: nil, action: nil)
    let world = WorldPoint(x: 140, y: 60), viewport = SpatialPoint(x: 1194, y: 834)
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      let p = anchor.camera.worldToScreen(world, viewport: viewport)
      return AnyView(CameraBodyProbe(button: button).frame(width: 40, height: 40)
        .position(x: p.x, y: p.y).frame(width: viewport.x, height: viewport.y))
    }
    container.update(presence: .init(mode: .board, camera: .init(scale: 0.7), viewport: viewport), revision: 0, content: content)
    container.layoutSubtreeIfNeeded()
    for index in 1...5 {
      let current = SessionPresence(mode: .board,
        camera: .init(center: .init(x: Double(index) * 37, y: -53), scale: 0.8), viewport: viewport)
      container.update(presence: current, revision: index, isCameraActive: true, content: content)
      let measured = button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: nil)
      let expected = current.camera.worldToScreen(world, viewport: viewport)
      XCTAssertEqual(measured.x, expected.x, accuracy: 1)
      XCTAssertEqual(measured.y, viewport.y - expected.y, accuracy: 1)
    }
  }

  @MainActor
  func testNativeCameraConversionKeepsOneHostedRootAndPhysicalBounds() {
    let container = SceneCameraPlaneView<Int>()
    container.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    let initial = SessionPresence(mode: .board, camera: .init(scale: 0.05), viewport: .init(x: 1194, y: 834))
    var builds = 0
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      builds += 1
      return AnyView(Color.red.frame(width: 30, height: 30)
        .position(x: 391, y: 284).frame(width: anchor.viewport.x, height: anchor.viewport.y))
    }
    container.update(presence: initial, revision: 1, content: content)
    let host = container.contentView
    for i in 0..<400 {
      let current = SessionPresence(mode: .board,
        camera: .init(center: .init(x: Double(i) * 0.31, y: Double(i) * -0.14), scale: 0.05 + Double(i % 170) / 100),
        viewport: initial.viewport)
      container.update(presence: current, revision: 1, isCameraActive: true, content: content)
      XCTAssertEqual(host.bounds.size, CGSize(width: 1194, height: 834))
      let screen = host.convert(NSPoint(x: 391, y: 284), to: nil)
      let expected = SceneCameraProjection(anchor: initial, current: current).project(.init(x: 391, y: 284))
      XCTAssertEqual(screen.x, expected.x, accuracy: 0.0001)
      XCTAssertEqual(screen.y, 834 - expected.y, accuracy: 0.0001)
    }
    XCTAssertEqual(builds, 1)
    XCTAssertEqual(container.contentPublicationCount, 1)
  }
}

private struct CameraBodyProbe: NSViewRepresentable {
  let button: NSButton
  func makeNSView(context: Context) -> NSButton { button }
  func updateNSView(_ view: NSButton, context: Context) {}
}
