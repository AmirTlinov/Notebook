import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle inverses preserve full placement undo provenance", .serialized)
struct NotebookLifecyclePlacementChainTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    let agent = UUID(), human = UUID()
    let boardID: UUID
    var board: CollaborationTarget { .init(kind: .board, id: boardID) }

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      boardID = try content.store.workspaceHeader().rootBoardID
    }

    func cover(_ id: UUID) -> CollaborationTarget { .init(kind: .cover, id: id, boardID: boardID) }

    func create(_ kind: CollaborationOperation.Kind) throws -> (UUID, CollaborationReceipt) {
      let id = UUID()
      var values: [String: JSONValue] = ["center": try .encode(WorldPoint(x: 1600, y: 900))]
      if kind == .createNotebook { values["pageID"] = try .encode(UUID()) }
      if kind == .createDocument {
        values["paperSize"] = .string("a4")
        values["blocks"] = try .encode([DocumentBlock.markdown(id: "body", source: "Unadopted document")])
      }
      let basis = try store.readBasis(targets: [board, .init(kind: .workspace, id: boardID)])
      let receipt = try store.applyCollaborationAction(.init(summary: "Create the original item lifetime", expected: basis.owners,
        operations: [.init(kind: kind, target: board, id: id.uuidString, values: values)]), actor: agent)
      return (id, receipt)
    }

    func move(_ id: UUID, to center: WorldPoint) throws -> CollaborationReceipt {
      let basis = try store.readBasis(targets: [board])
      return try store.applyCollaborationAction(.init(additionalOwners: [cover(id)], summary: "Earlier move",
        expected: basis.owners, operations: [.init(kind: .moveItem, target: board, id: id.uuidString,
          values: ["center": try .encode(center)])]), actor: agent)
    }

    func delete(_ id: UUID) throws -> CollaborationReceipt {
      var read = NotebookCommand(command: .read); read.readSnapshots = true
      read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(id)]).decode(NotebookReadQuery.self)]
      let basis = try #require(try NotebookCommandDispatcher(store: store).handle(read).array.first?["basis"]?.decode(NotebookReadBasis.self))
      let operation = CollaborationOperation(kind: .deleteItem, target: cover(id))
      return try store.applyCollaborationAction(.init(additionalOwners: [cover(id)], summary: "Later deletion",
        expected: store.expectations(base: basis, operations: [operation]), operations: [operation]), actor: agent)
    }

    func placement(_ id: UUID, on source: NotebookStore? = nil) throws -> WorkspacePlacement {
      try #require(try (source ?? store).readBoardNode(boardID)?.board.placements.first { $0.itemID == id })
    }

    func reopened(freshPeer: Bool) throws -> NotebookStore {
      guard freshPeer else { return NotebookStore(root: store.root) }
      let peer = NotebookStore(root: store.root.appendingPathComponent("fresh-peer")), peerID = UUID()
      try peer.prepareEmptyWorkspace(workspaceID: store.workspaceHeader().workspaceID)
      // The fresh replica receives only admitted manifests/receipt dependencies;
      // it did not run the original inverse and has no in-memory provenance.
      for change in try store.changeJournal(after: 0) {
        var delivered = false
        for _ in 0..<64 {
          let missing = try peer.missingBlobHashes(for: change)
          if missing.isEmpty {
            let accepted = try peer.applyRemoteChange(change, peerID: peerID)
            #expect(accepted == change.sequence); delivered = true; break
          }
          for hash in missing {
            let count = try store.blobSize(hash: hash)
            var data = Data()
            while Int64(data.count) < count {
              data += try store.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
            }
            try peer.stageBlob(data: data, expectedHash: hash)
          }
        }
        #expect(delivered)
        if !delivered { throw NotebookStorageError.invalidTransaction("placement chain fixture dependencies") }
      }
      return NotebookStore(root: peer.root)
    }
  }

  @Test(arguments: ["reopen", "fresh-peer", "migration", "two-cycles"])
  func undoingDeletionDoesNotMakeAnEarlierMoveLookLikeHumanAdoption(mode: String) throws {
    let f = try Fixture(), (id, _) = try f.create(.createNotebook)
    let original = try f.placement(id)
    let move = try f.move(id, to: .init(x: 4600, y: -1700)), moved = try f.placement(id)
    let deletion = try f.delete(id)
    _ = try f.store.undoCollaborationAction(deletion.id, actor: f.human)
    if mode == "two-cycles" {
      let secondDeletion = try f.delete(id)
      _ = try f.store.undoCollaborationAction(secondDeletion.id, actor: UUID())
    }
    let restored = try f.placement(id)
    #expect(restored.pose == moved.pose && restored.heads != moved.heads,
      "The lifecycle inverse authors a new causal register, not the old move dot")
    let reopened: NotebookStore
    if mode == "migration" {
      let readCursor = try f.store.currentReadCursor(), changeCursor = try f.store.currentChangeCursor()
      let files = [move.id, deletion.id].map { "collaboration/actions/" + $0.uuidString.lowercased() + ".json" }
      func receiptHashes(_ source: NotebookStore) throws -> [[String]] {
        try source.sqlRead { database in
          try database.rows("SELECT address,hash FROM records WHERE file IN (?,?) ORDER BY address", files.map(NotebookSQLValue.text))
            .map { [$0[0].text!, $0[1].text!] }
        }
      }
      let rawReceipts = try receiptHashes(f.store)
      try f.store.commandTransaction(advancesReadRevision: false) {
        try f.store.currentSQL!.run("DELETE FROM action_field_restorations WHERE field LIKE 'placement:%'")
        try f.store.currentSQL!.run("PRAGMA user_version=10")
      }
      reopened = NotebookStore(root: f.store.root)
      try reopened.prepare()
      #expect(try reopened.currentReadCursor() == readCursor)
      #expect(try reopened.currentChangeCursor() == changeCursor)
      #expect(try receiptHashes(reopened) == rawReceipts,
        "Migration may rebuild disposable proof rows, never rewrite either immutable receipt")
      let schema = try reopened.sqlRead { try $0.rows("PRAGMA user_version").first?[0].integer }
      #expect(schema == NotebookStore.currentDatabaseVersion)
      let proofs = try reopened.sqlRead { try $0.rows("SELECT COUNT(*) FROM action_field_restorations WHERE field LIKE 'placement:%'").first?[0].integer ?? 0 }
      #expect(proofs > 0, "Existing v10 receipts must rebuild their authenticated full-placement proof during admission")
    } else { reopened = try f.reopened(freshPeer: mode == "fresh-peer") }
    let undone = try reopened.undoCollaborationAction(move.id, actor: UUID())
    #expect(undone.undo?.preserved.isEmpty == true)
    #expect(undone.undo?.restored == 1)
    #expect(try f.placement(id, on: reopened).pose == original.pose,
      "A receipt-backed inverse must restore the earlier action's full placement ownership")
  }

  @Test(arguments: [CollaborationOperation.Kind.createNotebook, .createDocument, .createBoard])
  func undoingDeletionDoesNotAdoptAnOtherwiseUntouchedEarlierCreation(kind: CollaborationOperation.Kind) throws {
    let f = try Fixture(), (id, creation) = try f.create(kind), deletion = try f.delete(id)
    _ = try f.store.undoCollaborationAction(deletion.id, actor: f.human)
    #expect(try f.store.readItemHeader(id) != nil)
    let reopened = try f.reopened(freshPeer: false)
    let undone = try reopened.undoCollaborationAction(creation.id, actor: UUID())
    #expect(undone.undo?.preserved.isEmpty == true)
    #expect((undone.undo?.restored ?? 0) > 0)
    #expect(try reopened.readItemHeader(id) == nil)
    #expect(try reopened.ownerBoardID(of: id) == nil)
    if kind == .createBoard { #expect(try reopened.readBoardNode(id) == nil) }
    #expect(try reopened.readItemHeader(f.content.itemID) != nil)
  }

  @Test(arguments: [false, true])
  func anIndependentHumanReturnOrLosingConcurrentHeadAfterRestorationStillProtectsPlacement(losingHead: Bool) throws {
    let f = try Fixture(), (id, _) = try f.create(.createNotebook)
    let move = try f.move(id, to: .init(x: 4600, y: -1700)), deletion = try f.delete(id)
    _ = try f.store.undoCollaborationAction(deletion.id, actor: f.human)
    let restored = try f.placement(id), before = try f.store.loadBoard(items: f.store.loadIndex().items)
    let after: BoardHierarchy
    if losingHead {
      let pose = try #require(restored.pose)
      let concurrent = try WorkspacePlacement.authored(itemID: id,
        pose: .init(center: .init(x: -300, y: 700), zIndex: pose.zIndex),
        stamp: .init(counter: 1, actor: UUID()), human: false, previous: nil)
      let joined = try restored.merging(concurrent)
      #expect(joined.heads.count == 2 && joined.pose == restored.pose)
      let path: [CollaborationPathComponent] = [.field("boards"), .member(f.boardID.uuidString.lowercased()),
        .field("board"), .field("placements"), .member(id.uuidString.lowercased())]
      let value = try #require(try JSONValue.encode(before).setting(at: path[...], to: .encode(joined)))
      after = try value.decode(BoardHierarchy.self)
    } else {
      let pose = try #require(restored.pose)
      var edited = before
      let moved = edited.restorePlacement(itemID: id, on: f.boardID,
        pose: .init(center: .init(x: -300, y: 700), zIndex: pose.zIndex), actor: UUID())
      let returned = edited.restorePlacement(itemID: id, on: f.boardID, pose: pose, actor: UUID())
      #expect(moved && returned)
      // The complete visible pose returns to A, but these are independent
      // human publications with no receipt attesting an inverse of deletion.
      after = edited
    }
    _ = try f.store.saveBoardEdits(before: before, after: after)
    let adopted = try f.placement(id)
    #expect(adopted.pose == restored.pose && adopted.heads != restored.heads)
    let reopened = try f.reopened(freshPeer: false)
    let undone = try reopened.undoCollaborationAction(move.id, actor: UUID())
    #expect(undone.undo?.restored == 0 && undone.undo?.preserved.count == 1)
    #expect(try f.placement(id, on: reopened) == adopted,
      "Neither a matching winner nor receipt ancestry may erase a later independent head")
  }
}
