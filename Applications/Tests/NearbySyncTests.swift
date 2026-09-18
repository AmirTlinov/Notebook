import CryptoKit
import Foundation
import Network
import NotebookCore
import XCTest
@testable import Notebook

final class NearbySyncTests: XCTestCase {
  @MainActor
  func testDiscoveryIncludesThePeerToPeerInterfacesUsedByTheTransport() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    trust.records = [confirmedPeer(for: sync)]
    await sync.start()
    XCTAssertTrue(try XCTUnwrap(sync.browser).parameters.includePeerToPeer,
      "Discovery must reach the same nearby interfaces as its TLS connections")
  }

  @MainActor
  func testDiscoveryWaitingReportsLocalNetworkDenialWithoutChangingTrust() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    let peer = confirmedPeer(for: sync); trust.records = [peer]
    await sync.start()
    let reported = expectation(description: "Local network permission failure is actionable")
    sync.onStateChange = { state in
      if case .failed(let message) = state, message.contains("Локальная сеть") { reported.fulfill() }
    }
    let callback = try XCTUnwrap(try XCTUnwrap(sync.browser).stateUpdateHandler)
    callback(.waiting(.dns(Int32(kDNSServiceErr_PolicyDenied))))
    await fulfillment(of: [reported], timeout: 1)
    XCTAssertEqual(sync.pairedPeers, [peer.identity]); XCTAssertEqual(trust.records, [peer])
    XCTAssertEqual(trust.saves, 0, "Discovery failure is not a reason to replace a trusted pair")
  }

  @MainActor
  func testRetiredBrowserCannotPublishFailureAfterDiscoveryRestarts() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    trust.records = [confirmedPeer(for: sync)]; await sync.start()
    let retired = try XCTUnwrap(sync.browser)
    let callback = try XCTUnwrap(retired.stateUpdateHandler)
    sync.stop(); await sync.start()
    XCTAssertFalse(sync.browser === retired)
    let staleFailure = expectation(description: "Retired discovery remains silent"); staleFailure.isInverted = true
    sync.onStateChange = { if case .failed = $0 { staleFailure.fulfill() } }
    callback(.failed(.posix(.ENETDOWN)))
    await fulfillment(of: [staleFailure], timeout: 0.3)
  }

  @MainActor
  private func confirmedPeer(for sync: NearbySync) -> NotebookTrustedDevice {
    .init(identity: .init(deviceID: UUID(), workspaceID: sync.identity.workspaceID, displayName: "Retained peer"),
      credentialID: UUID(), secret: Data(repeating: 3, count: 32))
  }

  @MainActor
  private func makeRecoverableSync(_ trust: RecoverableDeviceStore) -> NearbySync {
    let storage = NotebookTransportStorage(changes: { _, _ in [] }, incomingCursor: { _ in 0 },
      acknowledgePeer: { _, _ in }, blobSize: { _ in throw NotebookTransportError.invalidBlob },
      readBlobChunk: { _, _, _ in throw NotebookTransportError.invalidBlob }, stageBlob: { _, _, _ in },
      missingBlobHashes: { _, _, _ in [] }, applyRemoteChange: { _ in 0 })
    return NearbySync(role: .iPadConnector,
      identity: .init(deviceID: UUID(), workspaceID: UUID(), displayName: "Acceptance iPad"),
      storage: storage, stagingRoot: temporaryDirectory(), trustStore: trust)
  }

  @MainActor
  func testStoppedStartupCannotPublishLateCredentialsAndRestartReadsAgain() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    let peer = NotebookTrustedDevice(identity: .init(deviceID: UUID(), workspaceID: sync.identity.workspaceID,
      displayName: "Retained peer"), credentialID: UUID(), secret: Data(repeating: 3, count: 32))
    trust.records = [peer]; trust.suspendNextLoad = true
    let loading = expectation(description: "Credential read suspended")
    trust.onLoad = { loading.fulfill() }
    let first = Task { await sync.start() }
    await fulfillment(of: [loading], timeout: 2)
    sync.stop(); trust.onLoad = nil; trust.releaseLoad(); await first.value
    XCTAssertTrue(sync.pairedPeers.isEmpty, "A retired start cannot publish credentials or restart discovery")
    await sync.start()
    XCTAssertEqual(trust.loads, 2)
    XCTAssertEqual(sync.pairedPeers, [peer.identity])
  }

  @MainActor
  func testConcurrentDisconnectsTransformTheLastSavedTrustNotStaleCopies() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    let peers = (0..<2).map { index in
      NotebookTrustedDevice(identity: .init(deviceID: UUID(), workspaceID: sync.identity.workspaceID,
        displayName: "Peer \(index)"), credentialID: UUID(), secret: Data(repeating: 3, count: 32))
    }
    trust.records = peers; await sync.start()
    trust.suspendNextSave = true
    let saving = expectation(description: "First revocation awaits Keychain")
    trust.onSave = { saving.fulfill() }
    let first = Task { try await sync.setDeviceAllowed(peers[0].identity.deviceID, allowed: false) }
    await fulfillment(of: [saving], timeout: 2)
    let submitted = expectation(description: "Second revocation submitted")
    let second = Task { submitted.fulfill(); try await sync.setDeviceAllowed(peers[1].identity.deviceID, allowed: false) }
    await fulfillment(of: [submitted], timeout: 2)
    XCTAssertEqual(trust.saves, 1, "The next credential mutation cannot race the accepted write")
    XCTAssertEqual(trust.records, peers)
    trust.onSave = nil; trust.releaseSave()
    try await first.value; try await second.value
    XCTAssertEqual(trust.saves, 2)
    XCTAssertEqual(trust.records, peers); XCTAssertEqual(trust.state.blocked.count, 2); XCTAssertTrue(sync.pairedPeers.isEmpty)
  }

  @MainActor
  func testStopDuringCredentialWriteSuppressesPublicationButRetainsTheAcceptedWrite() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    let peer = NotebookTrustedDevice(identity: .init(deviceID: UUID(), workspaceID: sync.identity.workspaceID,
      displayName: "Retained peer"), credentialID: UUID(), secret: Data(repeating: 3, count: 32))
    trust.records = [peer]; await sync.start(); trust.suspendNextSave = true
    let saving = expectation(description: "Accepted revocation awaits Keychain")
    trust.onSave = { saving.fulfill() }
    let revoke = Task { try await sync.setDeviceAllowed(peer.identity.deviceID, allowed: false) }
    await fulfillment(of: [saving], timeout: 2)
    var stopped = false
    let stopping = expectation(description: "Shutdown submitted")
    let shutdown = Task { stopping.fulfill(); let result = await sync.stopAndDrainTrust(); stopped = true; return result }
    await fulfillment(of: [stopping], timeout: 2)
    XCTAssertFalse(stopped, "Shutdown cannot complete before the admitted Keychain write")
    trust.releaseSave()
    let drained = await shutdown.value; XCTAssertTrue(drained)
    do { try await revoke.value; XCTFail("A stopped transport cannot publish success") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(trust.state.blocked.contains(peer.identity.deviceID), "Stopping the UI cannot roll back an accepted revocation")
    await sync.start()
    XCTAssertTrue(sync.pairedPeers.isEmpty)
  }

  func testDiscoveryExcludesTheOldWriterButKeepsItsIdentityForUpgrade() throws {
    let id = UUID()
    let name = NotebookPeerDiscovery.serviceName(deviceID: id, generation: UUID())
    XCTAssertLessThanOrEqual(name.utf8.count, 63)
    let current = try XCTUnwrap(NotebookPeerDiscovery(serviceName: name))
    XCTAssertEqual(current.deviceID, id)
    XCTAssertTrue(current.isCompatible)
    let restarted = try XCTUnwrap(NotebookPeerDiscovery(serviceName: NotebookPeerDiscovery.serviceName(deviceID: id, generation: UUID())))
    XCTAssertEqual(restarted.deviceID, id); XCTAssertTrue(restarted.isCompatible)
    XCTAssertNotEqual(restarted.generation, current.generation)
    let old = try XCTUnwrap(NotebookPeerDiscovery(serviceName: "notebook-v1-\(id)"))
    XCTAssertEqual(old.deviceID, id)
    XCTAssertFalse(old.isCompatible)
    XCTAssertNil(NotebookPeerDiscovery(serviceName: "notebook-v10-not-an-identity"))
    XCTAssertNil(NotebookPeerDiscovery(serviceName: "unrelated-\(id)"))
  }

  func testUpgradeAndCheckpointFailuresAreNotReportedAsNetworkErrors() {
    for code in ["placement_migration_pending_peer", "placement_peer_upgrade_required", "placement_checkpoint_required"] {
      let error = CollaborationError(code, "Изменения сохранены; требуется обновление пары.")
      XCTAssertEqual(NotebookPeerDiscovery.upgradeMessage(for: error), error.localizedDescription)
    }
    XCTAssertNotNil(NotebookPeerDiscovery.upgradeMessage(for: NotebookTransportError.unsupportedVersion))
    XCTAssertNil(NotebookPeerDiscovery.upgradeMessage(for: NotebookTransportError.disconnected))
  }

  func testFrameLengthIsRejectedBeforeBodyAllocation() throws {
    XCTAssertThrowsError(try NotebookTransportFraming.payloadLength(Data([0, 4, 0, 0])))
    XCTAssertThrowsError(try NotebookTransportFraming.payloadLength(Data([0, 0, 0, 0])))
    XCTAssertThrowsError(try NotebookTransportFraming.payloadLength(Data([0, 0, 1])))
    XCTAssertEqual(try NotebookTransportFraming.payloadLength(Data([0, 3, 255, 252])), 262_140)
    let frame = try NotebookTransportFraming.encode(.init(sequence: 1, message: .blob(.init(
      hash: String(repeating: "a", count: 64), offset: 0, totalBytes: 184_320, data: Data(repeating: 42, count: 184_320)))))
    XCTAssertLessThanOrEqual(frame.count, NotebookTransportLimits.maximumFrameBytes)
    let packet = try NotebookTransportFraming.decode(Data(frame.dropFirst(4)))
    XCTAssertEqual(packet.sequence, 1)
    XCTAssertThrowsError(try NotebookTransportFraming.decode(Data("{\"version\":1}".utf8)))
  }

  func testSixteenCreditsAreIndependentFromDurableAcknowledgement() throws {
    var sender = NotebookTransportSendWindow()
    for sequence in 1...16 { XCTAssertEqual(try sender.reserve(), UInt64(sequence)) }
    XCTAssertThrowsError(try sender.reserve())
    XCTAssertThrowsError(try sender.acknowledge([17]))
    XCTAssertThrowsError(try sender.acknowledge([1, 1]))
    try sender.acknowledge([2])
    XCTAssertEqual(try sender.reserve(), 17)
    try sender.acknowledge([2]) // retransmitted credit cannot free a different frame
    XCTAssertEqual(sender.unacknowledged.count, 16)
  }

  func testReceiveWindowRejectsReplayGapsAndAnUnconsumedSeventeenthFrame() throws {
    var receiver = NotebookTransportReceiveWindow()
    XCTAssertThrowsError(try receiver.accept(2))
    for sequence in 1...16 { try receiver.accept(UInt64(sequence)) }
    XCTAssertThrowsError(try receiver.accept(17))
    try receiver.consumed(3)
    XCTAssertThrowsError(try receiver.accept(16))
    try receiver.accept(17)
    XCTAssertThrowsError(try receiver.consumed(3))
  }

  func testBulkReservesTwoCreditsForTheLatestContactAndCamera() throws {
    var outgoing = NotebookTransportOutgoing()
    for sequence in 1...16 { try outgoing.enqueue(.offer(change(sequence: UInt64(sequence)))) }
    for _ in 0..<14 { XCTAssertNotNil(try outgoing.takeNext()) }
    XCTAssertNil(try outgoing.takeNext())
    let deviceID = UUID(), sessionID = UUID()
    for sequence in 1...10_000 {
      try outgoing.enqueue(.transient(.presence(envelope(sessionID: sessionID, sequence: UInt64(sequence), centerX: Double(sequence)))))
      try outgoing.enqueue(.transient(.inputActivity(.init(deviceID: deviceID, sessionID: sessionID, sequence: UInt64(sequence), targets: []))))
    }
    XCTAssertEqual(outgoing.pendingCount, 4)
    let contact = try XCTUnwrap(outgoing.takeNext())
    guard case .transient(.inputActivity(let activity)) = contact.message else { return XCTFail("Contact must precede camera and bulk") }
    XCTAssertEqual(activity.sequence, 10_000)
    guard case .transient(.presence(let presence)) = try XCTUnwrap(outgoing.takeNext()).message else { return XCTFail("Camera uses the reserved second credit") }
    XCTAssertEqual(presence.sequence, 10_000)
    XCTAssertEqual(outgoing.window.unacknowledged.count, 16)
    XCTAssertNil(try outgoing.takeNext())
    try outgoing.acknowledge([1])
    XCTAssertNil(try outgoing.takeNext(), "Bulk cannot consume the contact/camera reservation")
    try outgoing.acknowledge([2, 3])
    XCTAssertNotNil(try outgoing.takeNext())
  }

  func testFreshNoncesBindProofToDeviceWorkspaceAndJournal() throws {
    let workspaceID = UUID(), pairID = UUID()
    let first = NotebookTransportHello(identity: .init(deviceID: UUID(), workspaceID: workspaceID, displayName: "Mac"),
      credentialID: pairID, nonce: Data(repeating: 1, count: 32))
    let second = NotebookTransportHello(identity: .init(deviceID: UUID(), workspaceID: workspaceID, displayName: "iPad"),
      credentialID: pairID, nonce: Data(repeating: 2, count: 32))
    let secret = Data(repeating: 3, count: 32)
    let transcript = try NotebookTransportAuthentication.transcript(first, second)
    let proof = NotebookTransportAuthentication.proof(secret: secret, transcript: transcript, sender: first.identity.deviceID)
    XCTAssertTrue(NotebookTransportAuthentication.verifies(proof, secret: secret, transcript: transcript, sender: first.identity.deviceID))
    XCTAssertFalse(NotebookTransportAuthentication.verifies(proof, secret: Data(repeating: 4, count: 32), transcript: transcript, sender: first.identity.deviceID))
    XCTAssertFalse(NotebookTransportAuthentication.verifies(proof, secret: secret, transcript: transcript, sender: second.identity.deviceID))
    let freshSecond = NotebookTransportHello(identity: second.identity, credentialID: pairID, nonce: Data(repeating: 5, count: 32))
    XCTAssertFalse(NotebookTransportAuthentication.verifies(proof, secret: secret,
      transcript: try NotebookTransportAuthentication.transcript(first, freshSecond), sender: first.identity.deviceID))
    let anotherJournal = NotebookTransportHello(identity: second.identity, credentialID: pairID,
      nonce: second.nonce, journalGeneration: UUID())
    XCTAssertFalse(NotebookTransportAuthentication.verifies(proof, secret: secret,
      transcript: try NotebookTransportAuthentication.transcript(first, anotherJournal), sender: first.identity.deviceID))
    let wrongWorkspace = NotebookTransportHello(identity: .init(deviceID: UUID(), workspaceID: UUID(), displayName: "Other"),
      credentialID: pairID, nonce: second.nonce)
    XCTAssertThrowsError(try NotebookTransportAuthentication.transcript(first, wrongWorkspace))
  }

  func testPresenceSequenceRejectsDuplicateAndOlderFrames() {
    var tracker = PresenceSequenceTracker()
    let sessionID = UUID(), newest = envelope(sessionID: UUID(), sequence: 4, centerX: 40)
    XCTAssertTrue(tracker.accepts(newest)); XCTAssertFalse(tracker.accepts(newest))
    XCTAssertTrue(tracker.accepts(envelope(sessionID: sessionID, sequence: 4, centerX: 40)))
    XCTAssertFalse(tracker.accepts(envelope(sessionID: sessionID, sequence: 3, centerX: 30)))
  }

  private func change(sequence: UInt64) -> NotebookDurableChange {
    .init(sequence: sequence, transactionID: UUID(), manifestHash: String(repeating: "a", count: 64), byteCount: 64)
  }
  private func envelope(sessionID: UUID, sequence: UInt64, centerX: Double) -> PresenceEnvelope {
    .init(sessionID: sessionID, sequence: sequence, phase: .active,
      presence: .init(mode: .board, camera: .init(center: .init(x: centerX, y: 0)), viewport: .init(x: 1_024, y: 1_366)))
  }
}

