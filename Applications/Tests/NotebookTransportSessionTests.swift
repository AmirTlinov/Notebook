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
    XCTAssertEqual(applied, 1)
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
    let oldGeneration = try XCTUnwrap(pair.server).generation
    pair.stop()
    await pair.serverStorage.releaseCommit()
    await fulfillment(of: [finishedCommit], timeout: 10)
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
  private var reportedFailure = false
  private var isStopped = false

  init(wrongSecret: Bool = false, authorized: Bool = true, withChange: Bool = false, holdCommit: Bool = false,
    serverStorage: NotebookTransportMemoryStore? = nil, clientStorage: NotebookTransportMemoryStore? = nil,
    serverIdentity: NotebookTransportIdentity? = nil, clientIdentity: NotebookTransportIdentity? = nil, relay: NotebookRelayRoute? = nil, contentBytes: Int = 400_000, contentBlobCount: Int = 1,
    serverAdapter: NotebookTransportStorage? = nil, clientAdapter: NotebookTransportStorage? = nil) throws {
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
    self.serverAdapter = serverAdapter ?? self.serverStorage.adapter()
    self.clientAdapter = clientAdapter ?? self.clientStorage.adapter()
  }

  func start() throws {
    let key = NotebookTransportTLS.Key(identity: "device:\(credentialID)", secret: secret)
    let listener = try NWListener(using: NotebookTransportTLS.parameters(keys: [key], loopback: true)); self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self, !self.isStopped else { connection.cancel(); return }
        do {
          let session = try NotebookTransportSession(connection: connection, identity: self.serverIdentity, credential: nil,
            storage: self.serverAdapter, stagingRoot: self.root.appendingPathComponent("server"), queue: self.queue)
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
              storage: self.clientAdapter, stagingRoot: self.root.appendingPathComponent("client"), queue: self.queue)
            self.client = session; self.configure(session); session.start()
          } catch { self.failed(error) }
        case .failed(let error): self.failed(error)
        default: break
        }
      }
    }
    listener.start(queue: queue)
  }

  func stop() {
    isStopped = true; listener?.cancel(); listener = nil; uplink?.stop(); uplink = nil; server?.stop(); client?.stop()
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
      readBlobChunk: { try await self.read($0, offset: $1, count: $2) }, stageBlobs: { try await self.stage($0) },
      missingBlobHashes: { try await self.missing($0.change, limit: $1, after: $2) }, applyRemoteChange: { try await self.apply($0.change) })
  }
  private func changes(after cursor: UInt64, limit: Int) throws -> [NotebookDurableChange] {
    requestedJournalCursors.append(cursor)
    if let journalRequirement { throw journalRequirement.error }
    return Array(journal.filter { $0.sequence > cursor }.prefix(limit))
  }
  private func cursor() -> UInt64 { cursorReads += 1; return incomingCursor }
  private func acknowledge(_ cursor: UInt64) { acknowledgedCursor = cursor; acknowledgementObserver?() }
  private func read(_ hash: String, offset: Int64, count: Int) throws -> NotebookTransportBlobChunk {
    guard let data = blobs[hash], offset >= 0, offset <= data.count else { throw NotebookTransportError.invalidBlob }
    return .init(hash: hash, offset: offset, totalBytes: Int64(data.count), data: data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count)))
  }
  private func stage(_ batch: [NotebookTransportCompletedBlob]) throws {
    let checked = try batch.map { blob in
      let data = try Data(contentsOf: blob.file)
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
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
