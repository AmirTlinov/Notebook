import CryptoKit
import Foundation

/// The native owners first close authorship and drain while ordinary delivery
/// continues. No remote head is guessed from this preparation proposal.
public struct NotebookHistoryControlPreparation: Codable, Equatable, Sendable {
  public struct Endpoint: Codable, Equatable, Sendable {
    public let identity: NotebookTransportIdentity
    public let journalGeneration: UUID
    public init(identity: NotebookTransportIdentity, journalGeneration: UUID) {
      self.identity = identity; self.journalGeneration = journalGeneration
    }
  }
  public let requestID: UUID
  public let workspaceID: UUID
  public let credentialID: UUID
  public let applicationBuild: String
  public let databaseVersion: Int
  public let wireVersion: Int
  public let manifestVersion: Int
  public let endpoints: [Endpoint]
  public init(requestID: UUID, workspaceID: UUID, credentialID: UUID, applicationBuild: String,
    endpoints: [Endpoint]) {
    self.requestID = requestID; self.workspaceID = workspaceID; self.credentialID = credentialID
    self.applicationBuild = applicationBuild; databaseVersion = Int(NotebookStore.currentDatabaseVersion)
    wireVersion = NotebookTransportLimits.protocolVersion; manifestVersion = NotebookChangeManifest.currentFormat
    self.endpoints = endpoints.sorted { $0.identity.deviceID.uuidString < $1.identity.deviceID.uuidString }
  }
  public var isValid: Bool {
    !applicationBuild.isEmpty && applicationBuild.utf8.count <= 64 && endpoints.count == 2
      && endpoints[0].identity.deviceID.uuidString < endpoints[1].identity.deviceID.uuidString
      && endpoints.allSatisfy { $0.identity.isValid && $0.identity.workspaceID == workspaceID }
      && databaseVersion == Int(NotebookStore.currentDatabaseVersion)
      && wireVersion == NotebookTransportLimits.protocolVersion && manifestVersion == NotebookChangeManifest.currentFormat
  }
  public func endpoint(for deviceID: UUID) -> Endpoint? { endpoints.first { $0.identity.deviceID == deviceID } }
}

/// A request binds the already admitted pair and its two actual journal heads.
/// The transport checks committed prefixes; it does not establish a history seal.
public struct NotebookHistoryControlScope: Codable, Equatable, Sendable {
  public struct Endpoint: Codable, Equatable, Sendable {
    public let identity: NotebookTransportIdentity
    public let journalGeneration: UUID
    public let head: NotebookDurableChange?
    public var through: UInt64 { head?.sequence ?? 0 }
    public init(identity: NotebookTransportIdentity, journalGeneration: UUID, head: NotebookDurableChange?) {
      self.identity = identity; self.journalGeneration = journalGeneration; self.head = head
    }
  }
  public let requestID: UUID
  public let workspaceID: UUID
  public let credentialID: UUID
  public let applicationBuild: String
  public let databaseVersion: Int
  public let wireVersion: Int
  public let manifestVersion: Int
  public let endpoints: [Endpoint]

  public init(requestID: UUID, workspaceID: UUID, credentialID: UUID, applicationBuild: String,
    endpoints: [Endpoint]) {
    self.requestID = requestID; self.workspaceID = workspaceID; self.credentialID = credentialID
    self.applicationBuild = applicationBuild
    databaseVersion = Int(NotebookStore.currentDatabaseVersion)
    wireVersion = NotebookTransportLimits.protocolVersion; manifestVersion = NotebookChangeManifest.currentFormat
    self.endpoints = endpoints.sorted { $0.identity.deviceID.uuidString < $1.identity.deviceID.uuidString }
  }

