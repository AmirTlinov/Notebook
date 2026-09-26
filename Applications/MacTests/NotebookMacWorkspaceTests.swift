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
    XCTAssertEqual(frame.y, 0, accuracy: 0.001)
    let far = SpatialCamera(center: center.offsetBy(x: 100_000, y: 100_000), scale: fit.scale)
    let constrained = MacReadingCamera.constrained(far, center: center, geometry: geometry, viewport: viewport)
    let bottom = geometry.screenFrame(center: center, camera: constrained, viewport: viewport)
    XCTAssertEqual(bottom.x, 24, accuracy: 0.001)
    XCTAssertEqual(bottom.y + bottom.height, viewport.y, accuracy: 0.001)
    let whole = MacReadingCamera.fitted(center: center, geometry: geometry, viewport: viewport, fit: .page)
    let paper = geometry.screenFrame(center: center, camera: whole, viewport: viewport)
    XCTAssertEqual(paper.height, viewport.y, accuracy: 0.001)
    XCTAssertEqual(whole.center, center)
  }

  func testReaderResizeConstrainsTheOldScrollWithoutReservingAFooter() {
    let center = WorldPoint(x: 1800, y: -2400), geometry = WorkspaceItemGeometry.document(.a4)
    let original = SpatialPoint(x: 1100, y: 780)
    let camera = MacReadingCamera.fitted(center: center, geometry: geometry, viewport: original, fit: .width)
    let scrolled = MacReadingCamera.constrained(.init(center: center.offsetBy(x: 0, y: 100_000), scale: camera.scale),
      center: center, geometry: geometry, viewport: original)
    let presence = SessionPresence(boardID: UUID(), mode: .document, camera: scrolled,
      viewport: original, focusedItemID: UUID(), openProgress: 1)
    for viewport in [SpatialPoint(x: 920, y: 1300), SpatialPoint(x: 1400, y: 600)] {
      let adapted = presence.adapted(to: viewport, geometry: geometry)
      let constrained = MacReadingCamera.constrained(adapted.camera, center: center, geometry: geometry, viewport: viewport)
      let frame = geometry.screenFrame(center: center, camera: constrained, viewport: viewport)
      if frame.height >= viewport.y {
        XCTAssertLessThanOrEqual(frame.y, 0.001)
        XCTAssertGreaterThanOrEqual(frame.y + frame.height, viewport.y - 0.001)
      } else {
        XCTAssertEqual(frame.y, (viewport.y-frame.height)/2, accuracy: 0.001)
      }
    }
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

  func testCanonicalDeletionRevokesTheOldMouseCameraBeforeItsNextSample() async throws {
    for sendsLateDrag in [true, false] {
      try await assertCanonicalRetirementRevokesMouseCamera(transferring: false, sendsLateDrag: sendsLateDrag)
    }
  }

  func testCanonicalTransferRevokesTheOldMouseCameraWithoutDeletingItsSelection() async throws {
    for sendsLateDrag in [true, false] {
      try await assertCanonicalRetirementRevokesMouseCamera(transferring: true, sendsLateDrag: sendsLateDrag)
    }
  }

  private func assertCanonicalRetirementRevokesMouseCamera(transferring: Bool, sendsLateDrag: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = MacCommandFixture(root: root), model = fixture.model
    retainNotebookUntilTeardown(model, removing: root)
    try await fixture.start(showingPage: true)
    let itemID = try XCTUnwrap(model.presence?.selectedItemID)
    let pageID = try XCTUnwrap(model.presence?.notebookPageID)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let childID = try XCTUnwrap(model.createBoard(at: .init(x: 3_000, y: 0)))
    let created = await model.finishPendingPersistence(); XCTAssertTrue(created)
    model.selectItem(itemID)
    model.updatePresence(.init(boardID: boardID, mode: .cover,
      camera: .init(scale: 0.3), viewport: .init(x: 1_000, y: 800),
      focusedItemID: itemID, selectedItemID: itemID, notebookPageID: pageID), settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let peer = UUID(), local = model.actorID
    let peerStore = NotebookStore(root: root.appendingPathComponent("peer"))
    // The other device authors this change before the local mouse contact.
    // Native commands on the live store must continue to reject active input.
    try await model.performStoreCommand { store in
      try NotebookPeerFixture.copy(from: store, to: peerStore, peerID: local)
      if transferring {
        let workspace = try peerStore.loadIndex(), before = try peerStore.loadBoard(items: workspace.items)
        var after = before
        XCTAssertTrue(after.deleteItem(itemID, from: boardID, kind: .notebook,
          spatialInk: .init(stamp: before.stamp), actor: peer))
        XCTAssertTrue(after.addItem(itemID, to: childID, near: .zero, actor: peer))
        _ = try peerStore.saveBoardEdits(before: before, after: after)
      } else { _ = try peerStore.deleteTestItem(itemID: itemID, actor: peer) }
    }
    let canvas = MacCanvasNavigationView(model: model)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1_000, height: 800),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = canvas; window.orderBack(nil)
    defer { canvas.uninstall(); window.contentView = nil; window.close() }
    func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(.init(x: x, y: y), to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    let initial = try XCTUnwrap(model.presence)
    window.sendEvent(try event(.leftMouseDown, 200, 200))
    window.sendEvent(try event(.leftMouseDragged, 230, 220))
    let first = try XCTUnwrap(model.presence)
    XCTAssertNotEqual(first.camera, initial.camera)
    window.sendEvent(try event(.leftMouseDragged, 260, 240))
    let observed = try XCTUnwrap(model.presence)
    XCTAssertNotEqual(observed.camera, first.camera, "Ordinary successive samples keep one mouse owner")
    XCTAssertEqual(model.presencePhase, .active)
    XCTAssertEqual(observed.focusedItemID, itemID)
    let pins = [boardID: [itemID]]
    // As in the iPad retirement fixture, publish an already committed incoming
    // Core cut while the native camera still owns its original mouse-down.
    // Transport admission is a separate gate; no local native write bypasses it.
    let state = try await model.performStoreCommand { store in
      try NotebookPeerFixture.copy(from: peerStore, to: store, peerID: peer)
      return try NotebookSceneState.read(store: store, presence: observed,
        viewport: observed.viewport, pinnedItems: pins)
    }
    if transferring { XCTAssertEqual(state.transferredPinnedItems, [itemID: childID]) }
    else { XCTAssertEqual(state.missingPinnedItems, [itemID]) }
    model.prepareComposition(presence: observed, frame: nil, pinned: [.item(itemID)],
      displayScale: 1, installedItemOwners: [itemID: boardID])
    XCTAssertTrue(model.acceptExternalScene(state, observedEpoch: model.collaborationReadEpoch,
      observedPresence: observed, observedPreparation: observed, itemPins: pins))
    let normalized = try XCTUnwrap(model.presence)
    XCTAssertEqual(model.presencePhase, .settled)
    XCTAssertNil(normalized.focusedItemID)
    if transferring { XCTAssertEqual(normalized.selectedItemID, itemID) }
    else { XCTAssertNotEqual(normalized.selectedItemID, itemID) }
    if sendsLateDrag {
      window.sendEvent(try event(.leftMouseDragged, 290, 260))
      XCTAssertEqual(model.presence, normalized, "A late drag cannot revive the retired semantic owner")
      XCTAssertEqual(model.presencePhase, .settled)
    }
    // A late lift belongs to the revoked sequence, not any replacement owner.
    model.updatePresence(normalized, settled: false)
    model.selectWorkspaceItem(childID, boardID: boardID)
    let selected = model.selectionSession.target
    XCTAssertNotNil(selected)
    window.sendEvent(try event(.leftMouseUp, 200, 200))
    XCTAssertEqual(model.presence, normalized)
    XCTAssertEqual(model.presencePhase, .active, "The old lift cannot settle another camera owner")
    XCTAssertEqual(model.selectionSession.target, selected, "A direct late lift at the old down point cannot clear the new selection")
    model.updatePresence(normalized, settled: true)
    try await fixture.waitUntil { !model.inputGate.isActive }
    window.sendEvent(try event(.leftMouseDown, 200, 200))
    window.sendEvent(try event(.leftMouseDragged, 240, 230))
    XCTAssertNotEqual(model.presence?.camera, normalized.camera, "Revocation cannot disable the next ordinary mouse drag")
    XCTAssertNil(model.presence?.focusedItemID)
    XCTAssertEqual(model.presence?.selectedItemID, normalized.selectedItemID)
    window.sendEvent(try event(.leftMouseUp, 240, 230))
    XCTAssertEqual(model.presencePhase, .settled)
  }

  func testClosingLastWindowDoesNotTerminateSharedOwner() {
    let lifecycle = NotebookMacLifecycle()
    XCTAssertFalse(lifecycle.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
  }
}
