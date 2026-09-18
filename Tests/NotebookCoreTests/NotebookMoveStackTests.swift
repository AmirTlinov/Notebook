import Foundation
import Testing
@testable import NotebookCore

@Suite("Public moveItem extracts one stack member through its native placement owner", .serialized)
struct NotebookMoveStackTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    let agent = UUID(), siblingID = UUID(), boardID: UUID
    var store: NotebookStore { content.store }
    var itemID: UUID { content.itemID }
    var board: CollaborationTarget { .init(kind: .board, id: boardID) }

    init() throws {
      content = try .init()
      boardID = try content.store.workspaceHeader().rootBoardID
      let basis = try store.readBasis(targets: [board, .init(kind: .workspace, id: boardID)])
      _ = try store.applyCollaborationAction(.init(summary: "A second physical stack member",
        expected: basis.owners, operations: [.init(kind: .createNotebook, target: board, id: siblingID.uuidString,
          values: ["center": try .encode(WorldPoint(x: 500, y: 200)), "pageID": try .encode(UUID())])]), actor: agent)
      let before = try tree()
      var after = before
      let stackID = after.createStack(moving: itemID, onto: siblingID, in: boardID, actor: content.actor)
      _ = try #require(stackID)
      _ = try store.saveBoardEdits(before: before, after: after)
      #expect(try tree().board(boardID)?.stack(containing: itemID)?.itemIDs.count == 2)
    }

    func tree() throws -> BoardHierarchy { try store.loadBoard(items: store.loadIndex().items) }
    func address(_ id: UUID) -> String {
      "board.json#/boards/@" + boardID.uuidString.lowercased() + "/board/placements/@" + id.uuidString.lowercased()
    }
    func placement(_ id: UUID) throws -> WorkspacePlacement {
      let row = try #require(try store.storedFragments(address: address(id), descendants: false).first)
      return try row.value.decode(WorkspacePlacement.self)
    }
    func hash(_ id: UUID) throws -> String {
      try store.readTransaction { _ in
        try #require(try store.currentSQL!.rows("SELECT hash FROM records WHERE address=?", [.text(address(id))]).first?[0].text)
      }
    }
    func action(center: WorldPoint) throws -> CollaborationAction {
      .init(additionalOwners: [.init(kind: .cover, id: itemID, boardID: boardID)],
        summary: "Extract this stack member", expected: try store.readBasis(targets: [board]).owners,
        operations: [.init(kind: .moveItem, target: board, id: itemID.uuidString,
          values: ["center": try .encode(center)])])
    }
  }

  @Test func moveItemExtractsAStackMemberAndUndoRestoresOnlyItsPlacement() throws {
    let f = try Fixture(), original = try f.placement(f.itemID), sibling = try f.placement(f.siblingID)
    let siblingHash = try f.hash(f.siblingID), center = WorldPoint(x: 1800, y: -600)
    let oldPose = try #require(original.pose), stackID = try #require(oldPose.stackID)
    let action = try f.action(center: center)
    let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
    let moved = try f.placement(f.itemID)
    #expect(moved.pose?.center == center)
    #expect(moved.pose?.stackID == nil)
    #expect(!moved.winner.version.human)
    #expect(try f.tree().board(f.boardID)?.placement(of: f.itemID)?.center == center)
    #expect(try f.placement(f.siblingID) == sibling)
    #expect(try f.hash(f.siblingID) == siblingHash)
    #expect(receipt.changes.count == 1)

    let appliedCursor = try f.store.currentChangeCursor()
    let retried = try f.store.applyCollaborationAction(action, actor: f.agent)
    #expect(retried == receipt)
    #expect(try f.store.currentChangeCursor() == appliedCursor)
    #expect(try f.placement(f.itemID) == moved)

    let undone = try f.store.undoCollaborationAction(action.id, actor: f.content.actor)
    let restored = try f.placement(f.itemID)
    #expect(undone.undo?.restored == 1)
    #expect(undone.undo?.preserved.isEmpty == true)
    #expect(restored.pose == oldPose)
    #expect(restored.stamp.counter > moved.stamp.counter)
    #expect(restored.winner.version.includes(moved.winner.version))
    #expect(try f.tree().board(f.boardID)?.stack(containing: f.itemID)?.id == stackID)
    #expect(try f.placement(f.siblingID) == sibling)
    #expect(try f.hash(f.siblingID) == siblingHash)

    let undoneCursor = try f.store.currentChangeCursor()
    let repeatedUndo = try f.store.undoCollaborationAction(action.id, actor: f.content.actor)
    #expect(repeatedUndo == undone)
    #expect(try f.store.currentChangeCursor() == undoneCursor)
    #expect(try f.placement(f.itemID) == restored)
  }

  @Test func staleStackBasisRefusesTheWholeActionWithoutPublishingAnyPlacement() throws {
    let f = try Fixture(), action = try f.action(center: .init(x: 1800, y: -600))
    let before = try f.tree()
    var changed = before
    let extracted = changed.unstackItem(f.siblingID, in: f.boardID, at: .init(x: 800, y: 900), actor: f.content.actor)
    #expect(extracted)
    _ = try f.store.saveBoardEdits(before: before, after: changed)
    let snapshot = try f.store.collaborationContent(), cursor = try f.store.currentChangeCursor()
    let itemHash = try f.hash(f.itemID), siblingHash = try f.hash(f.siblingID)
    do {
      _ = try f.store.applyCollaborationAction(action, actor: f.agent)
      Issue.record("A stale stack read must not authorize extraction")
    } catch let error as CollaborationError {
      #expect(error.code == "revision_conflict")
      #expect(error.target == f.board)
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.collaborationContent() == snapshot)
    #expect(try f.hash(f.itemID) == itemHash)
    #expect(try f.hash(f.siblingID) == siblingHash)
    #expect(try f.store.collaborationActionIfPresent(action.id) == nil)
  }
}
