import CryptoKit
import Foundation
import Network
import NotebookCore
import XCTest
@testable import Notebook

@MainActor private final class HandoverRoute { var value = NearbySync.Route.direct }

final class NearbySyncTests: XCTestCase {
  @MainActor
  func testTenAuthenticatedHandoversKeepOneCommandIdentityAndRejectStaleDisconnects() async throws {
    let workspace = UUID(), macID = UUID(), padID = UUID(), credentialID = UUID(), secret = Data(repeating: 87, count: 32)
    let macIdentity = NotebookTransportIdentity(deviceID: macID, workspaceID: workspace, displayName: "Mac route fixture")
    let padIdentity = NotebookTransportIdentity(deviceID: padID, workspaceID: workspace, displayName: "iPad route fixture")
    let macTrust = RecoverableDeviceStore(), padTrust = RecoverableDeviceStore()
    macTrust.unavailable = false; padTrust.unavailable = false
    macTrust.records = [.init(identity: padIdentity, credentialID: credentialID, secret: secret)]
    padTrust.records = [.init(identity: macIdentity, credentialID: credentialID, secret: secret)]
    let storage = NotebookTransportStorage(changes: { _, _ in [] }, incomingCursor: { _ in 0 }, acknowledgePeer: { _, _ in },
      blobSize: { _ in throw NotebookTransportError.invalidBlob }, readBlobChunk: { _, _, _ in throw NotebookTransportError.invalidBlob },
      stageBlob: { _, _, _ in }, missingBlobHashes: { _, _, _ in [] }, applyRemoteChange: { _ in 0 })
    let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let mac = NearbySync(role: .macListener, identity: macIdentity, storage: storage, stagingRoot: root.appendingPathComponent("mac"), trustStore: macTrust)
    let pad = NearbySync(role: .iPadConnector, identity: padIdentity, storage: storage, stagingRoot: root.appendingPathComponent("pad"), trustStore: padTrust)
    defer { mac.stop(); pad.stop() }
    await pad.start(); pad.browser?.cancel() // Deterministic endpoints, not a fabricated DNS advertisement.
    await mac.start()
    let listener = try NWListener(using: NotebookTransportTLS.parameters(keys: [macTrust.records[0].tlsKey], loopback: true))
    defer { listener.cancel() }
    let selectedRoute = HandoverRoute()
    listener.newConnectionHandler = { connection in Task { @MainActor in mac.addSession(connection: connection, credential: nil, route: selectedRoute.value) } }
    listener.start(queue: .init(label: "Notebook.Handover.Test"))
    let deadline = ContinuousClock.now + .seconds(5)
    while listener.port == nil || listener.port == .any, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let port = try XCTUnwrap(listener.port); XCTAssertNotEqual(port, .any)
    let credential = NotebookPeerCredential(credentialID: credentialID, secret: secret, expectedPeer: macIdentity)
    let thread = UUID().uuidString, turn = UUID().uuidString
    let request = CodexUserRequest(nativeID: .number(183), method: "item/commandExecution/requestApproval", turnID: turn, parameters: .object([:]))
    let action = NotebookChatAction.respond(threadID: thread, request: request, decision: .allowOnce)
    let input = NotebookChatInput(id: try XCTUnwrap(action.controlID(author: padID)), author: padID, action: action)
    let journal = NotebookStore(root: root.appendingPathComponent("journal"))
    _ = try journal.initializeWorkspace(actor: macID, pageSize: .init(width: 100, height: 100))
    var receipts = 0, executed = 0, disconnected = 0, generations = Set<UUID>()
    var retiredFailures = 0
    let stateChanged: (NotebookConnectionState) -> Void = { if case .failed = $0 { retiredFailures += 1 } }
    pad.onStateChange = stateChanged; mac.onStateChange = stateChanged
    pad.onConnect = { _, generation in
      generations.insert(generation)
      pad.sendTransient(.codex(.init(body: .request(.job(input)))), to: macID)
    }
    pad.onDisconnect = { _, _ in disconnected += 1 }
    mac.onTransient = { value, _, _ in
      guard case .codex(let envelope) = value, case .request(.job(let received)) = envelope.body else { return }
      XCTAssertEqual(received, input)
      do {
        var job = try journal.saveChatInput(received)
        if job.state == .saved {
          _ = try journal.advanceChatJob(job.id, from: .saved, to: .attempting)
          executed += 1
          job = try journal.advanceChatJob(job.id, from: .attempting, to: .accepted, result: .acknowledged)
        }
        mac.sendTransient(.codex(.init(id: envelope.id, body: .reply(.job(job)))), to: padID)
      } catch { XCTFail(error.localizedDescription) }
    }
    pad.onTransient = { value, _, _ in
      if case .codex(let envelope) = value, case .reply(.job(let job)) = envelope.body {
        XCTAssertEqual(job.id, input.id); XCTAssertEqual(job.state, .accepted); receipts += 1
      }
    }
    // These loopback TLS connections exercise production handover and journals;
    // the separate public-relay test verifies the actual internet carrier.
    for index in 0...10 {
      if index > 0 { pad.networkPathChanged(); pad.browser?.cancel() }
      let route: NearbySync.Route = index.isMultiple(of: 2) ? .direct : .nearby
      selectedRoute.value = route
      pad.addSession(connection: NWConnection(host: "127.0.0.1", port: port,
        using: try NotebookTransportTLS.parameters(keys: [credential.tlsKey])), credential: credential, route: route)
      let deadline = ContinuousClock.now + .seconds(5)
      while receipts <= index, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertEqual(receipts, index + 1); XCTAssertEqual(pad.routeTitle(for: macID), NearbySync.Route.direct.title)
      XCTAssertEqual(mac.routeTitle(for: padID), NearbySync.Route.direct.title, "A nearby discovery hint cannot turn loopback into AWDL")
    }
    XCTAssertEqual(executed, 1); XCTAssertEqual(generations.count, 11)
    XCTAssertEqual(retiredFailures, 0, "An old goodbye must not report the replacement channel as failed")
    XCTAssertEqual(disconnected, 0, "A retired generation cannot disconnect the new selected route")
    XCTAssertEqual(try journal.recentChatJobs(author: padID).count, 1)
  }

