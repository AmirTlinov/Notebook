import CryptoKit
import Foundation

/// Incremental metadata observation for one exact, already admitted endpoint.
/// A completed digest proves the received stream, not history completeness,
/// birth, authorship, a fleet seal, or permission to activate another format.
public struct NotebookHistoryStreamAccumulator {
  public static let streams: [NotebookHistoryControl.Stream] = [
    .acceptedTransactions, .physicalClosures, .sourceOriginalRoots,
    .replicaInventory, .replicaControl, .fleet,
  ]
  public static let maximumEntriesPerPage = 64

  public let scope: NotebookHistoryControlScope
  public let source: NotebookReplicationSource
  public let stream: NotebookHistoryControl.Stream
  public private(set) var pageCount: UInt64 = 0
  public private(set) var entryCount: UInt64 = 0
  public private(set) var metadataCount: UInt64 = 0
  public private(set) var byteCount: UInt64 = 0
  public private(set) var isComplete = false

  private var content: HistoryDigestFrame
  private var transactions: HistoryDigestFrame? = nil
  private var previousPageHash: String? = nil
  private var previousTransaction: Data? = nil

  public init(scope: NotebookHistoryControlScope, source: NotebookReplicationSource,
    stream: NotebookHistoryControl.Stream) throws {
    guard scope.isValid, let endpoint = scope.endpoint(for: source.deviceID),
      endpoint.journalGeneration == source.generation else { throw NotebookTransportError.identityMismatch }
    self.scope = scope; self.source = source; self.stream = stream
    content = HistoryDigestFrame("notebook.history-readiness.content.v1")
    content.uuid(scope.workspaceID); content.string(stream.rawValue)
    content.number(UInt64(scope.databaseVersion)); content.number(UInt64(scope.wireVersion))
    content.number(UInt64(scope.manifestVersion))
    // Only these two streams describe common replica content. The other four
    // remain source evidence even when their opaque commitments happen to match.
    let common = stream == .acceptedTransactions || stream == .physicalClosures
    content.byte(common ? 0 : 1)
    if !common { content.uuid(source.deviceID); content.uuid(source.generation) }
    if stream.hasTransactionRows {
      var frontier = HistoryDigestFrame("notebook.history-readiness.transactions.v1")
      frontier.uuid(scope.workspaceID)
      transactions = frontier
    }
  }

  /// Rejection, including a late cancellation, leaves the entire prior cut intact.
  /// Only the current bounded page and the last UUID/page hash are visited/retained.
  public mutating func append(_ page: NotebookHistoryControl.Page) throws {
    try Task.checkCancellation()
    guard page.requestID == scope.requestID, page.workspaceID == scope.workspaceID,
      page.source == source, page.stream == stream else { throw NotebookTransportError.identityMismatch }
    guard !isComplete, page.ordinal == pageCount, page.previousPageHash == previousPageHash else {
      throw NotebookTransportError.invalidSequence
    }
    guard page.entries.count <= Self.maximumEntriesPerPage,
      page.isLast || !page.entries.isEmpty else { throw NotebookTransportError.invalidFrame }
    if !stream.hasTransactionRows {
      guard pageCount == 0, page.isLast, page.entries.count == 1 else { throw NotebookTransportError.invalidFrame }
    }
    try page.validate()
    var nextContent = content, nextTransactions = transactions, nextPrevious = previousTransaction
    var nextEntries = entryCount, nextCount = metadataCount, nextBytes = byteCount
    let nextPages = try Self.add(pageCount, 1)
    for entry in page.entries {
      try Task.checkCancellation()
      if stream.hasTransactionRows {
        guard let transactionID = entry.transactionID, entry.receiptID == nil, entry.count == 1 else {
          throw NotebookTransportError.invalidFrame
        }
        let key = HistoryDigestFrame.uuidBytes(transactionID)
        guard nextPrevious.map({ $0.lexicographicallyPrecedes(key) }) ?? true else {
          throw NotebookTransportError.invalidSequence
        }
        nextPrevious = key; nextTransactions?.uuid(transactionID)
      } else {
        guard entry.transactionID == nil, entry.receiptID == nil else { throw NotebookTransportError.invalidFrame }
      }
      nextEntries = try Self.add(nextEntries, 1)
      nextCount = try Self.add(nextCount, entry.count)
      nextBytes = try Self.add(nextBytes, entry.byteCount)
      nextContent.metadata(entry)
    }
    try Task.checkCancellation()
    content = nextContent; transactions = nextTransactions; previousTransaction = nextPrevious
    pageCount = nextPages; entryCount = nextEntries; metadataCount = nextCount; byteCount = nextBytes
    previousPageHash = page.hash; isComplete = page.isLast
  }

