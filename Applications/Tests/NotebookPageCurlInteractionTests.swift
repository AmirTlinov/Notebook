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
    var presentedSequence = -1, grabbedPose: Double?
    native.onFramesAcquired = { _ in captures += 1 }
    native.didTurn = { _, completed in completions.append(completed) }
    curl.onPageFrameReady = { image, progress, sequence, readiness in
      resolve?(image, progress, sequence, readiness)
      guard readiness.isReady else { return }
      poses.append(progress)
      presentedSequence = max(presentedSequence, sequence)
    }
    // Observe the actual input phase after the renderer's early animation
    // encoding, with a submitted pose ahead of the most recent OS receipt.
    // Grabbing only inside onPageFrameReady misses that ownership boundary.
    let inputPhase = UIUpdateLink(view: native.view)
    inputPhase.addAction(to: .beforeEventDispatch) { _, _ in
      if !regrabbed, let visible = curl.presentedPagePose?.progress,
        visible > 0.25, visible < 0.8, curl.submittedFrameCount > presentedSequence + 1 {
        grabbedPose = visible
        regrabbed = native.grabSettlement(direction: .reverse)
        native.updateInteractiveTurn(translation: 0)
      }
    }
    inputPhase.isEnabled = true
    defer { inputPhase.isEnabled = false }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward))
    native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.3)
    native.endInteractiveTurn(completed: true)
    var deadline = ContinuousClock.now + .seconds(2)
    while !regrabbed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(regrabbed)
    try await Task.sleep(for: .milliseconds(40)) // Drain frames already submitted before the grab.
    let held = try XCTUnwrap(poses.last), count = curl.submittedFrameCount
    XCTAssertEqual(held, try XCTUnwrap(grabbedPose), accuracy: 0.000001,
      "Contact must not inherit an encoded animation pose which was never shown")
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
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let firstPool = try XCTUnwrap(curl.pageOutputLayer)
    let poolBytes = curl.pageDrawableReservedBytes
    XCTAssertGreaterThan(poolBytes, 0)
    XCTAssertTrue(firstPool.isHidden, "An idle retained pool cannot expose its old sheet")
    completed = false
    native.show(source, direction: .reverse, animated: true) { completed = $0 }
    let returnDeadline = ContinuousClock.now + .seconds(2)
    while !completed, ContinuousClock.now < returnDeadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(completed); XCTAssertTrue(native.page === source)
    XCTAssertTrue(curl.pageOutputLayer === firstPool, "An exact-size completed pair reuses the physical drawable pool")
    XCTAssertEqual(curl.pageDrawableReservedBytes, poolBytes, "Reusing a pool must not reserve a second pool")
    var prepared = false, detachedCompletions: [Bool] = []
    native.onFramesAcquired = { _ in prepared = true }
    native.show(target, direction: .forward, animated: true) { detachedCompletions.append($0) }
    let preparedDeadline = ContinuousClock.now + .seconds(2)
    while !prepared, ContinuousClock.now < preparedDeadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(prepared)
    curl.removeFromSuperview()
    XCTAssertEqual(detachedCompletions, [false], "Detaching output resolves its owning motion before discarding the accepted pair")
    XCTAssertFalse(native.containsInActiveTurn(source)); XCTAssertFalse(native.containsInActiveTurn(target))
    XCTAssertNil(curl.pageOutputLayer)
    native.view.addSubview(curl)
    completed = false
    native.show(target, direction: .forward, animated: true) { completed = $0 }
    let attachedDeadline = ContinuousClock.now + .seconds(2)
    while !completed, ContinuousClock.now < attachedDeadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(completed); XCTAssertTrue(native.page === target)
    XCTAssertEqual(detachedCompletions, [false], "Late GPU or pool receipts cannot resolve the detached operation twice")
    window.rootViewController = nil
    XCTAssertNil(curl.pageOutputLayer, "Detaching the native owner retires even an idle pool")
    XCTAssertTrue(firstPool.isHidden)
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
    XCTAssertTrue(curl.isHidden); XCTAssertTrue(try XCTUnwrap(curl.pageOutputLayer).isHidden)
  }

  func testPartialAcceptedPairRetriesOnlyMissingSheetAndCancellationDropsItsCut() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for cancelWhileWaiting in [false, true] {
      let window = UIWindow(windowScene: scene), controller = IPadPageTurnController()
      window.frame = .init(x: 0, y: 0, width: 300, height: 400)
      let commands = NotebookPageNavigation(), owner = UUID()
      var readiness: [Int: PageTurnReadiness] = [:], selected = 0
      var sourceAcquisitions = 0, targetAcquisitions = 0, pairs = 0
      var sourceAccepted = false, targetRejected = false
      var sourceAcceptedWaiter: CheckedContinuation<Void, Never>?
      var initialSourceID: UUID?, latestSourceID: UUID?, shownCuts: [UUID] = []
      weak var acceptedSource: PageTurnFrame?
      controller.update(ownerID: owner, sequenceRevision: "partial", pageCount: 2, selectedIndex: 0,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          if readiness[index] !== ready {
            readiness[index] = ready
            if index == 0 {
              ready.setFrameProvider { _ in
                sourceAcquisitions += 1
                return try await PageTurnFrameFixture.solid(.blue)
              }
            } else {
              ready.setFrameProvider { [weak ready] _ in
                targetAcquisitions += 1
                if targetAcquisitions == 1 {
                  // Fail only after the real source producer has returned its
                  // accepted cut to Operation; no timer chooses this boundary.
                  if !sourceAccepted {
                    await withCheckedContinuation { sourceAcceptedWaiter = $0 }
                  }
                  ready?(false, capturable: false, paperReady: true)
                  targetRejected = true
                  throw PageTurnMaterialUnavailable.changed
                }
                return try await PageTurnFrameFixture.solid(.red)
              }
            }
            ready(true)
          }
          return AnyView(index == 0 ? Color.blue : Color.red)
        }, onCommit: { index, _ in selected = index }, onTransitioningChange: { _ in },
        notebookNavigation: commands, pageIdentities: [0: UUID(), 1: UUID()])
      window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
      let native = controller.sheetController
      let source = try XCTUnwrap(native.page), target = try XCTUnwrap(native.neighbor(source, .forward))
      let sourceReady = try XCTUnwrap(readiness[0]), targetReady = try XCTUnwrap(readiness[1])
      let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
      let acquire = native.acquireSheetFrame, resolve = curl.onPageFrameReady
      defer {
        sourceAcceptedWaiter?.resume(); sourceAcceptedWaiter = nil
        native.cancelMotion(); native.acquireSheetFrame = acquire; curl.onPageFrameReady = resolve
        window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
      }
      native.onFramesAcquired = { _ in pairs += 1 }
      native.acquireSheetFrame = { sheet in
        let frame = try await acquire(sheet)
        if sheet === source {
          initialSourceID = initialSourceID ?? frame.id; latestSourceID = frame.id
          acceptedSource = frame; sourceAccepted = true
          sourceAcceptedWaiter?.resume(); sourceAcceptedWaiter = nil
        }
        return frame
      }
      curl.onPageFrameReady = { image, progress, sequence, receipt in
        if receipt.isReady, progress > 0, progress < 1 { shownCuts.append(image.id) }
        resolve?(image, progress, sequence, receipt)
      }
      XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target))
      native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.35)
      var limit = ContinuousClock.now + .seconds(2)
      while !targetRejected, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(targetRejected); XCTAssertEqual(sourceAcquisitions, 1); XCTAssertEqual(targetAcquisitions, 1)
      let firstCut = try XCTUnwrap(initialSourceID)
      XCTAssertNotNil(acceptedSource); XCTAssertEqual(pairs, 0)
      // The live source changes while the other sheet is missing. Acquisition
      // uses its already accepted pixels; landing still uses live readiness.
      sourceReady.setFrameProvider { _ in
        sourceAcquisitions += 1
        return try await PageTurnFrameFixture.solid(.green)
      }
      sourceReady(false, capturable: false, paperReady: true); sourceReady.materialDidChange()
      XCTAssertTrue(native.hasAcceptedSheetFrame(source)); XCTAssertFalse(native.isSheetReadyForCapture(source))
      if cancelWhileWaiting {
        native.cancelMotion()
        limit = .now + .seconds(2)
        while acceptedSource != nil, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(acceptedSource); XCTAssertFalse(native.hasAcceptedSheetFrame(source))
        XCTAssertFalse(native.containsInActiveTurn(source)); XCTAssertEqual(pairs, 0); XCTAssertEqual(selected, 0)
        XCTAssertNil(curl.pageOutputLayer)
        sourceReady(true); targetReady(true)
        XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target))
        native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.35)
      } else { targetReady(true) }
      limit = .now + .seconds(2)
      while shownCuts.isEmpty, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertFalse(shownCuts.isEmpty, "The accepted pair must earn an actual curved OS receipt")
      XCTAssertEqual(pairs, 1); XCTAssertEqual(targetAcquisitions, 2)
      XCTAssertEqual(sourceAcquisitions, cancelWhileWaiting ? 2 : 1)
      if cancelWhileWaiting { XCTAssertNotEqual(latestSourceID, firstCut) }
      else { XCTAssertEqual(latestSourceID, firstCut) }
      XCTAssertEqual(shownCuts.last, latestSourceID)
      native.endInteractiveTurn(completed: true, duration: 0)
      limit = .now + .seconds(2)
      while selected != 1, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(selected, 1)
      native.cancelMotion()
      limit = .now + .seconds(2)
      while acceptedSource != nil, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertNil(acceptedSource, "Terminal ownership releases the operation's accepted cut")
    }
  }

  func testCancellingAnAdmittedPairDrainsBothCapturesWithoutPublishing() async throws {
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
    var sourceCompletedGPU = false, sourceDrained = false, targetDrained = false
    var completions: [Bool] = [], failures: [String] = []
    weak var acquiredSource: PageTurnFrame?, acquiredTarget: PageTurnFrame?
    native.onFramesAcquired = { _ in pairs += 1 }
    native.onFailure = { failures.append(String(reflecting: $0)) }
    native.acquireSheetFrame = { sheet in
      let isSource = sheet === source
      if isSource { sourceAcquisitions += 1 } else { targetAcquisitions += 1 }
      defer {
        if isSource { sourceDrained = true } else { targetDrained = true }
      }
      // These are the real charged GPU producers. Cancelling the admitted pair
      // after source completion must drain the concurrently submitted target,
      // whether it returns its frame or observes cancellation at its fence.
      let frame = try await acquire(sheet)
      if isSource {
        acquiredSource = frame
        sourceCompletedGPU = true
        native.cancelMotion()
      } else { acquiredTarget = frame }
      return frame
    }
    native.show(target, direction: .forward, animated: true) { completions.append($0) }
    let limit = ContinuousClock.now + .seconds(2)
    while (!sourceDrained || !targetDrained || acquiredSource != nil || acquiredTarget != nil
      || resources.reservedBytes != reserved), ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(sourceCompletedGPU, "Cancellation follows the actual source GPU completion")
    XCTAssertEqual(sourceAcquisitions, 1); XCTAssertEqual(targetAcquisitions, 1)
    XCTAssertTrue(sourceDrained); XCTAssertTrue(targetDrained)
    XCTAssertNil(acquiredSource); XCTAssertNil(acquiredTarget)
    XCTAssertEqual(pairs, 0)
    XCTAssertEqual(completions, [false])
    XCTAssertTrue(failures.isEmpty, "Cancellation is not a rendering failure: \(failures)")
    XCTAssertEqual(curl.submittedFrameCount, submitted)
    XCTAssertEqual(resources.reservedBytes, reserved)
    XCTAssertTrue(native.page === source)
    XCTAssertTrue(curl.isHidden); XCTAssertNil(curl.pageOutputLayer); XCTAssertEqual(curl.pageDrawableReservedBytes, 0)
    // Cancellation submitted no curl drawable, so there is no curl OS receipt
    // to await. Finish the restored UIKit source's update before the one final
    // window readback; GPU drain alone does not commit this new window's root.
    let sourceUpdated = expectation(description: "Cancelled pair's source finished its UIKit update")
    let publication = UIUpdateLink(view: window)
    publication.addAction(to: .afterUpdateComplete) { link, _ in
      link.isEnabled = false
      sourceUpdated.fulfill()
    }
    publication.requiresContinuousUpdates = true
    publication.isEnabled = true
    defer { publication.isEnabled = false }
    await fulfillment(of: [sourceUpdated], timeout: 2)
    let pixels = try NotebookUXObservation.Pixels(window: window)
    XCTAssertTrue(try pixels.matches([(.init(x: window.bounds.midX, y: window.bounds.midY), .blue)]),
      "Drained callbacks cannot expose target pixels after cancellation")
  }

  func testCancellationAtPagePublicationDiscardsScheduledPixelsAndStopsUpdates() async throws {
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
    let reservation = resources.reservedBytes
    let previousOwners = resources.retainedPhysicalOwners
    var operationOwners = Set<ScenePhysicalOwner>()
    let beforePublication = curl.onPageFrameWillPresent
    defer { curl.onPageFrameWillPresent = beforePublication }
    var completions: [Bool] = [], submittedAtCancellation: Int?
    curl.onPageFrameWillPresent = { _ in
      submittedAtCancellation = curl.submittedFrameCount
      operationOwners = Set(resources.retainedPhysicalOwners.subtracting(previousOwners).filter {
        if case .pageCurl = $0 { return true }; return false
      })
      native.cancelMotion()
    }
    native.show(target, direction: .forward, animated: true) { completions.append($0) }
    let deadline = ContinuousClock.now + .seconds(2)
    while (completions.isEmpty || resources.reservedBytes > reservation
      || !resources.retainedPhysicalOwners.isDisjoint(with: operationOwners)),
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    let submitted = try XCTUnwrap(submittedAtCancellation,
      "Cancel after the actual GPU command is scheduled, immediately before CA publication")
    XCTAssertGreaterThan(submitted, 0)
    XCTAssertEqual(completions, [false]); XCTAssertTrue(native.page === source)
    XCTAssertTrue(curl.isHidden); XCTAssertNil(curl.pageOutputLayer); XCTAssertEqual(curl.pageDrawableReservedBytes, 0)
    XCTAssertEqual(operationOwners.count, 1, "The scheduled turn owns one physical drawable pool")
    XCTAssertTrue(resources.retainedPhysicalOwners.isDisjoint(with: operationOwners),
      "The cancelled pool's own GPU and acquisition fences must release its physical owner")
    XCTAssertLessThanOrEqual(resources.reservedBytes, reservation,
      "Cancellation cannot retain extra bytes; unrelated idle pools may also retire during the drain")
    let updated = expectation(description: "The cancelled exposure's UIKit update completes")
    let publication = UIUpdateLink(view: window)
    publication.addAction(to: .afterUpdateComplete) { link, _ in link.isEnabled = false; updated.fulfill() }
    publication.requiresContinuousUpdates = true; publication.isEnabled = true
    defer { publication.isEnabled = false }
    await fulfillment(of: [updated], timeout: 2)
    XCTAssertEqual(curl.submittedFrameCount, submitted, "Cancellation leaves no active curl update demand")
    XCTAssertEqual(completions, [false])
    let pixels = try NotebookUXObservation.Pixels(window: window)
    XCTAssertTrue(try pixels.matches([(.init(x: window.bounds.midX, y: window.bounds.midY), .blue)]),
      "A scheduled but cancelled drawable must never cover the surviving source")
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
    try await SheetCurlGPU.shared.preparePage()
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
