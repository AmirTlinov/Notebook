import Foundation
import NotebookCore

/// A durable-change notification reads the current scene and a bounded history
/// page. It never merges a partial scene back into the authoritative store.
struct NotebookDiskRefresh: Sendable {
  let scene: NotebookSceneState
  let sceneIndex: WorkspaceSceneIndex
  let actions: [NotebookActionReadModel]
  let contexts: SharedContextDirectory
  let feedback: [NotebookAgentFeedbackChange]
  let attention: [NotebookAgentFeedbackChange.Subject]?
  let delivery: [DeviceActionReceipt]

  static func prepare(store: NotebookStore, presence: SessionPresence,
    receivingDeviceID: UUID?, pinnedElements: [UUID: [String]] = [:], pinnedItems: [UUID: [UUID]] = [:],
    preparedPages: [UUID] = [], feedbackKnown: Set<UUID>? = nil, feedbackTracked: Set<UUID> = [],
    attentionReferences: [CollaborationReference] = [], historyActor: UUID? = nil,
    reusing previousIndex: WorkspaceSceneIndex? = nil) throws -> Self {
    if let receivingDeviceID {
      try store.acknowledgeReceivedActions(deviceID: receivingDeviceID)
    }
    return try store.readTransaction { store in
      let actions = try store.recentActionPhases(limit: 64)
      let attention: [NotebookAgentFeedbackChange.Subject]?
      do { attention = try store.agentAttentionSubjects(attentionReferences) }
      catch let error as CollaborationError where error.code == "source_conflict" { attention = nil }
      let scene = try NotebookSceneState.read(store:store,presence:presence,viewport:presence.viewport,
        pinnedElements:pinnedElements,pinnedItems:pinnedItems,preparedPages:preparedPages,historyActor:historyActor)
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
      // This immutable projection is already on the read worker. Derive its
      // geometry here, not through another UI/background/UI round trip after
      // publishing the content that needs that geometry to become visible.
      let sizes = scene.paperSizes.merging(scene.documents.mapValues(\.paperSize)) { _, live in live }
      let index = previousIndex.flatMap {
        $0.represents(workspace: scene.workspace, hierarchy: scene.hierarchy, paperSizes: sizes) ? $0 : nil
      } ?? WorkspaceSceneIndex(workspace: scene.workspace, hierarchy: scene.hierarchy, paperSizes: sizes)
      return try Self(scene:scene, sceneIndex: index,
        actions: actions,
        contexts: store.sharedContexts(contextID: nil, limit: 64),
        feedback: try feedbackKnown.map { known in try store.agentFeedbackChanges(actions.filter { !known.contains($0.id) || feedbackTracked.contains($0.id) },elementsInScene:elementsInScene) } ?? [],
        attention: attention, delivery: store.deviceActionReceipts(actionIDs: actions.map(\.id)))
    }
  }
}
