import NotebookCore
import SwiftUI

/// One finite description accounts for all board projections in this frame.
/// A child portal consumes the root's remaining budget, never another full one.
struct WorkspaceSceneFrame {
  static let maximumReturnPrimitives = 24
  let index: WorkspaceSceneIndex
  let rootBoardID: UUID
  let returnBoardID: UUID?
  let worksets: [UUID: WorkspaceSceneWorkset]
  let covers: [UUID: WorkspaceSceneWorkset]
  let presences: [UUID: SessionPresence]
  let pixelScales: [UUID: Double]
  let primitiveCount: Int
  let visitedNodes: Int
  let budget: Int

  /// Pixels may cover the next viewport before its addressed SQL window has
  /// arrived. Reusing those pixels must not keep the old hit-test/live owners.
  struct SourceIdentity: Equatable {
    let generation: UUID
    let rootBoardID: UUID
    let boards: [UUID: [WorkspaceSpatialID]]
    let covers: [UUID: [WorkspaceSpatialID]]
  }
  var sourceIdentity: SourceIdentity {
    func ids(_ workset: WorkspaceSceneWorkset) -> [WorkspaceSpatialID] {
      workset.items.map { .item($0.id) } + workset.elements.map { .element($0.id) }
    }
    return .init(generation: index.generationID, rootBoardID: rootBoardID,
      boards: worksets.mapValues(ids), covers: covers.mapValues(ids))
  }

  func workset(boardID: UUID) -> WorkspaceSceneWorkset { worksets[boardID] ?? .empty }

  init(index: WorkspaceSceneIndex, presence: SessionPresence,
    portalCamera: (UUID) -> BoardPortalCamera?, pinned: Set<WorkspaceSpatialID> = [],
    budget: Int = WorkspaceSceneIndex.detailLimit, returnPresence: SessionPresence? = nil) {
    self.index = index
    var pinned = pinned
    if let id = presence.focusedItemID { pinned.insert(.item(id)) }
    precondition(budget > pinned.count)
    rootBoardID = presence.boardID
    returnBoardID = returnPresence?.boardID
    self.budget = budget
    struct Pending {
      let presence: SessionPresence
      let pixelScale: Double
      let passes: Int
    }
    var sets: [UUID: WorkspaceSceneWorkset] = [:]
    var covers: [UUID: WorkspaceSceneWorkset] = [:]
    var presences: [UUID: SessionPresence] = [:]
    var pixelScales: [UUID: Double] = [:]
    var queue = [Pending(presence: presence, pixelScale: presence.camera.scale,
      passes: WorkspaceSceneProjection.portalPasses)]
    if let returnPresence {
      precondition(returnPresence.boardID != presence.boardID)
      queue.append(.init(presence: returnPresence, pixelScale: returnPresence.camera.scale, passes: 0))
    }
    var remaining = budget
    var visits = 0
    var cursor = 0
    while cursor < queue.count, remaining > 0 {
      let next = queue[cursor]
      cursor += 1
      guard sets[next.presence.boardID] == nil else { continue }
      let isReturn = next.presence.boardID == returnBoardID
      // The return portal is the aperture of the already shown child, never a
      // flattened replacement. Its one parent window shares this frame's cap.
      let pins: Set<WorkspaceSpatialID> = next.presence.boardID == rootBoardID ? pinned
        : (isReturn ? [.item(rootBoardID)] : [])
      let peers = queue.count - cursor + 1
      let returnBudget = min(Self.maximumReturnPrimitives, max(1, budget / 4))
      let reservedReturn = !isReturn && returnBoardID.map({ sets[$0] == nil }) == true ? returnBudget : 0
      let allowance = isReturn ? min(returnBudget, remaining) : max(0, remaining - reservedReturn)
      guard allowance > pins.count else { continue }
      let available = max(1, min(allowance, remaining / peers) - pins.count)
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
      guard used <= allowance else { continue }
      remaining -= used
      var returnRemaining = isReturn ? max(0, returnBudget - used) : max(0, remaining - reservedReturn)
      sets[next.presence.boardID] = workset
      presences[next.presence.boardID] = next.presence
      pixelScales[next.presence.boardID] = next.pixelScale
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
      for (offset, item) in coverItems.enumerated() where remaining > 0 && returnRemaining > 0 {
        let coverPins = pins.filter { id in
          guard case .element(let elementID) = id else { return false }
          return index.element(id: elementID, boardID: next.presence.boardID)?.surface == .cover(item.id)
        }
        let available = max(1, min(remaining, returnRemaining) / (coverItems.count - offset + queue.count - cursor + 1) - coverPins.count)
        let cover = index.coverWorkset(item: item, presence: next.presence,
          pixelScale: next.pixelScale, limit: available, pinned: coverPins)
        let used = cover.elements.count + cover.aggregates.count
        guard used <= remaining, used <= returnRemaining else { continue }
        covers[item.id] = cover
        visits += cover.visitedNodes
        remaining -= used
        returnRemaining -= used
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
    self.presences = presences; self.pixelScales = pixelScales
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
