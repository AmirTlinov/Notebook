import Foundation
import Testing
@testable import NotebookCore

private let publicationActorA = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let publicationActorB = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
private let publicationSize = PageSize(width: 834, height: 1194)

private func withPublicationStore(_ body: (NotebookStore, WorkspaceIndex, BoardHierarchy) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let index = try store.loadOrCreate(actor: publicationActorA, pageSize: publicationSize).0
  let board = try store.loadOrCreateBoard(workspace: index, actor: publicationActorA)
  _ = try store.loadOrCreateSpatialInk(actor: publicationActorA)
  try store.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194),
    selectedItemID: index.selectedItemID, notebookPageID: index.selectedPageID))
  try body(store, index, board)
}

@Test("Выбор листа не удаляет независимо созданную тетрадь при любом порядке слияния")
func catalogSelectionPreservesIndependentCreation() throws {
  var base = WorkspaceIndex.initial(actor: publicationActorA, pageSize: publicationSize).index
  _ = base.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorA, pageSize: publicationSize)
  _ = base.selectPage(at: 0, in: base.selectedItemID, actor: publicationActorA, pageSize: publicationSize)
  var creation = base, selection = base
  let addedResult = creation.createNotebook(title: "Independent", actor: publicationActorA, pageSize: publicationSize)
  let added = try #require(addedResult)
  _ = selection.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorB, pageSize: publicationSize)
  var left = creation, right = selection
  _ = left.merge(selection)
  _ = right.merge(creation)
  #expect(left.item(id: added.item.id) != nil)
  #expect(right.item(id: added.item.id) != nil)
  #expect(try JSONValue.encode(left) == JSONValue.encode(right))
  #expect(left.selectedPageID == creation.selectedPageID)
  #expect(right.selectedPageID == selection.selectedPageID)
}

@Test("Два независимо добавленных листа сохраняются в одной тетради")
func catalogConcurrentPageCreationPreservesBothPages() throws {
  let base = WorkspaceIndex.initial(actor: publicationActorA, pageSize: publicationSize).index
  var left = base, right = base
  let aResult = left.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorA, pageSize: publicationSize)
  let a = try #require(aResult)
  let bResult = right.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorB, pageSize: publicationSize)
  let b = try #require(bResult)
  let originalLeft = left
  _ = left.merge(right)
  _ = right.merge(originalLeft)
  #expect(Set(left.selectedItem.pageIDs) == Set([base.selectedPageID!, a.pageID, b.pageID]))
  #expect(try JSONValue.encode(left) == JSONValue.encode(right))
}

@Test("Устаревший выбор не возвращает явно удалённый предмет")
func catalogDeletionSurvivesStaleSelection() throws {
  var base = WorkspaceIndex.initial(actor: publicationActorA, pageSize: publicationSize).index
  let addedResult = base.createNotebook(title: "Removed", actor: publicationActorA, pageSize: publicationSize)
  let added = try #require(addedResult)
  let retained = base.items.first!.id
  var removed = base, selection = base
  _ = removed.deleteItem(added.item.id, actor: publicationActorA)
  _ = selection.selectItem(retained, actor: publicationActorB)
  var reverse = selection
  _ = reverse.merge(removed)
  _ = removed.merge(selection)
  #expect(removed.item(id: added.item.id) == nil)
  #expect(reverse == removed)
  let decoded = try JSONDecoder().decode(WorkspaceIndex.self, from: JSONEncoder().encode(removed))
  var replay = decoded
  _ = replay.merge(base)
  #expect(replay.item(id: added.item.id) == nil)
}

