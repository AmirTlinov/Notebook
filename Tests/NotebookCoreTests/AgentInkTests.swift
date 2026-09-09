import Foundation
import Testing
@testable import NotebookCore

private struct AgentInkFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-ink-\(UUID())")
  let store: NotebookStore
  let human = UUID(), agent = UUID()
  let page: CollaborationTarget
  let board: CollaborationTarget
  let cover: CollaborationTarget

  init() throws {
    store = NotebookStore(root: root)
    let (index, _) = try store.loadOrCreate(actor: human, pageSize: .init(width: 834, height: 1194))
    _ = try store.loadOrCreateSpatialInk(actor: human)
    page = .init(kind: .page, id: index.selectedPageID!)
    board = .init(kind: .board, id: index.rootBoardID)
    cover = .init(kind: .cover, id: index.selectedItemID, boardID: index.rootBoardID)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func expectation(_ target: CollaborationTarget) throws -> CollaborationExpectation {
    if target.kind == .page {
      let page = try store.loadPage(target.id)
      return .init(target: target, revision: page.agentStamp.revision, inkRevision: page.drawingStamp.revision)
    }
    let board = try store.loadBoard(items: store.loadIndex().items).board(target.boardID ?? target.id)!
    return .init(target: target, revision: board.stamp.revision, inkRevision: try store.loadSpatialInk().stamp.revision)
  }
  func stroke(_ target: CollaborationTarget, id: UUID = UUID()) throws -> CollaborationOperation {
    var values: [String: JSONValue] = ["width": .number(4), "opacity": .number(0.7),
      "color": .object(["red": .number(0.2), "green": .number(0.3), "blue": .number(0.8)]),
      "points": .array([.object(["x": .number(100), "y": .number(120)]),
        .object(["x": .number(160), "y": .number(190), "width": .number(3), "opacity": .number(0.4)])])]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint(tileX: 1_000_000, tileY: -1_000_000, localX: 20, localY: 30)) }
    return .init(kind: .appendInkStroke, target: target, id: id.uuidString, values: values)
  }
  func action(_ ops: [CollaborationOperation]) throws -> CollaborationAction {
    .init(summary: "Рисунок общей ручкой", expected: try Array(Set(ops.map(\.target))).map(expectation), operations: ops)
  }
}

@Test("Агент добавляет точные нативные штрихи на лист, доску и обложку одним ходом")
func agentInkUsesExistingOwners() throws {
  let f = try AgentInkFixture(); defer { f.clean() }
  let before = try f.store.collaborationContent()
  let operations = try [f.page, f.board, f.cover].map { try f.stroke($0) }
  let action = try f.action(operations)
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(try f.store.applyCollaborationAction(action, actor: f.agent) == receipt)
  let content = try f.store.collaborationContent()
  let page = try #require(content.pages.first)
  let drawing = try PageInkDrawing.decode(page.drawingData)
  #expect(drawing.activeActions.count == 1)
  #expect(try drawing.activeActions[0].samples == CollaborationInkStroke(operations[0]).samples)
  #expect(try drawing.activeActions[0].color == CollaborationInkStroke(operations[0]).color)
  #expect(drawing.activeActions[0].tool == .pen)
  #expect(page.elements.isEmpty && content.hierarchy == before.hierarchy)
  #expect(content.workspace == before.workspace)
  #expect(page.agentStamp == before.pages[0].agentStamp)
  #expect(page.drawingStamp > before.pages[0].drawingStamp)
  #expect(content.ink.actions.count == 2)
  #expect(content.ink.actions[0].spans[0].samples[0].worldPoint?.tileX == 1_000_000)
  #expect(content.ink.actions[1].spans[0].surface == .cover(f.cover.id))
  #expect(receipt.revisions.allSatisfy { $0.inkRevision != nil })
  #expect(receipt.changes.isEmpty)
  let references = receipt.resultReferences(in: content)
  #expect(references.count == 3 && references.allSatisfy { $0.region != nil && $0.elementID == nil })
  #expect(references.first { $0.target == f.board }?.worldOrigin != nil)
}

