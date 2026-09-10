import Foundation
import Testing
@testable import NotebookCore

private enum CheckpointFault: Error { case injected }

@Suite("External checkpoints bootstrap one complete SQL archive")
struct NotebookCheckpointTests {
  private func checkpoint() throws -> NotebookCheckpoint {
    let actor = UUID()
    let initial = WorkspaceIndex.initial(actor: actor, pageSize: .init(width: 834, height: 1194))
    let content = CollaborationContent(workspace: initial.index,
      hierarchy: .initial(rootBoardID: initial.index.rootBoardID, itemIDs: initial.index.items.map(\.id), actor: actor),
      ink: .init(stamp: .init(counter: 0, actor: actor)), pages: [initial.page], documents: [], states: [])
    return .init(workspaceID: UUID(), envelope: .init(content: content),
      presence: .init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194),
        selectedItemID: initial.index.selectedItemID, notebookPageID: initial.page.id))
  }

  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-" + UUID().uuidString)
  }

  @Test func installsContentPresenceAndProvenanceWithOneDelivery() throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let value = try checkpoint(), store = NotebookStore(root: root)
    let receipt = try store.installCheckpoint(value)
    #expect(receipt.checkpointSHA256 == (try collaborationHash(value)))
    #expect(receipt.workspaceID == value.workspaceID)
    #expect(try store.currentChangeCursor() == 1)
    #expect(try store.currentReadCursor() == 1)
    #expect(try store.collaborationContent() == value.envelope.content)
    #expect(try store.loadPresence() == value.presence)
    #expect(try store.storedValue("local/checkpoint.json")?.decode(NotebookCheckpointReceipt.self) == receipt)
    #expect(try store.workspaceHeader().workspaceID == value.workspaceID)
    #expect(throws: NotebookStorageError.self) { try store.installCheckpoint(value) }
    #expect(try store.currentChangeCursor() == 1)
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func failedBootstrapPublishesNoOwnerAndCanRetry(fault: NotebookStorageFault) throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let value = try checkpoint()
    let failing = NotebookStore(root: root) { point in
      if String(describing: point) == String(describing: fault) { throw CheckpointFault.injected }
    }
    #expect(throws: CheckpointFault.self) { try failing.installCheckpoint(value) }
    let store = NotebookStore(root: root)
    #expect(try store.currentChangeCursor() == 0)
    #expect(try store.storedValue("workspace.json") == nil)
    #expect(try store.storedValue("local/checkpoint.json") == nil)
    _ = try store.installCheckpoint(value)
    #expect(try store.collaborationContent() == value.envelope.content)
  }

  @Test func ambiguousCommitCanBeReadBackButNotReplaced() throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let value = try checkpoint()
    let failing = NotebookStore(root: root) { if case .afterCommit = $0 { throw CheckpointFault.injected } }
    #expect(throws: CheckpointFault.self) { try failing.installCheckpoint(value) }
    let store = NotebookStore(root: root)
    #expect(try store.collaborationContent() == value.envelope.content)
    #expect(try store.loadPresence() == value.presence)
    #expect(try store.currentChangeCursor() == 1)
    #expect(throws: NotebookStorageError.self) { try store.installCheckpoint(value) }
  }

  @Test func missingPageIsRejectedBeforeCreatingDatabase() throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let value = try checkpoint(); var content = value.envelope.content!
    content.pages = []
    let invalid = NotebookCheckpoint(workspaceID: value.workspaceID, envelope: .init(content: content), presence: value.presence)
    #expect(throws: NotebookStorageError.self) { try NotebookStore(root: root).installCheckpoint(invalid) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func orphanSelectionIsRejectedBeforeCreatingDatabase() throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let value = try checkpoint()
    let invalid = NotebookCheckpoint(workspaceID: value.workspaceID, envelope: value.envelope,
      presence: value.presence.selecting(itemID: UUID(), pageID: nil))
    #expect(throws: NotebookStorageError.self) { try NotebookStore(root: root).installCheckpoint(invalid) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func cannotReplaceExistingWorkspaceOrRetargetAnEmptyIdentity() throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), value = try checkpoint()
    try store.prepareEmptyWorkspace(workspaceID: UUID())
    #expect(throws: NotebookStorageError.self) { try store.installCheckpoint(value) }
    #expect(try store.currentChangeCursor() == 0)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let content = try store.collaborationContent(), cursor = try store.currentChangeCursor()
    #expect(throws: NotebookStorageError.self) { try store.installCheckpoint(value) }
    #expect(try store.collaborationContent() == content)
    #expect(try store.currentChangeCursor() == cursor)
  }
}
