import Foundation
import Darwin
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

  init(pageSize: PageSize = .init(width: 834, height: 1194)) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-collaboration-\(UUID())")
    store = NotebookStore(root: root)
    let (index, _) = try store.loadOrCreate(actor: human, pageSize: pageSize)
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

@Test("Целевой лист и ссылка не читают чужие страницы и историю ходов")
func addressedReferenceIgnoresUnrelatedSources() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let otherID = UUID(), otherPage = UUID()
  _ = try f.store.applyCollaborationAction(f.action([.init(kind: .createNotebook, target: f.board,
    id: otherID.uuidString, values: ["pageID": .string(otherPage.uuidString), "center": try .encode(WorldPoint.zero)])],
    targets: [f.board, f.index]), actor: f.agent)
  let legacy = try f.store.collaborationSnapshot()
  let expected = try NotebookStore.referenceRevision(target: f.page, files: legacy)
  let request = try f.store.requestTargetRender(target: f.page, expectedRevision: f.expectation(f.page).revision)
  try f.store.fixtureWrite(Data("unrelated damaged page".utf8), to: f.store.pageURL(otherPage))
  try f.store.fixtureWrite(Data("unrelated damaged history".utf8), to:
    f.store.collaborationActionsURL.appendingPathComponent(UUID().uuidString.lowercased() + ".json"))
  let files = try f.store.referenceSourceFiles(target: f.page)
  #expect(Set(files.keys) == ["pages/\(f.pageID.uuidString.lowercased()).json"])
  #expect(try f.store.referenceRevision(target: f.page) == expected)
  let reference = CollaborationReference(target: f.page, revision: expected)
  #expect(try f.store.referenceStatus(reference).status == .current)
  #expect(try f.store.requestTargetRender(target: f.page, expectedRevision: f.expectation(f.page).revision) == request)
}

@Test("Адрес документа читает его блоки и состояние, а состояние меняет идентичность снимка")
func addressedDocumentIncludesItsInteractiveState() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let id = UUID(), target = CollaborationTarget(kind: .document, id: id)
  _ = try f.store.applyCollaborationAction(f.action([.init(kind: .createDocument, target: f.board,
    id: id.uuidString, values: ["center": try .encode(WorldPoint.zero), "paperSize": .string("letter"),
      "blocks": .array([.object(["id": .string("counter"), "kind": .string("interactive"),
        "html": .string("<button>+</button>"), "initialState": .number(0)])])])], targets: [f.board, f.index]), actor: f.agent)
  let legacy = try f.store.collaborationSnapshot(), suffix = id.uuidString.lowercased() + ".json"
  let files = try f.store.referenceSourceFiles(target: target)
  #expect(Set(files.keys) == Set(["documents/" + suffix, "document-states/" + suffix]))
  #expect(try NotebookStore.referenceRevision(target: target, files: files)
    == NotebookStore.referenceRevision(target: target, files: legacy))
  #expect(try NotebookStore.referenceRevision(target: target, elementID: "counter", files: files)
    == NotebookStore.referenceRevision(target: target, elementID: "counter", files: legacy))
  let version = try f.expectation(target).revision
  let before = try f.store.requestTargetRender(target: target, expectedRevision: version)
  var state = try f.store.loadDocumentState(id)
  _ = state.commit(blockID: "counter", value: .number(7), actor: f.human)
  try f.store.saveDocumentState(state)
  let after = try f.store.requestTargetRender(target: target, expectedRevision: version)
  #expect(before.id != after.id)
  #expect(before.sourceRevision != after.sourceRevision)
  try f.store.fixtureWrite(Data("unrelated damaged drawing".utf8), to: f.store.pageURL(f.pageID))
  #expect(try f.store.referenceRevision(target: target) == after.sourceRevision)
}

