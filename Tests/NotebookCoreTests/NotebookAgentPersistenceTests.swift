import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed request history and replication")
struct NotebookAgentPersistenceTests {
  private func fixture(_ body: (NotebookStore, UUID, CollaborationReference, SharedContext) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let page = try #require(store.loadIndex().selectedPageID), target = CollaborationTarget(kind: .page, id: page)
    let reference = CollaborationReference(target: target, revision: try store.referenceRevision(target: target))
    let context = try store.appendContext(references: [reference], author: .human, actor: actor, text: "Question", select: false)
    try body(store, actor, reference, context)
  }

  @Test func completedHistoryNeverHidesANewQuestionAndTheWorkerDoesNotReadChunks() throws {
    try fixture { store, actor, reference, context in
      let grant = try RequestGrant(mode: .question, references: [reference])
      var newest: UUID!, queued: UUID!
      try store.commandTransaction {
        for sequence in 0..<80 {
          let id = UUID(), request = AgentRequest(id: id, contextID: context.id, questionEntryID: context.entries[0].id,
            grant: grant, createdAt: Date(timeIntervalSince1970: Double(sequence)), authorDeviceID: actor, sourceIDs: [reference.id])
          try store.publishRecords(writes: [store.agentRequestFile(id): .encode(request)])
          if sequence == 79 { newest = id; queued = id }
          else {
            let execution = AgentExecution(requestID: id, executionID: UUID(), status: .stopped,
              stamp: .init(counter: 2, actor: actor), responseSequence: 0, responseBytes: 0, receiptIDs: [])
            try store.publishRecords(writes: [store.agentExecutionFile(id): .encode(execution)])
          }
        }
      }
      #expect(try store.pendingAgentRequests().map(\.id) == [queued])
      let first = try store.readAgentRequestHeaders(limit: 16)
      #expect(first.count == 16 && first[0].id == newest)
      let next = try store.readAgentRequestHeaders(afterID: first.last!.id, limit: 16)
      #expect(Set(first.map(\.id)).isDisjoint(with: next.map(\.id)))
      #expect(next.first!.createdAt < first.last!.createdAt)
      let authority = try store.claimAgentRequest(queued, actor: actor)
      _ = try store.finishAgentRequest(authority, status: .stopped)
      #expect(try store.pendingAgentRequests().isEmpty)
    }
  }

  @Test func immutableInputsAndExecutionTerminalStatesRejectConflictingReplication() throws {
    try fixture { store, actor, reference, context in
      let request = AgentRequest(id: UUID(), contextID: context.id, questionEntryID: context.entries[0].id,
        grant: try .init(mode: .question, references: [reference]), authorDeviceID: actor, sourceIDs: [reference.id])
      let file = store.agentRequestFile(request.id), original = try JSONValue.encode(request)
      #expect(try store.mergeAgentRecord(file: file, value: original, previous: original) == original)
      #expect(throws: NotebookStorageError.self) {
        try store.mergeAgentRecord(file: file, value: original.setting("authorDeviceID", .string(UUID().uuidString)), previous: original)
      }
      let completed = AgentExecution(requestID: request.id, executionID: UUID(), status: .stopped,
        stamp: .init(counter: 3, actor: actor), responseSequence: 0, responseBytes: 0, receiptIDs: [])
      var late = completed
      late.status = .running; late.stamp = .init(counter: 4, actor: actor)
      #expect(throws: NotebookStorageError.self) {
        try store.mergeAgentRecord(file: store.agentExecutionFile(request.id), value: .encode(late), previous: .encode(completed))
      }
      late.stamp = .init(counter: 2, actor: actor)
      #expect(try store.mergeAgentRecord(file: store.agentExecutionFile(request.id), value: .encode(late), previous: .encode(completed)) == .encode(completed))
    }
  }
}
