import Foundation
import Testing
@testable import NotebookCore

@Test("Плоское дерево проходит тысячу вложенных досок без рекурсивного JSON")
func boardHierarchySupportsDeepNesting() throws {
  let actor = UUID()
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var workspace = initial.index
  var hierarchy = BoardHierarchy.initial(
    rootBoardID: workspace.rootBoardID,
    itemIDs: workspace.items.map(\.id),
    actor: actor
  )
  var parent = workspace.rootBoardID

  for depth in 0..<1_000 {
    let boardID = UUID()
    let creation = workspace.createBoard(
      title: "Уровень \(depth + 1)",
      actor: actor,
      boardID: boardID
    )
    let item = try #require(creation)
    let created = hierarchy.createBoard(
      item.id,
      in: parent,
      near: .zero,
      actor: actor
    )
    #expect(created)
    parent = boardID
  }

  #expect(hierarchy.path(to: parent)?.count == 1_001)
  #expect(hierarchy.isValid(items: workspace.items))
  let roundTrip = try JSONDecoder().decode(
    BoardHierarchy.self,
    from: JSONEncoder().encode(hierarchy)
  )
  #expect(roundTrip == hierarchy)
}

@Test("Каждый предмет принадлежит ровно одной достижимой доске")
func boardHierarchyRejectsUnreachableCycle() throws {
  let actor = UUID()
  let notebookID = UUID()
  let pageID = UUID()
  let boardID = UUID()
  var workspace = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194),
    itemID: notebookID,
    pageID: pageID
  ).index
  let creation = workspace.createBoard(
    title: "Петля",
    actor: actor,
    boardID: boardID
  )
  _ = try #require(creation)
  let root = BoardDocument.initial(itemIDs: [notebookID], actor: actor)
  let cycle = BoardDocument.initial(itemIDs: [boardID], actor: actor)
  let malformed = BoardHierarchy(
    rootBoardID: workspace.rootBoardID,
    boards: [
      BoardNode(id: workspace.rootBoardID, board: root),
      BoardNode(id: boardID, board: cycle),
    ],
    stamp: VersionStamp(counter: 2, actor: actor)
  )

  #expect(!malformed.isValid(items: workspace.items))
  #expect(malformed.path(to: boardID) == nil)
}

@Test("Портал доски удаляется только после очистки дочерней доски")
func nestedBoardDeletionRequiresEmptyChild() throws {
  let actor = UUID()
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var workspace = initial.index
  var hierarchy = BoardHierarchy.initial(
    rootBoardID: workspace.rootBoardID,
    itemIDs: workspace.items.map(\.id),
    actor: actor
  )
  let boardCreation = workspace.createBoard(title: "Внутри", actor: actor)
  let boardItem = try #require(boardCreation)
  let boardWasCreated = hierarchy.createBoard(
    boardItem.id,
    in: workspace.rootBoardID,
    near: .zero,
    actor: actor
  )
  #expect(boardWasCreated)
  let nestedCreation = workspace.createNotebook(
    title: "Живая тетрадь",
    actor: actor,
    pageSize: initial.page.size
  )
  let nested = try #require(nestedCreation)
  let nestedWasAdded = hierarchy.addItem(
    nested.item.id,
    to: boardItem.id,
    near: .zero,
    actor: actor
  )
  #expect(nestedWasAdded)

  let prematureDeletion = hierarchy.deleteItem(
    boardItem.id,
    from: workspace.rootBoardID,
    kind: .board,
    actor: actor
  )
  #expect(!prematureDeletion)
  let nestedWasDeleted = hierarchy.deleteItem(
    nested.item.id,
    from: boardItem.id,
    kind: .notebook,
    actor: actor
  )
  #expect(nestedWasDeleted)
  let removedNested = workspace.deleteItem(nested.item.id, actor: actor)
  _ = try #require(removedNested)
  let boardWasDeleted = hierarchy.deleteItem(
    boardItem.id,
    from: workspace.rootBoardID,
    kind: .board,
    actor: actor
  )
  #expect(boardWasDeleted)
  let removedBoard = workspace.deleteItem(boardItem.id, actor: actor)
  _ = try #require(removedBoard)

  #expect(hierarchy.board(boardItem.id) == nil)
  #expect(hierarchy.isValid(items: workspace.items))
}

@Test("Присутствие сохраняет точную вложенную доску")
func sessionPresenceRoundTripsNestedBoard() throws {
  let boardID = UUID()
  let presence = SessionPresence(
    boardID: boardID,
    mode: .board,
    camera: SpatialCamera(center: WorldPoint(x: 20, y: -30), scale: 0.4),
    viewport: SpatialPoint(x: 1_024, y: 1_366)
  )

  let decoded = try JSONDecoder().decode(
    SessionPresence.self,
    from: JSONEncoder().encode(presence)
  )
  #expect(decoded == presence)
  #expect(decoded.boardID == boardID)
}

