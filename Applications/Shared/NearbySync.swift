import CryptoKit
import Foundation
import Network
import NotebookCore
import OSLog
import Security

/// Presence belongs to the current authenticated connection generation. The
/// small retired-session set rejects delayed callbacks without growing forever.
struct PresenceSequenceTracker {
  private var latestBySession: [UUID: UInt64] = [:]
  private var sessions: [UUID] = []
  mutating func accepts(_ envelope: PresenceEnvelope) -> Bool {
    guard envelope.isValid, envelope.sequence > latestBySession[envelope.sessionID, default: 0] else { return false }
    if latestBySession[envelope.sessionID] == nil {
      sessions.append(envelope.sessionID)
      if sessions.count > 8 { latestBySession.removeValue(forKey: sessions.removeFirst()) }
    }
    latestBySession[envelope.sessionID] = envelope.sequence
    return true
  }
}

/// This is an explicit TLS profile, not fallback negotiation. Apple's external
/// PSK path is tested with TLS 1.2 ECDHE-PSK/ChaCha20-Poly1305 (RFC 7905). ECDHE
/// supplies forward secrecy; the saved device key supplies authentication.
/// Both peers reject any other negotiated suite BEFORE sending application data.
/// TLS 1.3 and certificate trust overrides are deliberately not alternate paths.
enum NotebookTransportTLS {
  static let cipher: UInt16 = 0xCCAC
  struct Key: Sendable { let identity: String; let secret: Data }

  static func parameters(keys: [Key], loopback: Bool = false) throws -> NWParameters {
    guard !keys.isEmpty, keys.count <= 8,
      keys.allSatisfy({ $0.secret.count == 32 && !$0.identity.isEmpty && $0.identity.utf8.count <= 100 })
    else { throw NotebookTransportError.authenticationRequired }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: cipher)!)
    sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
    sec_protocol_options_set_tls_false_start_enabled(tls.securityProtocolOptions, false)
    for key in keys {
      sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(key.secret), dispatchData(Data(key.identity.utf8)))
    }
    let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
    tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 3; tcp.keepaliveCount = 2
    let parameters = NWParameters(tls: tls, tcp: tcp)
    parameters.includePeerToPeer = !loopback
    if loopback { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
    return parameters
  }

  static func accepts(_ connection: NWConnection) -> Bool {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
    return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv12
      && sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue == cipher
  }

  static func randomBytes(count: Int) throws -> Data {
    var bytes = Data(count: count)
    let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    guard result == errSecSuccess else { throw NotebookTransportError.storageUnavailable }
    return bytes
  }

  private static func dispatchData(_ value: Data) -> dispatch_data_t {
    value.withUnsafeBytes { DispatchData(bytes: $0) } as dispatch_data_t
  }
}

/// Discovery advertises compatibility, never authority. Only TLS and the saved
/// pair admit content; an older board writer must not enter that exchange.
struct NotebookPeerDiscovery: Equatable {
  let deviceID: UUID
  let version: Int
  let generation: String?
  var isCompatible: Bool { version == NotebookTransportLimits.protocolVersion && generation != nil }
  static func serviceName(deviceID: UUID, generation: UUID) -> String {
    let epoch = generation.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    return "notebook-v\(NotebookTransportLimits.protocolVersion)-\(deviceID)-\(epoch)"
  }
  static func metadata(workspaceID: UUID) -> NWTXTRecord {
    NWTXTRecord(["workspace": workspaceID.uuidString.lowercased()])
  }
  static func matches(_ metadata: NWBrowser.Result.Metadata, workspaceID: UUID) -> Bool {
    guard case .bonjour(let record) = metadata, let value = record["workspace"] else { return false }
    return UUID(uuidString: value) == workspaceID
  }
  init?(serviceName: String) {
    guard serviceName.hasPrefix("notebook-v") else { return nil }
    let suffix = serviceName.dropFirst("notebook-v".count)
    guard let split = suffix.firstIndex(of: "-"), let version = Int(suffix[..<split]), version > 0 else { return nil }
    let identity = suffix[suffix.index(after: split)...]
    guard let deviceID = UUID(uuidString: String(identity.prefix(36))) else { return nil }
    let tail = identity.dropFirst(36)
    if tail.isEmpty { generation = nil }
    else {
      guard tail.first == "-", tail.count == 13, tail.dropFirst().allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
      generation = String(tail.dropFirst())
    }
    self.deviceID = deviceID; self.version = version
  }
  static func upgradeMessage(for error: Error) -> String? {
    if let error = error as? CollaborationError,
      ["placement_migration_pending_peer", "placement_peer_upgrade_required", "format_checkpoint_required", "ink_migration_pending_peer"].contains(error.code) {
      return error.localizedDescription
    }
    if error as? NotebookTransportError == .unsupportedVersion {
      return "Обновите Notebook на обоих устройствах. Их версии обмена несовместимы; содержание и сопряжение сохранены."
    }
    return nil
  }
}

@MainActor
final class NearbySync {
  enum Role { case macListener, iPadConnector }
  enum Route: Int { case direct, nearby, relay
    var title: String { switch self { case .direct: "напрямую"; case .nearby: "рядом"; case .relay: "через интернет" } }
  }
  private var sessionRoutes: [UUID: Route] = [:]
  private var relayTasks: [UUID: Task<Void, Never>] = [:]
  private var uplinks: [UUID: NotebookRelayUplink] = [:]
  private var discoveryStop: Task<Void, Never>?
  private var pathMonitor: NWPathMonitor?
  private var networkChange: Task<Void, Never>?
  private var reconnectFailures = 0
  private var pathEpoch: UInt64 = 0
  private var sessionEpochs: [UUID: UInt64] = [:]
  private var nearbySearchAllowed = true
  var onDeviceRevoked: ((UUID) -> Void)?
  func routeTitle(for peer: UUID) -> String? { currentGeneration[peer].flatMap { sessionRoutes[$0]?.title } }
  func remoteEnabled(for peer: UUID) -> Bool { trust.relays?[peer] != nil }

  var onStateChange: ((NotebookConnectionState) -> Void)?
  var onConnect: ((NotebookTransportIdentity, UUID) -> Void)?
  var onDisconnect: ((UUID, UUID) -> Void)?
  var onTransient: ((NotebookTransportTransient, UUID, UUID) -> Void)?
  var onDurableChange: ((NotebookDurableChange, UUID, UUID) -> Void)?
  var onHistoryControl: ((NotebookHistoryControl, UUID, UUID) -> Void)?
  var onHistoryProgress: ((NotebookHistoryTransportObservation, UUID, UUID) -> Void)?
  private struct HistoryControlRequest {
    let scope: NotebookHistoryControlScope
    let connection: NotebookTransportSession
    let retiring: [NotebookTransportSession]
    let callbacks: [Task<Void, Never>]
    var connectionID: UUID { connection.generation }
  }
  private var historyControl: HistoryControlRequest?
  var pairedPeers: [NotebookTransportIdentity] { trusted.map(\.identity) }
  var knownPeers: [NotebookTransportIdentity] { trust.records.map(\.identity).filter { !retiredPeers.contains($0.deviceID) } }

  let identity: NotebookTransportIdentity
  private let role: Role
  private let storage: NotebookTransportStorage
  private let stagingRoot: URL
  private let trustStore: any NotebookDeviceTrustStore
  private let queue = DispatchQueue(label: "Notebook.Nearby.TLS")
  private var trust = NotebookDeviceTrustState()
  private let retiredPeers: Set<UUID>
  private var trusted: [NotebookTrustedDevice] {
    trust.records.filter { !trust.blocked.contains($0.identity.deviceID) && !retiredPeers.contains($0.identity.deviceID) }
  }
  var savedTrust: NotebookDeviceTrustState { trust }

  func historyBoundaryObservation(for peerID: UUID) -> NotebookHistoryTransportObservation? {
    currentGeneration[peerID].flatMap { sessions[$0]?.historyBoundaryObservation }
  }

