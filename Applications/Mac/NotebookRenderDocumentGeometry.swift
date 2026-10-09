import Foundation
import NotebookCore

/// Canonical physical paper belongs to the requested image, without opening a
/// native scene or retaining its document bodies after this preparation.
enum NotebookRenderDocumentGeometry {
  @MainActor static func prepare(store: NotebookStore, presence: SessionPresence) async throws -> [UUID: WorkspaceItemGeometry] {
    guard presence.mode == .board || presence.mode == .cover else { return [:] }
    let reader = Task.detached(priority: .utility) {
      try store.readTransaction { store in
        var pending = [presence], visited = Set<UUID>(), documents: [DocumentDocument] = []
        while !pending.isEmpty, visited.count < 4 {
          let view = pending.removeFirst()
          guard visited.insert(view.boardID).inserted else { continue }
          let bounds = WorkspaceSpatialBounds(origin: view.camera.screenToWorld(.init(x: -256, y: -256), viewport: view.viewport),
            width: (view.viewport.x + 512) / view.camera.scale, height: (view.viewport.y + 512) / view.camera.scale)
          let window = try store.readSceneWindow(boardID: view.boardID, bounds: bounds, limit: 256,
            pinnedIDs: view.focusedItemID.map { [$0] } ?? [])
          guard !window.truncated else { throw SceneRenderError.resourceLimit }
          for item in window.items {
            if item.kind == .document { documents.append(try store.loadDocument(item.id)) }
            else if item.kind == .board, item.id == view.focusedItemID, view.openProgress > 0,
              pending.count + visited.count < 4, let node = try store.readBoardNodeHeader(item.id) {
              pending.append(.init(boardID: item.id, mode: .board,
                camera: BoardPortalProjection.entryCamera(portalCamera: node.portalCamera, viewport: BoardPortalProjection.viewport),
                viewport: BoardPortalProjection.viewport))
            }
          }
        }
        return documents
      }
    }
    let documents = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
    var result: [UUID: WorkspaceItemGeometry] = [:]
    for document in documents {
      try Task.checkCancellation()
      let page = presence.focusedItemID == document.id ? presence.documentPageIndex : 0
      let source = DocumentSourceSnapshot(document, store: store)
      let printed = try await source.printedSource(resources: SceneRenderResources.shared)
      withExtendedLifetime(printed) { result[document.id] = source.paper(on: page).geometry }
    }
    return result
  }
}
