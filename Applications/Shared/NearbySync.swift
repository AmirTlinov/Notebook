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
/// supplies forward secrecy; the 128-bit invitation supplies authentication.
/// Both peers reject any other negotiated suite BEFORE sending application data.
/// TLS 1.3 and certificate trust overrides are deliberately not alternate paths.
enum NotebookTransportTLS {
  static let cipher: UInt16 = 0xCCAC
  struct Key: Sendable { let identity: String; let secret: Data }

  static func parameters(keys: [Key], loopback: Bool = false) throws -> NWParameters {
    guard !keys.isEmpty, keys.count <= 9,
      keys.allSatisfy({ (16...32).contains($0.secret.count) && !$0.identity.isEmpty && $0.identity.utf8.count <= 100 })
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

struct NotebookTrustedPeer: Codable, Equatable {
  let identity: NotebookTransportIdentity
  let pairingID: UUID
  let secret: Data
  var locallyConfirmed: Bool
  var remotelyConfirmed: Bool
  var isConfirmed: Bool { locallyConfirmed && remotelyConfirmed }
  var tlsKey: NotebookTransportTLS.Key { .init(identity: "paired:\(pairingID)", secret: secret) }
}

@MainActor
protocol NotebookPairingTrustStore {
  func load(for identity: NotebookTransportIdentity) throws -> [NotebookTrustedPeer]
  func save(_ records: [NotebookTrustedPeer], for identity: NotebookTransportIdentity) throws
}

/// One bounded, device-only Keychain item owns the pair credentials for a local
/// device/workspace and admitted archive activation. Pending approval is durable too, so a disconnect between
/// the two confirmations neither grants access nor strands an approved pair.
@MainActor
final class NotebookKeychainPairingStore: NotebookPairingTrustStore {
  private let activationID: UUID?
  init(activationID: UUID? = nil) { self.activationID = activationID }

  private func query(_ identity: NotebookTransportIdentity) -> [String: Any] {
    let activation = activationID.map { ":activation:\($0.uuidString.lowercased())" } ?? ""
    // Never fall back to another activation's credentials. Both devices retain
    // their own actor IDs while the newly admitted pair awaits confirmation.
    return [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.amirtlinov.notebook.nearby.pair-v1",
      kSecAttrAccount as String: "\(identity.deviceID):\(identity.workspaceID)\(activation)"]
  }
  func load(for identity: NotebookTransportIdentity) throws -> [NotebookTrustedPeer] {
    var query = query(identity); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let data = result as? Data, data.count <= 32_768 else { throw NotebookTransportError.storageUnavailable }
    let records = try JSONDecoder().decode([NotebookTrustedPeer].self, from: data)
    guard records.count <= 8, Set(records.map { $0.identity.deviceID }).count == records.count,
      records.allSatisfy({ $0.identity.isValid && $0.identity.workspaceID == identity.workspaceID
        && $0.identity.deviceID != identity.deviceID && $0.secret.count == 32 })
    else { throw NotebookTransportError.identityMismatch }
    return records
  }
  func save(_ records: [NotebookTrustedPeer], for identity: NotebookTransportIdentity) throws {
    guard records.count <= 8 else { throw NotebookTransportError.resourceLimit }
    let query = query(identity)
    if records.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw NotebookTransportError.storageUnavailable }
      return
    }
    let data = try JSONEncoder().encode(records)
    guard data.count <= 32_768 else { throw NotebookTransportError.resourceLimit }
    let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      let added = query.merging(values) { _, new in new }
      guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw NotebookTransportError.storageUnavailable }
    } else if status != errSecSuccess { throw NotebookTransportError.storageUnavailable }
  }
}

struct NotebookPeerCredential {
  let pairingID: UUID
  let kind: NotebookTransportHello.Credential
  let secret: Data
  let expectedPeer: NotebookTransportIdentity?
  var tlsKey: NotebookTransportTLS.Key { .init(identity: "\(kind.rawValue):\(pairingID)", secret: secret) }
}

@MainActor
final class NearbySync {
  enum Role { case macListener, iPadConnector }
  var onPairingChange: ((NotebookPairingState) -> Void)?
  var onConnect: ((NotebookTransportIdentity, UUID) -> Void)?
  var onDisconnect: ((UUID, UUID) -> Void)?
  var onTransient: ((NotebookTransportTransient, UUID, UUID) -> Void)?
  var onDurableChange: ((NotebookDurableChange, UUID, UUID) -> Void)?
  var pairedPeers: [NotebookTransportIdentity] { trusted.filter(\.isConfirmed).map(\.identity) }

