import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class SceneItemOwnerRetirementTests: XCTestCase {
  func testPinnedOwnerUsesCanonicalExistenceAndDistinguishesTransferOutsideCoverage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-owner-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try await Task.detached {
      let actor = UUID(), store = NotebookStore(root: root)
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      var workspace = try store.loadIndex()
      let itemID = workspace.selectedItemID
      var hierarchy = try store.loadBoard(items: workspace.items)
      let portal = try XCTUnwrap(workspace.createBoard(title: "Distant child", actor: actor))
      XCTAssertTrue(hierarchy.createBoard(portal.id, in: header.rootBoardID,
        near: .init(x: 1_000_000, y: 1_000_000), actor: actor))
      XCTAssertTrue(hierarchy.moveItem(itemID, in: header.rootBoardID,
        to: .init(x: -1_000_000, y: -1_000_000), actor: actor))
      try store.saveBoardWorkspaceBundle(index: workspace, board: hierarchy, boardID: portal.id)
      let presence = SessionPresence(boardID: header.rootBoardID, mode: .board,
        camera: .init(scale: 0.3), viewport: .init(x: 800, y: 600), selectedItemID: portal.id)
      let withoutPin = try NotebookSceneState.read(store: store, presence: presence,
        viewport: presence.viewport, loadsLiveContent: false)
      let pins = [header.rootBoardID: [itemID]]
      let pinned = try NotebookSceneState.read(store: store, presence: presence,
        viewport: presence.viewport, loadsLiveContent: false, pinnedItems: pins)
      let before = try store.loadBoard(items: workspace.items)
      var after = before
      XCTAssertTrue(after.deleteItem(itemID, from: header.rootBoardID, kind: .notebook,
        spatialInk: .init(stamp: header.stamp), actor: actor))
      XCTAssertTrue(after.addItem(itemID, to: portal.id,
        near: .init(x: -1_000_000, y: -1_000_000), actor: actor))
      _ = try store.saveBoardEdits(before: before, after: after)
      let transferred = try NotebookSceneState.read(store: store, presence: presence,
        viewport: presence.viewport, loadsLiveContent: false, pinnedItems: pins)
      let deletion = try store.deleteWorkspaceItem(itemID: itemID, actor: actor)
      let deleted = try NotebookSceneState.read(store: store, presence: presence,
        viewport: presence.viewport, loadsLiveContent: false, pinnedItems: pins)
      return (itemID, portal.id, withoutPin, pinned, transferred, deleted, deletion.cursor)
    }.value
    let (id, childID, withoutPin, pinned, transferred, deleted, deletionCursor) = result
    XCTAssertNil(withoutPin.workspace.items.first { $0.id == id }, "An ordinary finite window does not include this distant item")
    XCTAssertTrue(withoutPin.missingPinnedItems.isEmpty, "Projection absence is not evidence of deletion")
    XCTAssertNotNil(pinned.workspace.items.first { $0.id == id }, "The explicit physical pin survives viewport culling")
    XCTAssertTrue(pinned.missingPinnedItems.isEmpty)
    XCTAssertTrue(pinned.transferredPinnedItems.isEmpty)
    XCTAssertTrue(transferred.missingPinnedItems.isEmpty, "A still-existing item transferred to another board is not deleted")
    XCTAssertEqual(transferred.transferredPinnedItems, [id: childID])
    XCTAssertNil(transferred.hierarchy.board(childID)?.placement(of: id), "The new placement lies outside the child projection as well")
    XCTAssertGreaterThan(transferred.header.cursor, pinned.header.cursor)
    XCTAssertEqual(deleted.missingPinnedItems, [id])
    XCTAssertTrue(deleted.transferredPinnedItems.isEmpty)
    XCTAssertEqual(deleted.header.cursor, deletionCursor, "The removal proof belongs to the same WAL cut as the returned scene")
  }

  func testAddressedPhysicalPinsRejectOversizeAndDuplicatedRequestsBeforeReadingSQL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-pin-limit-" + UUID().uuidString)
    let store = NotebookStore(root: root), boardID = UUID(), repeated = UUID()
    for pins in [[boardID: (0..<8).map { _ in UUID() }], [boardID: [repeated], UUID(): [repeated]]] {
      do {
        _ = try await Task.detached { try NotebookSceneState.read(store: store, presence: nil,
          viewport: .init(x: 800, y: 600), pinnedItems: pins) }.value
        XCTFail("The requested pin set must be bounded before any database work")
      } catch NotebookStorageError.limitExceeded(let owner) { XCTAssertEqual(owner, "scene_item_pins") }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testLocalDeletionNotifiesTheCurrentPhysicalOwnerOnlyAfterAcceptedPencilAndSQLCommit() async throws {
    let model = try await makeModel()
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    _ = try XCTUnwrap(model.createNotebook(at: .init(x: 1_000, y: 0)))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let oldBinding = UUID(), currentBinding = UUID(), pencil = UUID()
    var notices: [(UUID, UUID, UInt64)] = []
    model.bindItemOwnerObserver(owner: oldBinding) { _, _, _ in XCTFail("The replaced view cannot receive a later deletion") }
    model.bindItemOwnerObserver(owner: currentBinding) { notices.append(($0, $1, $2)) }
    model.unbindItemOwnerObserver(owner: oldBinding)
    model.inputGate.beginPencilAction(source: pencil)
    defer { model.inputGate.endPencilAction(source: pencil) }
    model.prepareComposition(presence: try XCTUnwrap(model.presence), frame: nil,
      pinned: [.item(itemID)], displayScale: 1, installedItemOwners: [itemID: boardID])
    let deletion = Task { await model.deleteItem(itemID) }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(notices.isEmpty)
    XCTAssertFalse(model.isItemBeingDeleted(itemID), "The accepted physical contact drains before deletion starts")
    model.inputGate.endPencilAction(source: pencil)
    let deleted = await deletion.value
    XCTAssertTrue(deleted, model.persistenceFailure ?? "Deletion did not commit")
    XCTAssertEqual(notices.count, 1)
    let notice = try XCTUnwrap(notices.first)
    XCTAssertEqual(notice.0, itemID); XCTAssertEqual(notice.1, boardID)
    let durable = try await model.performStoreCommand { store in
      (try store.readItemHeader(itemID) == nil, try store.workspaceHeader().cursor)
    }
    XCTAssertTrue(durable.0)
    XCTAssertGreaterThanOrEqual(durable.1, notice.2)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(notices.count, 1, "A local command already consumed this exact pinned placement")
    model.unbindItemOwnerObserver(owner: currentBinding)
  }

  func testPeerDeletionPublishesItsAddressedProofOnlyAfterThePencilFence() async throws {
    let model = try await makeModel()
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    _ = try XCTUnwrap(model.createNotebook(at: .init(x: 1_000, y: 0)))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let presence = try XCTUnwrap(model.presence), pencil = UUID(), binding = UUID()
    var notices: [(UUID, UUID, UInt64)] = []
    model.bindItemOwnerObserver(owner: binding) { notices.append(($0, $1, $2)) }
    model.inputGate.beginPencilAction(source: pencil)
    defer { model.inputGate.endPencilAction(source: pencil) }
    // The existing preparation request names the engaged physical owner. An
    // active contact prevents preparation itself, but never discards this pin.
    model.prepareComposition(presence: presence, frame: nil, pinned: [.item(itemID)], displayScale: 1)
    let peer = UUID()
    let cursor = try await model.performStoreCommand { store in
      try store.deleteWorkspaceItem(itemID: itemID, actor: peer).cursor
    }
    XCTAssertNil(model.reloadExternalChanges())
    XCTAssertTrue(notices.isEmpty, "A completed external SQL write cannot mutate a leased physical pose")
    model.inputGate.endPencilAction(source: pencil)
    try await reloadAfterPhysicalContact(model)
    let notice = try XCTUnwrap(notices.first, model.persistenceFailure ?? "The accepted reload did not report its missing pin")
    XCTAssertEqual(notices.count, 1)
    XCTAssertEqual(notice.0, itemID); XCTAssertEqual(notice.1, boardID)
    XCTAssertGreaterThanOrEqual(notice.2, cursor)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(notices.count, 1, "An already consumed placement retirement is not replayed by another refresh")
    XCTAssertNil(model.persistenceFailure)
    model.unbindItemOwnerObserver(owner: binding)
  }

  func testPeerTransferUsesTheInstalledOwnerRatherThanTheNewRequestedProjection() async throws {
    let model = try await makeModel()
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let rootID = try XCTUnwrap(model.presence?.boardID)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let presence = SessionPresence(boardID: rootID, mode: .board, camera: .init(scale: 0.3),
      viewport: .init(x: 800, y: 600), selectedItemID: childID)
    model.updatePresence(presence, settled: true)
    let settled = await model.finishPendingPersistence()
    XCTAssertTrue(settled)
    await model.reloadExternalChanges()?.value
    let pencil = UUID(), binding = UUID(), peer = UUID()
    var notices: [(UUID, UUID, UInt64)] = []
    model.bindItemOwnerObserver(owner: binding) { notices.append(($0, $1, $2)) }
    model.inputGate.beginPencilAction(source: pencil)
    defer { model.inputGate.endPencilAction(source: pencil) }
    let state = try await model.performStoreCommand { store in
      let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
      var after = before
      XCTAssertTrue(after.deleteItem(itemID, from: rootID, kind: .notebook,
        spatialInk: .init(stamp: before.stamp), actor: peer))
      XCTAssertTrue(after.addItem(itemID, to: childID, near: .zero, actor: peer))
      _ = try store.saveBoardEdits(before: before, after: after)
      return try NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport,
        loadsLiveContent: false, pinnedItems: [childID: [itemID]])
    }
    let index = WorkspaceSceneIndex(workspace: state.workspace, hierarchy: state.hierarchy, paperSizes: state.paperSizes)
    let nextFrame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: state.hierarchy.portalCamera)
    XCTAssertEqual(nextFrame.index.ownerBoard(itemID: itemID), childID,
      "The requested scene genuinely knows the transferred placement, unlike the still-installed body")
    model.prepareComposition(presence: presence, frame: nextFrame, pinned: [.item(itemID)], displayScale: 1,
      installedItemOwners: [itemID: rootID])
    XCTAssertTrue(notices.isEmpty)
    model.inputGate.endPencilAction(source: pencil)
    try await reloadAfterPhysicalContact(model)
    XCTAssertEqual(notices.count, 1)
    let notice = try XCTUnwrap(notices.first, model.persistenceFailure ?? "The old physical placement was not retired")
    XCTAssertEqual(notice.0, itemID); XCTAssertEqual(notice.1, rootID)
    let owner = try await model.performStoreCommand { try $0.ownerBoardID(of: itemID) }
    XCTAssertEqual(owner, childID, "Retiring the old pose does not delete or move the canonical transferred item")
    XCTAssertNil(model.persistenceFailure)
    model.unbindItemOwnerObserver(owner: binding)
  }

  private func makeModel() async throws -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-retirement-model-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertEqual(model.loadState, .ready)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    return model
  }

  private func reloadAfterPhysicalContact(_ model: NotebookAppModel) async throws {
    XCTAssertFalse(model.inputGate.hasActivePencil)
    // endPencilAction intentionally leaves the broader contact barrier active
    // until UIKit's same-lift callbacks and the page finisher have drained.
    let deadline = ContinuousClock.now + .seconds(2)
    while model.inputGate.isActive, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertFalse(model.inputGate.isActive, "The physical contact did not finish its publication fence")
    let refresh = try XCTUnwrap(model.reloadExternalChanges(), "The completed contact must admit the addressed reload")
    await refresh.value
  }
}
