import Foundation
import Testing
@testable import NotebookCore

@Suite("Panel cards use native placement admission")
struct NotebookPanelPlacementTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-panel-card-\(UUID())")
    let actor = UUID()
    let store: NotebookStore
    let workspaceID: UUID
    let boardID: UUID
    let items: [UUID]
    var target: CollaborationTarget { .init(kind: .board, id: boardID) }

    init() throws {
      store = .init(root: root)
      let (initial, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      workspaceID = try store.storedWorkspaceID(); boardID = initial.rootBoardID
      var index = initial, tree = try store.loadBoard(items: index.items), ids = [initial.selectedItemID]
      for n in 1...2 {
        let created = index.createBoard(title: "Card \(n)", actor: actor)
        let child = try #require(created)
        let placed = tree.createBoard(child.id, in: boardID, near: .init(x: Double(n) * 1500, y: 0), actor: actor)
        #expect(placed)
        try store.saveBoardWorkspaceBundle(index: index, board: tree, boardID: child.id)
        ids.append(child.id)
      }
      items = ids
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func placement(_ id: UUID) throws -> WorkspacePlacement {
      try #require(try store.readBoardItem(id)?.board.placements.first { $0.id == id })
    }
    func source(_ id: UUID) throws -> NotebookPanelEditSource {
      let snapshot = try store.readPanel(.init(workspaceID: workspaceID, target: target,
        bounds: .init(anchor: .init(x: -1000, y: -1000), region: .init(x: 0, y: 0, width: 10_000, height: 4000))), actor: actor)
      let card = try #require(snapshot["cards"]?.array.first { $0["item"]?["id"]?.string.flatMap(UUID.init(uuidString:)) == id })
      return try #require(card["source"]).decode(NotebookPanelEditSource.self)
    }
    func move(_ id: UUID, to center: WorldPoint) throws -> CollaborationOperation {
      .init(kind: .moveItem, target: target, id: id.uuidString, values: ["center": try .encode(center)])
    }
    func edit(_ source: NotebookPanelEditSource, to center: WorldPoint, actionID: UUID = UUID()) throws -> NotebookPanelEditRequest {
      .init(workspaceID: workspaceID, actionID: actionID, target: target, summary: "Перенос карточки",
        operations: [try move(UUID(uuidString: source.id)!, to: center)], sources: [source])
    }
    func native(_ operations: [CollaborationOperation], ids: [UUID]) throws {
      var sources: [UUID: WorkspacePlacement] = [:]
      for id in ids {
        for placement in try #require(try store.readBoardItem(id)).board.placements { sources[placement.id] = placement }
      }
      _ = try store.applyNativePlacementEdits(operations, summary: "Изменение расположения",
        sources: sources.values.sorted { $0.id.uuidString < $1.id.uuidString }, actor: UUID())
    }
    func stack(_ a: UUID, onto b: UUID) throws {
      try native([.init(kind: .stackItems, target: target, values: ["itemIDs": try .encode([a, b])])], ids: [a, b])
    }
    func renameByAgent(_ id: UUID, title: String) throws {
      let basis = try store.readBasis(targets: [target, .init(kind: .workspace, id: boardID)])
      _ = try store.applyCollaborationAction(.init(summary: "Уточнить заголовок",
        expected: basis.owners,
        operations: [.init(kind: .renameItem, target: target, id: id.uuidString, values: ["title": .string(title)])]), actor: UUID())
    }
  }

  @Test func aCardMoveReplaysAfterColdReopenAndUndoKeepsAgentContent() throws {
    let f = try Fixture(); defer { f.clean() }
    let id = f.items[0], source = try f.source(id), original = try f.placement(id)
    #expect(source.page == nil && source.spatial == nil)
    #expect(source.placements == [original])
    try f.renameByAgent(id, title: "Заголовок до переноса")
    let request = try f.edit(source, to: .init(tileX: 2, tileY: -1, localX: 200, localY: 300))
    let accepted = try f.store.editPanel(request, actor: f.actor)
    let action = try f.store.collaborationAction(request.actionID)
    #expect(action.author == .human && action.requestFingerprint != nil)
    #expect(try f.placement(id).pose?.center == request.operations[0].values["center"]?.decode(WorldPoint.self))
    #expect(try f.store.nativeHistory(domain: .board(f.boardID), actor: f.actor).last == .command(request.actionID))
    try f.renameByAgent(id, title: "Заголовок агента после переноса")
    let cold = NotebookStore(root: f.root)
    #expect(try cold.editPanel(request, actor: f.actor) == accepted)
    let altered = try f.edit(source, to: .zero, actionID: request.actionID)
    #expect(throws: CollaborationError.self) { try cold.editPanel(altered, actor: f.actor) }
    let undo = NotebookPanelUndoRequest(workspaceID: f.workspaceID, target: f.target, actionID: request.actionID)
    let undone = try cold.undoPanel(undo, actor: f.actor)
    #expect(try cold.undoPanel(undo, actor: f.actor) == undone)
    #expect(try cold.editPanel(request, actor: f.actor) == accepted)
    #expect(try f.placement(id).pose == original.pose)
    #expect(try cold.readItemHeader(id)?.title == "Заголовок агента после переноса")
  }

  @Test(arguments: [false, true])
  func stalePlacementHeadsOrStackMembershipRejectWithoutWriting(stackMembership: Bool) throws {
    let f = try Fixture(); defer { f.clean() }
    let a = f.items[0], b = f.items[1], c = f.items[2]
    if stackMembership { try f.stack(a, onto: b) }
    let source = try f.source(a), original = try f.placement(a)
    if stackMembership {
      #expect(source.placements?.count == 2)
      try f.stack(c, onto: b)
      #expect(try f.placement(a) == original, "A new sibling leaves the moving item's own heads untouched")
    } else {
      try f.native([f.move(a, to: .init(x: 100, y: 200))], ids: [a])
      try f.native([f.move(a, to: try #require(original.pose).center)], ids: [a])
      #expect(try f.placement(a).pose?.center == original.pose?.center)
    }
    let request = try f.edit(source, to: .zero), cursor = try f.store.currentChangeCursor()
    let current = try f.placement(a)
    #expect(throws: CollaborationError.self) { try f.store.editPanel(request, actor: f.actor) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.placement(a) == current)
    #expect(try f.store.collaborationActionIfPresent(request.actionID) == nil)
  }
}
