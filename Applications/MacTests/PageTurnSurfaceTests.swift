import AppKit
import SwiftUI
import XCTest

@testable import Notebook

final class PageTurnSurfaceTests: XCTestCase {
  func testSlowShortTurnReturnsToTheCurrentPage() {
    XCTAssertFalse(
      PageTurnDecision.commits(progress: 0.20, velocity: 0.10)
    )
  }

  func testFastShortTurnKeepsTheTrackpadMomentum() {
    XCTAssertTrue(
      PageTurnDecision.commits(progress: 0.14, velocity: 1.10)
    )
  }

  func testReversingBeforeReleaseCancelsTheTurn() {
    XCTAssertFalse(
      PageTurnDecision.commits(progress: 0.48, velocity: -1.00)
    )
  }

  @MainActor
  func testSettledPreviewRendersThePageWithoutAnAnimationContainer() {
    let surface = PageTurnSurface(
      ownerID: UUID(),
      pageCount: 2,
      selectedIndex: 1,
      navigationIsEnabled: true,
      pageIsInteractive: true,
      canBeginNavigation: { true },
      page: { index, _, readiness in
        readiness(true)
        return AnyView(Text("Page \(index)"))
      },
      onCommit: { _ in },
      onTransitioningChange: { _ in }
    )
    .environment(\.rendersSettledPageSnapshot, true)
    let host = NSHostingView(rootView: surface)
    host.frame = CGRect(x: 0, y: 0, width: 800, height: 1_000)
    host.layoutSubtreeIfNeeded()

    XCTAssertFalse(
      containsPageTurnView(in: host),
      "Завершённый MCP-снимок должен рисовать один лист без вложенного hosting-графа"
    )
  }

  @MainActor
  private func containsPageTurnView(in view: NSView) -> Bool {
    view is MacPageTurnView
      || view.subviews.contains { containsPageTurnView(in: $0) }
  }
}
