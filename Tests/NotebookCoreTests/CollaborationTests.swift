import Foundation
import Testing
@testable import NotebookCore

private struct CollaborationFixture {
  let root: URL
  let store: NotebookStore
  let human = UUID()
  let agent = UUID()
  let pageID: UUID
  let itemID: UUID
  let boardID: UUID

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-collaboration-\(UUID())")
    store = NotebookStore(root: root)
    let (index, _) = try store.loadOrCreate(actor: human, pageSize: .init(width: 834, height: 1194))
    pageID = index.selectedPageID!
    itemID = index.selectedItemID
    boardID = index.rootBoardID
    _ = try store.loadOrCreateSpatialInk(actor: human)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  var page: CollaborationTarget { .init(kind: .page, id: pageID) }
  var board: CollaborationTarget { .init(kind: .board, id: boardID) }
  var index: CollaborationTarget { .init(kind: .workspace, id: boardID) }
  func expectation(_ target: CollaborationTarget) throws -> CollaborationExpectation {
    let stamp: VersionStamp
    switch target.kind {
    case .workspace: stamp = try store.loadIndex().stamp
    case .board, .cover: stamp = try store.loadBoard(items: store.loadIndex().items).board(target.boardID ?? target.id)!.stamp
    case .page: stamp = try store.loadPage(target.id).agentStamp
    case .document: stamp = try store.loadDocument(target.id).contentStamp
    }
    return .init(target: target, revision: stamp.revision)
  }
  func action(_ operations: [CollaborationOperation], targets: [CollaborationTarget]? = nil) throws -> CollaborationAction {
    .init(summary: "Пояснение рядом с мыслью", expected: try (targets ?? [page]).map(expectation), operations: operations)
  }
  func insert(_ id: String = "idea") -> CollaborationOperation {
    .init(kind: .insertElement, target: page, id: id, values: ["kind": .string("web"),
      "frame": .object(["x": .number(20), "y": .number(30), "width": .number(300), "height": .number(180)]),
      "source": .string("<p>Idea</p>"), "html": .string("<p>Idea</p>"), "state": .object(["count": .number(7)])])
  }
}

@Test("Повтор запроса возвращает один ход, частичная правка сохраняет состояние")
func collaborationIdempotencyAndState() throws {
  let fixture = try CollaborationFixture(); defer { fixture.clean() }
  let action = try fixture.action([fixture.insert()])
  let first = try fixture.store.applyCollaborationAction(action, actor: fixture.agent)
  #expect(try fixture.store.applyCollaborationAction(action, actor: fixture.agent) == first)
  #expect(try fixture.store.collaborationActions().count == 1)
  let changed = try fixture.action([.init(kind: .updateElement, target: fixture.page, id: "idea",
    values: ["html": .string("<h2>Idea</h2>"), "source": .string("<h2>Idea</h2>")])])
  _ = try fixture.store.applyCollaborationAction(changed, actor: fixture.agent)
  #expect(try fixture.store.loadPage(fixture.pageID).elements[0].state == .object(["count": .number(7)]))
  let collision = CollaborationAction(id: action.id, summary: "Другой ход", expected: action.expected, operations: action.operations)
  #expect(throws: CollaborationError.self) { try fixture.store.applyCollaborationAction(collision, actor: fixture.agent) }
}

@Test("Отмена сохраняет более позднюю человеческую правку и восстанавливает остальные поля")
func collaborationUndoPreservesHuman() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  let edit = try f.action([.init(kind: .updateElement, target: f.page, id: "idea", values: [
    "html": .string("<h2>Agent</h2>"), "source": .string("<h2>Agent</h2>"), "css": .string("p { color: red }")])])
  _ = try f.store.applyCollaborationAction(edit, actor: f.agent)
  var page = try f.store.loadPage(f.pageID)
  let before = page.elements[0]
  let humanElement = AgentElement(id: before.id, kind: before.kind, frame: before.frame,
    source: "Human meaning", html: "Human meaning", css: before.css, state: before.state)
  _ = page.replaceElements([humanElement], actor: f.human)
  try f.store.savePage(page)
  let undone = try f.store.undoCollaborationAction(edit.id, actor: f.human)
  let result = try f.store.loadPage(f.pageID)
  #expect(result.elements[0].source == "Human meaning")
  #expect(result.elements[0].css == "")
  #expect(undone.undo?.preserved.count == 2)
  #expect(try f.store.undoCollaborationAction(edit.id, actor: f.human) == undone)
}