  func proposeHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    try selectedHistorySession(preparation).proposeHistoryPreparation(preparation)
  }

  func admitHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    guard historyControl == nil, startup == nil, trustWrite == nil else { throw NotebookTransportError.historyNotDrained }
    try selectedHistorySession(preparation).admitHistoryPreparation(preparation)
  }

  func sendHistoryPrepared(_ prepared: NotebookHistoryControl.Prepared,
    preparation: NotebookHistoryControlPreparation) throws {
    try selectedHistorySession(preparation).sendHistoryPrepared(prepared)
  }

  func resumeHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    guard historyControl == nil else { throw NotebookTransportError.historyCutStale }
    try selectedHistorySession(preparation).resumeHistoryPreparation(preparation)
  }

  func proposeHistoryControl(_ scope: NotebookHistoryControlScope) throws {
    try selectedHistorySession(scope).proposeHistoryControl(scope)
  }

  func admitHistoryControl(_ scope: NotebookHistoryControlScope) throws {
    let session = try selectedHistorySession(scope)
    if let current = historyControl {
      guard current.scope == scope, current.connectionID == session.generation else {
        throw NotebookTransportError.historyReadinessPending
      }
      return
    }
    guard startup == nil, trustWrite == nil else { throw NotebookTransportError.historyNotDrained }
    let retiring = sessions.values.filter { $0.generation != session.generation }
    guard retiring.allSatisfy({ $0.historyBoundaryObservation.pendingDurableWork == 0
      && !$0.historyBoundaryObservation.hasStorageCallback }) else { throw NotebookTransportError.historyNotDrained }
    try session.admitHistoryControl(scope)
    let callbacks = [retryTask, discoveryStop, networkChange].compactMap { $0 } + Array(relayTasks.values)
    historyControl = .init(scope: scope, connection: session, retiring: retiring, callbacks: callbacks)
    for task in callbacks { task.cancel() }
    browser?.cancel(); browser = nil
    // A selected relay's physical uplink remains alive. These retired owners
    // stay retained until their actual callbacks join, despite onStop removal.
    for other in retiring { other.stop(notifyingPeer: false) }
  }

  func quiesceHistoryControl(_ scope: NotebookHistoryControlScope) async throws {
    try admitHistoryControl(scope)
    guard let current = historyControl, current.scope == scope else { throw NotebookTransportError.historyCutStale }
    for other in current.retiring { await other.stopAndJoin() }
    for task in current.callbacks { await task.value }
    try Task.checkCancellation()
    guard historyControl?.scope == scope, historyControl?.connectionID == current.connectionID,
      let peer = current.connection.peerIdentity, currentGeneration[peer.deviceID] == current.connectionID else {
      throw NotebookTransportError.historyCutStale
    }
    try await current.connection.quiesceHistoryControl(scope)
  }

  func sendHistoryControlAwaitingCredit(_ control: NotebookHistoryControl,
    scope: NotebookHistoryControlScope) async throws {
    guard let current = historyControl, current.scope == scope,
      let peer = current.connection.peerIdentity, currentGeneration[peer.deviceID] == current.connectionID else {
      throw NotebookTransportError.historyCutStale
    }
    try await current.connection.sendHistoryControlAwaitingCredit(control, scope: scope)
    guard historyControl?.scope == scope, historyControl?.connectionID == current.connectionID,
      currentGeneration[peer.deviceID] == current.connectionID else { throw NotebookTransportError.historyCutStale }
  }

  func resumeHistoryControl(_ scope: NotebookHistoryControlScope,
    refusal: NotebookHistoryControl.Refusal? = nil) async throws {
    guard let current = historyControl, current.scope == scope else { throw NotebookTransportError.historyCutStale }
    do {
      try await current.connection.resumeHistoryControl(scope, refusal: refusal)
      guard historyControl?.scope == scope, let peer = current.connection.peerIdentity,
        currentGeneration[peer.deviceID] == current.connectionID else { throw NotebookTransportError.historyCutStale }
      historyControl = nil; refreshDiscovery()
    } catch {
      await current.connection.stopAndJoin()
      for other in current.retiring { await other.stopAndJoin() }
      for task in current.callbacks { await task.value }
      if historyControl?.scope == scope { historyControl = nil }
      refreshDiscovery(); connectDiscoveredPeers(); connectRelayPeers()
      throw error
    }
  }

  private func selectedHistorySession(_ scope: NotebookHistoryControlScope) throws -> NotebookTransportSession {
    guard scope.isValid else { throw NotebookTransportError.identityMismatch }
    return try selectedHistorySession(scope.preparation)
  }
  private func selectedHistorySession(_ preparation: NotebookHistoryControlPreparation) throws -> NotebookTransportSession {
    guard isStarted, preparation.isValid, preparation.workspaceID == identity.workspaceID,
      preparation.endpoint(for: identity.deviceID)?.identity == identity,
      Set(trust.records.map { $0.identity.deviceID }).union([identity.deviceID]) == Set(preparation.endpoints.map { $0.identity.deviceID }),
      let peer = preparation.endpoints.first(where: { $0.identity.deviceID != identity.deviceID }),
      trusted.contains(where: { $0.identity == peer.identity && $0.credentialID == preparation.credentialID }),
      let connectionID = currentGeneration[peer.identity.deviceID], let session = sessions[connectionID], session.isReady else {
      throw NotebookTransportError.identityMismatch
    }
    return session
  }

  func historyFleetObservation(directory: NotebookAccountSnapshot?,
    directoryStatus: NotebookHistoryFleetObservation.DirectoryStatus) throws -> NotebookHistoryFleetObservation {
    try .init(local: identity, trust: trust, directory: directory, directoryStatus: directoryStatus,
      locallyRetired: retiredPeers, connections: sessions.values.map { session in
        session.historyObservation(selected: session.peerIdentity.map {
          currentGeneration[$0.deviceID] == session.generation
        } ?? false)
      })
  }
  private(set) var listener: NWListener?
  private(set) var browser: NWBrowser?
  private var endpointByPeer: [UUID: NWEndpoint] = [:]
  private let discoveryGeneration = UUID()
  private var suspendedPeers: Set<UUID> = []
  private var sessions: [UUID: NotebookTransportSession] = [:]
  private var currentGeneration: [UUID: UUID] = [:]
  private var retryTask: Task<Void, Never>?
  private var isStarted = false
  private var lifetime = UUID()
  private var startup: (id: UUID, task: Task<Void, Error>)?
  private var trustWrite: (id: UUID, task: Task<Void, Error>)?
  private let logger = Logger(subsystem: "com.amirtlinov.notebook", category: "NearbySync")

  init(role: Role, identity: NotebookTransportIdentity, storage: NotebookTransportStorage, stagingRoot: URL,
    trustStore: (any NotebookDeviceTrustStore)? = nil, retiredPeers: Set<UUID> = []) {
    self.role = role; self.identity = identity; self.storage = storage; self.stagingRoot = stagingRoot
    self.retiredPeers = retiredPeers
    self.trustStore = trustStore ?? NotebookKeychainDeviceStore()
  }

  func start() async {
    do { try await startIfNeeded() }
    catch is CancellationError {} catch { report(error) }
  }

  private func startIfNeeded(account: String? = nil) async throws {
    guard historyControl == nil else { throw NotebookTransportError.historyReadinessPending }
    guard !isStarted else { return }
    if let startup { try await startup.task.value; return }
    let epoch = lifetime, id = UUID(), previous = trustWrite?.task
    let task = Task { @MainActor [self] in
      // A stopped owner's already accepted Keychain write must finish before
      // a new start reads trust. It cannot resurrect discovery on completion.
      if let previous { _ = await previous.result }
      try Task.checkCancellation()
      guard lifetime == epoch else { throw CancellationError() }
      guard identity.isValid else { throw NotebookTransportError.identityMismatch }
      let records = try await trustStore.load(for: identity)
      try Task.checkCancellation()
      guard lifetime == epoch else { throw CancellationError() }
      if let account, let bound = records.account, account != bound { throw NotebookTransportError.identityMismatch }
      trust = records
      // Only abandoned generation directories beneath this transport-owned
      // cache are removed. Authoritative SQLite blobs are never staging files.
      if FileManager.default.fileExists(atPath: stagingRoot.path) {
        for url in try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)
          where UUID(uuidString: url.lastPathComponent) != nil {
          try FileManager.default.removeItem(at: url)
        }
      }
      isStarted = true
      let monitor = NWPathMonitor(); pathMonitor = monitor
      monitor.pathUpdateHandler = { [weak self] _ in
        Task { @MainActor in
          guard let self, self.isStarted else { return }
          self.networkChange?.cancel()
          self.networkChange = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.isStarted else { return }
            self.networkPathChanged()
          }
        }
      }
      monitor.start(queue: queue)
      refreshDiscovery()
    }
    startup = (id, task)
    defer { if startup?.id == id { startup = nil } }
    try await task.value
  }

  /// Only credential mutations are ordered here. Each transform sees the
  /// last saved state, not a stale snapshot from before another change.
  /// Content delivery and active connections never wait on this task chain.
  private func updateTrust(_ transform: @escaping @MainActor (NotebookDeviceTrustState) throws -> NotebookDeviceTrustState) async throws {
    let previous = trustWrite?.task, epoch = lifetime, id = UUID()
    let task = Task { @MainActor [self] in
      if let previous { _ = await previous.result }
      guard historyControl == nil else { throw NotebookTransportError.historyReadinessPending }
      guard isStarted, lifetime == epoch else { throw CancellationError() }
      let updated = try transform(trust)
      if updated != trust { try await trustStore.save(updated, for: identity) }
      guard historyControl == nil else { throw NotebookTransportError.historyReadinessPending }
      guard isStarted, lifetime == epoch else { throw CancellationError() }
      trust = updated
    }
    trustWrite = (id, task)
    defer { if trustWrite?.id == id { trustWrite = nil } }
    try await task.value
  }

  func stop() {
    lifetime = UUID(); startup?.task.cancel(); startup = nil
    isStarted = false; retryTask?.cancel(); retryTask = nil
    discoveryStop?.cancel(); discoveryStop = nil; networkChange?.cancel(); networkChange = nil
    pathMonitor?.cancel(); pathMonitor = nil
    for task in relayTasks.values { task.cancel() }; relayTasks.removeAll()
    for uplink in uplinks.values { uplink.stop() }; uplinks.removeAll(); sessionRoutes.removeAll(); sessionEpochs.removeAll()
    listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
    endpointByPeer.removeAll(); suspendedPeers.removeAll()
    for session in Array(sessions.values) { session.stop() }
    sessions.removeAll(); currentGeneration.removeAll()
    historyControl = nil
  }

  /// Stop admission before awaiting every owned storage callback. An accepted
  /// delivery or Keychain write keeps its original FIFO result during teardown.
  func stopAndDrain() async -> Bool {
    let pending = trustWrite?.task, starting = startup?.task
    let callbacks = [discoveryStop, networkChange, retryTask].compactMap { $0 } + Array(relayTasks.values)
      + (historyControl?.callbacks ?? [])
    let connections = Array(sessions.values) + (historyControl?.retiring ?? [])
      + (historyControl.map { [$0.connection] } ?? [])
    stop()
    for session in connections { await session.stopAndJoin() }
    for task in callbacks { await task.value }
    var drained = true
    for task in [starting, pending].compactMap({ $0 }) {
      if case .failure(let error) = await task.result, !(error is CancellationError) {
        report(error); drained = false
      }
    }
    return drained
  }

  /// The account service is the only enrollment authority. Persist first, then
  /// expose the devices and open discovery; a stopped owner cannot revive it.
  func applyAccountTrust(account: String, devices: [NotebookTrustedDevice]) async throws {
    try await startIfNeeded(account: account)
    let previous = trusted
    try await updateTrust { state in
      guard state.account == nil || state.account == account else { throw NotebookTransportError.identityMismatch }
      var state = state
      state.account = account
      for device in devices {
        if let index = state.records.firstIndex(where: { $0.identity.deviceID == device.identity.deviceID }) {
          if state.records[index].credentialID != device.credentialID || state.records[index].secret != device.secret {
            state.relays?.removeValue(forKey: device.identity.deviceID)
            state.relayClients?.removeValue(forKey: device.identity.deviceID)
          }
          state.records[index] = device
        } else { state.records.append(device) }
      }
      try state.validate(for: self.identity)
      return state
    }
    // A newly admitted activation may replace its account-owned credential.
    guard historyControl == nil else { throw NotebookTransportError.historyReadinessPending }
    // Finish old sessions before admitting the replacement; repeated directory
    // notifications with identical keys do not churn the Bonjour listener.
    if previous != trusted {
      for device in previous where !trusted.contains(device) {
        for session in Array(sessions.values) where session.expectedPeerID == device.identity.deviceID
          || session.peerIdentity?.deviceID == device.identity.deviceID { session.stop() }
      }
      if role == .macListener { refreshListener() } else { refreshDiscovery() }
      connectDiscoveredPeers()
    }
    onStateChange?(.waiting)
  }

  func setDeviceAllowed(_ id: UUID, allowed: Bool) async throws {
    guard historyControl == nil else { throw NotebookTransportError.historyReadinessPending }
    // Settings cannot restart a transport suspended by an account change.
    // Only successful account admission may resume a stopped owner.
    guard isStarted else { throw NotebookTransportError.disconnected }
    guard !retiredPeers.contains(id) else { throw NotebookTransportError.identityMismatch }
    if !allowed {
      suspendedPeers.insert(id)
      onDeviceRevoked?(id)
      relayTasks[id]?.cancel(); relayTasks.removeValue(forKey: id)
      uplinks[id]?.stop(); uplinks.removeValue(forKey: id)
      for session in Array(sessions.values) where session.expectedPeerID == id || session.peerIdentity?.deviceID == id { session.stop() }
    }
    try await updateTrust { state in
      var state = state
      if allowed { state.blocked.remove(id) } else { state.blocked.insert(id) }
      return state
    }
    if !allowed, role == .macListener, let route = trust.relays?[id] {
      _ = try? await NotebookRelayHTTP.request(route, role: "host", action: "revoke", as: NotebookRelayHTTP.Enrollment.self)
      try await updateTrust { state in var state = state; state.relays?.removeValue(forKey: id); state.relayClients?.removeValue(forKey: id); return state }
    }
    suspendedPeers.remove(id)
    onStateChange?(.waiting)
    if role == .macListener { refreshListener() } else { refreshDiscovery() }
  }

  func notifyDurableChanges() {
    guard historyControl == nil else { return }
    for session in sessions.values where session.isReady { session.notifyDurableChanges() }
  }
  func receivedCheckpoint(from peer: UUID) {
    guard historyControl == nil, isStarted, suspendedPeers.remove(peer) != nil else { return }
    connectDiscoveredPeers()
  }
  func sendTransient(_ value: NotebookTransportTransient, to peerID: UUID? = nil) {
    guard historyControl == nil, value.isValid(from: identity) else { return }
    for session in sessions.values where session.isReady && session.peerIdentity.map({ currentGeneration[$0.deviceID] == session.generation }) == true && (peerID == nil || session.peerIdentity?.deviceID == peerID) { session.sendTransient(value) }
  }

  /// Foreground after sleep may not change the default IP path. Permit one
  /// bounded discovery window without churning a healthy authenticated channel.
  func resumeDiscovery() {
    guard historyControl == nil else { return }
    guard currentGeneration.isEmpty else { return }
    networkPathChanged()
  }

  /// A debounced system path event opens a new candidate epoch without retiring
  /// the selected authenticated channel. The connector commits handover on ready.
  func networkPathChanged() {
    guard historyControl == nil, isStarted else { return }
    reconnectFailures = 0; pathEpoch &+= 1; nearbySearchAllowed = true
    if role == .iPadConnector { browser?.cancel(); browser = nil; discoveryStop?.cancel() }
    refreshDiscovery(); connectDiscoveredPeers(); connectRelayPeers()
  }

  private func refreshDiscovery(peerToPeer: Bool = false) {
    guard historyControl == nil, isStarted else { return }
    switch role {
    case .macListener: if listener == nil { refreshListener() } else { refreshUplinks() }
    case .iPadConnector:
      if trusted.isEmpty {
        browser?.cancel(); browser = nil; endpointByPeer.removeAll(); return
      }
      guard browser == nil, !trusted.isEmpty else { return }
      let parameters = NWParameters.tcp
      parameters.includePeerToPeer = peerToPeer
      let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_notebook._tcp", domain: nil), using: parameters)
      self.browser = browser
      browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
        Task { @MainActor in
          guard let self, let browser, self.browser === browser, self.isStarted else { return }
          let allowed = Set(self.trusted.map { $0.identity.deviceID })
          var endpoints: [UUID: NWEndpoint] = [:]
          var incompatiblePeers: Set<UUID> = []
          for result in results.sorted(by: { String(describing: $0.endpoint) < String(describing: $1.endpoint) }) {
            guard case .service(let name, _, _, _) = result.endpoint,
              let peer = NotebookPeerDiscovery(serviceName: name), allowed.contains(peer.deviceID) else { continue }
            guard peer.isCompatible else { incompatiblePeers.insert(peer.deviceID); continue }
            // Retained workspaces share this Mac's device identity. Select the
            // workspace before TLS, rather than whichever listener sorts first.
            guard NotebookPeerDiscovery.matches(result.metadata, workspaceID: self.identity.workspaceID) else { continue }
            if endpoints[peer.deviceID] == nil { endpoints[peer.deviceID] = result.endpoint }
          }
          // A changed advertisement is evidence of external progress. Repeated
          // callbacks for the same incompatible writer do not replay its data.
          self.suspendedPeers = self.suspendedPeers.filter { self.endpointByPeer[$0] == endpoints[$0] && endpoints[$0] != nil }
          self.endpointByPeer = endpoints; self.connectDiscoveredPeers()
          self.logger.info("Nearby discovery: \(endpoints.count) compatible trusted peers, \(incompatiblePeers.count) incompatible peers")
          if !incompatiblePeers.subtracting(endpoints.keys).isEmpty { self.report(NotebookTransportError.unsupportedVersion) }
        }
      }
      browser.stateUpdateHandler = { [weak self, weak browser] state in
        Task { @MainActor in
          guard let self, let browser, self.browser === browser, self.isStarted else { return }
          switch state {
          case .waiting(let error), .failed(let error): self.report(error)
          case .ready: self.logger.info("Trusted device discovery ready")
          default: break
          }
        }
      }
      browser.start(queue: queue)
      discoveryStop?.cancel()
      guard peerToPeer || nearbySearchAllowed else { connectRelayPeers(); return }
      discoveryStop = Task { [weak self, weak browser] in
        do { try await Task.sleep(for: .seconds(peerToPeer ? 12 : 4)) } catch { return }
        guard let self, let browser, self.browser === browser else { return }
        browser.cancel(); self.browser = nil
        let hasCurrentDirectPath = self.currentGeneration.values.contains {
          self.sessionEpochs[$0] == self.pathEpoch && self.sessionRoutes[$0] != .relay
        }
        if !peerToPeer, !hasCurrentDirectPath, self.nearbySearchAllowed { self.nearbySearchAllowed = false; self.refreshDiscovery(peerToPeer: true) }
        else if peerToPeer { self.refreshDiscovery() }
        self.connectRelayPeers()
      }
    }
  }

  private func refreshListener() {
    guard historyControl == nil else { return }
    for uplink in uplinks.values { uplink.stop() }; uplinks.removeAll()
    listener?.cancel(); listener = nil
    guard isStarted, role == .macListener else { return }
    let keys = trusted.map(\.tlsKey)
    guard !keys.isEmpty else { return }
    do {
      let listener = try NWListener(using: NotebookTransportTLS.parameters(keys: keys))
      self.listener = listener
      listener.service = .init(name: NotebookPeerDiscovery.serviceName(deviceID: identity.deviceID, generation: discoveryGeneration),
        type: "_notebook._tcp", txtRecord: NotebookPeerDiscovery.metadata(workspaceID: identity.workspaceID))
      listener.newConnectionHandler = { [weak self, weak listener] connection in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener, self.isStarted, self.sessions.count < 8 else { connection.cancel(); return }
          let isLoopback: Bool
          if case .hostPort(let host, _) = connection.endpoint { isLoopback = String(describing: host) == "127.0.0.1" || String(describing: host) == "::1" }
          else { isLoopback = false }
          self.addSession(connection: connection, credential: nil, route: isLoopback ? .relay : .direct)
        }
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, let listener, self.isStarted, self.listener === listener else { return }
          switch state {
          case .ready:
            self.retryTask?.cancel(); self.retryTask = nil; self.reconnectFailures = 0
            self.refreshUplinks()
          case .failed(let error):
            // A failed NWListener is terminal. Keeping it in this slot makes
            // every later discovery refresh mistake it for a listening owner.
            // Existing authenticated sessions survive advertisement recovery.
            self.listener = nil; listener.cancel()
            self.report(error); self.scheduleReconnect()
          default: break
          }
        }
      }
      listener.start(queue: queue)
    } catch { report(error); scheduleReconnect() }
  }

  private func connectDiscoveredPeers() {
    guard historyControl == nil, isStarted, role == .iPadConnector else { return }
    for (deviceID, endpoint) in endpointByPeer where sessions.count < 8 {
      guard !suspendedPeers.contains(deviceID) else { continue }
      guard !sessions.values.contains(where: { ($0.expectedPeerID == deviceID || $0.peerIdentity?.deviceID == deviceID) && sessionRoutes[$0.generation] != .relay && sessionEpochs[$0.generation] == pathEpoch }) else { continue }
      guard let peer = trusted.first(where: { $0.identity.deviceID == deviceID }) else { continue }
      let credential = NotebookPeerCredential(credentialID: peer.credentialID, secret: peer.secret, expectedPeer: peer.identity)
      do { addSession(connection: NWConnection(to: endpoint, using: try NotebookTransportTLS.parameters(keys: [credential.tlsKey])), credential: credential) }
      catch { report(error) }
    }
  }

  func configureRelay(for peerID: UUID, route: NotebookRelayRoute?) async throws {
    guard historyControl == nil else { throw NotebookTransportError.historyReadinessPending }
    guard isStarted, role == .macListener, let peer = trusted.first(where: { $0.identity.deviceID == peerID }) else {
      throw NotebookTransportError.authenticationRequired
    }
    let previousRoute = trust.relays?[peerID]
    let client: NotebookRelayRoute?
    if let route {
      guard route.isValid, !(trust.relays ?? [:]).contains(where: { $0.key != peerID && $0.value.route == route.route && $0.value.endpoint == route.endpoint }) else { throw NotebookTransportError.authenticationRequired }
      let value = try await NotebookRelayHTTP.request(route, role: "host", action: "enable", as: NotebookRelayHTTP.Enrollment.self)
      guard let token = value.clientCapability else { throw NotebookTransportError.authenticationRequired }
      client = .init(endpoint: route.endpoint, route: route.route, capability: token)
      guard client?.isValid == true else { throw NotebookTransportError.authenticationRequired }
    } else { client = nil }
    try await updateTrust { state in
      guard state.records.contains(peer), !state.blocked.contains(peerID) else { throw NotebookTransportError.authenticationRequired }
      var state = state
      if state.relays == nil { state.relays = [:] }; if state.relayClients == nil { state.relayClients = [:] }
      state.relays?[peerID] = route; state.relayClients?[peerID] = client
      return state
    }
    uplinks[peerID]?.stop(); uplinks.removeValue(forKey: peerID); refreshUplinks()
    sendTransient(.relay(.init(credentialID: peer.credentialID, route: client)), to: peerID)
    // Local shutdown/Keychain removal does not depend on internet reachability.
    // A replaced route loses server-side access too; never revoke the newly enabled route.
    if let old = previousRoute, route?.route != old.route || route?.endpoint != old.endpoint {
      _ = try? await NotebookRelayHTTP.request(old, role: "host", action: "revoke", as: NotebookRelayHTTP.Enrollment.self)
    }
  }

  private func receiveRelay(_ value: NotebookRelayAdvertisement, from peerID: UUID, generation: UUID) {
    guard historyControl == nil, role == .iPadConnector, let peer = trusted.first(where: { $0.identity.deviceID == peerID }),
      peer.credentialID == value.credentialID, value.route?.isValid != false else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        try await updateTrust { state in
          guard self.currentGeneration[peerID] == generation, state.records.contains(peer), !state.blocked.contains(peerID) else { throw NotebookTransportError.authenticationRequired }
          var state = state; if state.relays == nil { state.relays = [:] }; state.relays?[peerID] = value.route; return state
        }
        if value.route == nil {
          relayTasks[peerID]?.cancel(); relayTasks.removeValue(forKey: peerID)
          for session in Array(sessions.values) where session.peerIdentity?.deviceID == peerID && sessionRoutes[session.generation] == .relay { session.stop() }
        }
      } catch { report(error) }
    }
  }

  private func refreshUplinks() {
    guard historyControl == nil, isStarted, role == .macListener, let port = listener?.port, port != .any else { return }
    for peer in trusted where !suspendedPeers.contains(peer.identity.deviceID) {
      let id = peer.identity.deviceID
      guard uplinks[id] == nil, let route = trust.relays?[id] else { continue }
      let uplink = NotebookRelayUplink(route: route, port: port); uplinks[id] = uplink; uplink.start()
    }
  }

  private func connectRelayPeers() {
    guard historyControl == nil, isStarted, role == .iPadConnector else { return }
    for peer in trusted where sessions.count < 8 {
      let id = peer.identity.deviceID
      guard (currentGeneration[id].flatMap { sessionEpochs[$0] } ?? UInt64.max) != pathEpoch, !suspendedPeers.contains(id), relayTasks[id] == nil,
        !sessions.values.contains(where: { $0.expectedPeerID == id && sessionRoutes[$0.generation] == .relay && sessionEpochs[$0.generation] == pathEpoch }),
        let route = trust.relays?[id] else { continue }
      let epoch = lifetime
      relayTasks[id] = Task { [weak self] in
        guard let self else { return }
        defer { if self.lifetime == epoch { self.relayTasks.removeValue(forKey: id) } }
        do {
          let ticket = try await NotebookRelayHTTP.ticket(route, role: "client")
          guard self.historyControl == nil, !Task.isCancelled, self.lifetime == epoch, (self.currentGeneration[id].flatMap { self.sessionEpochs[$0] } ?? UInt64.max) != self.pathEpoch,
            self.trusted.contains(peer), !self.suspendedPeers.contains(id) else { return }
          let credential = NotebookPeerCredential(credentialID: peer.credentialID, secret: peer.secret, expectedPeer: peer.identity)
          let parameters = try NotebookRelayHTTP.parameters(keys: [credential.tlsKey], route: route, ticket: ticket)
          self.addSession(connection: NWConnection(host: .init(route.tunnelHost), port: 443, using: parameters), credential: credential, route: .relay)
        } catch { if !Task.isCancelled, self.lifetime == epoch { self.scheduleReconnect() } }
      }
    }
  }

  private func resolve(_ hello: NotebookTransportHello) throws -> NotebookPeerCredential {
    guard !suspendedPeers.contains(hello.identity.deviceID) else { throw NotebookTransportError.authenticationRequired }
    guard hello.identity.isValid, hello.identity.workspaceID == identity.workspaceID, hello.identity.deviceID != identity.deviceID else {
      throw NotebookTransportError.identityMismatch
    }
    if let peer = trusted.first(where: { $0.credentialID == hello.credentialID && $0.identity.deviceID == hello.identity.deviceID }) {
      return .init(credentialID: peer.credentialID, secret: peer.secret, expectedPeer: peer.identity)
    }
    throw NotebookTransportError.authenticationRequired
  }

  private func authenticate(_ peer: NotebookTransportIdentity, credential: NotebookPeerCredential, generation: UUID) throws -> Bool {
    guard sessions[generation] != nil, !suspendedPeers.contains(peer.deviceID),
      trusted.contains(where: { $0.identity.deviceID == peer.deviceID && $0.identity.workspaceID == peer.workspaceID
        && $0.credentialID == credential.credentialID && $0.secret == credential.secret }) else {
      throw NotebookTransportError.authenticationRequired
    }
    return true
  }

  func addSession(connection: NWConnection, credential: NotebookPeerCredential?, route: Route = .direct) {
    guard historyControl == nil else { connection.cancel(); return }
    do {
      let session = try NotebookTransportSession(connection: connection, identity: identity, credential: credential,
        storage: storage, stagingRoot: stagingRoot, queue: queue)
      let generation = session.generation
      let pathReport = connection.startDataTransferReport(), logger = self.logger
      sessions[generation] = session; sessionRoutes[generation] = route; sessionEpochs[generation] = pathEpoch
      session.resolveCredential = { [weak self] hello in guard let self else { throw NotebookTransportError.disconnected }; return try self.resolve(hello) }
      session.onAuthenticated = { [weak self] peer, credential in
        guard let self, self.sessions[generation] != nil else { throw NotebookTransportError.disconnected }
        return try self.authenticate(peer, credential: credential, generation: generation)
      }
      let select: (NotebookTransportIdentity) -> Void = { [weak self] peer in
        guard let self, self.historyControl == nil, self.sessions[generation]?.isReady == true else { return }
        let old = self.currentGeneration.updateValue(generation, forKey: peer.deviceID)
        self.reconnectFailures = 0
        if self.sessionRoutes[generation] != .relay { self.browser?.cancel(); self.browser = nil; self.discoveryStop?.cancel() }
        // Mac retires the old socket only after the connector's first selected
        // transient arrived here. Closing it on iPad first races EOF against
        // that message on another socket and falsely disconnects the Mac UI.
        if self.role == .macListener, let old, old != generation { self.sessions[old]?.stop() }
        self.onStateChange?(.connected(peer)); self.onConnect?(peer, generation)
        if self.role == .macListener, let credential = self.trusted.first(where: { $0.identity.deviceID == peer.deviceID }) {
          self.sendTransient(.relay(.init(credentialID: credential.credentialID, route: self.trust.relayClients?[peer.deviceID])), to: peer.deviceID)
        }
      }
      session.onReady = { [weak self] peer in
        guard let self, self.historyControl == nil, self.sessions[generation] != nil else { return }
        // Bonjour may omit an interface and an accepted Mac socket has no
        // discovery hint. Classify the resolved, established path on both ends,
        // never all available interfaces or includePeerToPeer.
        let selectedRoute: Route = route == .relay ? .relay
          : [connection.currentPath?.localEndpoint, connection.currentPath?.remoteEndpoint]
              .contains(where: { $0?.interface?.name == "awdl0" }) ? .nearby : .direct
        self.sessionRoutes[generation] = selectedRoute
        pathReport.collect(queue: self.queue) { report in
          for path in report.pathReports {
            logger.info("Authenticated transport generation=\(generation.uuidString, privacy: .public) interface=\(path.interface.name, privacy: .public) sentPackets=\(path.sentIPPacketCount) receivedPackets=\(path.receivedIPPacketCount)")
          }
        }
        if let previous = self.currentGeneration[peer.deviceID], previous != generation {
          // The connector alone chooses the route. Mac parks an authenticated
          // candidate until its first selected transient: an idle old TCP socket
          // must not veto a connector that has already left that network.
          if self.role == .macListener { return }
          if let selected = self.sessionRoutes[previous], self.sessionEpochs[previous] == self.sessionEpochs[generation], selected.rawValue <= selectedRoute.rawValue {
            self.sessions[generation]?.stop(); return
          }
        }
        select(peer)
      }
      session.onTransient = { [weak self] value, peer in
        guard let self, self.historyControl == nil, self.sessions[generation]?.isReady == true else { return }
        if self.role == .macListener, self.currentGeneration[peer.deviceID] != generation { select(peer) }
        guard self.currentGeneration[peer.deviceID] == generation else { return }
        if case .relay(let advertisement) = value {
          self.receiveRelay(advertisement, from: peer.deviceID, generation: generation)
        } else { self.onTransient?(value, peer.deviceID, generation) }
      }
      session.onDurableChange = { [weak self] change, peer in
        guard let self, self.historyControl == nil, self.currentGeneration[peer.deviceID] == generation else { return }
        self.onDurableChange?(change, peer.deviceID, generation); self.notifyDurableChanges()
      }
      session.onHistoryControl = { [weak self] control, peer in
        guard let self, self.currentGeneration[peer.deviceID] == generation else { return }
        if let current = self.historyControl {
          guard current.scope.requestID == control.requestID, current.connectionID == generation else { return }
        }
        self.onHistoryControl?(control, peer.deviceID, generation)
      }
      session.onHistoryProgress = { [weak self, weak session] observation in
        guard let self, let peer = session?.peerIdentity, self.currentGeneration[peer.deviceID] == generation else { return }
        self.onHistoryProgress?(observation, peer.deviceID, generation)
      }
      session.onStop = { [weak self] peer, error in
        guard let self else { return }
        let peerID = peer?.deviceID ?? credential?.expectedPeer.deviceID
        let selected = peerID.flatMap { self.currentGeneration[$0] }
        let hasReplacement = selected != nil && selected != generation
        self.sessions.removeValue(forKey: generation); self.sessionRoutes.removeValue(forKey: generation); self.sessionEpochs.removeValue(forKey: generation)
        if let peer, self.currentGeneration[peer.deviceID] == generation {
          self.currentGeneration.removeValue(forKey: peer.deviceID)
          if self.historyControl == nil { self.onDisconnect?(peer.deviceID, generation) }
        }
        if self.historyControl != nil { return }
        if let error, !hasReplacement { self.report(error) }
        if let error, !hasReplacement, NotebookPeerDiscovery.upgradeMessage(for: error) != nil,
          let deviceID = peer?.deviceID ?? credential?.expectedPeer.deviceID {
          self.suspendedPeers.insert(deviceID)
        }
        if error == nil, self.currentGeneration.isEmpty { self.onStateChange?(.waiting) }
        // A retired socket's goodbye is expected. It cannot publish failure,
        // suspend the new owner or restart discovery under a healthy channel.
        if !hasReplacement { self.scheduleReconnect() }
      }
      session.start()
    } catch { connection.cancel(); report(error) }
  }

  private func scheduleReconnect() {
    // Only a failed listener needs a Mac retry. A healthy listener accepts a
    // reconnect itself; it must not poll or be replaced when a peer goes away.
    guard historyControl == nil, isStarted, role == .iPadConnector || listener == nil, retryTask == nil else { return }
    retryTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(Double(1 << min(5, self?.reconnectFailures ?? 1)))) } catch { return }
      guard let self else { return }; self.retryTask = nil
      self.reconnectFailures += 1
      self.refreshDiscovery(); self.connectDiscoveredPeers(); self.connectRelayPeers()
    }
  }
  private func report(_ error: Error) {
    guard historyControl == nil else { return }
    // Credentials and notebook content never enter logs.
    logger.error("Trusted nearby connection failed: \(String(describing: error), privacy: .public)")
    if error as? NotebookTransportError == .storageUnavailable {
      onStateChange?(.failed("Не удалось открыть защищённое хранилище устройств. Подключение повторится автоматически."))
      return
    }
    if case .dns(let code) = error as? NWError, code == Int32(kDNSServiceErr_PolicyDenied) {
      onStateChange?(.failed("Разрешите Notebook доступ «Локальная сеть» в настройках устройства. Сохранённое подключение не изменено."))
      return
    }
    onStateChange?(.failed(NotebookPeerDiscovery.upgradeMessage(for: error)
      ?? "Устройство сейчас недоступно. Подключение восстановится автоматически."))
  }
}

