import Foundation
import Testing
@testable import NotebookCore

@Suite("Independent archive import adopts membership without replacing authors")
struct NotebookArchiveUnionTests {
  private func content(actor: UUID = UUID()) -> CollaborationContent {
    let initial = WorkspaceIndex.initial(actor: actor, pageSize: .init(width: 834, height: 1194))
    return .init(workspace: initial.index,
      hierarchy: .initial(rootBoardID: initial.index.rootBoardID, itemIDs: initial.index.items.map(\.id), actor: actor),
      ink: .init(stamp: .init(counter: 0, actor: actor)), pages: [initial.page], documents: [], states: [])
  }

  @Test func zeroClockMembersSurviveOrdinaryReplicationAndItsRepeat() throws {
    let high = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
    let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let local = content(actor: high), other = content(actor: low)
    let imported = try local.importingIndependent(other, actor: UUID())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-union-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.installCheckpoint(.init(workspaceID: UUID(), envelope: .init(content: local),
      presence: .init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194),
        selectedItemID: local.workspace.selectedItemID, notebookPageID: local.pages[0].id)))
    _ = try store.receiveCollaboration(.init(content: imported))
    let accepted = try store.collaborationContent(), cursor = try store.currentChangeCursor()
    #expect(accepted.pages.contains(local.pages[0]) && accepted.pages.contains(other.pages[0]))
    #expect(Set(accepted.hierarchy.itemIDs) == Set(local.hierarchy.itemIDs + other.hierarchy.itemIDs))
    _ = try store.receiveCollaboration(.init(content: imported))
    #expect(try store.collaborationContent() == accepted)
    #expect(try store.currentChangeCursor() == cursor)
    _ = try store.receiveCollaboration(.init(content: other))
    let replayed = try store.collaborationContent()
    #expect(replayed.workspace.items.count == 2 && replayed.pages.count == 2)
    #expect(Set(replayed.hierarchy.itemIDs) == Set(accepted.hierarchy.itemIDs))
  }

  @Test func existingFieldVersionsAndImportedValuesRetainTheirAuthors() throws {
    let a = UUID(), b = UUID(), importer = UUID()
    var local = BoardDocument.initial(itemIDs: [UUID()], actor: a)
    var other = BoardDocument.initial(itemIDs: [UUID()], actor: b)
    let addedLocal = local.addItem(UUID(), near: .init(x: 500, y: 200), actor: a)
    let addedOther = other.addItem(UUID(), near: .init(x: -500, y: 200), actor: b)
    #expect(addedLocal && addedOther)
    let imported = try local.importingIndependent(other, actor: importer)
    let metadata = try #require(imported.collaboration)
    for (key, version) in try #require(local.collaboration).fields where !key.hasSuffix("/order") {
      #expect(metadata.fields[key] == version)
    }
    for (key, version) in try #require(other.collaboration).fields where !key.hasSuffix("/order") && !key.hasSuffix("/exists") {
      #expect(metadata.fields[key] == version)
    }
    #expect(imported.placements == (local.placements + other.placements).sorted { $0.id.uuidString < $1.id.uuidString })
  }

  @Test func collisionIncompleteArchiveAndClockExhaustionFailBeforePublication() throws {
    let local = content(), other = content()
    #expect(throws: CollaborationError.self) { try local.importingIndependent(local, actor: UUID()) }
    var partial = other; partial.pages = []
    #expect(throws: NotebookStorageError.self) { try local.importingIndependent(partial, actor: UUID()) }
    let exhausted = BoardDocument(freeItems: [], stamp: .init(counter: VersionStamp.maximumCounter, actor: UUID()))
    #expect(throws: CollaborationError.self) {
      try exhausted.importingIndependent(BoardDocument.initial(itemIDs: [], actor: UUID()), actor: UUID())
    }
  }

  @Test func historicalMemberCollisionCannotResurrectADeletedOwner() throws {
    let id = UUID(), actor = UUID()
    let source = BoardDocument.initial(itemIDs: [id], actor: actor)
    var tombstone = source
    let removed = tombstone.reconcileItems([], actor: actor)
    #expect(removed)
    #expect(tombstone.itemIDs.isEmpty)
    #expect(throws: CollaborationError.self) { try tombstone.importingIndependent(source, actor: UUID()) }
  }
}