  @MainActor
  func testDiscoveryUsesLANFirstAndBoundsPeerToPeerSearch() async throws {
    let trust = RecoverableDeviceStore(); trust.unavailable = false
    let sync = makeRecoverableSync(trust); defer { sync.stop() }
    trust.records = [confirmedPeer(for: sync)]
    await sync.start()
    XCTAssertFalse(try XCTUnwrap(sync.browser).parameters.includePeerToPeer)
    let deadline = ContinuousClock.now + .seconds(7)
    while sync.browser?.parameters.includePeerToPeer != true, .now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    XCTAssertTrue(try XCTUnwrap(sync.browser).parameters.includePeerToPeer,
      "Only the bounded nearby search enables peer-to-peer interfaces")
    sync.resumeDiscovery()
    XCTAssertFalse(try XCTUnwrap(sync.browser).parameters.includePeerToPeer,
      "Foreground after an offline sleep starts a fresh bounded LAN-first window")
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

  func testDiscoverySelectsWorkspaceWhenOneMacRetainsMultipleListeners() {
    let selected = UUID(), background = UUID()
    XCTAssertTrue(NotebookPeerDiscovery.matches(.bonjour(NotebookPeerDiscovery.metadata(workspaceID: selected)), workspaceID: selected))
    XCTAssertFalse(NotebookPeerDiscovery.matches(.bonjour(NotebookPeerDiscovery.metadata(workspaceID: background)), workspaceID: selected))
    XCTAssertFalse(NotebookPeerDiscovery.matches(.bonjour(NWTXTRecord()), workspaceID: selected))
    XCTAssertFalse(NotebookPeerDiscovery.matches(.bonjour(NWTXTRecord(["workspace": "invalid"])), workspaceID: selected))
    XCTAssertFalse(NotebookPeerDiscovery.matches(.none, workspaceID: selected))
  }

  func testUpgradeAndCheckpointFailuresAreNotReportedAsNetworkErrors() {
    for code in ["placement_migration_pending_peer", "ink_migration_pending_peer", "placement_peer_upgrade_required", "format_checkpoint_required"] {
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
