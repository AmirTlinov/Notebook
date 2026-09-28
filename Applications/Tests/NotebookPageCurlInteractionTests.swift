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
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.neighbor = { _, _ in target }; native.willTurn = { _ in true }
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    var captures = 0, poses: [Double] = [], regrabbed = false, completions: [Bool] = []
    native.onFramesAcquired = { _ in captures += 1 }
    native.didTurn = { _, completed in completions.append(completed) }
    curl.onPageFrameReady = { image, progress, sequence, readiness in
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
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.willTurn = { _ in true }
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    var poses: [Double] = []
    curl.onPageFrameReady = { image, progress, sequence, readiness in
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

  func testLiveHostReadinessCycleDoesNotDiscardAnAcceptedImmutablePair() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    var captures = 0, ready = true, completed = false
    native.isSheetReadyForCapture = { $0 !== target || ready }
    native.isSheetPresented = native.isSheetReadyForCapture
    native.onFramesAcquired = { _ in
      captures += 1
      if captures == 1 {
        ready = false; native.sheetReadinessDidChange(target)
        ready = true; native.sheetReadinessDidChange(target)
      }
    }
    native.show(target, direction: .forward, animated: true) { completed = $0 }
    let deadline = ContinuousClock.now + .seconds(2)
    while !completed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(completed); XCTAssertEqual(captures, 1)
  }

  func testPresentedEndpointWaitsForTheSameLiveLandingToBecomeReadyWithoutRecapture() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    var ready = true, sawEndpoint = false, completed = false, captures = 0
    native.isSheetPresented = { $0 !== target || ready }
    native.onFramesAcquired = { _ in captures += 1 }
    curl.onPageFrameReady = { image, progress, sequence, readiness in
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
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    native.view.layoutIfNeeded()
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resources = SceneRenderResources.shared
    let submitted = curl.submittedFrameCount, reserved = resources.reservedBytes
    let acquire = native.acquireSheetFrame
    defer { native.acquireSheetFrame = acquire }
    var sourceAcquisitions = 0, targetAcquisitions = 0, pairs = 0
    var sourceReturned = false, sourceBytes = 0, reservedAtCancellation = 0
    var completions: [Bool] = [], failures: [String] = []
    weak var acquiredSource: PageTurnFrame?
    native.onFramesAcquired = { _ in pairs += 1 }
    native.onFailure = { failures.append(String(reflecting: $0)) }
    native.acquireSheetFrame = { sheet in
      if sheet === source { sourceAcquisitions += 1 }
      if sheet === target { targetAcquisitions += 1 }
      // Await the real, charged GPU composition. Cancel at the same boundary
      // where the source material is ready but the pair has not borrowed it.
      let frame = try await acquire(sheet)
      if sheet === source {
        acquiredSource = frame; sourceBytes = frame.byteCount
        reservedAtCancellation = resources.reservedBytes
        native.cancelMotion()
        sourceReturned = true
      }
      return frame
    }
    native.show(target, direction: .forward, animated: true) { completions.append($0) }
    let limit = ContinuousClock.now + .seconds(2)
    while (!sourceReturned || acquiredSource != nil), ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(sourceReturned, "The cancellation must follow a completed source GPU frame")
    XCTAssertEqual(sourceAcquisitions, 1)
    XCTAssertEqual(targetAcquisitions, 0, "A cancelled pair must not request the target material")
    XCTAssertGreaterThan(sourceBytes, 0)
    XCTAssertEqual(reservedAtCancellation, reserved + sourceBytes,
      "The awaited source allocation remains charged until the borrower returns")
    XCTAssertNil(acquiredSource, "Cancellation must release the returned immutable source frame")
    XCTAssertEqual(pairs, 0)
    XCTAssertEqual(completions, [false])
    XCTAssertTrue(failures.isEmpty, "Cancellation is not a rendering failure: \(failures)")
    XCTAssertEqual(curl.submittedFrameCount, submitted)
    XCTAssertEqual(resources.reservedBytes, reserved)
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
    try curl.preparePages(leaf: await PageTurnFrameFixture.frame(image(top: .red, bottom: .blue)),
      base: await PageTurnFrameFixture.frame(image(top: .blue, bottom: .red)), operationID: UUID())
    for progress in [0.0, 0.4, 1.0, 0.0] {
      var presented = false
      curl.onPageFrameReady = { _, shown, _, readiness in if shown == progress, readiness.isReady { presented = true } }
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
