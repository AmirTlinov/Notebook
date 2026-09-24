import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookTopBarTests: XCTestCase {
  func testNarrowWindowScrollsOneCompactToolbarWithoutResizingPaper() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .a4))
    let initial = try XCTUnwrap(model.presence)
    model.updatePresence(.init(boardID: initial.boardID, mode: .document, camera: initial.camera,
      viewport: initial.viewport, focusedItemID: id, openProgress: 1), settled: true)
    XCTAssertNotNil(model.activeDocument)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let previous = scene.windows.first { $0.isKeyWindow }
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    for width in [284.0, 360.0, 798.0, 1158.0] {
      let view = NotebookTopBar().environment(model)
      // This is a toolbar-sized window, not a full screen with status-bar insets.
      let host = UIHostingController(rootView: view.ignoresSafeArea())
      let size = host.sizeThatFits(in: CGSize(width: width, height: 200))
      XCTAssertLessThanOrEqual(size.width, width+0.5)
      XCTAssertLessThan(size.height, 60)
      window.frame = CGRect(origin: .zero, size: size); window.rootViewController = host; window.makeKeyAndVisible()
      host.view.frame = window.bounds; host.view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
      let attachment = XCTAttachment(image: image); attachment.name = "Unified toolbar width \(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }
}
