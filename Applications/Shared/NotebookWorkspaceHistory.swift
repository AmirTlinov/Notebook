import Foundation
import NotebookCore

/// Coordination borrows the admitted runtime's original FIFO, reader and TLS
/// owners. A presentation supplies only its already accepted input boundary.
extension NotebookWorkspaceRuntime {
  func observeHistorySource<Value: Sendable>(
    _ operation: @escaping @Sendable (NotebookQueryCut) throws -> Value
  ) async throws -> NotebookCommandReader.Observation<Value> {
    guard historyHooks.isReady(), permitsExternalWork, let workspaceID = admittedWorkspaceID else {
      throw CollaborationError("owner_unavailable", "Читатель рабочего пространства ещё не готов.")
    }
    let fence = persistence.captureReadFence()
    try await fence.wait()
    guard permitsExternalWork, admittedWorkspaceID == workspaceID else {
      throw CollaborationError("workspace_changed", "Рабочее пространство изменилось.")
    }
    let observation = try await commandReader.observe(workspaceID: workspaceID, operation)
    try Task.checkCancellation()
    guard permitsExternalWork, admittedWorkspaceID == workspaceID else {
      throw CollaborationError("workspace_changed", "Рабочее пространство изменилось.")
    }
    return observation
  }

  func observeHistoryFleet() async throws -> NotebookHistoryFleetObservation {
    try await captureHistoryFleet().observation
  }

  func captureHistoryFleet() async throws -> NotebookHistoryFleetWitness {
    guard permitsExternalWork else { throw NotebookTransportError.disconnected }
    return try await connection.captureHistoryFleet()
  }

  func historyTransportOwner(resuming requestID: UUID? = nil) throws -> NearbySync {
    let isCurrentCleanup = requestID != nil && historyReadiness.coordination?.id == requestID
      && historyReadiness.coordination?.state == "resuming" && shutdownPhase == .closing
    guard (permitsExternalWork || isCurrentCleanup), connection.permitsTransportWork,
      let sync = connection.sync, admittedWorkspaceID == sync.identity.workspaceID else {
      throw CollaborationError("owner_unavailable", "Владелец доставки пространства недоступен.")
    }
    return sync
  }

  func beginHistoryReadiness(_ preparation: NotebookHistoryControlPreparation) async throws -> NotebookHistoryReadiness.Request {
    func isCurrent() -> Bool {
      historyHooks.isReady() && permitsAuthoredWork && historyReadinessLifecycleIsBusy?() != true
        && !awaitingAccountContent && admittedWorkspaceID == preparation.workspaceID
        && preparation.endpoint(for: actorID) != nil
    }
    guard isCurrent() else {
      throw CollaborationError("input_active", "Завершите текущее действие перед сверкой истории.")
    }
    // The native hook finishes accepted contacts before authored admission
    // closes. Its final check and begin below share one MainActor turn.
    try await historyHooks.prepare()
    guard isCurrent() else {
      throw CollaborationError("input_active", "Источник изменился при подготовке сверки; завершите текущее действие.")
    }
    let request = NotebookHistoryReadiness.Request(id: preparation.requestID,
      workspaceID: preparation.workspaceID, devices: Set(preparation.endpoints.map { $0.identity.deviceID }),
      acceptedGeneration: persistence.acceptedMutationGeneration)
    try historyReadiness.begin(request)
    try await connection.cloudSync?.pauseForHistory(request.id)
    await connection.accountConnection?.stop()
    guard await historyHooks.drain(request), historyReadiness.phase == .draining(request), permitsExternalWork,
      await persistence.flush() else {
      throw NotebookPersistenceQueue.Failure(message: "Принятая очередь ещё не сохранена; сверка истории остановлена.")
    }
    return request
  }

  func sealHistoryWriter(request: NotebookHistoryReadiness.Request, scope: NotebookHistoryControlScope) async throws -> UUID {
    guard historyReadiness.phase == .draining(request), permitsExternalWork,
      historyReadinessLifecycleIsBusy?() != true,
      let sync = connection.sync, let peer = scope.endpoints.first(where: { $0.identity.deviceID != actorID }),
      sync.historyBoundaryObservation(for: peer.identity.deviceID)?.isQuiescent == true,
      await persistence.flush(), historyReadinessLifecycleIsBusy?() != true else { throw NotebookTransportError.historyNotDrained }
    let actor = actorID, generation = persistence.acceptedMutationGeneration
    _ = try await observeHistorySource { cut in
      let metadata = try cut.replicaInventoryCut()
      guard let local = scope.endpoint(for: actor), local.journalGeneration == metadata.journalGeneration,
        local.head == metadata.acceptedLocalPrefix, metadata.workspaceID == scope.workspaceID else {
        throw NotebookTransportError.historyCutStale
      }
      for endpoint in scope.endpoints where endpoint.identity.deviceID != actor {
        if let head = endpoint.head, try !cut.hasAcceptedHistoryOccurrence(
          transactionID: head.transactionID, manifestHash: head.manifestHash) {
          throw NotebookTransportError.historyNotDrained
        }
      }
      return metadata
    }
    guard historyReadiness.phase == .draining(request),
      historyReadinessLifecycleIsBusy?() != true,
      let seal = persistence.sealWorkspaceSelection(expectedGeneration: generation) else {
      throw NotebookTransportError.historyNotDrained
    }
    do { try historyReadiness.seal(request, writerSeal: seal) }
    catch { persistence.finishWorkspaceSelection(seal); throw error }
    return seal
  }

  func ownsHistoryWriterSeal(request: NotebookHistoryReadiness.Request, seal: UUID) -> Bool {
    historyReadiness.phase == .sealed(request, writerSeal: seal)
      && persistence.ownsWorkspaceSelectionSeal(seal)
      && admittedWorkspaceID == request.workspaceID && permitsExternalWork
      && historyReadinessLifecycleIsBusy?() != true
  }

  func releaseHistoryWriter(request: NotebookHistoryReadiness.Request) throws {
    try historyReadiness.releaseWriterForResume(request) { persistence.finishWorkspaceSelection($0) }
  }

  func finishHistoryReadiness(_ request: NotebookHistoryReadiness.Request) async throws {
    try historyReadiness.finish(request) { persistence.finishWorkspaceSelection($0) }
    try await connection.cloudSync?.finishHistoryPause(request.id)
    guard permitsExternalWork else { return }
    connection.accountConnection?.start()
    await resumeHistoryPrograms()
  }

  func resumeHistoryPrograms() async {
    guard permitsAuthoredWork else { return }
    if let current = historyReadiness.coordination, current.task != nil, current.state != "resuming" { return }
    await historyHooks.resume()
  }
}