  let identity: NotebookTransportIdentity
  private let role: Role
  private let storage: NotebookTransportStorage
  private let stagingRoot: URL
  private let trustStore: any NotebookPairingTrustStore
  private let queue = DispatchQueue(label: "Notebook.Nearby.TLS")
  private var trusted: [NotebookTrustedPeer] = []
  private var invitation: NotebookPairingInvitation?
  private var joinedInvitation: NotebookPairingInvitation?
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var endpointByPeer: [UUID: NWEndpoint] = [:]
  private var sessions: [UUID: NotebookTransportSession] = [:]
  private var currentGeneration: [UUID: UUID] = [:]
  private var retryTask: Task<Void, Never>?
  private var invitationTask: Task<Void, Never>?
  private var isStarted = false
  private let logger = Logger(subsystem: "com.amirtlinov.notebook", category: "NearbySync")

  init(role: Role, identity: NotebookTransportIdentity, storage: NotebookTransportStorage, stagingRoot: URL,
    trustStore: (any NotebookPairingTrustStore)? = nil) {
    self.role = role; self.identity = identity; self.storage = storage; self.stagingRoot = stagingRoot
    self.trustStore = trustStore ?? NotebookKeychainPairingStore()
  }

  func start() {
    guard !isStarted else { return }
    do {
      guard identity.isValid else { throw NotebookTransportError.identityMismatch }
      trusted = try trustStore.load(for: identity)
      // Only abandoned generation directories beneath this transport-owned
      // cache are removed. Authoritative SQLite blobs are never staging files.
      if FileManager.default.fileExists(atPath: stagingRoot.path) {
        for url in try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)
          where UUID(uuidString: url.lastPathComponent) != nil {
          try FileManager.default.removeItem(at: url)
        }
      }
      isStarted = true
      refreshDiscovery()
    } catch { report(error) }
  }

  func stop() {
    isStarted = false; retryTask?.cancel(); retryTask = nil; invitationTask?.cancel(); invitationTask = nil
    listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
    endpointByPeer.removeAll()
    for session in Array(sessions.values) { session.stop() }
    sessions.removeAll(); currentGeneration.removeAll()
    invitation = nil; joinedInvitation = nil
  }

  func createPairingInvitation() throws -> NotebookPairingInvitation {
    guard role == .macListener, isStarted, trusted.count < 8 else { throw NotebookTransportError.resourceLimit }
    try cancelPairing()
    let value = try NotebookPairingInvitation(inviter: identity, secret: NotebookTransportTLS.randomBytes(count: 16), expiresAt: Date().addingTimeInterval(600))
    invitation = value; onPairingChange?(.invitation(value)); refreshListener(); scheduleInvitationExpiry(value)
    return value
  }

  func joinPairingInvitation(_ text: String) throws {
    guard role == .iPadConnector, isStarted, trusted.count < 8 else { throw NotebookTransportError.resourceLimit }
    let value = try NotebookPairingInvitation.decode(text)
    guard value.inviter.workspaceID == identity.workspaceID, value.inviter.deviceID != identity.deviceID else {
      throw NotebookTransportError.identityMismatch
    }
    try cancelPairing(); joinedInvitation = value; onPairingChange?(.connecting)
    scheduleInvitationExpiry(value); refreshDiscovery(); connectDiscoveredPeers()
  }

  func confirmPairing(generation: UUID) throws {
    guard let session = sessions[generation] else { throw NotebookTransportError.disconnected }
    try session.confirmPairing()
  }

  func cancelPairing() throws {
    let pairingIDs = Set([invitation?.id, joinedInvitation?.id].compactMap { $0 }
      + trusted.filter { !$0.isConfirmed }.map(\.pairingID))
    let updated = trusted.filter { $0.isConfirmed || !pairingIDs.contains($0.pairingID) }
    if updated != trusted { try trustStore.save(updated, for: identity); trusted = updated }
    invitationTask?.cancel(); invitationTask = nil
    invitation = nil; joinedInvitation = nil
    for session in Array(sessions.values) where session.pairingID.map(pairingIDs.contains) == true && !session.isReady { session.stop() }
    onPairingChange?(.idle)
    if isStarted { refreshDiscovery() }
  }

  func revokePeer(_ deviceID: UUID) throws {
    let remaining = trusted.filter { $0.identity.deviceID != deviceID }
    try trustStore.save(remaining, for: identity); trusted = remaining
    for session in Array(sessions.values) where session.peerIdentity?.deviceID == deviceID { session.stop() }
    endpointByPeer.removeValue(forKey: deviceID); refreshDiscovery()
  }

  func notifyDurableChanges() { for session in sessions.values where session.isReady { session.notifyDurableChanges() } }
  func sendTransient(_ value: NotebookTransportTransient, to peerID: UUID? = nil) {
    guard value.isValid(from: identity) else { return }
    for session in sessions.values where session.isReady && (peerID == nil || session.peerIdentity?.deviceID == peerID) { session.sendTransient(value) }
  }

  private func scheduleInvitationExpiry(_ value: NotebookPairingInvitation) {
    invitationTask?.cancel()
    invitationTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0, value.expiresAt.timeIntervalSinceNow))) } catch { return }
      guard let self, self.invitation?.id == value.id || self.joinedInvitation?.id == value.id else { return }
      do { try self.cancelPairing(); self.onPairingChange?(.failed("Срок приглашения истёк. Создайте новое на Mac.")) }
      catch { self.report(error) }
    }
  }

  private func refreshDiscovery() {
    guard isStarted else { return }
    switch role {
    case .macListener: refreshListener()
    case .iPadConnector:
      if trusted.isEmpty, joinedInvitation == nil {
        browser?.cancel(); browser = nil; endpointByPeer.removeAll(); return
      }
      guard browser == nil, !trusted.isEmpty || joinedInvitation != nil else { return }
      let browser = NWBrowser(for: .bonjour(type: "_notebook._tcp", domain: nil), using: .tcp)
      self.browser = browser
      browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
        Task { @MainActor in
          guard let self, let browser, self.browser === browser, self.isStarted else { return }
          let allowed = Set(self.trusted.map { $0.identity.deviceID } + [self.joinedInvitation?.inviter.deviceID].compactMap { $0 })
          var endpoints: [UUID: NWEndpoint] = [:]
          for result in results.sorted(by: { String(describing: $0.endpoint) < String(describing: $1.endpoint) }) {
            guard case .service(let name, _, _, _) = result.endpoint, name.hasPrefix("notebook-v1-"),
              let deviceID = UUID(uuidString: String(name.dropFirst(12))), allowed.contains(deviceID), endpoints[deviceID] == nil else { continue }
            endpoints[deviceID] = result.endpoint
          }
          self.endpointByPeer = endpoints; self.connectDiscoveredPeers()
        }
      }
      browser.stateUpdateHandler = { [weak self] state in
        if case .failed(let error) = state { Task { @MainActor in self?.report(error) } }
      }
      browser.start(queue: queue)
    }
  }

  private func refreshListener() {
    listener?.cancel(); listener = nil
    guard isStarted, role == .macListener else { return }
    var keys = trusted.map(\.tlsKey)
    if let invitation, invitation.expiresAt > Date() { keys.append(.init(identity: "invitation:\(invitation.id)", secret: invitation.secret)) }
    guard !keys.isEmpty else { return }
    do {
      let listener = try NWListener(using: NotebookTransportTLS.parameters(keys: keys))
      self.listener = listener
      listener.service = .init(name: "notebook-v1-\(identity.deviceID)", type: "_notebook._tcp")
      listener.newConnectionHandler = { [weak self, weak listener] connection in
        Task { @MainActor in
          guard let self, let listener, self.listener === listener, self.isStarted, self.sessions.count < 8 else { connection.cancel(); return }
          self.addSession(connection: connection, credential: nil)
        }
      }
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        if case .failed(let error) = state {
          Task { @MainActor in guard let self, let listener, self.listener === listener else { return }; self.report(error) }
        }
      }
      listener.start(queue: queue)
    } catch { report(error) }
  }

  private func connectDiscoveredPeers() {
    guard isStarted, role == .iPadConnector else { return }
    for (deviceID, endpoint) in endpointByPeer where sessions.count < 8 {
      guard !sessions.values.contains(where: { $0.expectedPeerID == deviceID || $0.peerIdentity?.deviceID == deviceID }) else { continue }
      let credential: NotebookPeerCredential
      if let joinedInvitation, joinedInvitation.inviter.deviceID == deviceID, joinedInvitation.expiresAt > Date() {
        credential = .init(pairingID: joinedInvitation.id, kind: .invitation, secret: joinedInvitation.secret, expectedPeer: joinedInvitation.inviter)
      } else if let peer = trusted.first(where: { $0.identity.deviceID == deviceID }) {
        credential = .init(pairingID: peer.pairingID, kind: .paired, secret: peer.secret, expectedPeer: peer.identity)
      } else { continue }
      do { addSession(connection: NWConnection(to: endpoint, using: try NotebookTransportTLS.parameters(keys: [credential.tlsKey])), credential: credential) }
      catch { report(error) }
    }
  }

  private func resolve(_ hello: NotebookTransportHello) throws -> NotebookPeerCredential {
    guard hello.identity.isValid, hello.identity.workspaceID == identity.workspaceID, hello.identity.deviceID != identity.deviceID else {
      throw NotebookTransportError.identityMismatch
    }
    if hello.credential == .invitation, let invitation, invitation.id == hello.pairingID, invitation.expiresAt > Date() {
      guard !trusted.contains(where: { !$0.isConfirmed && $0.pairingID == invitation.id && $0.identity.deviceID != hello.identity.deviceID }) else {
        throw NotebookTransportError.pairingRejected
      }
      return .init(pairingID: invitation.id, kind: .invitation, secret: invitation.secret, expectedPeer: nil)
    }
    if hello.credential == .paired, let peer = trusted.first(where: { $0.pairingID == hello.pairingID && $0.identity.deviceID == hello.identity.deviceID }) {
      return .init(pairingID: peer.pairingID, kind: .paired, secret: peer.secret, expectedPeer: peer.identity)
    }
    throw NotebookTransportError.authenticationRequired
  }

  private func authenticate(_ peer: NotebookTransportIdentity, credential: NotebookPeerCredential, generation: UUID) throws -> Bool {
    if credential.kind == .invitation {
      guard let invitation = invitation ?? joinedInvitation, invitation.id == credential.pairingID, invitation.expiresAt > Date() else {
        throw NotebookTransportError.pairingExpired
      }
      let joiner = invitation.inviter.deviceID == identity.deviceID ? peer : identity
      let secret = try NotebookTransportAuthentication.pairedSecret(invitation: invitation, joiner: joiner)
      guard !trusted.contains(where: { $0.identity.deviceID == peer.deviceID && $0.pairingID != credential.pairingID }) else {
        throw NotebookTransportError.identityMismatch
      }
      if !trusted.contains(where: { $0.identity.deviceID == peer.deviceID && $0.pairingID == credential.pairingID }) {
        guard trusted.count < 8 else { throw NotebookTransportError.resourceLimit }
        var updated = trusted.filter { $0.identity.deviceID != peer.deviceID }
        updated.append(.init(identity: peer, pairingID: credential.pairingID, secret: secret, locallyConfirmed: false, remotelyConfirmed: false))
        try trustStore.save(updated, for: identity); trusted = updated
      }
    }
    guard let record = trusted.first(where: { $0.identity.deviceID == peer.deviceID && $0.pairingID == credential.pairingID }) else {
      throw NotebookTransportError.authenticationRequired
    }
    onPairingChange?(.confirmation(peer: peer, generation: generation, locallyConfirmed: record.locallyConfirmed))
    return record.locallyConfirmed
  }

  private func confirm(_ peer: NotebookTransportIdentity, pairingID: UUID, local: Bool, generation: UUID) throws {
    guard let index = trusted.firstIndex(where: { $0.identity.deviceID == peer.deviceID && $0.pairingID == pairingID }) else {
      throw NotebookTransportError.authenticationRequired
    }
    var updated = trusted
    if local { updated[index].locallyConfirmed = true } else { updated[index].remotelyConfirmed = true }
    try trustStore.save(updated, for: identity); trusted = updated
    onPairingChange?(.confirmation(peer: peer, generation: generation, locallyConfirmed: updated[index].locallyConfirmed))
  }

  private func addSession(connection: NWConnection, credential: NotebookPeerCredential?) {
    do {
      let session = try NotebookTransportSession(connection: connection, identity: identity, credential: credential,
        storage: storage, stagingRoot: stagingRoot, queue: queue)
      let generation = session.generation
      sessions[generation] = session
      session.resolveCredential = { [weak self] hello in guard let self else { throw NotebookTransportError.disconnected }; return try self.resolve(hello) }
      session.onAuthenticated = { [weak self] peer, credential in
        guard let self, self.sessions[generation] != nil else { throw NotebookTransportError.disconnected }
        return try self.authenticate(peer, credential: credential, generation: generation)
      }
      session.onConfirmation = { [weak self] peer, pairingID, local in
        guard let self, self.sessions[generation] != nil else { throw NotebookTransportError.disconnected }
        try self.confirm(peer, pairingID: pairingID, local: local, generation: generation)
      }
      session.onReady = { [weak self, weak session] peer in
        guard let self, let session, self.sessions[generation] != nil else { return }
        let old = self.currentGeneration.updateValue(generation, forKey: peer.deviceID)
        if let old, old != generation { self.sessions[old]?.stop() }
        self.onPairingChange?(.paired(peer)); self.onConnect?(peer, generation)
        if self.invitation?.id == session.pairingID || self.joinedInvitation?.id == session.pairingID {
          self.invitation = nil; self.joinedInvitation = nil; self.invitationTask?.cancel(); self.invitationTask = nil
          if self.role == .macListener { self.refreshListener() }
        }
      }
      session.onTransient = { [weak self] value, peer in
        guard let self, self.currentGeneration[peer.deviceID] == generation else { return }
        self.onTransient?(value, peer.deviceID, generation)
      }
      session.onDurableChange = { [weak self] change, peer in
        guard let self, self.currentGeneration[peer.deviceID] == generation else { return }
        self.onDurableChange?(change, peer.deviceID, generation); self.notifyDurableChanges()
      }
      session.onStop = { [weak self] peer, error in
        guard let self else { return }
        self.sessions.removeValue(forKey: generation)
        if let peer {
          if self.currentGeneration[peer.deviceID] == generation { self.currentGeneration.removeValue(forKey: peer.deviceID) }
          self.onDisconnect?(peer.deviceID, generation)
        }
        if let error { self.report(error) }
        self.scheduleReconnect()
      }
      session.start()
    } catch { connection.cancel(); report(error) }
  }

  private func scheduleReconnect() {
    guard isStarted, role == .iPadConnector, retryTask == nil else { return }
    retryTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self else { return }; self.retryTask = nil; self.connectDiscoveredPeers()
    }
  }
  private func report(_ error: Error) {
    // Credentials, invitation payloads and notebook content never enter logs.
    logger.error("Trusted nearby connection failed: \(String(describing: error), privacy: .public)")
    onPairingChange?(.failed("Связь не установлена. Проверьте приглашение, подтверждение и локальную сеть."))
  }
}

