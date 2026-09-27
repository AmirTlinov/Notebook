import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentNativeSourceSessionTests: XCTestCase {
  private func fixture() async throws -> (NotebookAppModel, UUID, DocumentSourceEditorSession) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero))
    await model.finishPendingPersistence()
    let presence = try XCTUnwrap(model.presence)
    model.selectItem(id)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: id,
      openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let request = try await model.insertDocumentFile(documentID: id, path: "chapters/edit.tex")
    return (model, id, DocumentSourceEditorSession(request: request, model: model))
  }

  func testInputDuringSaveUsesTheAcceptedVersionAndCommonUndo() async throws {
    let (model, id, session) = try await fixture()
    let contact = UUID(); model.inputGate.beginContact(source: contact)
    session.input("First", selection: .init(location: 5, length: 0), composing: false, scroll: 0)
    let saving = Task { await session.save() }
    while !session.saving { await Task.yield() }
    session.input("First and second", selection: .init(location: 16, length: 0), composing: false, scroll: 0)
    model.inputGate.endContact(source: contact)
    await saving.value
    XCTAssertFalse(session.conflicted)
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "First and second")
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "First")
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "")
  }

  func testComposingDraftRestoresExactSelectionWithoutPublishingHalfInput() async throws {
    let (model, id, session) = try await fixture()
    session.input("Неоконченный ввод", selection: .init(location: 2, length: 5), composing: true, scroll: 210)
    await session.checkpoint(); await model.finishPendingPersistence()
    let saved = try model.store.loadDocument(id)
    XCTAssertEqual(saved.files.first { $0.id == session.fileID }?.source, "")
    let file = try XCTUnwrap(saved.files.first { $0.id == session.fileID })
    let restored = DocumentSourceEditorSession(request: .init(documentID: id, file: file,
      version: saved.fileVersion(fileID: file.id), offset: 0), model: model)
    XCTAssertEqual(restored.text, session.text)
    XCTAssertEqual(restored.selection, NSRange(location: 2, length: 5))
    XCTAssertEqual(restored.restoredScroll, 210)
    XCTAssertEqual(try model.store.documentEditingSessions().last?.isComposing, true)
  }

  func testConcurrentAgentEditPreservesDraftAndNeedsExplicitResolution() async throws {
    let (model, id, session) = try await fixture()
    session.input("My unfinished text", selection: .init(location: 4, length: 0), composing: true, scroll: 0)
    await model.finishPendingPersistence()
    let fileID = session.fileID
    try await model.performStoreCommand(publishesChanges: true) { store in
      let document = try store.loadDocument(id), target = CollaborationTarget(kind: .document, id: id)
      _ = try store.applyCollaborationAction(.init(summary: "Agent edit", expected: [.init(target: target, revision: document.contentStamp.revision)],
        operations: [.init(kind: .putDocumentFile, target: target, id: fileID, values: ["path": .string("chapters/edit.tex"), "source": .string("Agent text"), "expectedVersion": try .encode(document.fileVersion(fileID: fileID))])]), actor: UUID())
    }
    await model.reloadExternalChanges()?.value
    session.input(session.text, selection: session.selection, composing: false, scroll: 0)
    await session.save()
    XCTAssertTrue(session.conflicted)
    XCTAssertEqual(session.text, "My unfinished text")
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "Agent text")
    session.useCurrentDocument(); await model.finishPendingPersistence()
    XCTAssertFalse(session.conflicted)
    XCTAssertEqual(session.text, "Agent text")
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  func testNewFileUsesCommonUndoRatherThanASeparateEditorHistory() async throws {
    let (model, id, session) = try await fixture()
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.path, "chapters/edit.tex")
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertFalse(try model.store.loadDocument(id).files.contains { $0.id == session.fileID })
  }

  func testRapidSourceUndoAndRedoKeepTheirAcceptedDocumentAcrossAWriteBarrier() async throws {
    let (model, id, session) = try await fixture()
    for text in ["First", "Second"] {
      session.input(text, selection: .init(location: text.utf16.count, length: 0), composing: false, scroll: 0)
      await session.save()
    }
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    session.input("Third", selection: .init(location: 5, length: 0), composing: false, scroll: 0)
    session.undo(); session.undo()
    let deadline = ContinuousClock.now + .seconds(2)
    while !session.saving, ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(session.saving)
    let notebook = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    model.selectItem(notebook)
    try lock.release()
    let undone = await model.finishPendingPersistence()
    XCTAssertTrue(undone, model.persistenceFailure ?? "")
    let afterUndo = try model.store.loadDocument(id)
    XCTAssertEqual(afterUndo.files.first { $0.id == session.fileID }?.source, "First",
      "Both accepted gestures must execute after the pending Third save, not cancel the same action twice")
    XCTAssertEqual(model.presence?.selectedItemID, notebook)
    session.reconcile(afterUndo)

    let redoLock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? redoLock.release() }
    session.redo(); session.redo()
    await Task.yield()
    try redoLock.release()
    let repeated = await model.finishPendingPersistence()
    XCTAssertTrue(repeated, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "Third")
    XCTAssertEqual(model.presence?.selectedItemID, notebook, "Queued history never switches or edits the new surface")
  }

  func testMessageSelectionFreezesABoundedDraftWithoutSavingOrOpeningChat() async throws {
    let (model, id, session) = try await fixture()
    let text = String(repeating: "x", count: 15_999) + "🪴" + " end"
    session.input(text, selection: .init(location: 0, length: text.utf16.count), composing: false, scroll: 0)
    let selection = try XCTUnwrap(session.messageSelection)
    XCTAssertEqual(selection.documentID, id)
    XCTAssertEqual(selection.fileID, session.fileID)
    XCTAssertEqual(selection.selectionEnd, text.utf16.count)
    XCTAssertEqual(selection.selectedText, String(repeating: "x", count: 15_999))
    XCTAssertTrue(selection.hasLocalDraft); XCTAssertNotNil(selection.draftID); XCTAssertTrue(selection.truncated)
    session.input("Later", selection: .init(location: 0, length: 5), composing: true, scroll: 0)
    XCTAssertNil(session.messageSelection, "Half of an IME transaction is not a selected message fragment")
    XCTAssertEqual(selection.selectionEnd, text.utf16.count, "A later contact cannot replace the frozen Send-time fragment")
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == session.fileID }?.source, "")
  }
}
