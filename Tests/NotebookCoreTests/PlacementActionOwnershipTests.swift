import Foundation
import Testing
@testable import NotebookCore

private struct PlacementActionFixture {
  let root: URL
  let store: NotebookStore
  let human = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  let agent = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
  let itemID: UUID
  let boardID: UUID

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-placement-action-" + UUID().uuidString)
    store = NotebookStore(root: root)
    let (index, _) = try store.loadOrCreate(actor: human, pageSize: .init(width: 834, height: 1194))
    itemID = index.selectedItemID; boardID = index.rootBoardID
    _ = try store.loadOrCreateSpatialInk(actor: human)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  var board: CollaborationTarget { .init(kind: .board, id: boardID) }
  var placementPath: [CollaborationPathComponent] {
    [.field("boards"), .member(boardID.uuidString.lowercased()), .field("board"),
      .field("placements"), .member(itemID.uuidString.lowercased())]
  }
  func tree() throws -> BoardHierarchy { try store.loadBoard(items: store.loadIndex().items) }
  func placement() throws -> WorkspacePlacement {
    try #require(try store.readBoardNode(boardID)?.board.placements.first { $0.id == itemID })
  }
  func move(to center: WorldPoint) throws -> CollaborationReceipt {
    let action = CollaborationAction(additionalOwners: [.init(kind: .cover, id: itemID, boardID: boardID)],
      summary: "Переместить выбранную тетрадь", expected: [
        .init(target: board, revision: try store.targetContentRevision(target: board))
      ], operations: [.init(kind: .moveItem, target: board, id: itemID.uuidString, values: ["center": try .encode(center)])])
    return try store.applyCollaborationAction(action, actor: agent)
  }
}

@Test("Отмена принятого движения создаёт новый причинный head, а старое эхо не возвращает объект")
func placementActionUndoAuthorsInverseIntent() throws {
  let f = try PlacementActionFixture(); defer { f.clean() }
  let before = try f.placement()
  let receipt = try f.move(to: .init(x: 600, y: 700))
  let accepted = try f.placement(), acceptedTree = try f.tree()
  #expect(accepted.winner.version.human == false)
  #expect(receipt.changes.count == 1)
  #expect(receipt.changes[0].path == f.placementPath)
  #expect(receipt.changes[0].afterVersion == accepted.winner.version)
  let undone = try f.store.undoCollaborationAction(receipt.id, actor: f.human)
  let inverse = try f.placement()
  #expect(undone.undo?.restored == 1)
  #expect(undone.undo?.preserved.isEmpty == true)
  #expect(inverse.pose == before.pose)
  #expect(inverse.heads.count == 1)
  #expect(inverse.stamp.counter > accepted.stamp.counter)
  #expect(inverse.winner.version.human)
  #expect(inverse.winner.version.observed[f.agent.uuidString.lowercased()] == accepted.stamp.counter)
  let merged = try f.tree().merging(acceptedTree, items: f.store.loadIndex().items)
  #expect(merged.board(f.boardID)?.placements.first { $0.id == f.itemID } == inverse)
  #expect(try f.store.undoCollaborationAction(receipt.id, actor: f.human) == undone)
  #expect(try f.placement() == inverse)
}

