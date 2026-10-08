import Foundation
import Testing
@testable import NotebookCore

@Suite("History digest confirms bounded pages without inventing fleet authority")
struct NotebookHistoryReadinessDigestTests {
  private static func id(_ value: UInt64) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
      UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
      UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)))
  }
  private static func scope(requestID: UUID = UUID(), credentialID: UUID? = nil,
    leftSequence: UInt64 = 2) -> NotebookHistoryControlScope {
    let workspace = id(900)
    return .init(requestID: requestID, workspaceID: workspace, credentialID: credentialID ?? id(901),
      applicationBuild: "260", endpoints: [
        .init(identity: .init(deviceID: id(100), workspaceID: workspace, displayName: "Mac fixture"),
          journalGeneration: id(200), head: .init(sequence: leftSequence, transactionID: id(2),
            manifestHash: String(repeating: "a", count: 64), byteCount: 128)),
        .init(identity: .init(deviceID: id(101), workspaceID: workspace, displayName: "iPad fixture"),
          journalGeneration: id(201), head: .init(sequence: 7, transactionID: id(2),
            manifestHash: String(repeating: "a", count: 64), byteCount: 128)),
      ])
  }
  private static func source(_ scope: NotebookHistoryControlScope, _ index: Int) -> NotebookReplicationSource {
    let endpoint = scope.endpoints[index]
    return .init(deviceID: endpoint.identity.deviceID, generation: endpoint.journalGeneration)
  }
  private static func row(_ id: UInt64, hash: String = String(repeating: "b", count: 64),
    bytes: UInt64 = 128) -> NotebookHistoryControl.Metadata {
    .init(transactionID: self.id(id), hash: hash, count: 1, byteCount: bytes)
  }
  private static func page(_ scope: NotebookHistoryControlScope, source: NotebookReplicationSource,
    stream: NotebookHistoryControl.Stream = .acceptedTransactions, ordinal: UInt64 = 0,
    previous: String? = nil, rows: [NotebookHistoryControl.Metadata], last: Bool = true) throws -> NotebookHistoryControl.Page {
    try .init(requestID: scope.requestID, workspaceID: scope.workspaceID, source: source, stream: stream,
      ordinal: ordinal, previousPageHash: previous, entries: rows, isLast: last)
  }
  private static func confirmed(_ scope: NotebookHistoryControlScope, source: NotebookReplicationSource,
    stream: NotebookHistoryControl.Stream, rows: [NotebookHistoryControl.Metadata]) throws -> NotebookHistoryConfirmedStream {
    var observer = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: stream)
    try observer.append(page(scope, source: source, stream: stream, rows: rows))
    return try observer.confirm(observer.completedRoot())
  }
  private static func jointStreams(_ scope: NotebookHistoryControlScope,
    physicalHashOnRight: String? = nil, otherPhysicalIDs: [UInt64]? = nil) throws -> [NotebookHistoryConfirmedStream] {
    var result: [NotebookHistoryConfirmedStream] = []
    for index in 0..<2 {
      let actual = source(scope, index)
      for stream in NotebookHistoryStreamAccumulator.streams {
        let rows: [NotebookHistoryControl.Metadata]
        switch stream {
        case .acceptedTransactions, .physicalClosures, .sourceOriginalRoots:
          let ids: [UInt64] = stream == .physicalClosures ? otherPhysicalIDs ?? [1, 2] : [1, 2]
          let hash = stream == .physicalClosures && index == 1 ? physicalHashOnRight : nil
          rows = ids.map { row($0, hash: hash ?? String(repeating: "b", count: 64)) }
        case .replicaInventory, .replicaControl, .fleet:
          rows = [.init(hash: String(repeating: index == 0 ? "c" : "d", count: 64), count: 3, byteCount: 48)]
        }
        result.append(try confirmed(scope, source: actual, stream: stream, rows: rows))
      }
    }
    return result
  }
  private static func joint(_ scope: NotebookHistoryControlScope,
    streams: [NotebookHistoryConfirmedStream], account: String = String(repeating: "e", count: 64),
    key: String = String(repeating: "f", count: 64)) throws -> NotebookHistoryJointDigest {
    try .init(scope: scope, accountScopeSHA256: account, keyScopeSHA256: key, streams: streams)
  }

  @Test func commonContentIgnoresSourceRequestCutsAndPageBoundariesButNotMetadata() throws {
    let firstScope = Self.scope(), secondScope = Self.scope(leftSequence: 11)
    let left = Self.source(firstScope, 0), right = Self.source(secondScope, 1)
    let rows = (1...64).map { Self.row(UInt64($0)) }
    var first = try NotebookHistoryStreamAccumulator(scope: firstScope, source: left, stream: .acceptedTransactions)
    let firstPage = try Self.page(firstScope, source: left, rows: rows)
    try first.append(firstPage)
    var second = try NotebookHistoryStreamAccumulator(scope: secondScope, source: right, stream: .acceptedTransactions)
    let secondPage = try Self.page(secondScope, source: right, rows: rows, last: false)
    try second.append(secondPage)
    try second.append(Self.page(secondScope, source: right, ordinal: 1, previous: secondPage.hash, rows: []))
    let firstRoot = try first.completedRoot(), secondRoot = try second.completedRoot()
    #expect(firstPage.hash != secondPage.hash)
    #expect(firstRoot.hash == secondRoot.hash && firstRoot.entryCount == 64)
    #expect(firstRoot.pageCount == 1 && secondRoot.pageCount == 2)
    _ = try first.confirm(firstRoot); _ = try second.confirm(secondRoot)
    var changed = rows
    changed[63] = Self.row(64, bytes: 129)
    let altered = try Self.confirmed(firstScope, source: left, stream: .acceptedTransactions, rows: changed)
    #expect(altered.root.hash != firstRoot.hash)
    let sourceLeft = try Self.confirmed(firstScope, source: left, stream: .sourceOriginalRoots, rows: rows)
    let sourceRight = try Self.confirmed(secondScope, source: right, stream: .sourceOriginalRoots, rows: rows)
    #expect(sourceLeft.root.hash != sourceRight.root.hash)
    #expect(sourceLeft.transactionFrontierSHA256 == sourceRight.transactionFrontierSHA256)
  }

  @Test func rejectedPageCannotPoisonTheOrderedPrefixOrItsDigest() throws {
    let scope = Self.scope(), source = Self.source(scope, 0)
    var observer = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: .acceptedTransactions)
    let first = try Self.page(scope, source: source, rows: [Self.row(1), Self.row(2)], last: false)
    try observer.append(first)
    let bad = try Self.page(scope, source: source, ordinal: 1, previous: first.hash, rows: [Self.row(3), Self.row(2)])
    #expect(throws: NotebookTransportError.invalidSequence) { try observer.append(bad) }
    #expect(observer.pageCount == 1 && observer.entryCount == 2 && !observer.isComplete)
    let duplicate = try Self.page(scope, source: source, ordinal: 1, previous: first.hash, rows: [Self.row(2)])
    #expect(throws: NotebookTransportError.invalidSequence) { try observer.append(duplicate) }
    let correct = try Self.page(scope, source: source, ordinal: 1, previous: first.hash, rows: [Self.row(3), Self.row(4)])
    try observer.append(correct)
    let root = try observer.completedRoot()
    let onePage = try Self.confirmed(scope, source: source, stream: .acceptedTransactions,
      rows: [Self.row(1), Self.row(2), Self.row(3), Self.row(4)])
    #expect(root.hash == onePage.root.hash && root.entryCount == 4)
    #expect(throws: NotebookTransportError.invalidSequence) { try observer.append(correct) }
    #expect(observer.pageCount == 2 && observer.entryCount == 4)
  }

  @Test func pageContextChainAndTamperedPageHashFailBeforeStateChanges() throws {
    let scope = Self.scope(), source = Self.source(scope, 0)
    var observer = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: .physicalClosures)
    let first = try Self.page(scope, source: source, stream: .physicalClosures, rows: [Self.row(1)], last: false)
    try observer.append(first)
    let wrongRequest = try Self.page(Self.scope(), source: source, stream: .physicalClosures,
      ordinal: 1, previous: first.hash, rows: [Self.row(2)])
    #expect(throws: NotebookTransportError.identityMismatch) { try observer.append(wrongRequest) }
    let wrongSource = try Self.page(scope, source: Self.source(scope, 1), stream: .physicalClosures,
      ordinal: 1, previous: first.hash, rows: [Self.row(2)])
    #expect(throws: NotebookTransportError.identityMismatch) { try observer.append(wrongSource) }
    let wrongStream = try Self.page(scope, source: source, ordinal: 1, previous: first.hash, rows: [Self.row(2)])
    #expect(throws: NotebookTransportError.identityMismatch) { try observer.append(wrongStream) }
    let wrongWorkspace = try NotebookHistoryControl.Page(requestID: scope.requestID, workspaceID: Self.id(999),
      source: source, stream: .physicalClosures, ordinal: 1, previousPageHash: first.hash,
      entries: [Self.row(2)], isLast: true)
    #expect(throws: NotebookTransportError.identityMismatch) { try observer.append(wrongWorkspace) }
    let wrongOrdinal = try Self.page(scope, source: source, stream: .physicalClosures,
      ordinal: 2, previous: first.hash, rows: [Self.row(2)])
    #expect(throws: NotebookTransportError.invalidSequence) { try observer.append(wrongOrdinal) }
    let wrongChain = try Self.page(scope, source: source, stream: .physicalClosures,
      ordinal: 1, previous: String(repeating: "0", count: 64), rows: [Self.row(2)])
    #expect(throws: NotebookTransportError.invalidSequence) { try observer.append(wrongChain) }
    let valid = try Self.page(scope, source: source, stream: .physicalClosures,
      ordinal: 1, previous: first.hash, rows: [Self.row(2)])
    let encoded = try JSONEncoder().encode(valid)
    var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    fields["hash"] = String(repeating: "0", count: 64)
    let tamperedBytes = try JSONSerialization.data(withJSONObject: fields)
    let tampered = try JSONDecoder().decode(NotebookHistoryControl.Page.self, from: tamperedBytes)
    #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(tampered) }
    #expect(observer.pageCount == 1 && observer.entryCount == 1 && !observer.isComplete)
    try observer.append(valid)
    let root = try observer.completedRoot()
    _ = try observer.confirm(root)
    let wrongCount = NotebookHistoryControl.Root(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: source, stream: .physicalClosures, hash: root.hash, pageCount: 1, entryCount: root.entryCount)
    #expect(throws: NotebookTransportError.historyCutStale) { _ = try observer.confirm(wrongCount) }
    let wrongEntries = NotebookHistoryControl.Root(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: source, stream: .physicalClosures, hash: root.hash, pageCount: root.pageCount, entryCount: 1)
    #expect(throws: NotebookTransportError.historyCutStale) { _ = try observer.confirm(wrongEntries) }
    let wrongHash = NotebookHistoryControl.Root(requestID: scope.requestID, workspaceID: scope.workspaceID,
      source: source, stream: .physicalClosures, hash: String(repeating: "1", count: 64),
      pageCount: root.pageCount, entryCount: root.entryCount)
    #expect(throws: NotebookTransportError.historyCutStale) { _ = try observer.confirm(wrongHash) }
  }

  @Test func shapeAndOverflowRefusalKeepTheLastAcceptedPage() throws {
    let scope = Self.scope(), source = Self.source(scope, 0)
    var observer = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: .acceptedTransactions)
    let empty = try Self.page(scope, source: source, rows: [], last: false)
    #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(empty) }
    let receipt = NotebookHistoryControl.Metadata(transactionID: Self.id(1), receiptID: Self.id(9),
      hash: String(repeating: "b", count: 64), count: 1)
    let receiptPage = try Self.page(scope, source: source, rows: [receipt])
    #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(receiptPage) }
    let wrongCount = NotebookHistoryControl.Metadata(transactionID: Self.id(1), hash: String(repeating: "b", count: 64))
    let wrongCountPage = try Self.page(scope, source: source, rows: [wrongCount])
    #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(wrongCountPage) }
    let first = try Self.page(scope, source: source, rows: [Self.row(1, bytes: UInt64(Int64.max))], last: false)
    try observer.append(first)
    let overflow = try Self.page(scope, source: source, ordinal: 1, previous: first.hash, rows: [Self.row(2, bytes: 1)])
    #expect(throws: NotebookTransportError.resourceLimit) { try observer.append(overflow) }
    #expect(observer.byteCount == UInt64(Int64.max) && observer.entryCount == 1 && !observer.isComplete)
    let corrected = try Self.page(scope, source: source, ordinal: 1, previous: first.hash, rows: [Self.row(2, bytes: 0)])
    try observer.append(corrected)
    let root = try observer.completedRoot()
    _ = try observer.confirm(root)
  }

  @Test func scalarStreamsRequireOneExplicitTerminalCommitmentAndRealScope() throws {
    let scope = Self.scope(), source = Self.source(scope, 0)
    let staleSource = NotebookReplicationSource(deviceID: source.deviceID, generation: UUID())
    #expect(throws: NotebookTransportError.identityMismatch) {
      _ = try NotebookHistoryStreamAccumulator(scope: scope, source: staleSource, stream: .replicaControl)
    }
    for stream in [NotebookHistoryControl.Stream.replicaInventory, .replicaControl, .fleet] {
      var observer = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: stream)
      #expect(throws: NotebookTransportError.historyReadinessPending) { _ = try observer.completedRoot() }
      let empty = try Self.page(scope, source: source, stream: stream, rows: [])
      #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(empty) }
      let scalar = NotebookHistoryControl.Metadata(hash: String(repeating: "a", count: 64), count: 0, byteCount: 0)
      let unfinished = try Self.page(scope, source: source, stream: stream, rows: [scalar], last: false)
      #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(unfinished) }
      let addressed = try Self.page(scope, source: source, stream: stream, rows: [Self.row(1)])
      #expect(throws: NotebookTransportError.invalidFrame) { try observer.append(addressed) }
      try observer.append(Self.page(scope, source: source, stream: stream, rows: [scalar]))
      let root = try observer.completedRoot()
      let confirmed = try observer.confirm(root)
      #expect(confirmed.transactionFrontierSHA256 == nil && confirmed.root.entryCount == 1)
    }
    var emptyHistory = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: .acceptedTransactions)
    try emptyHistory.append(Self.page(scope, source: source, rows: []))
    let root = try emptyHistory.completedRoot()
    #expect(root.pageCount == 1 && root.entryCount == 0)
    _ = try emptyHistory.confirm(root)
  }

  @Test func jointRequiresBothCompleteEndpointsAndTheSameThreeTransactionFrontiers() throws {
    let scope = Self.scope(), all = try Self.jointStreams(scope)
    let value = try Self.joint(scope, streams: all)
    let shuffled = try Self.joint(scope, streams: Array(all.reversed()))
    #expect(value.hash == shuffled.hash && value.roots.count == 12)
    #expect(value.roots[0].hash == value.roots[6].hash)
    #expect(value.roots[1].hash == value.roots[7].hash)
    #expect(value.roots[2].hash != value.roots[8].hash)
    #expect(throws: NotebookTransportError.historyReadinessPending) { _ = try Self.joint(scope, streams: Array(all.dropLast())) }
    var duplicate = all; duplicate[11] = all[10]
    #expect(throws: NotebookTransportError.identityMismatch) { _ = try Self.joint(scope, streams: duplicate) }
    let shifted = try Self.jointStreams(scope, otherPhysicalIDs: [1, 3])
    #expect(throws: NotebookTransportError.historyCutStale) { _ = try Self.joint(scope, streams: shifted) }
    let changedPhysical = try Self.jointStreams(scope, physicalHashOnRight: String(repeating: "a", count: 64))
    #expect(throws: NotebookTransportError.historyCutStale) { _ = try Self.joint(scope, streams: changedPhysical) }
  }

  @Test func jointBindsCredentialActualHeadsAccountAndKeyWithoutChangingCommonContent() throws {
    let scope = Self.scope(), all = try Self.jointStreams(scope), first = try Self.joint(scope, streams: all)
    let otherCredential = Self.scope(requestID: scope.requestID, credentialID: Self.id(902))
    #expect(throws: NotebookTransportError.identityMismatch) { _ = try Self.joint(otherCredential, streams: all) }
    let newCredential = try Self.joint(otherCredential, streams: Self.jointStreams(otherCredential))
    #expect(first.hash != newCredential.hash)
    let otherHead = Self.scope(requestID: scope.requestID, leftSequence: 3)
    #expect(throws: NotebookTransportError.identityMismatch) { _ = try Self.joint(otherHead, streams: all) }
    let newHead = try Self.joint(otherHead, streams: Self.jointStreams(otherHead))
    #expect(first.hash != newHead.hash && first.roots[0].hash == newHead.roots[0].hash)
    let variants = [
      NotebookDurableChange(sequence: 2, transactionID: Self.id(2), manifestHash: String(repeating: "c", count: 64), byteCount: 128),
      NotebookDurableChange(sequence: 2, transactionID: Self.id(3), manifestHash: String(repeating: "a", count: 64), byteCount: 128),
      NotebookDurableChange(sequence: 2, transactionID: Self.id(2), manifestHash: String(repeating: "a", count: 64), byteCount: 129),
    ]
    for head in variants {
      let original = scope.endpoints[0]
      let changed = NotebookHistoryControlScope(requestID: scope.requestID, workspaceID: scope.workspaceID,
        credentialID: scope.credentialID, applicationBuild: scope.applicationBuild, endpoints: [
          .init(identity: original.identity, journalGeneration: original.journalGeneration, head: head), scope.endpoints[1],
        ])
      let value = try Self.joint(changed, streams: Self.jointStreams(changed))
      #expect(value.hash != first.hash)
    }
    let newAccount = try Self.joint(scope, streams: all, account: String(repeating: "1", count: 64))
    let newKey = try Self.joint(scope, streams: all, key: String(repeating: "2", count: 64))
    #expect(first.hash != newAccount.hash && first.hash != newKey.hash && newAccount.hash != newKey.hash)
    #expect(throws: NotebookTransportError.identityMismatch) { _ = try Self.joint(scope, streams: all, key: "unknown") }
  }

  @Test func scalarIntegerCommitmentsDoNotRoundAtDoublePrecision() throws {
    let scope = Self.scope(), source = Self.source(scope, 0)
    let exact: UInt64 = 9_007_199_254_740_992
    let a = NotebookHistoryControl.Metadata(hash: String(repeating: "a", count: 64), count: exact, byteCount: exact)
    let b = NotebookHistoryControl.Metadata(hash: a.hash, count: exact + 1, byteCount: exact)
    let c = NotebookHistoryControl.Metadata(hash: a.hash, count: exact, byteCount: exact + 1)
    let first = try Self.confirmed(scope, source: source, stream: .replicaInventory, rows: [a])
    let nextCount = try Self.confirmed(scope, source: source, stream: .replicaInventory, rows: [b])
    let nextBytes = try Self.confirmed(scope, source: source, stream: .replicaInventory, rows: [c])
    #expect(first.root.hash != nextCount.root.hash && first.root.hash != nextBytes.root.hash)
    #expect(first.metadataCount == exact && nextCount.metadataCount == exact + 1)
    #expect(first.byteCount == exact && nextBytes.byteCount == exact + 1)
  }

  @Test func cancelledAppendPublishesNothingAndANewObservationStillWorks() async throws {
    let scope = Self.scope(), source = Self.source(scope, 0)
    let page = try Self.page(scope, source: source, rows: [Self.row(1)])
    let cancelled = Task { () throws -> (Bool, UInt64, UInt64) in
      var observer = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: .acceptedTransactions)
      withUnsafeCurrentTask { $0?.cancel() }
      do { try observer.append(page); return (false, observer.pageCount, observer.entryCount) }
      catch is CancellationError { return (true, observer.pageCount, observer.entryCount) }
    }
    let result = try await cancelled.value
    #expect(result.0 && result.1 == 0 && result.2 == 0)
    var fresh = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: .acceptedTransactions)
    try fresh.append(page)
    let root = try fresh.completedRoot()
    _ = try fresh.confirm(root)
    #expect(root.entryCount == 1)
  }

  @Test func hundredThousandTransactionsStreamInBoundedPagesAndMatchAcrossReplicas() throws {
    let scope = Self.scope(), left = Self.source(scope, 0), right = Self.source(scope, 1)
    var a = try NotebookHistoryStreamAccumulator(scope: scope, source: left, stream: .physicalClosures)
    var b = try NotebookHistoryStreamAccumulator(scope: scope, source: right, stream: .physicalClosures)
    var previousA: String?, previousB: String?, ordinal: UInt64 = 0
    for start in stride(from: 1, through: 100_000, by: 64) {
      let last = min(start + 63, 100_000)
      let rows = (start...last).map { Self.row(UInt64($0)) }
      let final = last == 100_000
      let pageA = try Self.page(scope, source: left, stream: .physicalClosures, ordinal: ordinal,
        previous: previousA, rows: rows, last: final)
      let pageB = try Self.page(scope, source: right, stream: .physicalClosures, ordinal: ordinal,
        previous: previousB, rows: rows, last: final)
      try a.append(pageA); try b.append(pageB)
      previousA = pageA.hash; previousB = pageB.hash; ordinal += 1
    }
    let rootA = try a.completedRoot(), rootB = try b.completedRoot()
    #expect(rootA.entryCount == 100_000 && rootB.entryCount == 100_000)
    #expect(rootA.hash == rootB.hash && rootA.pageCount == 1_563 && rootB.pageCount == 1_563)
    #expect(a.metadataCount == 100_000 && a.byteCount == 12_800_000)
    _ = try a.confirm(rootA); _ = try b.confirm(rootB)
  }
}
