import Foundation

extension CollaborationReceipt {
  /// Identity of the saved effect, not a reconstruction of the raw request.
  /// The canonical receipt includes undo metadata even when both effects have
  /// no revised targets. Compute on the storage worker, never per camera frame.
  public func deliveryVersion() throws -> String {
    try collaborationHash(JSONValue.object(["domain": .string("notebook.action-delivery.v1"),
      "receipt": try .encode(self)]))
  }
}

extension DeviceActionReceipt {
  public func matches(_ action: CollaborationReceipt, version: String) -> Bool {
    id == action.id && actionVersion == version && revisions == action.revisions
  }
}

extension NotebookStore {
  /// The iPad acknowledges the exact immutable receipts read by this writer.
  /// A metadata-only undo still has a distinct version and gets a new arrival.
  public func acknowledgeReceivedActions(deviceID: UUID) throws {
    try commandTransaction(readAllowance: .agentCommand) {
      let actions = try actionReadModels(limit: 64)
      for action in actions {
        let version = action.actionVersion
        let file = "collaboration/delivery/" + action.id.uuidString.lowercased() + ".json"
        let previous = try storedValue(file)?.decode(DeviceActionReceipt.self)
        guard previous?.matches(action) != true else { continue }
        let receipt = DeviceActionReceipt(id: action.id, deviceID: deviceID,
          revisions: action.revisions, actionVersion: version)
        try publishRecords(writes: [file: try .encode(receipt)])
      }
    }
  }

  /// Called inside the current writer, including the replication writer.
  /// Legacy bytes can be retained as history; they never acquire a version.
  func resolvedDeviceActionReceipt(_ receipt: DeviceActionReceipt,
    previous: DeviceActionReceipt?) throws -> DeviceActionReceipt? {
    guard receipt.actionVersion != nil else {
      if previous?.actionVersion != nil { return previous }
      return previous?.merging(receipt) ?? receipt
    }
    let action = try actionReadModel(receipt.id)
    guard receipt.matches(action) else { return previous }
    return previous?.matches(action) == true ? previous!.merging(receipt) : receipt
  }
}