@Test("Доска и обложка сохраняют полную идентичность без чтения содержимого ветви")
func addressedBoardPreservesHistoricalIdentityAndScope() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let a = UUID(), b = UUID(), documentA = UUID(), documentB = UUID()
  for id in [a, b] {
    _ = try f.store.applyCollaborationAction(f.action([.init(kind: .createBoard, target: f.board,
      id: id.uuidString, values: ["center": try .encode(WorldPoint.zero)])], targets: [f.board, f.index]), actor: f.agent)
  }
  for (boardID, id) in [(a, documentA), (b, documentB)] {
    let target = CollaborationTarget(kind: .board, id: boardID)
    _ = try f.store.applyCollaborationAction(f.action([.init(kind: .createDocument, target: target,
      id: id.uuidString, values: ["center": try .encode(WorldPoint.zero), "paperSize": .string("letter"),
        "blocks": .array([.object(["id": .string("body"), "kind": .string("markdown"),
          "source": .string("This text belongs to the document, not its cover.")])])])], targets: [target, f.index]), actor: f.agent)
  }
  let targets = [CollaborationTarget(kind: .board, id: a), .init(kind: .cover, id: documentA, boardID: a)]
  let legacy = try f.store.collaborationSnapshot()
  let expected = try targets.map { try NotebookStore.referenceRevision(target: $0, files: legacy) }
  try f.store.fixtureWrite(Data("unrelated damaged document".utf8), to: f.store.documentURL(documentB))
  for (target, revision) in zip(targets, expected) {
    let files = try f.store.referenceSourceFiles(target: target)
    if target.kind == .cover { #expect(files["documents/\(documentA.uuidString.lowercased()).json"] == .object(["paperSize": .string("letter")])) }
    else { #expect(files["documents/\(documentA.uuidString.lowercased()).json"] == nil) }
    #expect(files["documents/\(documentB.uuidString.lowercased()).json"] == nil)
    #expect(!files.keys.contains { $0.hasPrefix("pages/") || $0.hasPrefix("document-states/") || $0.hasPrefix("collaboration/") })
    #expect(try f.store.referenceRevision(target: target) == revision)
    #expect(try f.store.requestTargetRender(target: target, expectedRevision: f.expectation(target).revision).sourceRevision == revision)
  }
}

@Test("Ссылка на портал включает дочернюю доску и размеры вложенной бумаги")
func portalCoverReferenceOwnsItsVisibleChildSources() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let portalID = UUID(), documentID = UUID()
  _ = try f.store.applyCollaborationAction(f.action([.init(kind: .createBoard, target: f.board,
    id: portalID.uuidString, values: ["center": try .encode(WorldPoint.zero)])], targets: [f.board, f.index]), actor: f.agent)
  let child = CollaborationTarget(kind: .board, id: portalID)
  _ = try f.store.applyCollaborationAction(f.action([.init(kind: .createDocument, target: child,
    id: documentID.uuidString, values: ["center": try .encode(WorldPoint.zero), "paperSize": .string("letter")])],
    targets: [child, f.index]), actor: f.agent)
  let portal = CollaborationTarget(kind: .cover, id: portalID, boardID: f.boardID)
  let files = try f.store.referenceSourceFiles(target: portal)
  #expect(files["documents/\(documentID.uuidString.lowercased()).json"] == nil)
  let original = try f.store.referenceRevision(target: portal)
  let content = try f.store.collaborationContent()
  let memory = try content.sourceFiles(including: content.referenceFilePaths(for: [portal]))
  #expect(try NotebookStore.referenceRevision(target: portal, files: memory) == original)
  let parentVersion = try f.expectation(portal).revision
  let before = try f.store.requestTargetRender(target: portal, expectedRevision: parentVersion)
  _ = try f.store.applyCollaborationAction(f.action([.init(kind: .insertElement, target: child, id: "inside",
    values: ["kind": .string("web"), "source": .string("<svg/>"), "html": .string("<svg/>"),
      "frame": try .encode(PageRect(x: 0, y: 0, width: 100, height: 80)),
      "worldOrigin": try .encode(WorldPoint.zero)])], targets: [child]), actor: f.agent)
  #expect(try f.expectation(portal).revision == parentVersion)
  let after = try f.store.requestTargetRender(target: portal, expectedRevision: parentVersion)
  #expect(after.id != before.id)
  #expect(after.sourceRevision != original)
  #expect(try f.store.referenceStatus(.init(target: portal, revision: original)).status == .changed)
}