@Test("Отмена агентской ручки сохраняет поздние Pencil и ластик и переживает старый сетевой пакет")
func agentInkUndoPreservesLaterContacts() throws {
  let f = try AgentInkFixture(); defer { f.clean() }
  let ops = try [f.page, f.board, f.cover].map { try f.stroke($0) }
  let action = try f.action(ops)
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  let stale = try f.store.collaborationContent()
  var page = try f.store.loadPage(f.page.id)
  let point = try CollaborationInkStroke(ops[0]).samples[0]
  let humanPen = PageInkAction(tool: .pen, samples: [point])
  let eraser = PageInkAction(tool: .eraser, samples: [point])
  let later = try PageInkDrawing.decode(page.drawingData).appending(humanPen).appending(eraser)
  #expect(page.replaceDrawing(try later.dataRepresentation(), actor: f.human))
  try f.store.savePage(page)
  var ink = try f.store.loadSpatialInk()
  let appended = try ink.append(tool: .pen, spans: [CollaborationInkStroke(ops[2]).span(on: f.cover)], actor: f.human)
  let humanSpatial = try #require(appended)
  try f.store.saveSpatialInk(ink)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.agent)
  #expect(undone.undo?.restored == 3)
  #expect(try f.store.undoCollaborationAction(action.id, actor: f.agent) == undone)
  _ = try f.store.mergeCollaborationContent(stale)
  let result = try f.store.loadPage(f.page.id)
  #expect(try PageInkDrawing.decode(result.drawingData).activeActions.map(\.id) == [humanPen.id, eraser.id])
  #expect(try f.store.loadSpatialInk().actions.filter(\.isActive).map(\.id) == [humanSpatial.id])
}

@Test("Две независимые ручки сходятся по UUID, порядку и отмене, а не заменяют лист")
func pageInkConcurrentAppendAndUndoConverge() throws {
  let actor = UUID(), peer = UUID()
  let base = PageDocument(size: .init(width: 834, height: 1194), actor: actor)
  let sample = SpatialInkSample(point: .init(x: 10, y: 20), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
  let human = PageInkAction(tool: .pen, samples: [sample]), agent = PageInkAction(tool: .pen, samples: [sample])
  var a = base, b = base
  a.replaceDrawing(try PageInkDrawing().appending(human).dataRepresentation(), actor: actor)
  b.replaceDrawing(try PageInkDrawing().appending(agent).dataRepresentation(), actor: peer)
  let oldA = a, oldB = b
  #expect((a.merge(oldB) && b.merge(oldA)))
  #expect(a == b)
  let repeated = a.merge(b)
  #expect(!repeated)
  let drawing = try PageInkDrawing.decode(a.drawingData)
  #expect(Set(drawing.activeActions.map(\.id)) == [human.id, agent.id])
  a.replaceDrawing(try drawing.removing([agent.id]).dataRepresentation(), actor: actor)
  let receivedUndo = b.merge(a)
  #expect(receivedUndo)
  _ = b.merge(oldB)
  #expect(try PageInkDrawing.decode(b.drawingData).activeActions.map(\.id) == [human.id])
}

@Test("Локальная отмена Pencil после агентского добавления удаляет только свой контакт")
func pencilUndoKeepsAgentStroke() throws {
  let sample = SpatialInkSample(point: .init(x: 10, y: 20), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
  let human = PageInkAction(tool: .pen, samples: [sample]), agent = PageInkAction(tool: .pen, samples: [sample])
  let pageID = UUID()
  let drawing = PageInkDrawing().appending(human).appending(agent)
  var history = PencilUndoHistory()
  history.recordAction(pageID: pageID, actionID: human.id)
  let ids = try #require(history.lastContribution(for: pageID))
  let result = drawing.removing(ids)
  history.didRemoveContribution(ids, for: pageID)
  #expect(result.activeActions.map(\.id) == [agent.id])
}

@Test("Неверная или устаревшая ручка не публикует частичный пакет")
func agentInkRejectsInvalidAndStaleActions() throws {
  let f = try AgentInkFixture(); defer { f.clean() }
  let initial = try f.store.collaborationContent()
  let valid = try f.stroke(f.page)
  let missingRevision = CollaborationAction(summary: "Без версии чернил", expected: [.init(target: f.page, revision: initial.pages[0].agentStamp.revision)], operations: [valid])
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(missingRevision, actor: f.agent) }
  for patch: [String: JSONValue] in [
    ["points": .array([])], ["width": .number(0)], ["opacity": .number(2)],
    ["points": .array([.object(["x": .number(-5), "y": .number(10)])])],
    ["color": .object(["red": .number(-1), "green": .number(0), "blue": .number(0)])],
    ["points": .array(Array(repeating: .object(["x": .number(20), "y": .number(20)]), count: 8193))]
  ] {
    let values = valid.values.merging(patch) { _, new in new }
    let bad = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString, values: values)
    #expect(throws: (any Error).self) { try f.store.applyCollaborationAction(f.action([valid, bad]), actor: f.agent) }
    #expect(try f.store.collaborationContent() == initial)
  }
  let stale = try f.action([valid])
  _ = try f.store.applyCollaborationAction(f.action([f.stroke(f.page)]), actor: f.agent)
  #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(stale, actor: f.agent) }
  #expect(try f.store.collaborationActions().count == 1)
}

