import Foundation
import NotebookCore

extension NotebookHistoryReadiness {
  @MainActor
  final class Coordination {
    struct FirstCause {
      let originDeviceID: UUID
      let originGeneration: UUID?
      let code: NotebookHistoryControl.Refusal.Code
      let reason: NotebookHistoryControl.Refusal.Reason
      let stage: NotebookHistoryControl.Refusal.Stage
      let sourceSection: NotebookHistoryControl.Refusal.SourceSection?
      let stream: NotebookHistoryControl.Stream?
      let transactionID: UUID?
      let identifier: String?

      func wire(origin: NotebookReplicationSource) -> NotebookHistoryControl.Refusal {
        .init(origin: origin, code: code, reason: reason, stage: stage,
          sourceSection: sourceSection, stream: stream, transactionID: transactionID, identifier: identifier)
      }
      func value() -> JSONValue {
        var result: [String: JSONValue] = ["originDeviceID": .string(originDeviceID.uuidString),
          "code": .string(code.rawValue), "reason": .string(reason.rawValue), "stage": .string(stage.rawValue)]
        if let sourceSection { result["sourceSection"] = .string(sourceSection.rawValue) }
        if let originGeneration { result["originJournalGeneration"] = .string(originGeneration.uuidString) }
        if let stream { result["stream"] = .string(stream.rawValue) }
        if let transactionID { result["transactionID"] = .string(transactionID.uuidString) }
        if let identifier { result["identifier"] = .string(identifier) }
        return .object(result)
      }
    }
    let id: UUID
    let devices: Set<UUID>
    let initiatedHere: Bool
    let localDeviceID: UUID
    var preparation: NotebookHistoryControlPreparation?
    var request: Request?
    var scope: NotebookHistoryControlScope?
    var candidate: NotebookHistoryControlScope?
    var connectionID: UUID?
    var state = "queued"
    var stage = NotebookHistoryControl.Refusal.Stage.preparing
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    private(set) var failure: Error?
    private(set) var firstCause: FirstCause?
    var report: JSONValue?
    var localRootsSent = false
    var remote: [NotebookHistoryControl.Stream: NotebookHistoryStreamAccumulator] = [:]
    var confirmed: [NotebookHistoryControl.Stream: NotebookHistoryConfirmedStream] = [:]
    private var progress: UInt64 = 0
    private var waiting: CheckedContinuation<Void, Error>?

    init(id: UUID, devices: Set<UUID>, initiatedHere: Bool, localDeviceID: UUID) {
      self.id = id; self.devices = devices; self.initiatedHere = initiatedHere; self.localDeviceID = localDeviceID
    }

    func recordFailure(_ error: Error, code: NotebookHistoryControl.Refusal.Code? = nil,
      reason: NotebookHistoryControl.Refusal.Reason? = nil,
      stage: NotebookHistoryControl.Refusal.Stage? = nil, stream: NotebookHistoryControl.Stream? = nil) {
      guard failure == nil else { return }
      failure = error; report = nil
      if let refusal = error as? NotebookHistoryControl.Refusal {
        firstCause = .init(originDeviceID: refusal.origin.deviceID, originGeneration: refusal.origin.generation,
          code: refusal.code, reason: refusal.reason,
          stage: refusal.stage, sourceSection: refusal.sourceSection, stream: refusal.stream,
          transactionID: refusal.transactionID, identifier: refusal.identifier)
      } else {
        let source = error as? NotebookHistoryReadiness.SourceError
        let safe = Self.classify(source?.underlying ?? error)
        let sourceCode: NotebookHistoryControl.Refusal.Code?
        if let source, source.underlying == nil {
          switch source.reason {
          case .resourceLimit: sourceCode = .resourceLimit
          case .invalidStoredData: sourceCode = .invalidStoredData
          case .missingBlob: sourceCode = .missingBlob
          case .blobHashMismatch: sourceCode = .blobHashMismatch
          case .unexpectedFailure, .encodingFailure: sourceCode = .observationFailed
          default: sourceCode = .staleCut
          }
        } else { sourceCode = nil }
        firstCause = .init(originDeviceID: localDeviceID,
          originGeneration: preparation?.endpoint(for: localDeviceID)?.journalGeneration,
          code: code ?? sourceCode ?? safe.0,
          reason: reason ?? source?.reason ?? safe.1, stage: source == nil ? (stage ?? self.stage) : .reading,
          sourceSection: source?.section, stream: stream, transactionID: source?.transactionID,
          identifier: source?.identifier ?? safe.2)
      }
      signal()
    }

