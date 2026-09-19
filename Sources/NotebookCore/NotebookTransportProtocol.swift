import CryptoKit
import Foundation

/// The transport has no durable content owner. A completed frame grants only
/// transfer credit; a committed change acknowledges the store's SQL transaction.
public enum NotebookTransportLimits {
  // Native Bézier contours and mixed item/element selections have one vocabulary.
  // Both applications update together; identities and queued history stay intact.
  public static let protocolVersion = 31
  public static let maximumFrameBytes = 256 * 1_024
  public static let maximumChunkBytes = 180 * 1_024
  public static let maximumUnacknowledgedFrames = 16
  public static let maximumPendingChanges = 16
  public static let maximumBlobBytes: Int64 = 256 * 1_024 * 1_024
  public static let maximumManifestBytes: Int64 = 64 * 1_024 * 1_024
  public static let maximumConnections = 8
}

public enum NotebookTransportError: Error, Equatable, Sendable {
  case invalidFrame, frameTooLarge, unsupportedVersion, authenticationRequired
  case identityMismatch
  case invalidSequence, backpressure, invalidBlob, blobTooLarge, unexpectedBlob
  case disconnected, storageUnavailable, invalidAcknowledgement, resourceLimit
}

public struct NotebookTransportIdentity: Codable, Equatable, Hashable, Sendable {
  public let deviceID: UUID
  public let workspaceID: UUID
  public let displayName: String

  public init(deviceID: UUID, workspaceID: UUID, displayName: String) {
    self.deviceID = deviceID; self.workspaceID = workspaceID; self.displayName = displayName
  }
  public var isValid: Bool { !displayName.isEmpty && displayName.utf8.count <= 120 }
}

public enum NotebookTransportTransient: Codable, Equatable, Sendable {
  case presence(PresenceEnvelope)
  case selection(NotebookSelectionEnvelope)
  case inputActivity(NotebookInputActivity)
  case codex(NotebookChatEnvelope)
  case presentation(NotebookPresentationMessage)

  public func isValid(from identity: NotebookTransportIdentity) -> Bool {
    switch self {
    case .presence(let value): value.isValid
    case .selection(let value): value.isValid && value.deviceID == identity.deviceID
    case .inputActivity(let value): value.isValid && value.deviceID == identity.deviceID
    case .codex(let value): value.isValid(from: identity.deviceID)
    case .presentation(let value): value.isValid
    }
  }

  public var priority: Int {
    switch self {
    case .inputActivity: 0
    case .presence: 1
    case .codex(let envelope):
      if case .event = envelope.body { 4 } else { 3 }
    case .presentation: 5
    case .selection: 6
    }
  }
}

public struct NotebookTransportHello: Codable, Equatable, Sendable {
  public let identity: NotebookTransportIdentity
  public let credentialID: UUID
  public let nonce: Data
  public let journalGeneration: UUID
  public init(identity: NotebookTransportIdentity, credentialID: UUID, nonce: Data, journalGeneration: UUID? = nil) {
    self.identity = identity; self.credentialID = credentialID; self.nonce = nonce
    self.journalGeneration = journalGeneration ?? identity.deviceID
  }
}

public struct NotebookTransportBlobChunk: Codable, Equatable, Sendable {
  public let hash: String
  public let offset: Int64
  public let totalBytes: Int64
  public let data: Data
  public init(hash: String, offset: Int64, totalBytes: Int64, data: Data) {
    self.hash = hash; self.offset = offset; self.totalBytes = totalBytes; self.data = data
  }
}

public enum NotebookTransportContentRequirement: String, Codable, Equatable, Sendable {
  case peerUpgrade, checkpoint

  public init?(error: Error) {
    guard let error = error as? CollaborationError else { return nil }
    switch error.code {
    case "placement_peer_upgrade_required": self = .peerUpgrade
    case "placement_checkpoint_required": self = .checkpoint
    default: return nil
    }
  }
  public var error: CollaborationError {
    switch self {
    case .peerUpgrade:
      CollaborationError("placement_peer_upgrade_required", "Обновите Notebook на обоих устройствах. Прежние изменения не подтверждены и не будут пропущены.")
    case .checkpoint:
      CollaborationError("placement_checkpoint_required", "Для продолжения обмена отстающему устройству нужна текущая исходная копия пространства. Существующее содержание и сопряжение сохранены.")
    }
  }
}

