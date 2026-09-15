import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import Notebook

final class AgentWebLeaseTests: XCTestCase {
  @MainActor
  func testRetiredPhysicalViewportReleasesRuntimeWhileUIKitKeepsTheShell() async {
    weak var released: WKWebView?
    var shell: PhysicalWebViewport?
    autoreleasepool {
      let web = WKWebView()
      released = web
      shell = PhysicalWebViewport(webView: web, contentSize: .init(width: 160, height: 120))
      shell?.retire()
    }
    for _ in 0..<100 where released != nil { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(released)
    XCTAssertNil(shell?.webView)
    XCTAssertTrue(shell?.subviews.isEmpty == true)
    withExtendedLifetime(shell) { }
  }

  @MainActor
  func testOldPhysicalViewportCannotMoveOrDetachATransferredRuntime() {
    let web = WKWebView()
    let old = PhysicalWebViewport(webView: web, contentSize: .init(width: 160, height: 120))
    let current = PhysicalWebViewport(webView: web, contentSize: .init(width: 320, height: 240))
    current.frame = .init(x: 0, y: 0, width: 640, height: 480)
    current.layoutIfNeeded()
    let bounds = web.bounds, center = web.center, transform = web.transform
    old.frame = .init(x: 0, y: 0, width: 100, height: 75)
    old.layoutIfNeeded()
    XCTAssertEqual(web.bounds, bounds)
    XCTAssertEqual(web.center, center)
    XCTAssertEqual(web.transform, transform)
    old.retire()
    XCTAssertTrue(web.superview === current)
    current.retire()
    XCTAssertNil(web.superview)
  }

  @MainActor
  func testCurrentFrameCapturesTheInstalledDOMAndRevokesProofOnDetachOrReplacement() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .input)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = CGRect(x: 100, y: 100, width: 160, height: 120)
    defer { coordinator.invalidate(); lease.release(); web.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    let source = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 160, height: 120), source: "Current DOM",
      html: "<div id='surface' style='position:absolute;inset:0;background:lime'></div><script>window.contextWitness=42</script>")
    let focus = InteractiveElementReference.board(boardID: UUID(), elementID: source.id)
    coordinator.bindPresentation(to: focus)
    coordinator.load(source, policy: .exact(scale: 2), in: web)
    let deadline = ContinuousClock.now + .seconds(8)
    while resources.image(for: source, minimumScale: 2) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let cached = try XCTUnwrap(resources.retainRaster(for: source, minimumScale: 2))
    defer { cached.release() }
    let installed = try XCTUnwrap(coordinator.installation(for: source))
    XCTAssertTrue(installed.isInstalled)
    let token = coordinator.loadToken
    _ = try await web.evaluateJavaScript("document.getElementById('surface').style.background='red'")
    let captured = try await AgentWebCoordinator.captureCurrent(focus: focus, element: source, resources: resources)
    let current = try XCTUnwrap(captured)
    defer { current.release() }
    XCTAssertNotEqual(current.entryID, cached.entryID)
    let oldPixel = try pixel(XCTUnwrap(cached.image.cgImage), x: 80, y: 60)
    let shownPixel = try pixel(XCTUnwrap(current.image.cgImage), x: 80, y: 60)
    XCTAssertLessThan(oldPixel.0, 15); XCTAssertGreaterThan(oldPixel.1, 240)
    XCTAssertGreaterThan(shownPixel.0, 240); XCTAssertLessThan(shownPixel.1, 15)
    XCTAssertEqual(coordinator.loadToken, token)
    let witness = try await web.evaluateJavaScript("window.contextWitness") as? Int
    XCTAssertEqual(witness, 42, "Capturing attention must not restart the mounted program")
    web.isHidden = true
    XCTAssertFalse(installed.isInstalled)
    let hidden = try await AgentWebCoordinator.captureCurrent(focus: focus, element: source, resources: resources)
    XCTAssertNil(hidden, "An available cache cannot stand in for hidden current pixels")
    web.isHidden = false; web.removeFromSuperview()
    XCTAssertFalse(installed.isInstalled)
    let detached = try await AgentWebCoordinator.captureCurrent(focus: focus, element: source, resources: resources)
    XCTAssertNil(detached)
    host.view.addSubview(web)
    XCTAssertTrue(installed.isInstalled)
    coordinator.bindPresentation(to: .board(boardID: UUID(), elementID: source.id))
    XCTAssertFalse(installed.isInstalled, "A reused native owner cannot reassert the former physical address")
  }

  @MainActor
  func testRasterSourceInstallationIsRevokedByItsActualNativeConsumer() throws {
    let resources = SceneRenderResources()
    let source = element(source: "Raster witness", width: 160, height: 120)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
      UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
    }
    XCTAssertTrue(resources.store(image, for: source))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    defer { raster.release() }
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    let view = AgentSnapshotRasterView(); view.frame = CGRect(x: 100, y: 100, width: 160, height: 120)
    host.view.addSubview(view); view.updateRaster(raster)
    defer { view.uninstall(); view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    let installed = view.installation(for: raster)
    XCTAssertTrue(installed.isInstalled)
    view.removeFromSuperview()
    XCTAssertFalse(installed.isInstalled)
    host.view.addSubview(view)
    XCTAssertTrue(installed.isInstalled)
    XCTAssertTrue(resources.store(image, for: source))
    let replacement = try XCTUnwrap(resources.retainRaster(for: source))
    defer { replacement.release() }
    view.updateRaster(replacement)
    XCTAssertFalse(installed.isInstalled, "Replacing the bytes revokes the prior immutable paint receipt")
  }

  @MainActor
  func testLargeSourceCapturesOnlyItsVisibleRegionWithoutChangingLayoutOrReloading() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .input)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController()
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.addSubview(web)
    defer { coordinator.invalidate(); lease.release(); web.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    let source = AgentElement(id: "large-cropped-svg", kind: .web,
      frame: .init(x: 0, y: 0, width: 10_000, height: 8_000), source: "Large vector",
      html: "<svg width='100%' height='100%' viewBox='0 0 10000 8000'><rect width='10000' height='8000' fill='white'/><rect x='7900' y='1900' width='400' height='400' fill='red'/><path d='M8000 1900V2300' stroke='black' stroke-width='1'/></svg>",
      css: "html,body{margin:0;width:100%;height:100%;overflow:hidden}")
    let first = PageRect(x: 7950, y: 1950, width: 200, height: 200)
    web.frame = CGRect(x: -first.x, y: -first.y, width: source.frame.width, height: source.frame.height)
    coordinator.load(source, policy: .region(first, scale: 1), in: web)
    let deadline = ContinuousClock.now + .seconds(8)
    while resources.image(for: .agentRegion(source, first), minimumScale: 1) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(resources.image(for: .agentRegion(source, first), minimumScale: 1))
    let token = try XCTUnwrap(coordinator.loadToken)
    let canonicalWidth = try await web.evaluateJavaScript("window.cropWitness=42; innerWidth") as? Int
    XCTAssertEqual(canonicalWidth, 10_000)
    let next = PageRect(x: 8000, y: 2000, width: 160, height: 120)
    web.frame.origin = CGPoint(x: -next.x, y: -next.y)
    coordinator.load(source, policy: .region(next, scale: 2), in: web)
    while resources.image(for: .agentRegion(source, next), minimumScale: 2) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let raster = try XCTUnwrap(resources.retainRaster(for: .agentRegion(source, next), minimumScale: 2))
    defer { raster.release() }
    let image = try XCTUnwrap(raster.image.cgImage)
    XCTAssertEqual(image.width, 320); XCTAssertEqual(image.height, 240)
    let capturePixel = try pixel(image, x: 160, y: 120)
    XCTAssertGreaterThan(capturePixel.0, 240)
    XCTAssertLessThan(capturePixel.1, 15)
    XCTAssertLessThan(capturePixel.2, 15)
    XCTAssertEqual(raster.pixelScale, 2, accuracy: 0.001)
    XCTAssertEqual(coordinator.loadToken, token)
    let witness = try await web.evaluateJavaScript("window.cropWitness") as? Int
    XCTAssertEqual(witness, 42)
    XCTAssertNil(resources.image(for: source), "A visible crop is never indexed as the whole canonical source")
    XCTAssertLessThan(resources.peakAccountedBytes, 2 * 1024 * 1024)
    let view = AgentSnapshotRasterView()
    web.isHidden = true
    host.view.backgroundColor = .white
    view.frame = CGRect(x: -next.x, y: -next.y, width: source.frame.width, height: source.frame.height)
    host.view.addSubview(view); view.updateRaster(raster); view.layoutIfNeeded()
    defer { view.uninstall(); view.removeFromSuperview() }
    let layer = try XCTUnwrap(view.layer.sublayers?.first { $0.contents != nil })
    XCTAssertEqual(layer.frame, CGRect(x: next.x, y: next.y, width: next.width, height: next.height))
    let shown = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let shownImage = try XCTUnwrap(shown.cgImage)
    let center = try pixel(shownImage, x: Int(80 * shown.scale), y: Int(60 * shown.scale))
    XCTAssertGreaterThan(center.0, 240); XCTAssertLessThan(center.1, 15); XCTAssertLessThan(center.2, 15)
    let outside = try pixel(shownImage, x: Int(230 * shown.scale), y: Int(180 * shown.scale))
    XCTAssertGreaterThan(outside.0, 240); XCTAssertGreaterThan(outside.1, 240); XCTAssertGreaterThan(outside.2, 240)
    let attachment = XCTAttachment(image: shown); attachment.name = "large-source-region-native-pixels"; attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testDensityChangeRecapturesTheExistingLiveProgramWithoutReloadingIt() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .input)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = .init(x: 0, y: 0, width: 160, height: 120)
    defer { coordinator.invalidate(); lease.release(); web.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    let source = element(source: "Persistent program", width: 160, height: 120)
    coordinator.load(source, policy: .display(scale: 0.25), in: web)
    let deadline = ContinuousClock.now + .seconds(6)
    while resources.image(for: source, minimumScale: 0.25) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(resources.image(for: source, minimumScale: 0.25))
    let token = try XCTUnwrap(coordinator.loadToken)
    _ = try await web.evaluateJavaScript("window.persistenceWitness = 42")
    coordinator.load(source, policy: .display(scale: 2), in: web)
    while resources.image(for: source, minimumScale: 2) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let raster = try XCTUnwrap(resources.retainRaster(for: source, minimumScale: 2))
    defer { raster.release() }
    XCTAssertEqual(coordinator.loadToken, token)
    let witness = try await web.evaluateJavaScript("window.persistenceWitness") as? Int
    XCTAssertEqual(witness, 42)
    XCTAssertEqual(try XCTUnwrap(raster.image.cgImage).width, 320)
    XCTAssertTrue(coordinator.hasLiveSource(source))
  }

  @MainActor
  func testProjectedRasterPreservesReadableEdgesWithoutASecondBitmap() async throws {
    let source = element(source: "edge chart", width: 1280, height: 1120)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1.6
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 1120), format: format).image { context in
      UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 1120))
      UIColor.black.setFill()
      for x in stride(from: 0, to: 1280, by: 32) { context.fill(CGRect(x: x, y: 0, width: 16, height: 1120)) }
    }
    let resources = SceneRenderResources()
    XCTAssertTrue(resources.store(image, for: source))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    defer { host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil; raster.release() }
    window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
    window.rootViewController = host; window.makeKeyAndVisible()
    for zoom in [0.125, 0.5, 0.25, 0.5] {
      host.rootView = AnyView(AgentElementSnapshotView(raster: raster)
        .frame(width: 1280, height: 1120).scaleEffect(zoom)
        .frame(width: 1280 * zoom, height: 1120 * zoom).environment(\.displayScale, 2))
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let output = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: output); attachment.name = "projected-edges-\(zoom)"; attachment.lifetime = .keepAlways; add(attachment)
      let cg = try XCTUnwrap(output.cgImage)
      let bitmap = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
      let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
      let y = cg.height / 2
      let width = Int(1280 * zoom * output.scale)
      let left = (cg.width - width) / 2
      let line = (left + width / 4..<left + width * 3 / 4).map { Int(bytes[y * bitmap.bytesPerRow + $0 * 4]) }
      XCTAssertLessThan(try XCTUnwrap(line.min()), 30, "Black strokes remain black after projection at \(zoom)")
      XCTAssertGreaterThan(try XCTUnwrap(line.max()), 225, "White gaps remain white after projection at \(zoom)")
      XCTAssertGreaterThan(line.filter { $0 < 30 || $0 > 225 }.count, line.count / 2,
        "Minification must not turn most of a readable chart into gray blur")
    }
  }

  @MainActor
  func testPreviousSourceCannotCommitStateOrDiagnosticsIntoTheCurrentSource() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .input)
    var states: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { states.append($0); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let previous = element(source: "first")
    let current = element(source: "second")
    coordinator.load(previous, in: web)
    let previousToken = try XCTUnwrap(coordinator.loadToken)
    coordinator.load(current, in: web)
    let currentToken = try XCTUnwrap(coordinator.loadToken)
    XCTAssertNotEqual(previousToken, currentToken)

    coordinator.receive(["token": previousToken, "kind": "state", "revision": "1", "value": "late previous state"])
    coordinator.receive(["token": previousToken, "kind": "diagnostic", "category": "javascript_error", "message": "late previous error"])
    coordinator.receive(["kind": "state", "value": "unaddressed state"])
    XCTAssertTrue(states.isEmpty)
    XCTAssertTrue(resources.diagnostics(for: [previous, current]).isEmpty)

    coordinator.receive(["token": currentToken, "kind": "state", "revision": "1", "value": ["current": true]])
    coordinator.receive(["token": currentToken, "kind": "state", "revision": "1", "value": "replayed input"])
    coordinator.receive(["token": currentToken, "kind": "diagnostic", "category": "overflow", "message": "current frame"])
    XCTAssertEqual(states, [.object(["current": .bool(true)])])
    XCTAssertEqual(resources.diagnostics(for: [current]).map(\.kind), ["overflow"])
    XCTAssertTrue(resources.diagnostics(for: [previous]).isEmpty)
  }

  @MainActor
  func testSnapshotAndQueuedReadinessCannotPublishAfterInvalidation() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    var ready: [Bool] = []
    var states: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onRenderReady: { ready.append($0) }, onState: { states.append($0); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let source = element(source: "current")
    coordinator.load(source, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.invalidate()
    coordinator.completeSnapshot(raster(), error: nil, token: token, element: source, reservation: reservation)
    coordinator.receive(["token": token, "kind": "state", "value": 42])
    coordinator.receive(["token": token, "kind": "diagnostic", "category": "javascript_error", "message": "too late"])
    await Task.yield()
    XCTAssertNil(resources.image(for: source))
    XCTAssertTrue(resources.diagnostics(for: [source]).isEmpty)
    XCTAssertTrue(states.isEmpty)
    XCTAssertTrue(ready.isEmpty)
    XCTAssertNil(coordinator.loadToken)
    XCTAssertNil(web.navigationDelegate)
  }

  @MainActor
  func testSnapshotFromPreviousLoadDoesNotReplaceCurrentSourceRaster() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let previous = element(source: "previous")
    let current = element(source: "current")
    coordinator.load(previous, in: web)
    let previousToken = try XCTUnwrap(coordinator.loadToken)
    let previousReservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.load(current, in: web)
    coordinator.completeSnapshot(raster(), error: nil, token: previousToken, element: previous,
      reservation: previousReservation)
    XCTAssertNil(resources.image(for: previous))
    XCTAssertNil(resources.image(for: current))

    let currentReservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.completeSnapshot(raster(), error: nil, token: try XCTUnwrap(coordinator.loadToken),
      element: current, reservation: currentReservation)
    XCTAssertNotNil(resources.image(for: current))
    XCTAssertNil(resources.image(for: previous))
  }

  @MainActor
  func testReleasedLeaseRejectsCallbacksBeforeTheViewIsDismantled() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    var states: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { states.append($0); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate() }
    let source = element(source: "old owner")
    coordinator.load(source, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    lease.release()
    coordinator.receive(["token": token, "kind": "state", "value": 42])
    XCTAssertTrue(states.isEmpty)
    coordinator.load(element(source: "new owner"), in: web)
    XCTAssertEqual(coordinator.loadToken, token, "An expired coordinator cannot acquire another owner's source.")
  }

  @MainActor
  func testOriginOnlyMoveReusesRasterAndAcceptsAnAlreadyRunningSnapshot() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let original = element(source: "one physical surface")
    let moved = original.updating(frame: .init(x: 100, y: -50, width: 32, height: 32))
    coordinator.load(original, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    coordinator.load(moved, in: web)
    XCTAssertEqual(coordinator.loadToken, token)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
    coordinator.completeSnapshot(raster(), error: nil, token: token, element: original, reservation: reservation)
    let retained = try XCTUnwrap(resources.retainRaster(for: moved))
    defer { retained.release() }
    XCTAssertNotNil(retained.image(for: .agent(original)))
    XCTAssertNotNil(resources.image(for: moved))
    XCTAssertNil(resources.image(for: moved.updating(state: .number(2))))
    XCTAssertNil(resources.image(for: moved.updating(frame: .init(x: 100, y: -50, width: 64, height: 32))))
    XCTAssertNil(resources.image(for: element(source: "changed program")))
  }

  @MainActor
  func testCurrentSnapshotErrorIsReportedButInvalidatedErrorIsDiscarded() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .visible)
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let source = element(source: "current")
    coordinator.load(source, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    let failure = NSError(domain: "NotebookSnapshotTest", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Snapshot failed"])
    coordinator.completeSnapshot(nil, error: failure, token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32)))
    XCTAssertEqual(resources.diagnostics(for: [source]).map(\.kind), ["snapshot_error"])
    coordinator.invalidate()
    coordinator.completeSnapshot(nil, error: NSError(domain: "late", code: 2), token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32)))
    XCTAssertEqual(resources.diagnostics(for: [source]).count, 1)
  }

  @MainActor
  func testSnapshotSamplingCapsAllocationWithoutResizingPhysicalContent() throws {
    let source = element(source: "large", width: 10_000, height: 8_000)
    let display = try XCTUnwrap(AgentSnapshotPolicy.display(scale: 3).pixelSize(for: source))
    XCTAssertLessThanOrEqual(max(display.width, display.height), 2048)
    XCTAssertLessThanOrEqual(display.width * display.height, 4_194_304)
    let configuration = try XCTUnwrap(AgentWebCoordinator.snapshotConfiguration(for: source,
      policy: .display(scale: 3), backingScale: 3))
    XCTAssertEqual(configuration.rect.size, CGSize(width: 10_000, height: 8_000))
    XCTAssertEqual(try XCTUnwrap(configuration.snapshotWidth).doubleValue * 3, display.width, accuracy: 0.001)
    XCTAssertEqual(AgentSnapshotPolicy.exact(scale: 2).pixelSize(for: source), CGSize(width: 20_000, height: 16_000))
    let fractional = element(source: "fractional", width: 10_000.1, height: 100.1)
    let exact = try XCTUnwrap(AgentSnapshotPolicy.exact(scale: 2).pixelSize(for: fractional))
    XCTAssertGreaterThanOrEqual(exact.width / fractional.frame.width, 2)
    XCTAssertGreaterThanOrEqual(floor(exact.width * fractional.frame.height / fractional.frame.width) / fractional.frame.height, 2,
      "WebKit's rounded height must still satisfy the declared exact sampling density.")
    XCTAssertNil(AgentSnapshotPolicy.display(scale: 2).pixelSize(for: element(source: "thin", width: 1, height: 1_000_000)),
      "A one-pixel width cannot silently inflate a capped, extremely tall raster.")
  }

  @MainActor
  func testRasterBackingIsBoundedByPreparedPixelsAndDoesNotFollowCameraZoom() throws {
    let source = element(source: "large physical surface", width: 10_000, height: 8_000)
    let policy = AgentSnapshotPolicy.display(scale: 3)
    let pixels = try XCTUnwrap(policy.pixelSize(for: source))
    let density = policy.rasterizationScale(for: source, displayScale: 3)
    XCTAssertLessThanOrEqual(source.frame.width * density, 2048)
    XCTAssertLessThanOrEqual(source.frame.height * density, 2048)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
      UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: pixels))
    }
    let resources = SceneRenderResources()
    XCTAssertTrue(resources.store(image, for: source))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    let view = AgentSnapshotRasterView()
    defer { view.uninstall(); raster.release() }
    view.bounds = CGRect(x: 0, y: 0, width: source.frame.width, height: source.frame.height)
    view.updateRaster(raster)
    view.layoutIfNeeded()
    let projectedImage = try XCTUnwrap(image.cgImage)
    XCTAssertTrue((view.layer.contents as AnyObject?) === projectedImage)
    XCTAssertFalse(view.layer.shouldRasterize, "The admitted bitmap is projected directly, without a second cached raster")
    XCTAssertEqual(view.layer.minificationFilter, .trilinear)
    XCTAssertEqual(projectedImage.width, Int(pixels.width))
    XCTAssertEqual(projectedImage.height, Int(pixels.height))
    for zoom in [0.01, 0.1, 0.8, 2, 4] {
      view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
      view.setNeedsLayout(); view.layoutIfNeeded()
      XCTAssertTrue((view.layer.contents as AnyObject?) === projectedImage,
        "The camera changes projection, not the physical surface's raster density.")
    }
  }

  @MainActor
  func testNativeSnapshotPresenterKeepsItsRasterAccountedUntilContentsAreCleared() throws {
    let source = element(source: "retained by native presenter")
    let resources = SceneRenderResources(byteLimit: 8_192, profile: .headless)
    XCTAssertTrue(resources.store(raster(), for: source))
    var lease: RasterLease? = try XCTUnwrap(resources.retainRaster(for: source))
    weak let configurationLease = lease
    let shownBytes = try XCTUnwrap(lease).accountedByteCount
    let view = AgentSnapshotRasterView()
    view.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
    view.updateRaster(try XCTUnwrap(lease))
    lease = nil
    XCTAssertNil(configurationLease, "The configuration is not the native presenter’s independent lease.")
    XCTAssertNotNil(view.layer.contents)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, shownBytes)
    XCTAssertNil(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32),
      "The native presenter pins its source against eviction.")
    view.uninstall()
    XCTAssertNil(view.layer.contents)
    XCTAssertNil(configurationLease)
    let admitted = resources.reserveRaster(pixelWidth: 32, pixelHeight: 32)
    XCTAssertNotNil(admitted)
    admitted?.release()
  }

  func testOverlayReadinessRequiresCurrentSourceAndIgnoresPreviousSourceTeardown() {
    let previous = element(source: "previous")
    let current = element(source: "current")
    var readiness = AgentOverlayReadiness()
    readiness.record(previous, ready: true)
    XCTAssertTrue(readiness.isReady(for: [previous]))
    XCTAssertFalse(readiness.isReady(for: [current]), "Reusing an element ID does not confirm its new source.")
    readiness.retain([current])
    XCTAssertFalse(readiness.isReady(for: [current]))
    readiness.record(current, ready: true)
    readiness.record(previous, ready: false)
    XCTAssertTrue(readiness.isReady(for: [current]), "An old view's teardown cannot invalidate the current raster.")
    readiness.record(current, ready: false)
    XCTAssertFalse(readiness.isReady(for: [current]))
    XCTAssertTrue(readiness.isReady(for: []))
  }

  private func element(source: String, width: Double = 32, height: Double = 32) -> AgentElement {
    AgentElement(id: "same-element", kind: .web, frame: PageRect(x: 0, y: 0, width: width, height: height),
      source: source, html: "<p>\(source)</p>")
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
    let offset = y * bitmap.bytesPerRow + x * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
  }

  @MainActor
  private func raster() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
  }
}
