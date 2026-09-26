import XCTest
import CryptoKit
import NotebookCore
import NotebookCodex
@testable import Notebook

private actor NativeOwner: NotebookCodexConversationOwner, NotebookCodexCatalogueOwner, NotebookCodexProcessOwner, NotebookCodexVoiceOwner {
  enum AttachFailure { case requestRejected, externalOwner, unavailable }
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
  var attachFailure: AttachFailure?
  var projectEdits = 0
  var project: CodexProject?
  var accessMode = CodexAccessMode.workspace
  var model = CodexModelSelection(model: "fixture", effort: "low")
  var modelChanges = 0
  var pendingRequests: [CodexUserRequest] = []
  var submittedAttachments: [CodexInputAttachment] = []
  var accessChanges = 0
  var sent: [UUID] = [], interrupted: [String] = [], decisions: [CodexUserDecision] = []
  var accepted: [CodexMessage] = []
  func setMessages(_ messages: [CodexMessage]) { accepted = messages }
  var stopIsStale = false
  var needsSignIn = false
  var slowCreation = false
  var failsCreationSetup = false
  func failCreationSetup() { failsCreationSetup = true }
  func delayCreation() { slowCreation = true }
  func requireSignIn(_ required: Bool) { needsSignIn = required }
  func finishBeforeStop() { stopIsStale = true }
  func configure(busy: Bool = false, unknown: Bool = false) { self.busy = busy; self.unknown = unknown }
  func failAttach(_ failure: AttachFailure?) { attachFailure = failure }
  var observations: [String: Set<UUID>] = [:]
  var snapshotGate: AdmissionGate?
  func holdSnapshot(_ gate: AdmissionGate?) { snapshotGate = gate }
  var snapshotEntries = 0
  func snapshotCount() -> Int { snapshotEntries }
  var attachGate: AdmissionGate?
  func holdAttach(_ gate: AdmissionGate?) { attachGate = gate }
  func observationCount() -> Int { observations.values.reduce(0) { $0 + $1.count } }
  func counts() -> (Int, Int) { (sent.count, interrupted.count) }
  func attach(threadID: String, observationID: UUID) async throws {
    switch attachFailure {
    case .requestRejected: throw CodexRequestRejection(code: -32600)
    case .externalOwner: throw CodexBridgeError.externalOwnerUnavailable
    case .unavailable: throw CodexBridgeError.unavailable
    case nil: break
    }
    observations[threadID, default: []].insert(observationID)
    if let gate = attachGate { await gate.wait() }
    guard observations[threadID]?.contains(observationID) == true else { throw CancellationError() }
  }
  func detach(threadID: String, observationID: UUID) { observations[threadID]?.remove(observationID) }
  func close() { }
  func snapshot(threadID: String) async -> CodexConversation? {
    snapshotEntries += 1
    if let snapshotGate { await snapshotGate.wait() }
    return .init(threadID: threadID, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Математика", ready: true, busy: busy, activeTurnID: busy ? turn : nil,
      messages: accepted, requests: pendingRequests, acceptedMessages: [:], turnStatuses: [:],
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
  func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) { decisions.append(decision); pendingRequests.removeAll { $0 == request } }
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
  func largeRequests() -> [CodexUserRequest] {
    pendingRequests = (1...4).map { .init(nativeID: .number(Double($0)),
      generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
      method: "item/permissions/requestApproval", turnID: turn,
      parameters: .object(["permissions": .object(["fixture": .string(String(repeating: "x", count: 60_000))])])) }
    return pendingRequests
  }
  func models() -> [CodexModelOption] { [.init(id: "fixture", name: "Fixture", efforts: ["low", "high"], defaultEffort: "low")] }
  func resources(threadID: String, kind: CodexResourceKind, cursor: String?) -> CodexResourcePage { .init(resources: []) }
  func projects(cursor: String?) -> CodexProjectPage { .init(projects: [], nextCursor: nil) }
  func tasks(cursor: String?, project: CodexProject?) -> CodexTaskPage { .init(tasks: [.init(id: thread, title: "Математика", cwd: "/tmp")], nextCursor: nil, defaultProviderNeedsSignIn: needsSignIn) }
  func history(threadID: String, cursor: String?, turnID: String?) -> CodexHistoryPage { .init(messages: accepted, nextCursor: nil) }
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
  func testStartupStorageFailureRetriesRecoveryWithoutAnotherUserEvent() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native)
      let input = NotebookChatInput(author: peer,
        action: .send(threadID: native.thread, text: "Saved before startup", context: ""))
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      let permit = store.root.appendingPathComponent("allow-startup")
      queue.enqueue { _ in _ = try Data(contentsOf: permit); return false }
      let blocked = await queue.flush(); XCTAssertFalse(blocked)
      service.start()
      try await Task.sleep(for: .milliseconds(100))
      let before = await native.counts().0; XCTAssertEqual(before, 0)
      try Data().write(to: permit)
      queue.retry()
      let recovered = await queue.flush(); XCTAssertTrue(recovered)
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      let sent = await native.counts().0; XCTAssertEqual(sent, 1)
      await service.stop()
    }
  }

  func testNewlyAdmittedMessageWakesTheNativeWorkerWithoutThePollingSecond() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native); service.start()
      try await Task.sleep(for: .milliseconds(150))
      let input = NotebookChatInput(author: peer,
        action: .send(threadID: native.thread, text: "Immediate", context: ""))
      let started = ContinuousClock.now
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      let deadline = started + .milliseconds(650)
      while await native.counts().0 == 0, .now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let sent = await native.counts().0
      XCTAssertEqual(sent, 1)
      XCTAssertLessThan(started.duration(to: .now), .milliseconds(700))
      await service.stop()
    }
  }

  func testDetachDuringInitialUnsubscribedMessageReadCannotRestoreTransfer() async throws {
    try await fixture { store,queue,native,peer in
      let gate = AdmissionGate()
      let message = CodexMessage(id:"held",turnID:native.turn,clientID:nil,role:.assistant,text:"exact")
      await native.setMessages([message]); await native.holdSnapshot(gate)
      let service = try sidecar(store,queue,native)
      let reading = Task { await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id)))),peerID:peer) }
      try await wait { await native.snapshotCount() == 1 }
      service.detachView(); gate.release()
      let response = await reading.value
      guard case .reply(.failure) = response?.body else { return XCTFail("A late initial read must not reinstall a detached transfer") }
      await service.stop()
    }
  }

  func testOneLongNativeMessageReadsInBoundedPartsAndCloseRevokesTransfer() async throws {
    try await fixture { store,queue,native,peer in
      let message = CodexMessage(id:"long",turnID:native.turn,clientID:nil,role:.assistant,
        text:String(repeating:"Полный native ответ🙂 ",count:20_000)).identifyingContent()
      await native.setMessages([message])
      let service = try sidecar(store,queue,native)
      var assembly = CodexMessageAssembly(), complete: CodexMessage?
      repeat {
        let query = CodexMessageRead(threadID:native.thread,turnID:native.turn,messageID:message.id,
          transferID:assembly.transferID,offset:assembly.offset)
        let response = await service.receive(.init(body:.request(.message(query))),peerID:peer)
        guard case .reply(.message(.part(let part))) = response?.body else { return XCTFail("Missing exact message part") }
        XCTAssertTrue(response?.isValid(from:peer) == true)
        if try assembly.append(part) { complete = try assembly.decode() }
      } while complete == nil
      XCTAssertEqual(complete?.text,message.text)
      service.detachView()
      let retired = CodexMessageRead(threadID:native.thread,turnID:native.turn,messageID:message.id,
        transferID:assembly.transferID,offset:0)
      let response = await service.receive(.init(body:.request(.message(retired))),peerID:peer)
      guard case .reply(.failure) = response?.body else { return XCTFail("Detached reading cannot retain the old transfer") }
      await service.stop()
    }
  }

  func testRepeatedInitialMessageEnvelopeKeepsExactTransferAcrossNativeGrowth() async throws {
    try await fixture { store,queue,native,peer in
      let message = CodexMessage(id:"retry-head",turnID:native.turn,clientID:nil,role:.assistant,
        text:String(repeating:"Original🙂",count:12_000)).identifyingContent()
      let newer = CodexMessage(id:message.id,turnID:native.turn,clientID:nil,role:.assistant,
        text:message.text + "New native tail").identifyingContent()
      await native.setMessages([message])
      let service = try sidecar(store,queue,native)
      let query = CodexMessageRead(threadID:native.thread,turnID:native.turn,messageID:message.id)
      let initial = NotebookChatEnvelope(body:.request(.message(query)))
      let first = await service.receive(initial,peerID:peer)
      guard case .reply(.message(.part(let head))) = first?.body else { return XCTFail("Missing initial part") }
      let readsBefore = await native.snapshotCount()
      await native.setMessages([newer])
      let replay = await service.receive(initial,peerID:peer)
      guard case .reply(.message(.part(let replayed))) = replay?.body else { return XCTFail("Missing repeated initial part") }
      XCTAssertEqual(replayed.transferID,head.transferID)
      XCTAssertEqual(replayed.digest,head.digest); XCTAssertEqual(replayed.contentRevision,head.contentRevision)
      XCTAssertTrue(replayed.data == head.data,"Repeated part zero is the exact frozen bytes, not a new native read")
      let readsAfter = await native.snapshotCount(); XCTAssertEqual(readsAfter,readsBefore)
      var assembly = CodexMessageAssembly(); XCTAssertFalse(try assembly.append(head))
      while assembly.offset < head.totalBytes {
        let response = await service.receive(.init(body:.request(.message(.init(
          threadID:native.thread,turnID:native.turn,messageID:message.id,
          transferID:head.transferID,offset:assembly.offset)))),peerID:peer)
        guard case .reply(.message(.part(let part))) = response?.body else { return XCTFail("An initial retry revoked the issued continuation") }
        _ = try assembly.append(part)
      }
      XCTAssertTrue(try assembly.decode().text == message.text,"All parts remain the first immutable native revision")
      let replacement = await service.receive(.init(body:.request(.message(query))),peerID:peer)
      guard case .reply(.message(.part(let next))) = replacement?.body else { return XCTFail("A new envelope must start a new transfer") }
      XCTAssertNotEqual(next.transferID,head.transferID); XCTAssertEqual(next.contentRevision,newer.contentRevision)
      let stale = await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id,transferID:head.transferID,offset:0)))),peerID:peer)
      guard case .reply(.failure) = stale?.body else { return XCTFail("A deliberate new transfer must retire the previous continuation") }
      await service.stop()
    }
  }

  func testMessageReadEnvelopeIdentityIsPeerScopedAndRevokedWithItsOwner() async throws {
    try await fixture { store,queue,native,peer in
      let message = CodexMessage(id:"peer-head",turnID:native.turn,clientID:nil,role:.assistant,
        text:String(repeating:"Peer-local exact body",count:5000)).identifyingContent()
      await native.setMessages([message])
      let service = try sidecar(store,queue,native), otherPeer = UUID()
      let initial = NotebookChatEnvelope(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id))))
      let a = await service.receive(initial,peerID:peer), b = await service.receive(initial,peerID:otherPeer)
      guard case .reply(.message(.part(let headA))) = a?.body,
        case .reply(.message(.part(let headB))) = b?.body else { return XCTFail("Missing peer-local heads") }
      XCTAssertNotEqual(headA.transferID,headB.transferID)
      // Reuse of an envelope UUID with another payload is not an intentional
      // replacement; the original peer-local transfer must remain intact.
      let collision = await service.receive(.init(id:initial.id,body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:"different")))),peerID:peer)
      guard case .reply(.failure) = collision?.body else { return XCTFail("Same envelope cannot acquire another message") }
      let replay = await service.receive(initial,peerID:peer)
      guard case .reply(.message(.part(let headAgain))) = replay?.body else { return XCTFail("Collision destroyed the original transfer") }
      XCTAssertEqual(headAgain.transferID,headA.transferID)
      service.revokeDevice(peer); service.allowDevice(peer)
      let retired = await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id,
        transferID:headA.transferID,offset:headA.data.count)))),peerID:peer)
      guard case .reply(.failure) = retired?.body else { return XCTFail("A previous authorization generation retained its transfer") }
      let continuation = await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id,
        transferID:headB.transferID,offset:headB.data.count)))),peerID:otherPeer)
      guard case .reply(.message(.part(let nextB))) = continuation?.body else { return XCTFail("Revoking one peer revoked another reader") }
      XCTAssertEqual(nextB.transferID,headB.transferID)
      let reopened = await service.receive(initial,peerID:peer)
      guard case .reply(.message(.part(let fresh))) = reopened?.body else { return XCTFail("New authorization could not admit a fresh read") }
      XCTAssertNotEqual(fresh.transferID,headA.transferID)
      await service.stop()
    }
  }

  func testSameThreadRefreshRetainsObservationAndExactMessageTransfer() async throws {
    try await fixture { store,queue,native,peer in
      let message = CodexMessage(id:"refresh",turnID:native.turn,clientID:nil,role:.assistant,
        text:String(repeating:"Exact continuing body🙂 ",count:5000)).identifyingContent()
      await native.setMessages([message])
      let service = try sidecar(store,queue,native)
      let initial = NotebookChatEnvelope(body:.request(.conversation(threadID:native.thread)))
      _ = await service.receive(initial,peerID:peer)
      let before = await native.observations
      let first = await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id)))),peerID:peer)
      guard case .reply(.message(.part(let head))) = first?.body else { return XCTFail("Missing initial part") }
      var assembly = CodexMessageAssembly(); XCTAssertFalse(try assembly.append(head))
      let refresh = NotebookChatEnvelope(body:.request(.conversation(threadID:native.thread)))
      let refreshed = await service.receive(refresh,peerID:peer)
      guard case .reply(.conversation) = refreshed?.body else { return XCTFail("Same-thread refresh failed") }
      let after = await native.observations
      XCTAssertEqual(after[native.thread],before[native.thread],"Refresh retains the exact observation token")
      repeat {
        let response = await service.receive(.init(body:.request(.message(.init(
          threadID:native.thread,turnID:native.turn,messageID:message.id,
          transferID:assembly.transferID,offset:assembly.offset)))),peerID:peer)
        guard case .reply(.message(.part(let part))) = response?.body else { return XCTFail("Refresh revoked an ongoing transfer") }
        if try assembly.append(part) { break }
      } while true
      XCTAssertEqual(try assembly.decode().text,message.text)
      await service.stop()
    }
  }

  func testInitialConversationPreservesAnUnsubscribedSameThreadMessageRead() async throws {
    try await fixture { store,queue,native,peer in
      let message = CodexMessage(id:"initial",turnID:native.turn,clientID:nil,role:.assistant,
        text:String(repeating:"Frozen",count:20_000)).identifyingContent()
      await native.setMessages([message])
      let service = try sidecar(store,queue,native), gate = AdmissionGate()
      await native.holdSnapshot(gate)
      let reading = Task { await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id)))),peerID:peer) }
      try await wait { gate.entered }
      await native.holdSnapshot(nil)
      _ = await service.receive(.init(body:.request(.conversation(threadID:native.thread))),peerID:peer)
      gate.release()
      let first = await reading.value
      guard case .reply(.message(.part(let part))) = first?.body else { return XCTFail("Opening revoked the pending same-thread read") }
      let next = await service.receive(.init(body:.request(.message(.init(
        threadID:native.thread,turnID:native.turn,messageID:message.id,
        transferID:part.transferID,offset:part.data.count)))),peerID:peer)
      guard case .reply(.message(.part)) = next?.body else { return XCTFail("Opening the same conversation revoked its earlier content read") }
      await service.stop()
    }
  }

  func testActualConversationLifetimeChangesRevokeMessageTransfers() async throws {
    for end in ["switch","close","revoke","detach"] {
      try await fixture { store,queue,native,peer in
        let message = CodexMessage(id:"retired",turnID:native.turn,clientID:nil,role:.assistant,
          text:String(repeating:"Retained",count:20_000)).identifyingContent()
        await native.setMessages([message])
        let service = try sidecar(store,queue,native)
        _ = await service.receive(.init(body:.request(.conversation(threadID:native.thread))),peerID:peer)
        let first = await service.receive(.init(body:.request(.message(.init(
          threadID:native.thread,turnID:native.turn,messageID:message.id)))),peerID:peer)
        guard case .reply(.message(.part(let part))) = first?.body else { return XCTFail("Missing initial part") }
        switch end {
        case "switch": _ = await service.receive(.init(body:.request(.conversation(threadID:UUID().uuidString))),peerID:peer)
        case "close": _ = await service.receive(.init(body:.request(.activity(threadIDs:[]))),peerID:peer)
        case "revoke": service.revokeDevice(peer)
        default: service.detachView()
        }
        let response = await service.receive(.init(body:.request(.message(.init(
          threadID:native.thread,turnID:native.turn,messageID:message.id,
          transferID:part.transferID,offset:part.data.count)))),peerID:peer)
        if end == "revoke" { XCTAssertNil(response) }
        else if case .reply(.failure) = response?.body { }
        else { XCTFail("\(end) retained the previous conversation's transfer") }
        await service.stop()
      }
    }
  }

  func testNativeIdleEventWakesAQueuedNextMessage() async throws {
    try await fixture { store, queue, native, peer in
      await native.configure(busy: true)
      let service = try sidecar(store, queue, native); service.start()
      let input = NotebookChatInput(author: peer,
        action: .send(threadID: native.thread, text: "Next", context: ""))
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      try await Task.sleep(for: .milliseconds(150))
      XCTAssertEqual(try store.chatJob(input.id)?.state, .saved)
      await native.configure(busy: false)
      let snapshot = await native.snapshot(threadID: native.thread)
      let state = try XCTUnwrap(snapshot)
      let started = ContinuousClock.now
      service.receiveEvent(.conversation(state))
      let deadline = started + .milliseconds(650)
      while await native.counts().0 == 0, .now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let sent = await native.counts().0
      XCTAssertEqual(sent, 1)
      XCTAssertLessThan(started.duration(to: .now), .milliseconds(700))
      await service.stop()
    }
  }

  func testClosingSwitchingRevokingAndDetachingReleaseExactObservations() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native); service.start()
      for _ in 0..<12 {
        _ = await service.receive(.init(body: .request(.conversation(threadID: UUID().uuidString))), peerID: peer)
        _ = await service.receive(.init(body: .request(.activity(threadIDs: []))), peerID: peer)
        try await wait { await native.observationCount() == 0 }
      }
      _ = await service.receive(.init(body: .request(.conversation(threadID: native.thread))), peerID: peer)
      service.detachView()
      try await wait { await native.observationCount() == 0 }
      _ = await service.receive(.init(body: .request(.conversation(threadID: native.thread))), peerID: peer)
      service.revokeDevice(peer)
      try await wait { await native.observationCount() == 0 }
      await service.stop()
    }
  }

  func testCloseDuringPreparationCannotResurrectObservation() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native), gate = AdmissionGate()
      service.prepareThread = { _ in await gate.wait() }
      let opening = Task { await service.receive(.init(body: .request(.conversation(threadID: native.thread))), peerID: peer) }
      try await wait { gate.entered }
      _ = await service.receive(.init(body: .request(.activity(threadIDs: []))), peerID: peer)
      gate.release(); _ = await opening.value
      let count = await native.observationCount(); XCTAssertEqual(count, 0)
      await service.stop()
    }
  }

  func testCloseDuringNativeAttachCannotReleaseTheReplacementView() async throws {
    try await fixture { store, queue, native, peer in
      let gate = AdmissionGate(), service = try sidecar(store, queue, native)
      await native.holdAttach(gate)
      let opening = Task { await service.receive(.init(body: .request(.conversation(threadID: native.thread))), peerID: peer) }
      try await wait { gate.entered }
      _ = await service.receive(.init(body: .request(.activity(threadIDs: []))), peerID: peer)
      try await wait { await native.observationCount() == 0 }
      await native.holdAttach(nil)
      let next = UUID().uuidString
      _ = await service.receive(.init(body: .request(.conversation(threadID: next))), peerID: peer)
      gate.release(); _ = await opening.value
      let count = await native.observationCount(); XCTAssertEqual(count, 1)
      let observations = await native.observations
      XCTAssertEqual(observations[next]?.count, 1)
      await service.stop()
      let stoppedCount = await native.observationCount(); XCTAssertEqual(stoppedCount, 0)
    }
  }

  func testIdleWorkerWakesForControlWithoutPollingInterval() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native); service.start()
      await native.configure(busy: true)
      try await Task.sleep(for: .milliseconds(150))
      let action = NotebookChatAction.stop(threadID: native.thread, turnID: native.turn)
      let input = NotebookChatInput(id: try XCTUnwrap(action.controlID(author: peer)), author: peer, action: action)
      let start = ContinuousClock.now
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      try await wait { await native.counts().1 == 1 }
      XCTAssertLessThan(start.duration(to: .now), .milliseconds(500), "No one-second scheduling gate")
      _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
      try await Task.sleep(for: .milliseconds(100))
      let counts = await native.counts(); XCTAssertEqual(counts.1, 1)
      await service.stop()
    }
  }

  func testDefinitiveObserveFailureRejectsSavedMessageWithoutNativeDispatch() async throws {
    try await fixture { store, queue, native, peer in
      let service = try sidecar(store, queue, native); service.start()
      for failure in [NativeOwner.AttachFailure.requestRejected, .externalOwner] {
        await native.failAttach(failure)
        let input = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "Not dispatched", context: ""))
        _ = await service.receive(.init(body: .request(.job(input))), peerID: peer)
        try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .rejected } }
        XCTAssertNotNil(try store.chatJob(input.id)?.error)
      }
      await native.failAttach(.unavailable)
      let transient = NotebookChatInput(author: peer, action: .send(threadID: native.thread, text: "Retry when available", context: ""))
      _ = await service.receive(.init(body: .request(.job(transient))), peerID: peer)
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(try store.chatJob(transient.id)?.state, .saved)
      let counts = await native.counts(); XCTAssertEqual(counts.0, 0)
      await service.stop()
    }
  }
  func testLaserEvidenceIsResolvedOnlyForItsOneNativeMessage() async throws {
    try await fixture { store, queue, native, peer in
      let reference = CollaborationReference(target:.init(kind:.page,id:UUID()),region:.init(x:0,y:0,width:1,height:1),revision:"frozen")
      let png = try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
      let image = try AgentPinnedImage(referenceID:reference.id,sourceRevision:reference.revision,region:reference.region!,
        worldOrigin:nil,pageIndex:nil,pixelWidth:1,pixelHeight:1,pixelsPerPoint:1,png:png,
        sha256:SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined())
      let attachments = try await queue.submit { try $0.saveChatImageAttachments([.init(reference:reference,image:image)],author:peer) }
      let service = try sidecar(store,queue,native)
      let input = NotebookChatInput(author:peer,action:.send(threadID:native.thread,text:"Show",context:""),attachments:attachments)
      _ = await service.receive(.init(body:.request(.job(input))),peerID:peer); service.start()
      try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      let received = await native.submittedAttachments
      XCTAssertEqual(received.first?.imagePNG,png)
      XCTAssertNil(try store.chatJob(input.id)?.input.attachments?.first?.imagePNG)
      let next = NotebookChatInput(author:peer,action:.send(threadID:native.thread,text:"Next",context:""))
      _ = await service.receive(.init(body:.request(.job(next))),peerID:peer)
      try await wait { try await queue.submit { try $0.chatJob(next.id)?.state == .accepted } }
      let after = await native.submittedAttachments; XCTAssertTrue(after.isEmpty)
      await service.stop()
    }
  }
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

  func testLargeRequestsStayAddressableAndEachDecisionExecutesOnce() async throws {
    try await fixture { store, queue, native, peer in
      let requests = await native.largeRequests()
      let service = try sidecar(store, queue, native); service.start()
      let envelope = await service.receive(.init(body: .request(.conversation(threadID: native.thread))), peerID: peer)
      guard case .reply(.conversation(let value)) = envelope?.body else { return XCTFail("Missing conversation") }
      XCTAssertEqual(value.requestIDs.count, 4); XCTAssertEqual(value.requests.count, 1)
      XCTAssertTrue(envelope!.isValid(from: peer))
      for request in requests {
        let detail = await service.receive(.init(body: .request(.requestDetails(threadID: native.thread, generation: value.generation, requestID: request.id))), peerID: peer)
        guard case .reply(.requestDetails(let actual)) = detail?.body else { return XCTFail("Lost full request") }
        XCTAssertEqual(actual, request); XCTAssertTrue(detail!.isValid(from: peer))
        let action = NotebookChatAction.respond(threadID: native.thread, request: actual, decision: .decline)
        let input = NotebookChatInput(id: try XCTUnwrap(action.controlID(author: peer)), author: peer, action: action)
        for _ in 0..<2 { _ = await service.receive(.init(body: .request(.job(input))), peerID: peer) }
        try await wait { try await queue.submit { try $0.chatJob(input.id)?.state == .accepted } }
      }
      let count = await native.decisions.count
      XCTAssertEqual(count, 4)
      let stale = await service.receive(.init(body: .request(.requestDetails(threadID: native.thread, generation: UUID(), requestID: requests[0].id))), peerID: peer)
      guard case .reply(.failure) = stale?.body else { return XCTFail("Old generation must not approve a new request") }
      await service.stop()
    }
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
