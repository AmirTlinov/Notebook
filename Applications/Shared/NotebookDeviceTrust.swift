import Foundation
import NotebookCore
import Security

struct NotebookTrustedDevice: Codable, Equatable, Sendable {
  let identity: NotebookTransportIdentity
  let credentialID: UUID
  let secret: Data
  // This is the existing on-disk key name, not an alternate protocol.
  private enum CodingKeys: String, CodingKey { case identity, credentialID = "pairingID", secret }
  var tlsKey: NotebookTransportTLS.Key { .init(identity: "device:\(credentialID)", secret: secret) }
}

struct NotebookDeviceTrustState: Codable, Equatable, Sendable {
  var format = 2
  var account: String?
  var records: [NotebookTrustedDevice] = []
  var blocked: Set<UUID> = []
  var relays: [UUID: NotebookRelayRoute]?
  var relayClients: [UUID: NotebookRelayRoute]?

  init(account: String? = nil, records: [NotebookTrustedDevice] = [], blocked: Set<UUID> = []) {
    self.account = account; self.records = records; self.blocked = blocked
  }

  private enum CodingKeys: String, CodingKey { case format, account, records, blocked, relays, relayClients }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .format)
    guard version == 1 || version == 2 else { throw NotebookTransportError.unsupportedVersion }
    relays = try values.decodeIfPresent([UUID: NotebookRelayRoute].self, forKey: .relays)
    relayClients = try values.decodeIfPresent([UUID: NotebookRelayRoute].self, forKey: .relayClients)
    account = try values.decodeIfPresent(String.self, forKey: .account)
    blocked = try values.decodeIfPresent(Set<UUID>.self, forKey: .blocked) ?? []
    if version == 1 {
      // One-way data upgrade preserves established keys but NEVER promotes an
      // unfinished old approval. There is no old enrollment execution path.
      struct Established: Decodable {
        let identity: NotebookTransportIdentity
        let pairingID: UUID
        let secret: Data
        let locallyConfirmed: Bool
        let remotelyConfirmed: Bool
      }
      records = try values.decode([Established].self, forKey: .records)
        .filter { $0.locallyConfirmed && $0.remotelyConfirmed }
        .map { .init(identity: $0.identity, credentialID: $0.pairingID, secret: $0.secret) }
    } else { records = try values.decode([NotebookTrustedDevice].self, forKey: .records) }
  }

  func validate(for identity: NotebookTransportIdentity) throws {
    guard format == 2, records.count <= 8, blocked.count <= 64,
      (relays?.count ?? 0) <= 8, (relayClients?.count ?? 0) <= 8,
      (relays?.values.allSatisfy(\.isValid) ?? true), (relayClients?.values.allSatisfy(\.isValid) ?? true),
      account.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
      Set(records.map { $0.identity.deviceID }).count == records.count,
      records.allSatisfy({ $0.identity.isValid && $0.identity.workspaceID == identity.workspaceID
        && $0.identity.deviceID != identity.deviceID && $0.secret.count == 32 }) else {
      throw NotebookTransportError.identityMismatch
    }
  }
}

protocol NotebookDeviceTrustStore: Sendable {
  func load(for identity: NotebookTransportIdentity) async throws -> NotebookDeviceTrustState
  func save(_ state: NotebookDeviceTrustState, for identity: NotebookTransportIdentity) async throws
}

/// The sole device-only Keychain owner. Account adoption and peer updates are
/// atomic, read back before publication, and scoped to the admitted activation.
actor NotebookKeychainDeviceStore: NotebookDeviceTrustStore {
  let activationID: UUID?
  private let service: String
  init(activationID: UUID? = nil, service: String? = nil) {
    self.activationID = activationID
    // Keep the installed item address: an application update must not lose keys.
    self.service = service ?? "com.amirtlinov.notebook.nearby.pair-v1"
  }
  private func query(_ identity: NotebookTransportIdentity) -> [String: Any] {
    let activation = activationID.map { ":activation:\($0.uuidString.lowercased())" } ?? ""
    return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "\(identity.deviceID):\(identity.workspaceID)\(activation)"]
  }
  func load(for identity: NotebookTransportIdentity) throws -> NotebookDeviceTrustState {
    var query = query(identity)
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return .init() }
    guard status == errSecSuccess, let data = result as? Data, data.count <= 32_768 else {
      throw NotebookTransportError.storageUnavailable
    }
    let state = try JSONDecoder().decode(NotebookDeviceTrustState.self, from: data)
    try state.validate(for: identity)
    return state
  }
  func save(_ state: NotebookDeviceTrustState, for identity: NotebookTransportIdentity) throws {
    try state.validate(for: identity)
    let query = query(identity), data = try JSONEncoder().encode(state)
    guard data.count <= 32_768 else { throw NotebookTransportError.resourceLimit }
    let values: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      guard SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil) == errSecSuccess else {
        throw NotebookTransportError.storageUnavailable
      }
    } else if status != errSecSuccess { throw NotebookTransportError.storageUnavailable }
    guard try load(for: identity) == state else { throw NotebookTransportError.storageUnavailable }
  }
}

struct NotebookPeerCredential {
  let credentialID: UUID
  let secret: Data
  let expectedPeer: NotebookTransportIdentity
  var tlsKey: NotebookTransportTLS.Key { .init(identity: "device:\(credentialID)", secret: secret) }
}
