import NotebookCore
import Darwin
import XCTest
@testable import Notebook

final class NotebookPersistenceTests: XCTestCase {
  private enum TestFailure: Error { case unavailable }

  @MainActor
  func testNativeCommitAdvancesRenderIdentityWithoutReplacingTheCameraOrLocalOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    let item = try XCTUnwrap(model.presence?.selectedItemID)
    let before = try XCTUnwrap(model.workspaceHeader), presence = model.presence
    let center = WorldPoint(x: 140, y: -110)
    model.moveItem(item, to: center)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let after = try XCTUnwrap(model.workspaceHeader)
    XCTAssertGreaterThan(after.cursor, before.cursor,
      "A native write equal to its optimistic value is still a new durable render revision")
    XCTAssertEqual(after, try model.store.workspaceHeader())
    XCTAssertEqual(model.board?.focusedCenter(of: item), center)
    XCTAssertEqual(model.presence, presence)
  }

  @MainActor
  func testRejectedCommandDoesNotWakeDeliveryOrExecutorAsIfItCommitted() async throws {
    enum Rejected: Error { case sourceConflict }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    var commits = 0
    queue.onCommit = { _ in commits += 1 }
    do {
      let _: Bool = try await queue.submit(publishesChanges: true) { _ in throw Rejected.sourceConflict }
      XCTFail("The rejected command cannot report success")
    } catch Rejected.sourceConflict { }
    let saved = await queue.flush()
    XCTAssertTrue(saved, "A domain rejection does not poison the native input queue")
    XCTAssertEqual(commits, 0, "No commit notification may create a retry loop after a rejected command")
  }

  @MainActor
  func testContentCommandDrainsTheLatestPencilGeneration() {
    let gate = NotebookInputGate(), page = UUID(), pencil = UUID()
    var tails: [NotebookInputCompletion] = []
    gate.registerPageFinisher(source: page) { _, completion in tails.append(completion) }
    gate.setCurrentPageSource(page, isCurrent: true)
    var ran = false
    gate.performAfterPageInput { ran = true }
    XCTAssertEqual(tails.count, 1)
    gate.beginPencilAction(source: pencil)
    gate.endPencilAction(source: pencil)
    tails.removeFirst()()
    XCTAssertFalse(ran, "The old tail cannot release a command past a new lifted contact")
    XCTAssertEqual(tails.count, 1)
    tails.removeFirst()()
    XCTAssertTrue(ran)
    gate.unregisterPageFinisher(source: page)
  }

  @MainActor
  func testDeletionWaitsAgainForASecondAlreadyLiftedPencilContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    _ = model.createNotebook(at: .init(x: 1_000, y: 0))
    let initiallySaved = await model.finishPendingPersistence()
    XCTAssertTrue(initiallySaved)
    let pageSource = UUID(), pencilSource = UUID()
    let secondDrain = expectation(description: "The new serialization tail must also drain")
    var finishes = 0
    var held: [NotebookInputCompletion] = []
    var mayFinish = false
    model.inputGate.registerPageFinisher(source: pageSource) { _, completion in
      finishes += 1
      if finishes == 1 {
        completion()
        model.inputGate.beginPencilAction(source: pencilSource)
        model.inputGate.endPencilAction(source: pencilSource)
      } else if mayFinish {
        completion()
      } else {
        held.append(completion)
        if finishes == 2 { secondDrain.fulfill() }
      }
    }
    model.inputGate.setCurrentPageSource(pageSource, isCurrent: true)
    let deletion = Task { await model.deleteItem(first) }
    await fulfillment(of: [secondDrain], timeout: 2)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertFalse(model.isItemBeingDeleted(first))
    XCTAssertTrue(model.workspace?.items.contains { $0.id == first } == true,
      "A lifted contact still owns its accepted, unpublished ink")
    mayFinish = true
    for completion in held { completion() }
    held = []
    let deleted = await deletion.value
    XCTAssertTrue(deleted)
    model.inputGate.unregisterPageFinisher(source: pageSource)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  @MainActor
  func testDeletionRechecksPencilAfterItsContinuationResumes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    _ = model.createNotebook(at: .init(x: 1_000, y: 0))
    let initiallySaved = await model.finishPendingPersistence()
    XCTAssertTrue(initiallySaved)
    let pageSource = UUID(), pencilSource = UUID()
    let resumed = expectation(description: "The finisher resumes before the next Pencil-down")
    var finishes = 0
    model.inputGate.registerPageFinisher(source: pageSource) { _, completion in
      finishes += 1
      completion()
      if finishes == 1 {
        model.inputGate.beginPencilAction(source: pencilSource)
        resumed.fulfill()
      }
    }
    model.inputGate.setCurrentPageSource(pageSource, isCurrent: true)
    let deletion = Task { await model.deleteItem(first) }
    await fulfillment(of: [resumed], timeout: 2)
    // Let the resumed deletion run while the new contact still owns its frame.
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertFalse(model.isItemBeingDeleted(first))
    XCTAssertTrue(model.workspace?.items.contains { $0.id == first } == true)
    model.inputGate.endPencilAction(source: pencilSource)
    let deleted = await deletion.value
    XCTAssertTrue(deleted)
    XCTAssertGreaterThanOrEqual(finishes, 2)
    model.inputGate.unregisterPageFinisher(source: pageSource)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  @MainActor
  func testSelectionAndBoardEditDuringDeletionKeepTheirLaterCausalVersions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    let second = try XCTUnwrap(model.createNotebook(at: .init(x: 1_000, y: 0)))
    let third = try XCTUnwrap(model.createNotebook(at: .init(x: 2_000, y: 0)))
    model.selectItem(first)
    let initialSaved = await model.finishPendingPersistence()
    XCTAssertTrue(initialSaved)
    let counter = try XCTUnwrap(model.workspace?.stamp.counter)
    let firstPage = try XCTUnwrap(model.workspace?.selectedPageID)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let deletion = Task { await model.deleteItem(first) }
    let deadline = ContinuousClock.now + .seconds(2)
    while model.workspace?.stamp.counter == counter, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(try XCTUnwrap(model.workspace?.stamp.counter), counter,
      "A suspended deletion reserves its clock before another human command")
    XCTAssertTrue(model.isItemBeingDeleted(first))
    XCTAssertNil(model.selectNotebookPage(1, notebookID: first),
      "A deleted notebook cannot accept a new page behind its deletion fence")
    XCTAssertNil(model.reserveDrawingAction(pageID: firstPage))
    model.selectItem(third)
    let moved = WorldPoint(x: 1_100, y: 200)
    model.moveItem(second, to: moved)
    let current = try XCTUnwrap(model.presence)
    var nextPresence = SessionPresence(boardID: current.boardID, mode: .cover,
      camera: .init(center: .init(x: 2_000, y: 0), scale: 0.5), viewport: current.viewport,
      focusedItemID: third, openProgress: 0)
    nextPresence = nextPresence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(nextPresence, settled: true)
    try lock.release()
    let deleted = await deletion.value
    XCTAssertTrue(deleted)
    XCTAssertFalse(model.isItemBeingDeleted(first))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let index = try model.store.loadIndex()
    XCTAssertEqual(index.selectedItemID, third)
    XCTAssertEqual(model.workspace?.selectedItemID, third)
    XCTAssertFalse(index.items.contains { $0.id == first })
    let resolvedPage = try XCTUnwrap(index.item(id: third)?.pageIDs.first)
    XCTAssertEqual(model.presence, nextPresence.selecting(itemID: third, pageID: resolvedPage),
      "Addressed selection resolves the unknown page without changing the exact camera")
    let board = try model.store.loadBoard(items: index.items)
    XCTAssertEqual(board.board(index.rootBoardID)?.focusedCenter(of: second), moved)
  }

  @MainActor
  func testContactReleaseCannotOvertakeItsAcceptedInk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    let queue = NotebookPersistenceQueue(store: store)
    let log = root.appendingPathComponent("order")
    let owner = UUID(), page = UUID()
    for (key, value) in [(NotebookPersistenceQueue.Owner.page(page), "previous ink"),
      (.inputActivity(owner), "active"), (.page(page), "ink"), (.inputActivity(owner), "released")] {
      queue.enqueue(owner: key) { _ in
        let previous = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try (previous + value + "\n").write(to: log, atomically: true, encoding: .utf8)
        return false
      }
    }
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "previous ink\nactive\nink\nreleased\n")
  }

  @MainActor
  func testCreationCannotOvertakeAnAcceptedBoardMove() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    let center = WorldPoint(x: -30_000, y: -30_000)
    model.moveItem(first, to: center)
    let portal = try XCTUnwrap(model.createBoard(at: .zero))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let workspace = try model.store.loadIndex()
    let board = try model.store.loadBoard(items: workspace.items)
    XCTAssertNotNil(board.board(portal))
    XCTAssertEqual(board.board(workspace.rootBoardID)?.focusedCenter(of: first), center)
    XCTAssertEqual(model.workspaceHeader?.boardRevision, try model.store.workspaceHeader().boardRevision)
    XCTAssertEqual(model.boardHierarchy?.board(portal)?.stamp, board.board(portal)?.stamp)
  }

  @MainActor
  func testFirstStrokeOfProvisionalPageSurvivesDelayedCreationAndReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initialSaved = await model.finishPendingPersistence()
    XCTAssertTrue(initialSaved)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: item), 1)
    let pageID = try XCTUnwrap(model.activePage?.id)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
    let action = PageInkAction(tool: .pen, samples: [
      .init(point: .init(x: 20, y: 30), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
      .init(point: .init(x: 120, y: 130), timeOffset: 0.1, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    ])
    let accepted = await model.acceptDrawingAction(action, pageID: pageID, stamp: stamp).value
    XCTAssertNotNil(accepted, "The contact finishes without waiting for the storage lock")
    try lock.release()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertNil(model.persistenceFailure)
    let restored = try PageInkDrawing.decode(store.loadPage(pageID).drawingData)
    XCTAssertEqual(restored.activeActions.map(\.id), [action.id])
    XCTAssertTrue(try store.loadIndex().items.contains { $0.pageIDs.contains(pageID) })
  }

  @MainActor
  func testPeerDisconnectCannotBeOvertakenByAcceptedActiveContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let peer = UUID(), generation = UUID()
    model.peerConnected(.init(deviceID: peer, workspaceID: try model.store.workspaceHeader().workspaceID,
      displayName: "Test Mac"), generation: generation)
    let activity = NotebookInputActivity(deviceID: peer, sessionID: UUID(), sequence: 1,
      targets: [.init(kind: .board, id: WorkspaceRoot.boardID)])
    model.receivePeerTransient(.inputActivity(activity), peerID: peer, generation: generation)
    model.peerDisconnected(peerID: peer, generation: generation)
    model.receivePeerTransient(.inputActivity(activity), peerID: peer, generation: generation)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertFalse(model.peerInputIsActive)
    XCTAssertFalse(try model.store.inputActivities().contains { $0.deviceID == peer })
  }

  @MainActor
  func testCreationFencePrecedesFirstStrokeAndFailedWriteIsRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    let queue = NotebookPersistenceQueue(store: store)
    let ready = root.appendingPathComponent("ready")
    let owner = root.appendingPathComponent("owner")
    let ink = root.appendingPathComponent("ink")
    queue.enqueue { _ in
      guard FileManager.default.fileExists(atPath: ready.path) else { throw TestFailure.unavailable }
      try Data("page".utf8).write(to: owner)
      return false
    }
    queue.enqueue(owner: .page(UUID())) { _ in
      XCTAssertTrue(FileManager.default.fileExists(atPath: owner.path))
      try Data("first stroke".utf8).write(to: ink)
      return false
    }
    let failed = await queue.flush()
    XCTAssertFalse(failed)
    XCTAssertNotNil(queue.failure)
    XCTAssertEqual(queue.pendingCount, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ink.path))
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertNil(queue.failure)
    XCTAssertEqual(try String(contentsOf: ink, encoding: .utf8), "first stroke")
  }

  @MainActor
  func testCoalescingDoesNotCrossCreationOrDisconnectFence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    let queue = NotebookPersistenceQueue(store: store)
    let peer = UUID(), session = UUID()
    let board = CollaborationTarget(kind: .board, id: WorkspaceRoot.boardID)
    let active = NotebookInputActivity(deviceID: peer, sessionID: session, sequence: 1, targets: [board])
    queue.enqueue(owner: .inputActivity(peer)) { try $0.saveInputActivity(active); return false }
    queue.enqueue { try $0.resetInputActivities(); return false }
    let inactive = NotebookInputActivity(deviceID: peer, sessionID: UUID(), sequence: 1, targets: [])
    queue.enqueue(owner: .inputActivity(peer)) { try $0.saveInputActivity(inactive); return false }
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(try store.inputActivities(), [inactive])
  }

  @MainActor
  func testQueuedCommandReceivesFailureWithoutLosingDurablePredecessor() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let queue = NotebookPersistenceQueue(store: store)
    queue.enqueue { _ in throw TestFailure.unavailable }
    do {
      let _: Int = try await queue.submit { _ in XCTFail("A command cannot overtake a failed save"); return 1 }
      XCTFail("Expected explicit persistence failure")
    } catch { XCTAssertNotNil(queue.failure) }
    XCTAssertEqual(queue.pendingCount, 1)
  }
}