@Test("Запоздавшее создание не заменяет уже опубликованную тетрадь")
func staleNativeCreationPreservesDurableWorkspace() throws {
  try withPublicationStore { store, base, tree in
    var local = base, remote = base, localTree = tree, remoteTree = tree
    let aResult = local.createNotebook(title: "Local", actor: publicationActorA, pageSize: publicationSize)
    let a = try #require(aResult)
    let bResult = remote.createNotebook(title: "Durable", actor: publicationActorB, pageSize: publicationSize)
    let b = try #require(bResult)
    _ = localTree.addItem(a.item.id, to: base.rootBoardID, near: .zero, actor: publicationActorA)
    _ = remoteTree.addItem(b.item.id, to: base.rootBoardID, near: .zero, actor: publicationActorB)
    try store.saveWorkspaceBundle(index: remote, page: b.page, board: remoteTree)
    let before = try store.loadIndex()
    try store.saveWorkspaceBundle(index: local, page: a.page, board: localTree)
    let after = try store.loadIndex()
    #expect(after.item(id: a.item.id) != nil)
    #expect(after.item(id: b.item.id) != nil)
    #expect(after.stamp >= before.stamp)
    #expect(try store.loadBoard(items: after.items).isValid(items: after.items))
    #expect(try store.loadPage(a.page.id) == a.page)
    #expect(try store.loadPage(b.page.id) == b.page)
  }
}

@Test("Сетевой выбор не удаляет файл независимо созданной тетради")
func collaborationSelectionPreservesPublishedPage() throws {
  try withPublicationStore { store, initial, _ in
    var base = initial
    let secondResult = base.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorA, pageSize: publicationSize)
    let second = try #require(secondResult)
    _ = try store.saveWorkspaceSelection(index: base, createdPage: second.createdPage)
    _ = base.selectPage(at: 0, in: base.selectedItemID, actor: publicationActorA, pageSize: publicationSize)
    _ = try store.saveWorkspaceSelection(index: base, createdPage: nil)
    let tree = try store.loadBoard(items: base.items)
    var created = base, createdTree = tree, selection = base
    let addedResult = created.createNotebook(title: "Preserved", actor: publicationActorA, pageSize: publicationSize)
    let added = try #require(addedResult)
    _ = createdTree.addItem(added.item.id, to: base.rootBoardID, near: .zero, actor: publicationActorA)
    try store.saveWorkspaceBundle(index: created, page: added.page, board: createdTree)
    _ = selection.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorB, pageSize: publicationSize)
    let incoming = CollaborationContent(workspace: selection, hierarchy: tree, ink: try store.loadSpatialInk(), pages: [], documents: [], states: [])
    let result = try store.mergeCollaborationContent(incoming)
    #expect(result.workspace.item(id: added.item.id) != nil)
    #expect(try store.loadPage(added.page.id) == added.page)
    #expect(try store.loadBoard(items: result.workspace.items).isValid(items: result.workspace.items))
  }
}


@Test("Повтор ID тяжёлого владельца отклоняется до удержания первого сетевого пакета", arguments: ["page", "document", "state"])
func collaborationRejectsDuplicateHeavyOwners(kind: String) throws {
  let initial = WorkspaceIndex.initial(actor: publicationActorA, pageSize: publicationSize)
  let tree = BoardHierarchy.initial(rootBoardID: initial.index.rootBoardID, itemIDs: initial.index.items.map(\.id), actor: publicationActorA)
  let document = DocumentDocument(actor: publicationActorA)
  let state = DocumentStateJournal(id: document.id, actor: publicationActorA)
  let content = CollaborationContent(workspace: initial.index, hierarchy: tree,
    ink: SpatialInkJournal(stamp: .init(counter: 0, actor: publicationActorA)),
    pages: kind == "page" ? [initial.page, initial.page] : [],
    documents: kind == "document" ? [document, document] : [],
    states: kind == "state" ? [state, state] : [])
  let encoded = try JSONEncoder().encode(CollaborationEnvelope(content: content))
  #expect(throws: (any Error).self) {
    let incoming = try JSONDecoder().decode(CollaborationEnvelope.self, from: encoded)
    _ = try CollaborationEnvelope().merging(incoming)
  }
}