  /// The content hash deliberately excludes request, page boundaries, journal
  /// heads and snapshot IDs; the page chain and confirmed scope bind those cuts.
  public func completedRoot() throws -> NotebookHistoryControl.Root {
    try Task.checkCancellation()
    guard isComplete else { throw NotebookTransportError.historyReadinessPending }
    var final = content
    final.byte(255); final.number(entryCount); final.number(metadataCount); final.number(byteCount)
    return .init(requestID: scope.requestID, workspaceID: scope.workspaceID, source: source,
      stream: stream, hash: final.hash(), pageCount: pageCount, entryCount: entryCount)
  }

  /// Received roots can only become joint inputs after these actual pages agree.
  public func confirm(_ root: NotebookHistoryControl.Root) throws -> NotebookHistoryConfirmedStream {
    guard root.isValid else { throw NotebookTransportError.invalidFrame }
    guard root.requestID == scope.requestID, root.workspaceID == scope.workspaceID,
      root.source == source, root.stream == stream else { throw NotebookTransportError.identityMismatch }
    guard root == (try completedRoot()) else { throw NotebookTransportError.historyCutStale }
    var frontier = transactions
    frontier?.byte(255); frontier?.number(entryCount)
    return .init(scope: scope, root: root, transactionFrontierSHA256: frontier?.hash(),
      metadataCount: metadataCount, byteCount: byteCount)
  }

  private static func add(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
    let value = left.addingReportingOverflow(right)
    guard !value.overflow, value.partialValue <= UInt64(Int64.max) else { throw NotebookTransportError.resourceLimit }
    return value.partialValue
  }
}

/// Cannot be decoded or publicly constructed from a peer's claimed root.
/// Confirmation still grants no origin, actor, complete-history or activation authority.
public struct NotebookHistoryConfirmedStream: Equatable, Sendable {
  public let root: NotebookHistoryControl.Root
  public let transactionFrontierSHA256: String?
  public let metadataCount: UInt64
  public let byteCount: UInt64
  fileprivate let scope: NotebookHistoryControlScope

  fileprivate init(scope: NotebookHistoryControlScope, root: NotebookHistoryControl.Root,
    transactionFrontierSHA256: String?, metadataCount: UInt64, byteCount: UInt64) {
    self.scope = scope; self.root = root; self.transactionFrontierSHA256 = transactionFrontierSHA256
    self.metadataCount = metadataCount; self.byteCount = byteCount
  }
}

/// An ordered commitment to both confirmed endpoints and their six observations.
/// Account/key hashes are explicit inputs from the admitted native owner; their
/// authority, completeness and the actual quiescence barrier remain with that owner.
public struct NotebookHistoryJointDigest: Equatable, Sendable {
  public let scope: NotebookHistoryControlScope
  public let accountScopeSHA256: String
  public let keyScopeSHA256: String
  public let hash: String
  public let roots: [NotebookHistoryControl.Root]

