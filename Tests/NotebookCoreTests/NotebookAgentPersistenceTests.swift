import Foundation
import Testing
@testable import NotebookCore

@Suite("Historical request replication remains immutable")
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
