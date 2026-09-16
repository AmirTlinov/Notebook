import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookPreparationHostTests: XCTestCase {
  func testPreparationRemainsOutsideTheMainWindowAcrossResizeAndReleasesItsView() async throws {
    try await WorkspaceInkFixture.waitForForegroundWindow()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive }))
    let window = try XCTUnwrap(scene.keyWindow)
    let windows = Set(scene.windows.map(ObjectIdentifier.init))
    var preparation: NotebookPreparationHost? = try NotebookPreparationHost(windowScene: scene)
    let view = try XCTUnwrap(preparation?.view)
    let material = UIView(frame: .init(x: 0, y: 0, width: 900, height: 1400))
    material.backgroundColor = .red
    view.addSubview(material)

    for size in [CGSize(width: 900, height: 1400), .init(width: 1600, height: 900)] {
      preparation?.resize(to: size)
      window.setNeedsLayout(); window.layoutIfNeeded()
      XCTAssertTrue(view.window === window, "Metal/WebKit keep a real native window")
      XCTAssertTrue(window.isKeyWindow)
      XCTAssertEqual(Set(scene.windows.map(ObjectIdentifier.init)), windows,
        "Preparation must not create another UIWindow that iPadOS can display")
      XCTAssertFalse(view.convert(view.bounds, to: window).intersects(window.bounds))
      XCTAssertTrue(view.clipsToBounds)
      XCTAssertFalse(view.isUserInteractionEnabled)
      XCTAssertTrue(view.accessibilityElementsHidden)
    }

    preparation = nil
    XCTAssertNil(view.superview, "The real window cannot retain a retired preparation host")
    XCTAssertTrue(window.isKeyWindow)
  }
}
