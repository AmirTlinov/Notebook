import NotebookCore
import XCTest
@testable import Notebook

final class NotebookDocumentSourcePersistenceTests: XCTestCase {
  @MainActor
  func testOpeningAnUnloadedDocumentReadsItsContentWithoutAnExternalRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    var ids: [UUID] = []
    for _ in 0..<10 {
      let createdDocumentResult = await model.createDocument(at: .zero)
      ids.append(try XCTUnwrap(createdDocumentResult))
    }
    model.selectItem(notebook)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let id = try XCTUnwrap(ids.first { model.documents[$0] == nil },
      "The bounded working set must leave some document sources unloaded")
    let camera = try XCTUnwrap(model.presence?.camera)
    let expected = try model.store.loadDocument(id)
    let state = try model.store.loadDocumentState(id)

    model.selectItem(id)
    XCTAssertNil(model.documents[id], "Selecting a closed cover does not request its body")
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let deadline = ContinuousClock.now + .seconds(2)
    while model.documents[id] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.documents[id], expected, "Opening reads the addressed source, not a later sync event")
    XCTAssertEqual(model.documentStates[id], state)
    XCTAssertEqual(Set(model.documents.keys), [id], "Opening does not read neighbouring books before the chosen document")
    XCTAssertEqual(model.presence?.selectedItemID, id)
    XCTAssertEqual(model.presence?.camera, camera, "Content readiness cannot reposition the paper")
  }

  @MainActor
  func testAcceptedSourceUpdatesOnlyItsProgramAndKeepsHumanSelection() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id]), state = try model.store.loadDocumentState(id)
    let notebookID = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: before.files.first { $0.id == "a-html" }!.source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "<button>Accepted human text</button>", sequence: 1)
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
    XCTAssertEqual(stored.files.first { $0.id == "a-html" }!.source, edit.source)
    XCTAssertEqual(stored.files.first { $0.id == "a-css" }, before.files.first { $0.id == "a-css" })
    XCTAssertEqual(stored.files.first { $0.id == "b" }, before.files.first { $0.id == "b" })
    XCTAssertEqual(try model.store.loadDocumentState(id), state)
    XCTAssertEqual(model.presence?.selectedItemID, notebookID)
    XCTAssertFalse(model.documentEditingSessions.contains { $0.id == edit.sessionID })
    if let retained = model.documents[id] { XCTAssertEqual(retained.files, stored.files) }
  }

  @MainActor
  func testSourceReceiptReachesTheVisibleModelBeforeTheEditorCloses() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id])
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: before.files.first { $0.id == "a-html" }!.source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "<p>Visible source</p>", sequence: 1)
    let status = try await model.commitDocumentSource(edit: edit)
    XCTAssertEqual(status, .committed)
    let shown = try XCTUnwrap(model.documents[id])
    XCTAssertEqual(shown.files.first { $0.id == "a-html" }!.source, edit.source)
    XCTAssertEqual(shown, try model.store.loadDocument(id))
    let settled = await model.finishPendingPersistence()
    XCTAssertTrue(settled, model.persistenceFailure ?? "")
    let cursor = try model.store.currentChangeCursor()
    let repeated = try await model.commitDocumentSource(edit: edit)
    XCTAssertEqual(repeated, .committed)
    XCTAssertEqual(model.documents[id], shown)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    let state = try model.store.loadDocumentState(id)
    model.undoLastSurfaceAction()
    let undone = await model.finishPendingPersistence()
    XCTAssertTrue(undone, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadDocument(id).files, before.files)
    XCTAssertEqual(model.documents[id]?.files, before.files)
    XCTAssertEqual(try model.store.loadDocumentState(id), state,
      "Undo of a source field does not undo a live program's independent state")
  }

  @MainActor
  func testSaveJoinsItsReleasedHumanContactWithoutBypassingTheCommonInputBarrier() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id]), contact = UUID()
    model.inputGate.beginContact(source: contact)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: before.files.first { $0.id == "a-html" }!.source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "Saved after lifting", sequence: 1)
    let saving = Task { try await model.commitDocumentSource(edit: edit) }
    await Task.yield()
    XCTAssertEqual(try model.store.loadDocument(id).files, before.files)
    model.inputGate.endContact(source: contact)
    let status = try await saving.value
    XCTAssertEqual(status, .committed)
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == "a-html" }!.source, edit.source)
  }

  @MainActor
  func testShutdownRejectsALateEditorWithoutPublishingADraftOrSource() async throws {
    let (model, id) = try await makeModel()
    let document = try XCTUnwrap(model.documents[id])
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    let cursor = try model.store.currentChangeCursor()
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: document.files.first { $0.id == "a-html" }!.source,
      baseVersion: document.fileVersion(fileID: "a-html"), source: "Not admitted", sequence: 1)
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
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    let created = await model.finishPendingPersistence()
    XCTAssertTrue(created, model.persistenceFailure ?? "")
    var document = try model.store.loadDocument(id)
    XCTAssertTrue(document.replaceContent(files: DocumentTestFiles.document(contents: [
      .program(id: "a", html: "<button>A</button>", css: "button{color:blue}", initialState: .number(3)),
      .tex(id: "b", source: "Independent human program")]).files, actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    await model.reloadExternalChanges()?.value
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    let presence = try XCTUnwrap(model.presence)
    model.selectItem(id)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: id,
      openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    XCTAssertEqual(model.documents[id], document)
    return (model, id)
  }
}
