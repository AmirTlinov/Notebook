import NotebookCore
import XCTest
@testable import Notebook

final class NotebookDocumentSourcePersistenceTests: XCTestCase {
  @MainActor
  func testAcceptedSourceUpdatesOnlyItsProgramAndKeepsHumanSelection() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id]), state = try model.store.loadDocumentState(id)
    let notebookID = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, blockID: "a", baseSource: before.blocks[0].source,
      baseVersion: before.sourceVersion(blockID: "a"), source: "<button>Accepted human text</button>", sequence: 1)
    model.saveDocumentDraft(.init(edit: edit))
    let operation = Task { try await model.commitDocumentSource(edit: edit) }
    // The source command retains its explicit document even if human
    // navigation happens before its queued SQLite writer is admitted.
    await Task.yield()
    model.selectItem(notebookID)
    try lock.release()
    let status = try await operation.value
    XCTAssertEqual(status, .committed)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let stored = try model.store.loadDocument(id)
    XCTAssertEqual(stored.blocks[0].source, edit.source)
    XCTAssertEqual(stored.blocks[0].css, before.blocks[0].css)
    XCTAssertEqual(stored.blocks[1], before.blocks[1])
    XCTAssertEqual(try model.store.loadDocumentState(id), state)
    XCTAssertEqual(model.presence?.selectedItemID, notebookID)
    XCTAssertFalse(model.documentEditingSessions.contains { $0.id == edit.sessionID })
    if let retained = model.documents[id] { XCTAssertEqual(retained.blocks, stored.blocks) }
  }

  @MainActor
  func testSourceReceiptReachesTheVisibleModelBeforeTheEditorCloses() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id])
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, blockID: "a", baseSource: before.blocks[0].source,
      baseVersion: before.sourceVersion(blockID: "a"), source: "<p>Visible source</p>", sequence: 1)
    let status = try await model.commitDocumentSource(edit: edit)
    XCTAssertEqual(status, .committed)
    let shown = try XCTUnwrap(model.documents[id])
    XCTAssertEqual(shown.blocks[0].source, edit.source)
    XCTAssertEqual(shown, try model.store.loadDocument(id))
    let cursor = try model.store.currentChangeCursor()
    let repeated = try await model.commitDocumentSource(edit: edit)
    XCTAssertEqual(repeated, .committed)
    XCTAssertEqual(model.documents[id], shown)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
  }

  @MainActor
  func testShutdownRejectsALateEditorWithoutPublishingADraftOrSource() async throws {
    let (model, id) = try await makeModel()
    let document = try XCTUnwrap(model.documents[id])
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    let cursor = try model.store.currentChangeCursor()
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, blockID: "a", baseSource: document.blocks[0].source,
      baseVersion: document.sourceVersion(blockID: "a"), source: "Not admitted", sequence: 1)
    do {
      _ = try await model.commitDocumentSource(edit: edit)
      XCTFail("A closed Notebook admitted new source input")
    } catch is NotebookPersistenceQueue.Failure { }
    XCTAssertEqual(try model.store.loadDocument(id), document)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  @MainActor
  private func makeModel() async throws -> (NotebookAppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .letter))
    let created = await model.finishPendingPersistence()
    XCTAssertTrue(created, model.persistenceFailure ?? "")
    var document = try model.store.loadDocument(id)
    XCTAssertTrue(document.replaceContent(blocks: [
      .interactive(id: "a", html: "<button>A</button>", css: "button{color:blue}", initialState: .number(3)),
      .markdown(id: "b", source: "Independent human program")], actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    await model.reloadExternalChanges()?.value
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    XCTAssertEqual(model.documents[id], document)
    return (model, id)
  }
}
