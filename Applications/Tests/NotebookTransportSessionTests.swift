import CryptoKit
import Foundation
import Network
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookTransportSessionTests: XCTestCase {
  func testPublicRelayKeepsControlResponsiveDuringLargeMaterialAndRevokesTheTunnel() async throws {
    guard let path = ProcessInfo.processInfo.environment["NOTEBOOK_TEST_RELAY_HOST_FILE"] else { throw XCTSkip("Explicit disposable relay route required") }
    let route = try JSONDecoder().decode(NotebookRelayRoute.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let ready = expectation(description: "Both Notebook sessions authenticated through public relay"); ready.expectedFulfillmentCount = 2
    let committed = expectation(description: "Large material committed once")
    func residentBytes() -> UInt64 {
      var value = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
      }
      return result == KERN_SUCCESS ? UInt64(value.resident_size) : 0
    }
    let baseline = residentBytes(); var peak = baseline
    let memory = Task { @MainActor in
      while !Task.isCancelled { peak = max(peak, residentBytes()); do { try await Task.sleep(for: .milliseconds(100)) } catch { return } }
    }
    let pair = try NotebookTransportTestPair(withChange: true, relay: route, contentBytes: 8 * 1024 * 1024)
    defer { pair.stop(); memory.cancel() }
    await pair.clientStorage.setAcknowledgementObserver { committed.fulfill() }
    pair.onReady = { _, _ in ready.fulfill() }
    pair.onFailure = { error in XCTFail("Public relay session: \(error)") }
    try pair.start(); await fulfillment(of: [ready], timeout: 30)
    var latencies: [Double] = []
    for _ in 0..<10 {
      let delivered = expectation(description: "Control crosses the active bulk transfer")
      let envelope = NotebookChatEnvelope(body: .request(.account(.read)))
      let began = ContinuousClock.now
      pair.onTransient = { value, peer in
        guard case .codex(let received) = value, received.id == envelope.id else { return }
        if peer.deviceID == pair.clientIdentity.deviceID { pair.server?.sendTransient(.codex(.init(id: received.id, body: .reply(.acknowledged)))) }
        else {
          let duration = began.duration(to: .now).components
          latencies.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
          delivered.fulfill()
        }
      }
      pair.client?.sendTransient(.codex(envelope))
      await fulfillment(of: [delivered], timeout: 5)
    }
    await fulfillment(of: [committed], timeout: 240)
    let count = await pair.serverStorage.appliedCount, size = await pair.serverStorage.largestStagedBlob
    XCTAssertEqual(count, 1); XCTAssertEqual(size, 8 * 1024 * 1024)
    let revoked = expectation(description: "Relay revocation closes active stream")
    pair.onFailure = nil
    pair.client?.onStop = { _, _ in revoked.fulfill() }
    _ = try await NotebookRelayHTTP.request(route, role: "host", action: "revoke", as: NotebookRelayHTTP.Enrollment.self)
    await fulfillment(of: [revoked], timeout: 10)
    latencies.sort(); guard latencies.count == 10 else { return XCTFail("Missing control receipts") }
    let evidence: [String: Any] = ["payloadBytes": 8 * 1024 * 1024, "appliedCount": count,
      "controlMilliseconds": latencies, "p50Milliseconds": latencies[5], "p95Milliseconds": latencies[9],
      "baselineResidentBytes": baseline, "peakResidentBytes": peak, "revoked": true,
      "scope": "Simulator and Mac network stack via public relay; not two physical networks"]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "gui183-relay-metrics.json"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testSelectionAndUnavailableSceneUseTheExistingAuthenticatedTransientLane() async throws {
    let ready = expectation(description: "Both existing TLS peers ready"); ready.expectedFulfillmentCount = 2
    let selected = expectation(description: "Exact selected physical owner delivered")
    let unavailable = expectation(description: "Inactive scene is unknown, not a stale selection")
    let pair = try NotebookTransportTestPair()
    defer { pair.stop() }
    let session = UUID(), target = CollaborationTarget(kind: .page, id: UUID())
    let choice = NotebookSelection(id: UUID(), kind: .element, surface: target, target: target, elementID: "after-preview-window")
    pair.onReady = { _, _ in ready.fulfill() }
    pair.onTransient = { value, peer in
      guard case .selection(let publication) = value else { return XCTFail("Expected selection transient") }
      XCTAssertEqual(peer.deviceID, pair.clientIdentity.deviceID)
      XCTAssertEqual(publication.deviceID, peer.deviceID)
      XCTAssertEqual(publication.sessionID, session)
      if publication.sequence == 1 { XCTAssertEqual(publication.selection, choice); selected.fulfill() }
      else { XCTAssertEqual(publication.sequence, 2); XCTAssertNil(publication.selection); unavailable.fulfill() }
    }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    pair.client?.sendTransient(.selection(.init(deviceID: pair.clientIdentity.deviceID,
      sessionID: session, sequence: 1, selection: choice)))
    await fulfillment(of: [selected], timeout: 5)
    pair.client?.sendTransient(.selection(.init(deviceID: pair.clientIdentity.deviceID,
      sessionID: session, sequence: 2, selection: nil)))
    await fulfillment(of: [unavailable], timeout: 5)
  }

  func testImmediateJournalBoundaryStopsBothEndsWithTheSameReason() async throws {
    let rejected = expectation(description: "Both peers know why exchange stopped"); rejected.expectedFulfillmentCount = 2
    let source = NotebookTransportMemoryStore(journalRequirement: .checkpoint)
    let pair = try NotebookTransportTestPair(serverStorage: source)
    defer { pair.stop() }
    var stopped: Set<UUID> = []
    pair.onStopped = { identity, error in
      XCTAssertTrue(stopped.insert(identity.deviceID).inserted)
      XCTAssertEqual((error as? CollaborationError)?.code, "format_checkpoint_required")
      rejected.fulfill()
    }
    try pair.start()
    await fulfillment(of: [rejected], timeout: 10)
    XCTAssertFalse(pair.server?.isReady == true); XCTAssertFalse(pair.client?.isReady == true)
    let cursor = await source.acknowledgedCursor, applied = await pair.clientStorage.appliedCount
    XCTAssertEqual(cursor, 0); XCTAssertEqual(applied, 0)
  }

  func testFormatRefusalReachesThePairedDeviceBeforeClosingWithoutAcknowledgement() async throws {
    let ready = expectation(description: "Pair ready"); ready.expectedFulfillmentCount = 2
    let rejected = expectation(description: "Peer receives the actual checkpoint requirement")
    let pair = try NotebookTransportTestPair()
    defer { pair.stop() }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    client.onStop = { peer, error in
      XCTAssertEqual(peer?.deviceID, pair.serverIdentity.deviceID)
      XCTAssertEqual((error as? CollaborationError)?.code, "format_checkpoint_required")
      rejected.fulfill()
    }
    server.stop(NotebookTransportContentRequirement.checkpoint.error)
    await fulfillment(of: [rejected], timeout: 5)
    XCTAssertFalse(server.isReady); XCTAssertFalse(client.isReady)
  }

  func testFixedTLSProfileAuthenticatesAndNegotiatesTheExactPFSSuite() async throws {
    let ready = expectation(description: "Both authenticated TLS sessions ready"); ready.expectedFulfillmentCount = 2
    let peer = try NotebookTransportTestPair()
    defer { peer.stop() }
    peer.onReady = { _, _ in ready.fulfill() }
    try peer.start()
    await fulfillment(of: [ready], timeout: 10)
    XCTAssertTrue(peer.server?.isReady == true)
    XCTAssertTrue(peer.client?.isReady == true)
    // Session readiness is reachable only after TLS metadata accepts exactly
    // 1.2 / 0xCCAC, PSK proof and saved account authorization.
  }

  func testCodexEnvelopeUsesTheSameAuthenticatedPeerAndReceiptID() async throws {
    let ready = expectation(description: "Existing pair ready"); ready.expectedFulfillmentCount = 2
    let received = expectation(description: "Receipt, event, and audio returned through TLS"); received.expectedFulfillmentCount = 3
    let pair = try NotebookTransportTestPair()
    defer { pair.stop() }
    let input = NotebookChatInput(author: pair.clientIdentity.deviceID,
      action: .send(threadID: UUID().uuidString, text: "x² ≥ 0", context: ""))
    let envelope = NotebookChatEnvelope(body: .request(.job(input)))
    let recording = UUID(), audio = Data(repeating: 0xA7, count: NotebookDictationRecording.chunkBytes)
    let chunk = NotebookChatEnvelope(body: .request(.dictation(.append(id: recording, offset: 0, bytes: audio))))
    pair.onReady = { _, _ in ready.fulfill() }
    pair.onTransient = { value, peer in
      guard case .codex(let value) = value else { return XCTFail("Expected the chat lane") }
      switch value.body {
      case .request(.job(let actual)):
        XCTAssertEqual(value.id, envelope.id)
        XCTAssertEqual(actual, input); XCTAssertEqual(peer.deviceID, input.author)
        pair.server?.sendTransient(.codex(.init(id: value.id, body: .reply(.job(.init(input: actual))))))
      case .reply(.job(let job)):
        XCTAssertEqual(value.id, envelope.id)
        XCTAssertEqual(job.input, input); XCTAssertNotEqual(peer.deviceID, input.author); received.fulfill()
        let state = CodexConversation(threadID: input.action.threadID!, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 4, title: "Task", ready: true,
          busy: false, activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:])
        pair.server?.sendTransient(.codex(.init(body: .event(subscriptionID: envelope.id, conversation: state))))
      case .event(let subscription, let state):
        XCTAssertEqual(subscription, envelope.id); XCTAssertEqual(state.revision, 4)
        XCTAssertNotEqual(peer.deviceID, input.author); received.fulfill()
      case .request(.dictation(.append(let id, let offset, let bytes))):
        XCTAssertEqual(value.id, chunk.id); XCTAssertEqual(id, recording); XCTAssertEqual(offset, 0)
        XCTAssertEqual(bytes, audio); XCTAssertEqual(peer.deviceID, input.author)
        pair.server?.sendTransient(.codex(.init(id: value.id, body: .reply(.dictation(.init(id: id, receivedBytes: bytes.count))))))
      case .reply(.dictation(let state)):
        XCTAssertEqual(value.id, chunk.id); XCTAssertEqual(state.id, recording)
        XCTAssertEqual(state.receivedBytes, audio.count); XCTAssertNotEqual(peer.deviceID, input.author); received.fulfill()
      default: XCTFail("Unexpected chat reply")
      }
    }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    pair.client?.sendTransient(.codex(envelope))
    pair.client?.sendTransient(.codex(chunk))
    await fulfillment(of: [received], timeout: 10)
  }

  func testWrongTLSSecretNeverReachesApplicationAdmission() async throws {
    let failed = expectation(description: "TLS rejects the wrong secret")
    let pair = try NotebookTransportTestPair(wrongSecret: true)
    defer { pair.stop() }
    pair.onAuthenticated = { _, _ in XCTFail("Wrong TLS key must not reach Notebook authentication") }
    pair.onReady = { _, _ in XCTFail("Wrong TLS key must not receive notebook content") }
    pair.onFailure = { _ in failed.fulfill() }
    try pair.start()
    await fulfillment(of: [failed], timeout: 10)
    XCTAssertFalse(pair.server?.isReady == true)
    XCTAssertFalse(pair.client?.isReady == true)
    let reads = await pair.serverStorage.cursorReads
    XCTAssertEqual(reads, 0, "Even the durable cursor remains unread before account authorization")
  }

  func testAccountAdmissionPrecedesCursorAndContentWithoutHumanConfirmation() async throws {
    let waiting = expectation(description: "Account admission is pending")
    let ready = expectation(description: "Both account-authorized devices ready"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair()
    defer { pair.stop() }
    var gate: CheckedContinuation<Bool, Never>?
    defer { gate?.resume(returning: false) }
    pair.authorize = { peer in
      if peer.deviceID == pair.clientIdentity.deviceID {
        return await withCheckedContinuation { gate = $0; waiting.fulfill() }
      }
      return true
    }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [waiting], timeout: 10)
    let server = try XCTUnwrap(pair.server)
    let cursorReads = await pair.serverStorage.cursorReads
    XCTAssertEqual(cursorReads, 0); XCTAssertFalse(server.isReady)
    do { try await server.receive(.init(sequence: 1, message: .offer(pair.sampleChange))); XCTFail("No content before authorization") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .authenticationRequired) }
    gate?.resume(returning: true); gate = nil
    await fulfillment(of: [ready], timeout: 10)
  }

  func testStoppedSessionCannotPublishLateAccountAdmission() async throws {
    let waiting = expectation(description: "Account admission waits")
    let pair = try NotebookTransportTestPair()
    defer { pair.stop() }
    var gate: CheckedContinuation<Bool, Never>?
    defer { gate?.resume(returning: false) }
    pair.authorize = { peer in
      if peer.deviceID == pair.clientIdentity.deviceID {
        return await withCheckedContinuation { gate = $0; waiting.fulfill() }
      }
      return true
    }
    try pair.start(); await fulfillment(of: [waiting], timeout: 10)
    let server = try XCTUnwrap(pair.server)
    server.stop(); gate?.resume(returning: true); gate = nil
    let finished = expectation(description: "Late admission unwinds")
    Task { await Task.yield(); finished.fulfill() }
    await fulfillment(of: [finished], timeout: 2)
    let reads = await pair.serverStorage.cursorReads
    XCTAssertEqual(reads, 0); XCTAssertFalse(server.isReady)
  }

  func testDurableAcknowledgementWaitsForCommitWhileCameraAndContactContinue() async throws {
    let committing = expectation(description: "SQL apply reached its commit gate")
    let receivedTransient = expectation(description: "Camera and contact bypass blocked SQL"); receivedTransient.expectedFulfillmentCount = 2
    let committed = expectation(description: "Durable ACK follows SQL commit")
    let pair = try NotebookTransportTestPair(withChange: true, holdCommit: true)
    defer { pair.stop() }
    await pair.serverStorage.setCommitObserver { committing.fulfill() }
    await pair.clientStorage.setAcknowledgementObserver { committed.fulfill() }
    pair.onTransient = { value, peer in
      XCTAssertEqual(peer.deviceID, pair.clientIdentity.deviceID)
      switch value {
      case .presence, .inputActivity: receivedTransient.fulfill()
      default: XCTFail("Unexpected transient")
      }
    }
    try pair.start()
    await fulfillment(of: [committing], timeout: 10)
    let before = await pair.clientStorage.acknowledgedCursor
    XCTAssertEqual(before, 0)
    let client = try XCTUnwrap(pair.client)
    client.sendTransient(.presence(.init(sessionID: UUID(), sequence: 1, phase: .active,
      presence: .init(mode: .board, camera: .init(center: .init(x: 40, y: 0)), viewport: .init(x: 1_024, y: 1_366)))))
    client.sendTransient(.inputActivity(.init(deviceID: pair.clientIdentity.deviceID, sessionID: UUID(), sequence: 1, targets: [])))
    await fulfillment(of: [receivedTransient], timeout: 10)
    let stillWaiting = await pair.clientStorage.acknowledgedCursor
    XCTAssertEqual(stillWaiting, 0, "Transfer credits are not durable acknowledgements")
    await pair.serverStorage.releaseCommit()
    await fulfillment(of: [committed], timeout: 10)
    let after = await pair.clientStorage.acknowledgedCursor
    let applied = await pair.serverStorage.appliedCount
    let size = await pair.serverStorage.largestStagedBlob
    XCTAssertEqual(after, 1); XCTAssertEqual(applied, 1)
    XCTAssertEqual(size, 400_000, "The heavy owner reached SQL through a completed staged file")
  }

  func testSmallDependenciesUseTheWholeBoundedWindowBeforeCommit() async throws {
    let committed = expectation(description: "All dependency windows precede the durable ACK")
    let pair = try NotebookTransportTestPair(withChange: true, contentBytes: 512, contentBlobCount: 33)
    defer { pair.stop() }
    await pair.clientStorage.setAcknowledgementObserver { committed.fulfill() }
    pair.onFailure = { XCTFail("Bounded dependency delivery failed: \($0)") }
    try pair.start()
    await fulfillment(of: [committed], timeout: 10)
    let batches = await pair.serverStorage.stagedBatchSizes
    let applied = await pair.serverStorage.appliedCount
    XCTAssertEqual(batches, [1, 16, 16, 1], "One manifest and full dependency windows, not one SQL commit per field")
    let served = await pair.clientStorage.servedWindowSizes
    XCTAssertEqual(served, [1, 16, 16, 1], "Four response frames/read submissions, not 34 serial requests")
    XCTAssertEqual(applied, 1)
  }

  func testPartialHeadStreamsBeforeLaterHashesWithoutBlockingControl() async throws {
    let committed = expectation(description: "Partial heads and their later hashes all commit")
    let pair = try NotebookTransportTestPair(withChange: true, contentBytes: 1024 * 1024 + 17, contentBlobCount: 3)
    defer { pair.stop() }
    await pair.clientStorage.setAcknowledgementObserver { committed.fulfill() }
    pair.onFailure = { XCTFail("Partial dependency delivery failed: \($0)") }
    let ready = expectation(description: "Both TLS sessions ready"); ready.expectedFulfillmentCount = 2
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    let delivered = expectation(description: "Control crosses the streamed dependency window")
    let envelope = NotebookChatEnvelope(body: .request(.account(.read)))
    var roundTrip: Duration?
    let start = ContinuousClock.now
    pair.onTransient = { value, peer in
      guard case .codex(let received) = value, received.id == envelope.id else { return }
      if peer.deviceID == pair.clientIdentity.deviceID {
        pair.server?.sendTransient(.codex(.init(id: received.id, body: .reply(.acknowledged))))
      } else { roundTrip = start.duration(to: .now); delivered.fulfill() }
    }
    pair.client?.sendTransient(.codex(envelope))
    await fulfillment(of: [delivered, committed], timeout: 15)
    XCTAssertLessThanOrEqual(try XCTUnwrap(roundTrip), .milliseconds(100))
    let count = await pair.serverStorage.appliedCount, size = await pair.serverStorage.largestStagedBlob
    let windows = await pair.clientStorage.servedWindowSizes, bytes = await pair.clientStorage.servedWindowBytes
    XCTAssertEqual(count, 1); XCTAssertEqual(size, 1024 * 1024 + 17)
    XCTAssertTrue(windows.contains(2), "The final partial head and next hash share a response")
    XCTAssertTrue(bytes.allSatisfy { $0 <= NotebookTransportLimits.maximumBlobWindowBytes })
  }

  func testCloudCheckpointOvertakingAnOfferedLANChangeAcknowledgesOnlyThatOffer() async throws {
    let committing = expectation(description: "LAN waits before its SQL admission")
    let acknowledged = expectation(description: "Covered LAN offer receives its own ACK")
    let pair = try NotebookTransportTestPair(withChange: true, holdCommit: true)
    defer { pair.stop() }
    await pair.serverStorage.setCommitObserver { committing.fulfill() }
    await pair.clientStorage.setAcknowledgementObserver { acknowledged.fulfill() }
    try pair.start()
    await fulfillment(of: [committing], timeout: 10)
    // The source's CloudKit checkpoint commits while the LAN packet is still
    // in flight. Core has separately proved this prefix contains the action.
    await pair.serverStorage.coverIncomingPrefix(through: 20)
    await pair.serverStorage.releaseCommit()
    await fulfillment(of: [acknowledged], timeout: 10)
    let cursor = await pair.clientStorage.acknowledgedCursor
    let applied = await pair.serverStorage.appliedCount
    XCTAssertEqual(cursor, 1, "Never acknowledge sequence 20 with transaction 1")
    XCTAssertEqual(applied, 0, "The checkpoint-covered action has no second effect")
    XCTAssertTrue(pair.server?.isReady == true); XCTAssertTrue(pair.client?.isReady == true)
  }

  func testQuiescentHistoryControlJoinsTheExistingCallbackAndResumesTheSameTLSOwner() async throws {
    let gate = NotebookTransportHistoryJournalGate()
    let readStarted = expectation(description: "Actual journal callback is held")
    await gate.setObserver { readStarted.fulfill() }
    let ready = expectation(description: "Admitted existing TLS pair"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(serverJournalGeneration: UUID(), clientJournalGeneration: UUID(),
      historyApplicationBuild: "history-tests", serverJournalGate: gate)
    defer { pair.stop(); Task { await gate.release() } }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [ready, readStarted], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let serverGeneration = server.generation, clientGeneration = client.generation
    let scope = try await prepareHistoryPair(pair)
    try await admitHistoryPair(pair, scope: scope)
    let joining = expectation(description: "Quiesce joins the actual held callback")
    let first = Task<Void, Error> { joining.fulfill(); try await server.quiesceHistoryControl(scope) }
    let second = Task<Void, Error> { try await client.quiesceHistoryControl(scope) }
    await fulfillment(of: [joining], timeout: 5)
    XCTAssertTrue(server.historyBoundaryObservation.hasStorageCallback)
    XCTAssertFalse(server.isHistoryQuiescent); XCTAssertFalse(client.isHistoryQuiescent)
    await gate.release()
    try await first.value; try await second.value
    XCTAssertTrue(server.isHistoryQuiescent); XCTAssertTrue(client.isHistoryQuiescent)
    let serverBefore = await pair.serverStorage.historyActivity(), clientBefore = await pair.clientStorage.historyActivity()
    let readsBefore = await gate.calls
    let metadata = expectation(description: "Seventeen pages pass the actual credit window and the root follows")
    var receivedPages: [NotebookHistoryControl.Page] = []
    pair.onTransient = { _, _ in XCTFail("Quiescent generic callbacks cannot reach native owners") }
    pair.onHistoryControl = { control, peer in
      XCTAssertEqual(peer.deviceID, pair.clientIdentity.deviceID)
      switch control {
      case .page(let page):
        XCTAssertEqual(page.ordinal, UInt64(receivedPages.count)); XCTAssertEqual(page.entries.count, 64)
        XCTAssertEqual(page.previousPageHash, receivedPages.last?.hash); receivedPages.append(page)
      case .root(let root):
        XCTAssertEqual(receivedPages.count, 17); XCTAssertEqual(root.entryCount, 17 * 64); metadata.fulfill()
      default: break
      }
    }
    client.notifyDurableChanges(); server.notifyDurableChanges()
    let contact = NotebookInputActivity(deviceID: pair.clientIdentity.deviceID, sessionID: UUID(), sequence: 1,
      targets: [.init(kind: .page, id: UUID())])
    client.sendTransient(.inputActivity(contact))
    let source = try XCTUnwrap(client.historyBoundaryObservation.localSource)
    var previous: String?
    for ordinal in 0..<17 {
      let page = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: scope.workspaceID,
        source: source, stream: .acceptedTransactions, ordinal: UInt64(ordinal), previousPageHash: previous,
        entries: (0..<64).map { _ in .init(transactionID: UUID(), hash: String(repeating: "a", count: 64), count: 1) },
        isLast: ordinal == 16)
      try client.sendHistoryControl(.page(page)); previous = page.hash
    }
    // Content authentication belongs to the readiness digest; transport carries
    // this bounded opaque commitment, never claiming it proves authored bodies.
    try client.sendHistoryControl(.root(.init(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: source, stream: .acceptedTransactions, hash: String(repeating: "b", count: 64),
      pageCount: 17, entryCount: 17 * 64)))
    await fulfillment(of: [metadata], timeout: 10)
    let serverAfter = await pair.serverStorage.historyActivity(), clientAfter = await pair.clientStorage.historyActivity()
    let readsAfter = await gate.calls
    XCTAssertEqual(serverBefore, serverAfter); XCTAssertEqual(clientBefore, clientAfter); XCTAssertEqual(readsBefore, readsAfter)
    pair.onHistoryControl = nil
    let resumed = expectation(description: "Ordinary callback resumes on the same authenticated generation")
    pair.onTransient = { value, peer in
      guard case .inputActivity = value else { return XCTFail("Expected the resumed contact lane") }
      XCTAssertEqual(peer.deviceID, pair.clientIdentity.deviceID); resumed.fulfill()
    }
    let resumeFirst = Task<Void, Error> { try await server.resumeHistoryControl(scope) }
    let resumeSecond = Task<Void, Error> { try await client.resumeHistoryControl(scope) }
    try await resumeFirst.value; try await resumeSecond.value
    XCTAssertEqual(server.generation, serverGeneration); XCTAssertEqual(client.generation, clientGeneration)
    client.sendTransient(.inputActivity(contact))
    await fulfillment(of: [resumed], timeout: 5)
    await pair.stopAndJoin()
  }

  func testHistoryMetadataWaitsForDelayedTLSCreditWithoutDuplicatingTheHeldPage() async throws {
    let ready = expectation(description: "Existing authenticated pair ready"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(serverJournalGeneration: UUID(), clientJournalGeneration: UUID(),
      historyApplicationBuild: "history-tests")
    defer { pair.stop() }
    pair.onReady = { _, _ in ready.fulfill() }
    pair.onFailure = { XCTFail("Delayed credit cannot retire the admitted pair: \($0)") }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let scope = try await prepareHistoryPair(pair)
    try await admitHistoryPair(pair, scope: scope)
    let first = Task<Void, Error> { try await server.quiesceHistoryControl(scope) }
    let second = Task<Void, Error> { try await client.quiesceHistoryControl(scope) }
    try await first.value; try await second.value
    let connectionID = client.generation, source = try XCTUnwrap(client.historyBoundaryObservation.localSource)
    let serverBefore = await pair.serverStorage.historyActivity(), clientBefore = await pair.clientStorage.historyActivity()
    let pageCount = 48
    let queued = expectation(description: "One sending frame and twenty pending frames occupy the existing owner")
    let delivered = expectation(description: "The exact held page resumes after real TLS callbacks and the root follows")
    let root = NotebookHistoryControl.Root(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: source, stream: .acceptedTransactions, hash: String(repeating: "b", count: 64),
      pageCount: UInt64(pageCount), entryCount: UInt64(pageCount * 64))
    var enqueuedPages = 0, completed = false
    var submittedPages: [NotebookHistoryControl.Page] = [], receivedPages: [NotebookHistoryControl.Page] = []
    pair.onHistoryControl = { control, peer in
      XCTAssertEqual(peer.deviceID, pair.clientIdentity.deviceID)
      switch control {
      case .page(let page):
        XCTAssertEqual(page.ordinal, UInt64(receivedPages.count))
        XCTAssertEqual(page.entries.count, 64)
        XCTAssertEqual(page.previousPageHash, receivedPages.last?.hash)
        receivedPages.append(page)
      case .root(let actual):
        XCTAssertEqual(actual, root); XCTAssertEqual(receivedPages, submittedPages)
        XCTAssertEqual(receivedPages.count, pageCount); delivered.fulfill()
      default: XCTFail("Only the source's pages and root may cross this cut")
      }
    }
    // Suspend the pair's actual callback queue, not a substitute send window.
    // The physical TLS connection stays alive and its credits remain delayed.
    pair.holdNetworkCallbacks()
    let sending = Task<Void, Error> {
      var previous: String?
      for ordinal in 0..<pageCount {
        let page = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: scope.workspaceID,
          source: source, stream: .acceptedTransactions, ordinal: UInt64(ordinal), previousPageHash: previous,
          entries: (0..<64).map { _ in .init(transactionID: UUID(), hash: String(repeating: "a", count: 64), count: 1) },
          isLast: ordinal == pageCount - 1)
        submittedPages.append(page)
        try await client.sendHistoryControlAwaitingCredit(.page(page), scope: scope)
        enqueuedPages += 1; previous = page.hash
        if enqueuedPages == 21 { queued.fulfill() }
      }
      try await client.sendHistoryControlAwaitingCredit(.root(root), scope: scope)
      completed = true
    }
    defer { sending.cancel(); pair.releaseNetworkCallbacks() }
    await fulfillment(of: [queued], timeout: 5)
    XCTAssertEqual(enqueuedPages, 21); XCTAssertFalse(completed); XCTAssertTrue(receivedPages.isEmpty)
    XCTAssertEqual(client.historyBoundaryObservation.pendingFrames, 20)
    XCTAssertEqual(client.historyBoundaryObservation.unacknowledgedFrames, 1)
    let otherScope = NotebookHistoryControlScope(requestID: UUID(), workspaceID: scope.workspaceID,
      credentialID: scope.credentialID, applicationBuild: scope.applicationBuild, endpoints: scope.endpoints)
    do { try await client.sendHistoryControlAwaitingCredit(.root(root), scope: otherScope); XCTFail("A foreign cut cannot borrow the held sender") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .historyCutStale) }
    do { try await client.sendHistoryControlAwaitingCredit(.root(root), scope: scope); XCTFail("The same owner retains only one blocked control") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .historyReadinessPending) }
    XCTAssertEqual(client.historyBoundaryObservation.pendingFrames, 20)
    pair.releaseNetworkCallbacks()
    await fulfillment(of: [delivered], timeout: 10)
    try await sending.value
    XCTAssertTrue(completed); XCTAssertEqual(enqueuedPages, pageCount)
    XCTAssertEqual(client.generation, connectionID); XCTAssertTrue(client.isHistoryQuiescent)
    let serverAfter = await pair.serverStorage.historyActivity(), clientAfter = await pair.clientStorage.historyActivity()
    XCTAssertEqual(serverBefore, serverAfter); XCTAssertEqual(clientBefore, clientAfter)
    pair.onHistoryControl = nil
    await pair.stopAndJoin()
  }

  func testTerminalHistoryRefusalWaitsForCreditAndDrainsBothOrderedTailsOnTheSameTLSOwners() async throws {
    let ready = expectation(description: "The existing pair is authenticated"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(serverJournalGeneration: UUID(), clientJournalGeneration: UUID(),
      historyApplicationBuild: "history-tests")
    defer { pair.stop() }
    pair.onReady = { _, _ in ready.fulfill() }
    pair.onFailure = { XCTFail("Terminal refusal must retain TLS while its actual window drains: \($0)") }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let scope = try await prepareHistoryPair(pair)
    try await admitHistoryPair(pair, scope: scope)
    let first = Task<Void, Error> { try await server.quiesceHistoryControl(scope) }
    let second = Task<Void, Error> { try await client.quiesceHistoryControl(scope) }
    try await first.value; try await second.value
    let serverID = server.generation, clientID = client.generation
    let serverSource = try XCTUnwrap(server.historyBoundaryObservation.localSource)
    let clientSource = try XCTUnwrap(client.historyBoundaryObservation.localSource)
    let refusal = NotebookHistoryControl.Refusal(origin: serverSource, code: .resourceLimit,
      reason: .resourceLimit, stage: .reading, sourceSection: .acceptedPhysicalHistory, identifier: "read_sql_work")
    let forged = NotebookHistoryControl.Refusal(origin: clientSource, code: .resourceLimit,
      reason: .resourceLimit, stage: .reading)
    do { try await server.resumeHistoryControl(scope, refusal: forged); XCTFail("A sender cannot attribute its refusal to its peer") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .identityMismatch) }
    XCTAssertTrue(server.isHistoryQuiescent); XCTAssertTrue(client.isHistoryQuiescent)

    var pages: [UUID: Int] = [:], terminal: Set<UUID> = [], receivedRefusal: NotebookHistoryControl.Refusal?
    var resumingTailCount = 0
    pair.onHistoryControl = { control, peer in
      switch control {
      case .page:
        XCTAssertFalse(terminal.contains(peer.deviceID), "No page may follow this sender's terminal frame")
        pages[peer.deviceID, default: 0] += 1
        if !server.isHistoryQuiescent && !client.isHistoryQuiescent { resumingTailCount += 1 }
      case .resume(_, let actual):
        terminal.insert(peer.deviceID)
        if peer.deviceID == serverSource.deviceID { receivedRefusal = actual; XCTAssertEqual(actual, refusal) }
        else { XCTAssertNil(actual, "The recipient cannot reattribute and echo the peer's first refusal") }
      case .resumed: break
      default: XCTFail("Only already-sent pages and the ordered terminal handshake are expected")
      }
    }
    pair.holdNetworkCallbacks()
    for (owner, source) in [(server, serverSource), (client, clientSource)] {
      var previous: String?
      for ordinal in 0..<21 {
        let page = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: scope.workspaceID,
          source: source, stream: .acceptedTransactions, ordinal: UInt64(ordinal), previousPageHash: previous,
          entries: [.init(transactionID: UUID(), hash: String(repeating: "a", count: 64), count: 1)], isLast: false)
        try owner.sendHistoryControl(.page(page))
        previous = page.hash
      }
      XCTAssertEqual(owner.historyBoundaryObservation.pendingFrames, 20)
    }
    let entered = expectation(description: "Both terminal senders retain the same full window"); entered.expectedFulfillmentCount = 2
    var serverJoined = false, clientJoined = false
    let serverResume = Task<Void, Error> {
      entered.fulfill(); try await server.resumeHistoryControl(scope, refusal: refusal); serverJoined = true
    }
    let clientResume = Task<Void, Error> {
      entered.fulfill(); try await client.resumeHistoryControl(scope); clientJoined = true
    }
    defer { serverResume.cancel(); clientResume.cancel(); pair.releaseNetworkCallbacks() }
    await fulfillment(of: [entered], timeout: 5)
    XCTAssertFalse(serverJoined); XCTAssertFalse(clientJoined)
    XCTAssertTrue(server.isReady); XCTAssertTrue(client.isReady)
    XCTAssertEqual(server.historyBoundaryObservation.pendingFrames, 20)
    XCTAssertEqual(client.historyBoundaryObservation.pendingFrames, 20)
    pair.releaseNetworkCallbacks()
    try await serverResume.value; try await clientResume.value
    XCTAssertEqual(receivedRefusal, refusal)
    XCTAssertEqual(pages[serverSource.deviceID], 21); XCTAssertEqual(pages[clientSource.deviceID], 21)
    XCTAssertGreaterThan(resumingTailCount, 0)
    XCTAssertEqual(server.generation, serverID); XCTAssertEqual(client.generation, clientID)
    XCTAssertTrue(server.isReady); XCTAssertTrue(client.isReady)
    XCTAssertNil(server.historyControlScope); XCTAssertNil(client.historyControlScope)
    pair.onHistoryControl = nil
    await pair.stopAndJoin()
  }

  func testHistoryPreparationUsesTheAdvertisedHeadWhileOrdinaryDeliveryContinues() async throws {
    let gate = NotebookTransportHistoryJournalGate()
    let held = expectation(description: "Actual source head is not yet offered")
    await gate.setObserver { held.fulfill() }
    let ready = expectation(description: "Pair ready"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(withChange: true, contentBytes: 64,
      serverJournalGeneration: UUID(), clientJournalGeneration: UUID(), historyApplicationBuild: "history-tests",
      clientJournalGate: gate)
    defer { pair.stop(); Task { await gate.release() } }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [ready, held], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let scope = try await prepareHistoryPair(pair, clientHead: pair.sampleChange)
    XCTAssertEqual(server.historyBoundaryObservation.remoteOfferedThrough, 0)
    XCTAssertEqual(server.historyBoundaryObservation.peerPrepared?.head, pair.sampleChange)
    let guessed = NotebookHistoryControlScope(requestID: scope.requestID, workspaceID: scope.workspaceID,
      credentialID: scope.credentialID, applicationBuild: scope.applicationBuild,
      endpoints: scope.endpoints.map { .init(identity: $0.identity, journalGeneration: $0.journalGeneration, head: nil) })
    for owner in [server, client] {
      do { try owner.admitHistoryControl(guessed); XCTFail("Last offer zero is not the actual remote SQL head") }
      catch { XCTAssertEqual(error as? NotebookTransportError, .historyNotDrained) }
      XCTAssertNil(owner.historyControlScope); XCTAssertTrue(owner.isReady)
    }
    let committed = expectation(description: "The original draining request keeps actual delivery and durable ACK alive")
    await pair.clientStorage.setAcknowledgementObserver { committed.fulfill() }
    await gate.release(); await fulfillment(of: [committed], timeout: 10)
    let applied = await pair.serverStorage.appliedCount, acknowledged = await pair.clientStorage.acknowledgedCursor
    XCTAssertEqual(applied, 1); XCTAssertEqual(acknowledged, 1)
    XCTAssertEqual(server.historyBoundaryObservation.incomingAcceptedThrough, 1)
    XCTAssertEqual(client.historyBoundaryObservation.peerAcceptedThrough, 1)
    let proposed = expectation(description: "Final scope reaches the native owner still awaiting its SQL cut")
    let earlyQuiesced = expectation(description: "Exact peer acknowledgement is retained before native admission")
    let newerRead = expectation(description: "The same advertised head can carry a newer read cut after peer admission")
    pair.onHistoryControl = { control, peer in
      switch control {
      case .request(let value):
        XCTAssertEqual(value, scope); XCTAssertEqual(peer.deviceID, pair.serverIdentity.deviceID)
        XCTAssertNil(client.historyControlScope); proposed.fulfill()
      case .quiesced(let value) where peer.deviceID == pair.serverIdentity.deviceID:
        XCTAssertEqual(value, scope); XCTAssertNil(client.historyControlScope)
        XCTAssertFalse(client.isHistoryQuiescent); earlyQuiesced.fulfill()
      case .prepared(let value) where peer.deviceID == pair.clientIdentity.deviceID:
        XCTAssertEqual(value.head, pair.sampleChange); XCTAssertEqual(value.readRevision, 1)
        XCTAssertEqual(server.historyControlScope, scope); newerRead.fulfill()
      default: break
      }
    }
    try server.proposeHistoryControl(scope); try server.admitHistoryControl(scope)
    let first = Task<Void, Error> { try await server.quiesceHistoryControl(scope) }
    await fulfillment(of: [proposed, earlyQuiesced], timeout: 10)
    XCTAssertTrue(client.isReady); XCTAssertNil(client.historyControlScope)
    let page = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: try XCTUnwrap(client.historyBoundaryObservation.localSource), stream: .acceptedTransactions,
      ordinal: 0, entries: [], isLast: true)
    do { try client.sendHistoryControl(.page(page)); XCTFail("An early peer acknowledgement cannot admit local history emission") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .historyReadinessPending) }
    try client.sendHistoryPrepared(.init(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: try XCTUnwrap(client.historyBoundaryObservation.localSource), head: pair.sampleChange, readRevision: 1))
    await fulfillment(of: [newerRead], timeout: 10)
    try client.admitHistoryControl(scope)
    let second = Task<Void, Error> { try await client.quiesceHistoryControl(scope) }
    try await first.value; try await second.value
    XCTAssertTrue(server.isHistoryQuiescent); XCTAssertTrue(client.isHistoryQuiescent)
    XCTAssertEqual(server.historyBoundaryObservation.incomingAcceptedThrough, 1)
    XCTAssertEqual(client.historyBoundaryObservation.peerAcceptedThrough, 1)
    pair.onHistoryControl = nil
    await pair.stopAndJoin()
  }

  func testQuiescentHistoryRefusesForeignMetadataAndLateContentWithoutStorageOrACK() async throws {
    let ready = expectation(description: "Pair ready"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(serverJournalGeneration: UUID(), clientJournalGeneration: UUID(),
      historyApplicationBuild: "history-tests")
    defer { pair.stop() }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let scope = try await prepareHistoryPair(pair)
    try await admitHistoryPair(pair, scope: scope)
    let first = Task<Void, Error> { try await server.quiesceHistoryControl(scope) }
    let second = Task<Void, Error> { try await client.quiesceHistoryControl(scope) }
    try await first.value; try await second.value
    let before = await pair.serverStorage.historyActivity()
    let source = try XCTUnwrap(client.historyBoundaryObservation.localSource)
    let wrongPage = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: .init(deviceID: source.deviceID, generation: UUID()), stream: .acceptedTransactions,
      ordinal: 0, entries: [], isLast: true)
    do { try client.sendHistoryControl(.page(wrongPage)); XCTFail("A different source generation cannot enter the cut") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .identityMismatch) }
    let wrongScope = NotebookHistoryControlScope(requestID: UUID(), workspaceID: scope.workspaceID,
      credentialID: scope.credentialID, applicationBuild: scope.applicationBuild, endpoints: scope.endpoints)
    do { try await server.resumeHistoryControl(wrongScope); XCTFail("Only the exact native request may resume") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .historyCutStale) }
    do {
      _ = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: scope.workspaceID,
        source: source, stream: .acceptedTransactions, ordinal: 0,
        entries: Array(repeating: .init(hash: String(repeating: "a", count: 64)), count: 65), isLast: true)
      XCTFail("Metadata page must be bounded before encoding")
    } catch { XCTAssertEqual(error as? NotebookTransportError, .invalidFrame) }
    XCTAssertTrue(server.isHistoryQuiescent); XCTAssertTrue(client.isHistoryQuiescent)
    var stale: [NotebookHistoryControl.StaleReason] = []
    pair.onHistoryControl = { control, peer in
      if case .stale(let request, let reason) = control, peer.deviceID == pair.clientIdentity.deviceID {
        XCTAssertEqual(request, scope.requestID); stale.append(reason)
      }
    }
    do { try await server.receive(.init(sequence: 1, message: .offer(pair.sampleChange))); XCTFail("Late content invalidates before any acceptance") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .historyCutStale) }
    XCTAssertEqual(stale, [.lateContent]); XCTAssertFalse(server.isReady)
    let after = await pair.serverStorage.historyActivity(), peerACK = await pair.clientStorage.acknowledgedCursor
    XCTAssertEqual(before, after); XCTAssertEqual(peerACK, 0)
    XCTAssertEqual(server.historyBoundaryObservation.incomingAcceptedThrough, 0)
    await pair.stopAndJoin()
  }

  func testCanceledHistoryPreparationRequiresEachExactNativeOwnerToResume() async throws {
    let ready = expectation(description: "Pair ready"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(serverJournalGeneration: UUID(), clientJournalGeneration: UUID(),
      historyApplicationBuild: "history-tests")
    defer { pair.stop() }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let scope = try await prepareHistoryPair(pair), preparation = scope.preparation
    let foreign = NotebookHistoryControlPreparation(requestID: UUID(), workspaceID: preparation.workspaceID,
      credentialID: preparation.credentialID, applicationBuild: preparation.applicationBuild, endpoints: preparation.endpoints)
    do { try server.resumeHistoryPreparation(foreign); XCTFail("A different native request cannot release preparation") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .historyCutStale) }
    let cancelled = expectation(description: "Remote cancellation is a proposal to the native coordinator")
    pair.onHistoryControl = { control, peer in
      if case .stale(let request, let reason) = control {
        XCTAssertEqual(peer.deviceID, pair.serverIdentity.deviceID)
        XCTAssertEqual(request, preparation.requestID); XCTAssertEqual(reason, .cancelled)
        XCTAssertEqual(client.historyControlPreparation, preparation, "The message itself cannot open native authorship")
        cancelled.fulfill()
      }
    }
    try server.resumeHistoryPreparation(preparation)
    await fulfillment(of: [cancelled], timeout: 5)
    XCTAssertNil(server.historyControlPreparation); XCTAssertEqual(client.historyControlPreparation, preparation)
    try client.resumeHistoryPreparation(preparation)
    XCTAssertTrue(server.isReady); XCTAssertTrue(client.isReady)
    XCTAssertNil(client.historyControlPreparation)
    // Explicitly admitted new UUIDs are not held by the canceled preparation;
    // a delayed echo of the previous cancellation cannot affect this new phase.
    try server.admitHistoryPreparation(foreign); try client.admitHistoryPreparation(foreign)
    let contact = expectation(description: "Ordinary delivery remains on the same preparing connection")
    pair.onTransient = { _, _ in contact.fulfill() }
    server.sendTransient(.inputActivity(.init(deviceID: pair.serverIdentity.deviceID,
      sessionID: UUID(), sequence: 1, targets: [])))
    await fulfillment(of: [contact], timeout: 5)
    XCTAssertEqual(server.historyControlPreparation, foreign); XCTAssertEqual(client.historyControlPreparation, foreign)
    pair.onHistoryControl = nil
    await pair.stopAndJoin()
  }

  private func prepareHistoryPair(_ pair: NotebookTransportTestPair,
    serverHead: NotebookDurableChange? = nil, clientHead: NotebookDurableChange? = nil) async throws -> NotebookHistoryControlScope {
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let scope = NotebookHistoryControlScope(requestID: UUID(), workspaceID: pair.serverIdentity.workspaceID,
      credentialID: try XCTUnwrap(server.credentialID), applicationBuild: "history-tests",
      endpoints: [.init(identity: pair.serverIdentity, journalGeneration: try XCTUnwrap(server.historyBoundaryObservation.localSource).generation, head: serverHead),
        .init(identity: pair.clientIdentity, journalGeneration: try XCTUnwrap(client.historyBoundaryObservation.localSource).generation, head: clientHead)])
    let prepared = expectation(description: "Both actual native head observations cross TLS"); prepared.expectedFulfillmentCount = 2
    pair.onHistoryControl = { control, peer in
      do {
        switch control {
        case .prepare(let proposal):
          XCTAssertEqual(proposal, scope.preparation); XCTAssertEqual(peer.deviceID, pair.serverIdentity.deviceID)
          try client.admitHistoryPreparation(proposal)
          try client.sendHistoryPrepared(.init(requestID: scope.requestID, workspaceID: scope.workspaceID,
            source: try XCTUnwrap(client.historyBoundaryObservation.localSource), head: clientHead, readRevision: 0))
        case .prepared: prepared.fulfill()
        default: break
        }
      } catch { XCTFail("Head negotiation failed: \(error)") }
    }
    try server.admitHistoryPreparation(scope.preparation); try server.proposeHistoryPreparation(scope.preparation)
    try server.sendHistoryPrepared(.init(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: try XCTUnwrap(server.historyBoundaryObservation.localSource), head: serverHead, readRevision: 0))
    await fulfillment(of: [prepared], timeout: 10)
    return scope
  }

  private func admitHistoryPair(_ pair: NotebookTransportTestPair, scope: NotebookHistoryControlScope) async throws {
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    let admitted = expectation(description: "The other native owner explicitly admits the exact scope")
    pair.onHistoryControl = { control, _ in
      if case .request(let proposed) = control {
        do { XCTAssertEqual(proposed, scope); try client.admitHistoryControl(proposed); admitted.fulfill() }
        catch { XCTFail("Exact scope admission failed: \(error)") }
      }
    }
    try server.proposeHistoryControl(scope); try server.admitHistoryControl(scope)
    await fulfillment(of: [admitted], timeout: 10)
    pair.onHistoryControl = nil
  }

  func testDisconnectSuppressesLateCommitCallbacksAndReconnectUsesCommittedCursor() async throws {
    let committing = expectation(description: "Old generation waits inside SQL")
    let finishedCommit = expectation(description: "SQL may complete after disconnection")
    let pair = try NotebookTransportTestPair(withChange: true, holdCommit: true)
    defer { pair.stop() }
    await pair.serverStorage.setCommitObserver { committing.fulfill() }
    await pair.serverStorage.setCommittedObserver { finishedCommit.fulfill() }
    pair.onDurable = { _, _ in XCTFail("A disconnected generation cannot publish completion") }
    try pair.start()
    await fulfillment(of: [committing], timeout: 10)
    let server = try XCTUnwrap(pair.server), oldGeneration = server.generation
    pair.stop()
    let joined = Task {
      await server.stopAndJoin()
      let committed = await pair.serverStorage.appliedCount
      XCTAssertEqual(committed, 1, "Joining delivery cannot finish before its accepted storage callback")
    }
    await pair.serverStorage.releaseCommit()
    await fulfillment(of: [finishedCommit], timeout: 10)
    await joined.value
    let ready = expectation(description: "Reconnect resumes after the committed transaction"); ready.expectedFulfillmentCount = 2
    let reconnect = try NotebookTransportTestPair(serverStorage: pair.serverStorage, clientStorage: pair.clientStorage,
      serverIdentity: pair.serverIdentity, clientIdentity: pair.clientIdentity)
    defer { reconnect.stop() }
    reconnect.onReady = { _, _ in ready.fulfill() }
    try reconnect.start()
    await fulfillment(of: [ready], timeout: 10)
    XCTAssertNotEqual(try XCTUnwrap(reconnect.server).generation, oldGeneration)
    let applied = await pair.serverStorage.appliedCount
    let cursors = await pair.clientStorage.requestedJournalCursors
    XCTAssertEqual(applied, 1)
    XCTAssertTrue(cursors.contains(1), "Reconnect starts from the receiver's SQL cursor, not the last socket write")
  }
}

