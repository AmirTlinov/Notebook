import CryptoKit
import Foundation

/// This value is admitted only from the current account's PRIVATE CloudKit
/// database. Discovery names and network messages can never enroll a device.
public struct NotebookAccountDirectory: Codable, Equatable, Sendable {
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
  public let defaultSpaceID: UUID
  public private(set) var spaces: [Space]
  public private(set) var devices: [Device] = []
  public private(set) var pairs: [Pair] = []

  public init(space: Space) {
    format = 1; defaultSpaceID = space.id; spaces = [space]
  }

  public func validate() throws {
    guard format == 1, (1...32).contains(spaces.count), devices.count <= 64, pairs.count <= 224,
      Set(spaces.map(\.id)).count == spaces.count, spaces.contains(where: { $0.id == defaultSpaceID }),
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
    if !spaces.contains(where: { $0.id == local.workspaceID }) {
      spaces.append(.init(id: local.workspaceID, name: spaceName))
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