@Test("Разные вложенные доски сходятся без потери независимых движений")
func boardHierarchyMergesDisjointBoards() throws {
  let actor = UUID()
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var workspace = initial.index
  var base = BoardHierarchy.initial(
    rootBoardID: workspace.rootBoardID,
    itemIDs: workspace.items.map(\.id),
    actor: actor
  )
  let firstBoardCreation = workspace.createBoard(title: "A", actor: actor)
  let firstBoard = try #require(firstBoardCreation)
  let firstCreated = base.createBoard(
    firstBoard.id,
    in: workspace.rootBoardID,
    near: .zero,
    actor: actor
  )
  #expect(firstCreated)
  let secondBoardCreation = workspace.createBoard(title: "B", actor: actor)
  let secondBoard = try #require(secondBoardCreation)
  let secondCreated = base.createBoard(
    secondBoard.id,
    in: workspace.rootBoardID,
    near: WorldPoint(x: 900, y: 0),
    actor: actor
  )
  #expect(secondCreated)
  let firstNotebookCreation = workspace.createNotebook(
    title: "Первая",
    actor: actor,
    pageSize: initial.page.size
  )
  let firstNotebook = try #require(firstNotebookCreation)
  let firstAdded = base.addItem(
    firstNotebook.item.id,
    to: firstBoard.id,
    near: .zero,
    actor: actor
  )
  #expect(firstAdded)
  let secondNotebookCreation = workspace.createNotebook(
    title: "Вторая",
    actor: actor,
    pageSize: initial.page.size
  )
  let secondNotebook = try #require(secondNotebookCreation)
  let secondAdded = base.addItem(
    secondNotebook.item.id,
    to: secondBoard.id,
    near: .zero,
    actor: actor
  )
  #expect(secondAdded)

  var left = base
  var right = base
  let firstCenter = WorldPoint(x: 400, y: 200)
  let secondCenter = WorldPoint(x: -300, y: 700)
  let leftMoved = left.moveItem(
    firstNotebook.item.id,
    in: firstBoard.id,
    to: firstCenter,
    actor: actor
  )
  #expect(leftMoved)
  let rightMoved = right.moveItem(
    secondNotebook.item.id,
    in: secondBoard.id,
    to: secondCenter,
    actor: actor
  )
  #expect(rightMoved)
  let leftBeforeMerge = left
  let leftMerged = left.merge(right, items: workspace.items)
  let rightMerged = right.merge(leftBeforeMerge, items: workspace.items)
  #expect(leftMerged)
  #expect(rightMerged)

  #expect(left == right)
  #expect(
    left.board(firstBoard.id)?.focusedCenter(of: firstNotebook.item.id)
      == firstCenter
  )
  #expect(
    left.board(secondBoard.id)?.focusedCenter(of: secondNotebook.item.id)
      == secondCenter
  )
}

@Test("Новый предмет на одной доске не стирает новое движение на другой")
func catalogGrowthPreservesAnIndependentBoardEdit() throws {
  let actor = UUID()
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var workspace = initial.index
  var base = BoardHierarchy.initial(
    rootBoardID: workspace.rootBoardID,
    itemIDs: workspace.items.map(\.id),
    actor: actor
  )
  let firstBoardCreation = workspace.createBoard(title: "A", actor: actor)
  let firstBoard = try #require(firstBoardCreation)
  let firstCreated = base.createBoard(
    firstBoard.id,
    in: workspace.rootBoardID,
    near: .zero,
    actor: actor
  )
  #expect(firstCreated)
  let secondBoardCreation = workspace.createBoard(title: "B", actor: actor)
  let secondBoard = try #require(secondBoardCreation)
  let secondCreated = base.createBoard(
    secondBoard.id,
    in: workspace.rootBoardID,
    near: WorldPoint(x: 900, y: 0),
    actor: actor
  )
  #expect(secondCreated)
  let secondNotebookCreation = workspace.createNotebook(
    title: "Вторая",
    actor: actor,
    pageSize: initial.page.size
  )
  let secondNotebook = try #require(secondNotebookCreation)
  let secondAdded = base.addItem(
    secondNotebook.item.id,
    to: secondBoard.id,
    near: .zero,
    actor: actor
  )
  #expect(secondAdded)

  var local = base
  let movedCenter = WorldPoint(x: -420, y: 760)
  let moved = local.moveItem(
    secondNotebook.item.id,
    in: secondBoard.id,
    to: movedCenter,
    actor: actor
  )
  #expect(moved)

  var incoming = base
  let addedNotebookCreation = workspace.createNotebook(
    title: "Первая",
    actor: actor,
    pageSize: initial.page.size
  )
  let addedNotebook = try #require(addedNotebookCreation)
  let added = incoming.addItem(
    addedNotebook.item.id,
    to: firstBoard.id,
    near: WorldPoint(x: 120, y: 240),
    actor: actor
  )
  #expect(added)

  let merged = local.merge(incoming, items: workspace.items)
  #expect(merged)
  #expect(local.isValid(items: workspace.items))
  #expect(
    local.board(secondBoard.id)?.focusedCenter(of: secondNotebook.item.id)
      == movedCenter
  )
  #expect(
    local.board(firstBoard.id)?.focusedCenter(of: addedNotebook.item.id)
      == WorldPoint(x: 120, y: 240)
  )
}
