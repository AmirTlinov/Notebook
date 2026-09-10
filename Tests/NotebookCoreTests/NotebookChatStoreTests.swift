import Foundation
import Testing
@testable import NotebookCore

@Suite("Codex delivery survives lost acknowledgements without a second executor")
struct NotebookChatStoreTests {
  enum Fault: Error { case injected }
  func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try body(store, author)
  }
  func input(_ author: UUID, id: UUID = UUID(), text: String = "Почему x² ≥ 0?") -> NotebookChatInput {
    .init(id: id, author: author, action: .send(threadID: "00000000-0000-0000-0000-000000000001", text: text, context: ""), createdAt: Date(timeIntervalSince1970: 100))
  }

  @Test func exactReplayIsNotAnotherMessageAndCollisionCannotEditIt() throws {
    try fixture { store, author in
      let input = input(author), saved = try store.saveChatInput(input)
      #expect(try store.saveChatInput(input) == saved)
      #expect(throws: NotebookStorageError.self) { try store.saveChatInput(self.input(author, id: input.id, text: "different")) }
      #expect(try store.pendingChatJobs() == [saved])
    }
  }
  @Test func draftBindingAndQueueDoNotInvalidateCanvasOrReplicateHistory() throws {
    try fixture { store, author in
      let read = try store.currentReadCursor(), changes = try store.currentChangeCursor()
      let panel = NotebookChatPanelState(threadID: UUID().uuidString, draft: "интеграл ∫", sidecarID: UUID())
      try store.saveChatPanel(panel, author: author)
      let input = input(author)
      _ = try store.saveChatInput(input)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      #expect(try store.currentReadCursor() == read)
      #expect(try store.currentChangeCursor() == changes)
      #expect(try NotebookStore(root: store.root).chatPanel(author: author) == panel)
    }
  }
  @Test(arguments: [NotebookStorageFault.beforeCommit, .afterCommit])
  func disconnectAtAttemptBoundaryNeverErasesAnAcceptedAttempt(fault: NotebookStorageFault) throws {
    try fixture { store, author in
      let input = input(author); _ = try store.saveChatInput(input)
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: fault) == String(describing: point) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.advanceChatJob(input.id, from: .saved, to: .attempting) }
      let recovered = try #require(try NotebookStore(root: store.root).chatJob(input.id))
      #expect(recovered.state == (String(describing: fault) == String(describing: NotebookStorageFault.afterCommit) ? .attempting : .saved))
      #expect(try store.saveChatInput(input) == recovered)
    }
  }
  @Test func recoveryMustReconcileAndCannotRequeueUncertainAcceptance() throws {
    try fixture { store, author in
      let input = input(author); _ = try store.saveChatInput(input)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      _ = try store.advanceChatJob(input.id, from: .attempting, to: .uncertain)
      #expect(throws: NotebookStorageError.self) { try store.advanceChatJob(input.id, from: .uncertain, to: .saved) }
      let receipt = try store.advanceChatJob(input.id, from: .uncertain, to: .accepted, result: .turn(UUID().uuidString))
      #expect(try store.pendingChatJobs().isEmpty)
      #expect(try store.saveChatInput(input) == receipt)
      #expect(throws: NotebookStorageError.self) { try store.advanceChatJob(input.id, from: .accepted, to: .attempting) }
    }
  }
  @Test func receiptOrderingDoesNotRegressAfterReconnect() throws {
    try fixture { store, author in
      let input = input(author); let saved = try store.saveChatInput(input)
      let accepted = NotebookChatJob(input: input, state: .accepted, result: .turn(UUID().uuidString), revision: 2)
      #expect(try store.receiveChatReceipt(accepted) == accepted)
      #expect(try store.receiveChatReceipt(saved) == accepted)
      #expect(try store.receiveChatReceipt(accepted) == accepted)
      #expect(throws: NotebookStorageError.self) {
        try store.receiveChatReceipt(.init(input: input, state: .uncertain, revision: 3))
      }
    }
  }
  @Test func submissionClearsOnlyItsOwnDraftInTheSameTransaction() throws {
    try fixture { store, author in
      let input = input(author), thread = input.action.threadID!
      try store.saveChatPanel(.init(threadID: thread, draft: "Почему x² ≥ 0?"), author: author)
      let failing = NotebookStore(root: store.root) { if case .afterCommit = $0 { throw Fault.injected } }
      #expect(throws: Fault.self) { try failing.saveChatSubmission(input) }
      #expect(try store.chatJob(input.id) != nil)
      #expect(try store.chatPanel(author: author).draft.isEmpty)
      try store.saveChatPanel(.init(threadID: thread, draft: "Новый черновик"), author: author)
      _ = try store.saveChatSubmission(input)
      #expect(try store.chatPanel(author: author).draft == "Новый черновик")
    }
  }
  @Test func peerIdentityAndEnvelopeBudgetAreEnforced() throws {
    let author = UUID(), input = input(author)
    let envelope = NotebookChatEnvelope(body: .request(.job(input)))
    #expect(envelope.isValid(from: author))
    #expect(!envelope.isValid(from: UUID()))
    #expect(!NotebookChatEnvelope(body: .reply(.failure(String(repeating: "x", count: 200 * 1024)))).isValid(from: author))
    #expect(try JSONDecoder().decode(NotebookChatEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
    #expect(!self.input(author, text: String(repeating: "x", count: 32769)).isValid)
  }
  @Test func queueIsBoundedAndDoesNotDiscardUnknownMessages() throws {
    try fixture { store, author in
      for _ in 0..<128 { _ = try store.saveChatInput(input(author)) }
      #expect(throws: NotebookStorageError.self) { try store.saveChatInput(input(author)) }
      #expect(try store.pendingChatJobs().count == 128)
      #expect(try store.recentChatJobs(author: author).count == 32)
    }
  }
}

@Suite("Frozen Notebook attention is not a second execution grant")
struct NotebookAttentionEvidenceTests {
  @Test func evidenceSurvivesLaterSourceEditsAndHasNoAgentRequest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-attention-chat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID), target = CollaborationTarget(kind: .page, id: pageID)
    let files = try store.referenceSourceFiles(target: target)
    let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 120, height: 120),
      revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try store.appendContext(references: [reference], author: .human, actor: author, select: true)
    let source = try AgentPinnedSource.capture(requestID: context.id, reference: reference, files: files)
      .withVisual(nil, unavailable: "fixture_without_pixels")
    #expect(try !store.hasAttentionEvidence(contextID: context.id))
    try store.saveAttentionEvidence([source], contextID: context.id)
    #expect(try store.hasAttentionEvidence(contextID: context.id))
    let cursor = try store.currentChangeCursor()
    try store.saveAttentionEvidence([source], contextID: context.id)
    #expect(try store.currentChangeCursor() == cursor)
    var page = try store.loadPage(pageID)
    page.replaceElements([.init(id: "later", kind: .markdown, frame: .init(x: 10, y: 10, width: 40, height: 40), source: "human", html: "<p>human</p>")], actor: author)
    try store.savePage(page)
    #expect(try store.referenceRevision(target: target) != reference.revision)
    #expect(try NotebookStore(root: root).attentionEvidence(contextID: context.id, referenceID: reference.id) == source)
    #expect(try store.sqlRead { try $0.rows("SELECT address FROM records WHERE file LIKE 'agent/requests/%' LIMIT 1").isEmpty })
    let changed = try source.withVisual(nil, unavailable: "cannot replace the historical reason")
    #expect(throws: NotebookStorageError.self) { try store.saveAttentionEvidence([changed], contextID: context.id) }
  }
}
