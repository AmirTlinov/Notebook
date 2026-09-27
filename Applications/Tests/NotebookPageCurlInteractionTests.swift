import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookPageCurlInteractionTests: XCTestCase {
  func testSettlementTracksVelocityStrokeDurationAndCadenceWithoutAMinimum() {
    func duration(_ distance: Double, _ velocity: Double = 0, stroke: Double = 0,
      input: Double = .infinity, cadence: Double = .infinity) -> Double {
      IPadSheetCurlController.settlementDuration(distance: distance, velocity: velocity,
        strokeSpeed: stroke, inputDuration: input, cadence: cadence)
    }
    XCTAssertEqual(duration(0), 0)
    XCTAssertEqual(duration(0.8, 100), 0.016, accuracy: 0.000001)
    XCTAssertEqual(duration(-0.8, -100), 0.016, accuracy: 0.000001)
    XCTAssertEqual(duration(0.8, input: 0.025), 0.025)
    XCTAssertEqual(duration(0.8, cadence: 0.008), 0.008)
    XCTAssertEqual(duration(0.8, stroke: 80), 0.02, accuracy: 0.000001)
    XCTAssertEqual(duration(0.8, -100), 0.32, "Opposite velocity must not accelerate away from the destination")
  }

  func testRegrabPreservesTheVisiblePoseAndReusesThePair() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.neighbor = { _, _ in target }; native.willTurn = { _ in true }
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    var captures = 0, poses: [Double] = [], regrabbed = false, completions: [Bool] = []
    native.onCaptureMeasured = { _ in captures += 1 }
    native.didTurn = { _, completed in completions.append(completed) }
    curl.onFrameReady = { image, progress, sequence, readiness in
      resolve?(image, progress, sequence, readiness)
      guard readiness.isReady else { return }
      poses.append(progress)
      if !regrabbed, progress > 0.25, progress < 0.8 {
        regrabbed = native.grabSettlement(direction: .reverse)
        native.updateInteractiveTurn(translation: 0)
      }
    }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward))
    native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.3)
    native.endInteractiveTurn(completed: true)
    var deadline = ContinuousClock.now + .seconds(2)
    while !regrabbed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(regrabbed)
    try await Task.sleep(for: .milliseconds(40)) // Drain frames already submitted before the grab.
    let held = try XCTUnwrap(poses.last), count = curl.submittedFrameCount
    native.updateInteractiveTurn(translation: 0)
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(curl.submittedFrameCount, count, "A stationary regrab is not a new frame or timer")
    XCTAssertEqual(poses.last, held)
    XCTAssertEqual(captures, 1, "Regrab cannot capture or upload the same pair again")
    native.updateInteractiveTurn(translation: native.view.bounds.width * 0.4)
    native.endInteractiveTurn(completed: true, velocity: 1200, travel: native.view.bounds.width * 0.4, duration: 0.05)
    deadline = .now + .seconds(2)
    while completions.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(completions, [false])
    XCTAssertTrue(native.page === source)
    XCTAssertEqual(captures, 1)
  }

  func testExpiredBurstCadenceDoesNotSnapAStationaryCancelledContact() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.willTurn = { _ in true }
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    var poses: [Double] = []
    curl.onFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady { poses.append(progress) }
      resolve?(image, progress, sequence, readiness)
    }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target))
    native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.4)
    var limit = ContinuousClock.now + .seconds(2)
    while poses.isEmpty, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(poses.last, 0.4)
    let now = CACurrentMediaTime()
    native.noteNavigationIntent(at: now-1.001); native.noteNavigationIntent(at: now-1)
    poses.removeAll()
    native.endInteractiveTurn(completed: false)
    limit = .now + .seconds(2)
    while poses.isEmpty, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertGreaterThan(try XCTUnwrap(poses.first), 0.25,
      "An expired 1 ms burst must not snap the independently held page back to its source")
  }

  func testEitherHostChangingDuringPairCaptureInvalidatesThatAttempt() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    var captures = 0, ready = true, completed = false
    native.isSheetReadyForCapture = { $0 !== target || ready }
    native.onCaptureMeasured = { _ in
      captures += 1
      if captures == 1 {
        ready = false; native.sheetReadinessDidChange(target)
        ready = true; native.sheetReadinessDidChange(target)
      }
    }
    native.show(target, direction: .forward, animated: true) { completed = $0 }
    let deadline = ContinuousClock.now + .seconds(2)
    while !completed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(completed); XCTAssertEqual(captures, 2)
  }

  func testPresentedEndpointWaitsForTheSameLiveLandingToBecomeReadyWithoutRecapture() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    var ready = true, sawEndpoint = false, completed = false, captures = 0
    native.isSheetReadyForCapture = { $0 !== target || ready }
    native.onCaptureMeasured = { _ in captures += 1 }
    curl.onFrameReady = { image, progress, sequence, readiness in
      if progress == 1, readiness.isReady, !sawEndpoint {
        sawEndpoint = true; ready = false
        native.sheetReadinessDidChange(target)
      }
      resolve?(image, progress, sequence, readiness)
    }
    native.show(target, direction: .forward, animated: true) { completed = $0 }
    let limit = ContinuousClock.now + .seconds(2)
    while !sawEndpoint, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(sawEndpoint); XCTAssertFalse(completed)
    XCTAssertTrue(native.page === source); XCTAssertFalse(curl.isHidden)
    let submitted = curl.submittedFrameCount
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(curl.submittedFrameCount, submitted, "Waiting for live material does not animate or poll")
    ready = true; native.sheetReadinessDidChange(target)
    XCTAssertTrue(completed); XCTAssertTrue(native.page === target)
    XCTAssertEqual(captures, 1, "The already displayed pair remains immutable through handoff")
    XCTAssertTrue(curl.isHidden); XCTAssertNil(curl.frameLease)
  }

  func testCancellationDuringSourceCaptureSkipsTheSecondCaptureAndReleasesItsBudget() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    let sourceView = CaptureObservedView(), targetView = CaptureObservedView()
    source.view = sourceView; target.view = targetView
    sourceView.backgroundColor = .blue; targetView.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer {
      sourceView.afterCapture = nil
      native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    native.view.layoutIfNeeded()
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let submitted = curl.submittedFrameCount, reserved = SceneRenderResources.shared.reservedBytes
    sourceView.afterCapture = { native.cancelMotion() }
    native.show(target, direction: .forward, animated: true)
    let limit = ContinuousClock.now + .seconds(2)
    while sourceView.captureCount == 0, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(sourceView.captureCount, 1)
    XCTAssertEqual(targetView.captureCount, 0, "A cancelled pair must not spend another UIKit capture")
    XCTAssertEqual(curl.submittedFrameCount, submitted)
    XCTAssertEqual(SceneRenderResources.shared.reservedBytes, reserved)
    XCTAssertTrue(native.page === source)
    XCTAssertTrue(curl.isHidden); XCTAssertNil(curl.frameLease)
  }

  func testPageShaderKeepsTextureOrientationAndExactFlatEndpoints() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let host = UIViewController(), curl = SheetCurlMetalView(frame: .zero)
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(curl); curl.frame = host.view.bounds
    defer { curl.releaseSource(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    func image(top: UIColor, bottom: UIColor) -> CGImage {
      let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
      return UIGraphicsImageRenderer(size: .init(width: 64, height: 96), format: format).image { context in
        top.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 48))
        bottom.setFill(); context.fill(.init(x: 0, y: 48, width: 64, height: 48))
      }.cgImage!
    }
    curl.permitsFrameSubmission = { true }; curl.onDisplayUpdate = { _ in }
    curl.prepareDrawable(size: .init(width: 64, height: 96))
    try curl.preparePages(leaf: image(top: .red, bottom: .blue), base: image(top: .blue, bottom: .red))
    for progress in [0.0, 0.4, 1.0, 0.0] {
      var presented = false
      curl.onFrameReady = { _, shown, _, readiness in if shown == progress, readiness.isReady { presented = true } }
      curl.updatePage(progress: progress, anchor: 0.7, tilt: 0.2,
        layout: .init(sheetSize: host.view.bounds.size, clipsToSheet: true))
      let deadline = ContinuousClock.now + .seconds(2)
      while !presented, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(presented)
      let pixels = try NotebookUXObservation.Pixels(window: window)
      if progress == 0 || progress == 1 {
        XCTAssertTrue(try pixels.matches([
          (.init(x: window.bounds.midX, y: window.bounds.height*0.25), progress == 0 ? .red : .blue),
          (.init(x: window.bounds.midX, y: window.bounds.height*0.75), progress == 0 ? .blue : .red)
        ]), "Pair upload must preserve vertical orientation and flat-page colours")
      }
      let shot = XCTAttachment(image: pixels.image); shot.name = "Analytic page \(progress)"
      shot.lifetime = .keepAlways; add(shot)
    }
  }
}

@MainActor private final class CaptureObservedView: UIView {
  var afterCapture: (() -> Void)?
  private(set) var captureCount = 0
  override func drawHierarchy(in rect: CGRect, afterScreenUpdates afterUpdates: Bool) -> Bool {
    let captured = super.drawHierarchy(in: rect, afterScreenUpdates: afterUpdates)
    captureCount += 1; afterCapture?()
    return captured
  }
}
