import Foundation
import NotebookCore

extension NotebookHistoryReadiness {
  /// The admitted native owner adds account and connection evidence to Core's
  /// finite SQL observation. Exhaustive comparison remains a sealed phase.
  func observeInventory(_ command: NotebookCommand, runtime: NotebookWorkspaceRuntime) async throws -> JSONValue {
    guard command.command == .read, let query = command.queries?.first,
      command.queries?.count == 1, query.kind == .replicaInventory else {
      throw CollaborationError("invalid_replica_query", "Наблюдение реплики требует одного отдельного запроса.")
    }
    let request = try NotebookReadCommand(command), initialPhase = phase
    let fleetWitness = try await runtime.captureHistoryFleet()
    let fleet = fleetWitness.observation, actor = runtime.actorID
    let observation = try await runtime.observeHistorySource { cut in
      (try cut.handle(request), try cut.replicaInventoryCut())
    }
    try fleetWitness.requireCurrent()
    guard phase == initialPhase, fleet.local.workspaceID == observation.value.1.workspaceID,
      fleet.local.deviceID == actor else {
      throw CollaborationError("stale_history_readiness", "Граница наблюдения реплики изменилась.")
    }
    var native: [String: JSONValue] = ["readerLifetimeID": .string(observation.connectionLifetimeID.uuidString),
      "fleet": try fleet.projection(), "applicationBuild": .string(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")]
    switch phase {
    case .open: native["phase"] = .string("open")
    case .draining(let request), .sealed(let request, _):
      native["phase"] = .string(phase == .draining(request) ? "draining" : "sealed")
      native["requestID"] = .string(request.id.uuidString)
      native["declaredDevices"] = .array(request.devices.sorted { $0.uuidString < $1.uuidString }
        .map { .string($0.uuidString) })
    case .resuming(let request):
      native["phase"] = .string("resuming")
      native["requestID"] = .string(request.id.uuidString)
    }
    let response = observation.value.0
    if command.readSnapshots == true, let snapshot = response.arrayValues.first {
      guard response.arrayValues.count == 1, let data = snapshot["data"] else {
        throw NotebookStorageError.corruptRecord("replica observation snapshot")
      }
      return .array([snapshot.setting("data", data.setting("native", .object(native)))])
    }
    guard let value = response["values"]?.arrayValues.first,
      response["values"]?.arrayValues.count == 1 else {
      throw NotebookStorageError.corruptRecord("replica observation values")
    }
    return response.setting("values", .array([value.setting("native", .object(native))]))
  }
}
