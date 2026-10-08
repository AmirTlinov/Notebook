import CryptoKit
import Foundation
import NotebookCore

extension NotebookHistoryReadiness {
  /// Safe context only. The original typed cause is retained for the refusal
  /// classifier; arbitrary storage messages and authored values are not exposed.
  struct SourceError: Error, LocalizedError, Sendable {
    typealias Reason = NotebookHistoryControl.Refusal.Reason
    typealias Section = NotebookHistoryControl.Refusal.SourceSection
    let reason: Reason
    let section: Section
    let transactionID: UUID?
    let underlying: (any Error)?
    let identifier: String?

    nonisolated init(reason: Reason, section: Section, transactionID: UUID? = nil, underlying: (any Error)? = nil) {
      self.reason = reason; self.section = section
      self.transactionID = transactionID; self.underlying = underlying
      let candidate: String?
      if let storage = underlying as? NotebookStorageError, case .limitExceeded(let limit) = storage {
        candidate = limit
      } else { candidate = (underlying as? CollaborationError)?.code }
      identifier = candidate.flatMap { NotebookHistoryControl.Refusal.isValidIdentifier($0) ? $0 : nil }
    }
    nonisolated var errorDescription: String? { "history_source: \(section.rawValue)/\(reason.rawValue)" }

    nonisolated static func contextualize(_ error: any Error, section: Section,
      transactionID: UUID?) -> any Error {
      if error is SourceError || error is CancellationError || error is NotebookHistoryControl.Refusal { return error }
      let reason: Reason
      if let storage = error as? NotebookStorageError {
        switch storage {
        case .limitExceeded: reason = .resourceLimit
        case .unsupportedFormat, .legacyStoreRequiresConversion: reason = .formatChanged
        case .blobMissing: reason = .missingBlob
        case .blobHashMismatch: reason = .blobHashMismatch
        case .corruptRecord, .invalidTransaction: reason = .invalidStoredData
        case .transactionConflict, .readOnlyTransaction: reason = .storageFailure
        }
      } else if let transport = error as? NotebookTransportError {
        switch transport {
        case .identityMismatch, .authenticationRequired: reason = .identityMismatch
        case .resourceLimit, .frameTooLarge, .blobTooLarge: reason = .resourceLimit
        default: reason = .transportFailure
        }
      } else if let collaboration = error as? CollaborationError {
        switch collaboration.code {
        case "resource_limit": reason = .resourceLimit
        case "workspace_changed": reason = .workspaceChanged
        default: reason = .storageFailure
        }
      } else if error is DecodingError { reason = .invalidStoredData }
      else if error is EncodingError { reason = .encodingFailure }
      else { reason = .unexpectedFailure }
      return SourceError(reason: reason, section: section, transactionID: transactionID, underlying: error)
    }
  }
  struct SourceCounters: Codable, Equatable, Sendable {
    var acceptedTransactions: UInt64 = 0, receiptOccurrences: UInt64 = 0
    var incompletePhysical: UInt64 = 0, unknownSourceOriginals: UInt64 = 0, missingOriginalRoots: UInt64 = 0
    var endpointRows: UInt64 = 0, historicalGenerationRows: UInt64 = 0, retirementRows: UInt64 = 0
    var thirdDeviceRows: UInt64 = 0, endpointOverflowRows: UInt64 = 0
    var cloudAccountRows: UInt64 = 0, historicalCloudAccountRows: UInt64 = 0
    var cloudPendingRows: UInt64 = 0, foreignPendingAccountRows: UInt64 = 0, receiptCacheRows: UInt64 = 0
  }
  enum SourceBlockerReason: String, Codable, CaseIterable, Hashable, Sendable {
    case incompletePhysical, unknownSourceOriginal, missingOriginalRoot
    case thirdDevice, endpointOverflow, currentPeerGenerationMismatch, pendingCloud, foreignPendingAccount
    case directoryUnavailable, directoryMembershipMissing, workspaceUnenrolled, workspaceDeleted
    case accountScopeMismatch, cloudAccountScopeMismatch, credentialScopeMismatch
    case suppressedDevice, unknownPeer, peerScopeMismatch, invalidCloudControl, unjoinedTransport
  }
  struct SourceBlockerCount: Codable, Equatable, Sendable {
    let reason: SourceBlockerReason
    let count: UInt64
  }
  struct SourceReport: Sendable {
    let source: NotebookReplicationSource
    let readerLifetimeID: UUID
    let controlObservation: NotebookReplicaInventoryCut.ControlObservation
    let roots: [NotebookHistoryControl.Root]
    let confirmedStreams: [NotebookHistoryConfirmedStream]
    let counters: SourceCounters
    let blockers: [SourceBlockerCount]
    let endpointIDs: [UUID]
    let endpointOverflow: Bool
    /// At most one receipt per retained endpoint. Overflow is explicit; every
    /// historical receipt, including omitted report rows, enters inventory SHA.
    let retirements: [NotebookPeerRetirement]

