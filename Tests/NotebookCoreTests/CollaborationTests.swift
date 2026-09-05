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

@Test("Указание переносится с предметом и замечает изменение исходника")
func collaborationReferenceIdentity() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]),actor:f.agent)
  let source = try f.store.referenceRevision(target:f.page,elementID:"idea")
  _ = try f.store.applyCollaborationAction(f.action([.init(kind:.moveItem,target:f.board,id:f.itemID.uuidString,
    values:["center":try .encode(WorldPoint(x:700,y:900))])],targets:[f.board]),actor:f.human)
  #expect(try f.store.referenceRevision(target:f.page,elementID:"idea") == source)
  _ = try f.store.applyCollaborationAction(f.action([.init(kind:.updateElement,target:f.page,id:"idea",values:["css":.string("color:blue")])]),actor:f.agent)
  #expect(try f.store.referenceRevision(target:f.page,elementID:"idea") != source)
}

@Test("Свободная рамка учитывает все препятствия и возвращает заполненность")
func collaborationPlacementBounds() {
  let extent = PageSize(width:834,height:1194), size = PageSize(width:300,height:180)
  let anchor = PageRect(x:20,y:20,width:300,height:180)
  let placed = NotebookStore.freeCollaborationFrame(size:size,extent:extent,anchor:anchor,direction:"right",obstacles:[anchor])
  #expect(placed?.x == 344)
  #expect(NotebookStore.freeCollaborationFrame(size:size,extent:extent,anchor:anchor,direction:"free",obstacles:[.init(x:0,y:0,width:834,height:1194)]) == nil)
}

@Test("Целый сетевой срез сохраняет локальную человеческую правку")
func collaborationAtomicNetworkCut() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]),actor:f.agent)
  var human = try f.store.collaborationContent()
  var page = human.pages[0]; let old = page.elements[0]
  let edited = AgentElement(id:old.id,kind:old.kind,frame:old.frame,source:"Human",html:"Human",css:old.css,state:old.state)
  let changed = page.replaceElements([edited],actor:f.human)
  #expect(changed)
  human.pages = [page]
  _ = try f.store.applyCollaborationAction(f.action([.init(kind:.updateElement,target:f.page,id:"idea",values:["css":.string("color:green")])]),actor:f.agent)
  let incoming = try f.store.collaborationContent()
  let merged = try f.store.mergeCollaborationContent(incoming,local:human)
  #expect(merged.pages[0].elements[0].source == "Human")
  #expect(merged.pages[0].elements[0].css == "color:green")
  #expect(try f.store.collaborationContent() == merged)
}

@Test("Миграция сохраняет точную копию и выполняется один раз")
func collaborationOneTimeMigration() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let raw = try Data(contentsOf:f.store.pageURL(f.pageID))
  try f.store.migrateCollaborationStorage()
  let backup = f.root.appendingPathComponent("migrations/before-collaboration-v1/pages/\(f.pageID.uuidString.lowercased()).json")
  #expect(try Data(contentsOf:backup) == raw)
  #expect(try f.store.loadPage(f.pageID).collaboration != nil)
  try f.store.migrateCollaborationStorage()
  #expect(try Data(contentsOf:backup) == raw)
}

@Test("Состояние блока имеет явную операцию, отдельную версию и устойчивую отмену")
func collaborationBlockStateUndoAndMerge() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let id = UUID(), target = CollaborationTarget(kind:.document,id:id)
  _ = try f.store.applyCollaborationAction(f.action([.init(kind:.createDocument,target:f.board,id:id.uuidString,values:[
    "center":try .encode(WorldPoint.zero),"paperSize":.string("a4"),"blocks":.array([
      .object(["id":.string("counter"),"kind":.string("interactive"),"html":.string("<button>+</button>"),"initialState":.number(0)])])])],targets:[f.board,f.index]),actor:f.agent)
  let document = try f.store.loadDocument(id), state = try f.store.loadDocumentState(id)
  let action = CollaborationAction(summary:"Счётчик показывает семь",expected:[.init(target:target,revision:document.contentStamp.revision,stateRevision:state.stamp.revision)],operations:[
    .init(kind:.setBlockState,target:target,id:"counter",values:["state":.number(7)])])
  _ = try f.store.applyCollaborationAction(action,actor:f.agent)
  let delivered = try f.store.loadDocumentState(id)
  #expect(delivered.value(for:"counter") == .number(7))
  #expect(try f.store.loadDocument(id).contentStamp == document.contentStamp)
  _ = try f.store.undoCollaborationAction(action.id,actor:f.human)
  var final = try f.store.loadDocumentState(id)
  #expect(final.value(for:"counter") == .number(0))
  _ = final.merge(delivered)
  #expect(final.value(for:"counter") == .number(0))
  var human = delivered, agent = delivered
  _ = human.commit(blockID:"counter",value:.number(11),actor:f.human)
  _ = agent.commit(blockID:"counter",value:.number(12),actor:f.agent,human:false)
  _ = human.merge(agent); _ = agent.merge(human)
  #expect(human.value(for:"counter") == .number(11))
  #expect(agent.value(for:"counter") == .number(11))
}