@MainActor
final class NotebookTransportTestPair {
  let serverIdentity: NotebookTransportIdentity
  let clientIdentity: NotebookTransportIdentity
  let serverStorage: NotebookTransportMemoryStore
  let clientStorage: NotebookTransportMemoryStore
  let sampleChange: NotebookDurableChange
  var server: NotebookTransportSession?
  var client: NotebookTransportSession?
  var onReady: ((NotebookTransportIdentity, UUID) -> Void)?
  var onAuthenticated: ((NotebookTransportIdentity, UUID) -> Void)?
  var authorize: ((NotebookTransportIdentity) async throws -> Bool)?
  var onTransient: ((NotebookTransportTransient, NotebookTransportIdentity) -> Void)?
  var onDurable: ((NotebookDurableChange, NotebookTransportIdentity) -> Void)?
  var onHistoryControl: ((NotebookHistoryControl, NotebookTransportIdentity) -> Void)?
  var onFailure: ((Error) -> Void)?
  var onStopped: ((NotebookTransportIdentity, Error?) -> Void)?
  private let authorized: Bool
  private let wrongSecret: Bool
  private let credentialID = UUID()
  private let secret = Data(repeating: 17, count: 32)
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookTLSLoopback-\(UUID())")
  private let queue = DispatchQueue(label: "Notebook.Tests.TLSLoopback")
  private var listener: NWListener?
  private var uplink: NotebookRelayUplink?
  private let relay: NotebookRelayRoute?
  private let serverAdapter: NotebookTransportStorage
  private let clientAdapter: NotebookTransportStorage
  private let historyApplicationBuild: String?
  private var reportedFailure = false
  private var isStopped = false
  private var networkCallbacksHeld = false