    private static func classify(_ error: Error) -> (NotebookHistoryControl.Refusal.Code,
      NotebookHistoryControl.Refusal.Reason, String?) {
      if error is CancellationError { return (.cancelled, .cancelled, nil) }
      if let error = error as? NotebookStorageError {
        switch error {
        case .limitExceeded(let identifier):
          return (.resourceLimit, .resourceLimit, NotebookHistoryControl.Refusal.isValidIdentifier(identifier) ? identifier : nil)
        case .blobMissing: return (.missingBlob, .missingBlob, nil)
        case .blobHashMismatch: return (.blobHashMismatch, .blobHashMismatch, nil)
        default: return (.invalidStoredData, .invalidStoredData, nil)
        }
      }
      if let error = error as? NotebookTransportError {
        switch error {
        case .resourceLimit: return (.resourceLimit, .resourceLimit, nil)
        case .historyCutStale: return (.staleCut, .controlChanged, nil)
        case .disconnected: return (.transportFailure, .connectionChanged, nil)
        case .invalidFrame, .invalidSequence, .identityMismatch: return (.invalidControl, .invalidControl, nil)
        default: return (.transportFailure, .transportFailure, nil)
        }
      }
      if let error = error as? CollaborationError {
        let identifier = NotebookHistoryControl.Refusal.isValidIdentifier(error.code) ? error.code : nil
        switch error.code {
        case "stale_history_readiness", "read_cut_expired": return (.staleCut, .controlChanged, identifier)
        case "owner_unavailable", "workspace_changed": return (.ownerUnavailable, .sourceUnavailable, identifier)
        case "history_observation_timeout": return (.observationTimeout, .observationTimeout, identifier)
        default: return (.observationFailed, .unexpectedFailure, identifier)
        }
      }
      if error is NotebookAccountError { return (.accountChanged, .directoryChanged, nil) }
      if error is EncodingError { return (.observationFailed, .encodingFailure, nil) }
      return (.observationFailed, .unexpectedFailure, nil)
    }

    func signal() {
      progress &+= 1
      let completion = waiting; waiting = nil
      if let failure { completion?.resume(throwing: failure) }
      else { completion?.resume() }
    }

    var progressGeneration: UInt64 { progress }

