import Foundation
import NotebookCore

/// A durable-change notification reads the current scene and a bounded history
/// page. It never merges a partial scene back into the authoritative store.
struct NotebookDiskRefresh: Sendable {
  let scene: NotebookSceneState
  let actions: [NotebookActionReadModel]
  let contexts: SharedContextDirectory
  let feedback: [NotebookAgentFeedbackChange]
  let attention: [NotebookAgentFeedbackChange.Subject]?
  let delivery: [DeviceActionReceipt]

  static func prepare(store: NotebookStore, presence: SessionPresence,
    receivingDeviceID: UUID?, pinnedElements: [UUID: [String]] = [:], pinnedItems: [UUID: [UUID]] = [:],
    preparedPages: [UUID] = [], feedbackKnown: Set<UUID>? = nil, feedbackTracked: Set<UUID> = [],
    attentionReferences: [CollaborationReference] = []) throws -> Self {
    if let receivingDeviceID {
      try store.acknowledgeReceivedActions(deviceID: receivingDeviceID)
    }
    return try store.readTransaction { store in
      let actions = try store.actionReadModels(limit: 64)
      let attention: [NotebookAgentFeedbackChange.Subject]?
      do { attention = try store.agentAttentionSubjects(attentionReferences) }
      catch let error as CollaborationError where error.code == "source_conflict" { attention = nil }
      let scene = try NotebookSceneState.read(store:store,presence:presence,viewport:presence.viewport,
        pinnedElements:pinnedElements,pinnedItems:pinnedItems,preparedPages:preparedPages)
      var elementsInScene: [String: [String]] = [:]
      for node in scene.hierarchy.boards {
        for element in node.board.elements {
          guard let owner = element.surface.ownerID else { continue }
          let target = CollaborationTarget(kind:element.surface.kind == .cover ? .cover : .board,id:owner)
          elementsInScene[target.key,default:[]].append(element.id)
        }
      }
      for (id,page) in scene.pages { elementsInScene[CollaborationTarget(kind:.page,id:id).key] = page.elements.map(\.id) }
      for (id,document) in scene.documents { elementsInScene[CollaborationTarget(kind:.document,id:id).key] = document.blocks.map(\.id) }
      return try Self(scene:scene,
        actions: actions,
        contexts: store.sharedContexts(contextID: nil, limit: 64),
        feedback: try feedbackKnown.map { known in try store.agentFeedbackChanges(actions.filter { !known.contains($0.id) || feedbackTracked.contains($0.id) },elementsInScene:elementsInScene) } ?? [],
        attention: attention, delivery: store.deviceActionReceipts(actionIDs: actions.map(\.id)))
    }
  }
}
