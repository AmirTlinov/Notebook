import Foundation
import Testing
@testable import NotebookCore

@Suite("A question owns one immutable grant and execution")
struct AgentRequestTests {
  private struct Fixture {
    let store: NotebookStore
    let human: UUID
    let mac = UUID()
    let target: CollaborationTarget
    let reference: CollaborationReference
    let context: SharedContext
    let files: [String: JSONValue]
    func request(mode: RequestGrant.Mode = .change) throws -> AgentRequest {
      let id = UUID(), grant = try RequestGrant(mode: mode, references: [reference])
      let source = try AgentPinnedSource.capture(requestID: id, reference: reference, files: files)
      return try store.createAgentRequest(id: id, contextID: context.id, replyTo: context.entries[0].id,
        question: "Подпиши выделенную область", grant: grant, sources: [source], actor: human)
    }
    func action(_ request: AgentRequest, id: String = "answer", x: Double = 30) throws -> CollaborationAction {
      let page = try store.loadPage(target.id)
      return .init(contextID: request.contextID, requestID: request.id, summary: "Подпись в выделении",
        expected: [.init(target: target, revision: page.agentStamp.revision)], operations: [
          .init(kind: .insertElement, target: target, id: id, values: ["kind": .string("markdown"),
            "source": .string("Смысл"), "frame": try .encode(PageRect(x: x, y: 40, width: 80, height: 30))])])
    }
  }
  private func fixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-request-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), human = UUID()
    _ = try store.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID), target = CollaborationTarget(kind: .page, id: pageID)
    var page = try store.loadPage(pageID)
    _ = page.replaceElements([
      .init(id: "inside", kind: .markdown, frame: .init(x: 20, y: 20, width: 50, height: 40), source: "Visible", html: "<p>Visible</p>"),
      .init(id: "outside", kind: .markdown, frame: .init(x: 400, y: 400, width: 50, height: 40), source: "Private outside", html: "<p>Private outside</p>")], actor: human)
    _ = try store.saveMergedPage(page)
    let files = try store.referenceSourceFiles(target: target)
    let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 200, height: 150),
      revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try store.appendContext(references: [reference], author: .human, actor: human, select: true)
    try body(.init(store: store, human: human, target: target, reference: reference, context: context, files: files))
  }

  @Test func frozenSourceDoesNotFollowNewSelectionOrDiscloseTheRestOfThePage() throws {
    try fixture { f in
      let request = try f.request(mode: .question)
      let authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      try f.store.selectSharedContext(nil, actor: f.human)
      let sources = try f.store.agentPinnedSources(authority)
      let data = try String(decoding: JSONEncoder().encode(sources), as: UTF8.self)
      #expect(data.contains("Visible"))
      #expect(!data.contains("Private outside"))
      #expect(!data.contains("drawingData"))
      #expect(try f.store.agentRequest(request.id)?.request.contextID == f.context.id)
      #expect(throws: CollaborationError.self) { try f.store.claimAgentRequest(request.id, actor: f.mac) }
    }
  }

  @Test func repeatedQuestionRequiresIdenticalFrozenSourcesAndHumanAddress() throws {
    try fixture { f in
      let request = try f.request(mode: .question)
      let source = try AgentPinnedSource.capture(requestID: request.id, reference: f.reference, files: f.files)
      let cursor = try f.store.currentChangeCursor()
      let repeated = try f.store.createAgentRequest(id: request.id, contextID: f.context.id,
        replyTo: f.context.entries[0].id, question: "Подпиши выделенную область",
        grant: request.grant, sources: [source], actor: f.human)
      #expect(repeated == request)
      #expect(try f.store.currentChangeCursor() == cursor)
      let changed = try source.withVisual(nil, unavailable: "different evidence")
      #expect(throws: CollaborationError.self) {
        try f.store.createAgentRequest(id: request.id, contextID: f.context.id,
          replyTo: f.context.entries[0].id, question: "Подпиши выделенную область",
          grant: request.grant, sources: [changed], actor: f.human)
      }
      #expect(throws: CollaborationError.self) {
        try f.store.createAgentRequest(id: request.id, contextID: f.context.id,
          replyTo: UUID(), question: "Подпиши выделенную область",
          grant: request.grant, sources: [source], actor: f.human)
      }
      #expect(throws: CollaborationError.self) {
        try f.store.createAgentRequest(id: request.id, contextID: f.context.id,
          replyTo: f.context.entries[0].id, question: "Подпиши выделенную область",
          grant: request.grant, sources: [source], actor: f.mac)
      }
      #expect(try f.store.currentChangeCursor() == cursor)
    }
  }

  @Test func changeCannotClaimCompletionWithoutADurableMutationReceipt() throws {
    try fixture { f in
      let request = try f.request(), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      try f.store.appendAgentResponse(authority, sequence: 1, text: "Готово")
      let cursor = try f.store.currentChangeCursor()
      #expect(throws: CollaborationError.self) { try f.store.finishAgentRequest(authority, status: .completed) }
      #expect(try f.store.currentChangeCursor() == cursor)
      #expect(try f.store.agentRequest(request.id)?.status == .running)
      let context = try #require(f.store.sharedContexts(contextID: request.contextID).contexts.first)
      #expect(!context.entries.contains { $0.replyTo == request.questionEntryID })
      _ = try f.store.finishAgentRequest(authority, status: .failed, error: "mutation_unconfirmed")
      #expect(try f.store.agentRequest(request.id)?.status == .failed)
    }
  }

  @Test func grantAndReceiptShareTheContentCommitAndQuestionCannotWrite() throws {
    try fixture { f in
      let question = try f.request(mode: .question), readAuthority = try f.store.claimAgentRequest(question.id, actor: f.mac)
      #expect(throws: CollaborationError.self) {
        try f.store.applyCollaborationAction(f.action(question), actor: f.mac, agentAuthority: readAuthority)
      }
      let request = try f.request(), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      #expect(throws: CollaborationError.self) {
        try f.store.applyCollaborationAction(f.action(request, x: 300), actor: f.mac, agentAuthority: authority)
      }
      #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(f.action(request), actor: f.mac) }
      let action = try f.action(request), cursor = try f.store.workspaceHeader().cursor
      let receipt = try f.store.applyCollaborationAction(action, actor: f.mac, agentAuthority: authority)
      #expect(try f.store.workspaceHeader().cursor == cursor + 1)
      #expect(try f.store.agentRequest(request.id)?.execution?.receiptIDs == [receipt.id])
      #expect(try f.store.loadPage(f.target.id).elements.contains { $0.id == "answer" })
      _ = try f.store.applyCollaborationAction(action, actor: f.mac, agentAuthority: authority)
      #expect(try f.store.workspaceHeader().cursor == cursor + 1)
    }
  }

  @Test func failedCommitPublishesNeitherAnswerReceiptNorMutation() throws {
    enum Fault: Error { case disk }
    try fixture { f in
      let request = try f.request(), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      let failing = NotebookStore(root: f.store.root) { if case .beforeCommit = $0 { throw Fault.disk } }
      let before = try f.store.workspaceHeader().cursor, action = try f.action(request)
      #expect(throws: Fault.self) { try failing.applyCollaborationAction(action, actor: f.mac, agentAuthority: authority) }
      #expect(try f.store.workspaceHeader().cursor == before)
      #expect(try f.store.agentRequest(request.id)?.execution?.receiptIDs.isEmpty == true)
      #expect(try !f.store.loadPage(f.target.id).elements.contains { $0.id == "answer" })
    }
  }

  @Test func stopIsAnIntentUntilAcknowledgedAndThenFencesLateActions() throws {
    try fixture { f in
      let request = try f.request(), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      try f.store.requestAgentStop(request.id, actor: f.human)
      #expect(try f.store.agentRequest(request.id)?.status == .stopping)
      let receipt = try f.store.applyCollaborationAction(f.action(request), actor: f.mac, agentAuthority: authority)
      _ = try f.store.finishAgentRequest(authority, status: .stopped)
      #expect(try f.store.agentRequest(request.id)?.status == .stopped)
      #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(f.action(request, id: "late"), actor: f.mac, agentAuthority: authority) }
      _ = try f.store.undoCollaborationAction(receipt.id, actor: f.human)
      #expect(try !f.store.loadPage(f.target.id).elements.contains { $0.id == "answer" })
    }
  }

  @Test func streamRepeatsAreIdempotentAndOnlyOneFinalContextEntryIsCreated() throws {
    try fixture { f in
      let request = try f.request(mode: .question), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      try f.store.appendAgentResponse(authority, sequence: 1, text: "Первое ")
      let cursor = try f.store.workspaceHeader().cursor
      try f.store.appendAgentResponse(authority, sequence: 1, text: "Первое ")
      #expect(try f.store.workspaceHeader().cursor == cursor)
      #expect(throws: CollaborationError.self) { try f.store.appendAgentResponse(authority, sequence: 3, text: "Пропуск") }
      try f.store.appendAgentResponse(authority, sequence: 2, text: "наблюдение.")
      let final = try f.store.finishAgentRequest(authority, status: .completed)
      #expect(try f.store.finishAgentRequest(authority, status: .completed) == final)
      let context = try #require(f.store.sharedContexts(contextID: request.contextID).contexts.first)
      #expect(context.entries.filter { $0.replyTo == request.questionEntryID }.count == 1)
      #expect(context.entries.last?.text == "Первое наблюдение.")
    }
  }

  @Test func humanContinuationInvalidatesTheOriginalSourceButNotAnotherRequest() throws {
    try fixture { f in
      let request = try f.request(), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      var page = try f.store.loadPage(f.target.id)
      _ = page.replaceElements(page.elements + [.init(id: "human", kind: .markdown,
        frame: .init(x: 10, y: 10, width: 20, height: 20), source: "Доработка", html: "<p>Доработка</p>")], actor: f.human)
      _ = try f.store.saveMergedPage(page)
      #expect(throws: CollaborationError.self) { try f.store.applyCollaborationAction(f.action(request), actor: f.mac, agentAuthority: authority) }
      #expect(try f.store.loadPage(f.target.id).elements.contains { $0.id == "human" })
    }
  }
  @Test func privateDispatcherDerivesIdentityAndNeverAcceptsBroaderReadArguments() throws {
    try fixture { f in
      let request = try f.request(), authority = try f.store.claimAgentRequest(request.id, actor: f.mac)
      let dispatcher = NotebookCommandDispatcher(store: f.store)
      let read = try dispatcher.handleAgent(tool: "read", arguments: .object([:]), callID: "read-1", authority: authority)
      #expect(read["sources"] == nil)
      #expect(try read["request"]?.decode(AgentRequest.self) == request)
      #expect(throws: CollaborationError.self) {
        try dispatcher.handleAgent(tool: "read", arguments: .object(["target": .string("workspace")]), callID: "r", authority: authority)
      }
      #expect(throws: CollaborationError.self) {
        try dispatcher.handleAgent(tool: "read", arguments: .object(["referenceID": .string(UUID().uuidString)]), callID: "r", authority: authority)
      }
      let input = try JSONValue.object(["summary": .string("Подпись"), "operations": .encode(f.action(request).operations)])
      let receipt = try dispatcher.handleAgent(tool: "apply", arguments: input, callID: "stable-call", authority: authority)
        .decode(CollaborationReceipt.self)
      #expect(receipt.id == NotebookCommandDispatcher.agentActionID(requestID: request.id, callID: "stable-call"))
      #expect(receipt.action.requestID == request.id)
      var page = try f.store.loadPage(f.target.id)
      _ = page.replaceElements(page.elements.map { element in
        guard element.id == "answer" else { return element }
        return AgentElement(id: element.id, kind: element.kind, frame: element.frame,
          source: "Человеческая доработка", html: element.html, css: element.css,
          javaScript: element.javaScript, state: element.state)
      }, actor: f.human)
      _ = try f.store.saveMergedPage(page)
      let cursor = try f.store.workspaceHeader().cursor
      let repeated = try dispatcher.handleAgent(tool: "apply", arguments: input, callID: "stable-call", authority: authority)
        .decode(CollaborationReceipt.self)
      #expect(repeated == receipt)
      #expect(try f.store.workspaceHeader().cursor == cursor)
      #expect(try f.store.loadPage(f.target.id).elements.first { $0.id == "answer" }?.source == "Человеческая доработка")
      #expect(throws: CollaborationError.self) {
        try dispatcher.handleAgent(tool: "apply", arguments: input, callID: "new-call", authority: authority)
      }
      #expect(throws: CollaborationError.self) {
        try dispatcher.handleAgent(tool: "apply", arguments: .object(["summary": .string("Чужой"),
          "operations": .encode(f.action(request).operations), "requestID": .string(request.id.uuidString)]),
          callID: "forged", authority: authority)
      }
    }
  }

}
