import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class PagePresentationTests: XCTestCase {
  @MainActor
  func testOnlyMountedCurrentReadySourceCanAcknowledgePaperAndRetirementRevokesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-presentation-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    var page = PageDocument(size: .init(width: 100, height: 100), actor: UUID())
    let view = PagePresentationNativeView(), activity = PageTurnActivity()
    view.update(model: model, page: page, isCurrent: true, isVisible: true, isReady: true, activity: activity)
    XCTAssertFalse(model.pagePresentations.isPresented(page), "Preparation is not an installed surface")
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.frame = .init(x: 0, y: 0, width: 300, height: 300)
    window.rootViewController = host; window.makeKeyAndVisible()
    view.frame = .init(x: 20, y: 20, width: 100, height: 100); host.view.addSubview(view)
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    XCTAssertTrue(model.pagePresentations.isPresented(page))
    activity.update(true)
    XCTAssertFalse(model.pagePresentations.isPresented(page), "A curl owns its in-flight surface")
    activity.update(false)
    for state in [(false, true, true), (true, false, true), (true, true, false)] {
      view.update(model: model, page: page, isCurrent: state.0, isVisible: state.1, isReady: state.2, activity: activity)
      XCTAssertFalse(model.pagePresentations.isPresented(page))
    }
    view.update(model: model, page: page, isCurrent: true, isVisible: true, isReady: true, activity: activity)
    view.removeFromSuperview()
    XCTAssertFalse(model.pagePresentations.isPresented(page), "A retained detached native view is not on screen")
    host.view.addSubview(view)
    XCTAssertTrue(page.replaceElements([.init(id: "new", kind: .markdown,
      frame: .init(x: 0, y: 0, width: 100, height: 40), source: "New", html: "<p>New</p>")], actor: UUID()))
    XCTAssertFalse(model.pagePresentations.isPresented(page), "Old installed pixels cannot acknowledge a changed source")
    view.update(model: model, page: page, isCurrent: true, isVisible: true, isReady: true, activity: activity)
    XCTAssertTrue(model.pagePresentations.isPresented(page))
    view.uninstall()
    XCTAssertFalse(model.pagePresentations.isPresented(page), "UIKit retaining a retired owner cannot retain its proof")
  }
}