/// One TLS connection generation owns framing, credits, handshake, staging and
/// commit callbacks. SQL calls use the injected storage executor; camera/contact
/// receipt does not wait for a blob write or a SQL transaction to finish.
@MainActor
final class NotebookTransportSession {
  let generation = UUID()
  var resolveCredential: ((NotebookTransportHello) throws -> NotebookPeerCredential)?
  var onAuthenticated: ((NotebookTransportIdentity, NotebookPeerCredential) async throws -> Bool)?
  var onReady: ((NotebookTransportIdentity) -> Void)?
  var onTransient: ((NotebookTransportTransient, NotebookTransportIdentity) -> Void)?
  var onDurableChange: ((NotebookDurableChange, NotebookTransportIdentity) -> Void)?
  var onHistoryControl: ((NotebookHistoryControl, NotebookTransportIdentity) -> Void)?
  var onHistoryProgress: ((NotebookHistoryTransportObservation) -> Void)?
  var onStop: ((NotebookTransportIdentity?, Error?) -> Void)?
  private(set) var peerIdentity: NotebookTransportIdentity?
  private(set) var isReady = false
  var credentialID: UUID? { credential?.credentialID }
  var expectedPeerID: UUID? { credential?.expectedPeer.deviceID }

  private let connection: NWConnection
  private let identity: NotebookTransportIdentity
  private let storage: NotebookTransportStorage
  private let assembly: NotebookTransportBlobAssembly
  private let queue: DispatchQueue
  private var credential: NotebookPeerCredential?
  private var localHello: NotebookTransportHello?
  private var remoteHello: NotebookTransportHello?
  private var transcript: Data?
  private var authenticated = false
  private var sentReady = false
  private var remoteCursor: UInt64?
  private var isStopped = false
  private var isTLSReady = false
  private var isSending = false
  private var outgoing = NotebookTransportOutgoing()
  private var incoming = NotebookTransportReceiveWindow()
  private var receiveTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var readyTask: Task<Void, Never>?
  private var offerTask: Task<Void, Never>?
  private var incomingTask: Task<Void, Never>?
  private var servingBlobTask: Task<Void, Never>?
  private var acknowledgingTask: Task<Void, Never>?
  private var stopping: Task<Void, Never>?
  private var shouldReadJournal = false
  private var offeredCursor: UInt64 = 0
  private var offeredChanges: [NotebookDurableChange] = []
  private var incomingChanges: [NotebookDurableChange] = []
  private var lastIncomingOffer: UInt64 = 0
  private var requestedBlobs: [NotebookTransportBlobRequest] = []
  private var completedBlobs: [NotebookTransportCompletedBlob] = []
  private var commitAcknowledgements: [(UUID, UInt64)] = []
  private let historyApplicationBuild: String?
  private enum HistoryPhase: Equatable {
    case open, preparing(NotebookHistoryControlPreparation)
    case quiescing(NotebookHistoryControlScope), quiescent(NotebookHistoryControlScope)
    case resuming(NotebookHistoryControlScope), stale(NotebookHistoryControlScope)
    var scope: NotebookHistoryControlScope? {
      switch self { case .open, .preparing: nil; case .quiescing(let s), .quiescent(let s), .resuming(let s), .stale(let s): s }
    }
    var preparation: NotebookHistoryControlPreparation? {
      if case .preparing(let p) = self { return p }
      return scope?.preparation
    }
    var permitsStorage: Bool {
      switch self { case .open, .preparing: true; default: false }
    }
  }
  private var historyPhase = HistoryPhase.open
  private var historyOperation: UUID?
  private var historyWaiter: CheckedContinuation<Void, Error>?
  private var historyDeadline: Task<Void, Never>?
  private var historySendProgress: UInt64 = 0
  private var peerProposedHistoryScope: NotebookHistoryControlScope?
  private var peerQuiescedScope: NotebookHistoryControlScope?
  private var peerQuiesced: Bool { historyPhase.scope.map { peerQuiescedScope == $0 } == true }
  private var peerResumeRequested = false
  private var peerResumed = false
  private var localResumed = false
  private var completedHistoryResume: NotebookHistoryControlScope?
  private var completedHistoryPreparation: NotebookHistoryControlPreparation?
  private var peerAcceptedThrough: UInt64 = 0
  private var incomingAcceptedThrough: UInt64 = 0
  private var localPrepared: NotebookHistoryControl.Prepared?
  private var peerPrepared: NotebookHistoryControl.Prepared?
  var historyControlScope: NotebookHistoryControlScope? { historyPhase.scope }
  var historyControlPreparation: NotebookHistoryControlPreparation? { historyPhase.preparation }
  var isHistoryQuiescent: Bool { !isStopped && isReady && historyPhase.scope.map { historyPhase == .quiescent($0) } == true && peerQuiesced }

