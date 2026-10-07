import Foundation
import XCTest
@testable import NotebookCore
@testable import Notebook

@MainActor
final class NotebookItemCreationTests: XCTestCase {
  private struct Fixture {
    let model: NotebookAppModel
    let queue: NotebookPersistenceQueue
    let store: NotebookStore
  }

  private func fixture(limits: NotebookPersistenceAdmission.Limits = .init(),
    makeStore: ((URL) -> NotebookStore)? = nil) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-creation-" + UUID().uuidString)
    let domain = "Notebook.ItemCreation." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
    addTeardownBlock { preferences.removePersistentDomain(forName: domain) }
    let store = makeStore?(root) ?? NotebookStore(root: root)
    let queue = NotebookPersistenceQueue(store: store, admissionLimits: limits)
    let model = NotebookAppModel(store: store, startsNearbySync: false, preferences: preferences, persistenceQueue: queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    model.updatePresence(.init(boardID: board, mode: .board, camera: .init(), viewport: .init(x: 1194, y: 834)), settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    return .init(model: model, queue: queue, store: store)
  }

  func testByteAndCountRefusalPrecedeEveryKindOfSourceTaskAndPresenceChange() async throws {
    let kinds: [NotebookNativeItemCreation.Kind] = [.notebook(NotebookAppModel.defaultPageSize), .document(.book), .board]
    for kind in kinds {
      let budget = NotebookNativeItemCreation.cost(for: kind)
      let f = try await fixture(limits: .init(maximumBytes: budget.payloadBytes + budget.completionBytes - 1))
      let before = f.model.workspace, board = f.model.boardHierarchy, presence = f.model.presence
      let navigation = f.model.navigationGeneration
      let cursor = try f.store.currentChangeCursor()
      XCTAssertNil(f.model.beginItemCreation(kind: kind, at: .zero))
      XCTAssertEqual(f.queue.pendingCount, 0); XCTAssertEqual(f.queue.reservedWriteBytes, 0)
      XCTAssertEqual(f.model.workspace, before); XCTAssertEqual(f.model.boardHierarchy, board)
      XCTAssertEqual(f.model.presence, presence); XCTAssertEqual(try f.store.currentChangeCursor(), cursor)
      XCTAssertEqual(f.model.navigationGeneration, navigation)
    }
    let f = try await fixture(), presence = f.model.presence, cursor = try f.store.currentChangeCursor()
    let navigation = f.model.navigationGeneration
    var held: [NotebookPersistenceAdmission.Reservation] = []
    defer { for reservation in held { f.queue.releaseWriteReservation(reservation) } }
    for _ in 0..<512 { held.append(try XCTUnwrap(f.queue.reserveWrite(.init(payloadBytes: 1)))) }
    XCTAssertEqual(f.queue.reservedContactCount, 512)
    for kind in kinds { XCTAssertNil(f.model.beginItemCreation(kind: kind, at: .zero)) }
    XCTAssertEqual(f.queue.pendingCount, 0); XCTAssertEqual(f.queue.reservedContactCount, 512)
    XCTAssertEqual(f.model.presence, presence); XCTAssertEqual(try f.store.currentChangeCursor(), cursor)
    XCTAssertEqual(f.model.navigationGeneration, navigation)
  }

  func testThreeRapidCreatesSelectOnlyCommittedIdentitiesAndRetainOneActionPerBirth() async throws {
    let f = try await fixture(), before = f.model.presence
    let blocker = try NotebookSQLWriteBlocker(store: f.store)
    defer { try? blocker.release() }
    let notebook = try XCTUnwrap(f.model.beginItemCreation(kind: .notebook(NotebookAppModel.defaultPageSize), at: .zero))
    let document = try XCTUnwrap(f.model.beginItemCreation(kind: .document(.book), at: .init(x: 1500, y: 0)))
    let board = try XCTUnwrap(f.model.beginItemCreation(kind: .board, at: .init(x: 3000, y: 0)))
    XCTAssertEqual(f.model.presence, before)
    XCTAssertEqual(f.model.workspace?.items.count, 1, "No optimistic copy can fabricate a material owner")
    XCTAssertEqual(f.queue.reservedContactCount, 0)
    XCTAssertEqual(f.queue.acceptedPayloadBytes > 0, true)
    try blocker.release()
    let notebookResult = await f.model.finishItemCreation(notebook), documentResult = await f.model.finishItemCreation(document)
    let boardResult = await f.model.finishItemCreation(board)
    let notebookID = try XCTUnwrap(notebookResult), documentID = try XCTUnwrap(documentResult), boardID = try XCTUnwrap(boardResult)
    XCTAssertEqual(try f.store.readItemHeader(notebookID)?.kind, .notebook)
    XCTAssertEqual(try f.store.readItemHeader(documentID)?.kind, .document)
    XCTAssertEqual(try f.store.readItemHeader(boardID)?.kind, .board)
    XCTAssertEqual(f.model.presence?.selectedItemID, boardID)
    XCTAssertEqual(try f.store.loadPresence().selectedItemID, boardID)
    XCTAssertEqual(f.queue.reservedWriteBytes, 0)
    for id in [notebookID, documentID, boardID] {
      let history = try f.store.nativeHistory(domain: .cover(id), actor: f.model.actorID)
      XCTAssertEqual(history.count, 1)
      guard case .command(let actionID) = history.first else { return XCTFail("Birth must retain its native action identity") }
      XCTAssertNotNil(try f.store.collaborationActionIfPresent(actionID))
    }
  }

  func testLostCommitKeepsTheSamePendingBirthAcrossAPeerMoveAndUserRetry() async throws {
    enum Fault: Error { case completion }
    var block: URL?
    let f = try await fixture { root in
      let path = root.appendingPathComponent("lost-birth-commit"); block = path
      return NotebookStore(root: root) { if $0 == .afterCommit, FileManager.default.fileExists(atPath: path.path) { throw Fault.completion } }
    }
    let marker = try XCTUnwrap(block), before = f.model.presence, board = try XCTUnwrap(before?.boardID)
    let healthy = NotebookStore(root: f.store.root), baseline = Set(try healthy.readItemHeaders(limit: 8).map(\.id))
    try Data().write(to: marker)
    defer { try? FileManager.default.removeItem(at: marker); f.model.retryPendingPersistence() }
    let failed = expectation(description: "Storage failure keeps the same accepted birth")
    let observer = f.queue.onFailureChange
    f.queue.onFailureChange = { value in observer?(value); if value != nil { failed.fulfill() } }
    let creation = try XCTUnwrap(f.model.beginItemCreation(kind: .document(.article), at: .zero))
    await fulfillment(of: [failed], timeout: 3)
    XCTAssertEqual(f.model.presence, before); XCTAssertGreaterThan(f.queue.reservedWriteBytes, 0)
    let born = try XCTUnwrap(try healthy.readItemHeaders(limit: 8).first { !baseline.contains($0.id) })
    let history = try healthy.nativeHistory(domain: .cover(born.id), actor: f.model.actorID)
    guard case .command(let birthActionID) = try XCTUnwrap(history.first) else { return XCTFail("Missing committed birth") }
    let birthReceipt = try XCTUnwrap(try healthy.collaborationActionIfPresent(birthActionID))
    let placements = try XCTUnwrap(try healthy.readBoardItem(born.id)).board.placements
    let peerMove = try NotebookNativeCommand([.init(kind: .moveItem, target: .init(kind: .board, id: board),
      id: born.id.uuidString, values: ["center": try .encode(WorldPoint(x: 400, y: 300))])], summary: "Peer moves committed birth",
      placements: placements, actor: UUID()).apply(to: healthy)
    let cursor = try healthy.currentChangeCursor()
    try FileManager.default.removeItem(at: marker); f.model.retryPendingPersistence()
    let actual = await f.model.finishItemCreation(creation)
    let saved = await f.model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(actual, born.id); XCTAssertEqual(f.model.presence?.selectedItemID, born.id)
    XCTAssertEqual(try healthy.readBoardItem(born.id)?.board.placement(of: born.id)?.center, WorldPoint(x: 400, y: 300))
    XCTAssertEqual(try healthy.collaborationActionIfPresent(birthActionID), birthReceipt)
    // Scene publication acknowledges the peer's exact action on iPad. That
    // delivery record is legitimate; Retry cannot rewrite birth or material.
    let acknowledgementAddresses = Set([birthActionID, peerMove.receipt.id].map {
      "collaboration/delivery/" + $0.uuidString.lowercased() + ".json#"
    })
    try healthy.readTransaction { _ in
      let through = try healthy.currentChangeCursor(), journal = try healthy.changeJournal(after: cursor, limit: 4)
      XCTAssertLessThanOrEqual(journal.count, 2)
      XCTAssertEqual(journal.last?.sequence ?? cursor, through)
      for change in journal {
        let records = try healthy.readChangedAddresses(after: change.sequence - 1, through: change.sequence, limit: 3)
        XCTAssertFalse(records.hasMore); XCTAssertFalse(records.records.isEmpty)
        XCTAssertTrue(records.records.allSatisfy { acknowledgementAddresses.contains($0.address) && $0.afterHash != nil },
          "Retry published unexpected records: \(records.addresses)")
      }
    }
    #if os(iOS)
    for receipt in [birthReceipt, peerMove.receipt] {
      let received = try XCTUnwrap(try healthy.deviceActionReceipts(actionIDs: [receipt.id]).first)
      XCTAssertEqual(received.deviceID, f.model.actorID)
      XCTAssertTrue(received.matches(receipt, version: try receipt.deliveryVersion()))
    }
    #endif
    XCTAssertEqual(f.queue.reservedWriteBytes, 0)
    XCTAssertEqual(try healthy.nativeHistory(domain: .cover(born.id), actor: f.model.actorID), history)
  }

  func testTwoRapidBirthsWaitForMenuLiftAndOnlyTheLatestMayPresentItsCover() async throws {
    let f = try await fixture(), before = f.model.presence, contact = UUID()
    f.model.inputGate.beginContact(source: contact)
    defer { f.model.inputGate.endContact(source: contact) }
    let blocker = try NotebookSQLWriteBlocker(store: f.store)
    defer { try? blocker.release() }
    let first = try XCTUnwrap(f.model.beginItemCreation(kind: .notebook(NotebookAppModel.defaultPageSize), at: .zero))
    let firstNavigation = f.model.navigationGeneration
    let second = try XCTUnwrap(f.model.beginItemCreation(kind: .board, at: .init(x: 1500, y: 0)))
    let secondNavigation = f.model.navigationGeneration
    let oldPresentation = Task { await f.model.prepareItemCreationPresentation(first, navigation: firstNavigation) }
    var presented: UUID?
    let newPresentation = Task { presented = await f.model.prepareItemCreationPresentation(second, navigation: secondNavigation) }
    XCTAssertEqual(f.model.presence, before)
    try blocker.release()
    let firstResult = await first.value, secondResult = await second.value
    let firstID = try XCTUnwrap(firstResult), secondID = try XCTUnwrap(secondResult)
    let obsolete = await oldPresentation.value
    XCTAssertNil(obsolete); XCTAssertNil(presented)
    XCTAssertTrue(f.model.inputGate.isActive)
    XCTAssertEqual(f.model.presence?.camera, before?.camera)
    XCTAssertNotNil(try f.store.readItemHeader(firstID)); XCTAssertNotNil(try f.store.readItemHeader(secondID))
    f.model.inputGate.endContact(source: contact)
    await newPresentation.value
    XCTAssertEqual(presented, secondID); XCTAssertEqual(f.model.presence?.selectedItemID, secondID)
    XCTAssertNotNil(f.model.workspace?.item(id: secondID))
    XCTAssertEqual(f.model.presence?.camera, before?.camera)
    XCTAssertEqual(f.queue.reservedWriteBytes, 0)
  }

  func testColdCoverUndoAndParentRedoReachTheSameCommittedBirthForEveryKind() async throws {
    for kind: NotebookNativeItemCreation.Kind in [.notebook(NotebookAppModel.defaultPageSize), .document(.book), .board] {
      let f = try await fixture()
      let created = await f.model.finishItemCreation(f.model.beginItemCreation(kind: kind, at: .zero))
      let id = try XCTUnwrap(created), before = try XCTUnwrap(f.model.presence)
      let header = try XCTUnwrap(try f.store.readItemHeader(id))
      f.model.updatePresence(.init(boardID: before.boardID, mode: .cover, camera: before.camera,
        viewport: before.viewport, focusedItemID: id, selectedItemID: id, notebookPageID: header.firstPageID), settled: true)
      let closed = await f.model.shutdown(); XCTAssertTrue(closed)
      let cold = NotebookAppModel(store: .init(root: f.store.root), startsNearbySync: false, preferences: f.model.preferences)
      retainNotebookUntilTeardown(cold, removing: f.store.root)
      await cold.start(pageSize: NotebookAppModel.defaultPageSize)
      XCTAssertEqual(cold.actorID, f.model.actorID)
      XCTAssertEqual(cold.presence?.mode, .cover); XCTAssertEqual(cold.presence?.focusedItemID, id)
      cold.undoLastSurfaceAction()
      let undone = await cold.finishPendingPersistence(); XCTAssertTrue(undone, cold.persistenceFailure ?? "")
      await cold.reloadExternalChanges()?.value
      XCTAssertNil(try cold.store.readItemHeader(id)); XCTAssertNil(try cold.store.ownerBoardID(of: id))
      XCTAssertEqual(cold.presence?.mode, .board); XCTAssertEqual(cold.presence?.boardID, before.boardID)
      cold.redoLastSurfaceAction()
      let repeated = await cold.finishPendingPersistence(); XCTAssertTrue(repeated, cold.persistenceFailure ?? "")
      await cold.reloadExternalChanges()?.value
      XCTAssertEqual(try cold.store.readItemHeader(id)?.kind, kind.itemKind)
      XCTAssertEqual(try cold.store.readItemHeader(id)?.firstPageID, header.firstPageID)
      XCTAssertEqual(try cold.store.ownerBoardID(of: id), before.boardID)
      try cold.store.collaborationContent().validate()
      let finished = await cold.shutdown(); XCTAssertTrue(finished)
    }
  }

  func testParentRetiredAfterAdmissionCannotLeaveANewOwnerOrSelection() async throws {
    let f = try await fixture()
    let childResult = await f.model.createBoard(at: .zero), child = try XCTUnwrap(childResult)
    XCTAssertTrue(f.model.enterBoard(child))
    let initialSaved = await f.model.finishPendingPersistence(); XCTAssertTrue(initialSaved)
    let gate = CreationGate(), cost = NotebookPersistenceAdmission.Cost(payloadBytes: 1024)
    let reservation = try XCTUnwrap(f.queue.reserveWrite(cost))
    let fence = try f.queue.enqueuePreparedCommand(reservation: reservation, Task {
      await gate.wait()
      return NotebookPersistenceQueue.PreparedCommand(cost: cost, operation: { _ in true })
    })
    while !gate.entered { await Task.yield() }
    let before = f.model.presence, count = try f.store.workspaceHeader().itemCount
    let creation = try XCTUnwrap(f.model.beginItemCreation(kind: .document(.article), at: .zero))
    let healthy = NotebookStore(root: f.store.root)
    let placement = try XCTUnwrap(try healthy.readBoardItem(child)?.board.placements.first { $0.id == child })
    let source = try healthy.readNativeDeletionSource(itemID: child,
      boardID: try XCTUnwrap(try healthy.ownerBoardID(of: child)),
      placement: placement, kind: .board, title: "")
    _ = try NotebookNativeCommand(deleting: source, placement: placement, actor: UUID()).apply(to: healthy)
    gate.release(); _ = try await fence.value
    let refused = await f.model.finishItemCreation(creation)
    XCTAssertNil(refused); XCTAssertEqual(f.model.presence, before)
    XCTAssertEqual(try healthy.workspaceHeader().itemCount, count - 1)
    XCTAssertNil(f.queue.failure); XCTAssertEqual(f.queue.reservedWriteBytes, 0)
  }
}

@MainActor private final class CreationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
  func release() { continuation?.resume(); continuation = nil }
}