    func wait(after generation: UInt64) async throws {
      try Task.checkCancellation()
      if let failure { throw failure }
      guard progress == generation else { return }
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
          if let failure { completion.resume(throwing: failure) }
          else if progress != generation { completion.resume() }
          else if waiting != nil { completion.resume(throwing: NotebookTransportError.historyReadinessPending) }
          else { waiting = completion }
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          guard let self else { return }
          recordFailure(CancellationError())
        }
      }
    }

    func value() -> JSONValue {
      var fields: [String: JSONValue] = ["requestID": .string(id.uuidString), "state": .string(state),
        "deviceIDs": .array(devices.sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) }),
        "formatTransitionAuthorized": .bool(false), "stage": .string(stage.rawValue),
        "localRootsSent": .bool(localRootsSent),
        "peerStreams": .array(NotebookHistoryStreamAccumulator.streams.map { stream in
          let observed = remote[stream]
          return .object(["stream": .string(stream.rawValue), "pageCount": .string(String(observed?.pageCount ?? 0)),
            "entryCount": .string(String(observed?.entryCount ?? 0)),
            "complete": .bool(observed?.isComplete ?? false), "confirmed": .bool(confirmed[stream] != nil)])
        })]
      // A locally compared report is provisional until both ordered resume
      // frames join. A peer refusal removes it before terminal publication.
      if state == "completed", failure == nil, let report { fields["report"] = report }
      if let firstCause {
        fields["firstCause"] = firstCause.value()
        fields["error"] = .object(["code": .string(firstCause.code.rawValue),
          "message": .string("History observation refused: \(firstCause.reason.rawValue).")])
      }
      return .object(fields)
    }
  }

  func handle(_ input: NotebookHistoryReadinessRequest, model: NotebookAppModel) throws -> JSONValue {
    try input.validate()
    if let current = coordination, current.id == input.requestID {
      if input.operation == .start, Set(input.deviceIDs ?? []) != current.devices {
        throw CollaborationError("history_request_conflict", "Исходный requestID уже связан с другим составом устройств.")
      }
      if input.operation == .cancel { current.task?.cancel() }
      return current.value()
    }
    guard input.operation == .start else {
      throw CollaborationError("history_request_missing", "Запрос сверки истории не найден.")
    }
    guard phase == .open, coordination?.task == nil else { throw NotebookTransportError.historyReadinessPending }
    let current = Coordination(id: input.requestID, devices: Set(input.deviceIDs!), initiatedHere: true,
      localDeviceID: model.actorID)
    coordination = current
    launch(current, model: model)
    return current.value()
  }

  func receive(_ control: NotebookHistoryControl, peerID: UUID, connectionID: UUID,
    model: NotebookAppModel) {
    do {
      try control.validate()
      if case .prepare(let preparation) = control, coordination?.id != preparation.requestID {
        guard phase == .open, coordination?.task == nil,
          preparation.endpoint(for: model.actorID) != nil, preparation.endpoint(for: peerID) != nil else {
          throw NotebookTransportError.historyReadinessPending
        }
        let sync = try model.historyTransportOwner()
        guard sync.historyBoundaryObservation(for: peerID)?.connectionID == connectionID else {
          throw NotebookTransportError.historyCutStale
        }
        // Admit on this selected session before the directory read suspends.
        // Its next ordered prepared frame belongs to this same native request.
        try sync.admitHistoryPreparation(preparation)
        let current = Coordination(id: preparation.requestID,
          devices: Set(preparation.endpoints.map { $0.identity.deviceID }), initiatedHere: false,
          localDeviceID: model.actorID)
        current.preparation = preparation; current.connectionID = connectionID
        coordination = current; launch(current, model: model)
        return
      }
      guard let current = coordination, current.id == control.requestID, current.task != nil,
        current.devices.contains(peerID), current.connectionID == nil || current.connectionID == connectionID else {
        throw NotebookTransportError.historyCutStale
      }
      switch control {
      case .prepare: break
      case .prepared: break // Session retains only the actual latest advertised head.
      case .request(let scope):
        guard current.preparation == scope.preparation else { throw NotebookTransportError.identityMismatch }
        current.candidate = scope
      case .page(let page):
        if current.failure != nil { return }
        guard current.scope != nil, var accumulator = current.remote[page.stream] else {
          throw NotebookTransportError.historyNotDrained
        }
        try accumulator.append(page); current.remote[page.stream] = accumulator
      case .root(let root):
        if current.failure != nil { return }
        guard let accumulator = current.remote[root.stream], current.confirmed[root.stream] == nil else {
          throw NotebookTransportError.historyCutStale
        }
        do { current.confirmed[root.stream] = try accumulator.confirm(root) }
        catch {
          current.recordFailure(error, code: .comparisonFailed, reason: .rootMismatch,
            stage: .comparing, stream: root.stream)
          throw error
        }
      case .stale(_, let reason):
        let mapped: NotebookHistoryControl.Refusal.Reason
        switch reason {
        case .lateContent: mapped = .lateContent
        case .changedPrefix: mapped = .prefixChanged
        case .connectionChanged: mapped = .connectionChanged
        case .admissionChanged: mapped = .admissionChanged
        case .cancelled: mapped = .cancelled
        }
        current.recordFailure(NotebookTransportError.historyCutStale, reason: mapped)
      case .resume(_, let refusal):
        if let refusal {
          guard let endpoint = current.scope?.endpoint(for: peerID),
            refusal.origin == NotebookReplicationSource(deviceID: peerID, generation: endpoint.journalGeneration) else {
            throw NotebookTransportError.identityMismatch
          }
          current.recordFailure(refusal)
          // Source checks this same first failure between finite reads/pages.
          // Cancelling its TLS-credit await would retire the connection.
          return
        }
        if current.failure != nil { return }
        guard current.state == "resuming" || (current.localRootsSent
          && current.confirmed.count == NotebookHistoryStreamAccumulator.streams.count) else {
          current.recordFailure(NotebookTransportError.historyCutStale, reason: .peerResumedEarly)
          throw NotebookTransportError.historyCutStale
        }
      case .quiesced, .resumed: break
      }
      current.signal()
    } catch {
      guard let current = coordination, current.id == control.requestID, current.task != nil else { return }
      current.recordFailure(error)
    }
  }

  func deliveryProgress(peerID: UUID, connectionID: UUID) {
    guard let current = coordination, current.task != nil, current.devices.contains(peerID),
      current.connectionID == connectionID else { return }
    current.signal()
  }

  func deliveryDisconnected(peerID: UUID, connectionID: UUID) {
    guard let current = coordination, current.task != nil, current.devices.contains(peerID),
      current.connectionID == connectionID else { return }
    current.recordFailure(NotebookTransportError.disconnected)
  }

  func requireSourceCoordinationCurrent(requestID: UUID) throws {
    guard let current = coordination, current.id == requestID else { return }
    if let failure = current.failure { throw failure }
  }

  func stopAndJoin() async {
    let task = coordination?.task
    task?.cancel()
    await task?.value
  }

  private func launch(_ current: Coordination, model: NotebookAppModel) {
    current.task = Task { @MainActor [self, model] in
      do { try await run(current, model: model) }
      catch { current.recordFailure(error) }
      current.state = "resuming"
      current.stage = .resuming
      // Cancellation closes this observer, not any already accepted writer.
      let cleanup = Task { @MainActor in await self.resume(current, model: model) }
      await cleanup.value
      current.deadline?.cancel(); current.deadline = nil
      current.state = current.failure is CancellationError ? "cancelled" : current.failure == nil ? "completed" : "failed"
      current.task = nil; current.signal()
    }
    current.deadline = Task { @MainActor [weak current] in
      do { try await Task.sleep(for: .seconds(300)) } catch { return }
      guard let current, current.task != nil else { return }
      current.recordFailure(CollaborationError("history_observation_timeout", "Сверка не достигла общей границы за отведённое окно."))
      current.task?.cancel()
    }
  }

  private func run(_ current: Coordination, model: NotebookAppModel) async throws {
    let sync = try model.historyTransportOwner()
    let fleet = try await model.observeHistoryFleet()
    guard current.devices.count == 2, current.devices.contains(model.actorID),
      let peerID = current.devices.first(where: { $0 != model.actorID }),
      let connection = fleet.connections.first(where: { $0.selected && $0.ready && $0.peer?.deviceID == peerID }),
      let peer = connection.peer, let credential = connection.credentialID,
      let localGeneration = connection.localJournalGeneration,
      let remoteGeneration = connection.remoteJournalGeneration,
      let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != "unknown" else {
      throw NotebookTransportError.historyNotDrained
    }
    let preparation = NotebookHistoryControlPreparation(requestID: current.id,
      workspaceID: fleet.local.workspaceID, credentialID: credential, applicationBuild: build,
      endpoints: [.init(identity: fleet.local, journalGeneration: localGeneration),
        .init(identity: peer, journalGeneration: remoteGeneration)])
    guard current.preparation == nil || current.preparation == preparation,
      current.connectionID == nil || current.connectionID == connection.connectionID else {
      throw NotebookTransportError.identityMismatch
    }
    current.preparation = preparation; current.connectionID = connection.connectionID
    try sync.admitHistoryPreparation(preparation)
    if current.initiatedHere { try sync.proposeHistoryPreparation(preparation) }
    current.state = "draining"
    current.stage = .draining
    current.request = try await model.beginHistoryReadiness(preparation)
    current.stage = .negotiating
    let scope = try await negotiate(current, model: model, sync: sync, peerID: peerID)
    current.scope = scope
    let remoteSource = NotebookReplicationSource(deviceID: peerID, generation: remoteGeneration)
    for stream in NotebookHistoryStreamAccumulator.streams {
      current.remote[stream] = try .init(scope: scope, source: remoteSource, stream: stream)
    }
    current.state = "quiescing"
    current.stage = .quiescing
    try sync.admitHistoryControl(scope)
    try await sync.quiesceHistoryControl(scope)
    guard let request = current.request else { throw NotebookTransportError.historyCutStale }
    current.stage = .sealing
    let seal = try await model.sealHistoryWriter(request: request, scope: scope)
    let fleetWitness = try await model.captureHistoryFleet()
    current.state = "reading"
    current.stage = .reading
    let source = try await produceSource(model: model, request: request, scope: scope,
      fleetWitness: fleetWitness) { page in
        try await sync.sendHistoryControlAwaitingCredit(.page(page), scope: scope)
      }
    for root in source.roots {
      try requireSourceCoordinationCurrent(requestID: request.id)
      try await sync.sendHistoryControlAwaitingCredit(.root(root), scope: scope)
      try requireSourceCoordinationCurrent(requestID: request.id)
    }
    current.localRootsSent = true
    current.state = "comparing"
    current.stage = .comparing
    while current.confirmed.count != NotebookHistoryStreamAccumulator.streams.count {
      let progress = current.progressGeneration
      try await current.wait(after: progress)
    }
    try requireSourceCoordinationCurrent(requestID: request.id)
    guard model.ownsHistoryWriterSeal(request: request, seal: seal) else {
      current.recordFailure(NotebookTransportError.historyCutStale, reason: .writerSealChanged)
      throw NotebookTransportError.historyCutStale
    }
    guard sync.historyBoundaryObservation(for: peerID)?.isQuiescent == true else {
      current.recordFailure(NotebookTransportError.historyCutStale, reason: .controlChanged)
      throw NotebookTransportError.historyCutStale
    }
    try fleetWitness.requireCurrent()
    let final = try await model.observeHistorySource { try $0.replicaInventoryCut() }
    try requireSourceCoordinationCurrent(requestID: request.id)
    try fleetWitness.requireCurrent()
    guard let finalBoundary = sync.historyBoundaryObservation(for: peerID),
      finalBoundary.connectionID == current.connectionID, finalBoundary.isQuiescent else {
      current.recordFailure(NotebookTransportError.historyCutStale, reason: .controlChanged)
      throw NotebookTransportError.historyCutStale
    }
    guard final.connectionLifetimeID == source.readerLifetimeID else {
      current.recordFailure(NotebookTransportError.historyCutStale, reason: .readerChanged)
      throw NotebookTransportError.historyCutStale
    }
    guard final.value.controlObservation == source.controlObservation else {
      current.recordFailure(NotebookTransportError.historyCutStale, reason: .controlChanged)
      throw NotebookTransportError.historyCutStale
    }
    guard model.ownsHistoryWriterSeal(request: request, seal: seal) else {
      current.recordFailure(NotebookTransportError.historyCutStale, reason: .writerSealChanged)
      throw NotebookTransportError.historyCutStale
    }
    let sealedFleet = fleetWitness.observation
    guard let account = sealedFleet.accountScopeHash, account == sealedFleet.directoryAccountScopeHash,
      let key = sealedFleet.savedCredentials.first(where: { $0.id == scope.credentialID }),
      sealedFleet.directoryCredentials.contains(key) else { throw NotebookTransportError.identityMismatch }
    let remoteStreams = NotebookHistoryStreamAccumulator.streams.compactMap { current.confirmed[$0] }
    let joint: NotebookHistoryJointDigest
    do {
      joint = try NotebookHistoryJointDigest(scope: scope, accountScopeSHA256: account,
        keyScopeSHA256: key.scopeHash, streams: source.confirmedStreams + remoteStreams)
    } catch {
      current.recordFailure(error, code: .comparisonFailed, reason: .jointMismatch, stage: .comparing)
      throw error
    }
    try requireSourceCoordinationCurrent(requestID: request.id)
    let localBlockers = source.confirmedStreams.first(where: { $0.root.stream == .replicaControl })!.metadataCount
    let peerBlockers = remoteStreams.first(where: { $0.root.stream == .replicaControl })!.metadataCount
    let reportRoots: [JSONValue] = try joint.roots.map { root in
      .object(["requestID": .string(root.requestID.uuidString),
          "workspaceID": .string(root.workspaceID.uuidString), "source": try .encode(root.source),
          "stream": .string(root.stream.rawValue), "hash": .string(root.hash),
          "pageCount": .string(String(root.pageCount)), "entryCount": .string(String(root.entryCount))])
    }
    current.report = .object(["jointSHA256": .string(joint.hash),
      "acceptedAndPhysicalMetadataMatched": .bool(true), "local": try source.projection(),
      "peerBlockerCount": .string(String(peerBlockers)),
      "readyForNextSlice": .bool(localBlockers == 0 && peerBlockers == 0),
      "formatTransitionAuthorized": .bool(false), "roots": .array(reportRoots)])
  }

  private func negotiate(_ current: Coordination, model: NotebookAppModel, sync: NearbySync,
    peerID: UUID) async throws -> NotebookHistoryControlScope {
    guard let preparation = current.preparation else { throw NotebookTransportError.historyCutStale }
    while true {
      let progress = current.progressGeneration
      try Task.checkCancellation()
      if let failure = current.failure { throw failure }
      let source = try await model.observeHistorySource { try $0.replicaInventoryCut() }
      guard source.value.workspaceID == preparation.workspaceID,
        source.value.journalGeneration == preparation.endpoint(for: model.actorID)?.journalGeneration else {
        throw NotebookTransportError.historyCutStale
      }
      let prepared = NotebookHistoryControl.Prepared(requestID: current.id, workspaceID: preparation.workspaceID,
        source: .init(deviceID: model.actorID, generation: source.value.journalGeneration!),
        head: source.value.acceptedLocalPrefix, readRevision: source.value.readRevision)
      guard let boundary = sync.historyBoundaryObservation(for: peerID), boundary.connectionID == current.connectionID else {
        throw NotebookTransportError.historyCutStale
      }
      if boundary.localPrepared != prepared { try sync.sendHistoryPrepared(prepared, preparation: preparation) }
      if let remote = boundary.peerPrepared, boundary.pendingDurableWork == 0, !boundary.hasStorageCallback,
        boundary.peerAcceptedThrough == (prepared.head?.sequence ?? 0),
        boundary.incomingAcceptedThrough == (remote.head?.sequence ?? 0) {
        let scope = NotebookHistoryControlScope(requestID: current.id, workspaceID: preparation.workspaceID,
          credentialID: preparation.credentialID, applicationBuild: preparation.applicationBuild,
          endpoints: preparation.endpoints.map { .init(identity: $0.identity, journalGeneration: $0.journalGeneration,
            head: $0.identity.deviceID == model.actorID ? prepared.head : remote.head) })
        if current.initiatedHere {
          try sync.proposeHistoryControl(scope)
          return scope
        }
        if current.candidate == scope { return scope }
      }
      try await current.wait(after: progress)
    }
  }

  private func resume(_ current: Coordination, model: NotebookAppModel) async {
    let request: Request?
    switch phase {
    case .draining(let value), .sealed(let value, _), .resuming(let value): request = value.id == current.id ? value : nil
    case .open: request = nil
    }
    do {
      let sync = try model.historyTransportOwner()
      if let scope = current.scope, let request {
        if case .sealed = phase { try model.releaseHistoryWriter(request: request) }
        let refusal: NotebookHistoryControl.Refusal?
        if let first = current.firstCause, first.originDeviceID == model.actorID,
          let endpoint = scope.endpoint(for: model.actorID) {
          refusal = first.wire(origin: .init(deviceID: model.actorID, generation: endpoint.journalGeneration))
        } else { refusal = nil }
        do { try await sync.resumeHistoryControl(scope, refusal: refusal) }
        catch {
          guard await sync.stopAndDrain() else { throw error }
          await sync.start()
          throw error
        }
      } else if let preparation = current.preparation {
        try sync.resumeHistoryPreparation(preparation)
      }
    } catch { current.recordFailure(error) }
    do {
      if let request { try await model.finishHistoryReadiness(request) }
      else { await model.resumeHistoryPrograms() }
    } catch { current.recordFailure(error) }
  }
}