@Test("История готовит один срез только нужных владельцев и сохраняет точность доработок")
func collaborationReadSnapshotUsesCurrentSources() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let receipt = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  var content = try f.store.collaborationContent()
  let before = receipt.resultReferences(in: content)[0]
  let old = content.pages[0].elements[0]
  _ = content.pages[0].replaceElements([.init(id: old.id, kind: old.kind,
    frame: .init(x: 120, y: 130, width: 300, height: 180), source: "Human", html: "Human", state: old.state)], actor: f.human)
  let unrelated = PageDocument(id: UUID(), size: .init(width: 834, height: 1194), actor: f.human,
    drawingData: Data(repeating: 1, count: 16 * 1024 * 1024))
  content.pages.append(unrelated)
  let missing = CollaborationReference(target: f.page, elementID: "missing", revision: "missing")
  let regional = CollaborationReference(target: f.page, region: .init(x: 1, y: 1, width: 20, height: 20), revision: "old")
  let references = [before, missing, regional]
  let paths = content.referenceFilePaths(for: references.map(\.target) + receipt.resultTargets(in: content)).union(receipt.changes.map(\.file))
  #expect(!paths.contains("pages/\(unrelated.id.uuidString.lowercased()).json"))
  let files = try content.sourceFiles(including: paths)
  #expect(!files.keys.contains("pages/\(unrelated.id.uuidString.lowercased()).json"))
  let snapshot = try CollaborationReadSnapshot(content: content, actions: [receipt], references: references)
  #expect(snapshot.results[receipt.id] == receipt.resultReferences(in: content))
  #expect(snapshot.results[receipt.id]?.first?.region?.x == 120)
  #expect(snapshot.continuations[receipt.id] == receipt.continuations(in: files))
  #expect(snapshot.continuations[receipt.id]?.contains { $0.author == .human } == true)
  #expect(snapshot.references[before.id]?.status == .changed)
  #expect(snapshot.references[missing.id]?.status == .targetMissing)
  #expect(snapshot.references[regional.id]?.status == .checking)
}

@Test("Отменённая подготовка истории не возвращает частичный результат")
func collaborationReadSnapshotCancellation() async throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let content = try f.store.collaborationContent()
  await Task.detached {
    withUnsafeCurrentTask { $0?.cancel() }
    #expect(throws: CancellationError.self) {
      try CollaborationReadSnapshot(content: content, actions: [], references: [])
    }
  }.value
}

@Test("Проверка готового отпечатка не захватывает замок содержания повторно")
func referenceProofReadDoesNotLockContent() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let revision = try f.store.referenceRevision(target: f.page)
  let reference = CollaborationReference(target: f.page, region: .init(x: 0, y: 0, width: 30, height: 30), revision: revision)
  let result = try f.store.withMutationLock {
    try f.store.referenceStatus(reference, currentRevision: revision)
  }
  #expect(result.status == .checking)
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
  let continued = try f.store.collaborationContinuations(edit.id)
  #expect(continued.count == 2)
  #expect(continued.allSatisfy { $0.author == .human && $0.elementID == "idea" })
  let undone = try f.store.undoCollaborationAction(edit.id, actor: f.human)
  #expect(try f.store.collaborationContinuations(edit.id).isEmpty)
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
  _ = page.replaceDrawing(pageDrawingFixture(Data([1, 2, 3])), actor: f.human)
  try f.store.savePage(page)
  let receipt = try f.store.undoCollaborationAction(create.id, actor: f.human)
  #expect(try f.store.loadIndex().items.contains { $0.id == item })
  #expect(try f.store.loadPage(pageID).drawingData == pageDrawingFixture(Data([1, 2, 3])))
  #expect(receipt.undo?.preserved.isEmpty == false)
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
  _ = try f.store.applyCollaborationAction(.init(additionalOwners: [.init(kind: .cover, id: f.itemID, boardID: f.boardID)], summary: "Переместить носитель", expected: [f.expectation(f.board)], operations: [.init(kind:.moveItem,target:f.board,id:f.itemID.uuidString,
    values:["center":try .encode(WorldPoint(x:700,y:900))])]),actor:f.human)
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

