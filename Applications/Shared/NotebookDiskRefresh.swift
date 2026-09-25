import Foundation
import NotebookCore

/// One requested slot retains its immutable body only for the lifetime of its
/// preparation. An unrelated publication can require a fresh SQL cut without
/// decoding that body again. History is checked anew in that same cut.
struct NotebookPagePreparation: Sendable {
  let position: NotebookPagePosition
  let page: PageDocument
  let revision: String
  let projection: WorkspaceIndex
  let undo: [PencilUndoHistory.Entry]
  let redo: [PencilUndoHistory.Entry]

  static func read(store: NotebookStore, itemID: UUID, index: Int, root: String,
    actor: UUID, reusing previous: Self?) throws -> Self {
    try Task.checkCancellation()
    return try store.readTransaction { store in
      let directory = try store.readNotebookPageDirectory(itemID: itemID, from: index,
        limit: 1, expectedVisibleRoot: root)
      guard let position = directory.pages.first?.position else { throw NotebookStorageError.transactionConflict }
      let id = position.pageID
      guard let revision = try store.pageSourceRevision(id) else { throw NotebookStorageError.transactionConflict }
      let page: PageDocument
      if let previous, previous.position.itemID == itemID, previous.position.index == index,
        previous.position.visibleRoot == root, previous.revision == revision {
        page = previous.page
      } else {
        page = try store.readNotebookPageWindow(itemID: itemID, pages: [.page(id)],
          expectedVisibleRoot: root).pages[0].document
      }
      // Membership causal fields live in the catalog, not the page digest.
      // Re-read this one-page witness even when its immutable body is reused.
      let projection = try store.workspaceProjection(items: [.notebook(id: itemID,
        title: directory.header.item.title, pageIDs: [id])], selectedItemID: itemID, selectedPageID: id)
      return try Self(position: position, page: page, revision: revision, projection: projection,
        undo: store.nativeHistory(domain: .page(id), actor: actor),
        redo: store.nativeRedoHistory(domain: .page(id), actor: actor))
    }
  }

  /// A write can finish while the body is decoding without first changing the
  /// model. Validate only addressed headers at the writer boundary, never move
  /// that expensive decode back onto the accepted-write queue.
  func isCurrent(store: NotebookStore, actor: UUID) throws -> Bool {
    try store.readTransaction { store in
      guard let current = try store.resolveNotebookPage(page.id, in: position.itemID,
        expectedVisibleRoot: position.visibleRoot), current.index == position.index,
        try store.pageSourceRevision(page.id) == revision else { return false }
      let witness = try store.workspaceProjection(items: projection.items,
        selectedItemID: position.itemID, selectedPageID: page.id)
      guard witness.collaboration == projection.collaboration else { return false }
      return try store.nativeHistory(domain: .page(page.id), actor: actor) == undo
        && store.nativeRedoHistory(domain: .page(page.id), actor: actor) == redo
    }
  }
}

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
    pinnedElements: [UUID: [String]] = [:], pinnedItems: [UUID: [UUID]] = [:],
    preparedPages: [UUID] = [], feedbackKnown: Set<UUID>? = nil, feedbackTracked: Set<UUID> = [],
    attentionReferences: [CollaborationReference] = [], historyActor: UUID? = nil, pinnedInkActionIDs: Set<UUID> = [],
    reusing previousIndex: WorkspaceSceneIndex? = nil, reusingPages: [UUID: PageDocument] = [:]) throws -> Self {
    return try store.readTransaction { store in
      let actions = try store.recentActionPhases(limit: 64)
      let attention: [NotebookAgentFeedbackChange.Subject]?
      do { attention = try store.agentAttentionSubjects(attentionReferences) }
      catch let error as CollaborationError where error.code == "source_conflict" { attention = nil }
      let scene = try NotebookSceneState.read(store:store,presence:presence,viewport:presence.viewport,
        pinnedElements:pinnedElements,pinnedItems:pinnedItems,preparedPages:preparedPages,historyActor:historyActor,
        pinnedInkActionIDs:pinnedInkActionIDs,reusingPages:reusingPages)
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
      let index = WorkspaceSceneIndex(workspace: scene.workspace, hierarchy: scene.hierarchy,
        paperSizes: sizes, reusing: previousIndex)
      return try Self(scene:scene, sceneIndex: index,
        actions: actions,
        contexts: store.sharedContexts(contextID: nil, limit: 64),
        feedback: try feedbackKnown.map { known in try store.agentFeedbackChanges(actions.filter { !known.contains($0.id) || feedbackTracked.contains($0.id) },elementsInScene:elementsInScene) } ?? [],
        attention: attention, delivery: store.deviceActionReceipts(actionIDs: actions.map(\.id)))
    }
  }
}

/// One serial read owner reuses an idle connection. The short writer fence is
/// acquired by the caller; all scene preparation then borrows a fresh WAL cut
/// without keeping accepted Pencil writes behind mesh/index/metadata work.
actor NotebookSceneReader {
  private var session: NotebookReadSession?
  init(store: NotebookStore) { session = NotebookReadSession(store: store) }
  /// Serialized behind active reads; retained models cannot reopen after quit.
  func close() { session = nil }
  func read<Value: Sendable>(_ operation: @Sendable (NotebookStore) throws -> Value) throws -> Value {
    guard let session else { throw CancellationError() }
    return try session.read(operation)
  }
}
