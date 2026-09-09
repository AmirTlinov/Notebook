import CryptoKit
import Foundation

/// The transport has no durable content owner. A completed frame grants only
/// transfer credit; a committed change acknowledges the store's SQL transaction.
public enum NotebookTransportLimits {
  public static let protocolVersion = 1
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
  case identityMismatch, invalidPairingInvitation, pairingExpired, pairingRejected
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

/// The 128-bit secret is carried by an explicit invitation, never advertised
/// through Bonjour. A short numeric password is not a TLS PSK.
public struct NotebookPairingInvitation: Codable, Equatable, Sendable {
  public let version: Int
  public let id: UUID
  public let inviter: NotebookTransportIdentity
  public let secret: Data
  public let expiresAt: Date

  public init(id: UUID = UUID(), inviter: NotebookTransportIdentity, secret: Data, expiresAt: Date) throws {
    guard inviter.isValid, secret.count == 16, expiresAt.timeIntervalSince1970.isFinite else {
      throw NotebookTransportError.invalidPairingInvitation
    }
    version = NotebookTransportLimits.protocolVersion
    self.id = id; self.inviter = inviter; self.secret = secret; self.expiresAt = expiresAt
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return "notebook-pair:v1:" + (try encoder.encode(self)).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ text: String, now: Date = Date()) throws -> Self {
    let prefix = "notebook-pair:v1:"
    guard text.utf8.count <= 2_048, text.hasPrefix(prefix) else { throw NotebookTransportError.invalidPairingInvitation }
    var encoded = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded), let invitation = try? JSONDecoder().decode(Self.self, from: data),
      invitation.version == NotebookTransportLimits.protocolVersion,
      invitation.secret.count == 16, invitation.inviter.isValid,
      invitation.expiresAt.timeIntervalSince1970.isFinite
    else { throw NotebookTransportError.invalidPairingInvitation }
    guard invitation.expiresAt > now, invitation.expiresAt.timeIntervalSince(now) <= 600 else {
      throw NotebookTransportError.pairingExpired
    }
    return invitation
  }
}

public enum NotebookTransportTransient: Codable, Equatable, Sendable {
  case presence(PresenceEnvelope)
  case inputActivity(NotebookInputActivity)
  case documentPageSelection(DocumentPageSelectionRequest)

  public func isValid(from identity: NotebookTransportIdentity) -> Bool {
    switch self {
    case .presence(let value): value.isValid
    case .inputActivity(let value): value.isValid && value.deviceID == identity.deviceID
    case .documentPageSelection(let value): value.isValid
    }
  }

  public var priority: Int {
    switch self {
    case .inputActivity: 0
    case .presence: 1
    case .documentPageSelection: 2
    }
  }
}

public struct NotebookTransportHello: Codable, Equatable, Sendable {
  public enum Credential: String, Codable, Sendable { case invitation, paired }
  public let identity: NotebookTransportIdentity
  public let pairingID: UUID
  public let credential: Credential
  public let nonce: Data
  public init(identity: NotebookTransportIdentity, pairingID: UUID, credential: Credential, nonce: Data) {
    self.identity = identity; self.pairingID = pairingID; self.credential = credential; self.nonce = nonce
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

public enum NotebookTransportMessage: Codable, Equatable, Sendable {
  case hello(NotebookTransportHello)
  case proof(Data)
  case confirm(Data)
  case ready(cursor: UInt64)
  case credit([UInt64])
  case offer(NotebookDurableChange)
  case requestBlob(hash: String, offset: Int64)
  case blob(NotebookTransportBlobChunk)
  case committed(transactionID: UUID, cursor: UInt64)
  case transient(NotebookTransportTransient)

  public var isControl: Bool {
    switch self {
    case .hello, .proof, .confirm, .ready, .credit, .committed: true
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
      first.pairingID == second.pairingID,
      first.credential == second.credential,
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
  public static func confirmation(secret: Data, transcript: Data, sender: UUID) -> Data {
    proof(secret: secret, transcript: Data("Notebook human confirmation v1\0".utf8) + transcript, sender: sender)
  }
  public static func verifiesConfirmation(_ value: Data, secret: Data, transcript: Data, sender: UUID) -> Bool {
    verifies(value, secret: secret, transcript: Data("Notebook human confirmation v1\0".utf8) + transcript, sender: sender)
  }
  public static func pairedSecret(invitation: NotebookPairingInvitation, joiner: NotebookTransportIdentity) throws -> Data {
    guard invitation.inviter.workspaceID == joiner.workspaceID,
      invitation.inviter.deviceID != joiner.deviceID else { throw NotebookTransportError.identityMismatch }
    let context = "Notebook trusted pair v1:\(invitation.id):\(invitation.inviter.deviceID):\(joiner.deviceID):\(joiner.workspaceID)"
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: invitation.secret),
      salt: Data(invitation.id.uuidString.utf8), info: Data(context.utf8), outputByteCount: 32)
    return key.withUnsafeBytes { Data($0) }
  }
}

/// There are three replaceable transient slots, sixteen durable offers, and
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

public enum NotebookPairingState: Equatable, Sendable {
  case idle
  case invitation(NotebookPairingInvitation)
  case connecting
  case confirmation(peer: NotebookTransportIdentity, generation: UUID, locallyConfirmed: Bool)
  case paired(NotebookTransportIdentity)
  case failed(String)
}