@Test("Имена метаданных каталога внутри состояния остаются содержанием и отменяются")
func collaborationElementStatePreservesWorkspaceMetadataNames() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  func state(_ value: Int) -> JSONValue {
    .object(["pageOrders": .number(Double(value)),
      "nested": .array([.object(["pageOrderNodes": .string("nodes-\(value)"),
        "isProjection": .bool(value != 0)])])])
  }
  let initial = state(0), edited = state(1)
  var values = f.insert().values
  values["state"] = initial
  let insertion = CollaborationOperation(kind: .insertElement, target: f.page,
    id: "idea", values: values)
  _ = try f.store.applyCollaborationAction(f.action([insertion]), actor: f.agent)
  let action = try f.action([.init(kind: .setElementState, target: f.page,
    id: "idea", values: ["state": edited])])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(!receipt.changes.isEmpty)
  #expect(try f.store.loadPage(f.pageID).elements[0].state == edited)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(undone.undo?.restored == receipt.changes.count)
  #expect(undone.undo?.preserved.isEmpty == true)
  #expect(try f.store.loadPage(f.pageID).elements[0].state == initial)
}

@Test("Публикация хода переносит изменённых владельцев и сохраняет остальную тетрадь")
func collaborationSparsePublication() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let previous = try f.store.collaborationContent()
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]),actor:f.agent)
  let next = try f.store.collaborationContent()
  let patch = try next.publication(since:previous)
  #expect(patch.pages.count == 1)
  #expect(patch.ink.actions.isEmpty)
  var receiver = previous
  try receiver.merge(patch)
  #expect(receiver == next)
  #expect(try next.publication(since:next).pages.isEmpty)
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
  let changed = page.replaceDrawing(pageDrawingFixture(Data([1,2,3])),actor:f.human)
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

@Test("Новый общий фрагмент сохраняет прежнее указание и адрес начатого хода")
func durableContextDoesNotFollowHumanSelection() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let source = CollaborationReference(target: f.page, revision: try f.store.referenceRevision(target: f.page), label: "Рисунок")
  let first = try f.store.appendContext(references: [source], author: .human, actor: f.human, select: true)
  let next = try f.store.appendContext(references: [source], author: .human, actor: f.human, select: true)
  let answer = try f.store.appendContext(references: [source], author: .agent, actor: f.agent,
    contextID: first.id, replyTo: first.entry.id)
  #expect(answer.entry.replyTo == first.entry.id)
  let action = CollaborationAction(contextID: first.id, summary: "Ответ на исходный рисунок",
    references: [source], expected: [try f.expectation(f.page)], operations: [f.insert()])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(receipt.action.resolvedContextID == first.id)
  #expect(try f.store.sharedContexts().selection?.contextID == next.id)
  #expect(try f.store.sharedContexts().contexts.count == 2)
  #expect(try f.store.applyCollaborationAction(action, actor: f.agent) == receipt)
  let restarted = NotebookStore(root: f.root)
  #expect(try restarted.sharedContextEntry(contextID: first.id, entryID: answer.entry.id) == answer.entry)
  _ = try restarted.undoCollaborationAction(receipt.id, actor: f.human)
  #expect(try restarted.sharedContextEntry(contextID: first.id, entryID: answer.entry.id) == answer.entry)
}

