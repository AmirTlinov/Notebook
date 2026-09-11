import XCTest
import NotebookCore
import NotebookCodex
@testable import Notebook

private actor NativeOwner: NotebookCodexConversationOwner, NotebookCodexCatalogueOwner {
  let thread = UUID().uuidString, turn = UUID().uuidString
  var busy = false, unknown = false
  var projectEdits = 0
  var project: CodexProject?
  var sent: [UUID] = [], interrupted: [String] = [], decisions: [CodexUserDecision] = []
  var accepted: [CodexMessage] = []
  var stopIsStale = false
  var needsSignIn = false
  func requireSignIn(_ required: Bool) { needsSignIn = required }
  func finishBeforeStop() { stopIsStale = true }
  func configure(busy: Bool = false, unknown: Bool = false) { self.busy = busy; self.unknown = unknown }
  func counts() -> (Int, Int) { (sent.count, interrupted.count) }
  func attach(threadID: String) { }
  func detach(threadID: String) { }
  func close() { }
  func snapshot(threadID: String) -> CodexConversation? {
    .init(threadID: threadID, revision: 1, title: "Математика", ready: true, busy: busy, activeTurnID: busy ? turn : nil,
      messages: accepted, requests: [], acceptedMessages: [:], turnStatuses: [:])
  }
  func send(threadID: String, clientMessageID: UUID, text: String, context: String?) throws -> String {
    sent.append(clientMessageID)
    accepted.append(.init(id: UUID().uuidString, turnID: turn, clientID: clientMessageID.uuidString.lowercased(), role: .user, text: text))
    if unknown { throw CodexBridgeError.acceptanceUnknown }
    return turn
  }
  func interrupt(threadID: String, turnID: String) throws {
    if stopIsStale { throw CodexBridgeError.staleTurn }
    interrupted.append(turnID)
  }
  func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) { decisions.append(decision) }
  func activities(threadIDs: [String]) -> [CodexTaskActivity] { threadIDs.map { .init(id: $0, status: .idle) } }
  func readProject(id: String) -> CodexProject { project ?? .init(id: id, name: "Notebook", roots: ["/tmp"]) }
  func updateProject(_ edit: CodexProjectEdit) throws -> CodexProject {
    projectEdits += 1
    let value = CodexProject(id: edit.id, name: edit.name ?? "Notebook", roots: edit.roots ?? ["/tmp"])
    project = value
    if unknown { throw CodexBridgeError.acceptanceUnknown }
    return value
  }
  func projects(cursor: String?) -> CodexProjectPage { .init(projects: [], nextCursor: nil) }
  func tasks(cursor: String?, project: CodexProject?) -> CodexTaskPage { .init(tasks: [.init(id: thread, title: "Математика", cwd: "/tmp")], nextCursor: nil, defaultProviderNeedsSignIn: needsSignIn) }
  func history(threadID: String, cursor: String?) -> CodexHistoryPage { .init(messages: accepted, nextCursor: nil) }
  func create(directory: URL, title: String, workspaceID: UUID) throws -> CodexTask {
    if needsSignIn { throw CodexBridgeError.signInRequired }
    return .init(id: thread, title: title, cwd: directory.path)
  }
}