  init(wrongSecret: Bool = false, authorized: Bool = true, withChange: Bool = false, holdCommit: Bool = false,
    serverStorage: NotebookTransportMemoryStore? = nil, clientStorage: NotebookTransportMemoryStore? = nil,
    serverIdentity: NotebookTransportIdentity? = nil, clientIdentity: NotebookTransportIdentity? = nil, relay: NotebookRelayRoute? = nil, contentBytes: Int = 400_000, contentBlobCount: Int = 1,
    serverAdapter: NotebookTransportStorage? = nil, clientAdapter: NotebookTransportStorage? = nil,
    serverJournalGeneration: UUID? = nil, clientJournalGeneration: UUID? = nil,
    historyApplicationBuild: String? = nil,
    serverJournalGate: NotebookTransportHistoryJournalGate? = nil,
    clientJournalGate: NotebookTransportHistoryJournalGate? = nil) throws {
    let workspaceID = serverIdentity?.workspaceID ?? UUID()
    self.serverIdentity = serverIdentity ?? .init(deviceID: UUID(), workspaceID: workspaceID, displayName: "Loopback Mac")
    self.clientIdentity = clientIdentity ?? .init(deviceID: UUID(), workspaceID: workspaceID, displayName: "Loopback iPad")
    self.relay = relay
    self.wrongSecret = wrongSecret; self.authorized = authorized
    let contents = (0..<contentBlobCount).map { Data(repeating: UInt8($0 + 7), count: contentBytes) }
    let transactionID = UUID()
    let manifest = try JSONEncoder().encode(NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID,
      records: contents.enumerated().map { .init(address: "pages/test-\($0.offset).json", blobHash: Self.digest($0.element)) }))
    let manifestHash = Self.digest(manifest)
    sampleChange = .init(sequence: 1, transactionID: transactionID, manifestHash: manifestHash, byteCount: manifest.count)
    self.serverStorage = serverStorage ?? NotebookTransportMemoryStore(holdCommit: holdCommit)
    var blobs = Dictionary(uniqueKeysWithValues: contents.map { (Self.digest($0), $0) })
    blobs[manifestHash] = manifest
    self.clientStorage = clientStorage ?? NotebookTransportMemoryStore(changes: withChange ? [sampleChange] : [],
      blobs: withChange ? blobs : [:])
    var serverPort = serverAdapter ?? self.serverStorage.adapter(), clientPort = clientAdapter ?? self.clientStorage.adapter()
    if let serverJournalGeneration { serverPort.journalGeneration = serverJournalGeneration }
    if let clientJournalGeneration { clientPort.journalGeneration = clientJournalGeneration }
    if let serverJournalGate {
      let read = serverPort.changes
      serverPort.changes = { cursor, limit in await serverJournalGate.enter(); return try await read(cursor, limit) }
    }
    if let clientJournalGate {
      let read = clientPort.changes
      clientPort.changes = { cursor, limit in await clientJournalGate.enter(); return try await read(cursor, limit) }
    }
    self.serverAdapter = serverPort; self.clientAdapter = clientPort
    self.historyApplicationBuild = historyApplicationBuild ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }

  func start() throws {
    let key = NotebookTransportTLS.Key(identity: "device:\(credentialID)", secret: secret)
    let listener = try NWListener(using: NotebookTransportTLS.parameters(keys: [key], loopback: true)); self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self, !self.isStopped else { connection.cancel(); return }
        do {
          let session = try NotebookTransportSession(connection: connection, identity: self.serverIdentity, credential: nil,
            storage: self.serverAdapter, stagingRoot: self.root.appendingPathComponent("server"), queue: self.queue,
            historyApplicationBuild: self.historyApplicationBuild)
          self.server = session
          session.resolveCredential = { hello in
            guard hello.identity == self.clientIdentity, hello.credentialID == self.credentialID else { throw NotebookTransportError.identityMismatch }
            return .init(credentialID: self.credentialID, secret: self.secret, expectedPeer: self.clientIdentity)
          }
          self.configure(session); session.start()
        } catch { self.failed(error) }
      }
    }
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.isStopped else { return }
        switch state {
        case .ready:
          guard self.client == nil, let port = self.listener?.port else { return }
          do {
            let secret = self.wrongSecret ? Data(repeating: 18, count: 32) : self.secret
            let credential = NotebookPeerCredential(credentialID: self.credentialID, secret: secret, expectedPeer: self.serverIdentity)
            let connection: NWConnection
            if let route = self.relay {
              let enrollment = try await NotebookRelayHTTP.request(route, role: "host", action: "enable", as: NotebookRelayHTTP.Enrollment.self)
              let clientRoute = NotebookRelayRoute(endpoint: route.endpoint, route: route.route, capability: try XCTUnwrap(enrollment.clientCapability))
              let uplink = NotebookRelayUplink(route: route, port: port); self.uplink = uplink; uplink.start()
              try await Task.sleep(for: .seconds(2))
              let ticket = try await NotebookRelayHTTP.ticket(clientRoute, role: "client")
              connection = NWConnection(host: .init(route.tunnelHost), port: 443,
                using: try NotebookRelayHTTP.parameters(keys: [credential.tlsKey], route: clientRoute, ticket: ticket))
            } else {
              connection = NWConnection(host: "127.0.0.1", port: port,
                using: try NotebookTransportTLS.parameters(keys: [credential.tlsKey], loopback: true))
            }
            let session = try NotebookTransportSession(connection: connection, identity: self.clientIdentity, credential: credential,
              storage: self.clientAdapter, stagingRoot: self.root.appendingPathComponent("client"), queue: self.queue,
              historyApplicationBuild: self.historyApplicationBuild)
            self.client = session; self.configure(session); session.start()
          } catch { self.failed(error) }
        case .failed(let error): self.failed(error)
        default: break
        }
      }
    }
    listener.start(queue: queue)
  }

  func holdNetworkCallbacks() {
    precondition(!networkCallbacksHeld)
    networkCallbacksHeld = true; queue.suspend()
  }

  func releaseNetworkCallbacks() {
    guard networkCallbacksHeld else { return }
    networkCallbacksHeld = false; queue.resume()
  }

  func stop() {
    releaseNetworkCallbacks()
    isStopped = true; listener?.cancel(); listener = nil; uplink?.stop(); uplink = nil; server?.stop(); client?.stop()
    try? FileManager.default.removeItem(at: root)
  }

  func stopAndJoin() async {
    releaseNetworkCallbacks()
    isStopped = true; listener?.cancel(); listener = nil; uplink?.stop(); uplink = nil
    for session in [server, client].compactMap({ $0 }) { await session.stopAndJoin() }
    try? FileManager.default.removeItem(at: root)
  }

  private func configure(_ session: NotebookTransportSession) {
    let generation = session.generation
    session.onAuthenticated = { [weak self] identity, _ in
      guard let self else { throw NotebookTransportError.disconnected }
      self.onAuthenticated?(identity, generation)
      if let authorize = self.authorize { return try await authorize(identity) }
      return self.authorized
    }
    session.onReady = { [weak self] identity in self?.onReady?(identity, generation) }
    session.onTransient = { [weak self] value, peer in self?.onTransient?(value, peer) }
    session.onDurableChange = { [weak self] change, peer in self?.onDurable?(change, peer) }
    session.onHistoryControl = { [weak self] control, peer in self?.onHistoryControl?(control, peer) }
    session.onStop = { [weak self] peer, error in
      if let peer { self?.onStopped?(peer, error) }
      if let error { self?.failed(error) }
    }
  }
  private func failed(_ error: Error) {
    guard !isStopped, !reportedFailure else { return }
    reportedFailure = true; onFailure?(error)
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

actor NotebookTransportMemoryStore {
  private var journal: [NotebookDurableChange]
  private var blobs: [String: Data]
  private var incomingCursor: UInt64 = 0
  private var transactions: [UUID: String] = [:]
  private var holdCommit: Bool
  private let journalRequirement: NotebookTransportContentRequirement?
  private var commitContinuation: CheckedContinuation<Void, Never>?
  private var commitObserver: (@Sendable () -> Void)?
  private var committedObserver: (@Sendable () -> Void)?
  private var acknowledgementObserver: (@Sendable () -> Void)?
  private(set) var cursorReads = 0
  private(set) var acknowledgedCursor: UInt64 = 0
  private(set) var appliedCount = 0
  private(set) var largestStagedBlob = 0
  private(set) var stagedBatchSizes: [Int] = []
  private(set) var servedWindowSizes: [Int] = []
  private(set) var servedWindowBytes: [Int] = []
  private(set) var requestedJournalCursors: [UInt64] = []

  init(changes: [NotebookDurableChange] = [], blobs: [String: Data] = [:], holdCommit: Bool = false,
    journalRequirement: NotebookTransportContentRequirement? = nil) {
    journal = changes; self.blobs = blobs; self.holdCommit = holdCommit; self.journalRequirement = journalRequirement
  }
  func setCommitObserver(_ value: @escaping @Sendable () -> Void) { commitObserver = value }
  func setCommittedObserver(_ value: @escaping @Sendable () -> Void) { committedObserver = value }
  func setAcknowledgementObserver(_ value: @escaping @Sendable () -> Void) { acknowledgementObserver = value }
  func releaseCommit() { holdCommit = false; commitContinuation?.resume(); commitContinuation = nil }
  nonisolated func adapter() -> NotebookTransportStorage {
    .init(changes: { try await self.changes(after: $0, limit: $1) }, incomingCursor: { _ in await self.cursor() },
      acknowledgePeer: { _, cursor in await self.acknowledge(cursor) },
      readBlobWindow: { try await self.read($0) }, stageBlobs: { try await self.stage($0) },
      prepareIncoming: { try await self.prepare($0.change, staging: $1) }, applyRemoteChange: { try await self.apply($0.change) })
  }
  private func changes(after cursor: UInt64, limit: Int) throws -> [NotebookDurableChange] {
    requestedJournalCursors.append(cursor)
    if let journalRequirement { throw journalRequirement.error }
    return Array(journal.filter { $0.sequence > cursor }.prefix(limit))
  }
  private func cursor() -> UInt64 { cursorReads += 1; return incomingCursor }
  private func acknowledge(_ cursor: UInt64) { acknowledgedCursor = cursor; acknowledgementObserver?() }
  private func read(_ requests: [NotebookTransportBlobRequest]) throws -> [NotebookTransportBlobChunk] {
    try NotebookTransportBlobWindow.validate(requests)
    var chunks: [NotebookTransportBlobChunk] = []
    var remaining = NotebookTransportLimits.maximumBlobWindowBytes
    for request in requests {
      guard let data = blobs[request.hash], request.offset <= data.count else { throw NotebookTransportError.invalidBlob }
      let end = min(data.count, Int(request.offset) + min(remaining, NotebookTransportLimits.maximumChunkBytes))
      let bytes = data.subdata(in: Int(request.offset)..<end)
      chunks.append(.init(hash: request.hash, offset: request.offset, totalBytes: Int64(data.count), data: bytes))
      remaining -= bytes.count
      if remaining == 0 || end < data.count { break }
    }
    try NotebookTransportBlobWindow.validate(chunks, for: requests)
    servedWindowSizes.append(chunks.count)
    servedWindowBytes.append(chunks.reduce(0) { $0 + $1.data.count })
    return chunks
  }
  private func prepare(_ change: NotebookDurableChange, staging: [NotebookTransportCompletedBlob]) throws -> [String] {
    if !staging.isEmpty { try stage(staging) }
    return try missing(change, limit: NotebookTransportLimits.maximumBlobRequests, after: nil)
  }
  private func stage(_ batch: [NotebookTransportCompletedBlob]) throws {
    let checked = try batch.map { blob in
      let data: Data
      switch blob {
      case .bytes(_, let value): data = value
      case .file(_, let file, _): data = try Data(contentsOf: file)
      }
      guard data.count == blob.byteCount, Self.digest(data) == blob.hash else { throw NotebookTransportError.invalidBlob }
      return (blob.hash, data)
    }
    for (hash, data) in checked { blobs[hash] = data; largestStagedBlob = max(largestStagedBlob, data.count) }
    stagedBatchSizes.append(batch.count)
  }
  private func missing(_ change: NotebookDurableChange, limit: Int, after: String?) throws -> [String] {
    guard let data = blobs[change.manifestHash] else { return [change.manifestHash] }
    let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: data)
    return Array(Set(manifest.records.compactMap(\.blobHash)).filter { blobs[$0] == nil && (after == nil || $0 > after!) }.sorted().prefix(limit))
  }
  private func apply(_ change: NotebookDurableChange) async throws -> UInt64 {
    guard try missing(change, limit: 16, after: nil).isEmpty else { throw NotebookTransportError.invalidBlob }
    if let previous = transactions[change.transactionID] {
      guard previous == change.manifestHash else { throw NotebookTransportError.invalidBlob }; return incomingCursor
    }
    if holdCommit { commitObserver?(); await withCheckedContinuation { commitContinuation = $0 } }
    if change.sequence <= incomingCursor { return incomingCursor }
    // Deliberately ignore task cancellation here: a SQL commit that has started
    // may complete. The connection generation still cannot publish its ACK.
    transactions[change.transactionID] = change.manifestHash
    incomingCursor = change.sequence; appliedCount += 1; committedObserver?()
    return incomingCursor
  }
  func coverIncomingPrefix(through sequence: UInt64) { incomingCursor = max(incomingCursor, sequence) }
  func historyActivity() -> [Int] {
    [cursorReads, Int(acknowledgedCursor), appliedCount, stagedBatchSizes.count,
      servedWindowSizes.count, requestedJournalCursors.count]
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

actor NotebookTransportHistoryJournalGate {
  private var first = true
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var observer: (@Sendable () -> Void)?
  private(set) var calls = 0
  func setObserver(_ value: @escaping @Sendable () -> Void) { observer = value }
  func enter() async {
    calls += 1
    guard first else { return }
    first = false; observer?()
    if !released { await withCheckedContinuation { continuation = $0 } }
  }
  func release() { released = true; continuation?.resume(); continuation = nil }
}
