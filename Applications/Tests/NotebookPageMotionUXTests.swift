import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Observe real native curl images, independently of the run-loop latency
/// check: screenshot work must not be credited as display frames or FPS.
@MainActor final class NotebookPageMotionUXTests: XCTestCase {
  func testDirtyCapturedSheetWaitsForItsOwnReceiptAndCancellationDropsTheWait() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for reverse in [false, true] {
      let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
      let source = UIViewController(), target = UIViewController()
      source.view.backgroundColor = .red; target.view.backgroundColor = .green
      window.rootViewController = native; window.makeKeyAndVisible()
      defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
      native.show(source, direction: .forward, animated: false)
      native.prepare(target)
      let capturedSheet = reverse ? target : source, otherSheet = reverse ? source : target
      var ready = false, captures = 0
      native.isSheetReadyForCapture = { $0 !== capturedSheet || ready }
      native.onCaptureMeasured = { _ in captures += 1 }
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
        let source = UIViewController(), target = UIViewController()
        source.view.backgroundColor = .red; target.view.backgroundColor = .green
        window.rootViewController = native; window.makeKeyAndVisible()
        defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        native.show(source, direction: .forward, animated: false)
        native.prepare(target)
        let capturedSheet = reverse ? target : source
        var ready = false, captures = 0, completions: [Bool] = []
        native.isSheetReadyForCapture = { $0 !== capturedSheet || ready }
        native.onCaptureMeasured = { _ in captures += 1 }
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

  func testReadinessRevokedDuringCaptureDiscardsTheImageUntilItsNewReceipt() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .red; target.view.backgroundColor = .green
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    var ready = true, captures = 0, completion: Bool?
    native.isSheetReadyForCapture = { $0 !== source || ready }
    // Exercise the exact return boundary of the synchronous UIKit capture.
    // In the app its layout can revoke coverage before the image is installed.
    native.onCaptureMeasured = { _ in
      captures += 1
      if captures == 1 { ready = false }
    }
    native.show(target, direction: .forward, animated: true) { completion = $0 }
    let first = ContinuousClock.now + .seconds(2)
    while captures == 0, ContinuousClock.now < first { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(captures, 1)
    XCTAssertTrue(curl.isHidden, "A revoked image must not enter the curl")
    XCTAssertNil(completion); XCTAssertTrue(native.page === source)
    ready = true
    native.sheetReadinessDidChange(source)
    let second = ContinuousClock.now + .seconds(2)
    while completion == nil, ContinuousClock.now < second { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(captures, 2)
    XCTAssertEqual(completion, true); XCTAssertTrue(native.page === target)
  }

  func testCaptureRejectsRevokedAndRestoredReadinessFromItsExactHost() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    // A source change during capture invalidates pixels even when readiness is
    // true again on return. Another host or an old sequence cannot invalidate it.
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
              readiness[index] = ready; ready(true)
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
        controller.sheetController.onCaptureMeasured = { _ in
          captures += 1
          if captures == 1 { injected(false); injected(true) }
        }
        XCTAssertTrue(commands.send(.step(reverse ? -1 : 1), ownerID: owner, source: revision))
        let target = reverse ? 0 : 1, deadline = ContinuousClock.now + .seconds(2)
        while selected != target, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(selected, target)
        XCTAssertEqual(captures, receipt == "captured" ? 2 : 1,
          "Only the exact captured host in this sequence invalidates the image: \(receipt), reverse=\(reverse)")
      }
    }
  }

  func testPresentedEndpointWaitsForItsLiveHostWithoutRecaptureOrIdleFrames() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    for reverse in [false, true] {
      for completed in [false, true] {
        let window = UIWindow(windowScene: scene), native = IPadSheetCurlController()
        window.frame = .init(x: 0, y: 0, width: 300, height: 400)
        let source = UIViewController(), target = UIViewController()
        source.view.backgroundColor = .red; target.view.backgroundColor = .green
        window.rootViewController = native; window.makeKeyAndVisible()
        defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        native.show(source, direction: .forward, animated: false); native.prepare(target)
        window.layoutIfNeeded()
        let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
        let landing = completed ? target : source, other = completed ? source : target
        var ready = true, captures = 0, completions: [Bool] = []
        var bent = false, lifted = false, endpointPresented = false
        native.isSheetReadyForCapture = { $0 !== landing || ready }
        native.onCaptureMeasured = { _ in captures += 1 }
        native.willTurn = { $0 === target }
        native.didTurn = { from, completed in
          XCTAssertTrue(from === source); completions.append(completed)
        }
        let resolve = curl.onFrameReady
        let endpoint = reverse ? (completed ? 0.0 : 1.0) : (completed ? 1.0 : 0.0)
        curl.onFrameReady = { image, progress, sequence, readiness in
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
        XCTAssertTrue(completions.isEmpty, "A frozen endpoint cannot enable an unready live page")
        XCTAssertTrue(native.page === source)
        XCTAssertTrue(native.containsInActiveTurn(source)); XCTAssertTrue(native.containsInActiveTurn(target))
        XCTAssertFalse(curl.isHidden); XCTAssertNotNil(curl.frameLease)
        native.sheetReadinessDidChange(other)
        XCTAssertFalse(curl.animatesContinuously)
        let submitted = curl.submittedFrameCount
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(completions.isEmpty, "The other page cannot release this landing")
        XCTAssertEqual(curl.submittedFrameCount, submitted, "Waiting for live readiness must not poll the display")
        XCTAssertEqual(captures, 1)
        ready = true; native.sheetReadinessDidChange(landing)
        XCTAssertEqual(completions, [completed]); XCTAssertTrue(native.page === landing)
        XCTAssertTrue(curl.isHidden); XCTAssertNil(curl.frameLease)
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
      let state = ImmediateSheetColour()
      let changed = UIHostingController(rootView: ImmediateSheetView(state: state))
      let other = UIViewController(); other.view.backgroundColor = .blue
      window.rootViewController = native; window.makeKeyAndVisible()
      defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
      native.show(reverse ? other : changed, direction: .forward, animated: false)
      native.prepare(reverse ? changed : other)
      try await Task.sleep(for: .milliseconds(30))
      let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
      let resolve = curl.onFrameReady
      var captured: CGImage?
      curl.onFrameReady = { image, progress, sequence, readiness in
        if captured == nil, readiness.isReady { captured = image }
        resolve?(image, progress, sequence, readiness)
      }
      // No screenshot or intervening UI cycle may flush the pending update.
      state.green = true
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
          ready(true)
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
        source.view.backgroundColor = .blue; target.view.backgroundColor = .red
        window.rootViewController = native; window.makeKeyAndVisible()
        native.show(source, direction: .forward, animated: false); native.prepare(target)
        native.willTurn = { $0 === target }
        try await Task.sleep(for: .milliseconds(30))
        let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
        let resolve = curl.onFrameReady
        var resolvedProgress: Double?
        curl.onFrameReady = { image, progress, sequence, readiness in
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

  func testFirstPresentedCurlPrimesTheSourceBeforeExposingTheOtherLeaf() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), blue = UIViewController(), red = UIViewController()
    blue.view.backgroundColor = .blue; red.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(blue, direction: .forward, animated: false); native.prepare(red)
    try await Task.sleep(for: .milliseconds(30))
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    defer { curl.onFrameReady = resolve }
    for turn in 0..<6 {
      var first: NotebookMetalFrameReadiness?, firstProgress: Double?
      var underlay: UIView?
      curl.onFrameReady = { image, progress, sequence, readiness in
        if first == nil, readiness.isReady {
          first = readiness; firstProgress = progress
          underlay = native.view.subviews.dropLast().last
        }
        resolve?(image, progress, sequence, readiness)
      }
      let target = turn.isMultiple(of: 2) ? red : blue
      native.show(target, direction: turn.isMultiple(of: 2) ? .forward : .reverse, animated: true)
      let limit = ContinuousClock.now + .seconds(2)
      while native.page !== target, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(native.page === target)
      XCTAssertTrue(try XCTUnwrap(first).isReady)
      XCTAssertEqual(firstProgress, turn.isMultiple(of: 2) ? 0 : 1,
        "The first displayed drawable must match the live source, not expose the next page before its pixels exist")
      XCTAssertTrue(underlay === (turn.isMultiple(of: 2) ? blue.view : red.view))
    }
  }

  func testSlowSourcePreparationCannotConsumeTheVisibleCurl() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), blue = UIViewController(), red = UIViewController()
    blue.view.backgroundColor = .blue; red.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(blue, direction: .forward, animated: false); native.prepare(red)
    try await Task.sleep(for: .milliseconds(30))
    // Deliberately make preparation longer than the animation's entire 320 ms.
    // This is a continuity regression, not a latency or performance measurement.
    native.onCaptureMeasured = { _ in Thread.sleep(forTimeInterval: 0.35) }
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    defer { curl.onFrameReady = resolve }
    for turn in 0..<2 {
      var firstBend: Double?
      curl.onFrameReady = { image, progress, sequence, readiness in
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

  func testFlatReverseInstallsItsLiveUnderlayBeforeRetiringTheCurl() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.neighbor = { _, _ in target }; native.willTurn = { _ in true }
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    try await Task.sleep(for: .milliseconds(30))
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    defer { curl.onFrameReady = resolve }
    var shown: Double?
    curl.onFrameReady = { image, progress, sequence, readiness in
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
      XCTAssertTrue(curl.presentsWithTransaction,
        "Interior frames cannot detach an earlier reveal from UIKit's still-open transaction")
      XCTAssertTrue(try XCTUnwrap(curl.layer as? CAMetalLayer).presentsWithTransaction,
        "The display link bypasses MTKView.draw; its actual Metal layer must participate in the transaction")
      XCTAssertTrue(native.page === source, "Holding the endpoint does not accept the gesture")
      let layers = native.view.subviews
      XCTAssertTrue(layers.last === curl)
      XCTAssertTrue(layers.dropLast().last === (progress == 1 ? target.view : source.view),
        "The exact live underlay must be installed before the curl can retire; otherwise the compositor flashes the old leaf")
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
          let owner = curl.onFrameReady
          let endpoint = direction == .forward ? (completes ? 1.0 : 0.0) : (completes ? 0.0 : 1.0)
          curl.onFrameReady = { image, progress, sequence, readiness in
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
            XCTAssertTrue(completions.isEmpty, "Lift without a displayed endpoint is not presentation")
          }
          let limit = CACurrentMediaTime() + 2
          while completions.isEmpty, CACurrentMediaTime() < limit { try await Task.sleep(for: .milliseconds(2)) }
          XCTAssertTrue(endpointPresented)
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
    let layer = try XCTUnwrap(curl.layer as? CAMetalLayer)
    for side in [600.0, 1200.0, 600.0] {
      let size = CGSize(width: side, height: side)
      curl.prepareDrawable(size: size)
      XCTAssertEqual(curl.drawableSize, size)
      XCTAssertEqual(layer.drawableSize, size,
        "A paused MTKView must not leave its custom display clock acquiring old-sized drawables")
      XCTAssertEqual(curl.submittedFrameCount, 0, "Preparing size is not a fake presentation")
    }
    curl.releaseSource()
  }

  func testCurlHasIntermediatePixelsAndDoesNotLeaveABindingShadow() async throws {
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    var selected = 0
    func configure() {
      controller.update(ownerID:owner,sequenceRevision:"motion",pageCount:3,selectedIndex:selected,
        navigationIsEnabled:true,pageIsInteractive:true,canBeginNavigation:{true},
        page:{ index,_,ready in
          ready(true)
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
      XCTAssertLessThanOrEqual(SceneRenderResources.shared.reservedBytes,reservedBefore,
        "A completed turn must release its image and drawable backing before another turn")
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
        page: { index, _, ready in ready(true); return AnyView(Color.white.overlay(Text("Sheet \(index)"))) },
        onCommit: { index, _ in selected = index; landings.append((index, CACurrentMediaTime())); configure() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { controller.sheetController.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    try await Task.sleep(for: .milliseconds(60))
    let native = controller.sheetController
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let resolve = curl.onFrameReady
    var origin = CACurrentMediaTime(), phases: [String] = []
    var lastImage: ObjectIdentifier?, sawBend = false
    native.onCaptureMeasured = { measurement in
      phases.append("capture beginMS=\((measurement.began-origin)*1000) durationMS=\((measurement.ended-measurement.began)*1000) pixels=\(measurement.pixels)")
    }
    curl.onFrameReady = { image, progress, sequence, readiness in
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
    defer { native.onCaptureMeasured = nil; curl.onFrameReady = resolve }
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
    var selected = 0, committedAt: TimeInterval?
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "motion-timing", pageCount: 3, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          ready(true)
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
      let forwardReadiness = curl.onFrameReady
      var frames: [(progress: Double, presented: TimeInterval, delivered: TimeInterval)] = []
      var submission: [SheetCurlMetalView.FrameTiming] = []
      curl.onFrameMeasured = { submission.append($0) }
      committedAt = nil
      curl.onFrameReady = { image, progress, sequence, readiness in
        // The filtered presentation observer excludes precisely the zero or
        // invalid receipts this oracle must reject. Keep every native receipt.
        let presentedAt: TimeInterval
        switch readiness {
        case .osPresentation(let time): presentedAt = time
        case .simulatorCommandCompletion: presentedAt = .nan
        }
        frames.append((progress, presentedAt, CACurrentMediaTime()))
        forwardReadiness?(image, progress, sequence, readiness)
      }
      let start = CACurrentMediaTime()
      XCTAssertTrue(commands.send(.step(target == 1 ? 1 : -1), ownerID: owner, source: "motion-timing"))
      let commandReturned = CACurrentMediaTime()
      while committedAt == nil, CACurrentMediaTime() - start < 1 {
        try await Task.sleep(for: .milliseconds(1))
      }
      curl.onFrameReady = forwardReadiness
      curl.onFrameMeasured = nil
      let encoding = XCTAttachment(string: "Command execution=\((commandReturned-start)*1000) ms\n" + submission.map {
        "start=\(($0.encodingBegan-start)*1000)ms; CPU=\(($0.submitted-$0.encodingBegan)*1000)ms; GPU queue=\(($0.gpuBegan-$0.submitted)*1000)ms; GPU=\(($0.gpuEnded-$0.gpuBegan)*1000)ms; target=\(($0.targetPresentation-start)*1000)ms"
      }.joined(separator: "\n"))
      encoding.name = "Curl submission timing \(turn)"; encoding.lifetime = .keepAlways; add(encoding)
      XCTAssertFalse(frames.isEmpty, "No OS presentation evidence")
      XCTAssertTrue(frames.allSatisfy {
        $0.presented.isFinite && $0.presented > 0 && $0.presented >= start && $0.presented <= $0.delivered
      }, "Zero/dropped, invalid or pre-command timestamps cannot stand in for displayed frames")
      // Delivery onto MainActor can be delayed or reordered. Only the OS clock
      // measures display cadence; callback delay is retained as a separate lane.
      // Missing receipts already fail above. Do not turn their zero timestamp
      // into a meaningless negative first-response or a multi-day frame gap.
      let ordered = frames.filter { $0.presented.isFinite && $0.presented >= start }
        .sorted { $0.presented < $1.presented }
      let first = try XCTUnwrap(ordered.first { $0.progress > 0 && $0.progress < 1 },
        "An unchanged initial image or a source→target jump is not visible animation feedback")
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
