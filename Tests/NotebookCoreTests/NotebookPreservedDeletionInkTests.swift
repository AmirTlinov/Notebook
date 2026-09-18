import Foundation
import Testing
@testable import NotebookCore

@Suite("Preserved notebook deletion retains its cover ink", .serialized)
struct NotebookPreservedDeletionInkTests {
  @Test func foreignPlacementTombstonePreservesCoverStrokeDuringActualActionUndo() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), store = f.store
    let header = try store.workspaceHeader()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let cover = CollaborationTarget(kind: .cover, id: f.itemID, boardID: board.id)
    let neighborBasis = try store.readBasis(targets: [board, .init(kind: .workspace, id: board.id)])
    _ = try store.applyCollaborationAction(.init(summary: "Keep a live neighbor", expected: neighborBasis.owners,
      operations: [.init(kind: .createNotebook, target: board, id: UUID().uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])]), actor: f.actor)

    var read = NotebookCommand(command: .read)
    read.readSnapshots = true
    read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(f.itemID)])
      .decode(NotebookReadQuery.self)]
    let snapshot = try #require(try NotebookCommandDispatcher(store: store).handle(read).array.first)
    let basis = try #require(try snapshot["basis"]?.decode(NotebookReadBasis.self))
    let strokeID = UUID()
    let operations: [CollaborationOperation] = [
      .init(kind: .appendInkStroke, target: cover, id: strokeID.uuidString,
        values: ["points": .array([.object(["x": .number(20), "y": .number(20)]),
          .object(["x": .number(40), "y": .number(30)])])]),
      .init(kind: .deleteItem, target: cover)
    ]
    let expected = try store.expectations(base: basis, operations: operations)
    let receipt = try store.applyCollaborationAction(.init(additionalOwners: [cover],
      summary: "Draw on a cover then delete its notebook", expected: expected, operations: operations), actor: f.actor)
    #expect(try store.readItemHeader(f.itemID) == nil)

    // A human authors a new deletion dot with the same visible nil pose.
    // Whole-group preservation must include the hidden retained ink source.
    let beforeBoard = try store.loadBoard(items: store.loadIndex().items)
    var afterBoard = beforeBoard
    let authored = afterBoard.restorePlacement(itemID: f.itemID, on: board.id, pose: nil, actor: UUID())
    #expect(authored)
    _ = try store.saveBoardEdits(before: beforeBoard, after: afterBoard)
    let inkBefore = try store.loadSpatialInk()
    let strokeBefore = try #require(inkBefore.actions.first { $0.id == strokeID })
    #expect(strokeBefore.isActive)
    func rawInkHashes(_ target: NotebookStore) throws -> [[String]] {
      try target.readTransaction { reader in
        try reader.currentSQL!.rows("SELECT address,hash FROM records WHERE file='spatial-ink.json' ORDER BY address")
          .map { [$0[0].text!, $0[1].text!] }
      }
    }
    let rawBefore = try rawInkHashes(store)

    // Exercise the public whole-action undo, not the lifecycle helper alone.
    let reopened = NotebookStore(root: store.root)
    let undone = try reopened.undoCollaborationAction(receipt.id, actor: UUID())
    let undo = try #require(undone.undo)
    #expect(undo.preservedLifecycle == [cover])
    #expect(undo.lifecycleChanges?.isEmpty != false)
    #expect(try reopened.readItemHeader(f.itemID) == nil)
    #expect(try reopened.loadSpatialInk() == inkBefore,
      "A preserved deletion must not deactivate the action's hidden cover stroke")
    #expect(try rawInkHashes(reopened) == rawBefore,
      "Preserving the lifecycle group leaves every physical cover-ink source hash unchanged")
    #expect(undo.restorationInverse == nil)
  }
}
