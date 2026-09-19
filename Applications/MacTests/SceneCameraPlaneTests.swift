import AppKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

final class SceneCameraPlaneTests: XCTestCase {
  @MainActor
  func testZoomOutRevealsPreparedContentOutsideTheAnchorViewport() async throws {
    let container = SceneCameraPlaneView<Int>()
    let viewport = SpatialPoint(x: 320, y: 256)
    container.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = container; window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    let button = NSButton(title: "Already prepared", target: nil, action: nil)
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      let point = anchor.camera.worldToScreen(.init(x: 400, y: 0), viewport: viewport)
      return AnyView(CameraBodyProbe(button: button).frame(width: 80, height: 40)
        .position(x: point.x, y: point.y).frame(width: viewport.x, height: viewport.y))
    }
    let initial = SessionPresence(mode: .board, camera: .init(scale: 1), viewport: viewport)
    container.update(presence: initial, revision: 0, content: content)
    let installed = container.contentView
    container.update(presence: .init(mode: .board, camera: .init(scale: 0.25), viewport: viewport),
      revision: 0, isCameraActive: true, content: content)
    container.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(button.convert(button.bounds, to: nil).midX, 260, accuracy: 1)
    XCTAssertFalse(button.visibleRect.isEmpty,
      "Prepared offscreen content becomes visible without waiting for archive or gesture settlement")
    XCTAssertTrue(container.contentView === installed)
    XCTAssertEqual(container.contentPublicationCount, 2, "The 4x jump rebases density once, retaining its native host")
  }

  @MainActor
  func testRasterTileKeepsItsProjectedFrameAcrossZoomAndPublication() async throws {
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024)
    let source = AgentElement(id: "zoom-tile", kind: .web,
      frame: .init(x: 0, y: 0, width: 512, height: 512), source: "tile", html: "")
    let pixels = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024,
      bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.setFillColor(NSColor.red.cgColor); pixels.fill(.init(x: 0, y: 0, width: 1024, height: 1024))
    XCTAssertTrue(resources.store(NSImage(cgImage: try XCTUnwrap(pixels.makeImage()),
      size: .init(width: 1024, height: 1024)), for: source))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    let tiles = [AgentSnapshotRasterView(), AgentSnapshotRasterView()]
    tiles.forEach { $0.updateRaster(raster) }
    defer { tiles.forEach { $0.uninstall() }; raster.release() }
    let container = SceneCameraPlaneView<Int>()
    let viewport = SpatialPoint(x: 1100, y: 780)
    container.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = container; window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      AnyView(ZStack {
        ForEach(0..<2) { index in
          let center = anchor.camera.worldToScreen(.init(x: Double(index) * 512 + 256, y: 256), viewport: viewport)
          RasterBodyProbe(view: tiles[index])
            .frame(width: 512 * anchor.camera.scale, height: 512 * anchor.camera.scale)
            .position(x: center.x, y: center.y)
        }
      }.frame(width: viewport.x, height: viewport.y))
    }
    for (index, scale) in [0.1, 0.7, 1.4, 0.2, 1.8, 0.7, 0.1, 1.4].enumerated() {
      let presence = SessionPresence(mode: .board, camera: .init(center: .init(x: 512, y: 256), scale: scale), viewport: viewport)
      container.update(presence: presence, revision: index, isCameraActive: true, content: content)
      container.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
      container.layoutSubtreeIfNeeded()
      for (number, tile) in tiles.enumerated() {
        let actual = tile.convert(tile.bounds, to: nil)
        let expected = presence.camera.worldToScreen(.init(x: Double(number) * 512, y: 0), viewport: viewport)
        XCTAssertEqual(actual.width, 512 * scale, accuracy: 1, "Native image must not impose intrinsic pixel dimensions")
        XCTAssertEqual(actual.minX, expected.x, accuracy: 1)
      }
    }
  }

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
    var installedAnchor = initial
    let world = initial.camera.screenToWorld(.init(x: 391, y: 284), viewport: initial.viewport)
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      builds += 1; installedAnchor = anchor
      let point = anchor.camera.worldToScreen(world, viewport: anchor.viewport)
      return AnyView(Color.red.frame(width: 30, height: 30)
        .position(x: point.x, y: point.y).frame(width: anchor.viewport.x, height: anchor.viewport.y))
    }
    container.update(presence: initial, revision: 1, content: content)
    let host = container.contentView
    for i in 0..<400 {
      let current = SessionPresence(mode: .board,
        camera: .init(center: .init(x: Double(i) * 0.31, y: Double(i) * -0.14), scale: 0.05 + Double(i % 170) / 100),
        viewport: initial.viewport)
      container.update(presence: current, revision: 1, isCameraActive: true, content: content)
      XCTAssertEqual(host.bounds.size, CGSize(width: 1194, height: 834))
      let local = installedAnchor.camera.worldToScreen(world, viewport: installedAnchor.viewport)
      let screen = host.convert(NSPoint(x: local.x, y: local.y), to: nil)
      let expected = current.camera.worldToScreen(world, viewport: current.viewport)
      XCTAssertEqual(screen.x, expected.x, accuracy: 0.0001)
      XCTAssertEqual(screen.y, 834 - expected.y, accuracy: 0.0001)
    }
    XCTAssertGreaterThan(builds, 1)
    XCTAssertLessThan(builds, 40, "Only bounded density changes rebase, not every sample")
    XCTAssertEqual(container.contentPublicationCount, builds)
  }
}

private struct CameraBodyProbe: NSViewRepresentable {
  let button: NSButton
  func makeNSView(context: Context) -> NSButton { button }
  func updateNSView(_ view: NSButton, context: Context) {}
}

private struct RasterBodyProbe: NSViewRepresentable {
  let view: AgentSnapshotRasterView
  func makeNSView(context: Context) -> AgentSnapshotRasterView { view }
  func updateNSView(_ view: AgentSnapshotRasterView, context: Context) {}
}