@Test("Независимые ответы сходятся в одном контексте без перезаписи")
func contextEntriesMergeWithoutLosingIndependentReplies() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let source = CollaborationReference(target: f.page, revision: try f.store.referenceRevision(target: f.page))
  let first = try f.store.appendContext(references: [source], author: .human, actor: f.human, select: true)
  let replyA = SharedContextEntry(author: .agent, references: [source], replyTo: first.entry.id,
    stamp: .init(counter: 2, actor: f.agent))
  let replyB = SharedContextEntry(author: .agent, references: [source], replyTo: first.entry.id,
    stamp: .init(counter: 2, actor: UUID()))
  let a = SharedContext(id: first.id, entries: [first.entry] + [replyA])
  let b = SharedContext(id: first.id, entries: [first.entry] + [replyB])
  _ = try f.store.receiveCollaboration(.init(contexts: [a]))
  _ = try f.store.receiveCollaboration(.init(contexts: [b]))
  let merged = try #require(f.store.sharedContexts().contexts.first)
  #expect(Set(merged.entries.map(\.id)) == Set([first.entry.id, replyA.id, replyB.id]))
  _ = try f.store.receiveCollaboration(.init(contexts: [a]))
  #expect(try f.store.sharedContexts().contexts.first == merged)
  let corrupted = SharedContextEntry(id: replyA.id, author: .human, references: [source], stamp: replyA.stamp)
  #expect(throws: CollaborationError.self) {
    try f.store.receiveCollaboration(.init(contexts: [.init(id: first.id, entries: [corrupted])]))
  }
  #expect(try f.store.sharedContexts().contexts.first == merged)
}

@Test("Отсутствующий контекст отклоняет весь ход до публикации")
func missingContextDoesNotPublishContent() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let before = try f.store.loadPage(f.pageID)
  let action = CollaborationAction(contextID: UUID(), summary: "Нет источника",
    expected: [try f.expectation(f.page)], operations: [f.insert()])
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(action, actor: f.agent) }
  #expect(try f.store.loadPage(f.pageID) == before)
  #expect(try f.store.collaborationActions().isEmpty)
}


@Test("Общий поиск возвращает физический путь, исходник и версию одного завершённого снимка")
func sharedSearchOwnsAppAndAgentResults() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  let found = try f.store.search("IDEA", limit: 1)
  #expect(found.total == 1)
  #expect(!found.truncated)
  let hit = try #require(found.results.first)
  #expect(hit.target == f.page)
  #expect(hit.elementID == "idea")
  #expect(hit.path.last == "Лист 1")
  #expect(hit.preview == "Idea")
  #expect(hit.reference.revision == (try f.store.referenceRevision(target: f.page, elementID: "idea")))
  let same = try f.store.search("idea")
  #expect(same.results.map(\.preview) == found.results.map(\.preview))
  #expect(same.results.map(\.path) == found.results.map(\.path))
}

@Test("Самостоятельный ход не присоединяется к случайно совпавшему ID чужого контекста")
func autonomousActionCannotReuseContextIdentity() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let source = CollaborationReference(target: f.page, revision: try f.store.referenceRevision(target: f.page))
  let context = try f.store.appendContext(references: [source], author: .human, actor: f.human, select: true)
  let original = try f.action([f.insert()])
  let action = CollaborationAction(id: context.id, summary: original.summary, expected: original.expected, operations: original.operations)
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(action, actor: f.agent) }
  #expect(try f.store.loadPage(f.page.id).elements.isEmpty)
  #expect(try f.store.sharedContexts().contexts == [SharedContext(id: context.id, entries: [context.entry])])
}


private func completePlacementMap(_ f: CollaborationFixture, _ request: CollaborationPlacementRequest,
  ink: [PageRect] = []) throws -> CollaborationPlacement {
  let pending = try f.store.suggestCollaborationPlacement(request)
  #expect(pending.status == .snapshotPending)
  #expect(pending.placements.isEmpty && pending.moves.isEmpty)
  let render = try #require(pending.renderRequest)
  let receipt = TargetRenderReceipt(request: render, status: "ready", inkRegions: ink)
  try JSONEncoder().encode(receipt).write(to: f.store.targetReceiptURL(render.id), options: .atomic)
  return try f.store.suggestCollaborationPlacement(request)
}

