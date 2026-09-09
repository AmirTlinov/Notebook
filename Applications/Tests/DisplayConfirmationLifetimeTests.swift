import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class DisplayConfirmationLifetimeTests: XCTestCase {
  func testDisplayClockDoesNotRetainAReleasedSwiftUIScene() async throws {
    let receipt = DisplayLifetimeReceipt()
    var host: UIViewController? = UIHostingController(rootView: DisplayLifetimeScene(receipt: receipt))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; host = nil }
    try await waitUntil("The real attached display link must call the scene") { receipt.frames > 0 }
    weak let clock = host.flatMap { findClock(in: $0.view) }
    weak let releasedHost = host
    XCTAssertNotNil(clock)

    window.isHidden = true
    window.rootViewController = nil
    host = nil
    try await waitUntil("The display clock cannot be the last owner of a closed scene") { clock == nil }
    let completed = receipt.frames
    XCTAssertNil(clock)
    XCTContext.runActivity(named: "Released display callback ownership") { activity in
      let attachment = XCTAttachment(string: "hostAlive=\(releasedHost != nil) clockAlive=\(clock != nil) callbacks=\(completed)")
      attachment.name = "display-clock-retirement"; attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
  }

  private func findClock(in view: UIView) -> DisplayConfirmationView? {
    (view as? DisplayConfirmationView) ?? view.subviews.lazy.compactMap { self.findClock(in: $0) }.first
  }

  private func waitUntil(_ failure: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), failure)
  }
}

@MainActor
private final class DisplayLifetimeReceipt {
  var frames = 0
}

private struct DisplayLifetimeScene: View {
  let receipt: DisplayLifetimeReceipt
  @State private var renderedCallbacks = 0
  var body: some View {
    NotebookDisplayConfirmation {
      renderedCallbacks += 1
      receipt.frames = renderedCallbacks
    }
  }
}