@Test("Штрих и его отмена публикуются вместе с квитанцией на вторую копию")
func agentInkEnvelopeCarriesContentAndUndo() throws {
  let f = try AgentInkFixture(); defer { f.clean() }
  let remoteRoot = f.root.appendingPathComponent("peer")
  let remote = NotebookStore(root: remoteRoot)
  let before = try f.store.collaborationContent()
  try remote.publishRecords(writes: before.sourceFiles())

  let action = try f.action([f.stroke(f.page), f.stroke(f.board)])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let after = try f.store.collaborationContent()
  _ = try remote.receiveCollaboration(.init(content: after.publication(since: before), actions: [receipt]))
  #expect(try remote.loadPage(f.page.id) == f.store.loadPage(f.page.id))
  #expect(try remote.loadSpatialInk() == f.store.loadSpatialInk())
  #expect(try remote.collaborationAction(action.id) == receipt)
  let undo = try f.store.undoCollaborationAction(action.id, actor: f.agent)
  _ = try remote.receiveCollaboration(.init(content: f.store.collaborationContent().publication(since: after), actions: [undo]))
  #expect(try PageInkDrawing.decode(remote.loadPage(f.page.id).drawingData).isEmpty)
  #expect(try remote.loadSpatialInk().actions.allSatisfy { !$0.isActive })
}

@Test("Production отвергает старый нативный архив и записи без явных часов")
func agentInkRejectsOldArchivesAndImplicitClocks() throws {
  let sample = SpatialInkSample(point: .init(x: 10, y: 20), timeOffset: 0, width: 3, opacity: 0.3, force: 0.1, azimuth: 0, altitude: 1)
  let pen = PageInkAction(tool: .pen, samples: [sample])
  let eraser = PageInkAction(tool: .eraser, samples: [sample])
  let legacy = try JSONValue.encode(PageInkDrawing(actions: [pen, eraser])).setting("actions", .array([
    try JSONValue.encode(pen).setting("sequence", nil).setting("isActive", nil),
    try JSONValue.encode(eraser).setting("sequence", nil).setting("isActive", nil)
  ]))
  let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
  let data = try Data("NotebookInk/1\n".utf8) + PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
  #expect(throws: PageInkDrawing.InkError.self) { try PageInkDrawing.decode(data) }
  let incompleteNew = Data("NotebookInk/2\n".utf8) + (try JSONEncoder().encode(legacy))
  #expect(throws: (any Error).self) { try PageInkDrawing.decode(incompleteNew) }
}

@Test("Повторный сетевой обмен нативными чернилами перестаёт менять байты и версии")
func agentInkThreeWayMergeSettles() throws {
  let sample = SpatialInkSample(point: .init(x: 10, y: 20), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
  let actor = UUID()
  let base = PageDocument(size: .init(width: 400, height: 400), actor: actor)
  var peers = [base, base, base]
  for i in peers.indices {
    peers[i].replaceDrawing(try PageInkDrawing().appending(.init(tool: i == 2 ? .eraser : .pen, samples: [sample])).dataRepresentation(), actor: UUID())
  }
  for _ in 0..<3 {
    for i in peers.indices {
      for j in peers.indices where i != j { _ = peers[i].merge(peers[j]) }
    }
  }
  let settled = peers
  for i in peers.indices {
    for j in peers.indices where i != j { _ = peers[i].merge(peers[j]) }
  }
  #expect(peers == settled)
  #expect(peers[0] == peers[1] && peers[1] == peers[2])
  #expect(try PageInkDrawing.decode(peers[0].drawingData).actionCount == 3)
}

@Test("Создание тетради и рисунок на её листе и обложке отменяются одним ходом")
func agentInkCreationAndUndoHaveOneOwner() throws {
  let f = try AgentInkFixture(); defer { f.clean() }
  let itemID = UUID(), pageID = UUID()
  let page = CollaborationTarget(kind: .page, id: pageID)
  let cover = CollaborationTarget(kind: .cover, id: itemID, boardID: f.board.id)
  let initial = try f.store.loadIndex()
  let action = CollaborationAction(summary: "Создать и нарисовать", expected: [try f.expectation(f.board),
    .init(target: .init(kind: .workspace, id: f.board.id), revision: initial.stamp.revision)], operations: [
      .init(kind: .createNotebook, target: f.board, id: itemID.uuidString,
        values: ["pageID": .string(pageID.uuidString), "center": try .encode(WorldPoint(x: 300, y: 400))]),
      try f.stroke(page), try f.stroke(cover)
    ])
  _ = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(try PageInkDrawing.decode(f.store.loadPage(pageID).drawingData).activeActions.count == 1)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.agent)
  #expect(undone.undo != nil)
  #expect(try !f.store.loadIndex().items.contains { $0.id == itemID })
  #expect(try f.store.loadSpatialInk().actions.allSatisfy { !$0.isActive })
}
