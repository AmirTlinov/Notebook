import Foundation
import Testing
@testable import NotebookCore

private struct CreationUndoFixture {
  let root: URL
  let store: NotebookStore
  let human = UUID(), agent = UUID()
  let boardID: UUID
  let initialItemID: UUID

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-creation-undo-" + UUID().uuidString)
    store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
    boardID = header.rootBoardID
    initialItemID = try #require(try store.readWorkspaceItems(limit: 1).first?.id)
    _ = try store.loadOrCreateSpatialInk(actor: human)
    FileHandle.standardError.write(Data("CREATION_UNDO_FIXTURE \(root.path)\n".utf8))
  }

  func clean() { try? FileManager.default.removeItem(at: root) }
  var board: CollaborationTarget { .init(kind: .board, id: boardID) }

  func action(_ operations: [CollaborationOperation]) throws -> CollaborationAction {
    .init(summary: "Создать связанные материалы одним ходом", expected: [
      .init(target: board, revision: try store.readBoardNode(boardID)!.board.stamp.revision),
      .init(target: .init(kind: .workspace, id: boardID), revision: try store.workspaceHeader().stamp.revision)
    ], operations: operations)
  }

  func notebook(_ id: UUID, pageID: UUID, board target: CollaborationTarget? = nil) throws -> CollaborationOperation {
    .init(kind: .createNotebook, target: target ?? board, id: id.uuidString,
      values: ["pageID": .string(pageID.uuidString), "center": try .encode(WorldPoint.zero)])
  }

  func document(_ id: UUID) throws -> CollaborationOperation {
    .init(kind: .createDocument, target: board, id: id.uuidString, values: [
      "center": try .encode(WorldPoint.zero), "paperSize": .string("a4"),
      "blocks": try .encode([DocumentBlock.interactive(id: "choice", html: "<button>Выбрать</button>", initialState: .object([:]))])])
  }

  func element(on target: CollaborationTarget) throws -> CollaborationOperation {
    var values: [String: JSONValue] = ["kind": .string("web"), "source": .string("<button>Выбрать</button>"),
      "frame": try .encode(PageRect(x: 20, y: 20, width: 200, height: 80)), "state": .object(["stamp": .string("draft")])]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    return .init(kind: .insertElement, target: target, id: "choice", values: values)
  }

  func expectValidOwners() throws {
    let content = try store.collaborationContent()
    try content.validate()
    #expect(content.hierarchy.isValid(items: content.workspace.items))
    #expect(content.workspace.items.contains { $0.id == initialItemID })
  }

  func adoptPage(_ id: UUID) throws -> PageDocument {
    var page = try store.loadPage(id)
    let element = AgentElement(id: "human-choice", kind: .web, frame: .init(x: 20, y: 20, width: 200, height: 80),
      source: "<button>Ответ</button>", html: "<button>Ответ</button>", state: .object(["stamp": .string("Точный ответ человека")]))
    let changed = page.replaceElements(page.elements + [element], actor: human)
    #expect(changed)
    return try store.saveMergedPage(page)
  }

  func addHumanElement(on surface: SurfaceID, boardID: UUID) throws -> SpatialElement {
    let index = try store.loadIndex()
    var tree = try store.loadBoard(items: index.items)
    let element = SpatialElement(id: "zz-human-after-authored", surface: surface, kind: .web,
      frame: .init(x: 20, y: 20, width: 200, height: 80), worldOrigin: surface.kind == .board ? .zero : nil,
      source: "<button>Ответ человека</button>", state: .object(["collaboration": .string("Не стирать")]),
      stamp: .init(counter: 100, actor: human))
    let changed = tree.upsertElement(element, in: boardID, expected: nil, actor: human)
    #expect(changed)
    _ = try store.saveMergedBoard(tree, items: index.items)
    return try #require(try store.readSpatialElement(boardID: boardID, elementID: element.id))
  }
}

