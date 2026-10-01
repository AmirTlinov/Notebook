import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Observe real native curl images, independently of the run-loop latency
/// check: screenshot work must not be credited as display frames or FPS.
@MainActor final class NotebookPageMotionUXTests: XCTestCase {
  func testCommittedCurlHierarchyPublishesTheNextPoseWithoutAnOSAdmissionGate() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("This scenario requires actual OS presentation receipts")
    #endif
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    PageTurnFrameFixture.install(on: native)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    source.view.backgroundColor = .red; target.view.backgroundColor = .green
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    window.layoutIfNeeded()
    native.willTurn = { $0 === target }
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    var reveal: SheetCurlMetalView.PageUpdateTiming?, next: SheetCurlMetalView.PageUpdateTiming?
    var committed: SheetCurlMetalView.PageUpdateTiming?, firstOSDelivered: TimeInterval?
    var movedPresented = false, dropped = 0
    curl.onPageUpdateMeasured = { timing in
      if timing.phase == .beforePresent {
        if reveal == nil { reveal = timing }
        else if next == nil { next = timing }
      }
      guard timing.phase == .afterCommit, reveal != nil, committed == nil else { return }
      committed = timing
      if firstOSDelivered == nil {
        XCTAssertNil(curl.presentedPagePose, "Committing the hierarchy must not manufacture a shown pose")
      }
      // This is a new held-contact position accepted immediately after the
      // reveal's CA cut, without waiting for a presented-handler callback.
      native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.55)
    }
    curl.onPageFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady {
        if firstOSDelivered == nil { firstOSDelivered = CACurrentMediaTime() }
        if abs(progress - 0.55) < 0.001 { movedPresented = true }
      } else { dropped += 1 }
      resolve?(image, progress, sequence, readiness)
    }
    defer { curl.onPageFrameReady = resolve; curl.onPageUpdateMeasured = nil }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target))
    native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.35)
    let deadline = ContinuousClock.now + .seconds(2)
    while !movedPresented, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(movedPresented)
    let initial = try XCTUnwrap(reveal), successor = try XCTUnwrap(next), cut = try XCTUnwrap(committed)
    XCTAssertTrue(initial.presentsWithTransaction, "Reveal and its bent drawable must share the initial CA transaction")
    XCTAssertLessThan(cut.recorded, successor.recorded)
    XCTAssertFalse(successor.presentsWithTransaction, "The committed hierarchy, rather than OS receipt delivery, admits shader motion")
    XCTAssertTrue(native.containsInActiveTurn(source)); XCTAssertTrue(native.containsInActiveTurn(target))
    let osDelivery = try XCTUnwrap(firstOSDelivered)
    let report: [String: Any] = [
      "firstPublication": initial.recorded, "firstHierarchyCommit": cut.recorded,
      "nextPublication": successor.recorded, "firstOSDelivered": osDelivery,
      "nextPublishedBeforeFirstOSDelivery": successor.recorded < osDelivery,
      "nextPresentsWithTransaction": successor.presentsWithTransaction,
      "droppedDrawables": dropped,
      "scope": "Two held native positions; source CA cut and actual OS receipts; no readback during observation"
    ]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "Curl committed hierarchy before OS delivery"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testHeldCurlPublishesCommittedMotionAfterInputBeforeCA() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("This scenario requires actual OS presentation receipts")
    #endif
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    PageTurnFrameFixture.install(on: native)
    window.frame = .init(x: 0, y: 0, width: 300, height: 400)
    source.view.backgroundColor = .red; target.view.backgroundColor = .green
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    window.layoutIfNeeded()
    native.willTurn = { $0 === target }
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    var updates: [SheetCurlMetalView.PageUpdateTiming] = []
    var initialSequence: Int?, movedSequence: Int?
    var movedPresentedTime: TimeInterval?, movedReceiptRecorded: TimeInterval?
    curl.onPageUpdateMeasured = { updates.append($0) }
    curl.onPageFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady {
        if abs(progress - 0.35) < 0.001 { initialSequence = sequence }
        if abs(progress - 0.55) < 0.001 {
          movedSequence = sequence; movedPresentedTime = readiness.presentedTime
          movedReceiptRecorded = CACurrentMediaTime()
        }
      }
      resolve?(image, progress, sequence, readiness)
    }
    defer { curl.onPageFrameReady = resolve; curl.onPageUpdateMeasured = nil }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target))
    native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.35)
    let initialDeadline = ContinuousClock.now + .seconds(2)
    while initialSequence == nil, ContinuousClock.now < initialDeadline { try await Task.sleep(for: .milliseconds(2)) }
    let initial = try XCTUnwrap(initialSequence)
    native.updateInteractiveTurn(translation: -native.view.bounds.width * 0.55)
    let movedDeadline = ContinuousClock.now + .seconds(2)
    while movedSequence == nil, ContinuousClock.now < movedDeadline { try await Task.sleep(for: .milliseconds(2)) }
    let moved = try XCTUnwrap(movedSequence)
    // A discarded reveal may be followed by an asynchronously shown successor.
    // The initial hierarchy publication owns exposure; initialSequence denotes
    // the first actually shown .35 pose, which need not be that drawable.
    let reveal = try XCTUnwrap(updates.first { $0.phase == .beforePresent })
    XCTAssertTrue(reveal.presentsWithTransaction, "The initial drawable must share the owner's hierarchy exposure transaction")
    XCTAssertLessThanOrEqual(reveal.nextSequence, initial + 1,
      "The shown held pose must belong to the exposed source or its accepted successor")
    let publication = try XCTUnwrap(updates.first { $0.phase == .beforePresent && $0.nextSequence == moved + 1 })
    XCTAssertFalse(publication.presentsWithTransaction, "A held pose on the committed sheet needs only Metal publication")
    let afterInput = try XCTUnwrap(updates.first { $0.phase == .afterEvents && $0.modelTime == publication.modelTime })
    let beforeCA = try XCTUnwrap(updates.first { $0.phase == .beforeCommit && $0.modelTime == publication.modelTime })
    let afterCA = try XCTUnwrap(updates.first { $0.phase == .afterCommit && $0.modelTime == publication.modelTime })
    let phases: [[String: Any]] = try [publication, afterInput, beforeCA, afterCA].map {
      ["phase": $0.phase.rawValue, "modelTime": try XCTUnwrap($0.modelTime), "recorded": $0.recorded]
    }
    let report: [String: Any] = [
      "sequence": moved, "progress": 0.55, "phases": phases,
      "reveal": ["sequence": reveal.nextSequence - 1, "recorded": reveal.recorded,
        "presentsWithTransaction": reveal.presentsWithTransaction],
      "firstShownSequence": initial, "firstShownWasReveal": reveal.nextSequence == initial + 1,
      "publicationLeadBeforeCAMS": (beforeCA.recorded - publication.recorded) * 1000,
      "osReceipt": ["modelTime": try XCTUnwrap(publication.modelTime),
        "recorded": try XCTUnwrap(movedReceiptRecorded), "presentedTime": try XCTUnwrap(movedPresentedTime)]
    ]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "Held curl publication opportunity"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertLessThanOrEqual(publication.recorded, afterInput.recorded)
    XCTAssertLessThan(publication.recorded, beforeCA.recorded, "Accepted motion must publish before the later CA phase")
    XCTAssertTrue(native.containsInActiveTurn(source)); XCTAssertTrue(native.containsInActiveTurn(target))
  }

  func testSourceReplacementDuringBorrowKeepsTheAcceptedTurn() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for successorArrivesDuringBorrow in [false, true] {
      let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
      PageTurnFrameFixture.install(on: native)
      window.frame = .init(x: 0, y: 0, width: 300, height: 400)
      let source = UIViewController(), target = UIViewController()
      source.view.backgroundColor = .red; target.view.backgroundColor = .green
      window.rootViewController = native; window.makeKeyAndVisible()
      defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
      native.show(source, direction: .forward, animated: false); native.prepare(target)
      var ready = true, replaced = false, captures = 0, failures = 0, completion: Bool?
      native.isSheetReadyForCapture = { $0 !== source || ready }
      native.isSheetPresented = native.isSheetReadyForCapture
      native.onFailure = { _ in failures += 1 }
      native.onFramesAcquired = { _ in captures += 1 }
      native.acquireSheetFrame = { [weak native] sheet in
        if sheet === source, !replaced {
          replaced = true; ready = false
          native?.sheetReadinessDidChange(source)
          await Task.yield()
          if successorArrivesDuringBorrow { ready = true; native?.sheetReadinessDidChange(source) }
          throw PageTurnMaterialUnavailable.changed
        }
        return try await PageTurnFrameFixture.solid(sheet === source ? .red : .green,
          size: native?.view.bounds.size ?? .init(width: 300, height: 400))
      }
      native.show(target, direction: .forward, animated: true) { completion = $0 }
      let began = ContinuousClock.now
      while !replaced, ContinuousClock.now - began < .seconds(1) { await Task.yield() }
      XCTAssertTrue(replaced)
      if !successorArrivesDuringBorrow {
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(completion); XCTAssertEqual(captures, 0)
        ready = true; native.sheetReadinessDidChange(source)
      }
      while completion == nil, ContinuousClock.now - began < .seconds(2) {
        try await Task.sleep(for: .milliseconds(2))
      }
      XCTAssertEqual(failures, 0); XCTAssertEqual(completion, true)
      XCTAssertEqual(captures, 1); XCTAssertTrue(native.page === target)
    }
  }

  func testDirtyCapturedSheetWaitsForItsOwnReceiptAndCancellationDropsTheWait() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for reverse in [false, true] {
      let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
      PageTurnFrameFixture.install(on: native)
      let source = UIViewController(), target = UIViewController()
      source.view.backgroundColor = .red; target.view.backgroundColor = .green
      window.rootViewController = native; window.makeKeyAndVisible()
      defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
      native.show(source, direction: .forward, animated: false)
      native.prepare(target)
      let capturedSheet = reverse ? target : source, otherSheet = reverse ? source : target
      var ready = false, captures = 0
      native.isSheetReadyForCapture = { $0 !== capturedSheet || ready }
      native.isSheetPresented = native.isSheetReadyForCapture
      native.onFramesAcquired = { _ in captures += 1 }
      native.show(target, direction: reverse ? .reverse : .forward, animated: true)
      // Give the queued capture a chance to run. This is a negative assertion,
      // not a production debounce or evidence of the sheet's readiness.
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(captures, 0)
      native.sheetReadinessDidChange(otherSheet)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(captures, 0, "A neighbour's receipt cannot authorize this sheet")
      native.cancelMotion()
      ready = true
      native.sheetReadinessDidChange(capturedSheet)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(captures, 0, "A retired wait must not revive its curl")
      native.show(target, direction: reverse ? .reverse : .forward, animated: true)
      let deadline = ContinuousClock.now + .seconds(2)
      while captures == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(captures, 1)
    }
  }

  func testDirtySheetRetainsTheSameFingerProgressAndLiftUntilItsReceipt() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for reverse in [false, true] {
      for completed in [false, true] {
        let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
        PageTurnFrameFixture.install(on: native)
        let source = UIViewController(), target = UIViewController()
        source.view.backgroundColor = .red; target.view.backgroundColor = .green
        window.rootViewController = native; window.makeKeyAndVisible()
        defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        native.show(source, direction: .forward, animated: false)
        native.prepare(target)
        let capturedSheet = reverse ? target : source
        var ready = false, captures = 0, completions: [Bool] = []
        native.isSheetReadyForCapture = { $0 !== capturedSheet || ready }
        native.isSheetPresented = native.isSheetReadyForCapture
        native.onFramesAcquired = { _ in captures += 1 }
        native.willTurn = { $0 === target }
        native.didTurn = { from, completed in
          XCTAssertTrue(from === source); completions.append(completed)
        }
        XCTAssertTrue(native.beginInteractiveTurn(direction: reverse ? .reverse : .forward, target: target))
        native.updateInteractiveTurn(translation: native.view.bounds.width * (reverse ? 0.65 : -0.65))
        native.endInteractiveTurn(completed: completed)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(completions, completed ? [] : [false], "A cancelled cold contact releases without a future image")
        XCTAssertTrue(native.page === source)
        ready = true
        native.sheetReadinessDidChange(capturedSheet)
        native.sheetReadinessDidChange(capturedSheet)
        let deadline = ContinuousClock.now + .seconds(2)
        while completions.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(completions, [completed], "The original lift, not a new gesture, must finish")
        XCTAssertTrue(native.page === (completed ? target : source))
        XCTAssertEqual(captures, completed ? 1 : 0, "Repeated receipts cannot rebuild or revive the same motion image")
      }
    }
  }

  func testAcceptedCutSurvivesLaterSourceReadinessChange() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .red; target.view.backgroundColor = .green
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    var ready = true, captures = 0, completion: Bool?
    native.isSheetReadyForCapture = { $0 !== source || ready }
    native.isSheetPresented = native.isSheetReadyForCapture
    // A later live publication cannot revoke the pair already borrowed by the curl.
    native.onFramesAcquired = { _ in
      captures += 1
      if captures == 1 { ready = false }
    }
    native.show(target, direction: .forward, animated: true) { completion = $0 }
    let first = ContinuousClock.now + .seconds(2)
    while captures == 0, ContinuousClock.now < first { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(captures, 1)
    XCTAssertFalse(curl.isHidden, "The accepted immutable cut survives a newer live source")
    ready = true
    native.sheetReadinessDidChange(source)
    let second = ContinuousClock.now + .seconds(2)
    while completion == nil, ContinuousClock.now < second { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(completion, true); XCTAssertTrue(native.page === target)
  }

  func testAcceptedCutSurvivesNewAndRetiredReadinessPublications() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    // An accepted texture pair is immutable. New live receipts and retired
    // host callbacks cannot restart its source acquisition.
    for receipt in ["captured", "other", "retired"] {
      for reverse in [false, true] {
        let window = UIWindow(windowScene: scene), controller = IPadPageTurnController()
        window.frame = .init(x: 0, y: 0, width: 300, height: 400)
        let commands = NotebookPageNavigation(), owner = UUID()
        var selected = reverse ? 1 : 0, revision = "before"
        var readiness: [Int: PageTurnReadiness] = [:]
        func configure() {
          controller.update(ownerID: owner, sequenceRevision: revision, pageCount: 2, selectedIndex: selected,
            navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
            page: { index, _, ready in
              readiness[index] = ready; ready.installTestFrame(color: index == 0 ? .red : .green); ready(true)
              return AnyView(index == 0 ? Color.red : Color.green)
            }, onCommit: { index, _ in selected = index; configure() },
            onTransitioningChange: { _ in }, notebookNavigation: commands)
        }
        configure(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
          controller.sheetController.cancelMotion()
          window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        window.layoutIfNeeded()
        let capturedIndex = 0 // Forward source and reverse target are both page zero.
        let oldReceipt = try XCTUnwrap(readiness[capturedIndex])
        if receipt == "retired" { revision = "after"; configure() }
        let injected = try XCTUnwrap(receipt == "retired" ? oldReceipt
          : readiness[receipt == "captured" ? capturedIndex : 1])
        var captures = 0
        controller.sheetController.onFramesAcquired = { _ in
          captures += 1
          if captures == 1 { injected(false); injected(true) }
        }
        XCTAssertTrue(commands.send(.step(reverse ? -1 : 1), ownerID: owner, source: revision))
        let target = reverse ? 0 : 1, deadline = ContinuousClock.now + .seconds(2)
        while selected != target, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(selected, target)
        XCTAssertEqual(captures, 1, "An accepted pair keeps its cut: \(receipt), reverse=\(reverse)")
      }
    }
  }

  func testPresentedEndpointWaitsForItsLiveHostWithoutRecaptureOrIdleFrames() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for reverse in [false, true] {
      for completed in [false, true] {
        let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
        PageTurnFrameFixture.install(on: native)
        window.frame = .init(x: 0, y: 0, width: 300, height: 400)
        let source = UIViewController(), target = UIViewController()
        source.view.backgroundColor = .red; target.view.backgroundColor = .green
        window.rootViewController = native; window.makeKeyAndVisible()
        defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        native.show(source, direction: .forward, animated: false); native.prepare(target)
        window.layoutIfNeeded()
        let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
        let landing = completed ? target : source, other = completed ? source : target
        var ready = true, captures = 0, staged = 0, completions: [Bool] = []
        var bent = false, lifted = false, endpointPresented = false
        native.isSheetPresented = { $0 !== landing || ready }
        native.onStageLiveSheet = { [weak native] host in
          XCTAssertTrue(host === landing)
          XCTAssertTrue(native?.view.subviews.last === landing.view)
          XCTAssertTrue(native?.page === source)
          staged += 1
        }
        native.onFramesAcquired = { _ in captures += 1 }
        native.willTurn = { $0 === target }
        native.didTurn = { from, completed in
          XCTAssertTrue(from === source); completions.append(completed)
        }
        let resolve = curl.onPageFrameReady
        let endpoint = reverse ? (completed ? 0.0 : 1.0) : (completed ? 1.0 : 0.0)
        curl.onPageFrameReady = { image, progress, sequence, readiness in
          if readiness.isReady {
            if progress > 0, progress < 1 { bent = true }
            if lifted, progress == endpoint, !endpointPresented {
              ready = false; native.sheetReadinessDidChange(landing)
              endpointPresented = true
            }
          }
          resolve?(image, progress, sequence, readiness)
        }
        XCTAssertTrue(native.beginInteractiveTurn(direction: reverse ? .reverse : .forward, target: target))
        native.updateInteractiveTurn(translation: native.view.bounds.width * (reverse ? 0.4 : -0.4))
        let bendDeadline = ContinuousClock.now + .seconds(2)
        while !bent, ContinuousClock.now < bendDeadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(bent)
        lifted = true; native.endInteractiveTurn(completed: completed)
        let endDeadline = ContinuousClock.now + .seconds(2)
        while !endpointPresented, ContinuousClock.now < endDeadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(endpointPresented)
        XCTAssertEqual(staged, 1, "The GPU-ready host must be exposed before it can earn a live OS receipt")
        XCTAssertTrue(completions.isEmpty, "A frozen endpoint cannot enable an unready live page")
        XCTAssertTrue(native.page === source)
        XCTAssertTrue(native.containsInActiveTurn(source)); XCTAssertTrue(native.containsInActiveTurn(target))
        XCTAssertFalse(curl.isHidden); XCTAssertGreaterThan(curl.pageDrawableReservedBytes, 0)
        native.sheetReadinessDidChange(other)
        XCTAssertFalse(curl.animatesContinuously)
        let submitted = curl.submittedFrameCount
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(completions.isEmpty, "The other page cannot release this landing")
        XCTAssertEqual(curl.submittedFrameCount, submitted, "Waiting for live readiness must not poll the display")
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(staged, 1, "Unrelated readiness cannot restart the live presentation")
        ready = true; native.sheetReadinessDidChange(landing)
        XCTAssertEqual(completions, [completed]); XCTAssertTrue(native.page === landing)
        XCTAssertTrue(curl.isHidden); XCTAssertTrue(try XCTUnwrap(curl.pageOutputLayer).isHidden)
        native.sheetReadinessDidChange(landing)
        XCTAssertEqual(completions, [completed]); XCTAssertEqual(captures, 1)
      }
    }
  }

  func testCapturedCurlContainsTheImmediatelyUpdatedSwiftUISheet() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for reverse in [false, true] {
      let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
      PageTurnFrameFixture.install(on: native)
      let state = ImmediateSheetColour()
      let changed = UIHostingController(rootView: ImmediateSheetView(state: state))
      let other = UIViewController(); other.view.backgroundColor = .blue
      window.rootViewController = native; window.makeKeyAndVisible()
      defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
      native.show(reverse ? other : changed, direction: .forward, animated: false)
      native.prepare(reverse ? changed : other)
      try await Task.sleep(for: .milliseconds(30))
      let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
      let resolve = curl.onPageFrameReady
      var captured: CGImage?
      curl.onPageFrameReady = { image, progress, sequence, readiness in
        if captured == nil, readiness.isReady { captured = PageTurnFrameFixture.image(image) }
        resolve?(image, progress, sequence, readiness)
      }
      // No screenshot or intervening UI cycle may flush the pending update.
      state.green = true
      native.acquireSheetFrame = { [weak native] sheet in
        try await PageTurnFrameFixture.solid(sheet === changed ? (state.green ? .green : .red) : .blue,
          size: native?.view.bounds.size ?? .init(width: 300, height: 400))
      }
      native.show(reverse ? changed : other, direction: reverse ? .reverse : .forward, animated: true)
      let limit = ContinuousClock.now + .seconds(2)
      while captured == nil, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      let cg = try XCTUnwrap(captured)
      let pixel = try XCTUnwrap(cg.cropping(to: .init(x: cg.width/2, y: cg.height/2, width: 1, height: 1)))
      var rgba = [UInt8](repeating: 0, count: 4)
      rgba.withUnsafeMutableBytes { bytes in
        CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
          .draw(pixel, in: .init(x: 0, y: 0, width: 1, height: 1))
      }
      XCTAssertGreaterThan(rgba[1], 220, "Stale captured sheet, reverse=\(reverse): \(rgba)")
      XCTAssertLessThan(rgba[0], 40, "Old red pixels must not reappear in the curl")
    }
  }

  func testInteractiveReverseDoesNotResurrectSourceAfterTheTargetAppears() async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    var selected = 0
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "interactive-reverse", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          ready.installTestFrame(color: index == 0 ? .red : .blue); ready(true)
          return AnyView(index == 0 ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 0, blue: 1))
        }, onCommit: { index, _ in selected = index; configure() }, onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(100))
    let native = controller.sheetController
    let scripted = NotebookCurlPan()
    for turn in 0..<3 {
      XCTAssertTrue(commands.send(.step(1), ownerID: owner, source: "interactive-reverse"))
      let forwardLimit = CACurrentMediaTime() + 2
      while selected != 1 && CACurrentMediaTime() < forwardLimit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(selected, 1)
      scripted.phase = .began; scripted.offset = .init(x: 20, y: 0)
      guard native.gestureRecognizerShouldBegin(scripted) else {
        return XCTFail("The prepared neighbour must admit this reverse gesture")
      }
      native.perform(NSSelectorFromString("panned:"), with: scripted)
      var sawTarget = false, returned = false, samples: [String] = []
      for frame in 0..<55 {
        if frame < 24 {
          scripted.phase = .changed
          scripted.offset = .init(x: CGFloat(frame + 1) * (turn == 1 ? 20 : 40), y: 0)
          native.perform(NSSelectorFromString("panned:"), with: scripted)
        } else if frame == 24 {
          scripted.phase = .ended; scripted.speed = .init(x: 600, y: 0)
          native.perform(NSSelectorFromString("panned:"), with: scripted)
        }
        try await Task.sleep(for: .milliseconds(8))
        let format = UIGraphicsImageRendererFormat(); format.scale = 0.25
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let cg = try XCTUnwrap(image.cgImage)
        let point = try XCTUnwrap(cg.cropping(to: .init(x: cg.width / 2, y: cg.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
          CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            .draw(point, in: .init(x: 0, y: 0, width: 1, height: 1))
        }
        let target = rgba[0] > 220 && rgba[2] < 40
        if sawTarget && !target { returned = true }
        sawTarget = sawTarget || target
        samples.append("\(frame): \(rgba), selected=\(selected)")
        let picture = XCTAttachment(image: image); picture.name = "Interactive reverse \(turn) frame \(frame)"
        picture.lifetime = .keepAlways; add(picture)
      }
      XCTAssertTrue(sawTarget)
      XCTAssertFalse(returned, "After the target reached the centre, neither old paper nor a blank frame may cover it")
      XCTAssertEqual(selected, 0)
      let note = XCTAttachment(string: samples.joined(separator: "\n")); note.name = "Interactive reverse samples \(turn)"
      note.lifetime = .keepAlways; add(note)
    }
  }

  func testFirstSmallBendCannotExposeTheOtherLeafBeforeItsCurlPixels() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    for reverse in [false, true] {
      for repetition in 0..<3 {
        let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
        PageTurnFrameFixture.install(on: native)
        source.view.backgroundColor = .blue; target.view.backgroundColor = .red
        window.rootViewController = native; window.makeKeyAndVisible()
        native.show(source, direction: .forward, animated: false); native.prepare(target)
        native.willTurn = { $0 === target }
        try await Task.sleep(for: .milliseconds(30))
        let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
        let resolve = curl.onPageFrameReady
        var resolvedProgress: Double?
        curl.onPageFrameReady = { image, progress, sequence, readiness in
          if readiness.isReady { resolvedProgress = progress }
          resolve?(image, progress, sequence, readiness)
        }
        XCTAssertTrue(native.beginInteractiveTurn(direction: reverse ? .reverse : .forward, target: target))
        let travel = 0.02
        native.updateInteractiveTurn(translation: native.view.bounds.width * CGFloat(reverse ? travel : -travel))
        // A held 2% bend leaves the centre on the blue source in both directions.
        // Red here reproduces the historical premature-target flash. This is a
        // pixel safety oracle, not a timing test or a substitute for OS receipts.
        for frame in 0..<12 {
          try await Task.sleep(for: .milliseconds(8))
          let format = UIGraphicsImageRendererFormat(); format.scale = 0.25
          var captured = false
          let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
          }
          XCTAssertTrue(captured)
          let cg = try XCTUnwrap(image.cgImage)
          let point = try XCTUnwrap(cg.cropping(to: .init(x: cg.width / 2, y: cg.height / 2, width: 1, height: 1)))
          var rgba = [UInt8](repeating: 0, count: 4)
          rgba.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
              .draw(point, in: .init(x: 0, y: 0, width: 1, height: 1))
          }
          let picture = XCTAttachment(image: image)
          picture.name = "First small bend reverse=\(reverse) repetition=\(repetition) frame=\(frame) rgba=\(rgba)"
          picture.lifetime = .keepAlways; add(picture)
          XCTAssertGreaterThan(rgba[2], 220, "The target or an empty layer appeared before the source-backed bend")
          XCTAssertLessThan(rgba[0], 40, "Premature red target: reverse=\(reverse), frame=\(frame), rgba=\(rgba)")
        }
        XCTAssertEqual(try XCTUnwrap(resolvedProgress), reverse ? 1-travel : travel)
        XCTAssertTrue(native.page === source, "A held contact cannot accept the destination")
        native.cancelMotion()
        XCTAssertTrue(native.view.subviews.last === source.view)
      }
    }
  }

  func testFirstPresentedCurlBendsTheCompletePairWithoutAFlatPrimingFrame() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("This deadline requires actual OS presentation receipts")
    #endif
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), blue = UIViewController(), red = UIViewController()
    PageTurnFrameFixture.install(on: native)
    blue.view.backgroundColor = .blue; red.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(blue, direction: .forward, animated: false); native.prepare(red)
    let size = native.view.bounds.size
    let blueFrame = try await PageTurnFrameFixture.solid(.blue, size: size)
    let redFrame = try await PageTurnFrameFixture.solid(.red, size: size)
    native.acquireSheetFrame = { $0 === blue ? blueFrame : redFrame }
    try await Task.sleep(for: .milliseconds(30))
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    defer { curl.onPageFrameReady = resolve }
    for turn in 0..<6 {
      var first: NotebookMetalFrameReadiness?, firstProgress: Double?
      var receipts: [(sequence: Int, progress: Double, readiness: NotebookMetalFrameReadiness)] = []
      var underlay: UIView?
      curl.onPageFrameReady = { image, progress, sequence, readiness in
        receipts.append((sequence, progress, readiness))
        if let shownAt = readiness.presentedTime,
          first?.presentedTime.map({ shownAt < $0 }) ?? true {
          first = readiness; firstProgress = progress
          underlay = native.view.subviews.dropLast().last
        }
        resolve?(image, progress, sequence, readiness)
      }
      let target = turn.isMultiple(of: 2) ? red : blue
      let start = CACurrentMediaTime()
      native.show(target, direction: turn.isMultiple(of: 2) ? .forward : .reverse, animated: true)
      let limit = ContinuousClock.now + .seconds(2)
      while native.page !== target, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(native.page === target)
      XCTAssertTrue(try XCTUnwrap(first).isReady)
      let progress = try XCTUnwrap(firstProgress)
      XCTAssertGreaterThan(progress, 0)
      XCTAssertLessThan(progress, 1, "A complete pair can start bending in its first presented frame")
      let shownAt = try XCTUnwrap(first?.presentedTime)
      XCTAssertGreaterThanOrEqual(shownAt, start)
      XCTAssertLessThanOrEqual(Duration.seconds(shownAt - start), NotebookUXObservation.pageFirstResponse)
      let note = XCTAttachment(string: "First visible bend=\((shownAt-start)*1000) ms; receipts=\(receipts)")
      note.name = "Complete pair presentation \(turn)"; note.lifetime = .keepAlways; add(note)
      XCTAssertTrue(underlay === (turn.isMultiple(of: 2) ? blue.view : red.view))
    }
  }

  func testInstalledPaperParksOnlyItsCompletedOutputAndRevokesOnResizeOrCancellation() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), blue = UIViewController(), red = UIViewController()
    PageTurnFrameFixture.install(on: native)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(blue, direction: .forward, animated: false); native.prepare(red)
    window.layoutIfNeeded()
    let size = native.view.bounds.size
    func backdrop(_ page: UIViewController, color: UIColor) -> PageTurnOutputParkingHost {
      let host = PageTurnOutputParkingHost(frame: page.view.bounds)
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      page.view.addSubview(host)
      let paper = UIView(frame: page.view.bounds)
      paper.backgroundColor = color; paper.isOpaque = true
      paper.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      page.view.addSubview(paper)
      return host
    }
    let blueHost = backdrop(blue, color: .blue), redHost = backdrop(red, color: .red)
    native.idleOutputHost = { $0 === blue ? blueHost : redHost }
    let blueFrame = try await PageTurnFrameFixture.solid(.blue, size: size)
    let redFrame = try await PageTurnFrameFixture.solid(.red, size: size)
    native.acquireSheetFrame = { $0 === blue ? blueFrame : redFrame }
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    defer { curl.onPageFrameReady = resolve; curl.onPageUpdateMeasured = nil }
    var retainedOutput: CAMetalLayer?, reports: [[String: Any]] = []
    for turn in 0..<6 {
      let target = turn.isMultiple(of: 2) ? red : blue
      let host = turn.isMultiple(of: 2) ? redHost : blueHost
      let endpoint = turn.isMultiple(of: 2) ? 1.0 : 0.0
      var firstTime: TimeInterval?, firstProgress: Double?, endpointTime: TimeInterval?
      var discarded: [Int] = [], output: CAMetalLayer?, completed: Bool?
      curl.onPageUpdateMeasured = { timing in
        guard timing.phase == .beforePresent, output == nil else { return }
        output = curl.pageOutputLayer
        XCTAssertTrue(output?.superlayer === curl.layer,
          "The exact scheduled frame returns the output from paper to curl before publication")
        if let retainedOutput { XCTAssertTrue(output === retainedOutput) }
      }
      curl.onPageFrameReady = { image, progress, sequence, readiness in
        if let time = readiness.presentedTime {
          if firstTime == nil || time < firstTime! { firstTime = time; firstProgress = progress }
          if progress == endpoint { endpointTime = time }
        } else { discarded.append(sequence) }
        resolve?(image, progress, sequence, readiness)
      }
      let start = CACurrentMediaTime()
      native.show(target, direction: turn.isMultiple(of: 2) ? .forward : .reverse, animated: true) { completed = $0 }
      let deadline = ContinuousClock.now + .seconds(2)
      while completed == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(completed, true); XCTAssertTrue(native.page === target)
      let shown = try XCTUnwrap(firstTime), progress = try XCTUnwrap(firstProgress), terminal = try XCTUnwrap(endpointTime)
      XCTAssertGreaterThanOrEqual(shown, start); XCTAssertGreaterThan(progress, 0); XCTAssertLessThan(progress, 1)
      XCTAssertGreaterThanOrEqual(terminal, shown)
      let current = try XCTUnwrap(output)
      XCTAssertTrue(current.superlayer === host.layer, "Only a shown endpoint can park inside the installed paper")
      XCTAssertEqual(current.frame, host.bounds)
      XCTAssertFalse(current.isHidden); XCTAssertFalse(curl.isHidden)
      XCTAssertTrue(native.view.subviews.last === target.view)
      retainedOutput = current
      reports.append(["turn": turn, "firstOSMS": (shown-start)*1000,
        "firstProgress": progress, "discardedSequences": discarded, "endpointOSMS": (terminal-start)*1000])
    }
    let retired = try XCTUnwrap(retainedOutput)
    blueHost.bounds.size.width -= 1
    XCTAssertNil(retired.superlayer, "Changed paper geometry revokes the old output immediately")
    XCTAssertNil(curl.pageOutputLayer)
    XCTAssertTrue(curl.isHidden)
    blueHost.bounds.size = size
    var completed: Bool?
    native.show(red, direction: .forward, animated: true) { completed = $0 }
    let deadline = ContinuousClock.now + .seconds(2)
    while completed == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(completed, true)
    let replacement = try XCTUnwrap(curl.pageOutputLayer)
    XCTAssertFalse(replacement === retired)
    XCTAssertTrue(replacement.superlayer === redHost.layer)
    native.cancelMotion()
    XCTAssertNil(curl.pageOutputLayer)
    XCTAssertTrue(replacement.isHidden)
    // Returning to the cancelled host cannot resurrect its obsolete callback.
    redHost.bounds.size.width -= 1
    XCTAssertNil(curl.pageOutputLayer)
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["turns": reports], options: [.sortedKeys]),
      uniformTypeIdentifier: "public.json")
    attachment.name = "Completed output parking and shown bend"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testSlowSourcePreparationCannotConsumeTheVisibleCurl() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), blue = UIViewController(), red = UIViewController()
    PageTurnFrameFixture.install(on: native)
    blue.view.backgroundColor = .blue; red.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(blue, direction: .forward, animated: false); native.prepare(red)
    try await Task.sleep(for: .milliseconds(30))
    // Deliberately make preparation longer than the animation's entire 320 ms.
    // This is a continuity regression, not a latency or performance measurement.
    native.onFramesAcquired = { _ in Thread.sleep(forTimeInterval: 0.35) }
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    defer { curl.onPageFrameReady = resolve }
    for turn in 0..<2 {
      var firstBend: Double?
      curl.onPageFrameReady = { image, progress, sequence, readiness in
        let travel = turn == 0 ? progress : 1-progress
        if readiness.isReady, travel > 0, firstBend == nil { firstBend = travel }
        resolve?(image, progress, sequence, readiness)
      }
      let target = turn == 0 ? red : blue
      native.show(target, direction: turn == 0 ? .forward : .reverse, animated: true)
      let limit = ContinuousClock.now + .seconds(2)
      while native.page !== target, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(native.page === target)
      XCTAssertLessThan(try XCTUnwrap(firstBend), 0.25,
        "Slow capture cannot spend the bend's clock offscreen and turn the page by a source-to-target jump")
    }
  }

  func testOpaqueReverseKeepsLiveSourceUntilItsPresentedEndpoint() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    PageTurnFrameFixture.install(on: native)
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.neighbor = { _, _ in target }; native.willTurn = { _ in true }
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    try await Task.sleep(for: .milliseconds(30))
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    defer { curl.onPageFrameReady = resolve }
    var shown: Double?
    curl.onPageFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady { shown = progress }
      resolve?(image, progress, sequence, readiness)
    }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .reverse))
    for progress in [0.4, 0.5, 1, 0.4, 1] {
      shown = nil
      native.updateInteractiveTurn(translation: native.view.bounds.width * progress)
      let limit = ContinuousClock.now + .seconds(2)
      while shown != 1 - progress, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(shown, 1 - progress)
      XCTAssertFalse(try XCTUnwrap(curl.pageOutputLayer).presentsWithTransaction,
        "A complete opaque pair does not require a blocking UIKit scheduling fence per frame")
      XCTAssertTrue(native.page === source, "Holding the endpoint does not accept the gesture")
      let layers = native.view.subviews
      XCTAssertTrue(layers.last === curl)
      XCTAssertTrue(layers.dropLast().last === source.view,
        "Until landing, a missing drawable must expose the source, never an unconfirmed destination")
      if progress == 1 {
        let pixels = try NotebookUXObservation.Pixels(window: window)
        XCTAssertTrue(try pixels.matches([(.init(x: window.bounds.midX, y: window.bounds.midY), .red)]),
          "The opaque curl, not a prematurely swapped live underlay, must show the reverse endpoint")
      }
    }
    native.endInteractiveTurn(completed: true)
    XCTAssertTrue(native.page === target)
    XCTAssertTrue(native.view.subviews.last === target.view)
  }

  func testInteractiveEndpointUsesItsActualPresentationBeforeOrAfterLift() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    for direction in [IPadSheetCurlController.Direction.forward, .reverse] {
      for completes in [false, true] {
        for holdsEndpoint in [false, true] {
          let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
          PageTurnFrameFixture.install(on: native)
          source.view.backgroundColor = .blue; target.view.backgroundColor = .red
          native.neighbor = { _, _ in target }; native.willTurn = { _ in true }
          var completions: [Bool] = [], endpointPresented = false
          native.didTurn = { previous, completed in
            XCTAssertTrue(previous === source); completions.append(completed)
          }
          window.rootViewController = native; window.makeKeyAndVisible()
          native.show(source, direction: direction, animated: false)
          native.prepare(target)
          try await Task.sleep(for: .milliseconds(30))
          let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
          let owner = curl.onPageFrameReady
          let endpoint = direction == .forward ? (completes ? 1.0 : 0.0) : (completes ? 0.0 : 1.0)
          curl.onPageFrameReady = { image, progress, sequence, readiness in
            if readiness.isReady, progress == endpoint { endpointPresented = true }
            owner?(image, progress, sequence, readiness)
          }
          let pan = NotebookCurlPan(), sign: CGFloat = direction == .forward ? -1 : 1
          pan.phase = .began; pan.offset.x = sign * 20
          XCTAssertTrue(native.gestureRecognizerShouldBegin(pan))
          native.perform(NSSelectorFromString("panned:"), with: pan)
          pan.phase = .changed; pan.offset.x = completes ? sign * 900 : 0
          native.perform(NSSelectorFromString("panned:"), with: pan)
          if holdsEndpoint {
            let limit = CACurrentMediaTime() + 2
            while !endpointPresented, CACurrentMediaTime() < limit { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(endpointPresented)
          }
          XCTAssertTrue(completions.isEmpty, "Presented pixels cannot commit an unreleased gesture")
          pan.phase = completes ? .ended : .cancelled
          native.perform(NSSelectorFromString("panned:"), with: pan)
          if holdsEndpoint {
            XCTAssertEqual(completions, [completes], "Lift must accept the already displayed endpoint without waiting for a duplicate frame")
          } else {
            XCTAssertFalse(endpointPresented)
            XCTAssertEqual(completions, completes ? [] : [false],
              "Only an uncaptured cancellation may finish without a new displayed frame")
          }
          let limit = CACurrentMediaTime() + 2
          while completions.isEmpty, CACurrentMediaTime() < limit { try await Task.sleep(for: .milliseconds(2)) }
          XCTAssertEqual(endpointPresented, completes || holdsEndpoint)
          XCTAssertEqual(completions, [completes])
          XCTAssertTrue(native.page === (completes ? target : source))
          pan.phase = .began; pan.offset.x = sign * 20
          XCTAssertTrue(native.gestureRecognizerShouldBegin(pan), "Completion/cancellation must release the next gesture")
          let count = curl.submittedFrameCount
          try await Task.sleep(for: .milliseconds(30))
          XCTAssertEqual(completions, [completes], "Late display callbacks cannot finish the retired gesture twice")
          XCTAssertEqual(curl.submittedFrameCount, count, "An accepted endpoint must retire its display clock")
        }
      }
    }
  }

  func testCurlConfiguresTheActualDrawableLayerBeforeItsFirstDisplayUpdate() throws {
    let curl = SheetCurlMetalView(frame: .init(x: 0, y: 0, width: 300, height: 300))
    let backing = try XCTUnwrap(curl.layer as? CAMetalLayer)
    let coverSize = backing.drawableSize
    curl.onDisplayUpdate = { _ in }
    for side in [600.0, 1200.0, 600.0] {
      let size = CGSize(width: side, height: side)
      curl.prepareDrawable(size: size)
      let layer = try XCTUnwrap(curl.pageOutputLayer)
      XCTAssertFalse(layer === backing)
      XCTAssertEqual(layer.drawableSize, size,
        "Only the page output owner configures the pool used by its clock")
      XCTAssertEqual(layer.frame, curl.bounds)
      XCTAssertEqual(layer.maximumDrawableCount, 3)
      XCTAssertTrue(layer.framebufferOnly)
      XCTAssertTrue(layer.isOpaque)
      XCTAssertEqual(backing.drawableSize, coverSize, "Page preparation cannot reconfigure the cover's MTK backing")
      XCTAssertEqual(curl.submittedFrameCount, 0, "Preparing size is not a fake presentation")
    }
    let retired = try XCTUnwrap(curl.pageOutputLayer)
    curl.releaseSource()
    XCTAssertNil(curl.pageOutputLayer)
    XCTAssertTrue(retired.isHidden, "A new operation must not reveal the old layer while its GPU fence drains")
  }

  func testCurlHasIntermediatePixelsAndDoesNotLeaveABindingShadow() async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    var selected = 0
    func configure() {
      controller.update(ownerID:owner,sequenceRevision:"motion",pageCount:3,selectedIndex:selected,
        navigationIsEnabled:true,pageIsInteractive:true,canBeginNavigation:{true},
        page:{ index,_,ready in
          ready.setFrameProvider { [weak controller] _ in
            try await PageTurnFrameFixture.artwork(index: index, size: controller?.view.bounds.size ?? .init(width: 834, height: 1194))
          }; ready(true)
          return AnyView(Color.white.overlay(alignment:.center) {
            (index == 0 ? Color.blue : Color.red).frame(width:400,height:400)
          })
        },onCommit:{ index,_ in selected=index; configure() },onTransitioningChange:{_ in},notebookNavigation:commands)
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where:\.isKeyWindow), window = UIWindow(windowScene:scene)
    window.frame = .init(x:0,y:0,width:834,height:1194)
    configure(); window.rootViewController=controller; window.makeKeyAndVisible()
    defer { window.isHidden=true; window.rootViewController=nil; previous?.makeKey() }
    try await Task.sleep(for:.milliseconds(100))
    let reservedBefore = SceneRenderResources.shared.reservedBytes
    for (turn, targetIndex) in [1, 0, 1, 0].enumerated() {
      let targetColour: NotebookUXObservation.Color = targetIndex == 0 ? .blue : .red
      let sourceColour: NotebookUXObservation.Color = targetIndex == 0 ? .red : .blue
      XCTAssertTrue(commands.send(.step(targetIndex == 0 ? -1 : 1),ownerID:owner,source:"motion"))
      var intermediate = 0, shadowWidths: [Int] = []
      for frame in 0..<7 {
        try await Task.sleep(for:.milliseconds(55))
        let pixels = try NotebookUXObservation.Pixels(window:window)
        let source = try isSettled(pixels.image, mark: sourceColour)
        let target = try isSettled(pixels.image, mark: targetColour)
        if !source && !target { intermediate += 1 }
        let attachment = XCTAttachment(image:pixels.image)
        attachment.name="Native curl \(turn), frame \(frame)"; attachment.lifetime = .keepAlways; add(attachment)
        shadowWidths.append(try shadowWidth(pixels.image))
      }
      XCTAssertGreaterThan(intermediate,0,"A source→target jump without a bending sheet is not an animation")
      XCTAssertEqual(selected,targetIndex)
      // This screenshot-heavy lane proves shape/shadow, not product latency.
      // The presentation-only lane below owns the 16.67/450 ms deadlines.
      let final = try NotebookUXObservation.Pixels(window:window)
      XCTAssertTrue(try final.matches([(.init(x:417,y:597),targetColour)]))
      XCTAssertLessThanOrEqual(try shadowWidth(final.image),4,"A finished sheet must not retain the curl's binding shadow")
      let note=XCTAttachment(string:"Turn \(turn), left-edge dark widths: \(shadowWidths)")
      note.lifetime = .keepAlways; add(note)
      XCTAssertLessThanOrEqual(shadowWidths.max() ?? 0,32,"Sheet lighting cannot become a wide dark curtain along the screen")
      let curl = try XCTUnwrap(controller.sheetController.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
      XCTAssertGreaterThan(curl.pageDrawableReservedBytes, 0)
      XCTAssertLessThanOrEqual(SceneRenderResources.shared.reservedBytes, reservedBefore + curl.pageDrawableReservedBytes,
        "Only the charged, reclaimable native drawable pool survives a completed turn")
    }
  }

  func testRapidArrowSeriesDoesNotLeaveAQueueOfFullLengthAnimations() async throws {
    try await exerciseRapidSeries(swipes: false)
  }

  func testRapidReleasedSwipesDoNotLosePagesWhileEarlierSheetsLand() async throws {
    try await exerciseRapidSeries(swipes: true)
  }

  func testRapidAlternatingArrowsKeepTheirLatestDestination() async throws {
    try await exerciseRapidSeries(swipes: false, alternating: true)
  }

  func testRapidAlternatingReleasedSwipesKeepTheirLatestDestination() async throws {
    try await exerciseRapidSeries(swipes: true, alternating: true)
  }

  private func exerciseRapidSeries(swipes: Bool, alternating: Bool = false) async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    var selected = 0, landings: [(Int, TimeInterval)] = []
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "rapid-series", pageCount: 13, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in ready.installTestFrame(); ready(true); return AnyView(Color.white.overlay(Text("Sheet \(index)"))) },
        onCommit: { index, _ in selected = index; landings.append((index, CACurrentMediaTime())); configure() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(60))
    let native = controller.sheetController
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onPageFrameReady
    var origin = CACurrentMediaTime(), phases: [String] = []
    var lastImage: ObjectIdentifier?, sawBend = false
    native.onFramesAcquired = { measurement in
      phases.append("capture beginMS=\((measurement.began-origin)*1000) durationMS=\((measurement.ended-measurement.began)*1000) pixels=\(measurement.pixels)")
    }
    curl.onPageFrameReady = { image, progress, sequence, readiness in
      if readiness.isReady {
        let identity = ObjectIdentifier(image), first = identity != lastImage
        if first { lastImage = identity; sawBend = false }
        let bend = progress > 0 && progress < 1
        if first || (bend && !sawBend) || progress == 0 || progress == 1 {
          phases.append("frame source=\(identity) sequence=\(sequence) progress=\(progress) callbackMS=\((CACurrentMediaTime()-origin)*1000) presentedMS=\(readiness.presentedTime.map { ($0-origin)*1000 } ?? -1)")
        }
        sawBend = sawBend || bend
      }
      resolve?(image, progress, sequence, readiness)
    }
    defer { native.onFramesAcquired = nil; curl.onPageFrameReady = resolve }
    for direction in [1, -1] {
      landings = []; phases = []; lastImage = nil; sawBend = false
      let steps = (alternating ? [1, 1, -1, 1, -1, 1, 1, -1, 1, 1] : Array(repeating: 1, count: 10)).map { $0 * direction }
      let target = controller.displayedIndex + steps.reduce(0, +)
      let start = CACurrentMediaTime()
      origin = start
      for (input, direction) in steps.enumerated() {
        let due = start + Double(input) * 0.12
        if due > CACurrentMediaTime() { try await Task.sleep(for: .seconds(due - CACurrentMediaTime())) }
        phases.append("input=\(input) direction=\(direction) dueMS=\((due-start)*1000) actualMS=\((CACurrentMediaTime()-start)*1000) \(controller.navigationStateDescription)")
        if swipes {
          let native = controller.sheetController
          let admission = try XCTUnwrap(native.view.gestureRecognizers?.compactMap { $0 as? PageTurnAdmissionRecognizer }.first)
          let translation = -CGFloat(direction) * native.view.bounds.width * 0.4
          if admission.prepareDirection(direction) {
            XCTAssertTrue(native.beginInteractiveTurn(direction: direction == 1 ? .forward : .reverse))
            native.updateInteractiveTurn(translation: translation)
            native.endInteractiveTurn(completed: true)
          } else {
            admission.updateColdSwipe(translation)
            admission.finishColdSwipe(true)
          }
        } else {
          XCTAssertTrue(commands.send(.step(direction), ownerID: owner, source: "rapid-series"))
        }
      }
      let lastInput = start + 9 * 0.12
      let deadline = ContinuousClock.now + .seconds(6)
      while (controller.displayedIndex != target || controller.sheetController.settlingPage != nil), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      let rows = landings.map { "leaf=\($0.0), sinceFirstInputMS=\(($0.1-start)*1000)" }.joined(separator: "\n")
      let report = XCTAttachment(string: rows + "\nlastInputMS=1080; finalDelayMS=\(((landings.last?.1 ?? .infinity)-lastInput)*1000)\n" + phases.joined(separator: "\n"))
      report.name = "rapid-\(swipes ? "swipe" : "arrow")-\(alternating ? "alternating" : "series")-\(direction)"; report.lifetime = .keepAlways; add(report)
      XCTAssertEqual(controller.displayedIndex, target, "Every contact contributes to the destination")
      XCTAssertEqual(landings.last?.0, target)
      let visited = landings.map(\.0)
      if !alternating {
        XCTAssertTrue(zip(visited, visited.dropFirst()).allSatisfy { direction == 1 ? $0 < $1 : $0 > $1 },
          "Coalescing may omit obsolete animations, never rewind or reorder the actual landings")
      }
      XCTAssertLessThanOrEqual(Duration.seconds(try XCTUnwrap(landings.last).1-lastInput), NotebookUXObservation.pageLanding,
        "Later arrows cannot wait behind seconds of already obsolete full-duration animations")
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
    }
  }

  func testTenForwardReverseTurnsMeetFirstPresentationAndLandingDeadlines() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Simulator has no OS Metal presentation receipts; GPU completion is not frame-cadence evidence")
    #endif
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    // Resident paper owns prepared immutable pixels before a command. Keep
    // the curl pipeline cold, but do not reintroduce the removed UIKit paint
    // and image upload inside this synthetic frame provider on every turn.
    var preparedFrames: [Int: PageTurnFrame] = [:]
    for index in 0..<3 {
      preparedFrames[index] = try await PageTurnFrameFixture.artwork(index: index, size: .init(width: 834, height: 1194))
    }
    var selected = 0, committedAt: TimeInterval?
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "motion-timing", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          ready.setFrameProvider { _ in try XCTUnwrap(preparedFrames[index]) }; ready(true)
          return AnyView(Color.white.overlay {
            (index == 0 ? Color.blue : Color.red).frame(width: 400, height: 400)
          })
        }, onCommit: { index, _ in selected = index; configure(); committedAt = CACurrentMediaTime() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(100)) // Mount once; never prewarm a curl.
    let refreshRate = scene.screen.maximumFramesPerSecond
    XCTAssertGreaterThan(refreshRate, 0)
    let framePeriod = 1.0 / Double(max(1, refreshRate))
    // Target the device's advertised refresh rate, not a "budget" inferred from
    // the app's already-slow frames. 0.5 ms only tolerates clock/refresh jitter;
    // it cannot excuse a lost 8.33 ms (120 Hz) or 16.67 ms (60 Hz) interval.
    let presentationTolerance = 0.0005
    for turn in 0..<10 {
      let target = turn.isMultiple(of: 2) ? 1 : 0
      let curl = try XCTUnwrap(controller.sheetController.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
      let forwardReadiness = curl.onPageFrameReady
      var frames: [(sequence: Int, progress: Double, presented: TimeInterval, delivered: TimeInterval)] = []
      var submission: [SheetCurlMetalView.FrameTiming] = []
      var pageUpdates: [SheetCurlMetalView.PageUpdateTiming] = []
      curl.onFrameMeasured = { submission.append($0) }
      curl.onPageUpdateMeasured = { pageUpdates.append($0) }
      committedAt = nil
      curl.onPageFrameReady = { image, progress, sequence, readiness in
        // Keep dropped receipts in diagnostics. They cannot acknowledge a
        // visible frame, but need not precede it in delivery order.
        let presentedAt: TimeInterval
        switch readiness {
        case .osPresentation(let time): presentedAt = time
        case .simulatorCommandCompletion: presentedAt = .nan
        }
        frames.append((sequence, progress, presentedAt, CACurrentMediaTime()))
        forwardReadiness?(image, progress, sequence, readiness)
      }
      defer {
        curl.onPageFrameReady = forwardReadiness; curl.onFrameMeasured = nil; curl.onPageUpdateMeasured = nil
      }
      let start = CACurrentMediaTime()
      XCTAssertTrue(commands.send(.step(target == 1 ? 1 : -1), ownerID: owner, source: "motion-timing"))
      let commandReturned = CACurrentMediaTime()
      while committedAt == nil, CACurrentMediaTime() - start < 1 {
        try await Task.sleep(for: .milliseconds(1))
      }
      curl.onPageFrameReady = forwardReadiness
      curl.onFrameMeasured = nil
      curl.onPageUpdateMeasured = nil
      let encoding = XCTAttachment(string: "processID=\(ProcessInfo.processInfo.processIdentifier); epochUptime=\(start)\nCommand execution=\((commandReturned-start)*1000) ms\n" + submission.map {
        "operation=\($0.operationID?.uuidString ?? "cover"); sequence=\($0.sequence); clockRequestMS=\($0.clockRequested.map { ($0-start)*1000 } ?? .nan); callbackMS=\($0.displayUpdateReceived.map { ($0-start)*1000 } ?? .nan); start=\(($0.encodingBegan-start)*1000)ms; CPU=\(($0.submitted-$0.encodingBegan)*1000)ms; GPU queue=\(($0.gpuBegan-$0.submitted)*1000)ms; GPU=\(($0.gpuEnded-$0.gpuBegan)*1000)ms; scheduledMS=\($0.scheduled.map { ($0-start)*1000 } ?? .nan); renderDeadlineMS=\($0.renderingDeadline > 0 ? ($0.renderingDeadline-start)*1000 : .nan); targetMS=\($0.targetPresentation > 0 ? ($0.targetPresentation-start)*1000 : .nan)"
      }.joined(separator: "\n"))
      encoding.name = "Curl submission timing \(turn)"; encoding.lifetime = .keepAlways; add(encoding)
      let publication = XCTAttachment(string: pageUpdates.map {
        "operation=\($0.operationID); generation=\($0.generation); phase=\($0.phase.rawValue); nextSequence=\($0.nextSequence); recordedMS=\(($0.recorded-start)*1000); modelMS=\($0.modelTime.map { ($0-start)*1000 } ?? .nan); deadlineMS=\($0.completionDeadline.map { ($0-start)*1000 } ?? .nan); estimatedOSMS=\($0.estimatedPresentation.map { ($0-start)*1000 } ?? .nan); viewHidden=\($0.viewHidden); layerHidden=\($0.layerHidden); layerOpacity=\($0.layerOpacity); attached=\($0.windowAttached); transactionPresentation=\($0.presentsWithTransaction); drawableMatchesLayer=\($0.drawableMatchesLayer.map(String.init) ?? "n/a"); immediatePresentationExpected=\($0.immediatePresentationExpected.map(String.init) ?? "n/a")"
      }.joined(separator: "\n") + "\nOS receipts:\n" + frames.map {
        "sequence=\($0.sequence); progress=\($0.progress); presentedMS=\($0.presented > 0 ? ($0.presented-start)*1000 : .nan); unpresented=\($0.presented == 0); deliveredMS=\(($0.delivered-start)*1000)"
      }.joined(separator: "\n"))
      publication.name = "Curl layer publication \(turn)"; publication.lifetime = .keepAlways; add(publication)
      XCTAssertFalse(frames.isEmpty, "No OS presentation evidence")
      XCTAssertTrue(frames.allSatisfy {
        $0.presented == 0 || ($0.presented.isFinite && $0.presented >= start && $0.presented <= $0.delivered)
      }, "Invalid or pre-command timestamps cannot stand in for displayed frames")
      // Delivery onto MainActor can be delayed or reordered. Only the OS clock
      // measures display cadence; callback delay is retained as a separate lane.
      // A zero timestamp means the drawable was not shown. Preserve it in the
      // report while measuring first response and cadence from visible frames.
      let ordered = frames.filter { $0.presented.isFinite && $0.presented >= start }
        .sorted { $0.presented < $1.presented }
      let first = try XCTUnwrap(ordered.first { $0.progress > 0 && $0.progress < 1 },
        "An unchanged initial image or a source→target jump is not visible animation feedback")
      // A scheduled successor has everything needed for this CA publication.
      // The first drawable's delayed OS callback must not park that successor.
      // Use only phases already recorded by this scenario; this adds no wait.
      for frame in submission {
        guard let scheduled = frame.scheduled,
          let eligible = pageUpdates.first(where: {
            $0.phase == .beforeCommit && $0.nextSequence == frame.sequence + 1
              && $0.recorded >= scheduled && $0.recorded < first.presented
          }) else { continue }
        XCTAssertTrue(pageUpdates.contains {
          $0.phase == .beforePresent && $0.nextSequence == frame.sequence + 1
            && $0.recorded <= eligible.recorded
        }, "An encoded successor must publish in its eligible update before the preceding OS receipt")
      }
      XCTAssertLessThanOrEqual(Duration.seconds(first.presented - start), NotebookUXObservation.pageFirstResponse)
      let landed = try XCTUnwrap(committedAt, "The requested target never completed presentation")
      XCTAssertLessThanOrEqual(Duration.seconds(landed - start), NotebookUXObservation.pageLanding)
      XCTAssertEqual(selected, target)
      var changingFrames: [TimeInterval] = [], previousProgress: Double?
      for frame in ordered where frame.progress != previousProgress {
        changingFrames.append(frame.presented); previousProgress = frame.progress
      }
      let gaps = zip(changingFrames, changingFrames.dropFirst()).map { $1 - $0 }
      XCTAssertLessThanOrEqual(try XCTUnwrap(gaps.max()), framePeriod + presentationTolerance,
        "Changing displayed frames must meet \(refreshRate) Hz; callback time and average FPS cannot hide a missed interval")
      let note = XCTAttachment(string: "Turn \(turn): first=\((first.presented-start)*1000) ms; landing=\((landed-start)*1000) ms; target=\(refreshRate) Hz; OS presentation gaps=\(gaps); callback delays=\(ordered.map { $0.delivered-$0.presented }) s; unpresented progress=\(frames.filter { $0.presented <= 0 }.map(\.progress))")
      note.name = "Command-to-presentation deadlines"; note.lifetime = .keepAlways; add(note)
    }
  }

  private func isSettled(_ image: UIImage, mark: NotebookUXObservation.Color) throws -> Bool {
    let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
    var rgba = [UInt8](repeating: 0, count: w*h*4)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,
        bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg,in:.init(x:0,y:0,width:w,height:h))
    }
    for y in stride(from: 8, to: h, by: 16) {
      for x in stride(from: 8, to: w, by: 16) {
        let offset = (y*w+x)*4
        let colour = Array(rgba[offset..<offset+4])
        if (217..<617).contains(x) && (397..<797).contains(y) {
          if !mark.matches(colour) { return false }
        } else if !colour.prefix(3).allSatisfy({ $0 >= 252 }) {
          // This fixture is pure white, not document-coloured paper. The broad
          // paper tolerance classified the curled ivory backside as settled
          // whenever its thin shadow fell between the sampled columns.
          return false
        }
      }
    }
    return true
  }

  private func shadowWidth(_ image:UIImage) throws -> Int {
    let strip = try XCTUnwrap(image.cgImage?.cropping(to:.init(x:2,y:300,width:160,height:1)))
    var rgba = [UInt8](repeating:0,count:640)
    try rgba.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:160,height:1,bitsPerComponent:8,
        bytesPerRow:640,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(strip,in:.init(x:0,y:0,width:160,height:1))
    }
    return (0..<160).filter { x in (0..<3).allSatisfy { rgba[x*4+$0] < 220 } }.count
  }
}

/// Drives the ordinary pan action, not the command-only animation path. UIKit
/// touch arbitration and capture time are deliberately not claimed as hardware
/// gesture/FPS evidence by this diagnostic.
final class NotebookCurlPan: UIPanGestureRecognizer {
  var phase: UIGestureRecognizer.State = .possible
  var offset = CGPoint.zero
  var speed = CGPoint.zero
  override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
  override func translation(in view: UIView?) -> CGPoint { offset }
  override func velocity(in view: UIView?) -> CGPoint { speed }
}

@MainActor private final class ImmediateSheetColour: ObservableObject {
  @Published var green = false
}
private struct ImmediateSheetView: View {
  @ObservedObject var state: ImmediateSheetColour
  var body: some View { (state.green ? Color(red: 0, green: 1, blue: 0) : Color(red: 1, green: 0, blue: 0)).ignoresSafeArea() }
}