/// One TLS connection generation owns framing, credits, handshake, staging and
/// commit callbacks. SQL calls use the injected storage executor; camera/contact
/// receipt does not wait for a blob write or a SQL transaction to finish.
@MainActor
final class NotebookTransportSession {
  let generation = UUID()
  var resolveCredential: ((NotebookTransportHello) throws -> NotebookPeerCredential)?
  var onAuthenticated: ((NotebookTransportIdentity, NotebookPeerCredential) throws -> Bool)?
  var onConfirmation: ((NotebookTransportIdentity, UUID, Bool) throws -> Void)?
  var onReady: ((NotebookTransportIdentity) -> Void)?
  var onTransient: ((NotebookTransportTransient, NotebookTransportIdentity) -> Void)?
  var onDurableChange: ((NotebookDurableChange, NotebookTransportIdentity) -> Void)?
  var onStop: ((NotebookTransportIdentity?, Error?) -> Void)?
  private(set) var peerIdentity: NotebookTransportIdentity?
  private(set) var isReady = false
  var pairingID: UUID? { credential?.pairingID }
  var expectedPeerID: UUID? { credential?.expectedPeer?.deviceID }

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
  private var locallyConfirmed = false
  private var remotelyConfirmed = false
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
  private var shouldReadJournal = false
  private var offeredCursor: UInt64 = 0
  private var offeredChanges: [NotebookDurableChange] = []
  private var incomingChanges: [NotebookDurableChange] = []
  private var lastIncomingOffer: UInt64 = 0
  private var requestedBlob: (hash: String, offset: Int64)?
  private var commitAcknowledgements: [(UUID, UInt64)] = []

