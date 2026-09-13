import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class NotebookPresentationTests: XCTestCase {
  @MainActor func testSettlingAnExplicitPaperCameraDoesNotFitItAgainOrLoseItOnDisk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-paper-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    let page = try XCTUnwrap(model.workspace?.selectedPageID)
    let camera = SpatialCamera(center: .zero.offsetBy(x: 150, y: -110), scale: 1.4)
    let presence = SessionPresence(mode: .page, camera: camera, viewport: .init(x: 834, y: 1194),
      focusedItemID: item, openProgress: 1, selectedItemID: item, notebookPageID: page)
    model.updatePresence(presence, settled: true)
    XCTAssertEqual(model.presence?.camera, camera)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.loadPresence().camera, camera)
    XCTAssertEqual(model.presence?.notebookPageID, page)
  }

  @MainActor func testMountedWorkspaceReceivesTheTrustedShowAndPencilStopsItsActualCamera() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-scene-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model))
    addTeardownBlock { @MainActor in
      window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      try FileManager.default.removeItem(at: root)
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.updatePresence(.init(mode: .board, camera: .init(scale: 0.3), viewport: .init(x: 834, y: 1194)), settled: true)
    window.rootViewController = host; window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(250))
    let peer = NotebookTransportIdentity(deviceID: UUID(), workspaceID: try XCTUnwrap(model.workspaceHeader?.workspaceID), displayName: "Presentation Mac")
    let generation = UUID()
    model.peerConnected(peer, generation: generation)
    model.receivePeerTransient(.presentation(.receipt(.init(id: UUID(), status: .unavailable))), peerID: peer.deviceID, generation: generation)
    let (device, envelope) = try XCTUnwrap(model.presentationPlayer.currentView?())
    let before = try XCTUnwrap(model.presence), ink = model.spatialInk
    let camera = SpatialCamera(center: before.camera.center.offsetBy(x: 100, y: -100), scale: 0.6)
    let request = NotebookPresentationRequest(id: UUID(), view: .init(deviceID: device, sessionID: envelope.sessionID, sequence: envelope.sequence),
      steps: [.init(duration: 3, transition: 0.8, camera: camera)])
    model.receivePeerTransient(.presentation(.play(request, expiresAt: Date().addingTimeInterval(5))), peerID: peer.deviceID, generation: generation)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(model.presentationPlayer.isActive)
    XCTAssertNotEqual(model.presence?.camera, before.camera)
    let pencil = UUID(); XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    let stopped = model.presence
    XCTAssertFalse(model.presentationPlayer.isActive)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(model.presence, stopped, "No late animation sample may move accepted Pencil")
    XCTAssertEqual(model.spatialInk, ink)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    model.inputGate.endPencilAction(source: pencil)
    model.peerDisconnected(peerID: peer.deviceID, generation: generation)
  }

  @MainActor func testCameraScriptUsesOneSettlementAndDoesNotCloseTheOpenPage() async throws {
    let clock = SceneCameraSettlement(), player = NotebookPresentationPlayer()
    let peer = UUID(), device = UUID(), session = UUID(), item = UUID(), page = UUID()
    var presence = SessionPresence(mode: .page, camera: .init(scale: 0.5), viewport: .init(x: 800, y: 600),
      focusedItemID: item, openProgress: 1, selectedItemID: item, notebookPageID: page)
    let original = presence
    let view = NotebookPresentationView(deviceID: device, sessionID: session, sequence: 1)
    var cameraMoves = 0, receipts: [NotebookPresentationReceipt] = []
    player.currentView = { (device, .init(sessionID: session, sequence: 1, phase: .settled, presence: presence)) }
    player.isInputActive = { false }
    player.moveCamera = { camera, duration in
      cameraMoves += 1
      return clock.start(from: presence, to: presence.replacingCamera(camera), duration: duration, bounce: 0) { sample, _ in
        XCTAssertEqual(sample.mode, .page); XCTAssertEqual(sample.notebookPageID, page)
        presence = sample
      } completion: {}
    }
    player.stopCamera = { clock.cancel() }
    player.reply = { receipt, _ in receipts.append(receipt) }
    let camera = SpatialCamera(center: .zero.offsetBy(x: 140, y: -70), scale: 1)
    let request = NotebookPresentationRequest(id: UUID(), view: view, steps: [.init(duration: 0.5, transition: 0.1, camera: camera)])
    player.receive(.play(request, expiresAt: Date().addingTimeInterval(5)), peer: peer)
    try await Task.sleep(for: .milliseconds(750))
    XCTAssertEqual(presence.camera, camera); XCTAssertEqual(presence.selectedItemID, original.selectedItemID)
    XCTAssertEqual(receipts.last?.status, .completed); XCTAssertNil(player.stage)
    player.receive(.play(request, expiresAt: Date().addingTimeInterval(5)), peer: peer)
    XCTAssertEqual(cameraMoves, 1)
    XCTAssertEqual(receipts.last?.status, .completed)
  }

  @MainActor func testInputAndExpiredViewAreNotQueuedAndLateSVGReadinessCannotReviveAStoppedShow() async throws {
    let player = NotebookPresentationPlayer(), peer = UUID(), device = UUID(), session = UUID()
    let gate = NotebookInputGate()
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 800, y: 600))
    let view = NotebookPresentationView(deviceID: device, sessionID: session, sequence: 1)
    player.currentView = { (device, .init(sessionID: session, sequence: 1, phase: .settled, presence: presence)) }
    player.isInputActive = { gate.isActive }; player.moveCamera = { _, _ in true }
    gate.onActivityChange = { if $0 { player.interrupt() } }
    var receipts: [NotebookPresentationReceipt] = []
    player.reply = { receipt, _ in receipts.append(receipt) }
    let bounds = NotebookPresentationRegion(origin: .zero, width: 120, height: 80)
    let request = NotebookPresentationRequest(id: UUID(), view: view, steps: [.init(svg: "<svg viewBox=\"0 0 120 80\"><text x=\"5\" y=\"40\">GPT</text></svg>", bounds: bounds)])
    player.receive(.play(request, expiresAt: Date().addingTimeInterval(5)), peer: peer)
    await Task.yield()
    let stage = try XCTUnwrap(player.stage)
    let pencil = UUID(); XCTAssertTrue(gate.beginPencilAction(source: pencil))
    XCTAssertNil(player.stage); XCTAssertEqual(receipts.last?.status, .interrupted)
    XCTAssertTrue(gate.hasActivePencil, "Presentation must not finish or cancel accepted Pencil")
    player.rendered(stage.id)
    player.receive(.play(.init(id: UUID(), view: view, steps: request.steps), expiresAt: Date().addingTimeInterval(5)), peer: peer)
    XCTAssertEqual(receipts.last?.reason, "input_active")
    gate.endPencilAction(source: pencil)
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertNil(player.stage)
    player.receive(.play(.init(id: UUID(), view: view, steps: request.steps), expiresAt: Date().addingTimeInterval(-1)), peer: peer)
    XCTAssertEqual(receipts.last?.reason, "expired")
  }

  @MainActor func testRealSVGIsVectorTransparentNoninteractiveAndItsWebLeaseEndsWithTheShow() async throws {
    let resources = SceneRenderResources.shared
    let baseline = resources.activeWebSurfaceCount
    let player = NotebookPresentationPlayer(), peer = UUID(), device = UUID(), session = UUID()
    let presence = SessionPresence(mode: .board, camera: .init(scale: 1), viewport: .init(x: 400, y: 300))
    player.currentView = { (device, .init(sessionID: session, sequence: 1, phase: .settled, presence: presence)) }
    player.isInputActive = { false }; player.moveCamera = { _, _ in true }
    var receipts: [NotebookPresentationReceipt] = []
    player.reply = { receipt, _ in receipts.append(receipt) }
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: NotebookPresentationOverlay(player: player, presence: presence, cameraIsActive: false))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { player.interrupt(); window.isHidden = true; window.rootViewController = nil }
    let bounds = NotebookPresentationRegion(origin: .zero.offsetBy(x: -100, y: -50), width: 200, height: 100)
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><rect width=\"200\" height=\"100\" fill=\"#4263eb\"/><text x=\"14\" y=\"58\" fill=\"white\" font-size=\"28\">GPT</text></svg>"
    let request = NotebookPresentationRequest(id: UUID(), view: .init(deviceID: device, sessionID: session, sequence: 1),
      steps: [.init(duration: 2, svg: svg, bounds: bounds)])
    player.receive(.play(request, expiresAt: Date().addingTimeInterval(5)), peer: peer)
    for _ in 0..<150 where receipts.last?.status != .playing { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(receipts.last?.status, .playing, String(describing: receipts.last))
    func web(in view: UIView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web(in: $0) }.first }
    let rendered = try XCTUnwrap(web(in: host.view))
    XCTAssertFalse(rendered.isUserInteractionEnabled)
    XCTAssertFalse(rendered.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    func centerBlue(_ image: UIImage) throws -> UInt8 {
      let cg = try XCTUnwrap(image.cgImage)
      let bitmap = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
        bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      bitmap.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
      return try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)[(cg.height / 2 * cg.width + cg.width / 2) * 4 + 2]
    }
    var snapshot = try await rendered.takeSnapshot(configuration: nil)
    let paintDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while try centerBlue(snapshot) < 200, ContinuousClock.now < paintDeadline {
      try await Task.sleep(for: .milliseconds(20))
      snapshot = try await rendered.takeSnapshot(configuration: nil)
    }
    XCTAssertGreaterThan(snapshot.size.width, 100)
    let cg = try XCTUnwrap(snapshot.cgImage)
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(pixels[3], 0, "Outside SVG, paper must remain visible")
    let center = (cg.height / 2 * cg.width + cg.width / 2) * 4
    XCTAssertGreaterThan(pixels[center + 2], 200, "The vector rectangle must actually paint blue")
    let attachment = XCTAttachment(image: snapshot); attachment.name = "temporary-vector-svg"; attachment.lifetime = .keepAlways; add(attachment)
    try await Task.sleep(for: .milliseconds(2250))
    XCTAssertEqual(receipts.last?.status, .completed); XCTAssertNil(player.stage)
    for _ in 0..<50 where resources.activeWebSurfaceCount != baseline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(resources.activeWebSurfaceCount, baseline)
  }
}
