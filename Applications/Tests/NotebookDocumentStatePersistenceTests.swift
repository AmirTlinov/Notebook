import NotebookCore
import XCTest
@testable import Notebook

final class NotebookDocumentStatePersistenceTests: XCTestCase {
  @MainActor
  func testRuntimeCheckpointWaitsForTheAcceptedWriteAndRejectsANewerContact() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    let version = document.sourceVersion(blockID: "a")
    let initial = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .object([:]), sourceVersion: version, stateVersion: nil)
    XCTAssertNotNil(initial, "An unchanged durable initial state can release an unvisited runtime")
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let admitted = model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(1), sourceVersion: version)
    XCTAssertEqual(admitted, model.documentStates[documentID]?.records.first { $0.id == "a" }?.valueVersion)
    XCTAssertNotNil(admitted, "Causal admission is synchronous even while persistence is blocked")
    var completed = false
    let checkpoint = Task { @MainActor in
      let value = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
        value: .number(1), sourceVersion: version, stateVersion: admitted)
      completed = true
      return value
    }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(completed, "An optimistic UI echo must not release the program before SQLite accepts it")
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(2), sourceVersion: version)
    try lock.release()
    let old = try await checkpoint.value
    XCTAssertNil(old, "The old fence cannot retire a runtime after a later accepted contact")
    let current = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .number(2), sourceVersion: version, stateVersion: model.documentStates[documentID]?.records.first { $0.id == "a" }?.valueVersion)
    XCTAssertNotNil(current)
    XCTAssertEqual(try model.store.readDocumentBlock(documentID: documentID, blockID: "a")?.state, .number(2))
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    let late = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .number(2), sourceVersion: version, stateVersion: current)
    XCTAssertNil(late)
  }

  @MainActor
  func testDetachedDocumentCheckpointUsesTheAddressedWriterAfterWorkingSetEviction() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID]), source = document.sourceVersion(blockID: "a")
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    model.selectItem(notebook)
    _ = await model.finishPendingPersistence()
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.documents[documentID], "The closed book must actually leave the loaded working set")
    let accepted = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(0.75),
      sourceVersion: source, stateVersion: nil)
    XCTAssertNotNil(accepted)
    XCTAssertEqual(try model.store.readDocumentBlock(documentID: documentID, blockID: "a")?.state, .number(0.75))
    XCTAssertNil(model.documents[documentID], "Checkpoint cannot reopen a closed book or load its whole history")
    let stale = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(0.25),
      sourceVersion: source, stateVersion: nil)
    XCTAssertNil(stale)
    _ = await model.shutdown()
  }

  @MainActor
  func testCheckpointCannotAdoptANewerModelStateBeforeSwiftUIEchoesIt() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID]), source = document.sourceVersion(blockID: "a")
    let old = model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(1), sourceVersion: source)
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(2), sourceVersion: source)
    _ = await model.finishPendingPersistence()
    let before = model.documentStates[documentID], cursor = try model.store.currentChangeCursor()
    let rejected = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(99),
      sourceVersion: source, stateVersion: old)
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
      value: .object([:]), sourceVersion: document.sourceVersion(blockID: "a"), stateVersion: nil)
    XCTAssertNil(unseen, "Equal values with an unobserved causal state are not the accepted checkpoint")
    var changed = document
    XCTAssertTrue(changed.replaceContent(blocks: [.interactive(id: "a", html: "<button>Different code</button>")], actor: model.actorID))
    _ = try model.store.saveMergedDocument(changed)
    let stale = try await model.checkpointDocumentState(documentID: documentID, blockID: "a",
      value: .object([:]), sourceVersion: document.sourceVersion(blockID: "a"), stateVersion: nil)
    XCTAssertNil(stale)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let current = try XCTUnwrap(model.documents[documentID])
    XCTAssertNotEqual(current.sourceVersion(blockID: "a"), document.sourceVersion(blockID: "a"))
    let cursor = try model.store.currentChangeCursor()
    let journal = model.documentStates[documentID]
    XCTAssertNil(model.commitDocumentState(documentID: documentID, blockID: "a",
      value: .number(42), sourceVersion: document.sourceVersion(blockID: "a")),
      "A delayed callback from replaced source cannot be admitted against the new program")
    XCTAssertNil(model.commitDocumentState(documentID: documentID, blockID: "b",
      value: .number(43), sourceVersion: document.sourceVersion(blockID: "b")),
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
    let admitted = model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(47),
      sourceVersion: observed.sourceVersion(blockID: "a"))
    XCTAssertNotNil(admitted, "The old visible generation can only acknowledge in-memory admission")
    let drained = await model.finishPendingPersistence()
    XCTAssertTrue(drained, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadDocumentState(documentID), previous)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(model.documentStates[documentID], previous, "A rejected admission reconciles through the ordinary reload")
    XCTAssertEqual(model.documents[documentID], replacement)
    let checkpoint = try await model.checkpointDocumentState(documentID: documentID, blockID: "a", value: .number(47),
      sourceVersion: observed.sourceVersion(blockID: "a"), stateVersion: nil)
    XCTAssertNil(checkpoint)
  }

  @MainActor
  func testShutdownDrainsAcceptedStateAndRejectsALateProgramCallback() async throws {
    let (model, documentID) = try await makeModel()
    let document = try XCTUnwrap(model.documents[documentID])
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(19), sourceVersion: document.sourceVersion(blockID: "a"))
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    let state = try model.store.loadDocumentState(documentID), cursor = try model.store.currentChangeCursor()
    XCTAssertEqual(state.value(for: "a"), .number(19))
    let visible = model.documentStates[documentID]
    XCTAssertNil(model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(23), sourceVersion: document.sourceVersion(blockID: "a")))
    XCTAssertNil(model.commitDocumentState(documentID: documentID, blockID: "b", value: .number(29), sourceVersion: document.sourceVersion(blockID: "b")))
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
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(1), sourceVersion: document.sourceVersion(blockID: "a"))
    model.commitDocumentState(documentID: documentID, blockID: "b", value: .number(10), sourceVersion: document.sourceVersion(blockID: "b"))
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(2), sourceVersion: document.sourceVersion(blockID: "a"))
    XCTAssertEqual(model.documentStates[documentID]?.value(for: "a"), .number(2))
    XCTAssertEqual(model.documentStates[documentID]?.value(for: "b"), .number(10))
    model.selectItem(notebook)
    try lock.release()
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
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(17), sourceVersion: document.sourceVersion(blockID: "a"))
    let acceptedState = try XCTUnwrap(model.documentStates[documentID])
    let notebook = try XCTUnwrap(model.createNotebook(at: .init(x: 30_000, y: 30_000)))
    model.selectItem(notebook)
    try lock.release()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadDocumentState(documentID), acceptedState)
    XCTAssertEqual(model.presence?.selectedItemID, notebook)
  }

  @MainActor
  private func accepted(_ state: inout DocumentStateJournal, block: String, value: Double, actor: UUID,
    document: DocumentDocument) throws -> NotebookDocumentStateCommand {
    XCTAssertTrue(state.commit(blockID: block, value: .number(value), actor: actor))
    return .init(documentID: state.id, record: try XCTUnwrap(state.records.first { $0.id == block }),
      journalStamp: state.stamp, expectedSourceVersion: document.sourceVersion(blockID: block))
  }

  @MainActor
  private func makeModel() async throws -> (NotebookAppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
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