@MainActor
private final class RecoverableDeviceStore: NotebookDeviceTrustStore {
  var unavailable = true
  var state = NotebookDeviceTrustState()
  var records: [NotebookTrustedDevice] { get { state.records } set { state.records = newValue } }
  var suspendNextLoad = false
  var suspendNextSave = false
  var onLoad: (() -> Void)?
  var onSave: (() -> Void)?
  private var loadGate: CheckedContinuation<Void, Never>?
  private var saveGate: CheckedContinuation<Void, Never>?
  private(set) var loads = 0
  private(set) var saves = 0
  func load(for identity: NotebookTransportIdentity) async throws -> NotebookDeviceTrustState {
    loads += 1
    if unavailable { throw NotebookTransportError.storageUnavailable }
    onLoad?()
    if suspendNextLoad { suspendNextLoad = false; await withCheckedContinuation { loadGate = $0 } }
    return state
  }
  func save(_ state: NotebookDeviceTrustState, for identity: NotebookTransportIdentity) async throws {
    saves += 1
    if unavailable { throw NotebookTransportError.storageUnavailable }
    onSave?()
    if suspendNextSave { suspendNextSave = false; await withCheckedContinuation { saveGate = $0 } }
    self.state = state
  }
  func releaseLoad() { loadGate?.resume(); loadGate = nil }
  func releaseSave() { saveGate?.resume(); saveGate = nil }
}

