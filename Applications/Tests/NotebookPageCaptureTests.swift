import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor final class NotebookPageCaptureTests: XCTestCase {
  func testCancelledPendingCaptureCannotRevealOrRetainTheRetiredLeaf() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController(), replacement = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red; replacement.view.backgroundColor = .green
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.view.layoutIfNeeded()
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let submittedBefore = curl.submittedFrameCount
    native.show(target, direction: .forward, animated: true)
    native.cancelMotion()
    native.show(replacement, direction: .forward, animated: false)
    // Let the retired update's callback arrive. It cannot capture the
    // old page, acquire backing, submit a frame, or cover the replacement.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(native.page === replacement)
    XCTAssertTrue(native.view.subviews.last === replacement.view)
    XCTAssertTrue(curl.isHidden); XCTAssertNil(curl.frameLease)
    XCTAssertEqual(curl.submittedFrameCount, submittedBefore)
  }

  func testCancelledColdInteractiveTurnReleasesMotionWithoutCapturing() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.view.layoutIfNeeded()
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    var ready = false, captures = 0, completions: [Bool] = []
    native.willTurn = { _ in true }; native.isSheetReadyForCapture = { _ in ready }
    native.onCaptureMeasured = { _ in captures += 1 }; native.didTurn = { _, completed in completions.append(completed) }
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target))
    XCTAssertTrue(native.containsInActiveTurn(source)); XCTAssertTrue(native.containsInActiveTurn(target))
    native.updateInteractiveTurn(translation: -80)
    native.endInteractiveTurn(completed: false)
    XCTAssertEqual(completions, [false], "Cancellation releases its original contact synchronously")
    XCTAssertFalse(native.containsInActiveTurn(source)); XCTAssertFalse(native.containsInActiveTurn(target))
    XCTAssertTrue(native.page === source); XCTAssertTrue(native.view.subviews.last === source.view)
    ready = true; native.sheetReadinessDidChange(source)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(captures, 0); XCTAssertNil(curl.frameLease); XCTAssertTrue(curl.isHidden)
    XCTAssertEqual(curl.submittedFrameCount, 0, "Neither queued nor late readiness can revive the cancelled capture")
    XCTAssertTrue(native.beginInteractiveTurn(direction: .forward, target: target), "The next contact is not blocked")
    native.endInteractiveTurn(completed: false)
    XCTAssertEqual(completions, [false, false])
  }

  func testCurlWaitsForTheExistingReclamationFenceWithoutLosingItsMotion() async throws {
    try await checkReclamationCapture(cancelled: false)
  }

  func testCancelledCurlCannotRestartWhenTheReclamationFenceFinishes() async throws {
    try await checkReclamationCapture(cancelled: true)
  }

  private func checkReclamationCapture(cancelled: Bool) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 300, height: 400)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    let replacement = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red; replacement.view.backgroundColor = .green
    window.rootViewController = native; window.makeKeyAndVisible()
    native.show(source, direction: .forward, animated: false); native.prepare(target); native.view.layoutIfNeeded()
    let resources = SceneRenderResources.shared
    var retained: RasterReservation? = try XCTUnwrap(resources.reserveDerivedBytes(
      resources.byteLimit - resources.residentBytes - resources.reservedBytes, priority: .input))
    let bytes = try XCTUnwrap(retained).byteCount, identity = UUID()
    var releaseFence: CheckedContinuation<Void, Never>?, releaseStarted = false
    let owner = resources.registerReclamationOwner {
      guard !releaseStarted else { return [] }
      return [.init(id: identity, bytes: bytes, rasterCount: 0, value: .unused,
        distance: 0, restorationMilliseconds: 0, release: {
          releaseStarted = true
          return Task { @MainActor in
            await withCheckedContinuation { releaseFence = $0 }
            retained?.release(); retained = nil
          }
        })]
    }
    defer {
      releaseFence?.resume(); releaseFence = nil; retained?.release()
      resources.unregisterReclamationOwner(owner); native.cancelMotion()
      window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    var captures = 0, errors: [String] = [], completions: [Bool] = []
    native.onCaptureMeasured = { _ in captures += 1 }
    native.onFailure = { errors.append($0.localizedDescription) }
    native.show(target, direction: .reverse, animated: true) { completions.append($0) }
    let waitingLimit = ContinuousClock.now + .seconds(2)
    while releaseFence == nil, ContinuousClock.now < waitingLimit { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertNotNil(releaseFence); XCTAssertEqual(resources.pendingReclamationCount, 1)
    XCTAssertEqual(captures, 0); XCTAssertTrue(errors.isEmpty); XCTAssertTrue(completions.isEmpty)
    XCTAssertNil(curl.frameLease); XCTAssertTrue(native.page === source)
    if cancelled {
      native.cancelMotion(); native.show(replacement, direction: .forward, animated: false)
      XCTAssertEqual(completions, [false])
    }
    releaseFence?.resume(); releaseFence = nil
    await resources.finishPendingReclamations()
    if cancelled {
      await Task.yield()
      XCTAssertTrue(native.page === replacement); XCTAssertEqual(captures, 0)
      XCTAssertNil(curl.frameLease); XCTAssertTrue(curl.isHidden)
      XCTAssertEqual(completions, [false])
    } else {
      let finishedLimit = ContinuousClock.now + .seconds(2)
      while completions.isEmpty, ContinuousClock.now < finishedLimit { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(captures, 1, "The accepted reverse motion captures once, after the same fence")
      XCTAssertEqual(completions, [true]); XCTAssertTrue(native.page === target)
    }
    XCTAssertTrue(errors.isEmpty); XCTAssertEqual(resources.pendingReclamationCount, 0)
  }

  func testCurlCapturesChangedAndNewlyInstalledLayersInBothDirections() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 400, height: 600)
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    for direction in [IPadSheetCurlController.Direction.forward, .reverse] {
      for insertsLayer in [false, true] {
        let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
        source.view.backgroundColor = .blue; target.view.backgroundColor = .blue
        window.rootViewController = native; window.makeKeyAndVisible()
        native.show(source, direction: direction, animated: false); native.prepare(target)
        native.view.layoutIfNeeded()
        let sheet = direction == .forward ? source.view! : target.view!
        let layer = CALayer(); layer.frame = sheet.bounds
        layer.contents = solidImage(.blue)
        sheet.layer.addSublayer(layer)
        try await Task.sleep(for: .milliseconds(80))
        // Readiness installs sources before CA presents them. Capture in that
        // same event, including the reverse sheet still behind the live source.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if insertsLayer {
          let added = CALayer(); added.frame = sheet.bounds; added.contents = solidImage(.red)
          sheet.layer.addSublayer(added)
        } else { layer.contents = solidImage(.red) }
        CATransaction.commit()
        let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
        let owner = curl.onFrameReady
        var captured: CGImage?
        curl.onFrameReady = { image, progress, sequence, readiness in
          if readiness.isReady { captured = image }
          owner?(image, progress, sequence, readiness)
        }
        native.show(target, direction: direction, animated: true)
        XCTAssertTrue(native.view.subviews.last === source.view,
          "Live paper must remain in front until the new curl frame resolves")
        let limit = ContinuousClock.now + .seconds(2)
        while captured == nil, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
        let image = try XCTUnwrap(captured)
        let rgba = pixel(image)
        XCTAssertGreaterThan(rgba[0], 240, "The current red source was replaced with stale pixels: \(rgba)")
        XCTAssertLessThan(rgba[2], 15, "Old blue source leaked into the curl: \(rgba)")
        XCTAssertTrue([32,64].contains(image.bitsPerPixel), "The native source is admitted before capture, not converted on main")
        let drawableBytes = ((image.width * 4 + 255) / 256) * 256 * image.height * curl.drawableCount
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(curl.frameLease).byteCount,
          image.bytesPerRow * image.height + drawableBytes, "The larger source must not bypass shared admission")
        native.cancelMotion()
        XCTAssertTrue(native.view.subviews.last === source.view)
        XCTAssertTrue(native.view.subviews.contains { $0 === curl }, "A turn must not rebuild the Metal view")
        XCTAssertTrue(curl.isHidden, "Retired pixels cannot show through the next notebook's loading shell")
        XCTAssertNil(curl.frameLease)
      }
    }
  }

  func testFittedPageCaptureUsesProjectedDensityInsteadOfOffscreenPageSize() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let host = UIViewController(), native = IPadSheetCurlController()
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    host.addChild(native); host.view.addSubview(native.view); native.didMove(toParent: host)
    native.view.bounds = .init(x: 0, y: 0, width: 800, height: 1200)
    native.view.center = .init(x: 210, y: 310)
    native.view.transform = .init(scaleX: 0.5, y: 0.5)
    let source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    native.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let owner = curl.onFrameReady
    var captured: CGImage?
    curl.onFrameReady = { image, progress, sequence, readiness in
      captured = image; owner?(image, progress, sequence, readiness)
    }
    native.show(target, direction: .forward, animated: true)
    let limit = ContinuousClock.now + .seconds(2)
    while captured == nil, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
    let image = try XCTUnwrap(captured)
    XCTAssertEqual(image.width, Int(400 * window.screen.scale))
    XCTAssertEqual(image.height, Int(600 * window.screen.scale))
    native.cancelMotion()
  }

  func testFullSizeTurnRecordsCaptureAndFirstFrameWithoutWindowReadback() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let native = IPadSheetCurlController(), source = UIViewController(), target = UIViewController()
    source.view.backgroundColor = .blue; target.view.backgroundColor = .red
    window.rootViewController = native; window.makeKeyAndVisible()
    defer { native.cancelMotion(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    native.show(source, direction: .forward, animated: false); native.prepare(target)
    native.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    let curl = try XCTUnwrap(native.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let owner = curl.onFrameReady
    for direction in [IPadSheetCurlController.Direction.forward, .reverse] {
      var captures: [IPadSheetCurlController.CaptureTiming] = []
      var frames: [SheetCurlMetalView.FrameTiming] = []
      var resolved: TimeInterval?
      native.onCaptureMeasured = { captures.append($0) }
      curl.onFrameMeasured = { frames.append($0) }
      curl.onFrameReady = { image, progress, sequence, readiness in
        if readiness.isReady, resolved == nil { resolved = CACurrentMediaTime() }
        owner?(image, progress, sequence, readiness)
      }
      let start = CACurrentMediaTime()
      native.show(target, direction: direction, animated: true)
      let limit = ContinuousClock.now + .seconds(1)
      while resolved == nil || frames.isEmpty, ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(1)) }
      XCTAssertEqual(captures.count, 1)
      let capture = try XCTUnwrap(captures.first), frame = try XCTUnwrap(frames.first)
      let end = try XCTUnwrap(resolved)
      XCTAssertGreaterThanOrEqual(frame.encodingBegan, start, "A cancelled turn cannot publish into its replacement's observer")
      let note = XCTAttachment(string: "capture starts=\((capture.began-start)*1000) ms; capture CPU=\((capture.ended-capture.began)*1000) ms; pixels=\(capture.pixels); first encode starts=\((frame.encodingBegan-start)*1000) ms; encode CPU=\((frame.submitted-frame.encodingBegan)*1000) ms; first resolution callback=\((end-start)*1000) ms; GPU resolution is readiness on Simulator, not OS display time")
      note.name = "page-turn-start-phases"; note.lifetime = .keepAlways; add(note)
      native.cancelMotion()
    }
  }

  private func solidImage(_ color: UIColor) -> CGImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: .init(width: 8, height: 8), format: format).image { context in
      color.setFill(); context.fill(.init(x: 0, y: 0, width: 8, height: 8))
    }.cgImage!
  }

  private func pixel(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let centre = image.cropping(to: .init(x: image.width/2, y: image.height/2, width: 1, height: 1))!
    bytes.withUnsafeMutableBytes { data in
      let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(centre, in: .init(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
  }
}
