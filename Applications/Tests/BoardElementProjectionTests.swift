import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class BoardElementProjectionTests: XCTestCase {
  @MainActor
  func testThinDiagramLinesSurviveFractionalMinificationInLiveAndPortalLayers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let lines = (0..<10).map { "<path d='M \(50 + $0 * 100) 50 V 450'/>" }.joined()
    let element = SpatialElement(id: UUID().uuidString, surface: .board, kind: .web,
      frame: .init(x: 0, y: 0, width: 1000, height: 500), worldOrigin: .zero,
      source: "Thin diagram lines", html: "<svg width='100%' height='100%' viewBox='0 0 1000 500'><g stroke='black' stroke-width='3.5'>\(lines)</g></svg>",
      stamp: .init(counter: 0, actor: model.actorID))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    func content(scale: Double, phase: Double, passive: Bool) -> some View {
      SpatialElementContent(element: element, commitsState: !passive)
        .frame(width: 1000, height: 500).scaleEffect(scale).offset(x: phase)
        .frame(width: 600, height: 400).background(.white).ignoresSafeArea().environment(model)
    }
    let host = UIHostingController(rootView: content(scale: 0.5, phase: 0, passive: false))
    window.rootViewController = host
    window.makeKeyAndVisible()
    let deadline = ContinuousClock.now + .seconds(5)
    while SceneRenderResources.shared.image(for: agentElementSnapshotSource(element)) == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let sourceImage = try XCTUnwrap(SceneRenderResources.shared.image(for: agentElementSnapshotSource(element)))
    let format = UIGraphicsImageRendererFormat(); format.scale = scene.screen.scale
    let sourcePixels = try XCTUnwrap(sourceImage.cgImage)
    var report = ["snapshot=\(sourceImage.size), scale=\(sourceImage.scale), pixels=\(sourcePixels.width)x\(sourcePixels.height)"]
    for passive in [false, true] {
      for scale in [0.03, 0.05, 0.08, 0.13] {
        var coverage: [Double] = []
        for phase in [0.0, 0.17, 0.33, 0.5, 0.67, 0.83] {
          host.rootView = content(scale: scale, phase: phase, passive: passive)
          try await Task.sleep(for: .milliseconds(25))
          let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
          }
          let cg = try XCTUnwrap(image.cgImage)
          var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
          try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
              bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
          }
          let y0 = Int((200 - 100 * scale) * format.scale)
          let y1 = Int((200 + 100 * scale) * format.scale)
          for line in 0..<10 {
            let x = (300 + (Double(50 + line * 100) - 500) * scale + phase) * format.scale
            let center = Int(x.rounded(.down))
            var ink = 0.0
            for y in y0..<y1 { for px in (center - 2)...(center + 2) {
              ink += 1 - Double(bytes[(y * cg.width + px) * 4]) / 255
            } }
            coverage.append(ink / Double(y1 - y0))
          }
          if phase == 0 {
            let attachment = XCTAttachment(image: image)
            attachment.name = "diagram-lines-\(passive ? "portal" : "live")-\(scale)"
            attachment.lifetime = .keepAlways; add(attachment)
          }
        }
        let expected = 3.5 * scale * format.scale
        let minimum = try XCTUnwrap(coverage.min()), maximum = try XCTUnwrap(coverage.max())
        report.append("passive=\(passive), scale=\(scale), expected=\(expected), min=\(minimum), max=\(maximum)")
        XCTAssertGreaterThan(minimum, expected * 0.4, "Тонкая линия не исчезает между пикселями: \(report.last!)")
        XCTAssertLessThan(maximum - minimum, expected * 0.4 + 0.03,
          "Сдвиг камеры на долю пикселя сохраняет вес линии: \(report.last!)")
        XCTAssertLessThan(maximum, expected * 1.25 + 0.03,
          "Видимость не достигается утолщением линии: \(report.last!)")
      }
    }
    let attachment = XCTAttachment(string: report.joined(separator: "\n"))
    attachment.name = "diagram-line-coverage"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertTrue(SceneRenderResources.shared.image(for: agentElementSnapshotSource(element)) === sourceImage,
      "Дробный зум не пересоздаёт снимок и не меняет исходник схемы")
    await model.finishPendingPersistence()
  }

  @MainActor
  func testZoomKeepsLiveBoardObjectsRigidWithoutResizingTheirWebViewports() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: -30_000, y: -30_000))
    await model.finishPendingPersistence()
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let elements = [
      element("one", boardID: boardID, origin: .init(x: -350, y: -180), width: 340, height: 260),
      element("two", boardID: boardID, origin: .init(x: 200, y: 160), width: 2_689.263, height: 3_943.43),
    ]
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    }
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let originalBoard = model.board

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    func show(_ camera: SpatialCamera) {
      model.updatePresence(.init(boardID: boardID, mode: .board, camera: camera, viewport: viewport), settled: false)
    }
    show(.init(scale: 0.4))
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    window.makeKeyAndVisible()
    let compositionDeadline = ContinuousClock.now + .seconds(8)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < compositionDeadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNotNil(model.compositionTiles.published, model.compositionTiles.failure ?? "Initial settled composition must be ready before testing a camera contact")
    func activate(_ element: SpatialElement) async throws -> WKWebView {
      model.interactiveElementFocus = .board(boardID: boardID, elementID: element.id)
      let deadline = ContinuousClock.now + .seconds(8)
      while ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
        for web in descendants(of: host.view, as: WKWebView.self) {
          if let id = try? await web.evaluateJavaScript("document.body.dataset.testID") as? String,
            id == element.id { return web }
        }
      }
      throw NSError(domain: "InteractiveSurfaceNotReady", code: 1)
    }
    for element in elements {
      let web = try await activate(element)
      // A new ResizeObserver owes one initial notification even without a resize.
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        web.callAsyncJavaScript("""
          window.resizeCount = 0;
          await new Promise(resolve => {
            new ResizeObserver(() => { resizeCount++; resolve(); }).observe(document.documentElement);
          });
          resizeCount = 0;
          return true;
          """, arguments: [:], in: nil, in: .page) { result in
          continuation.resume(with: result.map { _ in () })
        }
      }
      for scale in [0.4, 0.13, 0.27, 0.5354, 0.91, 0.38, 0.4, 0.13] {
        let camera = SpatialCamera(center: .init(x: scale * 40, y: -scale * 30), scale: scale)
        show(camera)
        try await Task.sleep(for: .milliseconds(35))
        host.view.layoutIfNeeded()
        do {
          XCTAssertNotNil(web.window, "Камера сохраняет тот же живой экземпляр предмета")
          let physical = CGSize(width: element.frame.width, height: element.frame.height)
          XCTAssertEqual(web.bounds.width, physical.width, accuracy: 0.01, "Зум меняет проекцию предмета, а не размер WebKit")
          XCTAssertEqual(web.bounds.height, physical.height, accuracy: 0.01)
          let value = try await web.evaluateJavaScript("""
            (() => { const pin = document.querySelector('circle').getBoundingClientRect();
              return {width:innerWidth,height:innerHeight,resizes:resizeCount,
                pinX:pin.x + pin.width / 2,pinY:pin.y + pin.height / 2}; })()
            """)
          let metrics = try XCTUnwrap(value as? [String: Double])
          XCTAssertEqual(metrics["width"]!, physical.width, accuracy: 1)
          XCTAssertEqual(metrics["height"]!, physical.height, accuracy: 1)
          XCTAssertEqual(metrics["resizes"], 0, "Браузер не догоняет камеру отдельной переразметкой")
          let frame = web.convert(web.bounds, to: host.view)
          let top = camera.worldToScreen(try XCTUnwrap(element.worldOrigin), viewport: viewport)
          XCTAssertEqual(frame.minX, top.x, accuracy: 1)
          XCTAssertEqual(frame.minY, top.y, accuracy: 1)
          XCTAssertEqual(frame.width, physical.width * scale, accuracy: 1)
          XCTAssertEqual(frame.height, physical.height * scale, accuracy: 1)
          let pin = web.convert(CGPoint(x: try XCTUnwrap(metrics["pinX"]), y: try XCTUnwrap(metrics["pinY"])), to: host.view)
          XCTAssertEqual(pin.x, top.x + physical.width * 0.75 * scale, accuracy: 1)
          XCTAssertEqual(pin.y, top.y + physical.height * 0.25 * scale, accuracy: 1)
        }
      }
    }
    XCTAssertEqual(model.board, originalBoard, "Зум не меняет содержание и сохранённые расстояния между предметами")
    // The next operation is a new resize contact, not another camera sample.
    // Its SQL publication and exact cohort require the preceding pinch to end.
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    await model.finishPendingPersistence()
    let proof = XCTAttachment(image: UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    })
    proof.name = "rigid-board-elements-after-reversible-zoom"; proof.lifetime = .keepAlways; add(proof)

    let reference = EditableElementReference.spatial(boardID: boardID, elementID: elements[0].id)
    let web = try await activate(elements[0])
    model.selectElement(reference)
    let resize = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
    model.updateElementManipulation(resize, translation: .init(x: 90, y: 80))
    try await Task.sleep(for: .milliseconds(35))
    XCTAssertEqual(web.bounds.size, CGSize(width: 340, height: 260), "Пробная рамка сохраняет содержание под рукой")
    model.finishElementManipulation(resize, translation: .init(x: 90, y: 80))
    let accepted = try XCTUnwrap(model.board?.elements.first { $0.id == elements[0].id })
    XCTAssertEqual(accepted.frame.width, 430, "The physical owner accepts the completed resize before persistence")
    XCTAssertEqual(accepted.frame.height, 340)
    await model.finishPendingPersistence()
    let committed = try model.store.workspaceHeader()
    let resizedDeadline = ContinuousClock.now + .seconds(3)
    var resized: [String: Double] = [:]
    repeat {
      try await Task.sleep(for: .milliseconds(30))
      let value = try await web.evaluateJavaScript("({width:innerWidth,height:innerHeight})")
      resized = try XCTUnwrap(value as? [String: Double])
    } while (resized != ["width": 430, "height": 340]
      || model.compositionTiles.published?.plan.revision != committed.cursor)
      && model.compositionTiles.failure == nil && ContinuousClock.now < resizedDeadline
    XCTAssertEqual(model.workspaceHeader?.cursor, committed.cursor, "The successful content commit must advance the render source cursor")
    let shown = model.compositionTiles.published
    XCTAssertEqual(shown?.plan.revision, committed.cursor, model.compositionTiles.failure ?? "The whole cohort must publish the resized owner")
    XCTAssertEqual(shown?.frame.index.element(id: elements[0].id, boardID: boardID)?.frame.width, 430)
    XCTAssertEqual(web.bounds.size, CGSize(width: 430, height: 340), "Завершённое изменение размера обновляет физический холст")
    XCTAssertEqual(resized, ["width": 430, "height": 340])
    _ = try await web.evaluateJavaScript("notebook.commit({count:7})")
    await model.finishPendingPersistence()
    let stateDeadline = ContinuousClock.now + .seconds(3)
    while model.board?.elements.first(where: { $0.id == elements[0].id })?.state != .object(["count": .number(7)]),
      ContinuousClock.now < stateDeadline { try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertEqual(model.board?.elements.first(where: { $0.id == elements[0].id })?.state, .object(["count": .number(7)]))
    await model.finishPendingPersistence()
  }

  private func element(_ id: String, boardID: UUID, origin: WorldPoint, width: Double, height: Double) -> SpatialElement {
    .init(id: id, surface: .board(boardID), kind: .web, frame: .init(x: 0, y: 0, width: width, height: height),
      worldOrigin: origin, source: "Projection fixture", html: """
      <svg width="100%" height="100%" viewBox="0 0 \(width) \(height)">
      <rect width="\(width)" height="\(height)" fill="#e4eff8" stroke="#185481" stroke-width="8"/>
      <circle cx="\(width * 0.75)" cy="\(height * 0.25)" r="14" fill="#bb241e"/></svg>
      """, css: "svg{display:block}", javaScript: "document.body.dataset.testID='\(id)'", stamp: .init(counter: 0, actor: UUID()))
  }

  @MainActor
  private func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: $0, as: type) }
  }
}
