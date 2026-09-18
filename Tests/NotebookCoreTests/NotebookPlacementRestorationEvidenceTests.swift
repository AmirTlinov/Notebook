import Foundation
import Testing
@testable import NotebookCore

@Suite("Placement restoration evidence admits complete native registers", .serialized)
struct NotebookPlacementRestorationEvidenceTests {
  enum Corruption: String, CaseIterable, Sendable {
    case reusedDot, extraKey, noncanonicalPosition
  }

  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    let target: CollaborationTarget
    var store: NotebookStore { content.store }
    var placementAddress: String {
      "board.json#/boards/@" + target.boardID!.uuidString.lowercased()
        + "/board/placements/@" + target.id.uuidString.lowercased()
    }

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      let header = try content.store.workspaceHeader()
      let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
      target = .init(kind: .cover, id: content.itemID, boardID: header.rootBoardID)
      let basis = try content.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
      _ = try content.store.applyCollaborationAction(.init(summary: "Keep a live neighbor", expected: basis.owners, operations: [
        .init(kind: .createNotebook, target: board, id: UUID().uuidString,
          values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
      ]), actor: content.actor)
    }

    func restoredReceipt() throws -> CollaborationReceipt {
      let query = try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(target.id)])
        .decode(NotebookReadQuery.self)
      var command = NotebookCommand(command: .read)
      command.queries = [query]; command.readSnapshots = true
      let result = try #require(try NotebookCommandDispatcher(store: store).handle(command).array.first)
      let basis = try #require(try result["basis"]?.decode(NotebookReadBasis.self))
      let operations = [CollaborationOperation(kind: .deleteItem, target: target)]
      let expected = try store.expectations(base: basis, operations: operations)
      let deleted = try store.applyCollaborationAction(.init(additionalOwners: [target],
        summary: "Delete before restoration proof", expected: expected, operations: operations), actor: content.actor)
      return try store.undoCollaborationAction(deleted.id, actor: UUID())
    }

    /// Keep the real public action's scope and all other inverse records. Only
    /// the selected placement evidence is changed, using the actual closed
    /// capture builder rather than constructing an alternate manifest format.
    func corrupt(_ receipt: CollaborationReceipt, as kind: Corruption) throws -> CollaborationReceipt {
      try store.commandTransaction {
        let db = store.currentSQL!, original = try #require(receipt.lifecycleInverse)
        let restoration = try #require(receipt.undo?.restorationInverse)
        var selected: NotebookActionRecordChange?
        try store.visitLifecycleInverse(reference: restoration, actionID: receipt.id) { change in
          if change.address == placementAddress { selected = change }
        }
        let change = try #require(selected), after = try #require(change.afterHash)
        let writtenRow = try store.readLifecycleInverseFragment(hash: after, address: placementAddress)
        let written = try writtenRow.value.decode(WorkspacePlacement.self)
        #expect(written.heads.count == 1 && written.heads[0].version.human)
        var tombstoneHash: String?, writtenHash = after
        switch kind {
        case .reusedDot:
          // Each register is valid on its own, but a single authored dot cannot
          // mean both the human's restored pose and a deletion tombstone.
          let tombstone = WorkspacePlacement(itemID: target.id,
            heads: [.init(pose: nil, version: written.heads[0].version)])
          try tombstone.validate()
          #expect(written.hasObserved(tombstone), "Observation alone does not authenticate a dot's payload")
          #expect(throws: NotebookStorageError.self) { _ = try written.merging(tombstone) }
          tombstoneHash = try db.putBlob(NotebookStore.storageEncoder.encode(
            writtenRow.replacing(value: .encode(tombstone))))
        case .extraKey:
          let row = writtenRow.replacing(value: writtenRow.value.setting("unownedPose", .string("ignored by Codable")))
          #expect(try row.value.decode(WorkspacePlacement.self) == written)
          writtenHash = try db.putBlob(NotebookStore.storageEncoder.encode(row))
        case .noncanonicalPosition:
          #expect(writtenRow.position == 0)
          writtenHash = try db.putBlob(NotebookStore.storageEncoder.encode(
            writtenRow.replacing(value: writtenRow.value, position: 1)))
        }

        func rebuild(_ reference: NotebookLifecycleInverseReference, isUndo: Bool) throws -> NotebookLifecycleInverseReference {
          let captureID = UUID()
          try db.withActionRecordCapture(actionID: captureID) {
            try store.visitLifecycleInverse(reference: reference, actionID: receipt.id) { old in
              var before = old.beforeHash, after = old.afterHash
              if old.address == placementAddress {
                if isUndo { before = tombstoneHash ?? before; after = writtenHash }
                else if let tombstoneHash { after = tombstoneHash }
              }
              try db.recordActionRecordChange(address: old.address, beforeHash: before, afterHash: after)
            }
          }
          return try #require(try store.saveLifecycleInverse(actionID: receipt.id, captureID: captureID))
        }
        var result = receipt
        result.lifecycleInverse = try rebuild(original, isUndo: false)
        result.undo?.restorationInverse = try rebuild(restoration, isUndo: true)
        // Both streams are well-hashed, workspace/action-bound, and complete.
        // Only typed placement admission can reject these adversarial claims.
        try store.visitLifecycleInverse(reference: result.lifecycleInverse!, actionID: receipt.id) { _ in }
        try store.visitLifecycleInverse(reference: result.undo!.restorationInverse!, actionID: receipt.id) { _ in }
        return result
      }
    }

    func derivedProofs(_ receiptAddress: String) throws -> [String] {
      try store.readTransaction { store in
        try store.currentSQL!.rows("SELECT field,version,value FROM action_field_restorations WHERE address=? ORDER BY field",
          [.text(receiptAddress)]).map { $0[0].text! + "|" + $0[1].text! + "|" + $0[2].blob!.base64EncodedString() }
      }
    }
  }

  @Test(arguments: Corruption.allCases)
  func receiptPublicationRefusesInvalidPlacementProofAndRollsBack(_ corruption: Corruption) throws {
    let f = try Fixture(), accepted = try f.restoredReceipt()
    let forged = try f.corrupt(accepted, as: corruption)
    let file = "collaboration/actions/" + accepted.id.uuidString.lowercased() + ".json"
    let raw = try f.store.storedValue(file), proofs = try f.derivedProofs(file + "#")
    #expect(proofs.contains { $0.hasPrefix("placement:" + f.placementAddress + "|") })
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let placement = try f.store.storedFragments(address: f.placementAddress, descendants: false)

    // This is the real receipt writer: writeFragment -> indexActionReadModel
    // -> indexFieldRestorations. A refusal must unwind both the receipt and any
    // derived proof rows already replaced earlier in that transaction.
    #expect(throws: NotebookStorageError.self) {
      try f.store.publishCollaboration(writes: [file: .encode(forged)])
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.currentReadCursor() == readCursor)
    #expect(try f.store.storedValue(file) == raw)
    #expect(try f.derivedProofs(file + "#") == proofs)
    #expect(try f.store.storedFragments(address: f.placementAddress, descendants: false) == placement)
  }
}
