import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

final class SceneCameraPlaneTests: XCTestCase {
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