    func projection() throws -> JSONValue {
      guard roots.count == 6, confirmedStreams.count == 6, endpointIDs.count <= 64,
        retirements.count <= 64, blockers.count <= SourceBlockerReason.allCases.count else {
        throw NotebookTransportError.resourceLimit
      }
      let counts: [String: UInt64] = [
        "acceptedTransactions": counters.acceptedTransactions, "receiptOccurrences": counters.receiptOccurrences,
        "incompletePhysical": counters.incompletePhysical, "unknownSourceOriginals": counters.unknownSourceOriginals,
        "missingOriginalRoots": counters.missingOriginalRoots, "endpointRows": counters.endpointRows,
        "historicalGenerationRows": counters.historicalGenerationRows, "retirementRows": counters.retirementRows,
        "thirdDeviceRows": counters.thirdDeviceRows, "endpointOverflowRows": counters.endpointOverflowRows,
        "cloudAccountRows": counters.cloudAccountRows, "historicalCloudAccountRows": counters.historicalCloudAccountRows,
        "cloudPendingRows": counters.cloudPendingRows, "foreignPendingAccountRows": counters.foreignPendingAccountRows,
        "receiptCacheRows": counters.receiptCacheRows,
      ]
      return .object([
        "source": try .encode(source), "readerLifetimeID": .string(readerLifetimeID.uuidString),
        "controlObservation": .object(["scope": .string(controlObservation.scope.rawValue),
          "sqliteDataVersion": .string(String(controlObservation.sqliteDataVersion)),
          "fixedScalarHash": .string(controlObservation.fixedScalarHash)]),
        "roots": .array(try roots.map { root in
          guard let token = confirmedStreams.first(where: { $0.root == root }) else {
            throw NotebookTransportError.historyCutStale
          }
          return .object(["requestID": .string(root.requestID.uuidString),
            "workspaceID": .string(root.workspaceID.uuidString), "source": try .encode(root.source),
            "stream": .string(root.stream.rawValue), "hash": .string(root.hash),
            "pageCount": .string(String(root.pageCount)), "entryCount": .string(String(root.entryCount)),
            "metadataCount": .string(String(token.metadataCount)), "byteCount": .string(String(token.byteCount)),
            "transactionFrontierSHA256": token.transactionFrontierSHA256.map(JSONValue.string) ?? .null])
        }),
        "counters": .object(counts.mapValues { .string(String($0)) }),
        "blockers": .array(blockers.map { .object(["reason": .string($0.reason.rawValue),
          "count": .string(String($0.count))]) }),
        "endpointIDs": .array(endpointIDs.map { .string($0.uuidString) }),
        "endpointOverflow": .bool(endpointOverflow),
        "retirements": .array(try retirements.map { receipt in
          .object(["peerID": .string(receipt.peerID.uuidString),
            "workspaceID": .string(receipt.workspaceID.uuidString),
            "sourceCursor": .string(String(receipt.sourceCursor)),
            "acknowledgedCursor": .string(String(receipt.acknowledgedCursor)),
            "date": try .encode(receipt.date)])
        }),
      ])
    }
  }