@Test("Проверка пакета предшествует записи любого элемента")
func collaborationAtomicValidation() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let action = try f.action([f.insert(), .init(kind: .insertElement, target: f.page, id: "outside",
    values: ["kind": .string("web"), "source": .string("Outside"), "frame": .object([
      "x": .number(800), "y": .number(20), "width": .number(300), "height": .number(80)])])])
  #expect(throws: (any Error).self) { try f.store.applyCollaborationAction(action, actor: f.agent) }
  #expect(try f.store.loadPage(f.pageID).elements.isEmpty)
  #expect(try f.store.collaborationActions().isEmpty)
}

@Test("ID доски связывает запись с прочитанным владельцем при совпавших версиях")
func collaborationBoardAddress() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let a = UUID(), b = UUID()
  for id in [a, b] {
    let operation = CollaborationOperation(kind: .createBoard, target: f.board, id: id.uuidString,
      values: ["center": try .encode(WorldPoint(x: 100, y: 100))])
    _ = try f.store.applyCollaborationAction(f.action([operation], targets: [f.board, f.index]), actor: f.agent)
  }
  let target = CollaborationTarget(kind: .board, id: a)
  let expectation = try f.expectation(target)
  let otherExpectation = try f.expectation(.init(kind: .board, id: b))
  #expect(expectation.revision == otherExpectation.revision)
  try f.store.savePresence(.init(boardID: b, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
  let operation = CollaborationOperation(kind: .insertElement, target: target, id: "on-a", values: [
    "kind": .string("web"), "source": .string("A"), "frame": try .encode(PageRect(x: 0, y: 0, width: 100, height: 80)),
    "worldOrigin": try .encode(WorldPoint(x: 100, y: 100))])
  _ = try f.store.applyCollaborationAction(.init(summary: "На A", expected: [expectation], operations: [operation]), actor: f.agent)
  let board = try f.store.loadBoard(items: f.store.loadIndex().items)
  #expect(board.board(a)?.elements.map(\.id) == ["on-a"])
  #expect(board.board(b)?.elements.isEmpty == true)
}

@Test("Правка блока сохраняет соседей, преамбулу, состояние и выбор человека")
func collaborationDocumentPartialEdit() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let id = UUID()
  let create = CollaborationOperation(kind: .createDocument, target: f.board, id: id.uuidString, values: [
    "center": try .encode(WorldPoint(x: 200, y: 200)), "paperSize": .string("a4"), "preamble": .string("Preamble"),
    "blocks": .array([.object(["id": .string("first"), "kind": .string("markdown"), "source": .string("First")]),
      .object(["id": .string("second"), "kind": .string("markdown"), "source": .string("Second")])])])
  _ = try f.store.applyCollaborationAction(f.action([create], targets: [f.board, f.index]), actor: f.agent)
  #expect(try f.store.loadIndex().selectedItemID == f.itemID)
  let target = CollaborationTarget(kind: .document, id: id)
  let edit = try f.action([.init(kind: .updateBlock, target: target, id: "first", values: ["source": .string("Edited")])], targets: [target])
  _ = try f.store.applyCollaborationAction(edit, actor: f.agent)
  let doc = try f.store.loadDocument(id)
  #expect(doc.preamble == "Preamble")
  #expect(doc.blocks.map(\.source) == ["Edited", "Second"])
  _ = try f.store.undoCollaborationAction(edit.id, actor: f.human)
  #expect(try f.store.loadDocument(id).blocks.map(\.source) == ["First", "Second"])
}

@Test("Отмена созданной тетради сохраняет принятое человеком содержание")
func collaborationUndoAdoptedNotebook() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let item = UUID(), pageID = UUID()
  let create = try f.action([.init(kind: .createNotebook, target: f.board, id: item.uuidString, values: [
    "center": try .encode(WorldPoint(x: 200, y: 200)), "pageID": .string(pageID.uuidString)])], targets: [f.board, f.index])
  _ = try f.store.applyCollaborationAction(create, actor: f.agent)
  var page = try f.store.loadPage(pageID)
  _ = page.replaceDrawing(Data([1, 2, 3]), actor: f.human)
  try f.store.savePage(page)
  let receipt = try f.store.undoCollaborationAction(create.id, actor: f.human)
  #expect(try f.store.loadIndex().items.contains { $0.id == item })
  #expect(try f.store.loadPage(pageID).drawingData == Data([1, 2, 3]))
  #expect(receipt.undo?.preserved.isEmpty == false)
}

