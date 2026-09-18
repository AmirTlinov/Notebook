import Foundation
import Testing
@testable import NotebookCore

@Suite("Deleted item identities cannot acquire a second lifetime", .serialized)
struct NotebookItemIdentityRetirementTests {
  @Test(arguments: [false, true], [CollaborationOperation.Kind.createNotebook, .createDocument, .createBoard])
  func aNewRunCannotReuseADeletedItemButTheOriginalCreateRunCanReplay(nativeDelete: Bool, kind: CollaborationOperation.Kind) throws {
    let f = try NotebookItemLifecycleTests.Fixture(), header = try f.store.workspaceHeader(), id = UUID()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let cover = CollaborationTarget(kind: .cover, id: id, boardID: header.rootBoardID)
    func creation() throws -> CollaborationAction {
      var values: [String: JSONValue] = ["center": try .encode(WorldPoint.zero)]
      if kind == .createNotebook { values["pageID"] = try .encode(UUID()) }
      if kind == .createDocument {
        values["paperSize"] = .string("a4")
        values["blocks"] = try .encode([DocumentBlock.markdown(id: "body", source: "Original")])
      }
      let basis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
      return .init(summary: "A single item birth", expected: basis.owners,
        operations: [.init(kind: kind, target: board, id: id.uuidString, values: values)])
    }
    let original = try creation(), created = try f.store.applyCollaborationAction(original, actor: f.actor)
    if nativeDelete { _ = try f.store.deleteWorkspaceItem(itemID: id, actor: UUID()) }
    else {
      var read = NotebookCommand(command: .read); read.readSnapshots = true
      read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(id)]).decode(NotebookReadQuery.self)]
      let basis = try #require(try NotebookCommandDispatcher(store: f.store).handle(read).array.first?["basis"]?.decode(NotebookReadBasis.self))
      let operation = CollaborationOperation(kind: .deleteItem, target: cover)
      _ = try f.store.applyCollaborationAction(.init(additionalOwners: [cover], summary: "Retire original identity",
        expected: f.store.expectations(base: basis, operations: [operation]), operations: [operation]), actor: UUID())
    }
    #expect(try f.store.readItemHeader(id) == nil)
    let cursor = try f.store.currentChangeCursor(), secondLifetime = try creation()
    #expect(throws: (any Error).self) { _ = try f.store.applyCollaborationAction(secondLifetime, actor: UUID()) }
    #expect(try f.store.readItemHeader(id) == nil)
    #expect(try f.store.ownerBoardID(of: id) == nil)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.collaborationActionIfPresent(secondLifetime.id) == nil)
    #expect(try f.store.applyCollaborationAction(original, actor: f.actor) == created,
      "A retry of the original immutable action is not a second item birth")
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readItemHeader(id) == nil)
  }
}