  /// Exhaustive source evidence through the model's existing serial reader.
  /// Each finite call owns a new WAL cut; only semantic positions cross await.
  /// No report here grants joint readiness, authorship or format activation.
  func produceSource(model: NotebookAppModel, request: Request, scope: NotebookHistoryControlScope,
    fleetWitness: NotebookHistoryFleetWitness,
    send: @MainActor (NotebookHistoryControl.Page) async throws -> Void) async throws -> SourceReport {
    var section = SourceError.Section.acceptedPhysicalHistory
    var transactionID: UUID?
    do {
      try Task.checkCancellation()
      try requireSourceCoordinationCurrent(requestID: request.id)
      guard self === model.historyReadiness, case .sealed(let current, let seal) = phase, current == request else {
        throw SourceError(reason: .phaseChanged, section: section)
      }
      guard model.ownsHistoryWriterSeal(request: request, seal: seal) else {
        throw SourceError(reason: .writerSealChanged, section: section)
      }
      let fleet = fleetWitness.observation
      guard scope.isValid, scope.requestID == request.id, scope.workspaceID == request.workspaceID,
        Set(scope.endpoints.map { $0.identity.deviceID }) == request.devices,
        fleet.local.deviceID == model.actorID, fleet.local.workspaceID == request.workspaceID,
        let endpoint = scope.endpoint(for: model.actorID), endpoint.identity == fleet.local else {
        throw SourceError(reason: .identityMismatch, section: section)
      }
      try requireSourceCurrent(model: model, request: request, seal: seal, witness: fleetWitness, section: section)
      let initial = try await model.observeHistorySource { try $0.replicaInventoryCut() }
      try requireSourceCurrent(model: model, request: request, seal: seal, witness: fleetWitness, section: section)
      let cut = initial.value
      guard cut.workspaceID == scope.workspaceID else { throw SourceError(reason: .workspaceChanged, section: section) }
      guard cut.journalGenerationStatus == .stored, cut.journalGeneration == endpoint.journalGeneration else {
        throw SourceError(reason: .generationChanged, section: section)
      }
      guard cut.acceptedLocalPrefix == endpoint.head else { throw SourceError(reason: .prefixChanged, section: section) }
      guard cut.databaseVersion == scope.databaseVersion, cut.wireVersion == scope.wireVersion,
        cut.manifestVersion == scope.manifestVersion else { throw SourceError(reason: .formatChanged, section: section) }
      let source = NotebookReplicationSource(deviceID: model.actorID, generation: endpoint.journalGeneration)
      let borrow = NotebookHistorySourceBorrow(readiness: self, model: model, request: request, seal: seal,
        witness: fleetWitness, lifetime: initial.connectionLifetimeID, anchor: cut)
      var accepted = try NotebookHistorySourceEmission(scope: scope, source: source, stream: .acceptedTransactions)
      var physical = try NotebookHistorySourceEmission(scope: scope, source: source, stream: .physicalClosures)
      var originals = try NotebookHistorySourceEmission(scope: scope, source: source, stream: .sourceOriginalRoots)
      var diagnostics = NotebookHistorySourceDiagnostics(scope: scope)
      try diagnostics.control(cut, accountScopeHash: fleet.accountScopeHash)
      var afterTransaction: UUID?
      while true {
        section = .acceptedPhysicalHistory
        transactionID = nil
        let position = afterTransaction
        let batch = try await borrow.read(section: section) { query, _ in
          let page = try query.actionHistoryOccurrencePage(afterTransactionID: position, limit: 64)
          return (page.occurrences, page.next == nil)
        }
        var acceptedRows: [NotebookHistoryControl.Metadata] = [], physicalRows: [NotebookHistoryControl.Metadata] = []
        var originalRows: [NotebookHistoryControl.Metadata] = []
        for occurrence in batch.0 {
          transactionID = occurrence.transactionID
          try borrow.requireCurrent(section: section, transactionID: transactionID)
          let metadata = try await borrow.read(section: section, transactionID: transactionID) { query, _ in
            try query.actionHistoryReadinessMetadata(transactionID: occurrence.transactionID,
              manifestHash: occurrence.manifestHash)
          }
          guard metadata.acceptedTransactions == (try occurrence.historyReadinessAcceptedMetadata()) else {
            throw SourceError(reason: .acceptedMetadataChanged, section: section, transactionID: transactionID)
          }
          acceptedRows.append(try Self.sourceRow(metadata.acceptedTransactions))
          physicalRows.append(try Self.sourceRow(metadata.physicalClosures))
          originalRows.append(try Self.sourceRow(metadata.sourceOriginalRoots))
          try diagnostics.physical(metadata)
          afterTransaction = occurrence.transactionID
        }
        section = .emissions; transactionID = nil
        try borrow.requireCurrent(section: section)
        try await accepted.emit(acceptedRows, last: batch.1, send: send); try borrow.requireCurrent(section: section)
        try await physical.emit(physicalRows, last: batch.1, send: send); try borrow.requireCurrent(section: section)
        try await originals.emit(originalRows, last: batch.1, send: send); try borrow.requireCurrent(section: section)
        if batch.1 { break }
      }

      section = .endpoint
      var inventory = NotebookHistorySourceDigest("notebook.history-readiness.replica-inventory.v1")
      // The scalar observation binds this source's fixed control; a page's
      // ephemeral cut and cursor can never enter an inventory commitment.
      try inventory.record("cut", NotebookHistorySourceCutMetadata(cut: cut))
      var position: NotebookReplicaInventoryPosition?
      while true {
        let next = position, expected = cut.controlObservation
        let batch = try await borrow.read(section: section) { query, current in
          let page = try next.map { try query.replicaEndpointPage(in: current, resuming: $0,
            expectedControlObservation: expected, limit: 64) } ?? query.replicaEndpointPage(in: current, limit: 64)
          return (page.entries, page.next?.position, page.complete)
        }
        for row in batch.0 { try inventory.record("endpoint", row); try diagnostics.endpoint(row) }
        position = batch.1
        if batch.2 { break }
        guard position != nil, !batch.0.isEmpty else { throw SourceError(reason: .incompletePage, section: section) }
      }
      section = .cloudAccount
      position = nil
      while true {
        let next = position, expected = cut.controlObservation
        let batch = try await borrow.read(section: section) { query, current in
          let page = try next.map { try query.replicaCloudAccountPage(in: current, resuming: $0,
            expectedControlObservation: expected, limit: 64) } ?? query.replicaCloudAccountPage(in: current, limit: 64)
          return (page.entries, page.next?.position, page.complete)
        }
        for row in batch.0 {
          try inventory.record("cloud-account", row)
          try diagnostics.bump(\.cloudAccountRows)
          if let account = fleet.accountScopeHash, NotebookHistoryFleetObservation.accountScope(row.account) != account {
            try diagnostics.bump(\.historicalCloudAccountRows)
          }
        }
        position = batch.1
        if batch.2 { break }
        guard position != nil, !batch.0.isEmpty else { throw SourceError(reason: .incompletePage, section: section) }
      }
      section = .pending
      position = nil
      while true {
        let next = position, expected = cut.controlObservation
        let batch = try await borrow.read(section: section) { query, current in
          let page = try next.map { try query.replicaCloudPendingPage(in: current, resuming: $0,
            expectedControlObservation: expected, limit: 64) } ?? query.replicaCloudPendingPage(in: current, limit: 64)
          return (page.entries, page.next?.position, page.complete)
        }
        for row in batch.0 {
          try inventory.record("cloud-pending", row)
          try diagnostics.pending(row, accountScopeHash: fleet.accountScopeHash)
        }
        position = batch.1
        if batch.2 { break }
        guard position != nil, !batch.0.isEmpty else { throw SourceError(reason: .incompletePage, section: section) }
      }
      section = .cache
      position = nil
      while true {
        let next = position, expected = cut.controlObservation
        let batch = try await borrow.read(section: section) { query, current in
          let page = try next.map { try query.replicaCloudReceiptCachePage(in: current, resuming: $0,
            expectedControlObservation: expected, limit: 64) } ?? query.replicaCloudReceiptCachePage(in: current, limit: 64)
          return (page.entries, page.next?.position, page.complete)
        }
        for row in batch.0 { try inventory.record("cloud-receipt-cache", row); try diagnostics.bump(\.receiptCacheRows) }
        position = batch.1
        if batch.2 { break }
        guard position != nil, !batch.0.isEmpty else { throw SourceError(reason: .incompletePage, section: section) }
      }
      section = .emissions
      let fleetRow = try diagnostics.fleet(fleet)
      let summary = diagnostics.summary
      var control = NotebookHistorySourceDigest("notebook.history-readiness.replica-control.v1")
      try control.record("workspace", scope.workspaceID)
      try control.record("counters", diagnostics.counters)
      try control.record("blockers", summary)
      try control.record("endpoint-ids", diagnostics.endpointIDs.sorted { $0.uuidString < $1.uuidString })
      try control.record("endpoint-overflow", diagnostics.counters.endpointOverflowRows > 0)
      let inventoryCount = try Self.sourceAdd(try Self.sourceAdd(diagnostics.counters.endpointRows,
        diagnostics.counters.cloudAccountRows), try Self.sourceAdd(diagnostics.counters.cloudPendingRows,
        diagnostics.counters.receiptCacheRows))
      var scalarEmissions: [NotebookHistorySourceEmission] = []
      for (stream, row) in [(NotebookHistoryControl.Stream.replicaInventory, inventory.row(count: inventoryCount)),
        (.replicaControl, control.row(count: diagnostics.totalBlockers)), (.fleet, fleetRow)] {
        try borrow.requireCurrent(section: section)
        var emitter = try NotebookHistorySourceEmission(scope: scope, source: source, stream: stream)
        try await emitter.emit([row], last: true, send: send)
        try borrow.requireCurrent(section: section)
        scalarEmissions.append(emitter)
      }
      // A send callback or credit wait can advance metadata without read_revision.
      // Recheck the real reader after the last send before publishing roots.
      section = .finalReader
      let _: Bool = try await borrow.read(section: section) { _, _ in true }
      let emissions = [accepted, physical, originals] + scalarEmissions
      let roots = try emissions.map { try $0.accumulator.completedRoot() }
      let confirmed = try zip(emissions, roots).map { try $0.0.accumulator.confirm($0.1) }
      try borrow.requireCurrent(section: section)
      return .init(source: source, readerLifetimeID: initial.connectionLifetimeID,
        controlObservation: cut.controlObservation, roots: roots, confirmedStreams: confirmed,
        counters: diagnostics.counters, blockers: summary,
        endpointIDs: diagnostics.endpointIDs.sorted { $0.uuidString < $1.uuidString },
        endpointOverflow: diagnostics.counters.endpointOverflowRows > 0,
        retirements: diagnostics.retirements)
    } catch {
      throw SourceError.contextualize(error, section: section, transactionID: transactionID)
    }
  }

