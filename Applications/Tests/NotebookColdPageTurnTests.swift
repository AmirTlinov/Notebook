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

  func testReleasedSwipeDuringAnEarlierLandingStillTurnsTheNextSheet() async throws {
    try await exerciseOverlappingContact(direction: 1, releaseEarly: true)
  }

  func testHeldSwipeDuringAnEarlierLandingStartsWithoutAnotherMove() async throws {
    try await exerciseOverlappingContact(direction: 1, releaseEarly: false)
  }

  func testReverseSwipeDuringAnEarlierLandingKeepsItsDirection() async throws {
    try await exerciseOverlappingContact(direction: -1, releaseEarly: true)
  }

  func testOverlappingGestureKeepsTheInstalledPreparationIdentity() async throws {
    try await exerciseOverlappingContact(direction: 1, releaseEarly: true, startsWithGesture: true)
  }

  func testColdAndBusyFlicksUseTheSameLiftDecisionAsWarmPaper() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    // A short flick, stopped short drag, long drag with a reverse flick, and
    // stopped long drag. Readiness must not change their accept/cancel rule.
    let cases: [(samples: [(Double, CGFloat)], accepted: Bool)] = [
      ([(0, 0), (0.016, 16), (0.032, 24)], true),
      ([(0, 0), (0.016, 24), (0.15, 24)], false),
      ([(0, 0), (0.2, 100), (0.25, 60), (0.26, 60)], false),
      ([(0, 0), (0.2, 60), (0.4, 60)], true)
    ]
    for direction in [1, -1] {
      for scenario in cases {
        let admission = PageTurnAdmissionRecognizer(); host.view.addGestureRecognizer(admission)
        defer { host.view.removeGestureRecognizer(admission) }
        admission.prepareDirection = { XCTAssertEqual($0, direction); return false }
        var accepted: Bool?
        admission.finishColdSwipe = { accepted = $0 }
        let touch = ColdTouch(); touch.point = .init(x: 500, y: 300)
        admission.touchesBegan([touch], with: UIEvent())
        for (index, sample) in scenario.samples.dropFirst().enumerated() {
          touch.time = 1 + sample.0; touch.point.x = 500 - CGFloat(direction) * sample.1
          if index == scenario.samples.count - 2 { admission.touchesEnded([touch], with: UIEvent()) }
          else { admission.touchesMoved([touch], with: UIEvent()) }
        }
        XCTAssertEqual(accepted, scenario.accepted)
      }
    }
  }

  func testRepeatedReleasedColdSwipesKeepEveryAcceptedStep() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController()
    var readiness: [Int: PageTurnReadiness] = [:], commits: [Int] = []
    controller.update(ownerID: UUID(), sequenceRevision: "cold-series", pageCount: 5, selectedIndex: 0,
      navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in
        readiness[index] = ready; if index == 0 { ready(true) }
        return AnyView(Color.white.overlay(Text("Leaf \(index)")))
      }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(60))
    let admission = try XCTUnwrap(controller.sheetController.view.gestureRecognizers?.compactMap { $0 as? PageTurnAdmissionRecognizer }.first)
    for _ in 0..<3 {
      let touch = ColdTouch(); touch.point = .init(x: 500, y: 300)
      admission.touchesBegan([touch], with: UIEvent())
      touch.point.x = 200; admission.touchesMoved([touch], with: UIEvent())
      XCTAssertEqual(admission.state, .began)
      admission.touchesEnded([touch], with: UIEvent())
      try await Task.sleep(for: .milliseconds(120))
    }
    XCTAssertTrue(commits.isEmpty)
    try XCTUnwrap(readiness[3], "Three accepted cold swipes must demand page 3, not keep retrying page 1")(true)
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.displayedIndex != 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(commits, [3])
  }

  private func exerciseOverlappingContact(direction: Int, releaseEarly: Bool, startsWithGesture: Bool = false) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), notebook = UUID()
    var commits: [Int] = []
    var activity: PageTurnActivity?
    var installed: [PageTurnActivity.PreparationDemand?] = []
    controller.update(ownerID: notebook, sequenceRevision: "overlapping-contact", pageCount: 5, selectedIndex: 1,
      navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
      page: { index, _, ready in activity = ready.activity; ready(true); return AnyView(Color.white.overlay(Text("Leaf \(index)"))) },
      onCommit: { index, _ in commits.append(index); installed.append(activity?.installedPreparation) },
      onTransitioningChange: { _ in }, notebookNavigation: commands)
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(60))
    let native = controller.sheetController
    let admission = try XCTUnwrap(native.view.gestureRecognizers?.compactMap { $0 as? PageTurnAdmissionRecognizer }.first)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    var bending = false, nextBending = false
    curl.onFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady, progress > 0, progress < 1 {
        bending = true
        if controller.displayedIndex == 2 { nextBending = true }
      }
      resolve?(image, progress, sequence, readiness)
    }
    if startsWithGesture {
      XCTAssertTrue(admission.prepareDirection(1))
      XCTAssertTrue(native.beginInteractiveTurn(direction: .forward))
      native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.4)
      native.endInteractiveTurn(completed: true)
    } else {
      XCTAssertTrue(commands.send(.step(1), ownerID: notebook, source: "overlapping-contact"))
    }
    let firstPreparation = try XCTUnwrap(activity?.preparationDemand)
    XCTAssertEqual(firstPreparation.pageIndex, 2)
    var deadline = ContinuousClock.now + .seconds(2)
    while !bending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(bending); XCTAssertEqual(controller.displayedIndex, 1)
    let touch = ColdTouch(); touch.point = .init(x: 500, y: 300)
    admission.touchesBegan([touch], with: UIEvent())
    touch.point.x -= CGFloat(direction) * 250
    admission.touchesMoved([touch], with: UIEvent())
    XCTAssertEqual(admission.state, .began, "A second physical swipe must not disappear while the earlier sheet lands")
    if !releaseEarly {
      deadline = ContinuousClock.now + .seconds(2)
      while !nextBending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(nextBending, "The retained stationary contact must start the next curl at landing without another move")
      XCTAssertEqual(commits, [2], "A held next sheet has not landed")
    }
    admission.touchesEnded([touch], with: UIEvent())
    deadline = ContinuousClock.now + .seconds(2)
    while commits.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(commits, [2, 2 + direction])
    XCTAssertEqual(controller.displayedIndex, 2 + direction)
    XCTAssertEqual(installed.first ?? nil, firstPreparation,
      "The landing acknowledges its captured paper, not the newer contact's preparation")
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
    let owner = curl.onFrameReady
    var progresses: [Double] = []
    curl.onFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady { progresses.append(progress) }
      owner?(image, progress, sequence, readiness)
    }
    let touch = ColdTouch(); touch.point = .init(x: 500, y: 300)
    admission.touchesBegan([touch], with: UIEvent())
    touch.point.x = 200; admission.touchesMoved([touch], with: UIEvent())
    XCTAssertEqual(admission.state, .began)
    XCTAssertTrue(progresses.isEmpty)
    let prepared = try XCTUnwrap(readiness[1]?.activity?.preparationDemand)
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
    XCTAssertEqual(readiness[1]?.activity?.installedPreparation, cancel ? nil : prepared,
      "Cancellation must clear the gesture handoff; completion must acknowledge its exact prepared paper")
  }
}

private final class ColdTouch: UITouch {
  var point = CGPoint.zero
  override func location(in view: UIView?) -> CGPoint { point }
  var time: TimeInterval = 1
  override var timestamp: TimeInterval { time }
}