public enum NotebookTransportMessage: Codable, Equatable, Sendable {
  case hello(NotebookTransportHello)
  case proof(Data)
  case ready(cursor: UInt64)
  case credit([UInt64])
  case offer(NotebookDurableChange)
  case requestBlob(hash: String, offset: Int64)
  case blob(NotebookTransportBlobChunk)
  case committed(transactionID: UUID, cursor: UInt64)
  case contentUnavailable(NotebookTransportContentRequirement)
  case transient(NotebookTransportTransient)

  public var isControl: Bool {
    switch self {
    case .hello, .proof, .ready, .credit, .committed, .contentUnavailable: true
    default: false
    }
  }
}

public struct NotebookTransportPacket: Codable, Equatable, Sendable {
  public let version: Int
  public let sequence: UInt64
  public let message: NotebookTransportMessage
  public init(sequence: UInt64, message: NotebookTransportMessage) {
    version = NotebookTransportLimits.protocolVersion; self.sequence = sequence; self.message = message
  }
}

public enum NotebookTransportFraming {
  public static func encode(_ packet: NotebookTransportPacket) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(packet)
    guard !payload.isEmpty, payload.count <= NotebookTransportLimits.maximumFrameBytes - 4 else {
      throw NotebookTransportError.frameTooLarge
    }
    var length = UInt32(payload.count).bigEndian
    var result = withUnsafeBytes(of: &length) { Data($0) }; result.append(payload)
    return result
  }

  /// Validate the prefix before asking Network.framework to allocate the body.
  public static func payloadLength(_ prefix: Data) throws -> Int {
    guard prefix.count == 4 else { throw NotebookTransportError.invalidFrame }
    let length = prefix.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    guard length > 0, length <= NotebookTransportLimits.maximumFrameBytes - 4 else {
      throw NotebookTransportError.frameTooLarge
    }
    return Int(length)
  }

  public static func decode(_ payload: Data) throws -> NotebookTransportPacket {
    guard !payload.isEmpty, payload.count <= NotebookTransportLimits.maximumFrameBytes - 4 else {
      throw NotebookTransportError.frameTooLarge
    }
    let packet: NotebookTransportPacket
    do { packet = try JSONDecoder().decode(NotebookTransportPacket.self, from: payload) }
    catch { throw NotebookTransportError.invalidFrame }
    guard packet.version == NotebookTransportLimits.protocolVersion else { throw NotebookTransportError.unsupportedVersion }
    guard (packet.sequence == 0) == packet.message.isControl else { throw NotebookTransportError.invalidSequence }
    return packet
  }

  public static func isSHA256(_ hash: String) -> Bool {
    hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

public struct NotebookTransportSendWindow: Sendable {
  public private(set) var lastSequence: UInt64 = 0
  public private(set) var unacknowledged: Set<UInt64> = []
  public init() {}
  public var hasCapacity: Bool { unacknowledged.count < NotebookTransportLimits.maximumUnacknowledgedFrames }
  public mutating func reserve() throws -> UInt64 {
    guard hasCapacity else { throw NotebookTransportError.backpressure }
    guard lastSequence < UInt64.max else { throw NotebookTransportError.invalidSequence }
    lastSequence += 1; unacknowledged.insert(lastSequence); return lastSequence
  }
  public mutating func acknowledge(_ sequences: [UInt64]) throws {
    guard !sequences.isEmpty, sequences.count <= NotebookTransportLimits.maximumUnacknowledgedFrames,
      Set(sequences).count == sequences.count,
      sequences.allSatisfy({ $0 > 0 && $0 <= lastSequence })
    else { throw NotebookTransportError.invalidAcknowledgement }
    for sequence in sequences { unacknowledged.remove(sequence) }
  }
}

/// Receiving credit is bounded independently from SQL commit latency. A sender
/// cannot hide an unbounded disk queue behind a stream of camera updates.
public struct NotebookTransportReceiveWindow: Sendable {
  private var lastSequence: UInt64 = 0
  public private(set) var pending: Set<UInt64> = []
  public init() {}
  public mutating func accept(_ sequence: UInt64) throws {
    guard lastSequence < UInt64.max, sequence == lastSequence + 1,
      pending.count < NotebookTransportLimits.maximumUnacknowledgedFrames else {
      throw NotebookTransportError.invalidSequence
    }
    lastSequence = sequence; pending.insert(sequence)
  }
  public mutating func consumed(_ sequence: UInt64) throws {
    guard pending.remove(sequence) != nil else { throw NotebookTransportError.invalidSequence }
  }
}

/// Cryptographic operations are the system CryptoKit HKDF and HMAC primitives.
/// TLS still owns encryption and server/client PSK authentication. This proof
/// binds the claimed device and workspace to the particular configured PSK.
public enum NotebookTransportAuthentication {
  public static func transcript(_ first: NotebookTransportHello, _ second: NotebookTransportHello) throws -> Data {
    guard first.identity.isValid, second.identity.isValid,
      first.identity.deviceID != second.identity.deviceID,
      first.identity.workspaceID == second.identity.workspaceID,
      first.credentialID == second.credentialID,
      first.nonce.count == 32, second.nonce.count == 32, first.nonce != second.nonce
    else { throw NotebookTransportError.identityMismatch }
    let ordered = [first, second].sorted { $0.identity.deviceID.uuidString < $1.identity.deviceID.uuidString }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return Data("Notebook TLS device proof v1\0".utf8) + (try encoder.encode(ordered))
  }
  public static func proof(secret: Data, transcript: Data, sender: UUID) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: transcript + Data(sender.uuidString.utf8), using: SymmetricKey(data: secret)))
  }
  public static func verifies(_ proof: Data, secret: Data, transcript: Data, sender: UUID) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript + Data(sender.uuidString.utf8), using: SymmetricKey(data: secret))
  }

}

