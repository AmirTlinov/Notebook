import NotebookCore
import SwiftUI

/// One finite description accounts for all board projections in this frame.
/// A child portal consumes the root's remaining budget, never another full one.
struct WorkspaceSceneFrame {
  let rootBoardID: UUID
  let worksets: [UUID: WorkspaceSceneWorkset]
  let covers: [UUID: WorkspaceSceneWorkset]
  let primitiveCount: Int
  let visitedNodes: Int
  let budget: Int

  func workset(boardID: UUID) -> WorkspaceSceneWorkset { worksets[boardID] ?? .empty }

  init(index: WorkspaceSceneIndex, presence: SessionPresence,
    portalCamera: (UUID) -> BoardPortalCamera?, pinned: Set<WorkspaceSpatialID> = [],
    budget: Int = WorkspaceSceneIndex.detailLimit) {
    var pinned = pinned
    if let id = presence.focusedItemID { pinned.insert(.item(id)) }
    precondition(budget > pinned.count)
    rootBoardID = presence.boardID
    self.budget = budget
    struct Pending {
      let presence: SessionPresence
      let pixelScale: Double
      let passes: Int
    }
    var sets: [UUID: WorkspaceSceneWorkset] = [:]
    var covers: [UUID: WorkspaceSceneWorkset] = [:]
    var queue = [Pending(presence: presence, pixelScale: presence.camera.scale,
      passes: WorkspaceSceneProjection.portalPasses)]
    var remaining = budget
    var visits = 0
    var cursor = 0
    while cursor < queue.count, remaining > 0 {
      let next = queue[cursor]
      cursor += 1
      guard sets[next.presence.boardID] == nil else { continue }
      let pins = next.presence.boardID == rootBoardID ? pinned : []
      let peers = queue.count - cursor + 1
      let available = max(1, remaining / peers - pins.count)
      var workset = index.workset(presence: next.presence, pinned: pins,
        limit: available, pixelScale: next.pixelScale)
      visits += workset.visitedNodes
      // Keep capacity for the real descendants already visible in this query.
      // Re-querying is bounded by this frame, not by the archive's source count.
      if workset.items.contains(where: { ($0.item.kind == .board && next.passes > 0)
        || index.hasCoverElements(itemID: $0.id, boardID: next.presence.boardID) }), available > 2 {
        workset = index.workset(presence: next.presence, pinned: pins,
          limit: max(1, available / 2), pixelScale: next.pixelScale)
        visits += workset.visitedNodes
      }
      let used = workset.items.count + workset.elements.count + workset.aggregates.count
      guard used <= remaining else { continue }
      remaining -= used
      sets[next.presence.boardID] = workset
      let protectedCovers = Set(pins.compactMap { id -> UUID? in
        switch id {
        case .item(let itemID): return itemID
        case .element(let elementID):
          let surface = index.element(id: elementID, boardID: next.presence.boardID)?.surface
          return surface?.kind == .cover ? surface?.ownerID : nil
        }
      })
      let coverItems = workset.items.filter { index.hasCoverElements(itemID: $0.id, boardID: next.presence.boardID) }
        .sorted {
          let left = protectedCovers.contains($0.id), right = protectedCovers.contains($1.id)
          return left == right ? $0.zIndex < $1.zIndex : left
        }
      for (offset, item) in coverItems.enumerated() where remaining > 0 {
        let coverPins = pins.filter { id in
          guard case .element(let elementID) = id else { return false }
          return index.element(id: elementID, boardID: next.presence.boardID)?.surface == .cover(item.id)
        }
        let available = max(1, remaining / (coverItems.count - offset + queue.count - cursor + 1) - coverPins.count)
        let cover = index.coverWorkset(item: item, presence: next.presence,
          pixelScale: next.pixelScale, limit: available, pinned: coverPins)
        let used = cover.elements.count + cover.aggregates.count
        guard used <= remaining else { continue }
        covers[item.id] = cover
        visits += cover.visitedNodes
        remaining -= used
      }
      guard next.passes > 0,
        WorkspaceSceneProjection.showsPortal(pixelScale: next.pixelScale, remainingPasses: next.passes)
      else { continue }
      for item in workset.items where item.item.kind == .board {
        guard WorkspaceSceneProjection.mountsContent(of: item, in: next.presence) else { continue }
        let camera = BoardPortalProjection.entryCamera(portalCamera: portalCamera(item.id) ?? .init(),
          viewport: presence.viewport)
        let viewport = BoardPortalProjection.renderViewport(viewport: presence.viewport)
        let childScale = next.pixelScale * camera.scale / BoardPortalProjection.fillScale(viewport: presence.viewport)
        queue.append(.init(presence: .init(boardID: item.id, mode: .board, camera: camera, viewport: viewport),
          pixelScale: childScale, passes: next.passes - 1))
      }
    }
    worksets = sets
    self.covers = covers
    primitiveCount = budget - remaining
    visitedNodes = visits
  }
}

private struct WorkspaceSceneFrameKey: EnvironmentKey {
  static let defaultValue: WorkspaceSceneFrame? = nil
}
extension EnvironmentValues {
  var workspaceSceneFrame: WorkspaceSceneFrame? {
    get { self[WorkspaceSceneFrameKey.self] }
    set { self[WorkspaceSceneFrameKey.self] = newValue }
  }
}
