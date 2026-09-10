import Foundation
import Testing
@testable import NotebookCore

@Suite("Historical executor records are values, never a second execution path")
struct AgentArchiveTests {
  private func fixture(_ body: (NotebookStore, UUID, CollaborationReference, SharedContext) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-agent-archive-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let reference = CollaborationReference(target: target, revision: try store.referenceRevision(target: target))
    let context = try store.appendContext(references: [reference], author: .human, actor: actor, text: "Сохранённый вопрос")
    try body(store, actor, reference, context)
  }

  @Test func archivedRequestStopAndExactResponseRemainAddressReadableWithoutAWriter() throws {
    try fixture { store, actor, reference, context in
      let request = AgentRequest(contextID: context.id, questionEntryID: context.entries[0].id,
        grant: try .init(mode: .question, references: [reference]), authorDeviceID: actor, sourceIDs: [reference.id])
      let execution = AgentExecution(requestID: request.id, executionID: UUID(), status: .stopped,
        stamp: .init(counter: 2, actor: actor), responseSequence: 2, responseBytes: "Первое наблюдение.".utf8.count, receiptIDs: [])
      let first = AgentResponseChunk(requestID: request.id, executionID: execution.executionID, sequence: 1, text: "Первое ")
      let second = AgentResponseChunk(requestID: request.id, executionID: execution.executionID, sequence: 2, text: "наблюдение.")
      let source = try AgentPinnedSource.capture(requestID: request.id, reference: reference,
        files: store.referenceSourceFiles(target: reference.target))
      let records: [String: JSONValue] = try [store.agentRequestFile(request.id): .encode(request),
        store.agentExecutionFile(request.id): .encode(execution), store.agentChunkFile(request.id, 1): .encode(first),
        store.agentChunkFile(request.id, 2): .encode(second), store.agentSourceFile(request.id, reference.id): .encode(source),
        store.agentStopFile(request.id): .encode(AgentStopIntent(requestID: request.id, authorDeviceID: actor))]
      try store.publishRecords(writes: records)
      let before = try store.currentChangeCursor()
      let snapshot = try #require(try store.agentRequest(request.id))
      #expect(snapshot.request == request && snapshot.execution == execution && snapshot.stopRequested)
      #expect(snapshot.status == .stopped && snapshot.responseText == "Первое наблюдение.")
      #expect(try store.agentRequest(request.id, includesResponse: false)?.responseText == "")
      #expect(try store.currentChangeCursor() == before)
      for (file, value) in records { #expect(try store.storedValue(file) == value) }
    }
  }

  @Test func historicalRequestIDCannotAuthorizeANewCollaborationAction() throws {
    try fixture { store, actor, reference, context in
      let page = try store.loadPage(reference.target.id)
      let action = CollaborationAction(contextID: context.id, requestID: UUID(), summary: "Не новый исполнитель",
        expected: [.init(target: reference.target, revision: page.agentStamp.revision)], operations: [
          .init(kind: .insertElement, target: reference.target, id: "old-executor", values: [
            "kind": .string("markdown"), "source": .string("Недопустимо"),
            "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 30))])])
      let cursor = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) { try store.applyCollaborationAction(action, actor: actor) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.loadPage(reference.target.id) == page)
    }
  }
}
