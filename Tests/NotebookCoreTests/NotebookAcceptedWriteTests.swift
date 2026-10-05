import Foundation
import Testing
@testable import NotebookCore

@Suite("Accepted native outcomes belong to their transaction")
struct NotebookAcceptedWriteTests {
  private enum DiskFailure: Error { case unavailable }

  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-accepted-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }

  @Test func refusalAfterNestedWritesRollsBackTheWholeAcceptedCommand() throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor(), read = try store.currentReadCursor()
      do {
        try store.acceptedWrite { store in
          try store.publishRecords(writes: ["accepted-first.json": .object(["value": .number(1)])])
          try store.publishRecords(writes: ["accepted-second.json": .object(["value": .number(2)])])
          throw NotebookStorageError.limitExceeded("complete_reorder")
        }
        Issue.record("The rejected command cannot acknowledge either nested write")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .rejected)
        #expect(error.underlying as? NotebookStorageError == .limitExceeded("complete_reorder"))
      }
      #expect(try !store.hasStoredValue("accepted-first.json"))
      #expect(try !store.hasStoredValue("accepted-second.json"))
      #expect(try store.currentChangeCursor() == before)
      #expect(try store.currentReadCursor() == read)
    }
  }

  @Test func nestedSourceWritesShareOneCommitAndPublication() throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor(), read = try store.currentReadCursor()
      try store.acceptedWrite { store in
        try store.publishRecords(writes: ["accepted-first.json": .object(["value": .number(1)])])
        try store.publishRecords(writes: ["accepted-second.json": .object(["value": .number(2)])])
      }
      #expect(try store.hasStoredValue("accepted-first.json"))
      #expect(try store.hasStoredValue("accepted-second.json"))
      #expect(try store.currentChangeCursor() == before + 1)
      #expect(try store.currentReadCursor() == read + 1)
    }
  }

  @Test func anErrorNamedAsADomainLimitAfterCommitStillHasAnUnresolvedOutcome() throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor()
      let lost = NotebookStore(root: store.root, storageFault: { phase in
        if case .afterCommit = phase { throw CollaborationError("resource_limit", "A lost post-commit reply") }
      })
      do {
        try lost.acceptedWrite { try $0.publishRecords(writes: ["accepted.json": .object(["value": .number(1)])]) }
        Issue.record("The native writer must retain this identity until its receipt is checked")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .unresolved, "The error spelling cannot attest rollback")
        #expect((error.underlying as? CollaborationError)?.code == "resource_limit")
      }
      #expect(try store.hasStoredValue("accepted.json"))
      #expect(try store.currentChangeCursor() == before + 1)
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func diskFailureKeepsItsStorageOutcomeAfterSuccessfulRollback(phase: NotebookStorageFault) throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root, storageFault: { point in
        if point == phase { throw DiskFailure.unavailable }
      })
      do {
        try failing.acceptedWrite { try $0.publishRecords(writes: ["accepted.json": .object(["value": .number(1)])]) }
        Issue.record("An unavailable disk cannot report a completed native command")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .storageUnavailable)
        #expect(error.underlying is DiskFailure)
      }
      #expect(try !store.hasStoredValue("accepted.json"))
      #expect(try store.currentChangeCursor() == before)
    }
  }

  @Test func aStorageProtocolBridgeDoesNotBecomeATerminalDomainRefusal() throws {
    try fixture { store, _ in
      do {
        try store.acceptedWrite { _ in throw CollaborationError("storage_error", "An unreadable body") }
        Issue.record("Expected a blocked storage result")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .storageUnavailable)
      }
    }
  }

  @Test func nonpublishingNestedChatCommandsKeepTheirLocalReadFence() throws {
    try fixture { store, actor in
      let before = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let input = NotebookChatInput(author: actor, action: .send(threadID: UUID().uuidString, text: "Accepted", context: ""))
      let job = try store.acceptedWrite { store in
        _ = try store.saveChatSubmission(input)
        return try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      }
      #expect(job.state == .attempting)
      #expect(try store.chatJob(input.id) == job)
      #expect(try store.currentChangeCursor() == before)
      #expect(try store.currentReadCursor() == read)
    }
  }
}
