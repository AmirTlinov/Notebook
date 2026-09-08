import Foundation
import Testing
@testable import NotebookCore

@Test("Портал сохраняет весь диапазон камеры в каждом размере окна", arguments: [
  SpatialPoint(x: 320, y: 480),
  SpatialPoint(x: 834, y: 1_194),
  SpatialPoint(x: 1_366, y: 1_024),
  SpatialPoint(x: 3_024, y: 1_964),
], [SpatialCamera.minimumScale, 0.03, 0.22, 1.0, SpatialCamera.maximumScale])
func portalCameraRoundTrip(viewport: SpatialPoint, scale: Double) throws {
  let camera = SpatialCamera(center: WorldPoint(x: 12_340, y: -4_560), scale: scale)
  let saved = BoardPortalProjection.portalCamera(from: camera, viewport: viewport)
  #expect((saved.isValid))
  let decoded = try JSONDecoder().decode(
    BoardPortalCamera.self, from: JSONEncoder().encode(saved)
  )
  let entered = BoardPortalProjection.entryCamera(portalCamera: decoded, viewport: viewport)
  #expect((entered.center == camera.center))
  #expect((abs(entered.scale - scale) < 1e-12))

  let renderViewport = BoardPortalProjection.renderViewport(viewport: viewport)
  let fill = BoardPortalProjection.fillScale(viewport: viewport)
  let point = camera.center.offsetBy(x: 300, y: -150)
  let preview = entered.worldToScreen(point, viewport: renderViewport)
  let portalCenter = WorldPoint(x: 7_200, y: 300)
  let parentPoint = portalCenter.offsetBy(
    x: (preview.x - renderViewport.x / 2) / fill,
    y: (preview.y - renderViewport.y / 2) / fill
  )
  let boundary = BoardPortalProjection.parentBoundaryCamera(
    portalCenter: portalCenter, viewport: viewport
  ).worldToScreen(parentPoint, viewport: viewport)
  let active = entered.worldToScreen(point, viewport: viewport)
  #expect((abs(boundary.x - active.x) < 1e-8))
  #expect((abs(boundary.y - active.y) < 1e-8))
}

@Test("Слияние независимых досок меняет идентичность при прежнем максимуме часов")
func mergedBoardFrontierNamesEveryOwner() throws {
  let (workspace, base, childID) = try portalFixture()
  var left = base
  var right = base
  let highActor = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
  let lowActor = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
  let result1 = left.moveItem(workspace.items[0].id, in: workspace.rootBoardID,
    to: WorldPoint(x: 100, y: 100), actor: highActor)
  #expect(result1)
  let result2 = right.updatePortalCamera(BoardPortalCamera(scale: 0.8), for: childID, actor: lowActor)
  #expect(result2)
  let oldRevision = left.revision
  let oldStamp = left.stamp
  let unmergedLeft = left
  let result3 = left.merge(right, items: workspace.items)
  #expect(result3)
  #expect((left.stamp == oldStamp))
  #expect((left.revision != oldRevision))
  let result4 = right.merge(unmergedLeft, items: workspace.items)
  #expect(result4)
  #expect((right.revision == left.revision))
  let reordered = BoardHierarchy(rootBoardID: left.rootBoardID,
    boards: left.boards.reversed(), stamp: left.stamp)
  #expect((reordered.revision == left.revision))
}

@Test("Доска с элементом или редактируемыми чернилами сохраняет владельца")
func boardDeletionProtectsEveryContentOwner() throws {
  let (workspace, base, childID) = try portalFixture()
  let actor = workspace.stamp.actor
  var hierarchy = base
  var ink = SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: actor))
  let element = SpatialElement(
    id: "note", surface: .board(childID), kind: .nativeText,
    frame: SpatialRect(x: 0, y: 0, width: 200, height: 100), worldOrigin: .zero,
    source: "Сохранить", stamp: VersionStamp(counter: 0, actor: actor)
  )
  let result5 = hierarchy.upsertElement(element, in: childID, expected: nil, actor: actor)
  #expect(result5)
  let result6 = !hierarchy.deleteItem(childID, from: workspace.rootBoardID,
    kind: .board, spatialInk: ink, actor: actor)
  #expect(result6)
  let result7 = hierarchy.removeElements(ids: [element.id], from: childID, actor: actor) == 1
  #expect(result7)
  let span = SpatialInkSpan(surface: .board(childID), samples: [SpatialInkSample(
    point: .zero, worldPoint: .zero, timeOffset: 0, width: 4, opacity: 1,
    force: 1, azimuth: 0, altitude: 1
  )])
  _ = ink.append(tool: .pen, spans: [span], actor: actor)
  _ = ink.append(tool: .eraser, spans: [span], actor: actor)
  let result8 = !hierarchy.deleteItem(childID, from: workspace.rootBoardID,
    kind: .board, spatialInk: ink, actor: actor)
  #expect(result8)
  _ = ink.undoLast(actor: actor)
  _ = ink.undoLast(actor: actor)
  let result9 = hierarchy.deleteItem(childID, from: workspace.rootBoardID,
    kind: .board, spatialInk: ink, actor: actor)
  #expect(result9)
}

