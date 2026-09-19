import XCTest
import NotebookCore
import NotebookCodex
@testable import Notebook

private actor NativeOwner: NotebookCodexConversationOwner, NotebookCodexCatalogueOwner, NotebookCodexProcessOwner, NotebookCodexVoiceOwner {
  var processStarts = 0, voiceStarts = 0
  func startProcess(id: UUID, request: NotebookRunRequest, publish: @escaping @Sendable (NotebookProcessEvent) async throws -> Void) async throws { processStarts += 1; try await publish(.running) }
  func writeProcess(id: UUID, data: Data) async throws { }
  func resizeProcess(id: UUID, columns: Int, rows: Int) async throws { }
  func stopProcess(id: UUID) async throws { }
  func startVoice(id: UUID, request: NotebookVoiceStart) { voiceStarts += 1 }
  func stopVoice(id: UUID) { }
  func voiceState(id: UUID) -> NotebookVoiceState? { nil }

  let thread = UUID().uuidString, turn = UUID().uuidString
  var busy = false, unknown = false
  var projectEdits = 0
  var project: CodexProject?
  var accessMode = CodexAccessMode.workspace
  var model = CodexModelSelection(model: "fixture", effort: "low")
  var modelChanges = 0
  var submittedAttachments: [CodexInputAttachment] = []
  var accessChanges = 0
  var sent: [UUID] = [], interrupted: [String] = [], decisions: [CodexUserDecision] = []
  var accepted: [CodexMessage] = []
  var stopIsStale = false
  var needsSignIn = false
  var slowCreation = false
  var failsCreationSetup = false
  func failCreationSetup() { failsCreationSetup = true }
  func delayCreation() { slowCreation = true }
  func requireSignIn(_ required: Bool) { needsSignIn = required }
  func finishBeforeStop() { stopIsStale = true }
  func configure(busy: Bool = false, unknown: Bool = false) { self.busy = busy; self.unknown = unknown }
  func counts() -> (Int, Int) { (sent.count, interrupted.count) }
  func attach(threadID: String) { }
  func detach(threadID: String) { }
  func close() { }
  func snapshot(threadID: String) -> CodexConversation? {
    .init(threadID: threadID, revision: 1, title: "Математика", ready: true, busy: busy, activeTurnID: busy ? turn : nil,
      messages: accepted, requests: [], acceptedMessages: [:], turnStatuses: [:],
      access: .init(profileID: accessMode.rawValue, approvalPolicy: .string(accessMode.approvalPolicy), available: CodexAccessMode.allCases), model: model)
  }
  func send(threadID: String, clientMessageID: UUID, text: String, context: String?, attachments: [CodexInputAttachment]) throws -> String {
    submittedAttachments = attachments
    sent.append(clientMessageID)
    accepted.append(.init(id: UUID().uuidString, turnID: turn, clientID: clientMessageID.uuidString.lowercased(), role: .user, text: text))
    if unknown { throw CodexBridgeError.acceptanceUnknown }
    return turn
  }
  func steer(threadID: String, turnID: String, clientMessageID: UUID, text: String, context: String?, attachments: [CodexInputAttachment]) throws -> String {
    guard turnID == turn else { throw CodexBridgeError.staleTurn }
    return try send(threadID: threadID, clientMessageID: clientMessageID, text: text, context: context, attachments: attachments)
  }
  func interrupt(threadID: String, turnID: String) throws {
    if stopIsStale { throw CodexBridgeError.staleTurn }
    interrupted.append(turnID)
  }
  func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) { decisions.append(decision) }
  func setModel(threadID: String, selection: CodexModelSelection) throws {
    modelChanges += 1; model = selection
    if unknown { throw CodexBridgeError.acceptanceUnknown }
  }
  func compact(threadID: String) { }
  func setAccess(threadID: String, mode: CodexAccessMode) throws {
    accessChanges += 1; accessMode = mode
    if unknown { throw CodexBridgeError.acceptanceUnknown }
  }
  func activities(threadIDs: [String]) -> [CodexTaskActivity] { threadIDs.map { .init(id: $0, status: .idle) } }
  func readProject(id: String) -> CodexProject { project ?? .init(id: id, name: "Notebook", roots: ["/tmp"]) }
  func createProject(name: String, path: String, idempotencyKey: UUID) throws -> CodexProject { .init(id: idempotencyKey.uuidString, name: name, roots: [path]) }
  func updateProject(_ edit: CodexProjectEdit) throws -> CodexProject {
    projectEdits += 1
    let value = CodexProject(id: edit.id, name: edit.name ?? "Notebook", roots: edit.roots ?? ["/tmp"])
    project = value
    if unknown { throw CodexBridgeError.acceptanceUnknown }
    return value
  }
  func models() -> [CodexModelOption] { [.init(id: "fixture", name: "Fixture", efforts: ["low", "high"], defaultEffort: "low")] }
  func resources(threadID: String, kind: CodexResourceKind, cursor: String?) -> CodexResourcePage { .init(resources: []) }
  func projects(cursor: String?) -> CodexProjectPage { .init(projects: [], nextCursor: nil) }
  func tasks(cursor: String?, project: CodexProject?) -> CodexTaskPage { .init(tasks: [.init(id: thread, title: "Математика", cwd: "/tmp")], nextCursor: nil, defaultProviderNeedsSignIn: needsSignIn) }
  func history(threadID: String, cursor: String?) -> CodexHistoryPage { .init(messages: accepted, nextCursor: nil) }
  func create(directory: URL, title: String, workspaceID: UUID, project: CodexProject?, onCreated: @escaping @Sendable (CodexTask) async throws -> Void) async throws -> CodexTask {
    if slowCreation { try await Task.sleep(for: .seconds(5)) }
    if needsSignIn { throw CodexBridgeError.signInRequired }
    let task = CodexTask(id: thread, title: title, cwd: directory.path)
    try await onCreated(task)
    if failsCreationSetup { throw CodexBridgeError.disconnected }
    return task
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

  func testUncertainSettingsCannotStarveNarrowerAccessOrStop() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native)
      let old = NotebookChatInput(author: peer, action: .setAccess(threadID: native.thread, mode: .full))
      _ = try store.saveChatInput(old)
      _ = try store.advanceChatJob(old.id, from: .saved, to: .attempting)
      _ = try store.advanceChatJob(old.id, from: .attempting, to: .uncertain)
      let narrow = NotebookChatInput(author: peer, action: .setAccess(threadID: native.thread, mode: .readOnly))
      let stop = NotebookChatInput(author: peer, action: .stop(threadID: native.thread, turnID: native.turn))
      _ = await service.receive(.init(body: .request(.job(narrow))), peerID: peer)
      _ = await service.receive(.init(body: .request(.job(stop))), peerID: peer)
      service.start()
      try await wait { try await queue.submit { try $0.chatJob(stop.id)?.state == .accepted && $0.chatJob(narrow.id)?.state == .accepted } }
      XCTAssertEqual(try store.chatJob(old.id)?.state, .uncertain)
      let mode = await native.accessMode, stops = await native.counts().1
      XCTAssertEqual(mode, .readOnly); XCTAssertEqual(stops, 1)
      await service.stop()
    }
  }
  func testCreatedNativeIDSurvivesFailureOfAdditionalSetup() async throws {
    try await fixture { store, queue, native, peer in
      await native.failCreationSetup()
      let service = try sidecar(store, queue, native)
      let input = NotebookChatInput(author: peer, action: .create(title: "Task"))
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer); service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      let job = try XCTUnwrap(store.chatJob(input.id))
      XCTAssertEqual(job.createdTask?.id, native.thread); XCTAssertNotNil(job.error)
      if case .created(let task) = job.result { XCTAssertEqual(task.id, native.thread) } else { XCTFail("Lost native identity") }
      await service.stop()
    }
  }

  func testRevocationBeforeAdmissionRejectsRunAndVoiceButDoesNotUndoAcceptedWork() async throws {
    try await fixture { store, queue, native, peer in
      let computer = UUID()
      let service = NotebookCodexSidecar(persistence: queue, bridge: native, metadata: native,
        workspaceID: try store.workspaceHeader().workspaceID, computerID: computer, directory: store.root)
      let actions: [NotebookChatAction] = [
        .startRun(.init(root: .init(computer: computer, project: "p", root: "/tmp", path: ""), command: "fixture")),
        .startVoice(.init(threadID: native.thread, sdp: "v=0\r\noffer"))]
      for action in actions {
        service.allowDevice(peer)
        let gate = AdmissionGate()
        service.accountIdentity = { await gate.wait(); return nil }
        let input = NotebookChatInput(author: peer, action: action)
        let receiving = Task { await service.receive(.init(body: .request(.job(input))), peerID: peer) }
        try await wait { gate.entered }
        service.revokeDevice(peer); gate.release()
        _ = await receiving.value
        XCTAssertNil(try store.chatJob(input.id))
      }
      let starts = await native.processStarts, voiceStarts = await native.voiceStarts
      XCTAssertEqual(starts, 0); XCTAssertEqual(voiceStarts, 0)
      service.allowDevice(peer); service.accountIdentity = nil
      let accepted = NotebookChatInput(author: peer, action: actions[0])
      _ = await service.receive(.init(body: .request(.job(accepted))), peerID: peer)
      service.revokeDevice(peer)
      let flushed = await queue.flush(); XCTAssertTrue(flushed)
      XCTAssertEqual(try store.chatJob(accepted.id)?.state, .accepted)
      let after = await native.processStarts; XCTAssertEqual(after, 1)
      await service.stop()
    }
  }

  func testExplicitSteeringBypassesQueuedMessageButKeepsTheExpectedTurn() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(busy: true)
      let service = try sidecar(store, queue, native)
      let queued = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "next", context: ""))
      let steering = NotebookChatInput(author: peer, action: .steer(threadID: native.thread, turnID: native.turn, text: "clarify", context: "fragment"))
      _ = await service.receive(.init(body: .request(.job(queued))), peerID: peer)
      _ = await service.receive(.init(body: .request(.job(steering))), peerID: peer)
      service.start()
      try await wait { try await queue.submit { try $0.chatJob(steering.id)?.state == .accepted } }
      XCTAssertEqual(try store.chatJob(queued.id)?.state, .saved)
      let count = await native.counts(); XCTAssertEqual(count.0, 1)
      let stale = NotebookChatInput(author: peer, action: .steer(threadID: native.thread, turnID: UUID().uuidString, text: "late", context: ""))
      _ = await service.receive(.init(body: .request(.job(stale))), peerID: peer)
      try await wait { try await queue.submit { try $0.chatJob(stale.id)?.state == .rejected } }
      let final = await native.counts(); XCTAssertEqual(final.0, 1)
      await service.stop()
    }
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

  func testModelChangeAndMentionedInputKeepTheirNativeIdentityAfterUnknownReplies() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(unknown: true)
      let service = try sidecar(store, queue, native)
      let selection = CodexModelSelection(model: "fixture", effort: "high")
      let change = NotebookChatInput(author: peer, action: .setModel(threadID: native.thread, selection: selection))
      _ = await service.receive(.init(body: .request(.job(change))), peerID: peer); service.start()
      try await wait { try await queue.submit { try $0.chatJob(change.id)?.state == .accepted } }
      _ = await service.receive(.init(body: .request(.job(change))), peerID: peer)
      let changes = await native.modelChanges; XCTAssertEqual(changes, 1)
      let attachment = CodexInputAttachment(kind: .plugin, name: "plugin", path: "plugin://plugin@market")
      let message = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "Use it", context: ""), attachments: [attachment])
      _ = await service.receive(.init(body: .request(.job(message))), peerID: peer)
      try await wait { try await queue.submit { try $0.chatJob(message.id)?.state == .accepted } }
      _ = await service.receive(.init(body: .request(.job(message))), peerID: peer)
      let sent = await native.counts(), attached = await native.submittedAttachments
      XCTAssertEqual(sent.0, 1); XCTAssertEqual(attached, [attachment])
      await service.stop()
    }
  }

  func testAccessChangeReconcilesNativeStateWithoutRepeatingTheGrant() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(unknown: true)
      let service = try sidecar(store, queue, native)
      let input = NotebookChatInput(author: peer, action: .setAccess(threadID: native.thread, mode: .full))
      let request = NotebookChatEnvelope(body: .request(.job(input)))
      _ = await service.receive(request, peerID: peer); service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      _ = await service.receive(request, peerID: peer)
      let changes = await native.accessChanges, turns = await native.counts()
      XCTAssertEqual(changes, 1); XCTAssertEqual(turns.0, 0)
      XCTAssertEqual(try store.chatJob(input.id)?.result, .acknowledged)
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
  func testFileQueriesUseCurrentProjectAndExistingDurableQueueWithoutAModel() async throws {
    try await fixture { store, queue, native, peer in
      let root = store.root.appendingPathComponent("code"), computer = UUID()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let project = try await native.updateProject(.init(id: "code", name: "Code", roots: [root.path]))
      let address = NotebookFileAddress(computer: computer, project: project.id, root: root.path, path: "run.py")
      let file = root.appendingPathComponent("run.py"); try Data("print(2)\n".utf8).write(to: file)
      let service = NotebookCodexSidecar(persistence: queue, bridge: native, metadata: native,
        workspaceID: try store.workspaceHeader().workspaceID, computerID: computer, directory: root)
      let read = await service.receive(.init(body: .request(.file(.read(address, version: nil, offset: 0)))), peerID: peer)
      guard case .reply(.file(.part(let part))) = read?.body else { return XCTFail("Expected file bytes") }
      XCTAssertEqual(String(decoding: part.data, as: UTF8.self), "print(2)\n")
      let payload = try JSONEncoder().encode(NotebookFileEdit(address: address, base: "print(2)\n", text: "print(4)\n")), id = UUID()
      let chunk = NotebookFileUpload(id: id, digest: NotebookFileVersion.hash(payload), total: payload.count, offset: 0, data: payload)
      _ = await service.receive(.init(body: .request(.file(.upload(chunk)))), peerID: peer)
      let input = NotebookChatInput(id: id, author: peer, action: .saveFile(address))
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      service.start()
      try await wait { try await queue.submit { try $0.chatJob(id)?.state == .accepted } }
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "print(4)\n")
      try Data("newer\n".utf8).write(to: file)
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer\n")
      let counts = await native.counts(); XCTAssertEqual(counts.0, 0)
      _ = try await native.updateProject(.init(id: project.id, name: nil, roots: []))
      let revoked = await service.receive(.init(body: .request(.file(.read(address, version: part.version, offset: 0)))), peerID: peer)
      guard case .reply(.failure) = revoked?.body else { await service.stop(); return XCTFail("Revocation must also deny cached versions") }
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
      XCTAssertEqual(try store.chatJob(input.id)?.error, "Войдите в Codex через настройки аккаунта Notebook.")
      await native.requireSignIn(false)
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      XCTAssertEqual(try store.chatJob(input.id)?.state, .rejected, "Sign-in never silently replays a rejected creation")
      let next = NotebookChatInput(author: peer, action: .create(title: "Математика"))
      _ = await service.receive(.init(body: .request(.job(next))), peerID: peer)
      try await wait { try await queue.submit { try $0.chatJob(next.id)?.state == .accepted } }
      await service.stop()
    }
  }

  func testDetachingViewDoesNotStopAnAdmittedTaskAndSlowCreationDoesNotBlockAnotherThread() async throws {
    try await fixture { store, queue, native, peer in
      await native.delayCreation()
      let service = try sidecar(store, queue, native)
      let create = NotebookChatInput(author: peer, action: .create(title: "slow"))
      let message = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "independent", context: ""))
      _ = await service.receive(.init(body: .request(.job(create))), peerID: peer)
      _ = await service.receive(.init(body: .request(.job(message))), peerID: peer)
      service.start(); service.detachView()
      try await wait { try await queue.submit { try $0.chatJob(message.id)?.state == .accepted } }
      XCTAssertEqual(try store.chatJob(create.id)?.state, .attempting)
      let count = await native.counts(); XCTAssertEqual(count.0, 1)
      await service.stop()
    }
  }

  func testRevocationRejectsSavedInputBeforeItCanSurviveRestart() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native)
      let message = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "must not execute", context: ""))
      _ = await service.receive(.init(body: .request(.job(message))), peerID: peer)
      service.authorizePeer = { _ in false }; service.start()
      try await wait { try await queue.submit { try $0.chatJob(message.id)?.state == .rejected } }
      let count = await native.counts(); XCTAssertEqual(count.0, 0)
      await service.stop()
    }
  }

}

@MainActor private final class AdmissionGate {
  var entered = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
  func release() { continuation?.resume(); continuation = nil }
}