@Test("Созданная доска с собственным элементом полностью отменяется без чужого принятия")
func creationUndoOwnBoardContentIsNotAdoption() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let id = UUID(), board = CollaborationTarget(kind: .board, id: id)
  let action = try f.action([.init(kind: .createBoard, target: f.board, id: id.uuidString,
    values: ["center": try .encode(WorldPoint.zero)]), f.element(on: board)])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(try f.store.readBoardNode(id)?.board.elements.map(\.id) == ["choice"])
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(undone.undo?.preserved.isEmpty == true)
  #expect(undone.undo?.restored == receipt.changes.count)
  #expect(try f.store.readWorkspaceItem(id) == nil)
  #expect(try f.store.readBoardNode(id) == nil)
  #expect(try f.store.ownerBoardID(of: id) == nil)
  try f.expectValidOwners()
}

@Test("Принятие первой тетради не мешает полностью отменить вторую из того же хода")
func creationUndoMixedNotebooksPreservesOnlyAdoptedOwner() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let first = UUID(), firstPage = UUID(), second = UUID(), secondPage = UUID()
  let target = CollaborationTarget(kind: .page, id: firstPage)
  let action = try f.action([f.notebook(first, pageID: firstPage), f.notebook(second, pageID: secondPage), f.element(on: target)])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let delivered = try f.store.collaborationContent()
  var page = try f.store.loadPage(firstPage)
  let exact = JSONValue.object(["nested": .array([.object(["collaboration": .string("Ответ человека — сохранить целиком")])])])
  let changed = page.replaceElements([page.elements[0].updating(state: exact)], actor: f.human)
  #expect(changed)
  page = try f.store.saveMergedPage(page)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.loadPage(firstPage) == page)
  #expect(try f.store.readWorkspaceItem(first)?.pageIDs == [firstPage])
  #expect(try f.store.ownerBoardID(of: first) == f.boardID)
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(secondPage)))
  #expect(try f.store.ownerBoardID(of: second) == nil)
  #expect((undone.undo?.restored ?? 0) > 0)
  #expect(undone.undo?.preserved.isEmpty == false)
  #expect(try f.store.undoCollaborationAction(action.id, actor: f.human) == undone)
  _ = try f.store.mergeCollaborationContent(delivered)
  #expect(try f.store.loadPage(firstPage).elements[0].state == exact)
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(secondPage)))
  try f.expectValidOwners()
}

@Test("Принятие первого документа сохраняет его точное состояние, а второй удаляется без зависимостей")
func creationUndoMixedDocumentsPreservesOnlyAdoptedOwner() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let first = UUID(), second = UUID()
  let action = try f.action([f.document(first), f.document(second)])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let delivered = try f.store.collaborationContent()
  let document = try f.store.loadDocument(first)
  var state = try f.store.loadDocumentState(first)
  let changed = state.commit(blockID: "choice", value: .object(["fieldVersion": .string("Точный ответ человека")]), actor: f.human)
  #expect(changed)
  state = try f.store.saveMergedDocumentState(state)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.loadDocument(first) == document)
  #expect(try f.store.loadDocumentState(first) == state)
  #expect(try f.store.readWorkspaceItem(first) != nil)
  #expect(try f.store.ownerBoardID(of: first) == f.boardID)
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(documentFile(second)))
  #expect(try !f.store.hasStoredValue(stateFile(second)))
  #expect(try f.store.ownerBoardID(of: second) == nil)
  #expect((undone.undo?.restored ?? 0) > 0)
  #expect(undone.undo?.preserved.isEmpty == false)
  _ = try f.store.mergeCollaborationContent(delivered)
  #expect(try f.store.loadDocumentState(first).value(for: "choice") == state.value(for: "choice"))
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(documentFile(second)))
  #expect(try !f.store.hasStoredValue(stateFile(second)))
  try f.expectValidOwners()
}