@Test("Файловый замок защищает содержимое доски, пришедшее перед удалением")
func boardDeletionRechecksDurableContent() throws {
  let (workspace, base, childID) = try portalFixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let actor = workspace.stamp.actor
  let page = PageDocument(id: workspace.items[0].pageIDs[0], size: .init(width: 834, height: 1194), actor: actor)
  try store.saveWorkspaceBundle(index: workspace, page: page, board: base)
  let ink = SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: actor))
  try store.saveSpatialInk(ink)
  var removedIndex = workspace
  var removedBoard = base
  _ = removedIndex.deleteItem(childID, actor: actor)
  let result10 = removedBoard.deleteItem(childID, from: workspace.rootBoardID,
    kind: .board, spatialInk: ink, actor: actor)
  #expect(result10)
  var newer = base
  let element = SpatialElement(
    id: "just-arrived", surface: .board(childID), kind: .nativeText,
    frame: SpatialRect(x: 0, y: 0, width: 200, height: 100), worldOrigin: .zero,
    source: "Сохранить", stamp: VersionStamp(counter: 0, actor: actor)
  )
  let result11 = newer.upsertElement(element, in: childID, expected: nil, actor: actor)
  #expect(result11)
  try store.saveBoard(newer, items: workspace.items)
  #expect(throws: NotebookStoreError.self) {
    try store.deleteWorkspaceBundle(expectedIndex: workspace, index: removedIndex, board: removedBoard, pageIDs: [])
  }
  #expect((try store.loadIndex() == workspace))
  #expect((try store.loadBoard(items: workspace.items) == newer))
}

private func portalFixture() throws -> (WorkspaceIndex, BoardHierarchy, UUID) {
  let actor = UUID()
  var workspace = WorkspaceIndex.initial(actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)).index
  var hierarchy = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID,
    itemIDs: workspace.items.map(\.id), actor: actor)
  let created = workspace.createBoard(title: "Доска", actor: actor)
  let child = try #require(created)
  let result12 = hierarchy.createBoard(child.id, in: workspace.rootBoardID, near: .zero, actor: actor)
  #expect(result12)
  return (workspace, hierarchy, child.id)
}


@Test("Swift и MCP называют одинаковый полный фронт дерева")
func boardRevisionCrossLanguageVector() {
  let id = UUID(uuidString: "7e7a0000-0000-4000-8000-000000000003")!
  let hierarchy = BoardHierarchy.initial(rootBoardID: id, itemIDs: [], actor: id)
  #expect(hierarchy.revision == "480b5648900dd575275f5bb02828bc85d5d49a3ced16ad2f16d3ef6158103eb5")
}

@Test("Удаление сохраняет пришедшие чернила и новый предмет каталога", arguments: [false, true])
func boardDeletionProtectsRacingOwners(catalogChanged: Bool) throws {
  let (workspace, base, childID) = try portalFixture()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  let actor = workspace.stamp.actor
  let page = PageDocument(id: workspace.items[0].pageIDs[0], size: .init(width: 834, height: 1194), actor: actor)
  try store.saveWorkspaceBundle(index: workspace, page: page, board: base)
  var ink = SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: actor))
  try store.saveSpatialInk(ink)
  var removedIndex = workspace
  var removedBoard = base
  _ = removedIndex.deleteItem(childID, actor: actor)
  let deleted = removedBoard.deleteItem(childID, from: workspace.rootBoardID,
    kind: .board, spatialInk: ink, actor: actor)
  #expect(deleted)
  var latestIndex = workspace
  var latestBoard = base
  if catalogChanged {
    let creation = latestIndex.createBoard(title: "Пришла", actor: actor)
    let created = try #require(creation)
    let added = latestBoard.createBoard(created.id, in: workspace.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    try store.saveBoardWorkspaceBundle(index: latestIndex, board: latestBoard, boardID: created.id)
  } else {
    _ = ink.append(tool: .pen, spans: [SpatialInkSpan(surface: .board(childID), samples: [
      SpatialInkSample(point: .zero, worldPoint: .zero, timeOffset: 0,
        width: 8, opacity: 1, force: 1, azimuth: 0, altitude: 1),
    ])], actor: actor)
    try store.saveSpatialInk(ink)
  }
  let publishedBoard = try store.loadBoard(items: latestIndex.items)
  #expect(throws: NotebookStoreError.self) {
    try store.deleteWorkspaceBundle(expectedIndex: workspace, index: removedIndex,
      board: removedBoard, pageIDs: [])
  }
  #expect(try store.loadIndex() == latestIndex)
  #expect(try store.loadBoard(items: latestIndex.items) == publishedBoard)
  #expect(try store.loadSpatialInk() == ink)
}
