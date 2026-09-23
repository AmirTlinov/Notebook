import Foundation
import Testing
@testable import NotebookCore

@Suite("Native deletion shares lifecycle and board history", .serialized)
struct NotebookNativeDeletionTests {
  private enum Fault: Error { case disk }
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    var actor: UUID { content.actor }
    var id: UUID { content.itemID }
    let board: CollaborationTarget
    var domain: PencilUndoHistory.Domain { .board(board.id) }

    init() throws {
      content = try .init()
      board = .init(kind: .board, id: try content.store.workspaceHeader().rootBoardID)
      let base = try store.readBasis(targets: [board, .init(kind: .workspace, id: board.id)])
      _ = try store.applyCollaborationAction(.init(summary: "Retained neighbor", expected: base.owners,
        operations: [.init(kind: .createNotebook, target: board, id: UUID().uuidString,
          values: ["center": try .encode(WorldPoint(x: 1600, y: 0)), "pageID": try .encode(UUID())])]), actor: actor)
      try content.write(content.pageID, text: "Original invisible material")
    }

    func deletion() throws -> CollaborationReceipt {
      let extent = try #require(try store.readItemLifecycle(id))
      let operation = CollaborationOperation(kind: .deleteItem, target: extent.target)
      let expected = try operation.requiredOwners(workspaceRootID: board.id).map { target in
        CollaborationExpectation(target: target, revision: try store.targetContentRevision(target: target),
          lifecycleRevision: target == extent.target ? extent.revision : nil)
      }
      return try store.applyNativeAction(.init(additionalOwners: [extent.target], summary: "Delete notebook",
        expected: expected, operations: [operation]), actor: actor)
    }

    func command(actionID: UUID = UUID()) throws -> NotebookNativeCommand<NotebookItemLifecycle> {
      try .init(deleting: #require(try store.readItemLifecycle(id)), placement: placement(), actionID: actionID, actor: actor)
    }
    func placement() throws -> WorkspacePlacement {
      try #require(try store.readBoardItem(id)?.board.placements.first { $0.id == id })
    }
    func move(to center: WorldPoint, actor author: UUID? = nil) throws -> CollaborationReceipt {
      try NotebookNativeCommand([.init(kind: .moveItem, target: board, id: id.uuidString,
        values: ["center": .encode(center)])], summary: "Move before deletion",
        placements: [placement()], actor: author ?? actor).apply(to: store).receipt
    }
  }

  @Test func deletedItemIsUndoableFromTheSurvivingBoardAndColdRedoUsesTheSameLifecycleOwner() throws {
    let f = try Fixture(), before = try f.store.loadPage(f.content.pageID)
    let deleted = try f.deletion()
    #expect(try f.store.readItemHeader(f.id) == nil)
    #expect(try f.store.nativeHistory(domain: f.domain, actor: f.actor) == [.command(deleted.id)])
    #expect(try f.store.nativeHistory(domain: .cover(f.id), actor: f.actor).isEmpty)
    var action = deleted
    for _ in 0..<3 {
      let cold = NotebookStore(root: f.store.root)
      let inverse = try cold.undoNativeAction(action.id, actor: f.actor)
      #expect(inverse.undo?.lifecycleChanges?.first?.kind == .restoreItem)
      #expect(try cold.loadPage(f.content.pageID) == before)
      #expect(try cold.nativeRedoHistory(domain: f.domain, actor: f.actor) == [.command(action.id)])
      let repeated = try cold.redoNativeAction(action.id, actionID: UUID(), actor: f.actor)
      #expect(repeated.redoOf == action.id)
      #expect(try cold.readItemHeader(f.id) == nil)
      #expect(try cold.nativeHistory(domain: f.domain, actor: f.actor) == [.command(repeated.id)])
      #expect(try cold.nativeRedoHistory(domain: f.domain, actor: f.actor).isEmpty)
      let cursor = try cold.currentChangeCursor()
      #expect(try cold.redoNativeAction(action.id, actionID: repeated.id, actor: f.actor) == repeated)
      #expect(try cold.currentChangeCursor() == cursor)
      action = repeated
    }
  }