@Test("Пакет размещает связанные элементы по единой карте чернил без записи содержания")
func placementPackageIsReadOnlyAndAvoidsFinalInk() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let before = try f.store.collaborationContent()
  let request = CollaborationPlacementRequest(target: f.page, expectedRevision: try f.expectation(f.page).revision,
    items: [.init(id: "question", size: .init(width: 200, height: 100)),
      .init(id: "conclusion", size: .init(width: 200, height: 100), relativeToID: "question", direction: .below)])
  let ink = PageRect(x: 0, y: 0, width: 420, height: 300)
  let planned = try completePlacementMap(f, request, ink: [ink])
  #expect(planned.status == .ready && planned.placements.count == 2 && planned.moves.isEmpty)
  let first = planned.placements[0].frame, second = planned.placements[1].frame
  #expect(second.x == first.x && second.y == first.y + first.height + 24)
  #expect(planned.placements.allSatisfy { NotebookStore.collaborationFrameIsFree($0.frame, extent: .init(width: 834, height: 1194), obstacles: [ink]) })
  #expect(try f.store.collaborationContent() == before)
  #expect(try f.store.collaborationActions().isEmpty)
}

@Test("Перестройка двигает только разрешённый фрагмент и отменяется после человеческого продолжения")
func placementRecompositionKeepsHumanContinuation() throws {
  let f = try CollaborationFixture(pageSize: .init(width: 320, height: 400)); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([.init(kind: .insertElement, target: f.page, id: "source", values: [
    "kind": .string("web"), "source": .string("Source"), "html": .string("Source"), "state": .number(7),
    "frame": try .encode(PageRect(x: 110, y: 110, width: 100, height: 100))])]), actor: f.agent)
  let reference = CollaborationReference(target: f.page, elementID: "source", revision: try f.store.referenceRevision(target: f.page, elementID: "source"))
  let context = try f.store.appendContext(references: [reference], author: .human, actor: f.human, select: true)
  let request = CollaborationPlacementRequest(target: f.page, expectedRevision: try f.expectation(f.page).revision,
    items: [.init(id: "continuation", size: .init(width: 240, height: 180))],
    movable: [.init(target: f.page, elementID: "source")], contextID: context.id)
  let planned = try completePlacementMap(f, request)
  #expect(planned.status == .ready && planned.moves.count == 1)
  #expect(planned.moves[0].id == "source")
  _ = try f.store.appendContext(references: [reference], author: .human, actor: f.human, select: true)
  let operation = CollaborationOperation(kind: .insertElement, target: f.page, id: "continuation", values: [
    "kind": .string("web"), "source": .string("Next"), "html": .string("Next"), "frame": try .encode(planned.placements[0].frame)])
  let action = CollaborationAction(contextID: planned.contextID, summary: "Продолжение у исходника", expected: planned.expected, operations: planned.moves + [operation])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(receipt.action.contextID == context.id)
  #expect(try f.store.applyCollaborationAction(action, actor: f.agent) == receipt)
  var human = try f.store.loadPage(f.pageID)
  human.replaceElements(human.elements.map { $0.id == "source" ? AgentElement(id: $0.id, kind: $0.kind, frame: $0.frame, source: $0.source, html: "Human continuation", css: $0.css, javaScript: $0.javaScript, state: $0.state) : $0 }, actor: f.human)
  try f.store.savePage(human)
  let restarted = NotebookStore(root: f.root)
  _ = try restarted.undoCollaborationAction(action.id, actor: f.human)
  let result = try restarted.loadPage(f.pageID)
  #expect(result.elements.count == 1)
  #expect(result.elements[0].html == "Human continuation" && result.elements[0].state == .number(7))
  #expect(result.elements[0].frame == PageRect(x: 110, y: 110, width: 100, height: 100))
}

@Test("Геометрия вне контекста требует явного владельца даже при обходе расчёта размещения")
func compositionScopeCannotBeBypassed() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  let request = CollaborationPlacementRequest(target: f.page, expectedRevision: try f.expectation(f.page).revision,
    items: [.init(id: "new", size: .init(width: 100, height: 100))], movable: [.init(target: f.page, elementID: "idea")])
  #expect(throws: CollaborationError.self) { try f.store.suggestCollaborationPlacement(request) }
  let move = CollaborationOperation(kind: .updateElement, target: f.page, id: "idea", values: ["frame": try .encode(PageRect(x: 350, y: 30, width: 300, height: 180))])
  let before = try f.store.collaborationContent()
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(f.action([move]), actor: f.agent) }
  #expect(try f.store.collaborationContent() == before)
  _ = try f.store.applyCollaborationAction(.init(additionalOwners: [f.page], summary: "Явно переместить", expected: [f.expectation(f.page)], operations: [move]), actor: f.agent)
}

