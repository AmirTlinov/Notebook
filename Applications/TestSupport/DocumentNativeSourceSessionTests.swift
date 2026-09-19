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
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .a4))
    await model.finishPendingPersistence()
    let presence = try XCTUnwrap(model.presence)
    model.selectItem(id)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: id,
      openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let request = try await model.insertDocumentSource(documentID: id, kind: .tex)
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
    XCTAssertEqual(try model.store.loadDocument(id).blocks.last?.source, "First and second")
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.loadDocument(id).blocks.last?.source, "First")
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.loadDocument(id).blocks.last?.source, "")
  }

  func testComposingDraftRestoresExactSelectionWithoutPublishingHalfInput() async throws {
    let (model, id, session) = try await fixture()
    session.input("Неоконченный ввод", selection: .init(location: 2, length: 5), composing: true, scroll: 210)
    await session.checkpoint(); await model.finishPendingPersistence()
    let saved = try model.store.loadDocument(id)
    XCTAssertEqual(saved.blocks.last?.source, "")
    let block = try XCTUnwrap(saved.blocks.last)
    let restored = DocumentSourceEditorSession(request: .init(documentID: id, block: block,
      version: saved.sourceVersion(blockID: block.id), offset: 0), model: model)
    XCTAssertEqual(restored.text, session.text)
    XCTAssertEqual(restored.selection, NSRange(location: 2, length: 5))
    XCTAssertEqual(restored.restoredScroll, 210)
    XCTAssertEqual(try model.store.documentEditingSessions().last?.isComposing, true)
  }

  func testConcurrentAgentEditPreservesDraftAndNeedsExplicitResolution() async throws {
    let (model, id, session) = try await fixture()
    session.input("My unfinished text", selection: .init(location: 4, length: 0), composing: true, scroll: 0)
    await model.finishPendingPersistence()
    let blockID = session.blockID
    try await model.performStoreCommand(publishesChanges: true) { store in
      let document = try store.loadDocument(id), target = CollaborationTarget(kind: .document, id: id)
      _ = try store.applyCollaborationAction(.init(summary: "Agent edit", expected: [.init(target: target, revision: document.contentStamp.revision)],
        operations: [.init(kind: .updateBlock, target: target, id: blockID, values: ["source": .string("Agent text")])]), actor: UUID())
    }
    await model.reloadExternalChanges()?.value
    session.input(session.text, selection: session.selection, composing: false, scroll: 0)
    await session.save()
    XCTAssertTrue(session.conflicted)
    XCTAssertEqual(session.text, "My unfinished text")
    XCTAssertEqual(try model.store.loadDocument(id).blocks.last?.source, "Agent text")
    session.useCurrentDocument(); await model.finishPendingPersistence()
    XCTAssertFalse(session.conflicted)
    XCTAssertEqual(session.text, "Agent text")
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  func testNewSourceBlockUsesCommonUndoRatherThanASeparateEditorHistory() async throws {
    let (model, id, session) = try await fixture()
    XCTAssertEqual(try model.store.loadDocument(id).blocks.last?.kind, .tex)
    model.undoLastSurfaceAction(); await model.finishPendingPersistence()
    XCTAssertFalse(try model.store.loadDocument(id).blocks.contains { $0.id == session.blockID })
  }
}
