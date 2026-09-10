import AppKit
import SwiftUI
import XCTest

@testable import Notebook

final class PageTurnSurfaceTests: XCTestCase {
  @MainActor
  func testMacPreparesOnlyTheRequestedPageWithoutNavigationCallbacks() {
    var prepared: [Int] = []
    let surface = PageTurnSurface(
      ownerID: UUID(),
      sequenceRevision: "fixture-order",
      pageCount: 2,
      selectedIndex: 1,
      allowsTrailingPageCreation: false,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: { index, _, readiness in
        prepared.append(index)
        readiness(true)
        return AnyView(Text("Page \(index)"))
      },
      onCommit: { _, _ in XCTFail("Mac preparation cannot navigate the iPad") },
      onTransitioningChange: { _ in XCTFail("Mac has no page-turn transition") }
    )
    let host = NSHostingView(rootView: surface)
    host.frame = CGRect(x: 0, y: 0, width: 800, height: 1_000)
    host.layoutSubtreeIfNeeded()

    XCTAssertFalse(prepared.isEmpty)
    XCTAssertEqual(Set(prepared), [1])
  }
}
