import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class DisplayConfirmationLifetimeTests: XCTestCase {
  func testPreparedSourceWakesAnIdleSwiftUISceneWithoutAnotherContentChange() async throws {
    let source = DisplayPreparedSource()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let previous = window.windowScene?.windows.first(where: \.isKeyWindow)
    window.rootViewController = UIHostingController(rootView: DisplayPreparedScene(source: source))
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await waitUntil("The scene reaches its idle cadence") { source.frames >= 3 }
    // Just after an idle tick, the next idle opportunity is too late. Only
    // publishing the prepared source changes; no gesture, timer or remount.
    try await Task.sleep(for: .milliseconds(20))
    let prior = source.frames, start = ContinuousClock.now
    source.revision = 1
    try await assertUX("prepared-source-wakes-idle-scene", since: start) { source.frames > prior }
  }

  func testChangedSourceWakesConfirmationButAnIdleSceneKeepsItsLowCadence() async throws {
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let previous = window.windowScene?.windows.first(where: \.isKeyWindow)
    let host = UIViewController(), clock = DisplayConfirmationView()
    host.view.addSubview(clock); window.rootViewController = host
    var count = 0, pending = false
    clock.onFrame = { count += 1; return pending }
    let start = ContinuousClock.now
    window.makeKeyAndVisible()
    defer { clock.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await assertUX("confirmation-first-opportunity", since: start) { count > 0 }
    let first = count
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertLessThanOrEqual(count - first, 3, "An unchanged scene must not poll at rendering cadence")
    pending = true
    let resumed = ContinuousClock.now, prior = count
    clock.onFrame = { count += 1; return pending } // The ordinary SwiftUI source-publication input.
    try await assertUX("confirmation-after-source-publication", since: resumed) { count >= prior + 2 }
    pending = false
  }

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

@Observable
private final class DisplayPreparedSource {
  var revision: UInt64?
  @ObservationIgnored var frames = 0
}

private struct DisplayPreparedScene: View {
  let source: DisplayPreparedSource
  var body: some View {
    NotebookDisplayConfirmation(preparedSource: source.revision) {
      source.frames += 1
      return false
    }
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
      return false
    }
  }
}