@MainActor
final class NotebookCodexSidecarTests: XCTestCase {
  private func fixture(_ body: (NotebookStore, NotebookPersistenceQueue, NativeOwner, UUID) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sidecar-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), peer = UUID()
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    try await body(store, queue, NativeOwner(), peer)
    let saved = await queue.flush(); XCTAssertTrue(saved)
  }
  private func sidecar(_ store: NotebookStore, _ queue: NotebookPersistenceQueue, _ native: NativeOwner) throws -> NotebookCodexSidecar {
    .init(persistence: queue, bridge: native, metadata: native,
      workspaceID: try store.workspaceHeader().workspaceID, directory: store.root.appendingPathComponent("task"))
  }
  private func wait(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !(try await predicate()), .now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    let ready = try await predicate(); XCTAssertTrue(ready)
  }

  func testNativeProjectEditReconcilesLostReplyWithoutEditingOrStartingTwice() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(unknown: true)
      let service = try sidecar(store, queue, native)
      let edit = CodexProjectEdit(id: "native-project", name: "Исследование", roots: nil)
      let input = NotebookChatInput(author: peer, action: .updateProject(edit))
      let request = NotebookChatEnvelope(body: .request(.job(input)))
      _ = await service.receive(request, peerID: peer); service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      _ = await service.receive(request, peerID: peer)
      let edits = await native.projectEdits, turns = await native.counts()
      XCTAssertEqual(edits, 1); XCTAssertEqual(turns.0, 0)
      XCTAssertEqual(try store.chatJob(input.id)?.result, .project(.init(id: edit.id, name: "Исследование", roots: ["/tmp"])))
      await service.stop()
    }
  }

  func testRepeatedTransportRequestExecutesOneNativeMessageAndKeepsSameThread() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native), thread = native.thread
      let input = NotebookChatInput(author: peer, action: .send(threadID: thread, text: "2 + 2", context: ""))
      let request = NotebookChatEnvelope(body: .request(.job(input)))
      for _ in 0..<3 { _ = await service.receive(request, peerID: peer) }
      service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      for _ in 0..<3 { _ = await service.receive(request, peerID: peer) }
      let count = await native.counts(); XCTAssertEqual(count.0, 1); XCTAssertEqual(count.1, 0)
      let receipt = try XCTUnwrap(store.chatJob(input.id)); XCTAssertEqual(receipt.input.action.threadID, thread)
      await service.stop()
      let restarted = try sidecar(store, queue, native); restarted.start()
      _ = await restarted.receive(request, peerID: peer)
      try await Task.sleep(for: .milliseconds(1100))
      let final = await native.counts(); XCTAssertEqual(final.0, 1)
      await restarted.stop()
    }
  }

  func testBusyTaskQueuesWithoutSteeringAndUnknownAcceptanceReconcilesHistory() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(busy: true, unknown: true)
      let service = try sidecar(store, queue, native)
      let input = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "Объясни", context: ""))
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      service.start()
      try await Task.sleep(for: .milliseconds(1200))
      let counts = await native.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
      XCTAssertEqual(try store.chatJob(input.id)?.state, .saved)
      await native.configure(unknown: true)
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      let final = await native.counts(); XCTAssertEqual(final.0, 1)
      await service.stop()
    }
  }

  func testRestartWithoutAcceptanceProofCannotRepeatAttemptOrApproveAnything() async throws {
    try await fixture { store, queue, native, peer in
      let input = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "Объясни", context: ""))
      _ = try store.saveChatInput(input)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      let service = try sidecar(store, queue, native); service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .uncertain } }
      let counts = await native.counts(); XCTAssertEqual(counts.0, 0)
      let decisions = await native.decisions; XCTAssertTrue(decisions.isEmpty)
      let rejected = await service.receive(.init(body: .request(.job(input))), peerID: UUID())
      XCTAssertNil(rejected)
      await service.stop()
    }
  }

  func testTurnFinishedOnMacRejectsStopWithoutAnUnknownOrRepeatedInterruption() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(busy: true); await native.finishBeforeStop()
      let service = try sidecar(store, queue, native)
      let action = NotebookChatAction.stop(threadID: native.thread, turnID: native.turn)
      let input = NotebookChatInput(id: try XCTUnwrap(action.controlID(author: peer)), author: peer, action: action)
      let request = NotebookChatEnvelope(body: .request(.job(input)))
      _ = await service.receive(request, peerID: peer); service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .rejected } }
      _ = await service.receive(request, peerID: peer)
      let counts = await native.counts(); XCTAssertEqual(counts.1, 0)
      await service.stop()
    }
  }
  func testMissingDefaultAccountRejectsCreationBeforeDispatchAndKeepsCodexAsLoginOwner() async throws {
    try await fixture { store, queue, native, peer in
      await native.requireSignIn(true)
      let service = try sidecar(store, queue, native)
      let catalogue = await service.receive(.init(body: .request(.catalogue(cursor: nil))), peerID: peer)
      guard case .reply(.catalogue(let page)) = catalogue?.body else { return XCTFail("Expected the native catalogue") }
      XCTAssertTrue(page.defaultProviderNeedsSignIn)
      let input = NotebookChatInput(author: peer, action: .create(title: "Математика"))
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .rejected } }
      XCTAssertEqual(try store.chatJob(input.id)?.error, "Войдите в Codex на Mac. Отдельного входа Notebook нет.")
      await native.requireSignIn(false)
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      XCTAssertEqual(try store.chatJob(input.id)?.state, .rejected, "Sign-in never silently replays a rejected creation")
      let next = NotebookChatInput(author: peer, action: .create(title: "Математика"))
      _ = await service.receive(.init(body: .request(.job(next))), peerID: peer)
      try await wait { try await queue.submit { try $0.chatJob(next.id)?.state == .accepted } }
      await service.stop()
    }
  }

}
