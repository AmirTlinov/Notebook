import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class PreparedAgentElementLifetimeTests: XCTestCase {
  func testLateMountCannotAcquireResourcesAfterTheModelHasStopped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    let resources = SceneRenderResources.shared
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 64, height: 64), source: "Late mount", html: "red")
    let image = UIGraphicsImageRenderer(size: .init(width: 64, height: 64)).image { context in
      UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 64))
    }
    XCTAssertTrue(resources.store(image, for: element))
    let before = resources.rasterAdmission.pinnedBytes
    let webBefore = resources.activeWebSurfaceCount
    var ready = false
    let host = UIHostingController(rootView: PreparedAgentElementView(element: element,
      allowsInteraction: false, focus: .board(boardID: UUID(), elementID: element.id),
      onRenderReady: { ready = ready || $0 }, onState: { _ in }).environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, before)
    XCTAssertEqual(resources.activeWebSurfaceCount, webBefore)
    XCTAssertFalse(ready, "A stale SwiftUI mount cannot report a new ready presentation after shutdown")
  }

  func testUninstalledSwiftUIConfigurationsCannotPinThePreparedRaster() throws {
    let resources = SceneRenderResources.shared
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 64, height: 64), source: "Prepared red marker", html: "red")
    let image = UIGraphicsImageRenderer(size: .init(width: 64, height: 64)).image { context in
      UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 64))
    }
    XCTAssertTrue(resources.store(image, for: element))
    let before = resources.rasterAdmission.pinnedBytes
    let configurations = (0..<100).map { _ in
      PreparedAgentElementView(element: element, allowsInteraction: false,
        focus: .board(boardID: UUID(), elementID: element.id), onRenderReady: { _ in }, onState: { _ in })
    }
    withExtendedLifetime(configurations) {
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, before,
        "A cached SwiftUI value has not installed a presenter and cannot acquire its raster")
    }
  }
}