  fileprivate func requireSourceCurrent(model: NotebookAppModel, request: Request, seal: UUID,
    witness: NotebookHistoryFleetWitness, section: SourceError.Section, transactionID: UUID? = nil) throws {
    try Task.checkCancellation()
    try requireSourceCoordinationCurrent(requestID: request.id)
    guard phase == .sealed(request, writerSeal: seal) else {
      throw SourceError(reason: .phaseChanged, section: section, transactionID: transactionID)
    }
    guard model.ownsHistoryWriterSeal(request: request, seal: seal) else {
      throw SourceError(reason: .writerSealChanged, section: section, transactionID: transactionID)
    }
    do { try witness.requireCurrent() }
    catch {
      if error is CancellationError || error is NotebookHistoryControl.Refusal { throw error }
      throw SourceError(reason: .fleetChanged, section: section, transactionID: transactionID, underlying: error)
    }
  }

  /// Check named scalar fields before their aggregate hash so the first
  /// refusal identifies the actual changed anchor rather than just control.
  nonisolated static func sourceAnchorMismatch(_ current: NotebookReplicaInventoryCut,
    expected: NotebookReplicaInventoryCut) -> SourceError.Reason? {
    if current.workspaceID != expected.workspaceID { return .workspaceChanged }
    if current.readRevision != expected.readRevision { return .revisionChanged }
    if current.journalGenerationStatus != expected.journalGenerationStatus
      || current.journalGeneration != expected.journalGeneration { return .generationChanged }
    if current.acceptedLocalPrefix != expected.acceptedLocalPrefix { return .prefixChanged }
    if current.databaseVersion != expected.databaseVersion || current.wireVersion != expected.wireVersion
      || current.manifestVersion != expected.manifestVersion { return .formatChanged }
    if current.deliveryFloors != expected.deliveryFloors { return .floorsChanged }
    if current.cloud != expected.cloud { return .cloudChanged }
    if current.controlObservation != expected.controlObservation { return .controlChanged }
    return nil
  }
  nonisolated fileprivate static func sourceAdd(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
    let sum = left.addingReportingOverflow(right)
    guard !sum.overflow, sum.partialValue <= UInt64(Int64.max) else { throw NotebookTransportError.resourceLimit }
    return sum.partialValue
  }
  private static func sourceRow(_ row: NotebookHistoryReadinessMetadata.Row) throws -> NotebookHistoryControl.Metadata {
    guard row.count == 1, row.byteCount >= 0 else { throw NotebookTransportError.invalidFrame }
    return .init(transactionID: row.transactionID, hash: row.hash, count: 1, byteCount: UInt64(row.byteCount))
  }
}

