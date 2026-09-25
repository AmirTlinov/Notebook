import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookColdPageTurnTests: XCTestCase {
  func testColdPageFollowsTheHeldContactWhenReadyAndOnlyCommitsOnLift() async throws {
    try await exerciseColdContact(cancel: false)
  }

  func testPinchCancelsAColdPageThatAlreadyStartedFollowingTheContact() async throws {
    try await exerciseColdContact(cancel: true)
  }

  private func exerciseColdContact(cancel: Bool) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController()
    var readiness: [Int: PageTurnReadiness] = [:], commits: [Int] = []
    controller.update(ownerID: UUID(), sequenceRevision: "cold-held", pageCount: 2, selectedIndex: 0,
      navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        readiness[index] = ready; if index == 0 { ready(true) }
        return AnyView(index == 0 ? Color.blue : Color.red)
      }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(60))
    let native = controller.sheetController
    let admission = try XCTUnwrap(native.view.gestureRecognizers?.compactMap { $0 as? PageTurnAdmissionRecognizer }.first)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let owner = curl.onFrameResolved
    var progresses: [Double] = []
    curl.onFrameResolved = { image, progress, receipt in
      if receipt.completion.permitsProgress { progresses.append(progress) }
      owner?(image, progress, receipt)
    }
    let touch = ColdTouch(); touch.point = .init(x: 500, y: 300)
    admission.touchesBegan([touch], with: UIEvent())
    touch.point.x = 200; admission.touchesMoved([touch], with: UIEvent())
    XCTAssertEqual(admission.state, .began)
    XCTAssertTrue(progresses.isEmpty)
    try XCTUnwrap(readiness[1])(true)
    let limit = ContinuousClock.now + .seconds(2)
    while !progresses.contains(where: { $0 > 0 && $0 < 1 }), ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(progresses.contains { $0 > 0 && $0 < 1 }, "Ready paper must follow the stationary held contact before lift")
    XCTAssertTrue(commits.isEmpty); XCTAssertEqual(controller.displayedIndex, 0)
    if cancel {
      let second = ColdTouch(); second.point = .init(x: 250, y: 300)
      admission.touchesBegan([second], with: UIEvent())
      second.point.x = 650; admission.touchesMoved([second], with: UIEvent())
    }
    admission.touchesEnded([touch], with: UIEvent())
    let finish = ContinuousClock.now + .seconds(2)
    while curl.frameLease != nil, ContinuousClock.now < finish { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertNil(curl.frameLease)
    XCTAssertEqual(commits, cancel ? [] : [1])
    XCTAssertEqual(controller.displayedIndex, cancel ? 0 : 1)
  }
}

private final class ColdTouch: UITouch {
  var point = CGPoint.zero
  override func location(in view: UIView?) -> CGPoint { point }
  override var timestamp: TimeInterval { 1 }
}