  public var isValid: Bool {
    !applicationBuild.isEmpty && applicationBuild.utf8.count <= 64 && endpoints.count == 2
      && endpoints[0].identity.deviceID.uuidString < endpoints[1].identity.deviceID.uuidString
      && endpoints.allSatisfy { $0.identity.isValid && $0.identity.workspaceID == workspaceID
        && Self.validHead($0.head) }
      && databaseVersion == Int(NotebookStore.currentDatabaseVersion)
      && wireVersion == NotebookTransportLimits.protocolVersion && manifestVersion == NotebookChangeManifest.currentFormat
  }
  public func endpoint(for deviceID: UUID) -> Endpoint? { endpoints.first { $0.identity.deviceID == deviceID } }
  public var preparation: NotebookHistoryControlPreparation {
    .init(requestID: requestID, workspaceID: workspaceID, credentialID: credentialID, applicationBuild: applicationBuild,
      endpoints: endpoints.map { .init(identity: $0.identity, journalGeneration: $0.journalGeneration) })
  }
  static func validHead(_ head: NotebookDurableChange?) -> Bool {
    guard let head else { return true }
    return head.sequence > 0 && head.sequence <= UInt64(Int64.max)
      && NotebookTransportFraming.isSHA256(head.manifestHash) && head.byteCount > 0
      && Int64(head.byteCount) <= NotebookTransportLimits.maximumManifestBytes
  }
}

