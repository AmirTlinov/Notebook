import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookPaperGeometryTests: XCTestCase {
  func testNewSheetGeometryDoesNotInheritAnOlderLandscapePage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paper-existing-\(UUID())")
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 1194, height: 834))
    let oldID = try XCTUnwrap(store.loadIndex().selectedPageID)
    let old = try store.loadPage(oldID)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize, viewport: .init(x: 1194, y: 834))
    XCTAssertEqual(model.notebookPageSize, NotebookAppModel.defaultPageSize,
      "The provisional sheet uses its future persisted size, not the first old page")
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: itemID, expectedRoot: try XCTUnwrap(model.notebookPageRoot(itemID))), 1)
    let next = try XCTUnwrap(model.activePage)
    XCTAssertEqual(next.size, model.notebookPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try store.loadPage(next.id).size, NotebookAppModel.defaultPageSize)
    XCTAssertEqual(try store.loadPage(oldID), old, "Startup must never silently resize or delete existing human content")
  }

  func testWindowOrientationCannotChooseThePersistedPaperSize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paper-geometry-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: NotebookRootView().environment(model).frame(width: 1194, height: 834))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let deadline = ContinuousClock.now + .seconds(8)
    while model.loadState != .ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(model.loadState, .ready)
    let first = try XCTUnwrap(model.activePage)
    XCTAssertEqual(first.size, NotebookAppModel.defaultPageSize,
      "A landscape window is a viewport, not a different physical notebook sheet")
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: itemID, expectedRoot: try XCTUnwrap(model.notebookPageRoot(itemID))), 1)
    XCTAssertEqual(model.activePage?.size, NotebookAppModel.defaultPageSize,
      "Turning to a new sheet must use the same physical paper, not the startup window")
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPage(first.id).size, NotebookAppModel.defaultPageSize)
  }
}