/// Each transient priority has one replaceable slot, beside sixteen durable offers and
/// two outstanding blob-control/data slots. Bulk never consumes the last two
/// transfer credits reserved for contact and camera. Credit is not a SQL ACK.
public struct NotebookTransportOutgoing: Sendable {
  private var controls: [NotebookTransportMessage] = []
  private var credits: Set<UInt64> = []
  private var transients: [Int: NotebookTransportTransient] = [:]
  private var offers: [NotebookTransportMessage] = []
  private var blobs: [NotebookTransportMessage] = []
  private var requests: [NotebookTransportMessage] = []
  public private(set) var window = NotebookTransportSendWindow()
  public init() {}
  public var pendingCount: Int { controls.count + (credits.isEmpty ? 0 : 1) + transients.count + offers.count + blobs.count + requests.count }

  public mutating func enqueue(_ message: NotebookTransportMessage) throws {
    switch message {
    case .credit(let values):
      guard !values.isEmpty, values.count <= 16, values.allSatisfy({ $0 > 0 }) else { throw NotebookTransportError.invalidAcknowledgement }
      credits.formUnion(values)
      guard credits.count <= 16 else { throw NotebookTransportError.backpressure }
    case .transient(let transient): transients[transient.priority] = transient
    case .offer:
      guard offers.count < 16 else { throw NotebookTransportError.backpressure }; offers.append(message)
    case .blob:
      guard blobs.count < 2 else { throw NotebookTransportError.backpressure }; blobs.append(message)
    case .requestBlob:
      guard requests.count < 2 else { throw NotebookTransportError.backpressure }; requests.append(message)
    default:
      guard message.isControl, controls.count < 20 else { throw NotebookTransportError.backpressure }; controls.append(message)
    }
  }

  public mutating func acknowledge(_ sequences: [UInt64]) throws { try window.acknowledge(sequences) }

  public mutating func takeNext() throws -> NotebookTransportPacket? {
    if !credits.isEmpty {
      let values = credits.sorted(); credits.removeAll(keepingCapacity: true)
      return NotebookTransportPacket(sequence: 0, message: .credit(values))
    }
    if !controls.isEmpty { return NotebookTransportPacket(sequence: 0, message: controls.removeFirst()) }
    guard window.hasCapacity else { return nil }
    if let priority = transients.keys.min(), let transient = transients.removeValue(forKey: priority) {
      return NotebookTransportPacket(sequence: try window.reserve(), message: .transient(transient))
    }
    guard window.unacknowledged.count < NotebookTransportLimits.maximumUnacknowledgedFrames - 2 else { return nil }
    let message: NotebookTransportMessage
    if !requests.isEmpty { message = requests.removeFirst() }
    else if !blobs.isEmpty { message = blobs.removeFirst() }
    else if !offers.isEmpty { message = offers.removeFirst() }
    else { return nil }
    return NotebookTransportPacket(sequence: try window.reserve(), message: message)
  }
}

public enum NotebookConnectionState: Equatable, Sendable {
  case waiting
  case connecting
  case connected(NotebookTransportIdentity)
  case failed(String)
}
