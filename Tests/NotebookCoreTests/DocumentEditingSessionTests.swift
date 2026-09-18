import Foundation
import Testing
@testable import NotebookCore

private struct EditingFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let actor = UUID()
  let store: NotebookStore
  let document: DocumentDocument

  init() throws {
    store = NotebookStore(root: root)
    document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Начало"),
      .markdown(id: "other", source: "Другой блок")])
    let index = WorkspaceIndex(items: [.document(id: document.id, title: "Черновик")],
      selectedItemID: document.id, selectedPageID: nil, stamp: .init(counter: 0, actor: actor))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    try store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: DocumentStateJournal(id: document.id, actor: actor),
      board: BoardHierarchy.initial(rootBoardID: index.rootBoardID, itemIDs: [document.id], actor: actor))
  }

  func edit(_ source: String, sequence: UInt64 = 1, sessionID: UUID = UUID()) -> DocumentSourceEdit {
    .init(sessionID: sessionID, documentID: document.id, blockID: "body", baseSource: "Начало",
      baseVersion: document.sourceVersion(blockID: "body"), source: source, sequence: sequence)
  }
}

@Test("Человеческий текст и закрытие черновика публикуются одним владельцем")
func documentEditPreservesAnotherBlockAndFencesLateDraft() throws {
  let fixture = try EditingFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let edit = fixture.edit("Продолжение")
  try fixture.store.saveDocumentDraft(.init(edit: edit, selectionStart: 3, selectionEnd: 3))
  var external = fixture.document
  let changed1 = external.replaceBlockSource(id: "other", source: "Независимая правка", actor: UUID())
  #expect(changed1)
  try fixture.store.saveDocument(external)
  let result = try fixture.store.commitDocumentSource(edit: edit, actor: fixture.actor)
  #expect(result.status == .committed)
  #expect(result.publication?.block.source == "Продолжение")
  #expect(try fixture.store.loadDocument(fixture.document.id).blocks.last?.source == "Независимая правка")
  #expect(try fixture.store.documentEditingSessions().isEmpty)
  try fixture.store.saveDocumentDraft(.init(edit: fixture.edit("Позднее сообщение", sequence: 2, sessionID: edit.sessionID)))
  #expect(try fixture.store.documentEditingSessions().isEmpty)
  #expect(try fixture.store.commitDocumentSource(edit: edit, actor: fixture.actor).status == .committed)
}

@Test("Изменённый исходник сохраняет оба текста и возвращает конфликт")
func documentSourceCASLeavesConflictDraft() throws {
  let fixture = try EditingFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let edit = fixture.edit("Мой незавершённый текст")
  try fixture.store.saveDocumentDraft(.init(edit: edit, selectionStart: 4, selectionEnd: 9, isComposing: true, scrollTop: 132.5))
  var external = fixture.document
  let changed2 = external.replaceBlockSource(id: "body", source: "Другой принятый текст", actor: UUID())
  #expect(changed2)
  try fixture.store.saveDocument(external)
  let result = try fixture.store.commitDocumentSource(edit: edit, actor: fixture.actor)
  #expect(result.status == .conflict)
  #expect(try fixture.store.loadDocument(fixture.document.id).blocks.first?.source == "Другой принятый текст")
  let drafts = try fixture.store.documentEditingSessions()
  #expect(drafts.first?.edit.source == "Мой незавершённый текст")
  #expect(drafts.first?.phase == .conflict)
  #expect(drafts.first?.selectionStart == 4)
  #expect(drafts.first?.selectionEnd == 9)
  #expect(drafts.first?.scrollTop == 132.5)
  #expect(try NotebookStore(root: fixture.root).documentEditingSessions().first?.scrollTop == 132.5)
}

@Test("Возврат того же текста не обходит проверку причинной версии")
func documentSourceCASRejectsAnABAEdit() throws {
  let fixture = try EditingFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  var external = fixture.document
  let changed3 = external.replaceBlockSource(id: "body", source: "Промежуточный", actor: UUID())
  #expect(changed3)
  let changed4 = external.replaceBlockSource(id: "body", source: "Начало", actor: UUID())
  #expect(changed4)
  try fixture.store.saveDocument(external)
  let result = try fixture.store.commitDocumentSource(edit: fixture.edit("Новое"), actor: fixture.actor)
  #expect(result.status == .conflict)
}