@Test("Без принятия отменяются все независимые создания", arguments: [false, true])
func creationUndoIndependentUnadoptedOwnersAreRemoved(documents: Bool) throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let ids = [UUID(), UUID()], pages = [UUID(), UUID()]
  let action = try f.action(try ids.enumerated().map { index, id in
    try documents ? f.document(id) : f.notebook(id, pageID: pages[index])
  })
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  // The addressed catalog projection orders its selected UUIDs independently
  // of the full catalog. That presentation-only inverse may be preserved; no
  // physical creation or dependency may be classified as adopted here.
  let result = try #require(undone.undo)
  #expect(result.preserved.allSatisfy { $0.file == "workspace.json" && $0.path == [.field("items"), .order] })
  #expect(result.restored + result.preserved.count == receipt.changes.count)
  for (index, id) in ids.enumerated() {
    #expect(try f.store.readWorkspaceItem(id) == nil)
    #expect(try f.store.ownerBoardID(of: id) == nil)
    for file in documents ? [documentFile(id), stateFile(id)] : [pageFile(pages[index])] {
      #expect(try !f.store.hasStoredValue(file))
    }
  }
  try f.expectValidOwners()
}

@Test("Поздний элемент новой доски защищён, даже если адресная проекция показывает только исходный")
func creationUndoLaterBoardChildOutsideProjectionIsAdoption() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let id = UUID(), board = CollaborationTarget(kind: .board, id: id)
  let action = try f.action([.init(kind: .createBoard, target: f.board, id: id.uuidString,
    values: ["center": try .encode(WorldPoint.zero)]), f.element(on: board)])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let human = try f.addHumanElement(on: .board(id), boardID: id)
  let projection = try f.store.readTransaction { try $0.actionSourceProjection(action, receipt: receipt) }
  let projected = try #require(projection["board.json"]).decode(BoardHierarchy.self)
  #expect(projected.board(id)?.elements.map(\.id) == ["choice"], "The independent child is deliberately outside the bounded command projection")
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.readWorkspaceItem(id) != nil)
  #expect(try f.store.readSpatialElement(boardID: id, elementID: human.id) == human)
  #expect(undone.undo?.restored == 0)
  try f.expectValidOwners()
}

@Test("Поздняя правка обложки сохраняет только её тетрадь, не независимого соседа")
func creationUndoLaterCoverContentProtectsItsPhysicalOwner() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let first = UUID(), firstPage = UUID(), second = UUID(), secondPage = UUID()
  let action = try f.action([f.notebook(first, pageID: firstPage), f.notebook(second, pageID: secondPage)])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let human = try f.addHumanElement(on: .cover(first), boardID: f.boardID)
  _ = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.readWorkspaceItem(first) != nil)
  #expect(try f.store.hasStoredValue(pageFile(firstPage)))
  #expect(try f.store.readSpatialElement(boardID: f.boardID, elementID: human.id) == human)
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(secondPage)))
  #expect(try f.store.ownerBoardID(of: second) == nil)
  try f.expectValidOwners()
}

@Test("Замыкание сохраняет целый созданный узел с принятым ребёнком, но отменяет независимого соседа")
func creationUndoNestedAdoptionKeepsOnlyConnectedDependencies() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let boardID = UUID(), board = CollaborationTarget(kind: .board, id: boardID)
  let children = [UUID(), UUID()], pages = [UUID(), UUID()], outside = UUID(), outsidePage = UUID()
  let action = try f.action([.init(kind: .createBoard, target: f.board, id: boardID.uuidString,
    values: ["center": try .encode(WorldPoint.zero)]),
    f.notebook(children[0], pageID: pages[0], board: board), f.notebook(children[1], pageID: pages[1], board: board),
    f.notebook(outside, pageID: outsidePage)])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let human = try f.adoptPage(pages[0])
  _ = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.loadPage(pages[0]) == human)
  #expect(try f.store.readWorkspaceItem(boardID) != nil)
  #expect(try f.store.readBoardNode(boardID)?.board.itemIDs == children)
  for (index, id) in children.enumerated() {
    #expect(try f.store.readWorkspaceItem(id)?.pageIDs == [pages[index]])
    #expect(try f.store.ownerBoardID(of: id) == boardID)
    #expect(try f.store.hasStoredValue(pageFile(pages[index])))
  }
  #expect(try f.store.readWorkspaceItem(outside) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(outsidePage)))
  #expect(try f.store.ownerBoardID(of: outside) == nil)
  try f.expectValidOwners()
}