  @Test func anInvisiblePeerEditAfterUndoPreventsRedoEvenIfItReturnsTheSameMaterial() throws {
    let f = try Fixture(), action = try f.deletion()
    _ = try f.store.undoNativeAction(action.id, actor: f.actor)
    try f.content.write(f.content.pageID, text: "Changed by another contact")
    try f.content.write(f.content.pageID, text: "Original invisible material")
    let current = try f.store.loadPage(f.content.pageID), cursor = try f.store.currentChangeCursor()
    #expect(throws: CollaborationError.self) {
      try NotebookStore(root: f.store.root).redoNativeAction(action.id, actionID: UUID(), actor: f.actor)
    }
    #expect(try f.store.loadPage(f.content.pageID) == current)
    #expect(try f.store.readItemHeader(f.id) != nil)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test(arguments: [false, true], [0, 2])
  func moveDeleteAndRepeatedColdHistoryDistinguishOwnRedoFromPeerABA(peer: Bool, repetitions: Int) throws {
    let f = try Fixture(), initial = try f.placement(), moved = try f.move(to: .init(x: 730, y: 40))
    var deletion = try f.command().apply(to: f.store).receipt
    for _ in 0..<repetitions {
      _ = try f.store.undoNativeAction(deletion.id, actor: f.actor)
      deletion = try NotebookStore(root: f.store.root).redoNativeAction(deletion.id, actionID: UUID(), actor: f.actor)
    }
    _ = try f.store.undoNativeAction(deletion.id, actor: f.actor)
    _ = try f.store.undoNativeAction(moved.id, actor: f.actor)
    #expect(try f.placement().pose == initial.pose)
    let cold = NotebookStore(root: f.store.root)
    _ = try cold.redoNativeAction(moved.id, actionID: UUID(), actor: f.actor)
    if peer {
      _ = try f.move(to: .zero, actor: UUID())
      _ = try f.move(to: .init(x: 730, y: 40), actor: UUID())
      #expect(throws: CollaborationError.self) { try cold.redoNativeAction(deletion.id, actionID: UUID(), actor: f.actor) }
      #expect(try cold.readItemHeader(f.id) != nil)
    } else {
      _ = try cold.redoNativeAction(deletion.id, actionID: UUID(), actor: f.actor)
      #expect(try cold.readItemHeader(f.id) == nil)
      #expect(try cold.nativeHistory(domain: f.domain, actor: f.actor).count == 2)
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit], [false, true])
  func retainedDeletionRetriesItsOwnExtentAndNeverDeletesASecondLifetime(_ fault: NotebookStorageFault, edited: Bool) throws {
    let f = try Fixture(), id = UUID(), command = try f.command(actionID: id)
    let failing = NotebookStore(root: f.store.root) { point in
      if String(describing: point) == String(describing: fault) { throw Fault.disk }
    }
    #expect(throws: Fault.self) { try command.apply(to: failing) }
    let committed: Bool
    if case .afterCommit = fault { committed = true } else { committed = false }
    #expect(try f.store.nativeHistory(domain: f.domain, actor: f.actor) == (committed ? [.command(id)] : []))
    if edited {
      if committed { _ = try f.store.undoNativeAction(id, actor: f.actor) }
      try f.content.write(f.content.pageID, text: "A later contribution")
    }
    let cursor = try f.store.currentChangeCursor()
    if edited && !committed {
      #expect(throws: CollaborationError.self) { try command.apply(to: f.store) }
      #expect(try f.store.currentChangeCursor() == cursor)
    } else {
      let repeated = try command.apply(to: NotebookStore(root: f.store.root))
      #expect(repeated.receipt.id == id)
      #expect(try f.store.currentChangeCursor() == cursor + (committed ? 0 : 1))
    }
    #expect((try f.store.readItemHeader(f.id) != nil) == edited)
  }
}
