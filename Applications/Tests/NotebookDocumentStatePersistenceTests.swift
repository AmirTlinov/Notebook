import NotebookCore
import XCTest
@testable import Notebook

final class NotebookDocumentStatePersistenceTests: XCTestCase {
  @MainActor
  func testRuntimeCheckpointWaitsForTheAcceptedWriteAndRejectsANewerContact() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    let version = document.programIdentity(blockID: "a")
    let initial = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .object([:]), programIdentity: version, stateVersion: nil)
    XCTAssertNotNil(initial, "An unchanged durable initial state can release an unvisited runtime")
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    var firstCompleted = false
    let first = Task { @MainActor in
      let receipt = try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(1), programIdentity: version)
      firstCompleted = true
      return receipt
    }
    try await waitForOptimisticValue(model, documentID: documentID, blockID: "a", value: .number(1))
    let admitted = try XCTUnwrap(model.documentStates[documentID]?.records.first { $0.id == "a" }?.valueVersion)
    XCTAssertFalse(firstCompleted, "Optimistic display does not manufacture a durable receipt while the writer is blocked")
    var completed = false
    let checkpoint = Task { @MainActor in
      let value = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
        value: .number(1), programIdentity: version, stateVersion: admitted)
      completed = true
      return value
    }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(completed, "An optimistic UI echo must not release the program before SQLite accepts it")
    let second = Task { @MainActor in
      try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(2), programIdentity: version)
    }
    try await waitForOptimisticValue(model, documentID: documentID, blockID: "a", value: .number(2))
    try lock.release()
    let firstReceipt = try await first.value, secondReceipt = try await second.value
    XCTAssertEqual(firstReceipt, admitted)
    XCTAssertNotNil(secondReceipt)
    let old = try await checkpoint.value
    XCTAssertNil(old, "The old fence cannot retire a runtime after a later accepted contact")
    let current = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .number(2), programIdentity: version, stateVersion: model.documentStates[documentID]?.records.first { $0.id == "a" }?.valueVersion)
    XCTAssertNotNil(current)
    XCTAssertEqual(try model.store.readDocumentBlock(documentID: documentID, blockID: "a")?.state, .number(2))
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    let late = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .number(2), programIdentity: version, stateVersion: current)
    XCTAssertNil(late)
  }

  @MainActor
  func testLargeCheckpointUsesItsRetainedSnapshotAdmissionThroughWriterRetry() async throws {
    final class FailOnce: @unchecked Sendable {
      private let lock = NSLock()
      private var failed = false
      func write() throws {
        try lock.withLock {
          if !failed { failed = true; throw CocoaError(.fileWriteUnknown) }
        }
      }
    }
    var writer: NotebookPersistenceQueue?
    let (model, documentID) = try await makeModel(captureQueue: { writer = $0 })
    let queue = try XCTUnwrap(writer), source = try XCTUnwrap(model.documents[documentID]).programIdentity(blockID: "a")
    let resources = SceneRenderResources.shared
    let bytes = Data(("\"" + String(repeating: "x", count: 10 * 1_024 * 1_024) + "\"").utf8)
    let cost = bytes.count * 8 + 64
    let before = resources.rasterAdmission
    let available = min(before.byteLimit - before.heldBytes,
      before.passiveByteLimit - before.pinnedBytes - before.passiveReservedBytes)
    // Leave one snapshot plus one small transfer window on either platform.
    // A second full-state reservation cannot fit until this snapshot releases.
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(available - cost - 1_024 * 1_024, priority: .passive))
    defer { pressure.release() }
    var transfer: NotebookProgramStateTransfer? = NotebookProgramStateTransfer(resources: resources)
    weak var retainedTransfer = transfer
    let baseline = resources.rasterAdmission.heldBytes
    let initialCredit = try XCTUnwrap(transfer).initialCredit
    var snapshot: NotebookProgramStateTransfer.Checkpoint? = try await transfer!.checkpoint(
      .init(revision: "frozen", units: bytes.count, cost: cost)) { _, offset in
        String(decoding: bytes[offset..<min(bytes.count, offset + 262_144)], as: UTF8.self)
      }
    transfer = nil
    XCTAssertNotNil(retainedTransfer, "The frozen snapshot retains its admitted transfer owner")
    XCTAssertEqual(resources.rasterAdmission.heldBytes, baseline + cost - initialCredit)
    let failure = FailOnce()
    queue.enqueue { _ in try failure.write(); return false }
    let failed = await queue.flush()
    XCTAssertFalse(failed)
    var completed = false
    let value = try XCTUnwrap(snapshot).value
    let checkpoint = Task { @MainActor in
      defer { completed = true }
      return try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: value,
        programIdentity: source, stateVersion: nil)
    }
    try await waitForOptimisticValue(model, documentID: documentID, blockID: "a", value: value)
    XCTAssertFalse(completed, "A blocked writer cannot acknowledge an optimistic checkpoint")
    XCTAssertNotNil(retainedTransfer)
    XCTAssertEqual(resources.rasterAdmission.heldBytes, baseline + cost - initialCredit)
    model.retryPendingPersistence()
    let deadline = ContinuousClock.now + .seconds(10)
    while !completed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(completed, "The addressed receipt must not wait for a second reservation owned by its own caller")
    XCTAssertNotNil(retainedTransfer)
    XCTAssertEqual(resources.rasterAdmission.heldBytes, baseline + cost - initialCredit,
      "The caller, not the writer, releases its frozen snapshot after the receipt")
    // Release before joining so the old self-deadlocking path fails this test
    // without leaving the suite or its shared resource pool permanently hung.
    snapshot?.release(); snapshot = nil
    XCTAssertNil(retainedTransfer)
    XCTAssertEqual(resources.rasterAdmission.heldBytes, baseline - initialCredit)
    let receipt = try await checkpoint.value
    XCTAssertNotNil(receipt)
    let reopened = NotebookStore(root: model.store.root)
    let admission = try reopened.documentProgramStateReadBytes(documentID: documentID, blockID: "a")
    let stored = try XCTUnwrap(try reopened.readDocumentProgramState(documentID: documentID, blockID: "a", admittedBytes: admission))
    XCTAssertEqual(stored.state, value); XCTAssertEqual(stored.stateVersion, receipt)
    XCTAssertThrowsError(try reopened.readDocumentBlock(documentID: documentID, blockID: "a"),
      "The public document-block read budget remains unchanged")
  }

  @MainActor
  func testDetachedDocumentCheckpointUsesTheAddressedWriterAfterWorkingSetEviction() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID]), source = document.programIdentity(blockID: "a")
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    model.selectItem(notebook)
    _ = await model.finishPendingPersistence()
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.documents[documentID], "The closed book must actually leave the loaded working set")
    let accepted = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(0.75),
      programIdentity: source, stateVersion: nil)
    XCTAssertNotNil(accepted)
    XCTAssertEqual(try model.store.readDocumentBlock(documentID: documentID, blockID: "a")?.state, .number(0.75))
    XCTAssertNil(model.documents[documentID], "Checkpoint cannot reopen a closed book or load its whole history")
    let stale = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(0.25),
      programIdentity: source, stateVersion: nil)
    XCTAssertNil(stale)
    _ = await model.shutdown()
  }

  @MainActor
  func testAcceptedDocumentEventsAfterEvictionKeepFIFOWithoutHydratingTheBook() async throws {
    let (model, documentID) = try await makeModel()
    let source = try XCTUnwrap(model.documents[documentID]).programIdentity(blockID: "a")
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    model.selectItem(notebook)
    _ = await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
    XCTAssertNil(model.documents[documentID]); XCTAssertNil(model.documentStates[documentID])
    let cursor = try model.store.currentChangeCursor()
    var versions: [ContentFieldVersion] = []
    for value in [1.0, 2.0, 3.0] {
      let accepted = try await model.commitDocumentState(documentID: documentID, blockID: "a",
        value: .number(value), programIdentity: source)
      versions.append(try XCTUnwrap(accepted))
      XCTAssertEqual(try model.store.readDocumentBlock(documentID: documentID, blockID: "a")?.state, .number(value))
    }
    XCTAssertNotEqual(versions[0], versions[1]); XCTAssertNotEqual(versions[1], versions[2])
    _ = await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
    let file = "document-states/" + documentID.uuidString.lowercased() + ".json"
    let changes = try model.store.changeJournal(after: cursor).filter { change in
      try model.store.readChangedAddresses(after: change.sequence - 1, through: change.sequence)
        .addresses.contains { $0.hasPrefix(file) }
    }
    XCTAssertEqual(changes.count, 3)
    XCTAssertNil(model.documents[documentID]); XCTAssertNil(model.documentStates[documentID])
    XCTAssertEqual(model.presence?.selectedItemID, notebook)
    let checkpoint = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(3),
      programIdentity: source, stateVersion: versions.last)
    XCTAssertEqual(checkpoint, versions.last)
    _ = await model.shutdown()
  }

  @MainActor
  func testCheckpointCannotAdoptANewerModelStateBeforeSwiftUIEchoesIt() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID]), source = document.programIdentity(blockID: "a")
    let old = try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(1), programIdentity: source)
    try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(2), programIdentity: source)
    _ = await model.finishPendingPersistence()
    let before = model.documentStates[documentID], cursor = try model.store.currentChangeCursor()
    let rejected = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(99),
      programIdentity: source, stateVersion: old)
    XCTAssertNil(rejected)
    XCTAssertEqual(model.documentStates[documentID], before, "A stale checkpoint cannot even optimistically replace the newer value")
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(try model.store.readDocumentBlock(documentID: documentID, blockID: "a")?.state, .number(2))
    _ = await model.shutdown()
  }

  @MainActor
  func testRuntimeCheckpointRejectsAChangedSourceAndAnUnobservedStoredState() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    var state = try model.store.loadDocumentState(documentID)
    XCTAssertTrue(state.commit(blockID: "a", value: .object([:]), actor: UUID()))
    try model.store.saveDocumentState(state)
    let unseen = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .object([:]), programIdentity: document.programIdentity(blockID: "a"), stateVersion: nil)
    XCTAssertNil(unseen, "Equal values with an unobserved causal state are not the accepted checkpoint")
    var changed = document
    XCTAssertTrue(changed.replaceContent(blocks: [.interactive(id: "a", html: "<button>Different code</button>")], actor: model.actorID))
    _ = try model.store.saveMergedDocument(changed)
    let stale = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .object([:]), programIdentity: document.programIdentity(blockID: "a"), stateVersion: nil)
    XCTAssertNil(stale)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let current = try XCTUnwrap(model.documents[documentID])
    XCTAssertNotEqual(current.programIdentity(blockID: "a"), document.programIdentity(blockID: "a"))
    let cursor = try model.store.currentChangeCursor()
    let journal = model.documentStates[documentID]
    let stateAdmission1 = try await model.commitDocumentState(documentID: documentID, blockID: "a",
      value: .number(42), programIdentity: document.programIdentity(blockID: "a"))
    XCTAssertNil(stateAdmission1,
      "A delayed callback from replaced source cannot be admitted against the new program")
    let stateAdmission2 = try await model.commitDocumentState(documentID: documentID, blockID: "b",
      value: .number(43), programIdentity: document.programIdentity(blockID: "b"))
    XCTAssertNil(stateAdmission2,
      "A removed program cannot recreate its state through a delayed callback")
    await model.finishPendingPersistence()
    XCTAssertEqual(model.documentStates[documentID], journal)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
  }

  @MainActor
  func testWriterRejectsStaleRuntimeBeforeTheModelObservesSourceReplacement() async throws {
    let (model, documentID) = try await makeModel()
    let observed = try XCTUnwrap(model.documents[documentID])
    let previous = try model.store.loadDocumentState(documentID)
    var replacement = observed
    XCTAssertTrue(replacement.replaceBlockSource(id: "a", source: "<button>Replacement</button>", actor: UUID()))
    _ = try model.store.saveMergedDocument(replacement)
    XCTAssertEqual(model.documents[documentID], observed, "The race requires the real model to remain behind SQL")
    let cursor = try model.store.currentChangeCursor()
    let admitted = try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(47),
      programIdentity: observed.programIdentity(blockID: "a"))
    XCTAssertNil(admitted, "An optimistic model echo cannot acknowledge a source generation rejected by SQLite")
    let drained = await model.finishPendingPersistence()
    XCTAssertTrue(drained, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadDocumentState(documentID), previous)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(model.documentStates[documentID], previous, "A rejected admission reconciles through the ordinary reload")
    XCTAssertEqual(model.documents[documentID], replacement)
    let checkpoint = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(47),
      programIdentity: observed.programIdentity(blockID: "a"), stateVersion: nil)
    XCTAssertNil(checkpoint)
  }

  @MainActor
  func testShutdownDrainsAcceptedStateAndRejectsALateProgramCallback() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let commit = Task { @MainActor in
      try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(19),
        programIdentity: document.programIdentity(blockID: "a"))
    }
    try await waitForOptimisticValue(model, documentID: documentID, blockID: "a", value: .number(19))
    let shutdown = Task { @MainActor in await model.shutdown() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.shutdownPhase == .running, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertNotEqual(model.shutdownPhase, .running, "Shutdown must begin with the accepted write still blocked")
    try lock.release()
    let receipt = try await commit.value
    XCTAssertNotNil(receipt)
    let stopped = await shutdown.value
    XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    let state = try model.store.loadDocumentState(documentID), cursor = try model.store.currentChangeCursor()
    XCTAssertEqual(state.value(for: "a"), .number(19))
    let visible = model.documentStates[documentID]
    let stateAdmission3 = try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(23), programIdentity: document.programIdentity(blockID: "a"))
    XCTAssertNil(stateAdmission3)
    let stateAdmission4 = try await model.commitDocumentState(documentID: documentID, blockID: "b", value: .number(29), programIdentity: document.programIdentity(blockID: "b"))
    XCTAssertNil(stateAdmission4)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertEqual(model.documentStates[documentID], visible)
    XCTAssertEqual(try model.store.loadDocumentState(documentID), state)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
  }

  @MainActor
  func testMultipleAcceptedProgramsKeepTheirOrderThroughNavigation() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    let cursor = try model.store.currentChangeCursor()
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    var commits: [Task<ContentFieldVersion?, Error>] = []
    for (block, value) in [("a", 1.0), ("b", 10.0), ("a", 2.0)] {
      commits.append(Task { @MainActor in
        try await model.commitDocumentState(documentID: documentID, blockID: block, value: .number(value),
          programIdentity: document.programIdentity(blockID: block))
      })
      // Sequential optimistic admission fixes FIFO order without waiting for
      // durability behind the deliberately held SQLite transaction.
      try await waitForOptimisticValue(model, documentID: documentID, blockID: block, value: .number(value))
    }
    XCTAssertEqual(model.documentStates[documentID]?.value(for: "a"), .number(2))
    XCTAssertEqual(model.documentStates[documentID]?.value(for: "b"), .number(10))
    model.selectItem(notebook)
    try lock.release()
    for commit in commits {
      let receipt = try await commit.value
      XCTAssertNotNil(receipt)
    }
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let stored = try model.store.loadDocumentState(documentID)
    XCTAssertEqual(stored.value(for: "a"), .number(2))
    XCTAssertEqual(stored.value(for: "b"), .number(10))
    let stateFile = "document-states/" + documentID.uuidString.lowercased() + ".json"
    let publications = try model.store.changeJournal(after: cursor).filter { change in
      try model.store.readChangedAddresses(after: change.sequence - 1, through: change.sequence)
        .addresses.contains { $0.hasPrefix(stateFile) }
    }
    XCTAssertEqual(publications.count, 3, "Three accepted commands, not one replacement journal, must reach the durable queue")
    XCTAssertEqual(model.presence?.selectedItemID, notebook, "A later state receipt cannot change the human's navigation")
  }

  @MainActor
  func testBlockedFirstValueRetainsOtherBlocksAndTheObservationFenceUntilRetry() async throws {
    enum Failure: Error { case unavailable }
    let (model, documentID) = try await makeModel()
    let queue = NotebookPersistenceQueue(store: model.store)
    let ready = model.store.root.appendingPathComponent("test-state-write-ready")
    let observed = model.store.root.appendingPathComponent("test-state-fence.json")
    var state = try model.store.loadDocumentState(documentID)
    let document = try model.store.loadDocument(documentID)
    let first = try accepted(&state, block: "a", value: 1, actor: model.actorID, document: document)
    let second = try accepted(&state, block: "b", value: 10, actor: model.actorID, document: document)
    let third = try accepted(&state, block: "a", value: 2, actor: model.actorID, document: document)
    let cursor = try model.store.currentChangeCursor()
    queue.enqueue(owner: .documentState(documentID)) { store in
      guard FileManager.default.fileExists(atPath: ready.path) else { throw Failure.unavailable }
      return try store.commitDocumentState(first) != first.expectedResult
    }
    queue.enqueue(owner: .documentState(documentID)) { try $0.commitDocumentState(second) != second.expectedResult }
    queue.enqueue { store in
      try JSONEncoder().encode(store.loadDocumentState(documentID)).write(to: observed)
      return false
    }
    queue.enqueue(owner: .documentState(documentID)) { try $0.commitDocumentState(third) != third.expectedResult }
    let failed = await queue.flush()
    XCTAssertFalse(failed)
    XCTAssertEqual(queue.pendingCount, 4)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertFalse(FileManager.default.fileExists(atPath: observed.path))
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved, queue.failure ?? "")
    let middle = try JSONDecoder().decode(DocumentStateJournal.self, from: Data(contentsOf: observed))
    XCTAssertEqual(middle.value(for: "a"), .number(1))
    XCTAssertEqual(middle.value(for: "b"), .number(10))
    XCTAssertEqual(try model.store.loadDocumentState(documentID), state)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor + 3)
  }

  @MainActor
  func testCapturedValueSurvivesDocumentLeavingTheLoadedScene() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let commit = Task { @MainActor in
      try await model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(17),
        programIdentity: document.programIdentity(blockID: "a"))
    }
    try await waitForOptimisticValue(model, documentID: documentID, blockID: "a", value: .number(17))
    let acceptedState = try XCTUnwrap(model.documentStates[documentID])
    let notebook = try XCTUnwrap(model.createNotebook(at: .init(x: 30_000, y: 30_000)))
    model.selectItem(notebook)
    try lock.release()
    let receipt = try await commit.value
    XCTAssertNotNil(receipt)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadDocumentState(documentID), acceptedState)
    XCTAssertEqual(model.presence?.selectedItemID, notebook)
  }

  @MainActor
  private func waitForOptimisticValue(_ model: NotebookAppModel, documentID: UUID, blockID: String,
    value: JSONValue) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.documentStates[documentID]?.value(for: blockID) != value, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(model.documentStates[documentID]?.value(for: blockID), value,
      "Local display must advance independently of the blocked durable receipt")
  }

  @MainActor
  private func accepted(_ state: inout DocumentStateJournal, block: String, value: Double, actor: UUID,
    document: DocumentDocument) throws -> NotebookDocumentStateCommand {
    XCTAssertTrue(state.commit(blockID: block, value: .number(value), actor: actor))
    return .init(documentID: state.id, record: try XCTUnwrap(state.records.first { $0.id == block }),
      journalStamp: state.stamp, expectedProgramIdentity: document.programIdentity(blockID: block))
  }

  @MainActor
  private func makeModel(captureQueue: ((NotebookPersistenceQueue) -> Void)? = nil) async throws -> (NotebookAppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    captureQueue?(queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .a4))
    let created = await model.finishPendingPersistence()
    XCTAssertTrue(created, model.persistenceFailure ?? "")
    var document = try model.store.loadDocument(id)
    XCTAssertTrue(document.replaceContent(blocks: [
      .interactive(id: "a", html: "<button>A</button>"),
      .interactive(id: "b", html: "<button>B</button>")], actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    let presence = try XCTUnwrap(model.presence)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: id,
      openProgress: 1, selectedItemID: id), settled: true)
    let opened = await model.finishPendingPersistence()
    XCTAssertTrue(opened, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    XCTAssertEqual(model.documents[id], document)
    return (model, id)
  }
}