@Test("Документ и портал, созданные из старого каталога, сохраняют уже опубликованный предмет", arguments: [WorkspaceItemKind.document, .board])
func staleNativeDocumentAndBoardCreation(kind: WorkspaceItemKind) throws {
  try withPublicationStore { store, base, tree in
    var local = base, remote = base, localTree = tree, remoteTree = tree
    let remoteResult = remote.createNotebook(title: "Already durable", actor: publicationActorB, pageSize: publicationSize)
    let other = try #require(remoteResult)
    _ = remoteTree.addItem(other.item.id, to: base.rootBoardID, near: .zero, actor: publicationActorB)
    try store.saveWorkspaceBundle(index: remote, page: other.page, board: remoteTree)
    let id = UUID()
    if kind == .document {
      _ = local.createDocument(title: "Local document", actor: publicationActorA, documentID: id)
      _ = localTree.addItem(id, to: base.rootBoardID, near: .zero, actor: publicationActorA)
      let document = DocumentDocument(id: id, actor: publicationActorA)
      try store.saveDocumentWorkspaceBundle(index: local, document: document,
        state: .init(id: id, actor: publicationActorA), board: localTree)
      let persisted = try store.loadDocument(id)
      #expect(persisted.blocks == document.blocks && persisted.contentStamp == document.contentStamp)
      #expect(persisted.collaboration?.fields.isEmpty == false)
      #expect(persisted.collaboration?.fields.values.allSatisfy(\.human) == true)
      #expect(try store.loadDocumentState(id).id == id)
    } else {
      _ = local.createBoard(title: "Local board", actor: publicationActorA, boardID: id)
      _ = localTree.createBoard(id, in: base.rootBoardID, near: .zero, actor: publicationActorA)
      try store.saveBoardWorkspaceBundle(index: local, board: localTree, boardID: id)
    }
    let actual = try store.loadIndex()
    #expect(actual.item(id: id)?.kind == kind)
    #expect(actual.item(id: other.item.id) != nil)
    #expect(try store.loadPage(other.page.id) == other.page)
    #expect(try store.loadBoard(items: actual.items).isValid(items: actual.items))
  }
}

@Test("Независимые предметы сохраняют реальные родительские доски при слиянии")
func concurrentCreationsKeepTheirPhysicalBoardOwners() throws {
  var base = WorkspaceIndex.initial(actor: publicationActorA, pageSize: publicationSize).index
  var tree = BoardHierarchy.initial(rootBoardID: base.rootBoardID, itemIDs: base.items.map(\.id), actor: publicationActorA)
  let parentA = UUID(), parentB = UUID()
  for id in [parentA, parentB] {
    _ = base.createBoard(title: "Parent", actor: publicationActorA, boardID: id)
    _ = tree.createBoard(id, in: base.rootBoardID, near: .zero, actor: publicationActorA)
  }
  var a = base, b = base, treeA = tree, treeB = tree
  let createdAResult = a.createNotebook(title: "A", actor: publicationActorA, pageSize: publicationSize)
  let createdBResult = b.createNotebook(title: "B", actor: publicationActorB, pageSize: publicationSize)
  let createdA = try #require(createdAResult), createdB = try #require(createdBResult)
  _ = treeA.addItem(createdA.item.id, to: parentA, near: .init(x: 120, y: 250), actor: publicationActorA)
  _ = treeB.addItem(createdB.item.id, to: parentB, near: .init(x: 900, y: 550), actor: publicationActorB)
  _ = a.merge(b)
  let oldA = treeA
  _ = try treeA.merge(treeB, items: a.items)
  _ = try treeB.merge(oldA, items: a.items)
  #expect(treeA == treeB)
  #expect(treeA.ownerBoardID(of: createdA.item.id) == parentA)
  #expect(treeA.ownerBoardID(of: createdB.item.id) == parentB)
  #expect(treeA.board(parentA)?.focusedCenter(of: createdA.item.id) == .init(x: 120, y: 250))
  #expect(treeA.board(parentB)?.focusedCenter(of: createdB.item.id) == .init(x: 900, y: 550))
}

@Test("Запоздавшая публикация чистого нового листа не стирает уже сохранённые чернила")
func delayedBlankPageCreationKeepsPublishedDrawing() throws {
  try withPublicationStore { store, base, _ in
    var index = base
    let selectionResult = index.selectPage(at: 1, in: base.selectedItemID, actor: publicationActorA, pageSize: publicationSize)
    let selection = try #require(selectionResult), blank = try #require(selection.createdPage)
    var drawn = blank
    _ = drawn.replaceDrawing(pageDrawingFixture(Data("already published ink".utf8)), actor: publicationActorA)
    _ = try store.saveWorkspaceSelection(index: index, createdPage: drawn)
    _ = try store.saveWorkspaceSelection(index: index, createdPage: blank)
    #expect(try store.loadPage(blank.id).drawingData == drawn.drawingData)
  }
}