final class NotebookTransportBlobTests: XCTestCase, @unchecked Sendable {
  func testBlobIsWrittenInBoundedChunksAndPublishedOnlyAfterExactHash() async throws {
    let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(repeating: 7, count: 400_000), hash = digest(bytes)
    let assembly = try NotebookTransportBlobAssembly(stagingRoot: root, generation: UUID())
    var complete: NotebookTransportCompletedBlob?
    for offset in stride(from: 0, to: bytes.count, by: NotebookTransportLimits.maximumChunkBytes) {
      let chunk = bytes.subdata(in: offset..<min(bytes.count, offset + NotebookTransportLimits.maximumChunkBytes))
      complete = try await assembly.append(.init(hash: hash, offset: Int64(offset), totalBytes: Int64(bytes.count), data: chunk), expectedHash: hash, maximumBytes: 500_000)
      if offset + chunk.count < bytes.count { XCTAssertNil(complete) }
    }
    let blob = try XCTUnwrap(complete)
    XCTAssertEqual(blob.byteCount, Int64(bytes.count)); XCTAssertEqual(try Data(contentsOf: blob.file), bytes)
    try await assembly.discardCompleted(blob); await assembly.cancel()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  func testWrongHashAndOffsetRemoveTheWholePartialGeneration() async throws {
    for wrongHash in [false, true] {
      let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
      let generation = UUID(), bytes = Data(repeating: 7, count: 4), hash = digest(bytes)
      let assembly = try NotebookTransportBlobAssembly(stagingRoot: root, generation: generation)
      _ = try await assembly.append(.init(hash: hash, offset: 0, totalBytes: 4, data: Data([7, 7])), expectedHash: hash, maximumBytes: 4)
      do {
        _ = try await assembly.append(.init(hash: hash, offset: wrongHash ? 2 : 1, totalBytes: 4,
          data: wrongHash ? Data([8, 8]) : Data([7, 7])), expectedHash: hash, maximumBytes: 4)
        XCTFail("Invalid bytes must not become a completed blob")
      } catch { }
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(generation.uuidString).path))
    }
  }

  func testOversizedBlobIsRejectedWithoutCreatingItsFile() async throws {
    let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let assembly = try NotebookTransportBlobAssembly(stagingRoot: root, generation: UUID())
    let hash = digest(Data([1]))
    do {
      _ = try await assembly.append(.init(hash: hash, offset: 0, totalBytes: NotebookTransportLimits.maximumBlobBytes + 1, data: Data([1])),
        expectedHash: hash, maximumBytes: NotebookTransportLimits.maximumBlobBytes)
      XCTFail("No truncation or allocation for oversized owners")
    } catch { }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }
}

private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("NotebookTransportTests-\(UUID())", isDirectory: true)
}
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
