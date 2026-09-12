import CryptoKit
import Foundation
import Network
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookTransportSessionTests: XCTestCase {
  func testImmediateJournalBoundaryStopsBothEndsWithTheSameReason() async throws {
    let rejected = expectation(description: "Both peers know why exchange stopped"); rejected.expectedFulfillmentCount = 2
    let source = NotebookTransportMemoryStore(journalRequirement: .checkpoint)
    let pair = try NotebookTransportTestPair(serverStorage: source)
    defer { pair.stop() }
    var stopped: Set<UUID> = []
    pair.onStopped = { identity, error in
      XCTAssertTrue(stopped.insert(identity.deviceID).inserted)
      XCTAssertEqual((error as? CollaborationError)?.code, "placement_checkpoint_required")
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
      XCTAssertEqual((error as? CollaborationError)?.code, "placement_checkpoint_required")
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
    // 1.2 / 0xCCAC, PSK proof and both human-confirmation records.
  }

  func testCodexEnvelopeUsesTheSameAuthenticatedPeerAndReceiptID() async throws {
    let ready = expectation(description: "Existing pair ready"); ready.expectedFulfillmentCount = 2
    let received = expectation(description: "Receipt and event returned through TLS"); received.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair()
    defer { pair.stop() }
    let input = NotebookChatInput(author: pair.clientIdentity.deviceID,
      action: .send(threadID: UUID().uuidString, text: "x² ≥ 0", context: ""))
    let envelope = NotebookChatEnvelope(body: .request(.job(input)))
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
        let state = CodexConversation(threadID: input.action.threadID!, revision: 4, title: "Task", ready: true,
          busy: false, activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:])
        pair.server?.sendTransient(.codex(.init(body: .event(subscriptionID: envelope.id, conversation: state))))
      case .event(let subscription, let state):
        XCTAssertEqual(subscription, envelope.id); XCTAssertEqual(state.revision, 4)
        XCTAssertNotEqual(peer.deviceID, input.author); received.fulfill()
      default: XCTFail("Unexpected chat reply")
      }
    }
    try pair.start(); await fulfillment(of: [ready], timeout: 10)
    pair.client?.sendTransient(.codex(envelope))
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
    XCTAssertEqual(reads, 0, "Even the durable cursor remains unread before pairing")
  }

  func testPairingRequiresBothConfirmationsBeforeAnyContentOrCursor() async throws {
    let authenticated = expectation(description: "Both TLS identities proved"); authenticated.expectedFulfillmentCount = 2
    let ready = expectation(description: "Both peers explicitly confirmed"); ready.expectedFulfillmentCount = 2
    let pair = try NotebookTransportTestPair(autoConfirm: false)
    defer { pair.stop() }
    pair.onAuthenticated = { _, _ in authenticated.fulfill() }
    pair.onReady = { _, _ in ready.fulfill() }
    try pair.start()
    await fulfillment(of: [authenticated], timeout: 10)
    let server = try XCTUnwrap(pair.server), client = try XCTUnwrap(pair.client)
    XCTAssertFalse(server.isReady); XCTAssertFalse(client.isReady)
    let cursorReads = await pair.serverStorage.cursorReads + pair.clientStorage.cursorReads
    XCTAssertEqual(cursorReads, 0)
    XCTAssertThrowsError(try server.receive(.init(sequence: 1, message: .offer(pair.sampleChange))))
    XCTAssertThrowsError(try client.receive(.init(sequence: 0, message: .ready(cursor: 0))))
    XCTAssertThrowsError(try client.receive(.init(sequence: 0, message: .contentUnavailable(.checkpoint))))
    try client.confirmPairing()
    XCTAssertFalse(server.isReady); XCTAssertFalse(client.isReady)
    try server.confirmPairing()
    await fulfillment(of: [ready], timeout: 10)
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
private final class NotebookTransportTestPair {
  let serverIdentity: NotebookTransportIdentity
  let clientIdentity: NotebookTransportIdentity
  let serverStorage: NotebookTransportMemoryStore
  let clientStorage: NotebookTransportMemoryStore
  let sampleChange: NotebookDurableChange
  var server: NotebookTransportSession?
  var client: NotebookTransportSession?
  var onReady: ((NotebookTransportIdentity, UUID) -> Void)?
  var onAuthenticated: ((NotebookTransportIdentity, UUID) -> Void)?
  var onTransient: ((NotebookTransportTransient, NotebookTransportIdentity) -> Void)?
  var onDurable: ((NotebookDurableChange, NotebookTransportIdentity) -> Void)?
  var onFailure: ((Error) -> Void)?
  var onStopped: ((NotebookTransportIdentity, Error?) -> Void)?
  private let autoConfirm: Bool
  private let wrongSecret: Bool
  private let pairingID = UUID()
  private let secret = Data(repeating: 17, count: 32)
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookTLSLoopback-\(UUID())")
  private let queue = DispatchQueue(label: "Notebook.Tests.TLSLoopback")
  private var listener: NWListener?
  private var reportedFailure = false
  private var isStopped = false

  init(wrongSecret: Bool = false, autoConfirm: Bool = true, withChange: Bool = false, holdCommit: Bool = false,
    serverStorage: NotebookTransportMemoryStore? = nil, clientStorage: NotebookTransportMemoryStore? = nil,
    serverIdentity: NotebookTransportIdentity? = nil, clientIdentity: NotebookTransportIdentity? = nil) throws {
    let workspaceID = serverIdentity?.workspaceID ?? UUID()
    self.serverIdentity = serverIdentity ?? .init(deviceID: UUID(), workspaceID: workspaceID, displayName: "Loopback Mac")
    self.clientIdentity = clientIdentity ?? .init(deviceID: UUID(), workspaceID: workspaceID, displayName: "Loopback iPad")
    self.wrongSecret = wrongSecret; self.autoConfirm = autoConfirm
    let content = Data(repeating: 7, count: 400_000), contentHash = Self.digest(content), transactionID = UUID()
    let manifest = try JSONEncoder().encode(NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID,
      records: [.init(address: "pages/test.json", blobHash: contentHash)]))
    let manifestHash = Self.digest(manifest)
    sampleChange = .init(sequence: 1, transactionID: transactionID, manifestHash: manifestHash, byteCount: manifest.count)
    self.serverStorage = serverStorage ?? NotebookTransportMemoryStore(holdCommit: holdCommit)
    self.clientStorage = clientStorage ?? NotebookTransportMemoryStore(changes: withChange ? [sampleChange] : [],
      blobs: withChange ? [manifestHash: manifest, contentHash: content] : [:])
  }

  func start() throws {
    let key = NotebookTransportTLS.Key(identity: "paired:\(pairingID)", secret: secret)
    let listener = try NWListener(using: NotebookTransportTLS.parameters(keys: [key], loopback: true)); self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self, !self.isStopped else { connection.cancel(); return }
        do {
          let session = try NotebookTransportSession(connection: connection, identity: self.serverIdentity, credential: nil,
            storage: self.serverStorage.adapter(), stagingRoot: self.root.appendingPathComponent("server"), queue: self.queue)
          self.server = session
          session.resolveCredential = { hello in
            guard hello.identity == self.clientIdentity, hello.pairingID == self.pairingID else { throw NotebookTransportError.identityMismatch }
            return .init(pairingID: self.pairingID, kind: .paired, secret: self.secret, expectedPeer: self.clientIdentity)
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
            let credential = NotebookPeerCredential(pairingID: self.pairingID, kind: .paired, secret: secret, expectedPeer: self.serverIdentity)
            let connection = NWConnection(host: "127.0.0.1", port: port,
              using: try NotebookTransportTLS.parameters(keys: [credential.tlsKey], loopback: true))
            let session = try NotebookTransportSession(connection: connection, identity: self.clientIdentity, credential: credential,
              storage: self.clientStorage.adapter(), stagingRoot: self.root.appendingPathComponent("client"), queue: self.queue)
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
    isStopped = true; listener?.cancel(); listener = nil; server?.stop(); client?.stop()
    try? FileManager.default.removeItem(at: root)
  }

  private func configure(_ session: NotebookTransportSession) {
    let generation = session.generation
    session.onAuthenticated = { [weak self] identity, _ in
      guard let self else { throw NotebookTransportError.disconnected }
      self.onAuthenticated?(identity, generation); return self.autoConfirm
    }
    session.onConfirmation = { _, _, _ in } // persisted trust is injected, never the user's Keychain
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

private actor NotebookTransportMemoryStore {
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
      acknowledgePeer: { _, cursor in await self.acknowledge(cursor) }, blobSize: { try await self.size($0) },
      readBlobChunk: { try await self.read($0, offset: $1, count: $2) }, stageBlob: { try await self.stage($0, hash: $1, byteCount: $2) },
      missingBlobHashes: { try await self.missing($0, limit: $1, after: $2) }, applyRemoteChange: { change, _ in try await self.apply(change) })
  }
  private func changes(after cursor: UInt64, limit: Int) throws -> [NotebookDurableChange] {
    requestedJournalCursors.append(cursor)
    if let journalRequirement { throw journalRequirement.error }
    return Array(journal.filter { $0.sequence > cursor }.prefix(limit))
  }
  private func cursor() -> UInt64 { cursorReads += 1; return incomingCursor }
  private func acknowledge(_ cursor: UInt64) { acknowledgedCursor = cursor; acknowledgementObserver?() }
  private func size(_ hash: String) throws -> Int64 {
    guard let data = blobs[hash] else { throw NotebookTransportError.invalidBlob }; return Int64(data.count)
  }
  private func read(_ hash: String, offset: Int64, count: Int) throws -> Data {
    guard let data = blobs[hash], offset >= 0, offset <= data.count else { throw NotebookTransportError.invalidBlob }
    return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
  }
  private func stage(_ file: URL, hash: String, byteCount: Int64) throws {
    let data = try Data(contentsOf: file)
    guard data.count == byteCount, Self.digest(data) == hash else { throw NotebookTransportError.invalidBlob }
    blobs[hash] = data; largestStagedBlob = max(largestStagedBlob, data.count)
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
    // Deliberately ignore task cancellation here: a SQL commit that has started
    // may complete. The connection generation still cannot publish its ACK.
    transactions[change.transactionID] = change.manifestHash
    incomingCursor = change.sequence; appliedCount += 1; committedObserver?()
    return incomingCursor
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