@MainActor
private struct NotebookHistorySourceBorrow {
  let readiness: NotebookHistoryReadiness, model: NotebookAppModel
  let request: NotebookHistoryReadiness.Request, seal: UUID
  let witness: NotebookHistoryFleetWitness, lifetime: UUID
  let anchor: NotebookReplicaInventoryCut

  func requireCurrent(section: NotebookHistoryReadiness.SourceError.Section, transactionID: UUID? = nil) throws {
    try readiness.requireSourceCurrent(model: model, request: request, seal: seal,
      witness: witness, section: section, transactionID: transactionID)
  }
  func read<Value: Sendable>(section: NotebookHistoryReadiness.SourceError.Section, transactionID: UUID? = nil,
    _ operation: @escaping @Sendable (NotebookQueryCut, NotebookReplicaInventoryCut) throws -> Value)
    async throws -> Value {
    do {
      try requireCurrent(section: section, transactionID: transactionID)
      let expected = anchor
      let observation = try await model.observeHistorySource { query -> Result<Value, NotebookHistoryReadiness.SourceError> in
        let current = try query.replicaInventoryCut()
        if let reason = NotebookHistoryReadiness.sourceAnchorMismatch(current, expected: expected) {
          return .failure(.init(reason: reason, section: section, transactionID: transactionID))
        }
        return .success(try operation(query, current))
      }
      try requireCurrent(section: section, transactionID: transactionID)
      guard observation.connectionLifetimeID == lifetime else {
        throw NotebookHistoryReadiness.SourceError(reason: .readerChanged, section: section, transactionID: transactionID)
      }
      return try observation.value.get()
    } catch {
      throw NotebookHistoryReadiness.SourceError.contextualize(error, section: section, transactionID: transactionID)
    }
  }
}

