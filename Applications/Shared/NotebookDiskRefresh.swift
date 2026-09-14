import Foundation
import NotebookCore

/// A durable-change notification reads the current scene and a bounded history
/// page. It never merges a partial scene back into the authoritative store.
struct NotebookDiskRefresh: Sendable {
  let scene: NotebookSceneState
  let actions: [NotebookActionReadModel]
  let contexts: SharedContextDirectory
  let delivery: [DeviceActionReceipt]

  static func prepare(store: NotebookStore, presence: SessionPresence,
    receivingDeviceID: UUID?, pinnedElements: [UUID: [String]] = [:], pinnedItems: [UUID: [UUID]] = [:],
    preparedPages: [UUID] = []) throws -> Self {
    if let receivingDeviceID {
      try store.acknowledgeReceivedActions(deviceID: receivingDeviceID)
    }
    return try store.readTransaction { store in
      let actions = try store.actionReadModels(limit: 64)
      return try Self(scene: NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport,
        pinnedElements: pinnedElements, pinnedItems: pinnedItems, preparedPages: preparedPages),
        actions: actions,
        contexts: store.sharedContexts(contextID: nil, limit: 64),
        delivery: store.deviceActionReceipts(actionIDs: actions.map(\.id)))
    }
  }
}