@Test("Отдельная запись каталога не публикует предмет без содержания и размещения")
func bareCatalogCannotExposeIncompleteCreation() throws {
  try withPublicationStore { store, base, _ in
    var incoming = base
    _ = incoming.createNotebook(title: "Missing", actor: publicationActorA, pageSize: publicationSize)
    #expect(throws: (any Error).self) { try store.saveIndex(incoming) }
    let actual = try store.loadIndex()
    #expect(actual == base)
    #expect(!FileManager.default.fileExists(atPath: store.collaborationURL.appendingPathComponent("pending.json").path))
  }
}

@Test("Недопустимый сетевой пакет оставляет опубликованную библиотеку неизменной")
func invalidCollaborationDoesNotPublishAnyOwner() throws {
  try withPublicationStore { store, _, _ in
    let before = try store.collaborationContent()
    var incoming = before
    incoming.pages.append(incoming.pages[0])
    #expect(throws: (any Error).self) { _ = try store.receiveCollaboration(.init(content: incoming)) }
    #expect(try store.collaborationContent() == before)
    #expect(throws: (any Error).self) { _ = try incoming.publication(since: before) }
    var retained = before
    #expect(throws: (any Error).self) { try retained.merge(incoming) }
    #expect(retained == before)
  }
}

@Test("Старая тетрадь без листов отклоняется декодером, а не precondition")
func malformedLegacyNotebookDoesNotTrap() throws {
  let id = UUID(), actor = publicationActorA
  let value: JSONValue = .object(["format": .number(1), "notebooks": .array([
    .object(["id": .string(id.uuidString), "title": .string("Invalid"), "pageIDs": .array([])])
  ]), "selectedNotebookID": .string(id.uuidString), "selectedPageID": .string(UUID().uuidString),
    "stamp": try .encode(VersionStamp(counter: 0, actor: actor))])
  #expect(throws: (any Error).self) { _ = try value.decode(WorkspaceIndex.self) }
}