private struct NotebookHistorySourceEmission {
  var accumulator: NotebookHistoryStreamAccumulator
  private var previousPageHash: String?
  init(scope: NotebookHistoryControlScope, source: NotebookReplicationSource, stream: NotebookHistoryControl.Stream) throws {
    accumulator = try .init(scope: scope, source: source, stream: stream)
  }
  @MainActor mutating func emit(_ entries: [NotebookHistoryControl.Metadata], last: Bool,
    send: @MainActor (NotebookHistoryControl.Page) async throws -> Void) async throws {
    let page = try NotebookHistoryControl.Page(requestID: accumulator.scope.requestID,
      workspaceID: accumulator.scope.workspaceID, source: accumulator.source, stream: accumulator.stream,
      ordinal: accumulator.pageCount, previousPageHash: previousPageHash, entries: entries, isLast: last)
    try accumulator.append(page)
    try await send(page)
    previousPageHash = page.hash
  }
}

/// Encode integer scalars directly, without JSONValue's floating point
/// projection. The borrowed snapshot UUID is deliberately absent.
private struct NotebookHistorySourceCutMetadata: Encodable {
  let cut: NotebookReplicaInventoryCut
  private enum CodingKeys: String, CodingKey {
    case workspaceID, readRevision, databaseVersion, wireVersion, manifestVersion
    case journalGenerationStatus, journalGeneration, acceptedLocalPrefix, deliveryFloors, cloud, controlObservation
  }
  func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(cut.workspaceID, forKey: .workspaceID)
    try fields.encode(cut.readRevision, forKey: .readRevision)
    try fields.encode(cut.databaseVersion, forKey: .databaseVersion)
    try fields.encode(cut.wireVersion, forKey: .wireVersion)
    try fields.encode(cut.manifestVersion, forKey: .manifestVersion)
    try fields.encode(cut.journalGenerationStatus, forKey: .journalGenerationStatus)
    try fields.encodeIfPresent(cut.journalGeneration, forKey: .journalGeneration)
    try fields.encodeIfPresent(cut.acceptedLocalPrefix, forKey: .acceptedLocalPrefix)
    try fields.encode(cut.deliveryFloors, forKey: .deliveryFloors)
    try fields.encode(cut.cloud, forKey: .cloud)
    try fields.encode(cut.controlObservation, forKey: .controlObservation)
  }
}