@Test("Изменение чернил между предложением и записью отвергает весь пакет")
func placementCannotOverwriteNewInk() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let planned = try completePlacementMap(f, .init(target: f.page, expectedRevision: f.expectation(f.page).revision,
    items: [.init(id: "new", size: .init(width: 120, height: 80))]))
  var page = try f.store.loadPage(f.pageID); page.replaceDrawing(pageDrawingFixture(Data([1, 2, 3])), actor: f.human); try f.store.savePage(page)
  let action = CollaborationAction(summary: "Поздняя запись", expected: planned.expected, operations: [f.insert("new")])
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(action, actor: f.agent) }
  #expect(try f.store.loadPage(f.pageID).elements.isEmpty)
  #expect(try f.store.loadPage(f.pageID).drawingData == pageDrawingFixture(Data([1, 2, 3])))
}

@Test("Непоместившийся пакет не возвращает частичное размещение")
func placementUnavailableIsWholePackage() throws {
  let f = try CollaborationFixture(pageSize: .init(width: 320, height: 400)); defer { f.clean() }
  let planned = try completePlacementMap(f, .init(target: f.page, expectedRevision: f.expectation(f.page).revision,
    items: [.init(id: "a", size: .init(width: 260, height: 250)), .init(id: "b", size: .init(width: 260, height: 250))]))
  #expect(planned.status == .unavailable && planned.placements.isEmpty && planned.moves.isEmpty)
}


@Test("Указанный лист разрешает перенос его тетради, но не чужого носителя")
func pageContextOwnsItsPhysicalCarrier() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let context = try f.store.appendContext(references: [.init(target: f.page, region: .init(x: 20, y: 20, width: 80, height: 80), revision: f.store.referenceRevision(target: f.page))], author: .human, actor: f.human)
  let move = CollaborationOperation(kind: .moveItem, target: f.board, id: f.itemID.uuidString, values: ["center": try .encode(WorldPoint(x: 600, y: 700))])
  _ = try f.store.applyCollaborationAction(.init(contextID: context.id, summary: "Передвинуть рисунок с носителем", expected: [f.expectation(f.board)], operations: [move]), actor: f.agent)
  #expect(try f.store.loadBoard(items: f.store.loadIndex().items).board(f.boardID)?.focusedCenter(of: f.itemID) == WorldPoint(x: 600, y: 700))
}

@Test("Новые элементы одного пакета можно упорядочить без разрешения на чужое содержание")
func newPackageElementsCanBeReordered() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  _ = try f.store.applyCollaborationAction(f.action([f.insert("a"),f.insert("b"),
    .init(kind: .reorderElements, target: f.page, values: ["ids": .array([.string("b"),.string("a")])])]), actor: f.agent)
  #expect(try f.store.loadPage(f.pageID).elements.map(\.id) == ["b","a"])
}

@Test("Контакт удерживает весь ход без записи, а отпускание повторно проверяет версии")
func inputHoldsPublicationAndRechecks() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let session = UUID()
  let action = try f.action([f.insert()])
  try f.store.saveInputActivity(.init(deviceID: f.human, sessionID: session, sequence: 1, targets: [f.page]))
  do { _ = try f.store.applyCollaborationAction(action, actor: f.agent); Issue.record("Контакт должен удерживать публикацию") }
  catch let error as CollaborationError { #expect(error.code == "input_active") }
  #expect(try f.store.collaborationActions().isEmpty)
  #expect(try f.store.loadPage(f.pageID).elements.isEmpty)
  var humanPage = try f.store.loadPage(f.pageID)
  _ = humanPage.replaceElements([.init(id: "human", kind: .markdown, frame: .init(x: 20, y: 400, width: 200, height: 80), source: "Human", html: "Human")], actor: f.human)
  try f.store.saveMergedPage(humanPage)
  try f.store.saveInputActivity(.init(deviceID: f.human, sessionID: session, sequence: 2, targets: []))
  do { _ = try f.store.applyCollaborationAction(action, actor: f.agent); Issue.record("Поздняя правка требует нового рассмотрения") }
  catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
  #expect(try f.store.loadPage(f.pageID).elements.map(\.id) == ["human"])
  #expect(try f.store.collaborationActions().isEmpty)
}

