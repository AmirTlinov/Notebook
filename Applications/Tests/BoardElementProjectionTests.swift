import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class BoardElementProjectionTests: XCTestCase {
  @MainActor
  func testZoomKeepsLiveBoardObjectsRigidWithoutResizingTheirWebViewports() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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
    model.reloadExternalChanges()
    await model.finishPendingPersistence()
    let originalBoard = model.board

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true }
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    func show(_ camera: SpatialCamera) {
      model.updatePresence(.init(boardID: boardID, mode: .board, camera: camera, viewport: viewport), settled: false)
    }
    show(.init(scale: 0.4))
    window.makeKeyAndVisible()
    var webViews: [String: WKWebView] = [:]
    let deadline = ContinuousClock.now + .seconds(8)
    repeat {
      try await Task.sleep(for: .milliseconds(30))
      for web in descendants(of: host.view, as: WKWebView.self) {
        if let id = try? await web.evaluateJavaScript("document.body.dataset.testID") as? String { webViews[id] = web }
      }
    } while webViews.count < 2 && ContinuousClock.now < deadline
    XCTAssertEqual(webViews.count, 2)
    for web in webViews.values {
      _ = try await web.evaluateJavaScript("window.resizeCount=0; new ResizeObserver(()=>resizeCount++).observe(document.documentElement)")
    }
    try await Task.sleep(for: .milliseconds(40))
    for web in webViews.values { _ = try await web.evaluateJavaScript("resizeCount=0") }

    for scale in [0.4, 0.13, 0.27, 0.5354, 0.91, 0.38, 0.4, 0.13] {
      let camera = SpatialCamera(center: .init(x: scale * 40, y: -scale * 30), scale: scale)
      show(camera)
      try await Task.sleep(for: .milliseconds(35))
      host.view.layoutIfNeeded()
      for element in elements {
        let web = try XCTUnwrap(webViews[element.id])
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
    XCTAssertEqual(model.board, originalBoard, "Зум не меняет содержание и сохранённые расстояния между предметами")
    let proof = XCTAttachment(image: UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    })
    proof.name = "rigid-board-elements-after-reversible-zoom"; proof.lifetime = .keepAlways; add(proof)

    let reference = EditableElementReference.spatial(elementID: elements[0].id)
    let web = try XCTUnwrap(webViews[elements[0].id])
    model.selectElement(reference)
    model.updateElementResize(reference, delta: .init(x: 90, y: 80))
    try await Task.sleep(for: .milliseconds(35))
    XCTAssertEqual(web.bounds.size, CGSize(width: 340, height: 260), "Пробная рамка сохраняет содержание под рукой")
    model.finishElementResize(reference, delta: .init(x: 90, y: 80))
    await model.finishPendingPersistence()
    let resizedDeadline = ContinuousClock.now + .seconds(3)
    var resized: [String: Double] = [:]
    repeat {
      try await Task.sleep(for: .milliseconds(30))
      let value = try await web.evaluateJavaScript("({width:innerWidth,height:innerHeight})")
      resized = try XCTUnwrap(value as? [String: Double])
    } while resized != ["width": 430, "height": 340] && ContinuousClock.now < resizedDeadline
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