@Test("Запоздавшие записи не возвращают удалённый лист, документ или его состояние", arguments: [WorkspaceItemKind.notebook, .document])
func lateHeavyOwnerSaveDoesNotResurrectDeletion(kind: WorkspaceItemKind) throws {
  try withPublicationStore { store, base, tree in
    var index = base, board = tree
    let id = UUID()
    var capturedPage: PageDocument?
    let capturedDocument = DocumentDocument(id: id, actor: publicationActorA)
    var capturedState = DocumentStateJournal(id: id, actor: publicationActorA)
    if kind == .notebook {
      let creation = index.createNotebook(title: "Delete after input", actor: publicationActorA,
        pageSize: publicationSize, itemID: id)
      let created = try #require(creation)
      _ = board.addItem(id, to: base.rootBoardID, near: .zero, actor: publicationActorA)
      try store.saveWorkspaceBundle(index: index, page: created.page, board: board)
      capturedPage = created.page
      _ = capturedPage?.replaceDrawing(pageDrawingFixture(Data("accepted input".utf8)), actor: publicationActorA)
    } else {
      _ = index.createDocument(title: "Delete after input", actor: publicationActorA, documentID: id)
      _ = board.addItem(id, to: base.rootBoardID, near: .zero, actor: publicationActorA)
      try store.saveDocumentWorkspaceBundle(index: index, document: capturedDocument, state: capturedState, board: board)
    }
    let accepted = capturedState.commit(blockID: "accepted", value: .number(1), actor: publicationActorA)
    #expect(accepted)
    let stateCommand = NotebookDocumentStateCommand(documentID: id,
      record: try #require(capturedState.records.first), journalStamp: capturedState.stamp)
    let beforeDeletion = index
    _ = index.deleteItem(id, actor: publicationActorA)
    _ = board.deleteItem(id, from: base.rootBoardID, kind: kind,
      spatialInk: try store.loadSpatialInk(), actor: publicationActorA)
    _ = try store.deleteWorkspaceBundle(expectedIndex: beforeDeletion, index: index, board: board,
      pageIDs: capturedPage.map { [$0.id] } ?? [], documentIDs: kind == .document ? [id] : [])
    if let capturedPage {
      #expect(throws: CocoaError.self) { _ = try store.savePage(capturedPage) }
      #expect(!FileManager.default.fileExists(atPath: store.pageURL(capturedPage.id).path))
    } else {
      #expect(throws: CocoaError.self) { _ = try store.saveMergedDocument(capturedDocument) }
      #expect(throws: CocoaError.self) { _ = try store.commitDocumentState(stateCommand) }
      #expect(!FileManager.default.fileExists(atPath: store.documentURL(id).path))
      #expect(!FileManager.default.fileExists(atPath: store.documentStateURL(id).path))
    }
    let actual = try store.loadIndex()
    #expect(actual.item(id: id) == nil)
  }
}

@Test("Сохранение доски из старой памяти сохраняет новый предмет опубликованного каталога")
func staleBoardSaveKeepsDurableMembership() throws {
  try withPublicationStore { store, base, tree in
    var staleBoard = tree, index = base, durableBoard = tree
    let center = WorldPoint(x: 1900, y: 2600)
    _ = staleBoard.moveItem(base.selectedItemID, in: base.rootBoardID, to: center, actor: publicationActorA)
    let creation = index.createBoard(title: "Already published", actor: publicationActorB)
    let created = try #require(creation)
    _ = durableBoard.createBoard(created.id, in: base.rootBoardID, near: .zero, actor: publicationActorB)
    try store.saveBoardWorkspaceBundle(index: index, board: durableBoard, boardID: created.id)
    let resolved = try store.saveMergedBoard(staleBoard, items: base.items)
    #expect(resolved.isValid(items: index.items))
    #expect(resolved.board(created.id) != nil)
    #expect(resolved.focusedCenter(of: base.selectedItemID, in: base.rootBoardID) == center)
    #expect(try store.loadBoard(items: index.items) == resolved)
  }
}

@Test("Конфликт двух физических родителей отклоняет весь пакет без частичной записи")
func conflictingPhysicalOwnersRejectWholePublication() throws {
  try withPublicationStore { store, base, tree in
    var index = base, boards = tree
    let parentA = UUID(), parentB = UUID()
    for id in [parentA, parentB] {
      _ = index.createBoard(title: "Parent", actor: publicationActorA, boardID: id)
      _ = boards.createBoard(id, in: index.rootBoardID, near: .zero, actor: publicationActorA)
      try store.saveBoardWorkspaceBundle(index: index, board: boards, boardID: id)
    }
    var local = boards, incoming = boards
    let ink = try store.loadSpatialInk()
    _ = local.deleteItem(base.selectedItemID, from: base.rootBoardID, kind: .notebook, spatialInk: ink, actor: publicationActorA)
    _ = local.addItem(base.selectedItemID, to: parentA, near: .zero, actor: publicationActorA)
    _ = incoming.deleteItem(base.selectedItemID, from: base.rootBoardID, kind: .notebook, spatialInk: ink, actor: publicationActorB)
    _ = incoming.addItem(base.selectedItemID, to: parentB, near: .zero, actor: publicationActorB)
    _ = try store.saveMergedBoard(local, items: index.items)
    let before = try store.collaborationContent()
    var page = try store.loadPage(base.selectedPageID!)
    _ = page.replaceDrawing(pageDrawingFixture(Data("must not partially publish".utf8)), actor: publicationActorB)
    let content = CollaborationContent(workspace: index, hierarchy: incoming, ink: ink, pages: [page], documents: [], states: [])
    #expect(throws: CollaborationError.self) { _ = try store.receiveCollaboration(.init(content: content)) }
    #expect(try store.collaborationContent() == before)
    #expect(!FileManager.default.fileExists(atPath: store.collaborationURL.appendingPathComponent("pending.json").path))
  }
}

@Test("Ожидающее удаления намерение резервирует часы, не меняя выбранное место")
func pendingDeletionReservesClockForLaterNavigation() throws {
  var base = WorkspaceIndex.initial(actor: publicationActorA, pageSize: publicationSize).index
  let removedID = base.selectedItemID
  let bResult = base.createNotebook(title: "Fallback", actor: publicationActorA, pageSize: publicationSize)
  let b = try #require(bResult)
  let cResult = base.createNotebook(title: "Later navigation", actor: publicationActorA, pageSize: publicationSize)
  let c = try #require(cResult)
  _ = base.selectItem(removedID, actor: publicationActorA)
  var deleted = base, current = base
  _ = deleted.deleteItem(removedID, actor: publicationActorA)
  #expect(deleted.selectedItemID == b.item.id)

  let reserved = current.observeCausalFrontier(deleted.stamp)
  #expect(reserved)
  #expect(current.items == base.items)
  #expect(current.selectedItemID == base.selectedItemID)
  #expect(current.selectedPageID == base.selectedPageID)
  #expect(current.collaboration == base.collaboration)
  #expect(current.stamp == deleted.stamp)

  _ = current.selectItem(c.item.id, actor: publicationActorA)
  #expect(current.stamp == deleted.stamp)
  let durable = try deleted.merging(current)
  let memory = try current.merging(deleted)
  #expect(durable.items == memory.items)
  #expect(memory.selectedItemID == c.item.id)
  #expect(durable.item(id: removedID) == nil)

  let accepted = current
  let older = current.observeCausalFrontier(base.stamp)
  let invalid = current.observeCausalFrontier(.init(counter: VersionStamp.maximumCounter + 1, actor: publicationActorA))
  #expect(!older && !invalid)
  #expect(current == accepted)
}

@Test("Ожидающее удаление резервирует часы родителя без принятия его содержания")
func pendingBoardDeletionReservesSharedOwnerClocks() throws {
  let removedID = UUID(), movedID = UUID(), childID = UUID()
  let items: [WorkspaceItem] = [
    .notebook(id: removedID, title: "Removed", pageIDs: [UUID()]),
    .notebook(id: movedID, title: "Moved later", pageIDs: [UUID()]),
    .board(id: childID, title: "Unchanged child")
  ]
  let stamp = VersionStamp(counter: 0, actor: publicationActorA)
  let root = BoardDocument.initial(itemIDs: items.map(\.id), actor: publicationActorA)
  let child = BoardNode(id: childID, board: .initial(itemIDs: [], actor: publicationActorA))
  let base = BoardHierarchy(rootBoardID: WorkspaceRoot.boardID,
    boards: [.init(id: WorkspaceRoot.boardID, board: root), child], stamp: stamp)
  var pending = base, current = base
  _ = pending.deleteItem(removedID, from: base.rootBoardID, kind: .notebook,
    spatialInk: .init(stamp: stamp), actor: publicationActorA)
  let pendingRoot = try #require(pending.board(base.rootBoardID))
  let observed = current.observeCausalFrontiers(from: pending)
  #expect(observed)
  let reserved = try #require(current.board(base.rootBoardID))
  #expect(reserved.freeItems == root.freeItems)
  #expect(reserved.stacks == root.stacks)
  #expect(reserved.elements == root.elements)
  #expect(reserved.stamp == pendingRoot.stamp)
  #expect(current.stamp == pending.stamp)
  #expect(current.boards.first { $0.id == childID } == child)
  #expect(current.portalCamera(base.rootBoardID) == base.portalCamera(base.rootBoardID))
  #expect(reserved.placements == root.placements)

  let center = WorldPoint(x: 1200, y: 3200)
  _ = current.moveItem(movedID, in: base.rootBoardID, to: center, actor: publicationActorA)
  #expect(current.board(base.rootBoardID)?.stamp.counter == pendingRoot.stamp.counter + 1)
  let retained = items.filter { $0.id != removedID }
  let left = try current.merging(pending, items: retained)
  let right = try pending.merging(current, items: retained)
  #expect(try JSONValue.encode(left) == JSONValue.encode(right))
  #expect(left.focusedCenter(of: movedID, in: base.rootBoardID) == center)
  #expect(!left.itemIDs.contains(removedID))
}