@Test("Контакт доски удерживает её листы, но не другую доску; старое отпускание не снимает новый контакт")
func inputScopeAndSequence() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let session = UUID()
  let action = try f.action([f.insert()])
  try f.store.saveInputActivity(.init(deviceID: f.human, sessionID: session, sequence: 2, targets: [f.board]))
  try f.store.saveInputActivity(.init(deviceID: f.human, sessionID: session, sequence: 1, targets: []))
  #expect(try f.store.inputActivities().first?.isActive == true)
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(action, actor: f.agent) }
  try f.store.saveInputActivity(.init(deviceID: f.human, sessionID: session, sequence: 3, targets: [.init(kind: .board, id: UUID())]))
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  try f.store.saveInputActivity(.init(deviceID: f.human, sessionID: session, sequence: 4, targets: [f.page]))
  #expect(try f.store.applyCollaborationAction(action, actor: f.agent) == receipt, "Квитанция повтора доступна даже при новом касании")
  #expect(throws: CollaborationError.self) { try f.store.undoCollaborationAction(action.id, actor: f.agent) }
  try f.store.resetInputActivities()
  #expect(try f.store.undoCollaborationAction(action.id, actor: f.agent).undo != nil)
}

@Test("Удерживаемые пакеты сходятся в один срез, сохраняя окончательную отмену")
func heldEnvelopesKeepOneCausalCut() throws {
  let f = try CollaborationFixture(); defer { f.clean() }
  let first = try f.store.applyCollaborationAction(f.action([f.insert()]), actor: f.agent)
  let content = try f.store.collaborationContent()
  let undone = try f.store.undoCollaborationAction(first.id, actor: f.agent)
  var held = CollaborationEnvelope(content: content, actions: [first])
  let latest = CollaborationEnvelope(content: try f.store.collaborationContent(), actions: [undone])
  for _ in 0..<200 { held = try held.merging(latest) }
  held = try held.merging(.init(content: content, actions: [first]))
  #expect(held.actions == [undone])
  #expect(held.content?.pages.count == 1)
  #expect(held.content?.pages.first?.elements.isEmpty == true)
  #expect(throws: CollaborationError.self) { try held.merging(.init(actions: [first, first])) }
  let wire = NotebookTransportTransient.inputActivity(.init(deviceID: f.human, sessionID: UUID(), sequence: 1, targets: [f.page]))
  #expect(try JSONDecoder().decode(NotebookTransportTransient.self, from: JSONEncoder().encode(wire)) == wire)
}

@Test("Диагностика кадров ограничивает память и отличает частоту от задержки")
func inputFrameWindowIsBounded() {
  var frames = InputFrameStatistics()
  for index in 0...10_000 { frames.record(timestamp: Double(index) / 120, expectedInterval: 1.0 / 120) }
  #expect(frames.summary.totalIntervals == 10_000)
  #expect(frames.summary.retainedIntervals == InputFrameStatistics.capacity)
  #expect(abs(frames.summary.recentIntervalP95MS - 1000.0 / 120) < 0.001)
  #expect(frames.summary.estimatedUnservicedIntervals == 0)
  frames.record(timestamp: 10_000.0 / 120 + 0.1, expectedInterval: 1.0 / 120)
  #expect(abs(frames.summary.maximumIntervalMS - 100) < 0.001)
  #expect(frames.summary.estimatedUnservicedIntervals == 11)
  frames.record(timestamp: .nan, expectedInterval: 0)
  #expect(frames.summary.totalIntervals == 10_001)
}
