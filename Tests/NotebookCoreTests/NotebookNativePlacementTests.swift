import Foundation
import Testing
@testable import NotebookCore

@Suite("Native placement shares causal action history")
struct NotebookNativePlacementTests {
  private enum Fault: Error { case disk }
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let actor = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
    let store: NotebookStore
    let boardID: UUID
    let items: [UUID]
    var target: CollaborationTarget { .init(kind: .board, id: boardID) }
    init() throws {
      store = .init(root: root)
      let (initial, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      boardID = initial.rootBoardID
      var index = initial, tree = try store.loadBoard(items: index.items), ids = [initial.selectedItemID]
      for n in 1...2 {
        let created = index.createBoard(title: "Board \(n)", actor: actor)
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
    func sources(_ ids: [UUID]) throws -> [WorkspacePlacement] {
      var values: [UUID: WorkspacePlacement] = [:]
      for id in ids {
        for p in try #require(try store.readBoardItem(id)).board.placements { values[p.id] = p }
      }
      return values.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func move(_ id: UUID, to center: WorldPoint) throws -> CollaborationOperation {
      .init(kind: .moveItem, target: target, id: id.uuidString, values: ["center": try .encode(center)])
    }
    func stack(_ moving: UUID, onto targetID: UUID) throws -> CollaborationOperation {
      .init(kind: .stackItems, target: target, values: ["itemIDs": try .encode([moving, targetID])])
    }
    func command(_ operations: [CollaborationOperation], ids: [UUID], actor author: UUID? = nil,
      actionID: UUID = UUID()) throws -> NotebookNativeCommand<WorkspacePlacement> {
      try .init(operations, summary: "Перенос предмета", placements: sources(ids), actionID: actionID, actor: author ?? actor)
    }
    func publish(_ value: WorkspacePlacement) throws {
      let before = try store.loadBoard(items: store.loadIndex().items)
      let path: [CollaborationPathComponent] = [.field("boards"), .member(boardID.uuidString),
        .field("board"), .field("placements"), .member(value.id.uuidString)]
      let after = try #require(JSONValue.encode(before).setting(at: path[...], to: .encode(value))).decode(BoardHierarchy.self)
      _ = try store.saveBoardEdits(before: before, after: after)
    }
  }

  @Test func aDropIsOneMixedEntryAndItsRedoAuthorsNewHeadsWithTheSameStack() throws {
    let f = try Fixture(); defer { f.clean() }
    let a = f.items[0], b = f.items[1], before = try f.sources([a, b]), actionID = UUID()
    let stroke = SpatialInkAction(tool: .pen, spans: [.init(surface: .board(f.boardID), samples: [
      .init(point: .init(x: 10, y: 10), worldPoint: .init(x: 10, y: 10), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], stamp: .init(counter: 1, actor: f.actor))
    _ = try f.store.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp))
    let dropped = try f.command([f.move(a, to: .init(x: 1400, y: 0)), f.stack(a, onto: b)],
      ids: [a, b], actionID: actionID).apply(to: f.store)
    let domain = PencilUndoHistory.Domain.board(f.boardID)
    #expect(dropped.receipt.author == .human)
    #expect(dropped.sources.allSatisfy { $0.heads.count == 1 && $0.winner.version.human })
    #expect(try f.placement(a).pose?.stackID == NotebookStore.submissionID(actionID, suffix: "stack:1"))
    #expect(try f.store.nativeHistory(domain: domain, actor: f.actor) == [.ink([stroke.id]), .command(actionID)])
    let inverse = try f.store.undoNativeAction(actionID, actor: f.actor)
    #expect(inverse.undo?.preserved.isEmpty == true)
    #expect(inverse.undo?.redoGates?.count == 2)
    #expect(try f.sources([a, b]).map(\.pose) == before.map(\.pose))
    let cold = NotebookStore(root: f.root), repeatedID = UUID()
    let repeated = try cold.redoNativeAction(actionID, actionID: repeatedID, actor: f.actor)
    #expect(repeated.redoOf == actionID)
    #expect(try cold.nativeHistory(domain: domain, actor: f.actor) == [.ink([stroke.id]), .command(repeatedID)])
    #expect(try cold.nativeRedoHistory(domain: domain, actor: f.actor).isEmpty)
    for accepted in dropped.sources {
      let current = try f.placement(accepted.id)
      #expect(current.pose == accepted.pose && current.stamp > accepted.stamp)
      #expect(try current.merging(accepted) == current, "Old transport echo cannot undo the new placement")
    }
    #expect(try cold.redoNativeAction(actionID, actionID: repeatedID, actor: f.actor) == repeated)
    _ = try cold.undoNativeAction(repeatedID, actor: f.actor)
    #expect(try f.sources([a, b]).map(\.pose) == before.map(\.pose))
    #expect(try cold.nativeHistory(domain: domain, actor: f.actor) == [.ink([stroke.id])])
  }

  @Test func exactHeadsAllowUnrelatedEditsButRejectChangedStackMembership() throws {
    let f = try Fixture(); defer { f.clean() }
    let a = f.items[0], b = f.items[1], c = f.items[2], peer = UUID()
    let moving = try f.command([f.move(a, to: .init(x: 120, y: 130))], ids: [a])
    _ = try f.command([f.move(c, to: .init(x: 8000, y: 8000))], ids: [c], actor: peer).apply(to: f.store)
    _ = try moving.apply(to: f.store)
    #expect(try f.placement(a).pose?.center == .init(x: 120, y: 130))
    #expect(try f.placement(c).pose?.center == .init(x: 8000, y: 8000))
    _ = try f.command([f.stack(a, onto: b)], ids: [a, b]).apply(to: f.store)
    let captured = try f.command([f.move(a, to: .zero)], ids: [a])
    let previousA = try f.placement(a)
    _ = try f.command([f.stack(c, onto: b)], ids: [c, b], actor: peer).apply(to: f.store)
    #expect(try f.placement(a) == previousA, "Adding a sibling does not rewrite the moving item")
    #expect(throws: CollaborationError.self) { try captured.apply(to: f.store) }
    #expect(try f.store.readBoardItem(a)?.board.stack(containing: a)?.itemIDs.count == 3)
  }

  @Test(arguments: [false, true], [0, 2])
  func successiveMovesUndoAndRedoInOrderAfterColdReopen(peerAfterFirstRedo: Bool, repeatFirstRedo: Int) throws {
    let f = try Fixture(); defer { f.clean() }
    let id = f.items[0], initial = try f.placement(id), domain = PencilUndoHistory.Domain.board(f.boardID)
    var accepted: [NotebookNativeCommand<WorkspacePlacement>.Output] = []
    for offset in 1...3 {
      accepted.append(try f.command([f.move(id, to: .init(x: Double(offset) * 100, y: 50))], ids: [id]).apply(to: f.store))
    }
    for command in accepted.reversed() {
      let inverse = try f.store.undoNativeAction(command.receipt.id, actor: f.actor)
      #expect(inverse.undo?.preserved.isEmpty == true)
    }
    #expect(try f.placement(id).pose == initial.pose)
    let cold = NotebookStore(root: f.root)
    #expect(try cold.nativeRedoHistory(domain: domain, actor: f.actor).count == 3)
    for (offset, command) in accepted.enumerated() {
      var repeated = try cold.redoNativeAction(command.receipt.id, actionID: UUID(), actor: f.actor)
      if offset == 0 {
        for _ in 0..<repeatFirstRedo {
          _ = try cold.undoNativeAction(repeated.id, actor: f.actor)
          repeated = try NotebookStore(root: f.root).redoNativeAction(repeated.id, actionID: UUID(), actor: f.actor)
        }
      }
      #expect(try f.placement(id).pose == command.sources[0].pose)
      if peerAfterFirstRedo, offset == 0 {
        let current = try f.placement(id)
        let peer = try WorkspacePlacement.authored(itemID: id, pose: current.pose,
          stamp: .init(counter: current.stamp.counter + 1, actor: UUID()), human: true, previous: current)
        try f.publish(peer)
        #expect(throws: CollaborationError.self) {
          try cold.redoNativeAction(accepted[1].receipt.id, actionID: UUID(), actor: f.actor)
        }
        #expect(try f.placement(id) == peer, "An identical peer move cannot impersonate the preceding Redo")
        return
      }
    }
    #expect(try cold.nativeRedoHistory(domain: domain, actor: f.actor).isEmpty)
    #expect(try cold.nativeHistory(domain: domain, actor: f.actor).count == 3)
  }

  @Test(arguments: [false, true])
  func redoRejectsPeerABAAndAnInvisibleConcurrentHead(concurrent: Bool) throws {
    let f = try Fixture(); defer { f.clean() }
    let id = f.items[0], before = try f.placement(id), peer = UUID()
    let moved = try f.command([f.move(id, to: .init(x: 150, y: 90))], ids: [id]).apply(to: f.store)
    _ = try f.store.undoNativeAction(moved.receipt.id, actor: f.actor)
    let inverse = try f.placement(id)
    if concurrent {
      let other = try WorkspacePlacement.authored(itemID: id, pose: before.pose,
        stamp: .init(counter: before.stamp.counter + 1, actor: peer), human: false, previous: before)
      let joined = try inverse.merging(other)
      #expect(joined.pose == inverse.pose && joined.winner.version == inverse.winner.version)
      #expect(joined.heads.count == 2)
      try f.publish(joined)
    } else {
      let changed = try WorkspacePlacement.authored(itemID: id, pose: .init(center: .zero, zIndex: 55),
        stamp: .init(counter: inverse.stamp.counter + 1, actor: peer), human: true, previous: inverse)
      let returned = try WorkspacePlacement.authored(itemID: id, pose: inverse.pose,
        stamp: .init(counter: changed.stamp.counter + 1, actor: peer), human: true, previous: changed)
      try f.publish(returned)
    }
    let current = try f.placement(id)
    #expect(throws: CollaborationError.self) {
      try NotebookStore(root: f.root).redoNativeAction(moved.receipt.id, actionID: UUID(), actor: f.actor)
    }
    #expect(try f.placement(id) == current)
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func oneRetryOwnerRetainsTheActualPlacementCutAndAtomicHistory(_ fault: NotebookStorageFault) throws {
    let f = try Fixture(); defer { f.clean() }
    let id = f.items[0], actionID = UUID(), domain = PencilUndoHistory.Domain.board(f.boardID)
    let command = try f.command([f.move(id, to: .init(x: 400, y: 500))], ids: [id], actionID: actionID)
    let failing = NotebookStore(root: f.root) { point in
      if String(describing: point) == String(describing: fault) { throw Fault.disk }
    }
    #expect(throws: Fault.self) { try command.apply(to: failing) }
    let committed: Bool
    if case .afterCommit = fault { committed = true } else { committed = false }
    #expect(try f.store.nativeHistory(domain: domain, actor: f.actor) == (committed ? [.command(actionID)] : []))
    let accepted = try f.placement(id)
    if committed {
      _ = try f.command([f.move(id, to: .init(x: 950, y: 850))], ids: [id], actor: UUID()).apply(to: f.store)
    }
    let cursor = try f.store.currentChangeCursor(), result = try command.apply(to: NotebookStore(root: f.root))
    #expect(try f.store.currentChangeCursor() == cursor + (committed ? 0 : 1))
    #expect(try f.store.nativeHistory(domain: domain, actor: f.actor) == [.command(actionID)])
    #expect(result.sources[0].pose?.center == .init(x: 400, y: 500))
    if committed {
      #expect(result.sources == [accepted], "A lost reply cannot substitute a peer's newer position")
      let stale = try NotebookNativeCommand([f.move(id, to: .zero)], summary: "Dependent move",
        placements: result.sources, actor: f.actor)
      #expect(throws: CollaborationError.self) { try stale.apply(to: f.store) }
      #expect(try f.placement(id).pose?.center == .init(x: 950, y: 850))
    }
  }
}
