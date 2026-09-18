import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle evidence remains the identity of its original action", .serialized)
struct NotebookLifecycleReceiptIdentityTests {
  private func appended() throws -> (NotebookItemLifecycleTests.Fixture, CollaborationReceipt) {
    let f = try NotebookItemLifecycleTests.Fixture()
    let extent = try #require(try f.store.readItemLifecycle(f.itemID))
    let base = try f.store.readBasis(targets: [extent.target, .init(kind: .workspace, id: f.store.workspaceHeader().rootBoardID)])
    let action = CollaborationAction(summary: "Immutable lifecycle", expected: base.owners, operations: [
      .init(kind: .appendPage, target: extent.target, id: UUID().uuidString, values: [:])])
    return (f, try f.store.applyCollaborationAction(action, actor: f.actor))
  }

  @Test func heldEnvelopeCannotReplaceOrDropTheOriginalInverse() throws {
    let (f, saved) = try appended(); _ = f
    #expect(saved.lifecycleInverse != nil)
    for reference in [nil, NotebookLifecycleInverseReference(rootHash: String(repeating: "a", count: 64), recordCount: 1)] {
      var changed = saved; changed.lifecycleInverse = reference
      #expect(throws: CollaborationError.self) {
        try CollaborationEnvelope(actions: [saved]).merging(.init(actions: [changed]))
      }
    }
  }

  @Test func envelopeAndDiskCannotRewriteCompactOriginalEffects() throws {
    let (f, saved) = try appended()
    var changed = saved; changed.lifecycleChanges = nil
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: CollaborationError.self) {
      try CollaborationEnvelope(actions: [saved]).merging(.init(actions: [changed]))
    }
    #expect(throws: CollaborationError.self) {
      try f.store.mergeCollaborationContent(nil, actions: [changed])
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.collaborationActionIfPresent(saved.id) == saved)
  }

  @Test func aNewEnvelopeReceiptCannotPublishAnUnavailableInverse() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), id = UUID()
    let action = CollaborationAction(id: id, summary: "Missing evidence", expected: [], operations: [])
    var receipt = CollaborationReceipt(id: id, action: action, createdAt: Date(), revisions: [], changes: [])
    receipt.lifecycleInverse = .init(rootHash: String(repeating: "b", count: 64), recordCount: 1)
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: NotebookStorageError.self) { try f.store.mergeCollaborationContent(nil, actions: [receipt]) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.collaborationActionIfPresent(id) == nil)
  }
}