@Test("Удалённый блок не воскрешается сохранением его черновика")
func documentEditKeepsDraftOfDeletedBlock() throws {
  let fixture = try EditingFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let edit = fixture.edit("Текст удалённого блока")
  var external = fixture.document
  let changed5 = external.replaceContent(blocks: Array(external.blocks.suffix(1)), actor: UUID())
  #expect(changed5)
  try fixture.store.saveDocument(external)
  #expect(try fixture.store.commitDocumentSource(edit: edit, actor: fixture.actor).status == .targetMissing)
  #expect(try fixture.store.documentEditingSessions().first?.edit == edit)
  #expect(try fixture.store.loadDocument(fixture.document.id).blocks.count == 1)
}

@Test("Последовательность защищает черновик от запоздавшего ввода")
func documentDraftSequenceAndDiscardAreDurable() throws {
  let fixture = try EditingFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let id = UUID(), latest = fixture.edit("Последний", sequence: 5, sessionID: id)
  try fixture.store.saveDocumentDraft(.init(edit: latest, selectionStart: 2, selectionEnd: 2))
  try fixture.store.saveDocumentDraft(.init(edit: fixture.edit("Ранний", sequence: 2, sessionID: id)))
  #expect(try NotebookStore(root: fixture.root).documentEditingSessions().first?.edit == latest)
  try fixture.store.discardDocumentDraft(id)
  try fixture.store.saveDocumentDraft(.init(edit: fixture.edit("Поздний", sequence: 8, sessionID: id)))
  #expect(try fixture.store.documentEditingSessions().isEmpty)
}

@Test("Правка печатного блока, агент и последовательная отмена используют общий исполнитель после перезапуска")
func printMappedSourceEditsShareDurableActionUndo() throws {
  let f = try EditingFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
  let tex = "preamble\nНачало\n\nДругой блок\n\nend\n", pdf = Data("%PDF-fixture".utf8)
  let map = try DocumentPrintSourceMap(document: f.document, source: tex, pdf: pdf,
    ranges: [.init(blockID: "body", firstLine: 2, lastLine: 3), .init(blockID: "other", firstLine: 4, lastLine: 5)])
  #expect(map.blockID(atGeneratedLine: 1) == nil)
  #expect(map.blockID(atGeneratedLine: 2) == "body")
  #expect(map.blockID(atGeneratedLine: 5) == "other")
  #expect(map.blockID(atGeneratedLine: 6) == nil)
  let edit = try map.edit(blockID: "body", snapshot: f.document, source: "Человек")
  let human = try f.store.commitDocumentSource(edit: edit, actor: f.actor)
  let humanID = try #require(human.actionID)
  #expect(try f.store.collaborationAction(humanID).author == .human)
  #expect(try f.store.commitDocumentSource(edit: edit, actor: f.actor).actionID == humanID)
  let target = CollaborationTarget(kind: .document, id: f.document.id)
  let agent = try f.store.applyCollaborationAction(.init(summary: "Agent edit", expected: [
    .init(target: target, revision: f.store.targetContentRevision(target: target))],
    operations: [.init(kind: .updateBlock, target: target, id: "body", values: ["source": .string("Агент")])]), actor: UUID())
  let reopened = NotebookStore(root: f.root)
  _ = try reopened.undoCollaborationAction(agent.id, actor: f.actor)
  #expect(try reopened.loadDocument(f.document.id).blocks.first?.source == "Человек")
  _ = try NotebookStore(root: f.root).undoCollaborationAction(humanID, actor: f.actor)
  #expect(try reopened.loadDocument(f.document.id).blocks.first?.source == "Начало")
  #expect(try reopened.loadDocument(f.document.id).blocks.last?.source == "Другой блок")
}

@Test("Старая печатная страница не подменяет основание правки текущим текстом")
func printSourceMapDoesNotRebaseAStalePageOrAdoptAnABA() throws {
  let f = try EditingFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
  let map = try DocumentPrintSourceMap(document: f.document, source: "header\nbody\nother\nend\n", pdf: Data("%PDF".utf8),
    ranges: [.init(blockID: "body", firstLine: 2, lastLine: 2), .init(blockID: "other", firstLine: 3, lastLine: 3)])
  var changed = f.document
  let changedFirst = changed.replaceBlockSource(id: "body", source: "New", actor: f.actor); #expect(changedFirst)
  let changedBack = changed.replaceBlockSource(id: "body", source: "Начало", actor: f.actor); #expect(changedBack)
  try f.store.saveDocument(changed)
  #expect(throws: CollaborationError.self) { try map.edit(blockID: "body", snapshot: changed, source: "Must not rebase") }
  let edit = try map.edit(blockID: "body", snapshot: f.document, source: "Мой черновик")
  #expect(try f.store.commitDocumentSource(edit: edit, actor: f.actor).status == .conflict)
  #expect(try NotebookStore(root: f.root).documentEditingSessions().first?.edit == edit)
}