  init(connection: NWConnection, identity: NotebookTransportIdentity, credential: NotebookPeerCredential?,
    storage: NotebookTransportStorage, stagingRoot: URL, queue: DispatchQueue) throws {
    self.connection = connection; self.identity = identity; self.credential = credential
    self.storage = storage; self.queue = queue
    assembly = try NotebookTransportBlobAssembly(stagingRoot: stagingRoot, generation: generation)
    if let credential {
      localHello = .init(identity: identity, pairingID: credential.pairingID, credential: credential.kind,
        nonce: try NotebookTransportTLS.randomBytes(count: 32))
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

  func stop(_ error: Error? = nil) {
    guard !isStopped else { return }
    isStopped = true; isReady = false
    receiveTask?.cancel(); timeoutTask?.cancel(); readyTask?.cancel(); offerTask?.cancel()
    incomingTask?.cancel(); servingBlobTask?.cancel(); acknowledgingTask?.cancel()
    receiveTask = nil; timeoutTask = nil; readyTask = nil; offerTask = nil
    incomingTask = nil; servingBlobTask = nil; acknowledgingTask = nil
    outgoing = NotebookTransportOutgoing(); incomingChanges.removeAll(); offeredChanges.removeAll(); commitAcknowledgements.removeAll()
    connection.stateUpdateHandler = nil; connection.cancel()
    let assembly = assembly; Task { await assembly.cancel() }
    onStop?(peerIdentity, error)
    resolveCredential = nil; onAuthenticated = nil; onConfirmation = nil; onReady = nil; onTransient = nil; onDurableChange = nil; onStop = nil
  }

  func confirmPairing() throws {
    guard !isStopped, authenticated, let peerIdentity, let credential, let transcript else {
      throw NotebookTransportError.authenticationRequired
    }
    guard !locallyConfirmed else { return }
    try onConfirmation?(peerIdentity, credential.pairingID, true)
    locallyConfirmed = true
    enqueue(.confirm(NotebookTransportAuthentication.confirmation(secret: credential.secret, transcript: transcript, sender: identity.deviceID)))
    prepareReady()
  }

  func sendTransient(_ value: NotebookTransportTransient) {
    guard isReady, !isStopped, value.isValid(from: identity) else { return }
    enqueue(.transient(value))
  }

  func notifyDurableChanges() {
    guard isReady, !isStopped else { return }
    shouldReadJournal = true
    guard offerTask == nil, offeredChanges.count < 16 else { return }
    offerTask = Task { [weak self] in
      guard let self else { return }
      do {
        while self.shouldReadJournal, !self.isStopped, self.offeredChanges.count < 16 {
          self.shouldReadJournal = false
          let capacity = 16 - self.offeredChanges.count
          let cursor = self.offeredCursor
          let changes = try await self.storage.changes(cursor, capacity)
          guard !self.isStopped, !Task.isCancelled else { return }
          guard changes.count <= capacity else { throw NotebookTransportError.resourceLimit }
          for change in changes {
            try Self.validate(change)
            guard change.sequence > self.offeredCursor else { throw NotebookTransportError.invalidSequence }
            self.offeredCursor = change.sequence; self.offeredChanges.append(change); self.enqueue(.offer(change))
          }
          // A full journal page is resumed by durable ACK, never by polling.
        }
        self.offerTask = nil
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
        try receive(packet)
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
  func receive(_ packet: NotebookTransportPacket) throws {
    guard !isStopped, isTLSReady else { throw NotebookTransportError.authenticationRequired }
    guard packet.version == NotebookTransportLimits.protocolVersion,
      (packet.sequence == 0) == packet.message.isControl else { throw NotebookTransportError.invalidFrame }
    if !packet.message.isControl {
      guard isReady else { throw NotebookTransportError.authenticationRequired }
      try incoming.accept(packet.sequence)
    }
    switch packet.message {
    case .hello(let hello): try receiveHello(hello)
    case .proof(let proof): try receiveProof(proof)
    case .confirm(let proof):
      guard authenticated, !remotelyConfirmed, let transcript, let credential, let peerIdentity,
        NotebookTransportAuthentication.verifiesConfirmation(proof, secret: credential.secret, transcript: transcript, sender: peerIdentity.deviceID)
      else { throw NotebookTransportError.authenticationRequired }
      try onConfirmation?(peerIdentity, credential.pairingID, false)
      remotelyConfirmed = true; prepareReady()
    case .ready(let cursor):
      guard authenticated, locallyConfirmed, remotelyConfirmed, remoteCursor == nil, cursor <= UInt64(Int64.max) else {
        throw NotebookTransportError.authenticationRequired
      }
      remoteCursor = cursor; offeredCursor = cursor; becomeReady()
    case .credit(let values):
      guard isReady else { throw NotebookTransportError.authenticationRequired }
      try outgoing.acknowledge(values); pump()
    default:
      guard isReady, let peerIdentity else { throw NotebookTransportError.authenticationRequired }
      switch packet.message {
      case .transient(let value):
        guard value.isValid(from: peerIdentity) else { throw NotebookTransportError.identityMismatch }
        onTransient?(value, peerIdentity); try consumed(packet.sequence)
      case .offer(let change):
        try Self.validate(change)
        guard incomingChanges.count < 16, change.sequence > lastIncomingOffer else { throw NotebookTransportError.invalidSequence }
        lastIncomingOffer = change.sequence; incomingChanges.append(change)
        try consumed(packet.sequence); advanceIncomingChange()
      case .requestBlob(let hash, let offset): try serveBlob(hash: hash, offset: offset, frameSequence: packet.sequence)
      case .blob(let chunk): try receiveBlob(chunk, frameSequence: packet.sequence)
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
      localHello = .init(identity: identity, pairingID: resolved.pairingID, credential: resolved.kind, nonce: try NotebookTransportTLS.randomBytes(count: 32))
      enqueue(.hello(localHello!))
    }
    guard let credential, let localHello, hello.pairingID == credential.pairingID, hello.credential == credential.kind else {
      throw NotebookTransportError.authenticationRequired
    }
    if let expected = credential.expectedPeer {
      guard expected.deviceID == hello.identity.deviceID, expected.workspaceID == hello.identity.workspaceID else { throw NotebookTransportError.identityMismatch }
    }
    let transcript = try NotebookTransportAuthentication.transcript(localHello, hello)
    self.transcript = transcript; remoteHello = hello; peerIdentity = hello.identity
    enqueue(.proof(NotebookTransportAuthentication.proof(secret: credential.secret, transcript: transcript, sender: identity.deviceID)))
  }

  private func receiveProof(_ proof: Data) throws {
    guard !authenticated, let credential, let transcript, let peerIdentity,
      NotebookTransportAuthentication.verifies(proof, secret: credential.secret, transcript: transcript, sender: peerIdentity.deviceID)
    else { throw NotebookTransportError.authenticationRequired }
    let approved = try onAuthenticated?(peerIdentity, credential) ?? false
    authenticated = true; setTimeout(seconds: 600)
    if approved { try confirmPairing() }
  }

  private func prepareReady() {
    guard authenticated, locallyConfirmed, remotelyConfirmed, !sentReady, readyTask == nil, let peerIdentity else { return }
    readyTask = Task { [weak self] in
      guard let self else { return }
      do {
        let cursor = try await self.storage.incomingCursor(peerIdentity.deviceID)
        guard !self.isStopped, !Task.isCancelled else { return }
        guard cursor <= UInt64(Int64.max) else { throw NotebookTransportError.invalidSequence }
        self.lastIncomingOffer = cursor; self.sentReady = true; self.enqueue(.ready(cursor: cursor)); self.becomeReady()
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
    guard incomingTask == nil, requestedBlob == nil, !isStopped, let change = incomingChanges.first, let peerIdentity else { return }
    incomingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let missing = try await self.storage.missingBlobHashes(change, 16, nil)
        guard !self.isStopped, !Task.isCancelled else { return }
        guard missing.count <= 16, Set(missing).count == missing.count,
          missing.allSatisfy(NotebookTransportFraming.isSHA256) else { throw NotebookTransportError.invalidBlob }
        if let hash = missing.first {
          self.requestedBlob = (hash, 0); self.enqueue(.requestBlob(hash: hash, offset: 0))
        } else {
          // This await is the only durable receive boundary. A frame credit
          // never advertises that history or an incoming cursor was committed.
          let cursor = try await self.storage.applyRemoteChange(change, peerIdentity.deviceID)
          guard !self.isStopped, !Task.isCancelled else { return }
          guard cursor == change.sequence else { throw NotebookTransportError.invalidAcknowledgement }
          self.incomingChanges.removeFirst()
          self.enqueue(.committed(transactionID: change.transactionID, cursor: cursor))
          self.onDurableChange?(change, peerIdentity)
        }
        self.incomingTask = nil
        if self.requestedBlob == nil { self.advanceIncomingChange() }
      } catch { self.stop(error) }
    }
  }

  private func serveBlob(hash: String, offset: Int64, frameSequence: UInt64) throws {
    guard servingBlobTask == nil, NotebookTransportFraming.isSHA256(hash), offset >= 0 else { throw NotebookTransportError.unexpectedBlob }
    servingBlobTask = Task { [weak self] in
      guard let self else { return }
      do {
        let total = try await self.storage.blobSize(hash)
        guard total >= 0, total <= NotebookTransportLimits.maximumBlobBytes, offset <= total else { throw NotebookTransportError.blobTooLarge }
        let data = try await self.storage.readBlobChunk(hash, offset, NotebookTransportLimits.maximumChunkBytes)
        guard !self.isStopped, !Task.isCancelled else { return }
        guard data.count <= NotebookTransportLimits.maximumChunkBytes, Int64(data.count) <= total - offset,
          !data.isEmpty || total == 0 else { throw NotebookTransportError.invalidBlob }
        self.enqueue(.blob(.init(hash: hash, offset: offset, totalBytes: total, data: data)))
        try self.consumed(frameSequence); self.servingBlobTask = nil
      } catch { self.stop(error) }
    }
  }

  private func receiveBlob(_ chunk: NotebookTransportBlobChunk, frameSequence: UInt64) throws {
    guard incomingTask == nil, let request = requestedBlob, request.hash == chunk.hash, request.offset == chunk.offset,
      let change = incomingChanges.first else { throw NotebookTransportError.unexpectedBlob }
    requestedBlob = nil
    incomingTask = Task { [weak self] in
      guard let self else { return }
      do {
        let maximum = chunk.hash == change.manifestHash ? NotebookTransportLimits.maximumManifestBytes : NotebookTransportLimits.maximumBlobBytes
        if chunk.hash == change.manifestHash, chunk.totalBytes != Int64(change.byteCount) { throw NotebookTransportError.invalidBlob }
        let completed = try await self.assembly.append(chunk, expectedHash: request.hash, maximumBytes: maximum)
        guard !self.isStopped, !Task.isCancelled else { return }
        if let completed {
          try await self.storage.stageBlob(completed.file, completed.hash, completed.byteCount)
          try await self.assembly.discardCompleted(completed)
          guard !self.isStopped, !Task.isCancelled else { return }
        } else {
          self.requestedBlob = (chunk.hash, chunk.offset + Int64(chunk.data.count))
          self.enqueue(.requestBlob(hash: chunk.hash, offset: chunk.offset + Int64(chunk.data.count)))
        }
        try self.consumed(frameSequence); self.incomingTask = nil
        if completed != nil { self.advanceIncomingChange() }
      } catch { self.stop(error) }
    }
  }

  private func persistAcknowledgements() {
    guard acknowledgingTask == nil, let peerIdentity else { return }
    acknowledgingTask = Task { [weak self] in
      guard let self else { return }
      do {
        while !self.isStopped, let (transactionID, cursor) = self.commitAcknowledgements.first {
          guard let first = self.offeredChanges.first, first.transactionID == transactionID, first.sequence == cursor else {
            throw NotebookTransportError.invalidAcknowledgement
          }
          try await self.storage.acknowledgePeer(peerIdentity.deviceID, cursor)
          guard !self.isStopped, !Task.isCancelled else { return }
          self.commitAcknowledgements.removeFirst(); self.offeredChanges.removeFirst(); self.notifyDurableChanges()
        }
        self.acknowledgingTask = nil
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
          if let error { self.stop(error) } else { self.pump() }
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