/// Only hashes, UUIDs and scalar counts cross this lane. These messages never
/// authorize birth, authorship, restoration, retirement, or a storage callback.
public enum NotebookHistoryControl: Codable, Equatable, Sendable {
  public enum Stream: String, Codable, Sendable {
    case acceptedTransactions, physicalClosures, sourceOriginalRoots, replicaInventory, replicaControl, fleet
  }
  public enum StaleReason: String, Codable, Sendable {
    case lateContent, changedPrefix, connectionChanged, admissionChanged, cancelled
  }
  /// The first terminal refusal travels in the existing ordered resume lane.
  /// Only finite classifications and actual metadata identities are representable.
  public struct Refusal: Error, Codable, Equatable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
      case cancelled, staleCut, resourceLimit, invalidStoredData, missingBlob, blobHashMismatch
      case ownerUnavailable, accountChanged, transportFailure, invalidControl, comparisonFailed
      case observationTimeout, observationFailed
    }
    public enum Stage: String, Codable, Sendable {
      case preparing, draining, negotiating, quiescing, sealing, reading, comparing, resuming
    }
    public enum SourceSection: String, Codable, Sendable {
      case acceptedPhysicalHistory, endpoint, cloudAccount, pending, cache, emissions, finalReader
    }
    public enum Reason: String, Codable, Sendable {
      case phaseChanged, writerSealChanged, fleetChanged, workspaceChanged, controlChanged, revisionChanged
      case generationChanged, prefixChanged, formatChanged, floorsChanged, cloudChanged, readerChanged
      case acceptedMetadataChanged, incompletePage, cancelled, identityMismatch, resourceLimit
      case invalidStoredData, missingBlob, blobHashMismatch, storageFailure, transportFailure
      case encodingFailure, unexpectedFailure, sourceUnavailable, directoryChanged, invalidControl
      case rootMismatch, jointMismatch, observationTimeout, lateContent, connectionChanged, admissionChanged
      case peerResumedEarly
    }
    public let origin: NotebookReplicationSource
    public let code: Code
    public let reason: Reason
    public let stage: Stage
    public let sourceSection: SourceSection?
    public let stream: Stream?
    public let transactionID: UUID?
    public let identifier: String?

    public init(origin: NotebookReplicationSource, code: Code, reason: Reason, stage: Stage,
      sourceSection: SourceSection? = nil, stream: Stream? = nil, transactionID: UUID? = nil,
      identifier: String? = nil) {
      self.origin = origin; self.code = code; self.reason = reason; self.stage = stage
      self.sourceSection = sourceSection; self.stream = stream; self.transactionID = transactionID
      self.identifier = identifier
    }
    public var isValid: Bool {
      (sourceSection == nil || stage == .reading)
        && (stream == nil || stage == .reading || stage == .comparing)
        && (transactionID == nil || stage == .reading || stage == .comparing)
        && (identifier.map(Self.isValidIdentifier) ?? true)
    }
    public static func isValidIdentifier(_ value: String) -> Bool {
      let bytes = value.utf8
      guard (1...80).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
      return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    public var errorDescription: String? {
      "History observation refused: \(code.rawValue)/\(reason.rawValue) (\(stage.rawValue))."
    }
  }
  public struct Prepared: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let workspaceID: UUID
    public let source: NotebookReplicationSource
    public let head: NotebookDurableChange?
    public let readRevision: UInt64
    public init(requestID: UUID, workspaceID: UUID, source: NotebookReplicationSource,
      head: NotebookDurableChange?, readRevision: UInt64) {
      self.requestID = requestID; self.workspaceID = workspaceID; self.source = source
      self.head = head; self.readRevision = readRevision
    }
    public var isValid: Bool { readRevision <= UInt64(Int64.max) && NotebookHistoryControlScope.validHead(head) }
  }
  public struct Metadata: Codable, Equatable, Sendable {
    public let transactionID: UUID?
    public let receiptID: UUID?
    public let hash: String
    public let count: UInt64
    public let byteCount: UInt64
    public init(transactionID: UUID? = nil, receiptID: UUID? = nil, hash: String,
      count: UInt64 = 0, byteCount: UInt64 = 0) {
      self.transactionID = transactionID; self.receiptID = receiptID; self.hash = hash
      self.count = count; self.byteCount = byteCount
    }
    var isValid: Bool {
      NotebookTransportFraming.isSHA256(hash) && count <= UInt64(Int64.max)
        && byteCount <= UInt64(Int64.max) && (receiptID == nil || transactionID != nil)
    }
  }
  public struct Page: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let workspaceID: UUID
    public let source: NotebookReplicationSource
    public let stream: Stream
    public let ordinal: UInt64
    public let previousPageHash: String?
    public let entries: [Metadata]
    public let isLast: Bool
    public let hash: String

    private struct Payload: Codable {
      let requestID: UUID; let workspaceID: UUID; let source: NotebookReplicationSource
      let stream: Stream; let ordinal: UInt64; let previousPageHash: String?
      let entries: [Metadata]; let isLast: Bool
    }
    public init(requestID: UUID, workspaceID: UUID, source: NotebookReplicationSource, stream: Stream,
      ordinal: UInt64, previousPageHash: String? = nil, entries: [Metadata], isLast: Bool) throws {
      self.requestID = requestID; self.workspaceID = workspaceID; self.source = source; self.stream = stream
      self.ordinal = ordinal; self.previousPageHash = previousPageHash; self.entries = entries; self.isLast = isLast
      guard Self.valid(ordinal: ordinal, previous: previousPageHash, entries: entries) else {
        throw NotebookTransportError.invalidFrame
      }
      hash = try Self.digest(.init(requestID: requestID, workspaceID: workspaceID, source: source,
        stream: stream, ordinal: ordinal, previousPageHash: previousPageHash, entries: entries, isLast: isLast))
    }
    private static func valid(ordinal: UInt64, previous: String?, entries: [Metadata]) -> Bool {
      ordinal <= UInt64(Int64.max) && entries.count <= 64 && entries.allSatisfy(\.isValid)
        && (ordinal == 0 ? previous == nil : previous.map(NotebookTransportFraming.isSHA256) == true)
    }
    private static func digest(_ payload: Payload) throws -> String {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return SHA256.hash(data: Data("notebook.history-control.page.v1\u{0}".utf8) + (try encoder.encode(payload)))
        .map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
      guard Self.valid(ordinal: ordinal, previous: previousPageHash, entries: entries),
        NotebookTransportFraming.isSHA256(hash), hash == (try Self.digest(.init(requestID: requestID,
          workspaceID: workspaceID, source: source, stream: stream, ordinal: ordinal,
          previousPageHash: previousPageHash, entries: entries, isLast: isLast))) else {
        throw NotebookTransportError.invalidFrame
      }
    }
  }
  public struct Root: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let workspaceID: UUID
    public let source: NotebookReplicationSource
    public let stream: Stream
    public let hash: String
    public let pageCount: UInt64
    public let entryCount: UInt64
    public init(requestID: UUID, workspaceID: UUID, source: NotebookReplicationSource, stream: Stream,
      hash: String, pageCount: UInt64, entryCount: UInt64) {
      self.requestID = requestID; self.workspaceID = workspaceID; self.source = source; self.stream = stream
      self.hash = hash; self.pageCount = pageCount; self.entryCount = entryCount
    }
    var isValid: Bool {
      NotebookTransportFraming.isSHA256(hash) && pageCount <= UInt64(Int64.max)
        && entryCount <= UInt64(Int64.max)
    }
  }

  case prepare(NotebookHistoryControlPreparation)
  case prepared(Prepared)
  case request(NotebookHistoryControlScope)
  case quiesced(NotebookHistoryControlScope)
  case page(Page)
  case root(Root)
  case resume(requestID: UUID, refusal: Refusal? = nil)
  case resumed(requestID: UUID)
  case stale(requestID: UUID, reason: StaleReason)

  public var requestID: UUID {
    switch self {
    case .prepare(let proposal): proposal.requestID
    case .prepared(let prepared): prepared.requestID
    case .request(let scope), .quiesced(let scope): scope.requestID
    case .page(let page): page.requestID
    case .root(let root): root.requestID
    case .resume(let id, _), .resumed(let id), .stale(let id, _): id
    }
  }
  public func validate() throws {
    switch self {
    case .prepare(let proposal):
      guard proposal.isValid else { throw NotebookTransportError.identityMismatch }
    case .prepared(let prepared): guard prepared.isValid else { throw NotebookTransportError.invalidFrame }
    case .request(let scope), .quiesced(let scope):
      guard scope.isValid else { throw NotebookTransportError.identityMismatch }
    case .page(let page): try page.validate()
    case .root(let root): guard root.isValid else { throw NotebookTransportError.invalidFrame }
    case .resume(_, let refusal):
      guard refusal?.isValid != false else { throw NotebookTransportError.invalidFrame }
    case .resumed, .stale: break
    }
  }
}