  public init(scope: NotebookHistoryControlScope, accountScopeSHA256: String, keyScopeSHA256: String,
    streams: [NotebookHistoryConfirmedStream]) throws {
    try Task.checkCancellation()
    guard scope.isValid, NotebookTransportFraming.isSHA256(accountScopeSHA256),
      NotebookTransportFraming.isSHA256(keyScopeSHA256) else { throw NotebookTransportError.identityMismatch }
    let order = NotebookHistoryStreamAccumulator.streams
    guard streams.count == scope.endpoints.count * order.count else { throw NotebookTransportError.historyReadinessPending }
    var ordered: [NotebookHistoryConfirmedStream] = []
    ordered.reserveCapacity(12)
    for endpoint in scope.endpoints {
      let source = NotebookReplicationSource(deviceID: endpoint.identity.deviceID, generation: endpoint.journalGeneration)
      for stream in order {
        let matches = streams.filter { $0.root.source == source && $0.root.stream == stream }
        guard matches.count == 1, matches[0].scope == scope else { throw NotebookTransportError.identityMismatch }
        ordered.append(matches[0])
      }
      let first = ordered[ordered.count - order.count]
      for offset in 1...2 {
        let other = ordered[ordered.count - order.count + offset]
        guard first.root.entryCount == other.root.entryCount,
          first.transactionFrontierSHA256 == other.transactionFrontierSHA256 else {
          throw NotebookTransportError.historyCutStale
        }
      }
    }
    for offset in 0...1 {
      let left = ordered[offset].root, right = ordered[order.count + offset].root
      guard left.hash == right.hash, left.entryCount == right.entryCount else { throw NotebookTransportError.historyCutStale }
    }
    var digest = HistoryDigestFrame("notebook.history-readiness.joint.v1")
    digest.uuid(scope.requestID); digest.uuid(scope.workspaceID); digest.uuid(scope.credentialID)
    digest.string(scope.applicationBuild); digest.number(UInt64(scope.databaseVersion))
    digest.number(UInt64(scope.wireVersion)); digest.number(UInt64(scope.manifestVersion))
    digest.hashBytes(accountScopeSHA256); digest.hashBytes(keyScopeSHA256)
    for endpoint in scope.endpoints {
      digest.uuid(endpoint.identity.deviceID); digest.uuid(endpoint.identity.workspaceID)
      digest.string(endpoint.identity.displayName); digest.uuid(endpoint.journalGeneration)
      if let head = endpoint.head {
        digest.byte(1); digest.number(head.sequence); digest.uuid(head.transactionID)
        digest.hashBytes(head.manifestHash); digest.number(UInt64(head.byteCount))
      } else { digest.byte(0) }
    }
    for value in ordered {
      try Task.checkCancellation()
      digest.uuid(value.root.source.deviceID); digest.uuid(value.root.source.generation)
      digest.string(value.root.stream.rawValue); digest.hashBytes(value.root.hash)
      digest.number(value.root.pageCount); digest.number(value.root.entryCount)
      digest.number(value.metadataCount); digest.number(value.byteCount)
    }
    try Task.checkCancellation()
    self.scope = scope; self.accountScopeSHA256 = accountScopeSHA256; self.keyScopeSHA256 = keyScopeSHA256
    hash = digest.hash(); roots = ordered.map(\.root)
  }
}

private extension NotebookHistoryControl.Stream {
  var hasTransactionRows: Bool {
    switch self {
    case .acceptedTransactions, .physicalClosures, .sourceOriginalRoots: true
    case .replicaInventory, .replicaControl, .fleet: false
    }
  }
}

/// All variable strings are already bounded scope fields; each row contributes
/// only fixed UUID/hash/scalar buffers to the existing incremental SHA256 state.
private struct HistoryDigestFrame {
  private var digest = SHA256()
  init(_ domain: String) { digest.update(data: Data((domain + "\u{0}").utf8)) }
  mutating func byte(_ value: UInt8) { digest.update(data: Data([value])) }
  mutating func number(_ value: UInt64) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { digest.update(data: Data($0)) }
  }
  static func uuidBytes(_ value: UUID) -> Data {
    var bytes = value.uuid
    return withUnsafeBytes(of: &bytes) { Data($0) }
  }
  mutating func uuid(_ value: UUID) { digest.update(data: Self.uuidBytes(value)) }
  mutating func optionalUUID(_ value: UUID?) {
    byte(value == nil ? 0 : 1)
    if let value { uuid(value) }
  }
  mutating func string(_ value: String) {
    number(UInt64(value.utf8.count)); digest.update(data: Data(value.utf8))
  }
  mutating func hashBytes(_ value: String) {
    var bytes = Data(); bytes.reserveCapacity(32)
    var high: UInt8?
    for scalar in value.utf8 {
      let nibble = scalar <= 57 ? scalar - 48 : scalar - 87
      if let previous = high { bytes.append(previous << 4 | nibble); high = nil }
      else { high = nibble }
    }
    digest.update(data: bytes)
  }
  mutating func metadata(_ value: NotebookHistoryControl.Metadata) {
    byte(1); optionalUUID(value.transactionID); optionalUUID(value.receiptID)
    hashBytes(value.hash); number(value.count); number(value.byteCount)
  }
  mutating func hash() -> String { NotebookHexEncoding.encode(digest.finalize()) }
}
