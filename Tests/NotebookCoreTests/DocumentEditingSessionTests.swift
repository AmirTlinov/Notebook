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
  try fixture.store.saveDocumentDraft(.init(edit: edit, selectionStart: 4, selectionEnd: 9, isComposing: true))
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
