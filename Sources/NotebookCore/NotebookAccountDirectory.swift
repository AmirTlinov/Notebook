import CryptoKit
import Foundation

/// This value is admitted only from the current account's PRIVATE CloudKit
/// database. Discovery names and network messages can never enroll a device.
public struct NotebookAccountDirectory: Codable, Equatable, Sendable {
  public enum Failure: Error, Equatable { case spaceDeleted, spaceMissing }
  public struct Space: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
  }

  public struct Device: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable { case mac, iPad }
    public let identity: NotebookTransportIdentity
    public let platform: Platform
    public let activation: UUID?
    public init(identity: NotebookTransportIdentity, platform: Platform, activation: UUID?) {
      self.identity = identity; self.platform = platform; self.activation = activation
    }
  }

  public struct Pair: Codable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let first: UUID
    public let second: UUID
    public let secret: Data
    public init(id: UUID, workspaceID: UUID, first: UUID, second: UUID, secret: Data) {
      self.id = id; self.workspaceID = workspaceID
      let ordered = [first, second].sorted { $0.uuidString < $1.uuidString }
      self.first = ordered[0]; self.second = ordered[1]; self.secret = secret
    }
    public func otherDevice(than id: UUID) -> UUID? { first == id ? second : second == id ? first : nil }
  }

  public let format: Int
  public private(set) var defaultSpaceID: UUID?
  public private(set) var spaces: [Space]
  public private(set) var deletedSpaceIDs: Set<UUID> = []
  public private(set) var devices: [Device] = []
  public private(set) var pairs: [Pair] = []

  public init(space: Space) {
    format = 2; defaultSpaceID = space.id; spaces = [space]
  }

  private enum CodingKeys: String, CodingKey { case format, defaultSpaceID, spaces, deletedSpaceIDs, devices, pairs }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let oldFormat = try values.decode(Int.self, forKey: .format)
    guard oldFormat == 1 || oldFormat == 2 else { throw NotebookTransportError.unsupportedVersion }
    format = 2
    defaultSpaceID = try values.decodeIfPresent(UUID.self, forKey: .defaultSpaceID)
    spaces = try values.decode([Space].self, forKey: .spaces)
    devices = try values.decode([Device].self, forKey: .devices)
    pairs = try values.decode([Pair].self, forKey: .pairs)
    deletedSpaceIDs = oldFormat == 1 ? [] : try values.decode(Set<UUID>.self, forKey: .deletedSpaceIDs)
    try validate()
  }

  public func validate() throws {
    guard format == 2, spaces.count <= 32, devices.count <= 64, pairs.count <= 224,
      deletedSpaceIDs.count <= 4096, Set(spaces.map(\.id)).isDisjoint(with: deletedSpaceIDs),
      Set(spaces.map(\.id)).count == spaces.count,
      spaces.isEmpty ? defaultSpaceID == nil : spaces.contains(where: { $0.id == defaultSpaceID }),
      spaces.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 240 }),
      devices.allSatisfy({ $0.identity.isValid }) else {
      throw NotebookTransportError.identityMismatch
    }
    var memberships: Set<String> = [], links: Set<String> = [], ids: Set<UUID> = []
    for device in devices {
      guard spaces.contains(where: { $0.id == device.identity.workspaceID }),
        memberships.insert("\(device.identity.workspaceID):\(device.identity.deviceID)").inserted,
        devices.filter({ $0.identity.workspaceID == device.identity.workspaceID }).count <= 8 else {
        throw NotebookTransportError.resourceLimit
      }
    }
    for pair in pairs {
      guard pair.first.uuidString < pair.second.uuidString, pair.secret.count == 32,
        spaces.contains(where: { $0.id == pair.workspaceID }), ids.insert(pair.id).inserted,
        links.insert("\(pair.workspaceID):\(pair.first):\(pair.second)").inserted else {
        throw NotebookTransportError.identityMismatch
      }
    }
  }

  /// CAS on the containing CloudKit record serializes enrollment. Existing
  /// credentials seed a previously unknown pair. After enrollment the private
  /// directory is authoritative: a stale device cannot restore a superseded
  /// key. A pair is usable only after BOTH account memberships exist.
  public mutating func enroll(_ device: Device, retained: [Pair], spaceName: String) throws {
    var candidate = self
    try candidate.applyEnrollment(device, retained: retained, spaceName: spaceName)
    self = candidate
  }

  private mutating func applyEnrollment(_ device: Device, retained: [Pair], spaceName: String) throws {
    try validate()
    guard device.identity.isValid, retained.count <= 8 else { throw NotebookTransportError.identityMismatch }
    let local = device.identity
    guard !deletedSpaceIDs.contains(local.workspaceID) else { throw Failure.spaceDeleted }
    if !spaces.contains(where: { $0.id == local.workspaceID }) {
      spaces.append(.init(id: local.workspaceID, name: spaceName))
      if defaultSpaceID == nil { defaultSpaceID = local.workspaceID }
    }
    if let index = devices.firstIndex(where: { $0.identity.deviceID == local.deviceID && $0.identity.workspaceID == local.workspaceID }) {
      if devices[index].activation != device.activation {
        pairs.removeAll { $0.workspaceID == local.workspaceID && $0.otherDevice(than: local.deviceID) != nil }
      }
      devices[index] = device
    } else { devices.append(device) }
    for pair in retained {
      guard pair.workspaceID == local.workspaceID, pair.otherDevice(than: local.deviceID) != nil,
        pair.secret.count == 32 else { throw NotebookTransportError.identityMismatch }
      if !pairs.contains(where: { $0.workspaceID == pair.workspaceID && $0.first == pair.first && $0.second == pair.second }) {
        pairs.append(pair)
      }
    }
    for peer in devices where peer.identity.workspaceID == local.workspaceID
      && peer.identity.deviceID != local.deviceID && peer.platform != device.platform {
      if !pairs.contains(where: { $0.workspaceID == local.workspaceID && $0.otherDevice(than: local.deviceID) == peer.identity.deviceID }) {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        pairs.append(.init(id: UUID(), workspaceID: local.workspaceID, first: local.deviceID,
          second: peer.identity.deviceID, secret: secret))
      }
    }
    try validate()
  }

  public mutating func renameSpace(_ id: UUID, name: String) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 240 else { throw NotebookTransportError.identityMismatch }
    guard let index = spaces.firstIndex(where: { $0.id == id }) else { throw Failure.spaceMissing }
    spaces[index] = .init(id: id, name: name)
  }

  /// The deletion is account authority, not a missing record. A device coming
  /// back from offline cannot enroll the retired UUID or restore its pair keys.
  public mutating func deleteSpace(_ id: UUID) throws {
    guard spaces.contains(where: { $0.id == id }) || deletedSpaceIDs.contains(id) else { throw Failure.spaceMissing }
    var next = self
    next.deletedSpaceIDs.insert(id)
    next.spaces.removeAll { $0.id == id }
    next.devices.removeAll { $0.identity.workspaceID == id }
    next.pairs.removeAll { $0.workspaceID == id }
    if next.defaultSpaceID == id { next.defaultSpaceID = next.spaces.first?.id }
    try next.validate(); self = next
  }

  public func credentials(for device: Device) -> [(Device, Pair)] {
    guard devices.contains(device) else { return [] }
    return devices.compactMap { peer in
      guard peer.identity.workspaceID == device.identity.workspaceID, peer.platform != device.platform,
        let pair = pairs.first(where: { $0.workspaceID == device.identity.workspaceID
          && $0.otherDevice(than: device.identity.deviceID) == peer.identity.deviceID }) else { return nil }
      return (peer, pair)
    }
  }
}
