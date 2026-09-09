import Foundation
import NotebookCore

/// A durable-change notification reads the current scene and a bounded history
/// page. It never merges a partial scene back into the authoritative store.
struct NotebookDiskRefresh: Sendable {
  let scene: NotebookSceneState
  let actions: [CollaborationReceipt]
  let contexts: SharedContextSnapshot
  let delivery: [DeviceActionReceipt]

  static func prepare(store: NotebookStore, presence: SessionPresence,
    receivingDeviceID: UUID?, pinnedElements: [UUID: [String]] = [:], pinnedItems: [UUID: [UUID]] = [:]) throws -> Self {
    if let receivingDeviceID {
      let actions = try store.collaborationActions(afterID: nil, limit: 64)
      let delivered = try store.deviceActionReceipts(actionIDs: actions.map(\.id))
      for action in actions where !delivered.contains(where: { $0.id == action.id && $0.revisions == action.revisions }) {
        try store.saveDeviceActionReceipt(.init(id: action.id, deviceID: receivingDeviceID, revisions: action.revisions))
      }
    }
    return try store.readTransaction { store in
      let actions = try store.collaborationActions(afterID: nil, limit: 64)
      return try Self(scene: NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport,
        pinnedElements: pinnedElements, pinnedItems: pinnedItems),
        actions: actions, contexts: store.sharedContexts(contextID: nil, limit: 64),
        delivery: store.deviceActionReceipts(actionIDs: actions.map(\.id)))
    }
  }
}