@MainActor
private struct NotebookHistorySourceDiagnostics {
  let scope: NotebookHistoryControlScope
  var counters = NotebookHistoryReadiness.SourceCounters()
  var endpointIDs: Set<UUID> = []
  private(set) var retirements: [NotebookPeerRetirement] = []
  private var counts: [NotebookHistoryReadiness.SourceBlockerReason: UInt64] = [:]
  private(set) var totalBlockers: UInt64 = 0

  init(scope: NotebookHistoryControlScope) { self.scope = scope }
  var summary: [NotebookHistoryReadiness.SourceBlockerCount] {
    NotebookHistoryReadiness.SourceBlockerReason.allCases.compactMap { reason in
      counts[reason].map { .init(reason: reason, count: $0) }
    }
  }
  mutating func bump(_ field: WritableKeyPath<NotebookHistoryReadiness.SourceCounters, UInt64>, by count: UInt64 = 1) throws {
    counters[keyPath: field] = try NotebookHistoryReadiness.sourceAdd(counters[keyPath: field], count)
  }
  private mutating func block(_ reason: NotebookHistoryReadiness.SourceBlockerReason, _ count: UInt64 = 1) throws {
    guard count > 0 else { return }
    counts[reason] = try NotebookHistoryReadiness.sourceAdd(counts[reason] ?? 0, count)
    totalBlockers = try NotebookHistoryReadiness.sourceAdd(totalBlockers, count)
  }
  private mutating func device(_ id: UUID) throws {
    if !endpointIDs.contains(id) {
      if endpointIDs.count < 64 { endpointIDs.insert(id) }
      else { try bump(\.endpointOverflowRows); try block(.endpointOverflow) }
    }
    if scope.endpoint(for: id) == nil { try bump(\.thirdDeviceRows); try block(.thirdDevice) }
  }
  private mutating func generation(_ source: NotebookReplicationSource) throws {
    try device(source.deviceID)
    if let endpoint = scope.endpoint(for: source.deviceID), endpoint.journalGeneration != source.generation {
      try bump(\.historicalGenerationRows)
    }
  }
  mutating func control(_ cut: NotebookReplicaInventoryCut, accountScopeHash: String?) throws {
    if cut.cloud.status == .invalid { try block(.invalidCloudControl) }
    if cut.cloud.enabled == true, let account = cut.cloud.account,
      NotebookHistoryFleetObservation.accountScope(account) != accountScopeHash { try block(.cloudAccountScopeMismatch) }
  }
  mutating func physical(_ value: NotebookHistoryReadinessMetadata) throws {
    try bump(\.acceptedTransactions); try bump(\.receiptOccurrences, by: UInt64(value.receiptCount))
    try bump(\.incompletePhysical, by: UInt64(value.incompletePhysicalCount))
    try bump(\.unknownSourceOriginals, by: UInt64(value.unknownSourceOriginalCount))
    try bump(\.missingOriginalRoots, by: UInt64(value.missingSourceOriginalRootCount))
    try block(.incompletePhysical, UInt64(value.incompletePhysicalCount))
    try block(.unknownSourceOriginal, UInt64(value.unknownSourceOriginalCount))
    try block(.missingOriginalRoot, UInt64(value.missingSourceOriginalRootCount))
  }
  mutating func endpoint(_ value: NotebookReplicaEndpointObservation) throws {
    try bump(\.endpointRows)
    switch value {
    case .incoming(let source, _), .firstReceived(_, let source, _, _), .snapshotCoverage(let source, _):
      try generation(source)
    case .outgoing(let id, _): try device(id)
    case .admittedGeneration(let id, let value):
      try generation(.init(deviceID: id, generation: value))
      if let endpoint = scope.endpoint(for: id), endpoint.journalGeneration != value { try block(.currentPeerGenerationMismatch) }
    case .retirement(let receipt):
      try device(receipt.peerID); try bump(\.retirementRows)
      if endpointIDs.contains(receipt.peerID) { retirements.append(receipt) }
    }
  }
  mutating func pending(_ value: NotebookReplicaCloudPendingObservation, accountScopeHash expected: String?) throws {
    try bump(\.cloudPendingRows); try block(.pendingCloud)
    let account: String
    switch value {
    case .export(let name, _, _, _, _, _, _), .outbox(let name, _, _, _, _, _), .chunk(let name, _, _, _, _): account = name
    case .incoming(let name, _, let source, _, _, _): account = name; try generation(source)
    }
    if let expected, NotebookHistoryFleetObservation.accountScope(account) != expected {
      try bump(\.foreignPendingAccountRows); try block(.foreignPendingAccount)
    }
  }
  mutating func fleet(_ value: NotebookHistoryFleetObservation) throws -> NotebookHistoryControl.Metadata {
    if value.directoryStatus != .verified { try block(.directoryUnavailable) }
    if !scope.endpoints.allSatisfy({ endpoint in value.directoryDevices.contains {
      $0.identity.deviceID == endpoint.identity.deviceID && $0.identity.workspaceID == scope.workspaceID
    } }) { try block(.directoryMembershipMissing) }
    if !value.workspaceEnrolled { try block(.workspaceUnenrolled) }
    if value.workspaceDeleted { try block(.workspaceDeleted) }
    if value.accountScopeHash == nil || value.accountScopeHash != value.directoryAccountScopeHash { try block(.accountScopeMismatch) }
    let saved = value.savedCredentials.first { $0.id == scope.credentialID }
    let directory = value.directoryCredentials.first { $0.id == scope.credentialID }
    if saved == nil || directory == nil || saved != directory { try block(.credentialScopeMismatch) }
    var digest = NotebookHistorySourceDigest("notebook.history-readiness.fleet.v1")
    let header: JSONValue = .object(["local": try .encode(value.local),
      "accountScopeHash": value.accountScopeHash.map(JSONValue.string) ?? .null,
      "directoryAccountScopeHash": value.directoryAccountScopeHash.map(JSONValue.string) ?? .null,
      "directoryStatus": .string(value.directoryStatus.rawValue), "workspaceEnrolled": .bool(value.workspaceEnrolled),
      "workspaceDeleted": .bool(value.workspaceDeleted)])
    try digest.record("header", header); try device(value.local.deviceID)
    for row in value.directoryDevices { try digest.record("directory-device", row); try device(row.identity.deviceID) }
    for row in value.directoryCredentials {
      try digest.record("directory-credential", row); try device(row.first); try device(row.second)
    }
    for row in value.savedCredentials {
      try digest.record("saved-credential", row); try device(row.first); try device(row.second)
    }
    for id in value.blockedDevices { try digest.record("blocked-device", id); try device(id); try block(.suppressedDevice) }
    for id in value.locallyRetiredDevices { try digest.record("locally-suppressed-device", id); try device(id); try block(.suppressedDevice) }
    for id in value.configuredRelayDevices { try digest.record("relay-device", id); try device(id) }
    for row in value.connections {
      try digest.record("connection", row)
      if let peer = row.peer {
        try device(peer.deviceID)
        if let endpoint = scope.endpoint(for: peer.deviceID), endpoint.identity != peer {
          try block(.peerScopeMismatch)
        }
      } else { try block(.unknownPeer) }
      if row.hasStorageCallback || row.pendingOffers > 0 || row.pendingIncoming > 0
        || row.pendingAcknowledgements > 0 || row.pendingBlobRequests > 0 { try block(.unjoinedTransport) }
    }
    return digest.row(count: 1)
  }
}

/// Only the current typed entry is encoded; no endpoint/history array is kept
/// for a later hash. Length framing and section tags distinguish every row.
private struct NotebookHistorySourceDigest {
  private var digest = SHA256()
  private var byteCount: UInt64 = 0
  init(_ domain: String) { digest.update(data: Data((domain + "\u{0}").utf8)); byteCount = UInt64(domain.utf8.count + 1) }
  mutating func record<Value: Encodable>(_ role: String, _ value: Value) throws {
    try Task.checkCancellation()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= 1_024 * 1_024 else { throw NotebookTransportError.resourceLimit }
    try frame(Data(role.utf8)); try frame(data)
  }
  private mutating func frame(_ bytes: Data) throws {
    byteCount = try NotebookHistoryReadiness.sourceAdd(byteCount, UInt64(bytes.count) + 8)
    var size = UInt64(bytes.count).bigEndian
    withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
    digest.update(data: bytes)
  }
  func row(count: UInt64) -> NotebookHistoryControl.Metadata {
    .init(hash: digest.finalize().map { String(format: "%02x", $0) }.joined(), count: count, byteCount: byteCount)
  }
}