@Test("Целая созданная стопка сохраняет принятых участников, не защищая независимую тетрадь")
func creationUndoStackAdoptionKeepsOnlyConnectedDependencies() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let items = [UUID(), UUID(), UUID()], pages = [UUID(), UUID(), UUID()]
  var operations = try items.enumerated().map { try f.notebook($0.element, pageID: pages[$0.offset]) }
  operations.append(.init(kind: .stackItems, target: f.board, values: ["itemIDs": try .encode(Array(items.prefix(2)))]))
  let action = try f.action(operations)
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let human = try f.adoptPage(pages[0])
  let stack = try #require(try f.store.readBoardItem(items[0])?.board.stacks.first)
  _ = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.loadPage(pages[0]) == human)
  #expect(try f.store.readBoardItem(items[0])?.board.stacks.first == stack)
  for index in 0..<2 {
    #expect(try f.store.readWorkspaceItem(items[index])?.pageIDs == [pages[index]])
    #expect(try f.store.hasStoredValue(pageFile(pages[index])))
  }
  #expect(try f.store.readWorkspaceItem(items[2]) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(pages[2])))
  #expect(try f.store.ownerBoardID(of: items[2]) == nil)
  try f.expectValidOwners()
}

@Test("Принятый новый лист за пределами проекции сохраняет тетрадь и точное содержание после отмены создания")
func creationUndoAcceptedTrailingPageProtectsNotebook() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let first = UUID(), firstPage = UUID(), second = UUID(), secondPage = UUID()
  let action = try f.action([f.notebook(first, pageID: firstPage), f.notebook(second, pageID: secondPage)])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  var index = try f.store.loadIndex()
  let selected = index.selectItem(first, actor: f.human)
  #expect(selected)
  try f.store.savePresence(.init(boardID: f.boardID, mode: .page, camera: .init(),
    viewport: .init(x: 834, y: 1194), focusedItemID: first, openProgress: 1, notebookPageID: firstPage))
  let selectedPage = index.selectPage(at: 1, in: first, actor: f.human, pageSize: .init(width: 834, height: 1194))
  let landing = try #require(selectedPage)
  _ = try f.store.saveWorkspaceSelection(index: index, createdPage: landing.createdPage)
  let human = try f.adoptPage(landing.pageID)
  _ = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.readWorkspaceItem(first)?.pageIDs == [firstPage, landing.pageID])
  #expect(try f.store.loadPage(landing.pageID) == human)
  #expect(try f.store.loadIndex().selectedPageID == landing.pageID)
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(secondPage)))
  try f.expectValidOwners()
}

@Test("Причинное принятие размещения сохраняет зависимости даже после возврата в исходный центр")
func creationUndoCausalPlacementAdoptionKeepsPaper() throws {
  let f = try CreationUndoFixture(); defer { f.clean() }
  let first = UUID(), firstPage = UUID(), second = UUID(), secondPage = UUID()
  let action = try f.action([f.notebook(first, pageID: firstPage), f.notebook(second, pageID: secondPage)])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let center = try #require(try f.store.readBoardItem(first)?.board.placement(of: first)?.center)
  let moved = try f.store.moveWorkspaceItem(itemID: first, in: f.boardID, to: .init(x: 2000, y: 1000), actor: f.human)
  #expect(moved)
  let returned = try f.store.moveWorkspaceItem(itemID: first, in: f.boardID, to: center, actor: f.human)
  #expect(returned)
  let placement = try #require(try f.store.readBoardItem(first)?.board.placement(of: first))
  _ = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.readBoardItem(first)?.board.placement(of: first) == placement)
  #expect(try f.store.readWorkspaceItem(first) != nil)
  #expect(try f.store.hasStoredValue(pageFile(firstPage)))
  #expect(try f.store.readWorkspaceItem(second) == nil)
  #expect(try !f.store.hasStoredValue(pageFile(secondPage)))
  try f.expectValidOwners()
}