@Test("Подготовленная транзакция завершается следующим владельцем записи")
func collaborationRecoversPreparedTransaction() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let receipt = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  let snapshot = try f.store.collaborationSnapshot()
  let file = "pages/\(f.pageID.uuidString.lowercased()).json"
  let finalPage = snapshot[file]!
  var page = try f.store.loadPage(f.pageID)
  _ = page.replaceElements([], actor: f.human)
  try f.store.savePage(page)
  let transaction: JSONValue = .object(["writes": .object([file: finalPage]), "removals": .array([])])
  try JSONEncoder().encode(transaction).write(to: f.store.collaborationURL.appendingPathComponent("pending.json"), options: .atomic)
  #expect(try f.store.collaborationAction(receipt.id) == receipt)
  #expect(try f.store.loadPage(f.pageID).elements.map(\.id) == ["idea"])
  #expect(!FileManager.default.fileExists(atPath: f.store.collaborationURL.appendingPathComponent("pending.json").path))
}

@Test("Параллельные правки одного элемента сохраняют человеческий смысл и агентское оформление")
func collaborationConcurrentPageFields() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  let base = try f.store.loadPage(f.pageID)
  var human = base
  let element = base.elements[0]
  _ = human.replaceElements([AgentElement(id: element.id, kind: element.kind, frame: element.frame,
    source: "Human", html: "Human", css: element.css, state: element.state)], actor: f.human)
  let action = try f.action([.init(kind: .updateElement, target: f.page, id: "idea", values: [
    "source": .string("Agent"), "html": .string("Agent"), "css": .string("p { color: blue }")])])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  var agent = try f.store.loadPage(f.pageID)
  let agentBeforeMerge = agent
  _ = agent.merge(human)
  _ = human.merge(agentBeforeMerge)
  #expect(agent.elements == human.elements)
  #expect(human.elements[0].source == "Human")
  #expect(human.elements[0].css == "p { color: blue }")
  _ = agent.merge(human)
  _ = human.merge(agent)
  #expect(agent == human)
}

@Test("Разные блоки документа сходятся независимо на двух устройствах")
func collaborationConcurrentDocumentBlocks() throws {
  let actor = UUID(), a = UUID(), b = UUID()
  let original = DocumentDocument(actor: actor, blocks: [.markdown(id: "a", source: "A"), .markdown(id: "b", source: "B")])
  var left = original, right = original
  _ = left.replaceBlockSource(id: "a", source: "Left", actor: a)
  _ = right.replaceBlockSource(id: "b", source: "Right", actor: b)
  let oldLeft = left
  _ = left.merge(right)
  _ = right.merge(oldLeft)
  #expect(left.blocks.map(\.source) == ["Left", "Right"])
  #expect(right.blocks == left.blocks)
  _ = left.merge(right)
  _ = right.merge(left)
  #expect(left == right)
}

@Test("Два устройства добавляют элементы на одну доску с сохранением обоих")
func collaborationConcurrentBoardElements() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let board = try f.store.loadBoard(items: f.store.loadIndex().items).board(f.boardID)!
  var left = board, right = board
  for (id, actor) in [("a", f.human), ("b", f.agent)] {
    let element = SpatialElement(id: id, surface: .board(f.boardID), kind: .markdown,
      frame: .init(x: 0, y: 0, width: 100, height: 80), worldOrigin: .init(x: 100, y: 100),
      source: id, stamp: .init(counter: 1, actor: actor))
    if id == "a" { _ = left.upsertElement(element, expected: nil, actor: actor) }
    else { _ = right.upsertElement(element, expected: nil, actor: actor) }
  }
  let oldLeft = left
  _ = left.merge(right, itemIDs: Set(board.itemIDs))
  _ = right.merge(oldLeft, itemIDs: Set(board.itemIDs))
  #expect(Set(left.elements.map(\.id)) == ["a", "b"])
  #expect(left.elements == right.elements)
}
