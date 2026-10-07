import Combine
import Foundation
import NotebookCore

/// Finite witnesses of scenes already sent to a panel. It waits for owner
/// events and borrows a short read cut only to validate the addressed scene.
@MainActor
final class NotebookPanelObservation {
  private struct Scene: Sendable {
    let checkpoint: NotebookPanelCheckpoint
    let requestID: UUID
    let metadata: NotebookPanelMetadata
    let pixels: ScenePixelDependencies?
    let leafRasters: [SceneLeafRasterWitness]
    var leafChanged = false
  }
  @MainActor private final class WaitSignal {
    let checkpointID: UUID
    var generation: UInt64 = 0
    var timedOut = false
    var continuation: CheckedContinuation<Void, Never>?
    init(checkpointID: UUID) { self.checkpointID = checkpointID }
    func wake() {
      generation &+= 1
      resume()
    }
    func expire() {
      timedOut = true
      resume()
    }
    private func resume() {
      let pending = continuation; continuation = nil
      pending?.resume()
    }
  }

  private weak var model: NotebookAppModel?
  private let epoch = UUID()
  private let waitDuration: Duration
  private var scenes: [UUID: Scene] = [:]
  private var order: [UUID] = []
  private var signals: [UUID: WaitSignal] = [:]
  private var jobs: [UUID: Task<JSONValue, any Error>] = [:]
  private var rasterObserver: AnyCancellable?
  private var stopped = false
  var waitingCount: Int { signals.count }

  init(model: NotebookAppModel, waitDuration: Duration = .seconds(25)) {
    self.model = model; self.waitDuration = waitDuration
    let publicationKey = SceneRenderResources.leafRasterPublicationKey
    rasterObserver = NotificationCenter.default.publisher(for: SceneRenderResources.didPublishLeafRaster)
      .sink { [weak self] notification in
        guard let sender = notification.object as? SceneRenderResources,
          let publication = notification.userInfo?[publicationKey] as? SceneLeafRasterPublication else { return }
        MainActor.assumeIsolated {
          guard sender === SceneRenderResources.shared else { return }
          self?.leafPublished(publication)
        }
      }
  }

  func publish(_ prepared: NotebookPanelPreparedScene, requestID: UUID) throws -> JSONValue {
    guard !stopped, prepared.leafRasterCollector.isCurrent,
      SceneRenderResources.shared.leafRastersAreCurrent(prepared.leafRasterCollector.witnesses) else {
      throw NotebookStorageError.transactionConflict
    }
    let metadata = prepared.metadata
    let checkpoint = NotebookPanelCheckpoint(id: UUID(), epoch: epoch,
      readCursor: String(metadata.readCursor), changeCursor: String(metadata.changeCursor))
    scenes[checkpoint.id] = .init(checkpoint: checkpoint, requestID: requestID,
      metadata: metadata, pixels: prepared.pixels, leafRasters: prepared.leafRasterCollector.witnesses)
    order.append(checkpoint.id)
    var expired: Set<UUID> = []
    while order.count > 16 {
      let id = order.removeFirst(); scenes.removeValue(forKey: id); expired.insert(id)
    }
    prepared.leafRasterCollector.close()
    for signal in signals.values where expired.contains(signal.checkpointID) { signal.wake() }
    return prepared.snapshot.setting("checkpoint", try .encode(checkpoint))
  }

  /// No scene preparation or mutation takes place on the unchanged path.
  func unchanged(requestID: UUID, workspaceID: UUID, target: CollaborationTarget,
    cursor: String) throws -> JSONValue? {
    guard let scene = order.reversed().compactMap({ scenes[$0] }).first(where: {
      $0.requestID == requestID && $0.metadata.workspaceID == workspaceID && $0.metadata.target == target
        && $0.checkpoint.readCursor == cursor && !$0.leafChanged
    }), SceneRenderResources.shared.leafRastersAreCurrent(scene.leafRasters) else { return nil }
    return .object(["workspaceID": try .encode(workspaceID), "target": try .encode(target),
      "cursor": .string(cursor), "unchanged": .bool(true), "checkpoint": try .encode(scene.checkpoint)])
  }

