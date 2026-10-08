import CryptoKit
import Foundation
import NotebookCore

/// A directory observation keeps its actual local owners until the following
/// SQL read returns. Its validator never fetches or enrolls another directory.
@MainActor
struct NotebookHistoryFleetWitness {
  let observation: NotebookHistoryFleetObservation
  private let validate: @MainActor () throws -> Void

  init(observation: NotebookHistoryFleetObservation,
    validate: @escaping @MainActor () throws -> Void) {
    self.observation = observation; self.validate = validate
  }

  func requireCurrent() throws { try validate() }
}

/// Enrollment and saved credentials are distinct evidence. Blocked and
/// trust-only endpoints remain visible; a network discovery never enrolls one.
struct NotebookHistoryFleetObservation: Codable, Equatable, Sendable {
  struct Credential: Codable, Equatable, Sendable {
    let id: UUID
    let first: UUID
    let second: UUID
    let scopeHash: String

    init(id: UUID, workspaceID: UUID, first: UUID, second: UUID, secret: Data) {
      self.id = id
      let devices = [first, second].sorted { $0.uuidString < $1.uuidString }
      self.first = devices[0]; self.second = devices[1]
      var hash = SHA256()
      hash.update(data: Data("Notebook.history.credential.v1\u{0}".utf8))
      for value in [workspaceID, id, devices[0], devices[1]] {
        hash.update(data: Data(value.uuidString.lowercased().utf8))
      }
      hash.update(data: secret)
      scopeHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }

  enum DirectoryStatus: String, Codable, Sendable { case verified, missing, unavailable }
  let local: NotebookTransportIdentity
  let accountScopeHash: String?
  let directoryAccountScopeHash: String?
  let directoryStatus: DirectoryStatus
  let workspaceEnrolled: Bool
  let workspaceDeleted: Bool
  let directoryDevices: [NotebookAccountDirectory.Device]
  let directoryCredentials: [Credential]
  let savedCredentials: [Credential]
  let blockedDevices: [UUID]
  let configuredRelayDevices: [UUID]
  /// A configured local suppression remains evidence, not mutual retirement.
  let locallyRetiredDevices: [UUID]
  let connections: [NotebookHistoryConnectionObservation]

  init(local: NotebookTransportIdentity, trust: NotebookDeviceTrustState,
    directory: NotebookAccountSnapshot?, directoryStatus: DirectoryStatus,
    locallyRetired: Set<UUID>, connections: [NotebookHistoryConnectionObservation]) throws {
    try trust.validate(for: local)
    if let directory {
      try directory.directory.validate()
    }
    guard (directoryStatus == .verified) == (directory != nil),
      connections.count <= NotebookTransportLimits.maximumConnections, locallyRetired.count <= 64 else {
      throw NotebookTransportError.resourceLimit
    }
    self.local = local
    accountScopeHash = trust.account.map(Self.accountScope)
    directoryAccountScopeHash = directory.map { Self.accountScope($0.account) }
    self.directoryStatus = directoryStatus
    workspaceEnrolled = directory?.directory.spaces.contains { $0.id == local.workspaceID } == true
    workspaceDeleted = directory?.directory.deletedSpaceIDs.contains(local.workspaceID) == true
    directoryDevices = (directory?.directory.devices ?? [])
      .filter { $0.identity.workspaceID == local.workspaceID }
      .sorted { $0.identity.deviceID.uuidString < $1.identity.deviceID.uuidString }
    directoryCredentials = (directory?.directory.pairs ?? [])
      .filter { $0.workspaceID == local.workspaceID }
      .map { Credential(id: $0.id, workspaceID: local.workspaceID,
        first: $0.first, second: $0.second, secret: $0.secret) }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    savedCredentials = trust.records.map {
      Credential(id: $0.credentialID, workspaceID: local.workspaceID,
        first: local.deviceID, second: $0.identity.deviceID, secret: $0.secret)
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    blockedDevices = trust.blocked.sorted { $0.uuidString < $1.uuidString }
    configuredRelayDevices = Set(trust.relays?.keys.map { $0 } ?? [])
      .union(trust.relayClients?.keys.map { $0 } ?? []).sorted { $0.uuidString < $1.uuidString }
    locallyRetiredDevices = locallyRetired.sorted { $0.uuidString < $1.uuidString }
    self.connections = connections.sorted { $0.connectionID.uuidString < $1.connectionID.uuidString }
  }

  static func accountScope(_ account: String) -> String {
    SHA256.hash(data: Data(("Notebook.history.account.v1\u{0}" + account).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  var observedDeviceIDs: Set<UUID> {
    Set(directoryDevices.map { $0.identity.deviceID })
      .union(savedCredentials.flatMap { [$0.first, $0.second] })
      .union(directoryCredentials.flatMap { [$0.first, $0.second] })
      .union(blockedDevices).union(locallyRetiredDevices).union(configuredRelayDevices)
      .union(connections.compactMap { $0.peer?.deviceID })
      .union([local.deviceID])
  }

  func projection() throws -> JSONValue {
    var fields = try JSONValue.encode(self).objectFields
    fields["connections"] = .array(try connections.map { connection in
      var value = try JSONValue.encode(connection).objectFields
      value["offeredThrough"] = .string(String(connection.offeredThrough))
      value["lastIncomingOffer"] = .string(String(connection.lastIncomingOffer))
      if let cursor = connection.initialPeerAcceptedThrough {
        value["initialPeerAcceptedThrough"] = .string(String(cursor))
      }
      return .object(value)
    })
    fields["observedDeviceIDs"] = .array(observedDeviceIDs.sorted { $0.uuidString < $1.uuidString }
      .map { .string($0.uuidString) })
    return .object(fields)
  }
}

/// Counters describe the actual selected TLS generation before its callbacks
/// are joined. A ready socket does not certify an unoffered remote journal tail.
struct NotebookHistoryConnectionObservation: Codable, Equatable, Sendable {
  let connectionID: UUID
  let peer: NotebookTransportIdentity?
  let credentialID: UUID?
  let selected: Bool
  let ready: Bool
  let localJournalGeneration: UUID?
  let remoteJournalGeneration: UUID?
  let offeredThrough: UInt64
  let lastIncomingOffer: UInt64
  let initialPeerAcceptedThrough: UInt64?
  let pendingOffers: Int
  let pendingIncoming: Int
  let pendingAcknowledgements: Int
  let pendingBlobRequests: Int
  let hasStorageCallback: Bool
}