  var historyBoundaryObservation: NotebookHistoryTransportObservation {
    .init(connectionID: generation,
      localSource: storage.journalGeneration.map { .init(deviceID: identity.deviceID, generation: $0) },
      remoteSource: remoteHello.map { .init(deviceID: $0.identity.deviceID, generation: $0.journalGeneration) },
      localOfferedThrough: offeredCursor, peerAcceptedThrough: peerAcceptedThrough,
      remoteOfferedThrough: lastIncomingOffer, incomingAcceptedThrough: incomingAcceptedThrough,
      pendingDurableWork: offeredChanges.count + incomingChanges.count + commitAcknowledgements.count
        + requestedBlobs.count + completedBlobs.count,
      hasStorageCallback: readyTask != nil || offerTask != nil || incomingTask != nil
        || servingBlobTask != nil || acknowledgingTask != nil,
      pendingFrames: outgoing.pendingCount, unacknowledgedFrames: outgoing.window.unacknowledged.count,
      isSending: isSending, scope: historyPhase.scope, isQuiescent: isHistoryQuiescent,
      preparation: historyPhase.preparation, localPrepared: localPrepared, peerPrepared: peerPrepared)
  }

  func historyObservation(selected: Bool) -> NotebookHistoryConnectionObservation {
    .init(connectionID: generation, peer: peerIdentity, credentialID: credentialID,
      selected: selected, ready: isReady, localJournalGeneration: storage.journalGeneration,
      remoteJournalGeneration: remoteHello?.journalGeneration, offeredThrough: offeredCursor,
      lastIncomingOffer: lastIncomingOffer, initialPeerAcceptedThrough: remoteCursor,
      pendingOffers: offeredChanges.count, pendingIncoming: incomingChanges.count,
      pendingAcknowledgements: commitAcknowledgements.count, pendingBlobRequests: requestedBlobs.count,
      hasStorageCallback: readyTask != nil || offerTask != nil || incomingTask != nil
        || servingBlobTask != nil || acknowledgingTask != nil)
  }