  func contentDidCommit() { for signal in signals.values { signal.wake() } }

  private func leafPublished(_ publication: SceneLeafRasterPublication) {
    guard !stopped else { return }
    var changed: Set<UUID> = []
    for id in order where scenes[id]?.leafChanged == false
      && scenes[id]?.leafRasters.contains(where: { $0.isAffected(by: publication) }) == true {
      scenes[id]?.leafChanged = true; changed.insert(id)
    }
    for signal in signals.values where changed.contains(signal.checkpointID) { signal.wake() }
  }

  func changes(_ request: NotebookPanelChangesRequest) async throws -> JSONValue {
    try request.validated()
    guard !stopped, let model, model.permitsExternalWork else { throw CancellationError() }
    guard jobs.count < 16 else { throw CollaborationError("ipc_busy", "Notebook уже обслуживает 16 ожидающих панелей.") }
    let id = UUID()
    let job = Task { @MainActor in try await self.waitForChanges(request, id: id, model: model) }
    jobs[id] = job
    defer { jobs.removeValue(forKey: id) }
    return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
  }

  private func waitForChanges(_ request: NotebookPanelChangesRequest, id: UUID,
    model: NotebookAppModel) async throws -> JSONValue {
    try Task.checkCancellation()
    let signal = WaitSignal(checkpointID: request.checkpoint.id)
    signals[id] = signal // Registration precedes the first read or suspension.
    let duration = waitDuration
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: duration) } catch { return }
      signal.expire()
    }
    defer { deadline.cancel(); signals.removeValue(forKey: id) }
    while true {
      try Task.checkCancellation()
      guard !stopped, model.permitsExternalWork else { throw CancellationError() }
      guard request.checkpoint.epoch == epoch, let scene = scenes[request.checkpoint.id],
        scene.checkpoint == request.checkpoint, scene.metadata.workspaceID == request.workspaceID,
        scene.metadata.target == request.target else { return try response(request, changed: true, reset: true) }
      if scene.leafChanged { return try response(request, changed: true) }
      let generation = signal.generation
      let actor = model.actorID
      let current: Bool
      do {
        current = try await model.readCommandCut { cut in
          let metadata = try cut.readPanelMetadata(workspaceID: request.workspaceID, target: request.target, actor: actor)
          guard metadata.hasSameScene(as: scene.metadata) else { return false }
          return try scene.pixels?.isCurrent(cut) != false
        }
      } catch let error as CollaborationError where error.code == "target_missing" {
        try Task.checkCancellation()
        guard !stopped, model.permitsExternalWork else { throw CancellationError() }
        return try response(request, changed: true)
      }
      try Task.checkCancellation()
      guard !stopped, model.permitsExternalWork else { throw CancellationError() }
      guard let retained = scenes[request.checkpoint.id] else { return try response(request, changed: true, reset: true) }
      if !current || retained.leafChanged || !SceneRenderResources.shared.leafRastersAreCurrent(scene.leafRasters) {
        return try response(request, changed: true)
      }
      // An event during the read remains latched until another fresh cut has
      // validated it. There is no gap between this guard and continuation install.
      if signal.timedOut { return try response(request, changed: generation != signal.generation) }
      if generation != signal.generation { continue }
      await withTaskCancellationHandler {
        await withCheckedContinuation { signal.continuation = $0 }
      } onCancel: {
        Task { @MainActor in signal.wake() }
      }
    }
  }

  private func response(_ request: NotebookPanelChangesRequest, changed: Bool, reset: Bool = false) throws -> JSONValue {
    var fields: [String: JSONValue] = ["workspaceID": try .encode(request.workspaceID), "target": try .encode(request.target),
      "checkpoint": try .encode(request.checkpoint), "changed": .bool(changed)]
    if reset { fields["reset"] = .bool(true) }
    return .object(fields)
  }

  func stop() async {
    guard !stopped else { return }
    stopped = true; rasterObserver?.cancel(); rasterObserver = nil
    let pending = Array(jobs.values)
    for job in pending { job.cancel() }
    for signal in signals.values { signal.wake() }
    for job in pending { _ = try? await job.value }
    scenes.removeAll(); order.removeAll()
  }
}
