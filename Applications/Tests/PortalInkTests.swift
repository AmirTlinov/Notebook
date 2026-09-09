import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class PortalInkTests: XCTestCase {
  @MainActor
  func testPortalCompositionPreservesTheSharedMetalPenAndEraserPixels() async throws {
    let id = UUID(), actor = UUID()
    var journal = SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: actor))
    for (tool, xs, width) in [
      (SpatialInkTool.pen, [-100.0, 0, 100], 20.0),
      (.eraser, [-20.0, 0, 20], 30.0),
    ] {
      _ = journal.append(tool: tool, spans: [SpatialInkSpan(surface: .board(id), samples: xs.enumerated().map { i, x in
        SpatialInkSample(point: .zero, worldPoint: WorldPoint(x: x, y: 0),
          timeOffset: Double(i) / 10, width: width, opacity: 1,
          force: 1, azimuth: 0, altitude: 1)
      })], actor: actor)
    }
    let size = CGSize(width: 300, height: 300), viewport = SpatialPoint(x: 300, y: 300)
    let camera = SpatialCamera(scale: 1), resources = SceneRenderResources()
    let layers = SpatialInkComposer.boardLayers(board: .board(id), journal: journal, camera: camera, viewport: viewport)
    let native = InkCanvasView(frame: .init(origin: .zero, size: size))
    native.applySpatial(.local(layers))
    XCTAssertGreaterThan(native.committedVertexCount, 0)
    XCTAssertGreaterThan(native.committedEraserVertexCount, 0)
    let expected = try XCTUnwrap(InkRasterRenderer.shared.render(layers: layers, size: size, scale: 2))
    // Passive portal ink now traverses this compositor, including its 512-pixel
    // mask chunks. Compare actual alpha pixels with the same Metal used by the
    // active canvas; no test-only portal surface remains mounted.
    let compositor = try await SceneRasterCompositor.create(size: size, scale: 2, resources: resources)
    try await compositor.drawInk(surface: .board(id), journal: journal, camera: camera,
      size: size, in: .init(origin: .zero, size: size))
    let png = try await compositor.finishPNG()
    let actual = try XCTUnwrap(UIImage(data: png)?.cgImage)
    XCTAssertEqual(actual.width, expected.width)
    XCTAssertEqual(actual.height, expected.height)
    func pixels(_ image: CGImage) throws -> [UInt8] {
      let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
      let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }
    let rendered = try pixels(actual), reference = try pixels(expected)
    let difference = zip(rendered, reference).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    XCTAssertLessThan(Double(difference) / Double(rendered.count * 255), 0.001)
    XCTAssertGreaterThan(stride(from: 3, to: rendered.count, by: 4).filter { rendered[$0] > 240 }.count, 4_000)
    XCTAssertLessThan(rendered[(300 * actual.width + 300) * 4 + 3], 5, "The later eraser clears the center")
    XCTAssertGreaterThan(rendered[(300 * actual.width + 160) * 4 + 3], 240, "Unaffected pen survives the mask composition")
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testSpatialWebRetainsItsExactRasterWhileOwnerChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let element = SpatialElement(id: UUID().uuidString, surface: .board,
      kind: .web, frame: SpatialRect(x: 0, y: 0, width: 300, height: 180),
      worldOrigin: .zero, source: "<svg>",
      html: "<svg width='300' height='180'><rect width='300' height='180' fill='#e02020'/></svg>",
      stamp: VersionStamp(counter: 0, actor: UUID()))
    let source = agentElementSnapshotSource(element)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
    defer { window.isHidden = true }
    let first = UIHostingController(rootView: SpatialElementContent(element: element)
      .frame(width: 300, height: 180).environment(model))
    window.rootViewController = first
    window.makeKeyAndVisible()
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while SceneRenderResources.shared.image(for: source) == nil, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(SceneRenderResources.shared.image(for: source))
    let ready = expectation(description: "Готовый статический источник не запускается повторно")
    ready.isInverted = true
    let observer = NotificationCenter.default.addObserver(
      forName: SceneRenderResources.didChange, object: nil, queue: .main
    ) { notification in
      if notification.object as? String == element.id { ready.fulfill() }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let next = UIHostingController(rootView: SpatialElementContent(element: element)
      .frame(width: 300, height: 180).environment(model))
    window.rootViewController = next
    next.view.layoutIfNeeded()
    // Capture synchronously: the new WebKit has not completed its navigation.
    let immediate = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 180)).image { _ in
      next.view.drawHierarchy(in: next.view.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(immediate.cgImage)
    var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    let center = (cg.height / 2 * cg.width + cg.width / 2) * 4
    XCTAssertGreaterThan(rgba[center], 180)
    XCTAssertLessThan(rgba[center + 1], 80)
    await fulfillment(of: [ready], timeout: 0.3)
  }

  @MainActor
  func testPassivePortalRendersChangedContentOnceWithoutRestartingItsScripts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var element = SpatialElement(id: UUID().uuidString, surface: .board, kind: .web,
      frame: .init(x: 0, y: 0, width: 300, height: 180), worldOrigin: .zero,
      source: "Portal state", html: "<div id='value'></div>",
      javaScript: "document.body.style.background=notebook.state.value===1?'#e02020':'#2040e0'",
      state: .object(["value": .number(1)]), stamp: .init(counter: 0, actor: UUID()))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
    defer { window.isHidden = true }
    func webCount(in view: UIView) -> Int {
      (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webCount(in: $1) }
    }
    var previousPNG: Data?
    for value in [1, 2] {
      XCTAssertTrue(element.update(state: .object(["value": .number(Double(value))]), actor: model.actorID))
      let source = agentElementSnapshotSource(element)
      XCTAssertNil(SceneRenderResources.shared.image(for: source), "Предыдущий растр не выдаётся за изменённое состояние")
      let host = UIHostingController(rootView: SpatialElementContent(element: element, commitsState: false)
        .frame(width: 300, height: 180).environment(model))
      window.rootViewController = host
      window.makeKeyAndVisible()
      let deadline = ContinuousClock.now + .seconds(5)
      while SceneRenderResources.shared.image(for: source) == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      let image = try XCTUnwrap(SceneRenderResources.shared.image(for: source))
      try await Task.sleep(for: .milliseconds(40))
      XCTAssertEqual(webCount(in: host.view), 0, "Предпросмотр освобождает WebKit после получения точного кадра")
      XCTAssertTrue(SceneRenderResources.shared.image(for: source) === image)
      let png = try XCTUnwrap(image.pngData())
      if let previousPNG { XCTAssertNotEqual(png, previousPNG, "Новое состояние меняет видимый результат") }
      previousPNG = png
    }
    await model.finishPendingPersistence()
  }
}
