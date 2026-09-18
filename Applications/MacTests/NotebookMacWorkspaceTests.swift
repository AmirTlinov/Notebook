import AppKit
import NotebookCore
import XCTest
import SwiftUI
@testable import Notebook

@MainActor final class NotebookMacWorkspaceTests: XCTestCase {
  func testPeerCameraDoesNotMoveLocalWindowAndIPCStillObservesIPad() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start(showingPage: true)
    model.setSelectionSurfaceActive(true)
    let local = try XCTUnwrap(model.presence)
    let header = try fixture.store.workspaceHeader()
    let peer = NotebookTransportIdentity(deviceID: UUID(), workspaceID: header.workspaceID, displayName: "iPad")
    let connection = UUID(), session = UUID()
    model.peerConnected(peer, generation: connection)
    let remote = SessionPresence(boardID: header.rootBoardID, mode: .board,
      camera: .init(scale: 0.3), viewport: .init(x: 834, y: 1194))
    model.receivePeerTransient(.presence(.init(sessionID: session, sequence: 1, phase: .active, presence: remote)), peerID: peer.deviceID, generation: connection)
    XCTAssertEqual(model.presence, local)
    XCTAssertEqual(model.observedPresencePhase, .active)
    model.receivePeerTransient(.presence(.init(sessionID: session, sequence: 2, phase: .settled, presence: remote)), peerID: peer.deviceID, generation: connection)
    await model.finishPendingPersistence()
    XCTAssertEqual(model.presence, local)
    XCTAssertEqual(try fixture.store.loadPresence(), local)
    let observed = try await fixture.read(.init(kind: .presence)).decode(SessionPresence.self)
    XCTAssertEqual(observed, remote)
    try await fixture.waitUntil(seconds: 8) {
      (try? fixture.store.loadCurrentViewReceipt())?.presence == remote
    }
    XCTAssertEqual(model.presence, local, "The peer preview cannot borrow or move the local camera")
    model.macGoBack()
    let navigated = try XCTUnwrap(model.presence)
    XCTAssertEqual(navigated.mode, .board)
    XCTAssertEqual(model.observedPresence, remote)
    model.peerDisconnected(peerID: peer.deviceID, generation: connection)
    await model.finishPendingPersistence()
    XCTAssertEqual(model.presence, navigated)
    let disconnected = try await fixture.read(.init(kind: .presence)).decode(SessionPresence.self)
    XCTAssertEqual(disconnected, navigated)
    let selection = try await fixture.read(.init(kind: .selection)).decode(NotebookSelectionSnapshot.self)
    XCTAssertEqual(selection.deviceID, model.actorID)
    XCTAssertEqual(selection.selection?.surface.id, navigated.boardID)
  }

  func testSwiftUIMaterialReceivesPointerButEmptyPlanePassesThrough() {
    let view = SceneCameraPlaneView<Int>()
    let presence = SessionPresence(boardID: UUID(), mode: .board, camera: .init(), viewport: .init(x: 600, y: 400))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.orderOut(nil) }
    window.orderFront(nil)
    view.update(presence: presence, revision: 1, hitRegions: { _ in [CGRect(x: 100, y: 80, width: 200, height: 200)] }) { _, _ in
      AnyView(Rectangle().fill(.white).frame(width: 600, height: 400).onTapGesture {})
    }
    XCTAssertNotNil(view.hitTest(view.convert(CGPoint(x: 150, y: 100), to: view.superview)))
    XCTAssertNil(view.hitTest(view.convert(CGPoint(x: 10, y: 10), to: view.superview)))
    view.uninstall()
  }

  func testClosingLastWindowDoesNotTerminateSharedOwner() {
    let lifecycle = NotebookMacLifecycle()
    XCTAssertFalse(lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
  }
}