@Test("Публикация хода переносит изменённых владельцев и сохраняет остальную тетрадь")
func collaborationSparsePublication() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  try f.store.migrateCollaborationStorage()
  let previous = try f.store.collaborationContent()
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]),actor:f.agent)
  let next = try f.store.collaborationContent()
  let patch = next.publication(since:previous)
  #expect(patch.pages.count == 1)
  #expect(patch.ink.actions.isEmpty)
  var receiver = previous
  receiver.merge(patch)
  #expect(receiver == next)
  #expect(next.publication(since:next).pages.isEmpty)
}

@Test("Переход человека меняет внимание, сохраняя хеш содержания доски")
func collaborationBoardReferenceIgnoresSelection() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let id = UUID()
  _ = try f.store.applyCollaborationAction(f.action([.init(kind:.createNotebook,target:f.board,id:id.uuidString,
    values:["center":try .encode(WorldPoint(x:1200,y:0)),"pageID":.string(UUID().uuidString)])],targets:[f.board,f.index]),actor:f.agent)
  let source = try f.store.referenceRevision(target:f.board)
  var workspace = try f.store.loadIndex()
  _ = workspace.selectItem(id,actor:f.human)
  try f.store.saveIndex(workspace)
  #expect(try f.store.referenceRevision(target:f.board) == source)
}

@Test("Размещение защищает рассмотренные чернила при неизменной версии элементов")
func collaborationPlacementRejectsChangedInk() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let source = try f.store.referenceRevision(target:f.page)
  let expectation = CollaborationExpectation(target:f.page,revision:try f.expectation(f.page).revision,sourceRevision:source)
  var page = try f.store.loadPage(f.pageID)
  let changed = page.replaceDrawing(Data([1,2,3]),actor:f.human)
  #expect(changed)
  try f.store.savePage(page)
  let action = CollaborationAction(summary:"Продолжение рядом",expected:[expectation],operations:[f.insert()])
  do {
    _ = try f.store.applyCollaborationAction(action,actor:f.agent)
    Issue.record("Рамка должна быть пересчитана после рукописи")
  } catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
  #expect(try f.store.loadPage(f.pageID).elements.isEmpty)
}

@Test("Конфликт истории отклоняет весь пришедший срез до публикации")
func collaborationReceivedActionIdentityIsAtomic() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let action = try f.action([f.insert()])
  let receipt = try f.store.applyCollaborationAction(action,actor:f.agent)
  let before = try f.store.collaborationContent()
  var incoming = before
  let prior = incoming.pages[0].elements[0]
  _ = incoming.pages[0].replaceElements([AgentElement(id:prior.id,kind:prior.kind,frame:prior.frame,source:"Changed",html:"Changed")],actor:f.agent)
  let conflict = CollaborationAction(id:action.id,summary:"Другое намерение",references:action.references,expected:action.expected,operations:action.operations)
  let counterfeit = CollaborationReceipt(id:receipt.id,action:conflict,createdAt:receipt.createdAt,revisions:receipt.revisions,changes:receipt.changes)
  #expect(throws:CollaborationError.self) { try f.store.receiveCollaboration(.init(content:incoming,actions:[counterfeit])) }
  #expect(try f.store.collaborationContent() == before)
  #expect(try f.store.collaborationAction(action.id) == receipt)
}

@Test("Сошедшееся состояние получает версию собственного видимого результата")
func collaborationStateMergeNamesTheCombinedResult() {
  let id = UUID(), actorA = UUID(), actorB = UUID()
  var a = DocumentStateJournal(id:id,actor:actorA), b = DocumentStateJournal(id:id,actor:actorA)
  _ = a.commit(blockID:"a",value:.number(1),actor:actorA)
  _ = b.commit(blockID:"b",value:.number(2),actor:actorB)
  let frontier = max(a.stamp,b.stamp)
  _ = a.merge(b); _ = b.merge(a)
  #expect(a == b)
  #expect(a.stamp > frontier)
  let settled = a
  _ = a.merge(b)
  #expect(a == settled)
}