@Test("Отмена не стирает проигравший параллельный head даже при неизменном видимом победителе")
func placementActionUndoPreservesConcurrentIntent() throws {
  let f = try PlacementActionFixture(); defer { f.clean() }
  let before = try f.tree()
  let receipt = try f.move(to: .init(x: 600, y: 700))
  let accepted = try f.placement(), acceptedTree = try f.tree()
  let other = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
  var concurrentBoard = try #require(before.board(f.boardID))
  let moved = concurrentBoard.moveItem(f.itemID, to: .init(x: 90, y: 80), actor: other)
  #expect(moved)
  concurrentBoard.recordPlacementPreference(from: try #require(before.board(f.boardID)), human: false)
  let concurrent = try #require(concurrentBoard.placements.first { $0.id == f.itemID })
  let joined = try accepted.merging(concurrent)
  #expect(joined.heads.count == 2)
  #expect(joined.pose == accepted.pose)
  var files = try JSONValue.encode(acceptedTree)
  files = try #require(files.setting(at: f.placementPath[...], to: .encode(joined)))
  let currentTree = try files.decode(BoardHierarchy.self)
  _ = try f.store.saveBoardEdits(before: acceptedTree, after: currentTree)
  let undone = try f.store.undoCollaborationAction(receipt.id, actor: f.human)
  #expect(undone.undo?.restored == 0)
  #expect(undone.undo?.preserved.map(\.path) == [f.placementPath])
  #expect(try f.placement() == joined)
}

@Test("Движение туда и обратно сохраняет новое человеческое владение, независимо от совпадения координат")
func placementActionUndoPreservesHumanReturn() throws {
  let f = try PlacementActionFixture(); defer { f.clean() }
  let center = WorldPoint(x: 600, y: 700)
  let receipt = try f.move(to: center)
  let before = try f.tree()
  var after = before
  let moved = after.moveItem(f.itemID, in: f.boardID, to: .init(x: -400, y: 300), actor: f.human)
  let returned = after.moveItem(f.itemID, in: f.boardID, to: center, actor: f.human)
  #expect(moved && returned)
  _ = try f.store.saveBoardEdits(before: before, after: after)
  let human = try f.placement()
  #expect(human.winner.version.human)
  let undone = try f.store.undoCollaborationAction(receipt.id, actor: f.human)
  #expect(undone.undo?.restored == 0)
  #expect(undone.undo?.preserved.count == 1)
  #expect(try f.placement() == human)
}

@Test("Точный одиночный ход прежнего формата отменяется новым владельцем без изменения квитанции", arguments: [false, true])
func placementActionUndoConvertsProvenHistoricalMove(laterHumanMove: Bool) throws {
  let f = try PlacementActionFixture(); defer { f.clean() }
  let prior = try #require(try f.placement().pose)
  var receipt = try f.move(to: .init(x: 600, y: 700))
  let accepted = try f.placement(), pose = try #require(accepted.pose)
  let legacyPath: [CollaborationPathComponent] = [.field("boards"), .member(f.boardID.uuidString.lowercased()),
    .field("board"), .field("freeItems"), .member(f.itemID.uuidString.lowercased())]
  receipt.changes = [
    .init(file: "board.json", path: legacyPath + [.field("center")], before: try .encode(prior.center), after: try .encode(pose.center), afterVersion: accepted.winner.version),
    .init(file: "board.json", path: legacyPath + [.field("zIndex")], before: .number(Double(prior.zIndex)), after: .number(Double(pose.zIndex)), afterVersion: .init(stamp: accepted.stamp, human: false))
  ]
  // The explicit migration seeds exactly the old body's dot, not its joined
  // field observations. Reproduce that admitted state without a legacy reader.
  let seeded = try WorkspacePlacement.authored(itemID: f.itemID, pose: pose,
    stamp: accepted.stamp, human: false, previous: nil)
  try f.store.commandTransaction {
    let db = f.store.currentSQL!
    let address = "board.json#/boards/@" + f.boardID.uuidString.lowercased()
      + "/board/placements/@" + f.itemID.uuidString.lowercased()
    let row = try #require(try f.store.storedFragments(address: address, descendants: false).first)
    let previous = try #require(try db.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text)
    let replacement = row.replacing(value: try .encode(seeded))
    let hash = try db.putBlob(NotebookStore.storageEncoder.encode(replacement))
    // This fixture changes only the seeded clock. The live geometry/index
    // already describes the same pose and must not be deleted with its row.
    try db.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
    try f.store.updateBoardContribution(address: address, previous: previous, next: hash, database: db)
  }
  try f.store.fixtureWrite(JSONEncoder().encode(receipt), to: f.store.collaborationActionsURL.appendingPathComponent(receipt.id.uuidString.lowercased() + ".json"))
  if laterHumanMove {
    let before = try f.tree(); var after = before
    let moved = after.moveItem(f.itemID, in: f.boardID, to: pose.center, actor: f.human)
    #expect(moved)
    _ = try f.store.saveBoardEdits(before: before, after: after)
  }
  let current = try f.placement()
  if !laterHumanMove {
    #expect(current == seeded)
    let projected = try f.store.readTransaction { _ in
      try f.store.actionSourceProjection(receipt.action, receipt: receipt).hierarchy.board(f.boardID)?.placements.first { $0.id == f.itemID }
    }
    #expect(projected == current)
    #expect(current.winner.version.observed == [f.agent.uuidString.lowercased(): accepted.stamp.counter])
    let value = try JSONValue.encode(pose)
    for change in receipt.changes { #expect(value.value(at: change.path.dropFirst(5)) == change.after) }
  }
  let undone = try f.store.undoCollaborationAction(receipt.id, actor: f.human)
  #expect(undone.action == receipt.action)
  #expect(undone.changes == receipt.changes)
  if laterHumanMove {
    #expect(undone.undo?.restored == 0)
    #expect(undone.undo?.preserved == receipt.changes)
    #expect(try f.placement() == current)
  } else {
    #expect(undone.undo?.restored == 2)
    #expect(undone.undo?.preserved.isEmpty == true)
    let inverse = try f.placement()
    #expect(inverse.pose == prior)
    #expect(inverse.stamp.counter > current.stamp.counter)
    #expect(inverse.winner.version.observed[f.agent.uuidString.lowercased()] == current.stamp.counter)
  }
}

@Test("Историческая квитанция прежнего владельца не меняется и явно отказывает в небезопасной отмене")
func placementActionUndoRespectsMigrationBoundary() throws {
  let f = try PlacementActionFixture(); defer { f.clean() }
  var receipt = try f.move(to: .init(x: 600, y: 700))
  let accepted = try f.placement()
  receipt.changes = [.init(file: "board.json", path: [
    .field("boards"), .member(f.boardID.uuidString), .field("board"), .field("freeItems"), .member(f.itemID.uuidString)
  ], before: try .encode(FreeItemPlacement(itemID: f.itemID, center: .zero, zIndex: 0, stamp: accepted.stamp)),
    after: try .encode(FreeItemPlacement(itemID: f.itemID, center: .init(x: 600, y: 700), zIndex: 1, stamp: accepted.stamp)))]
  try f.store.fixtureWrite(JSONEncoder().encode(receipt), to: f.store.collaborationActionsURL.appendingPathComponent(receipt.id.uuidString.lowercased() + ".json"))
  let before = try f.store.collaborationSnapshot()
  do {
    _ = try f.store.undoCollaborationAction(receipt.id, actor: f.human)
    Issue.record("Необходим явный отказ на границе формата расположений")
  } catch let error as CollaborationError { #expect(error.code == "placement_migration_boundary") }
  #expect(try f.store.collaborationAction(receipt.id) == receipt)
  #expect(try f.store.collaborationSnapshot() == before)
  #expect(try f.placement() == accepted)
}
