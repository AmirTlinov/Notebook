import AppKit
import NotebookCore
import XCTest
import SwiftUI
@testable import Notebook

@MainActor final class NotebookMacWorkspaceTests: XCTestCase {
  func testOpeningExistingNotebookAdmitsItsColdPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    let header = try fixture.store.initializeWorkspace(actor: UUID(), pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    try fixture.store.savePresence(.init(boardID: header.rootBoardID, mode: .board,
      camera: .init(scale: 0.22), viewport: .init(x: 1100, y: 780), selectedItemID: item.id))
    try await fixture.start()
    XCTAssertNil(model.activePage, "A closed cover must not eagerly load its paper")
    let boardView = try XCTUnwrap(model.presence)
    model.macOpenItem(item.id)
    XCTAssertEqual(model.returnPlaces.last?.presence, boardView, "Back restores the exact board camera, not a new guessed scale")
    try await fixture.waitUntil { model.activePage?.id == item.firstPageID }
    XCTAssertEqual(model.presence?.mode, .page)
  }

  func testReaderFitsWidthAtTopAndCannotScrollAwayFromPaper() {
    let center = WorldPoint(x: 1800, y: -2400)
    let geometry = WorkspaceItemGeometry.notebook
    let viewport = SpatialPoint(x: 1100, y: 780)
    let fit = MacReadingCamera.fitted(center: center, geometry: geometry, viewport: viewport, fit: .width)
    let frame = geometry.screenFrame(center: center, camera: fit, viewport: viewport)
    XCTAssertEqual(frame.width, viewport.x - 48, accuracy: 0.001)
    XCTAssertEqual(frame.x, 24, accuracy: 0.001)
    XCTAssertEqual(frame.y, 24, accuracy: 0.001)
    let far = SpatialCamera(center: center.offsetBy(x: 100_000, y: 100_000), scale: fit.scale)
    let constrained = MacReadingCamera.constrained(far, center: center, geometry: geometry, viewport: viewport)
    let bottom = geometry.screenFrame(center: center, camera: constrained, viewport: viewport)
    XCTAssertEqual(bottom.x, 24, accuracy: 0.001)
    XCTAssertEqual(bottom.y + bottom.height, viewport.y - 24, accuracy: 0.001)
    let whole = MacReadingCamera.fitted(center: center, geometry: geometry, viewport: viewport, fit: .page)
    let paper = geometry.screenFrame(center: center, camera: whole, viewport: viewport)
    XCTAssertEqual(paper.height, viewport.y - 48, accuracy: 0.001)
    XCTAssertEqual(whole.center, center)
  }

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
