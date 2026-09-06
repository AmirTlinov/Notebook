import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class PortalInkTests: XCTestCase {
  @MainActor
  func testPortalReplaysErasedInkThroughTheActiveMetalRenderer() async throws {
    let id = UUID()
    let actor = UUID()
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
    let size = SpatialPoint(x: 300, y: 300)
    let camera = SpatialCamera(scale: 1)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
    defer { window.isHidden = true }
    let controller = UIViewController()
    controller.view.backgroundColor = .white
    window.rootViewController = controller
    let host = UIHostingController(rootView: PortalBoardInkView(boardID: id,
      journal: journal, camera: camera, viewport: size).frame(width: 300, height: 300))
    host.view.backgroundColor = .white
    controller.addChild(host)
    controller.view.addSubview(host.view)
    host.view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
    host.didMove(toParent: controller)
    let active = InkCanvasView(frame: CGRect(x: 300, y: 0, width: 300, height: 300))
    controller.view.addSubview(active)
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    active.applySpatial(.local(SpatialInkComposer.boardLayers(board: .board(id), journal: journal,
      camera: camera, viewport: size)))
    let portal = try XCTUnwrap(canvas(in: host.view))
    let ready = expectation(description: "Оба Metal-кадра завершены")
    ready.expectedFulfillmentCount = 2
    var seenPortal = false
    var seenActive = false
    portal.onRenderReadinessChange = { value in
      if value && !seenPortal { seenPortal = true; ready.fulfill() }
    }
    active.onRenderReadinessChange = { value in
      if value && !seenActive { seenActive = true; ready.fulfill() }
    }
    await fulfillment(of: [ready], timeout: 4)
    XCTAssertEqual(portal.committedVertexCount, active.committedVertexCount)
    XCTAssertEqual(portal.committedEraserVertexCount, active.committedEraserVertexCount)
    XCTAssertGreaterThan(portal.committedEraserVertexCount, 0)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300), format: format).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let cgImage = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: 600 * 300 * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 600, height: 300,
        bitsPerComponent: 8, bytesPerRow: 600 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 600, height: 300))
    }
    var difference = 0
    var dark = 0
    for y in 0..<300 {
      for x in 0..<300 {
        let left = (y * 600 + x) * 4
        let right = (y * 600 + x + 300) * 4
        for c in 0..<3 { difference += abs(Int(pixels[left + c]) - Int(pixels[right + c])) }
        if pixels[left] < 128 { dark += 1 }
      }
    }
    XCTAssertGreaterThan(dark, 1_000)
    XCTAssertLessThan(Double(difference) / Double(300 * 300 * 3 * 255), 0.001)
  }

  @MainActor
  func testSpatialWebRetainsItsExactRasterWhileOwnerChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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

  @MainActor
  private func canvas(in view: UIView) -> InkCanvasView? {
    if let view = view as? InkCanvasView { return view }
    return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
  }
}
