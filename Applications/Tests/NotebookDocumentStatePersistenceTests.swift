import NotebookCore
import XCTest
@testable import Notebook

final class NotebookDocumentStatePersistenceTests: XCTestCase {
  @MainActor
  func testShutdownDrainsAcceptedStateAndRejectsALateProgramCallback() async throws {
    let (model, documentID) = try await makeModel()
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(19))
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    let state = try model.store.loadDocumentState(documentID), cursor = try model.store.currentChangeCursor()
    XCTAssertEqual(state.value(for: "a"), .number(19))
    let visible = model.documentStates[documentID]
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(23))
    model.commitDocumentState(documentID: documentID, blockID: "b", value: .number(29))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertEqual(model.documentStates[documentID], visible)
    XCTAssertEqual(try model.store.loadDocumentState(documentID), state)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
  }

  @MainActor
  func testMultipleAcceptedProgramsKeepTheirOrderThroughNavigation() async throws {
    let (model, documentID) = try await makeModel()
    let cursor = try model.store.currentChangeCursor()
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(1))
    model.commitDocumentState(documentID: documentID, blockID: "b", value: .number(10))
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(2))
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
    let first = try accepted(&state, block: "a", value: 1, actor: model.actorID)
    let second = try accepted(&state, block: "b", value: 10, actor: model.actorID)
    let third = try accepted(&state, block: "a", value: 2, actor: model.actorID)
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
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    model.commitDocumentState(documentID: documentID, blockID: "a", value: .number(17))
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
  private func accepted(_ state: inout DocumentStateJournal, block: String, value: Double, actor: UUID) throws -> NotebookDocumentStateCommand {
    XCTAssertTrue(state.commit(blockID: block, value: .number(value), actor: actor))
    return .init(documentID: state.id, record: try XCTUnwrap(state.records.first { $0.id == block }), journalStamp: state.stamp)
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
    await model.reloadExternalChanges()?.value
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    XCTAssertEqual(model.documents[id], document)
    return (model, id)
  }
}