  init(connection: NWConnection, identity: NotebookTransportIdentity, credential: NotebookPeerCredential?,
    storage: NotebookTransportStorage, stagingRoot: URL, queue: DispatchQueue,
    historyApplicationBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) throws {
    self.connection = connection; self.identity = identity; self.credential = credential
    self.storage = storage; self.queue = queue
    self.historyApplicationBuild = historyApplicationBuild
    assembly = try NotebookTransportBlobAssembly(stagingRoot: stagingRoot, generation: generation)
    if let credential {
      localHello = .init(identity: identity, credentialID: credential.credentialID,
        nonce: try NotebookTransportTLS.randomBytes(count: 32), journalGeneration: storage.journalGeneration)
    }
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.isStopped else { return }
        switch state {
        case .ready:
          guard !self.isTLSReady else { return }
          guard NotebookTransportTLS.accepts(self.connection) else { self.stop(NotebookTransportError.authenticationRequired); return }
          self.isTLSReady = true
          if let hello = self.localHello { self.enqueue(.hello(hello)) }
          self.receiveTask = Task { [weak self] in await self?.readFrames() }
        case .failed(let error): self.stop(error)
        case .cancelled: self.stop()
        default: break
        }
      }
    }
    setTimeout(seconds: 30)
    connection.start(queue: queue)
  }

  func stop(_ error: Error? = nil, notifyingPeer: Bool = true) {
    guard !isStopped else { return }
    let requirement = notifyingPeer && isReady ? error.flatMap(NotebookTransportContentRequirement.init(error:)) : nil
    isStopped = true; isReady = false
    if let scope = historyPhase.scope, historyPhase != .stale(scope) {
      historyPhase = .stale(scope)
      if let peerIdentity { onHistoryControl?(.stale(requestID: scope.requestID, reason: .connectionChanged), peerIdentity) }
    } else if case .preparing(let preparation) = historyPhase, let peerIdentity {
      onHistoryControl?(.stale(requestID: preparation.requestID, reason: .connectionChanged), peerIdentity)
    }
    historyDeadline?.cancel(); historyDeadline = nil
    peerProposedHistoryScope = nil; peerQuiescedScope = nil
    signalHistory(throwing: error ?? NotebookTransportError.disconnected)
    let callbacks = [receiveTask, timeoutTask, readyTask, offerTask, incomingTask,
      servingBlobTask, acknowledgingTask].compactMap { $0 }
    receiveTask?.cancel(); timeoutTask?.cancel(); readyTask?.cancel(); offerTask?.cancel()
    incomingTask?.cancel(); servingBlobTask?.cancel(); acknowledgingTask?.cancel()
    receiveTask = nil; timeoutTask = nil; readyTask = nil; offerTask = nil
    incomingTask = nil; servingBlobTask = nil; acknowledgingTask = nil
    outgoing = NotebookTransportOutgoing(); incomingChanges.removeAll(); offeredChanges.removeAll(); commitAcknowledgements.removeAll()
    requestedBlobs.removeAll(); completedBlobs.removeAll()
    connection.stateUpdateHandler = nil
    if let requirement,
      let frame = try? NotebookTransportFraming.encode(.init(sequence: 0, message: .contentUnavailable(requirement))) {
      // Release session ownership now, but deliver one bounded authenticated
      // refusal before closing. Both ends then stop retrying an unchanged cut.
      let connection = connection
      let deadline = Task { try? await Task.sleep(for: .seconds(2)); connection.cancel() }
      connection.send(content: frame, completion: .contentProcessed { _ in deadline.cancel(); connection.cancel() })
    } else { connection.cancel() }
    let assembly = assembly
    stopping = Task {
      for task in callbacks { await task.value }
      await assembly.cancel()
    }
    onStop?(peerIdentity, error)
    resolveCredential = nil; onAuthenticated = nil; onReady = nil; onTransient = nil; onDurableChange = nil
    onHistoryControl = nil; onHistoryProgress = nil; onStop = nil
  }

  func stopAndJoin() async {
    stop(notifyingPeer: false)
    await stopping?.value
  }

  func proposeHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    try validateHistoryPreparation(preparation)
    guard historyPhase == .open || historyPhase == .preparing(preparation) else {
      throw NotebookTransportError.historyReadinessPending
    }
    guard completedHistoryResume?.requestID != preparation.requestID,
      completedHistoryPreparation?.requestID != preparation.requestID else { throw NotebookTransportError.historyCutStale }
    try outgoing.enqueue(.historyReadiness(.prepare(preparation))); pump()
  }

  func admitHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    try validateHistoryPreparation(preparation)
    if historyPhase == .preparing(preparation) { return }
    guard historyPhase == .open else { throw NotebookTransportError.historyReadinessPending }
    guard completedHistoryResume?.requestID != preparation.requestID,
      completedHistoryPreparation?.requestID != preparation.requestID else { throw NotebookTransportError.historyCutStale }
    historyPhase = .preparing(preparation); localPrepared = nil; peerPrepared = nil
    peerProposedHistoryScope = nil; peerQuiescedScope = nil
  }

  func sendHistoryPrepared(_ prepared: NotebookHistoryControl.Prepared) throws {
    guard case .preparing(let preparation) = historyPhase else { throw NotebookTransportError.historyReadinessPending }
    try validateHistoryPrepared(prepared, preparation: preparation, sender: identity.deviceID, previous: localPrepared)
    try outgoing.enqueue(.historyReadiness(.prepared(prepared))); localPrepared = prepared; pump()
    onHistoryProgress?(historyBoundaryObservation)
  }

  /// This is the native owner's explicit cancellation before a final scope.
  /// The peer receives a proposal and independently releases its own phase.
  func resumeHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    try validateHistoryPreparation(preparation)
    guard historyPhase == .preparing(preparation) else { throw NotebookTransportError.historyCutStale }
    try outgoing.enqueue(.historyReadiness(.stale(requestID: preparation.requestID, reason: .cancelled))); pump()
    completedHistoryPreparation = preparation; historyPhase = .open
    localPrepared = nil; peerPrepared = nil
    peerProposedHistoryScope = nil; peerQuiescedScope = nil
  }

  func proposeHistoryControl(_ scope: NotebookHistoryControlScope) throws {
    try validateHistoryScope(scope)
    guard historyPhase == .preparing(scope.preparation) else { throw NotebookTransportError.historyReadinessPending }
    guard preparedHeadsMatch(scope), committedPrefixesMatch(scope) else { throw NotebookTransportError.historyNotDrained }
    try outgoing.enqueue(.historyReadiness(.request(scope))); pump()
  }

  /// Admission is synchronous, before waiting on the existing callbacks. A
  /// remote proposal only reaches the native phase owner; it cannot admit itself.
  func admitHistoryControl(_ scope: NotebookHistoryControlScope) throws {
    try validateHistoryScope(scope)
    if historyPhase.scope == scope, historyPhase != .stale(scope) { return }
    guard historyPhase == .preparing(scope.preparation) else { throw NotebookTransportError.historyReadinessPending }
    guard durableWorkIsEmpty, preparedHeadsMatch(scope), committedPrefixesMatch(scope) else {
      throw NotebookTransportError.historyNotDrained
    }
    guard peerQuiescedScope == nil || peerQuiescedScope == scope else { throw NotebookTransportError.historyCutStale }
    historyPhase = .quiescing(scope); shouldReadJournal = false
    peerResumeRequested = false; peerResumed = false; localResumed = false
  }

  func quiesceHistoryControl(_ scope: NotebookHistoryControlScope) async throws {
    try admitHistoryControl(scope)
    if isHistoryQuiescent { return }
    guard historyOperation == nil, historyPhase == .quiescing(scope) else {
      throw NotebookTransportError.historyReadinessPending
    }
    let operation = UUID(); historyOperation = operation
    startHistoryDeadline(scope)
    defer {
      if historyOperation == operation { historyOperation = nil; historyDeadline?.cancel(); historyDeadline = nil }
    }
    do {
      // These are the actual accepted operations, not cancelled proxy waiters.
      for task in [readyTask, offerTask, incomingTask, servingBlobTask, acknowledgingTask].compactMap({ $0 }) {
        await task.value
      }
      try Task.checkCancellation(); try requireHistoryScope(scope)
      guard durableWorkIsEmpty, readyTask == nil, offerTask == nil, incomingTask == nil,
        servingBlobTask == nil, acknowledgingTask == nil,
        preparedHeadsMatch(scope), committedPrefixesMatch(scope) else {
        throw NotebookTransportError.historyNotDrained
      }
      try await waitForHistory(scope) { self.framesAreDrained }
      historyPhase = .quiescent(scope)
      try outgoing.enqueue(.historyReadiness(.quiesced(scope))); pump()
      try await waitForHistory(scope) { self.peerQuiesced && self.framesAreDrained }
    } catch {
      invalidateHistory(error is CancellationError ? .cancelled : .changedPrefix)
      throw error
    }
  }

  /// The native phase owner releases its writer seal before invoking resume.
  /// Both owners explicitly join the same request before durable work restarts.
  func resumeHistoryControl(_ scope: NotebookHistoryControlScope,
    refusal: NotebookHistoryControl.Refusal? = nil) async throws {
    try requireHistoryScope(scope)
    let terminal = NotebookHistoryControl.resume(requestID: scope.requestID, refusal: refusal)
    try validateHistoryPayload(terminal, scope: scope, sender: identity.deviceID)
    guard historyOperation == nil, historyPhase == .quiescent(scope), peerQuiesced else {
      throw NotebookTransportError.historyReadinessPending
    }
    let operation = UUID(); historyOperation = operation
    historyPhase = .resuming(scope); startHistoryDeadline(scope)
    defer {
      if historyOperation == operation { historyOperation = nil; historyDeadline?.cancel(); historyDeadline = nil }
    }
    do {
      try await enqueueHistoryAwaitingCredit(scope) {
        try self.outgoing.enqueue(.historyReadiness(terminal)); self.pump()
      }
      try await waitForHistory(scope) { self.peerResumeRequested }
      try await enqueueHistoryAwaitingCredit(scope) {
        try self.outgoing.enqueue(.historyReadiness(.resumed(requestID: scope.requestID))); self.pump()
      }
      localResumed = true
      finishHistoryResumeIfReady(scope)
      try await waitForHistory(scope) { self.completedHistoryResume == scope }
    } catch {
      invalidateHistory(error is CancellationError ? .cancelled : .connectionChanged)
      throw error
    }
  }

  func sendHistoryControl(_ control: NotebookHistoryControl) throws {
    guard let scope = historyPhase.scope, historyPhase == .quiescent(scope), peerQuiesced,
      !peerResumeRequested else {
      throw NotebookTransportError.historyReadinessPending
    }
    try validateHistoryPayload(control, scope: scope, sender: identity.deviceID)
    switch control {
    case .page, .root: try outgoing.enqueue(.historyReadiness(control)); pump()
    default: throw NotebookTransportError.invalidFrame
    }
  }

  /// Retain one caller-owned page while the existing TLS window is full. Only
  /// an actual credit or socket send completion permits another enqueue try.
  func sendHistoryControlAwaitingCredit(_ control: NotebookHistoryControl,
    scope: NotebookHistoryControlScope) async throws {
    try Task.checkCancellation()
    try requireHistoryScope(scope)
    guard historyOperation == nil else { throw NotebookTransportError.historyReadinessPending }
    let operation = UUID(); historyOperation = operation
    defer {
      if historyOperation == operation { historyOperation = nil; historyDeadline?.cancel(); historyDeadline = nil }
    }
    try await enqueueHistoryAwaitingCredit(scope) { try self.sendHistoryControl(control) }
  }

  /// Borrow the caller's existing historyOperation and its one waiter. A
  /// blocked terminal frame shares the same window and original deadline.
  private func enqueueHistoryAwaitingCredit(_ scope: NotebookHistoryControlScope,
    enqueue: () throws -> Void) async throws {
    while true {
      try Task.checkCancellation()
      try requireHistoryScope(scope)
      let progress = historySendProgress
      do {
        try enqueue()
        try requireHistoryScope(scope)
        return
      } catch NotebookTransportError.backpressure {
        if historyDeadline == nil { startHistoryDeadline(scope) }
        try await waitForHistory(scope) { self.historySendProgress != progress }
      }
    }
  }

  private var durableWorkIsEmpty: Bool {
    offeredChanges.isEmpty && incomingChanges.isEmpty && commitAcknowledgements.isEmpty
      && requestedBlobs.isEmpty && completedBlobs.isEmpty
  }
  private var framesAreDrained: Bool {
    !isSending && outgoing.pendingCount == 0 && outgoing.window.unacknowledged.isEmpty && incoming.pending.isEmpty
  }
  private func committedPrefixesMatch(_ scope: NotebookHistoryControlScope) -> Bool {
    guard let local = scope.endpoint(for: identity.deviceID), let peer = peerIdentity,
      let remote = scope.endpoint(for: peer.deviceID) else { return false }
    return offeredCursor == local.through && peerAcceptedThrough == local.through
      && lastIncomingOffer == remote.through && incomingAcceptedThrough == remote.through
  }
  private func preparedHeadsMatch(_ scope: NotebookHistoryControlScope) -> Bool {
    guard let localPrepared, let peerPrepared, let peer = peerIdentity else { return false }
    return scope.endpoint(for: identity.deviceID)?.head == localPrepared.head
      && scope.endpoint(for: peer.deviceID)?.head == peerPrepared.head
  }
  private func validateHistoryPreparation(_ preparation: NotebookHistoryControlPreparation) throws {
    guard !isStopped, isReady, authenticated, preparation.isValid, preparation.workspaceID == identity.workspaceID,
      preparation.credentialID == credentialID, let build = historyApplicationBuild, build != "unknown",
      preparation.applicationBuild == build, let journalGeneration = storage.journalGeneration,
      let local = preparation.endpoint(for: identity.deviceID), local.identity == identity,
      local.journalGeneration == journalGeneration, let peer = peerIdentity,
      let remote = preparation.endpoint(for: peer.deviceID), remote.identity == peer,
      remote.journalGeneration == remoteHello?.journalGeneration else { throw NotebookTransportError.identityMismatch }
  }
  private func validateHistoryScope(_ scope: NotebookHistoryControlScope) throws {
    guard scope.isValid else { throw NotebookTransportError.identityMismatch }
    try validateHistoryPreparation(scope.preparation)
  }
  private func validateHistoryPrepared(_ prepared: NotebookHistoryControl.Prepared,
    preparation: NotebookHistoryControlPreparation, sender: UUID, previous: NotebookHistoryControl.Prepared?) throws {
    guard prepared.isValid, prepared.requestID == preparation.requestID, prepared.workspaceID == preparation.workspaceID,
      prepared.source.deviceID == sender, let endpoint = preparation.endpoint(for: sender),
      prepared.source.generation == endpoint.journalGeneration else { throw NotebookTransportError.identityMismatch }
    if let previous {
      let before = previous.head?.sequence ?? 0, after = prepared.head?.sequence ?? 0
      guard prepared.readRevision >= previous.readRevision, after >= before,
        after != before || previous.head == prepared.head else { throw NotebookTransportError.historyCutStale }
    }
  }
  private func requireHistoryScope(_ scope: NotebookHistoryControlScope) throws {
    try validateHistoryScope(scope)
    guard historyPhase.scope == scope, historyPhase != .stale(scope) else { throw NotebookTransportError.historyCutStale }
  }
  private func validateHistoryPayload(_ control: NotebookHistoryControl, scope: NotebookHistoryControlScope,
    sender: UUID) throws {
    try control.validate()
    guard control.requestID == scope.requestID, let endpoint = scope.endpoint(for: sender) else {
      throw NotebookTransportError.historyCutStale
    }
    let source: NotebookReplicationSource?, workspace: UUID?
    switch control {
    case .page(let page): source = page.source; workspace = page.workspaceID
    case .root(let root): source = root.source; workspace = root.workspaceID
    case .resume(_, let refusal):
      if let refusal {
        guard refusal.origin.deviceID == sender,
          refusal.origin.generation == endpoint.journalGeneration else {
          throw NotebookTransportError.identityMismatch
        }
      }
      source = nil; workspace = nil
    default: source = nil; workspace = nil
    }
    if let source {
      guard source.deviceID == sender, source.generation == endpoint.journalGeneration,
        workspace == scope.workspaceID else { throw NotebookTransportError.identityMismatch }
    }
  }
  private func receiveHistoryControl(_ control: NotebookHistoryControl, from peer: NotebookTransportIdentity) throws {
    try control.validate()
    if case .stale(let requestID, let reason) = control {
      // The cancellation echo may follow a newly admitted request in this
      // same ordered connection. It cannot release or stale that new owner.
      if reason == .cancelled, completedHistoryPreparation?.requestID == requestID { return }
      if case .preparing(let preparation) = historyPhase {
        guard requestID == preparation.requestID else { throw NotebookTransportError.historyCutStale }
        onHistoryControl?(control, peer)
        if reason != .cancelled { stop(NotebookTransportError.historyCutStale, notifyingPeer: false) }
        return
      }
    }
    if case .prepare(let preparation) = control {
      try validateHistoryPreparation(preparation)
      guard historyPhase == .open || historyPhase == .preparing(preparation), onHistoryControl != nil else {
        throw NotebookTransportError.historyReadinessPending
      }
      onHistoryControl?(control, peer); return
    }
    if case .prepared(let prepared) = control {
      guard let preparation = historyPhase.preparation else { throw NotebookTransportError.historyReadinessPending }
      if let scope = historyPhase.scope {
        // A newer read_revision for the same advertised head can already be
        // queued when this native owner admits. It cannot change the scope.
        guard (historyPhase == .quiescing(scope) || historyPhase == .quiescent(scope)),
          !peerQuiesced, prepared.head == scope.endpoint(for: peer.deviceID)?.head else {
          throw NotebookTransportError.historyCutStale
        }
      }
      try validateHistoryPrepared(prepared, preparation: preparation, sender: peer.deviceID, previous: peerPrepared)
      peerPrepared = prepared; onHistoryControl?(control, peer); onHistoryProgress?(historyBoundaryObservation); return
    }
    if case .request(let scope) = control {
      try validateHistoryScope(scope)
      guard historyPhase == .preparing(scope.preparation) || historyPhase.scope == scope, onHistoryControl != nil else {
        throw NotebookTransportError.historyReadinessPending
      }
      guard peerProposedHistoryScope == nil || peerProposedHistoryScope == scope else {
        throw NotebookTransportError.historyCutStale
      }
      peerProposedHistoryScope = scope
      onHistoryControl?(control, peer); return
    }
    if case .quiesced(let scope) = control, historyPhase == .preparing(scope.preparation) {
      // Receipt credit can precede the native owner's SQL await. Retain this
      // bounded acknowledgement only after its exact ordered proposal. The
      // phase stays preparing until that owner independently admits the cut.
      try validateHistoryScope(scope)
      guard peerProposedHistoryScope == scope else { throw NotebookTransportError.historyCutStale }
      peerQuiescedScope = scope
      onHistoryControl?(control, peer); signalHistory(); return
    }
    guard let scope = historyPhase.scope else { throw NotebookTransportError.historyReadinessPending }
    try requireHistoryScope(scope); try validateHistoryPayload(control, scope: scope, sender: peer.deviceID)
    switch control {
    case .quiesced(let remoteScope):
      guard remoteScope == scope, historyPhase == .quiescing(scope) || historyPhase == .quiescent(scope) else {
        throw NotebookTransportError.historyCutStale
      }
      peerQuiescedScope = scope
    case .page, .root:
      // The two TCP directions drain independently. Pages already sent before
      // this endpoint's refusal still earn normal credit until the peer's own
      // ordered terminal resume. They cannot cross that terminal boundary.
      guard peerQuiesced, !peerResumeRequested,
        historyPhase == .quiescent(scope) || historyPhase == .resuming(scope) else {
        throw NotebookTransportError.historyNotDrained
      }
    case .resume:
      guard !peerResumeRequested,
        historyPhase == .quiescent(scope) || historyPhase == .resuming(scope) else {
        throw NotebookTransportError.historyCutStale
      }
      peerResumeRequested = true
    case .resumed:
      guard historyPhase == .resuming(scope), peerResumeRequested else { throw NotebookTransportError.historyCutStale }
      peerResumed = true
      finishHistoryResumeIfReady(scope)
    case .stale(_, let reason): invalidateHistory(reason); throw NotebookTransportError.historyCutStale
    case .prepare, .prepared, .request: throw NotebookTransportError.invalidFrame
    }
    onHistoryControl?(control, peer); signalHistory()
  }
  private func waitForHistory(_ scope: NotebookHistoryControlScope, until condition: () -> Bool) async throws {
    try await withTaskCancellationHandler {
      while true {
        try Task.checkCancellation()
        guard !isStopped, isReady else { throw NotebookTransportError.disconnected }
        if historyPhase == .open, completedHistoryResume == scope, condition() { return }
        try requireHistoryScope(scope)
        if condition() { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          guard historyWaiter == nil else { continuation.resume(throwing: NotebookTransportError.historyReadinessPending); return }
          historyWaiter = continuation
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.historyPhase.scope == scope else { return }
        self.invalidateHistory(.cancelled)
      }
    }
  }
  private func signalHistory(throwing error: Error? = nil) {
    let waiter = historyWaiter; historyWaiter = nil
    if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
  }
  private func finishHistoryResumeIfReady(_ scope: NotebookHistoryControlScope) {
    guard historyPhase == .resuming(scope), localResumed, peerResumed else { return }
    // The resumed frame is queued before any restarted offer in the same FIFO.
    // Open synchronously on receipt, before a following TCP frame can enter.
    completedHistoryResume = scope; historyPhase = .open
    peerProposedHistoryScope = nil; peerQuiescedScope = nil
    signalHistory(); notifyDurableChanges()
  }
  private func startHistoryDeadline(_ scope: NotebookHistoryControlScope) {
    historyDeadline?.cancel()
    historyDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, self.historyPhase.scope == scope else { return }
      self.invalidateHistory(.connectionChanged)
    }
  }
  private func invalidateHistory(_ reason: NotebookHistoryControl.StaleReason) {
    guard let scope = historyPhase.scope, historyPhase != .stale(scope) else { return }
    historyPhase = .stale(scope)
    if let peerIdentity { onHistoryControl?(.stale(requestID: scope.requestID, reason: reason), peerIdentity) }
    stop(NotebookTransportError.historyCutStale, notifyingPeer: false)
  }

  func sendTransient(_ value: NotebookTransportTransient) {
    guard historyPhase.permitsStorage, isReady, !isStopped, value.isValid(from: identity) else { return }
    enqueue(.transient(value))
  }

  func notifyDurableChanges() {
    guard historyPhase.permitsStorage, isReady, !isStopped else { return }
    shouldReadJournal = true
    guard offerTask == nil, offeredChanges.count < NotebookTransportLimits.maximumPendingChanges else { return }
    offerTask = Task { [weak self] in
      guard let self else { return }
      do {
        while self.historyPhase.permitsStorage, self.shouldReadJournal, !self.isStopped, self.offeredChanges.count < NotebookTransportLimits.maximumPendingChanges {
          self.shouldReadJournal = false
          let capacity = NotebookTransportLimits.maximumPendingChanges - self.offeredChanges.count
          let cursor = self.offeredCursor
          let changes = try await self.storage.changes(cursor, capacity)
          guard !self.isStopped, !Task.isCancelled else { return }
          if !self.historyPhase.permitsStorage {
            guard changes.isEmpty else { self.invalidateHistory(.changedPrefix); return }
            break
          }
          guard changes.count <= capacity else { throw NotebookTransportError.resourceLimit }
          for change in changes {
            try Self.validate(change)
            guard change.sequence > self.offeredCursor else { throw NotebookTransportError.invalidSequence }
            self.offeredCursor = change.sequence; self.offeredChanges.append(change); self.enqueue(.offer(change))
          }
          // A full journal page is resumed by durable ACK, never by polling.
        }
        self.offerTask = nil
        self.onHistoryProgress?(self.historyBoundaryObservation)
      } catch { self.stop(error) }
    }
  }

  private func readFrames() async {
    do {
      while !isStopped, !Task.isCancelled {
        let prefix = try await receiveExactly(4)
        let length = try NotebookTransportFraming.payloadLength(prefix)
        let payload = try await receiveExactly(length)
        guard !isStopped, !Task.isCancelled else { return }
        let packet = try await Task.detached(priority: .userInitiated) { try NotebookTransportFraming.decode(payload) }.value
        guard !isStopped, !Task.isCancelled else { return }
        try await receive(packet)
      }
    } catch { if !isStopped { stop(error) } }
  }

  private func receiveExactly(_ length: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
        if let error { continuation.resume(throwing: error) }
        else if let data, data.count == length { continuation.resume(returning: data) }
        else { continuation.resume(throwing: NotebookTransportError.disconnected) }
      }
    }
  }

  /// The same admission path serves real frames and deterministic negative tests.
  func receive(_ packet: NotebookTransportPacket) async throws {
    guard !isStopped, isTLSReady else { throw NotebookTransportError.authenticationRequired }
    guard packet.version == NotebookTransportLimits.protocolVersion,
      (packet.sequence == 0) == packet.message.isControl else { throw NotebookTransportError.invalidFrame }
    if !historyPhase.permitsStorage {
      switch packet.message {
      case .offer, .requestBlobs, .blobs, .committed:
        // A late durable frame invalidates the shared cut before any storage
        // callback or frame/durable acknowledgement can be admitted.
        invalidateHistory(.lateContent); throw NotebookTransportError.historyCutStale
      default: break
      }
    }
    if !packet.message.isControl {
      guard isReady else { throw NotebookTransportError.authenticationRequired }
      try incoming.accept(packet.sequence)
    }
    switch packet.message {
    case .hello(let hello): try receiveHello(hello)
    case .proof(let proof): try await receiveProof(proof)
    case .ready(let cursor):
      guard authenticated, remoteCursor == nil, cursor <= UInt64(Int64.max) else {
        throw NotebookTransportError.authenticationRequired
      }
      remoteCursor = cursor; offeredCursor = cursor; peerAcceptedThrough = cursor; becomeReady()
    case .credit(let values):
      guard isReady else { throw NotebookTransportError.authenticationRequired }
      try outgoing.acknowledge(values); historySendProgress &+= 1; pump(); signalHistory()
    case .contentUnavailable(let requirement):
      // The peer can reject its first journal read before its queued ready
      // frame reaches us. Account-authorized authentication admits this
      // error-only control. Offers and blobs still require full readiness.
      guard authenticated else { throw NotebookTransportError.authenticationRequired }
      stop(requirement.error, notifyingPeer: false)
    default:
      guard isReady, let peerIdentity else { throw NotebookTransportError.authenticationRequired }
      switch packet.message {
      case .transient(let value):
        guard value.isValid(from: peerIdentity) else { throw NotebookTransportError.identityMismatch }
        if historyPhase.permitsStorage { onTransient?(value, peerIdentity) }
        try consumed(packet.sequence)
      case .historyReadiness(let control):
        try receiveHistoryControl(control, from: peerIdentity)
        try consumed(packet.sequence)
      case .offer(let change):
        try Self.validate(change)
        guard incomingChanges.count < 16, change.sequence > lastIncomingOffer else { throw NotebookTransportError.invalidSequence }
        lastIncomingOffer = change.sequence; incomingChanges.append(change)
        try consumed(packet.sequence); advanceIncomingChange()
      case .requestBlobs(let requests): try serveBlobs(requests, frameSequence: packet.sequence)
      case .blobs(let chunks): try receiveBlobs(chunks, frameSequence: packet.sequence)
      case .committed(let transactionID, let cursor):
        guard commitAcknowledgements.count < 16, !commitAcknowledgements.contains(where: { $0.0 == transactionID }),
          offeredChanges.contains(where: { $0.transactionID == transactionID && $0.sequence == cursor }) else {
          throw NotebookTransportError.invalidAcknowledgement
        }
        commitAcknowledgements.append((transactionID, cursor)); persistAcknowledgements()
      default: throw NotebookTransportError.invalidFrame
      }
    }
  }

  private func receiveHello(_ hello: NotebookTransportHello) throws {
    guard remoteHello == nil, !authenticated, hello.nonce.count == 32 else { throw NotebookTransportError.authenticationRequired }
    if credential == nil {
      guard let resolved = try resolveCredential?(hello) else { throw NotebookTransportError.authenticationRequired }
      credential = resolved
      localHello = .init(identity: identity, credentialID: resolved.credentialID, nonce: try NotebookTransportTLS.randomBytes(count: 32), journalGeneration: storage.journalGeneration)
      enqueue(.hello(localHello!))
    }
    guard let credential, let localHello, hello.credentialID == credential.credentialID else {
      throw NotebookTransportError.authenticationRequired
    }
    let expected = credential.expectedPeer
    guard expected.deviceID == hello.identity.deviceID, expected.workspaceID == hello.identity.workspaceID else { throw NotebookTransportError.identityMismatch }
    let transcript = try NotebookTransportAuthentication.transcript(localHello, hello)
    self.transcript = transcript; remoteHello = hello; peerIdentity = hello.identity
    enqueue(.proof(NotebookTransportAuthentication.proof(secret: credential.secret, transcript: transcript, sender: identity.deviceID)))
  }

  private func receiveProof(_ proof: Data) async throws {
    guard !authenticated, let credential, let transcript, let peerIdentity,
      NotebookTransportAuthentication.verifies(proof, secret: credential.secret, transcript: transcript, sender: peerIdentity.deviceID)
    else { throw NotebookTransportError.authenticationRequired }
    let approved = try await onAuthenticated?(peerIdentity, credential) ?? false
    guard !isStopped else { throw NotebookTransportError.disconnected }
    guard approved else { throw NotebookTransportError.authenticationRequired }
    authenticated = true
    prepareReady()
  }

  private func prepareReady() {
    guard authenticated, !sentReady, readyTask == nil, let peerIdentity else { return }
    readyTask = Task { [weak self] in
      guard let self else { return }
      do {
        let cursor = try await self.storage.incomingCursor(.init(deviceID: peerIdentity.deviceID, generation: self.remoteHello!.journalGeneration))
        guard !self.isStopped, !Task.isCancelled else { return }
        guard cursor <= UInt64(Int64.max) else { throw NotebookTransportError.invalidSequence }
        self.lastIncomingOffer = cursor; self.incomingAcceptedThrough = cursor
        self.sentReady = true; self.enqueue(.ready(cursor: cursor)); self.becomeReady()
        self.onHistoryProgress?(self.historyBoundaryObservation)
      } catch { self.stop(error) }
      self.readyTask = nil
    }
  }

  private func becomeReady() {
    guard !isReady, !isStopped, sentReady, remoteCursor != nil, let peerIdentity else { return }
    isReady = true; timeoutTask?.cancel(); timeoutTask = nil
    onReady?(peerIdentity); notifyDurableChanges()
  }

  private func advanceIncomingChange() {
    guard historyPhase.permitsStorage, incomingTask == nil, requestedBlobs.isEmpty, !isStopped, let change = incomingChanges.first, let peerIdentity else { return }
    incomingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let delivery = NotebookReplicationDelivery(source: .init(deviceID: peerIdentity.deviceID, generation: self.remoteHello!.journalGeneration), change: change)
        let batch = self.completedBlobs
        let missing = try await self.storage.prepareIncoming(delivery, batch)
        guard !self.isStopped, !Task.isCancelled else { return }
        for blob in batch { try await self.assembly.discardCompleted(blob) }
        self.completedBlobs.removeAll(keepingCapacity: true)
        guard !self.isStopped, !Task.isCancelled else { return }
        guard missing.count <= NotebookTransportLimits.maximumBlobRequests, Set(missing).count == missing.count,
          missing.allSatisfy(NotebookTransportFraming.isSHA256) else { throw NotebookTransportError.invalidBlob }
        if !missing.isEmpty {
          self.requestedBlobs = missing.map { .init(hash: $0) }
          self.enqueue(.requestBlobs(self.requestedBlobs))
        } else {
          // This await is the only durable receive boundary. A frame credit
          // never advertises that history or an incoming cursor was committed.
          let cursor = try await self.storage.applyRemoteChange(delivery)
          guard !self.isStopped, !Task.isCancelled else { return }
          // Cloud may have covered a later prefix while this LAN offer was in
          // flight. Acknowledge only this offered transaction, not an unoffered
          // future sequence; the next connection reads the advanced SQL cursor.
          guard cursor >= change.sequence, cursor <= UInt64(Int64.max) else { throw NotebookTransportError.invalidAcknowledgement }
          self.incomingAcceptedThrough = max(self.incomingAcceptedThrough, cursor)
          self.incomingChanges.removeFirst()
          self.enqueue(.committed(transactionID: change.transactionID, cursor: change.sequence))
          self.onDurableChange?(change, peerIdentity)
        }
        self.incomingTask = nil
        self.onHistoryProgress?(self.historyBoundaryObservation)
        if self.requestedBlobs.isEmpty { self.advanceIncomingChange() }
      } catch { self.stop(error) }
    }
  }

  private func serveBlobs(_ requests: [NotebookTransportBlobRequest], frameSequence: UInt64) throws {
    guard historyPhase.permitsStorage, servingBlobTask == nil else { throw NotebookTransportError.unexpectedBlob }
    try NotebookTransportBlobWindow.validate(requests)
    servingBlobTask = Task { [weak self] in
      guard let self else { return }
      do {
        let chunks = try await self.storage.readBlobWindow(requests)
        guard !self.isStopped, !Task.isCancelled else { return }
        try NotebookTransportBlobWindow.validate(chunks, for: requests)
        self.enqueue(.blobs(chunks))
        try self.consumed(frameSequence); self.servingBlobTask = nil
      } catch { self.stop(error) }
    }
  }

  private func receiveBlobs(_ chunks: [NotebookTransportBlobChunk], frameSequence: UInt64) throws {
    guard historyPhase.permitsStorage, incomingTask == nil, !requestedBlobs.isEmpty,
      let change = incomingChanges.first else { throw NotebookTransportError.unexpectedBlob }
    try NotebookTransportBlobWindow.validate(chunks, for: requestedBlobs)
    incomingTask = Task { [weak self] in
      guard let self else { return }
      do {
        for chunk in chunks {
          guard !self.isStopped, !Task.isCancelled else { return }
          let maximum = chunk.hash == change.manifestHash ? NotebookTransportLimits.maximumManifestBytes : NotebookTransportLimits.maximumBlobBytes
          if chunk.hash == change.manifestHash, chunk.totalBytes != Int64(change.byteCount) { throw NotebookTransportError.invalidBlob }
          let completed = try await self.assembly.append(chunk, expectedHash: self.requestedBlobs[0].hash, maximumBytes: maximum)
          guard !self.isStopped, !Task.isCancelled else { return }
          if let completed {
            self.completedBlobs.append(completed)
            self.requestedBlobs.removeFirst()
            // Retain at most one dependency window and 512 KiB of small files;
            // a large streamed blob flushes immediately. Only verified bytes
            // reach SQL, and no transaction survives a network await.
            // The end of the window stages together with next discovery in
            // advanceIncomingChange; only a large interim prefix flushes here.
            if !self.requestedBlobs.isEmpty && self.completedBlobs.reduce(Int64(0), { $0 + $1.byteCount }) >= 512 * 1_024 {
              let batch = self.completedBlobs
              try await self.storage.stageBlobs(batch)
              guard !self.isStopped, !Task.isCancelled else { return }
              for blob in batch { try await self.assembly.discardCompleted(blob) }
              self.completedBlobs.removeAll(keepingCapacity: true)
            }
          } else {
            self.requestedBlobs[0] = .init(hash: chunk.hash, offset: chunk.offset + Int64(chunk.data.count))
          }
        }
        guard !self.isStopped, !Task.isCancelled else { return }
        try self.consumed(frameSequence); self.incomingTask = nil
        if self.requestedBlobs.isEmpty { self.advanceIncomingChange() }
        else { self.enqueue(.requestBlobs(self.requestedBlobs)) }
      } catch { self.stop(error) }
    }
  }

  private func persistAcknowledgements() {
    guard historyPhase.permitsStorage, acknowledgingTask == nil, let peerIdentity else { return }
    acknowledgingTask = Task { [weak self] in
      guard let self else { return }
      do {
        while !self.isStopped, let (transactionID, cursor) = self.commitAcknowledgements.first {
          guard let first = self.offeredChanges.first, first.transactionID == transactionID, first.sequence == cursor else {
            throw NotebookTransportError.invalidAcknowledgement
          }
          try await self.storage.acknowledgePeer(peerIdentity.deviceID, cursor)
          guard !self.isStopped, !Task.isCancelled else { return }
          self.peerAcceptedThrough = max(self.peerAcceptedThrough, cursor)
          self.commitAcknowledgements.removeFirst(); self.offeredChanges.removeFirst(); self.notifyDurableChanges()
        }
        self.acknowledgingTask = nil
        self.onHistoryProgress?(self.historyBoundaryObservation)
      } catch { self.stop(error) }
    }
  }

  private static func validate(_ change: NotebookDurableChange) throws {
    guard change.sequence > 0, change.sequence <= UInt64(Int64.max), NotebookTransportFraming.isSHA256(change.manifestHash),
      change.byteCount > 0, Int64(change.byteCount) <= NotebookTransportLimits.maximumManifestBytes else { throw NotebookTransportError.invalidBlob }
  }

  private func consumed(_ sequence: UInt64) throws {
    try incoming.consumed(sequence); try outgoing.enqueue(.credit([sequence])); pump()
  }
  private func enqueue(_ message: NotebookTransportMessage) {
    guard !isStopped else { return }
    do { try outgoing.enqueue(message); pump() } catch { stop(error) }
  }
  private func pump() {
    guard !isStopped, isTLSReady, !isSending else { return }
    do {
      guard let packet = try outgoing.takeNext() else { return }
      let frame = try NotebookTransportFraming.encode(packet)
      isSending = true
      connection.send(content: frame, completion: .contentProcessed { [weak self] error in
        Task { @MainActor in
          guard let self, !self.isStopped else { return }
          self.isSending = false
          if let error { self.stop(error) }
          else { self.historySendProgress &+= 1; self.pump(); self.signalHistory() }
        }
      })
    } catch { stop(error) }
  }
  private func setTimeout(seconds: Double) {
    timeoutTask?.cancel()
    timeoutTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      self?.stop(NotebookTransportError.disconnected)
    }
  }
}