/// Live counters of the existing connection, separate from either SQL snapshot
/// and from a sealed joint result. Accepted cursors advance after storage returns.
public struct NotebookHistoryTransportObservation: Codable, Equatable, Sendable {
  public let connectionID: UUID
  public let localSource: NotebookReplicationSource?
  public let remoteSource: NotebookReplicationSource?
  public let localOfferedThrough: UInt64
  public let peerAcceptedThrough: UInt64
  public let remoteOfferedThrough: UInt64
  public let incomingAcceptedThrough: UInt64
  public let pendingDurableWork: Int
  public let hasStorageCallback: Bool
  public let pendingFrames: Int
  public let unacknowledgedFrames: Int
  public let isSending: Bool
  public let scope: NotebookHistoryControlScope?
  public let preparation: NotebookHistoryControlPreparation?
  public let localPrepared: NotebookHistoryControl.Prepared?
  public let peerPrepared: NotebookHistoryControl.Prepared?
  public let isQuiescent: Bool

  public init(connectionID: UUID, localSource: NotebookReplicationSource?, remoteSource: NotebookReplicationSource?,
    localOfferedThrough: UInt64, peerAcceptedThrough: UInt64, remoteOfferedThrough: UInt64,
    incomingAcceptedThrough: UInt64, pendingDurableWork: Int, hasStorageCallback: Bool,
    pendingFrames: Int, unacknowledgedFrames: Int, isSending: Bool,
    scope: NotebookHistoryControlScope?, isQuiescent: Bool,
    preparation: NotebookHistoryControlPreparation? = nil,
    localPrepared: NotebookHistoryControl.Prepared? = nil, peerPrepared: NotebookHistoryControl.Prepared? = nil) {
    self.connectionID = connectionID; self.localSource = localSource; self.remoteSource = remoteSource
    self.localOfferedThrough = localOfferedThrough; self.peerAcceptedThrough = peerAcceptedThrough
    self.remoteOfferedThrough = remoteOfferedThrough; self.incomingAcceptedThrough = incomingAcceptedThrough
    self.pendingDurableWork = pendingDurableWork; self.hasStorageCallback = hasStorageCallback
    self.pendingFrames = pendingFrames; self.unacknowledgedFrames = unacknowledgedFrames; self.isSending = isSending
    self.scope = scope; self.isQuiescent = isQuiescent
    self.preparation = preparation; self.localPrepared = localPrepared; self.peerPrepared = peerPrepared
  }
}
