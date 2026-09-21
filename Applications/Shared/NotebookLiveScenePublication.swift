import Foundation
import NotebookCore

extension WorkspaceSceneProjection {
  /// Both the prepared index and the live model project a stack through this
  /// formula. An accepted placement does not wait for a new raster generation.
  static func renderedItem(_ item: WorkspaceItem, geometry: WorkspaceItemGeometry,
    center: WorldPoint, zIndex: Double, stack: WorkspaceItemStack?,
    presence: SessionPresence) -> RenderedWorkspaceItem? {
    var center = center
    if let stack {
      if presence.mode != .board, let focused = presence.focusedItemID,
        stack.itemIDs.contains(focused), focused != item.id { return nil }
      center = WorkspaceItemStackPresentation.boardCenter(of: item.id, in: stack,
        cameraScale: presence.camera.scale, viewport: presence.viewport) ?? center
    }
    return .init(item: item, geometry: geometry, center: center,
      zIndex: zIndex, stackID: stack?.id)
  }
}

extension NotebookAppModel {
  func presentedGraphicGraph(boardID: UUID, cohort: SceneCompositionCohort, preview: Bool = true) -> NotebookGraphicGraph {
    guard let captured = cohort.frame.index.capturedHierarchy.board(boardID) else { return .init([]) }
    let retained=preview ? retainedGraphicGraph(includingGroups:false) { .spatial(boardID:boardID,elementID:$0) } : nil
    let groups=cohort.plan.groupPoses.filter { $0.key.boardID == boardID }.values.reduce(into:[String:NotebookElementPlacement.Source]()) { result,plane in
      result.merge(plane) { first,_ in first }
    }
    let graph = (retained ?? presentedBoard(captured,boardID:boardID,cohort:cohort).graphicGraph()).projecting(placements:groups)
    guard preview else { return graph }
    let working = workingGraphics.filter {
      ($0.surface == .board(boardID) || ($0.surface.kind == .cover && $0.surface.ownerID.flatMap { cohort.frame.index.ownerBoard(itemID:$0) } == boardID))
        && ($0.publicationCursor.map { cohort.plan.revision < $0 } ?? true)
    }
    // A retained insertion is a live host, not a frozen copy of its geometry.
    // SQL may already contain subsequent edits while the original cohort waits.
    let admitted = working.isEmpty ? nil : boardHierarchy?.board(boardID)?.graphicGraph()
    let nodes = working.map { object in
      if object.accepted, let cursor = object.publicationCursor, sceneContentCursor >= cursor,
        let current = admitted?.nodes[object.id], current.surface == object.surface { return current }
      return object.node
    }
    let combined = graph.projecting(adding:nodes)
    return projectingGraphicCommands(combined,publishedGroups:groups) { .spatial(boardID: boardID, elementID: $0) }
  }
  /// The cohort admits physical hosts and excludes their pixels from its tiles.
  /// Its immutable geometry is not another owner of subsequent accepted input.
  /// This bounded projection changes only those already admitted hosts.
  func presentedWorkset(cohort: SceneCompositionCohort, boardID: UUID,
    presence: SessionPresence) -> WorkspaceSceneWorkset {
    let admitted = cohort.frame.workset(boardID: boardID)
    return .init(items: admitted.items.compactMap { presentedItem($0, cohort: cohort, presence: presence) },
      elements: admitted.elements.compactMap { presentedElement($0, boardID: boardID, cohort: cohort) },
      query: admitted.query, generationID: admitted.generationID)
  }

  func presentedCoverElements(cohort: SceneCompositionCohort, boardID: UUID, itemID: UUID) -> [SpatialElement] {
    guard !isItemBeingDeleted(itemID) else { return [] }
    return (cohort.frame.covers[itemID]?.elements ?? []).compactMap {
      presentedElement($0, boardID: boardID, cohort: cohort)
    }
  }

  func presentedElement(_ reference: EditableElementReference, cohort: SceneCompositionCohort) -> SpatialElement? {
    guard case .spatial(let boardID, let id) = reference,
      let admitted = cohort.frame.index.element(id: id, boardID: boardID),
      let plane = elementPlane(admitted, boardID: boardID),
      cohort.plan.allowsLive(.element(id), in: plane) else { return nil }
    return presentedElement(admitted, boardID: boardID, cohort: cohort)
  }

  func presentedItem(id: UUID, cohort: SceneCompositionCohort,
    presence: SessionPresence) -> RenderedWorkspaceItem? {
    guard let admitted = cohort.frame.workset(boardID: presence.boardID).items.first(where: { $0.id == id }) else { return nil }
    return presentedItem(admitted, cohort: cohort, presence: presence)
  }

  func presentedWorkspace(cohort: SceneCompositionCohort) -> WorkspaceIndex {
    let captured = cohort.frame.index.capturedWorkspace
    let liveItems = Set(cohort.plan.liveOwners.compactMap { owner -> UUID? in
      if case .item(let id) = owner.id { return id }; return nil
    })
    return captured.projecting(items: captured.items.map { item in
      liveItems.contains(item.id) ? (workspace?.item(id: item.id) ?? item) : item
    })
  }

  /// A pointing contact freezes the same admitted sources as the body. This
  /// projection is never written back or used to admit additional hosts.
  func presentedHierarchy(cohort: SceneCompositionCohort) -> BoardHierarchy {
    let captured = cohort.frame.index.capturedHierarchy
    let nodes = captured.boards.map { node in
      BoardNode(id: node.id, board: presentedBoard(node.board, boardID: node.id, cohort: cohort),
        portalCamera: node.portalCamera, portalStamp: node.portalStamp)
    }
    return .init(rootBoardID: captured.rootBoardID, boards: nodes, stamp: captured.stamp)
  }

  func presentedBoard(_ captured: BoardDocument, boardID: UUID,
    cohort: SceneCompositionCohort) -> BoardDocument {
    let current = boardHierarchy?.board(boardID) ?? captured
    let liveItems = Set(cohort.plan.liveOwners.compactMap { owner -> UUID? in
      guard owner.plane == .board(boardID), case .item(let id) = owner.id else { return nil }; return id
    })
    let admitted = cohort.frame.workset(boardID: boardID).items
    let placements = captured.placements.compactMap { original -> WorkspacePlacement? in
      guard liveItems.contains(original.id) else { return original }
      // A canonical tombstone remains a source even though its body is gone.
      if let accepted = current.placements.first(where: { $0.id == original.id }), accepted.pose == nil { return accepted }
      guard !isItemBeingDeleted(original.id) else { return nil }
      if let owner = boardHierarchy?.ownerBoardID(of: original.id), owner != boardID { return nil }
      if let accepted = current.placements.first(where: { $0.id == original.id }) { return accepted }
      guard let item = admitted.first(where: { $0.id == original.id }) else { return original }
      let bounds = WorkspaceSpatialBounds(origin: item.center.offsetBy(
        x: -item.geometry.width / 2, y: -item.geometry.height / 2),
        width: item.geometry.width, height: item.geometry.height)
      return sceneConfirmsAbsence(in: boardID, bounds: bounds) ? nil : original
    }
    // A bounded scene cannot prove that its loaded members are the whole.
    // Group bases therefore follow the cohort even when every loaded child
    // is live; the published pose projects both live bodies and passive tiles.
    let elements = captured.elements.compactMap {
      presentedElement($0,boardID:boardID,cohort:cohort)
    }
    // Retain passive intent sources rather than claiming unseen new peers. A
    // whole-area capture separately checks that this describes shown pixels.
    let header = cohort.plan.presentedOwners.contains { $0.plane.boardID == boardID } ? current : captured
    return header.projecting(placements: placements, elements: elements)
  }

  private func presentedItem(_ admitted: RenderedWorkspaceItem, cohort: SceneCompositionCohort,
    presence: SessionPresence) -> RenderedWorkspaceItem? {
    guard !isItemBeingDeleted(admitted.id) else { return nil }
    guard cohort.plan.allowsLive(.item(admitted.id), in: .board(presence.boardID)) else { return admitted }
    if let owner = boardHierarchy?.ownerBoardID(of: admitted.id), owner != presence.boardID { return nil }
    guard let board = boardHierarchy?.board(presence.boardID) else { return admitted }
    if let placement = board.placements.first(where: { $0.id == admitted.id }), placement.pose == nil { return nil }
    let item = workspace?.item(id: admitted.id) ?? admitted.item
    if let placement = board.placement(of: admitted.id) {
      return WorkspaceSceneProjection.renderedItem(item, geometry: admitted.geometry,
        center: placement.center, zIndex: Double(placement.zIndex), stack: nil, presence: presence)
    }
    if let stack = board.stack(containing: admitted.id), let offset = stack.itemIDs.firstIndex(of: admitted.id) {
      return WorkspaceSceneProjection.renderedItem(item, geometry: admitted.geometry,
        center: stack.center, zIndex: Double(stack.zIndex) + Double(offset) / 100, stack: stack, presence: presence)
    }
    let bounds = WorkspaceSpatialBounds(origin: admitted.center.offsetBy(
      x: -admitted.geometry.width / 2, y: -admitted.geometry.height / 2),
      width: admitted.geometry.width, height: admitted.geometry.height)
    return sceneConfirmsAbsence(in: presence.boardID, bounds: bounds) ? nil : admitted
  }

  private func presentedElement(_ admitted: SpatialElement, boardID: UUID,
    cohort: SceneCompositionCohort) -> SpatialElement? {
    guard let owner = admitted.surface.ownerID, !isItemBeingDeleted(owner),
      let plane = elementPlane(admitted, boardID: boardID) else { return nil }
    guard cohort.plan.allowsLive(.element(admitted.id), in: plane) else { return admitted }
    if admitted.surface.kind == .cover,
      let actual = boardHierarchy?.ownerBoardID(of: owner), actual != boardID { return nil }
    guard let board = boardHierarchy?.board(boardID) else { return admitted }
    if let current = board.elements.first(where: { $0.id == admitted.id }) {
      // Membership is installed with its complete source cut. A current local
      // frame cannot be placed under an older cohort's parent chain.
      if current.parentID != admitted.parentID { return admitted }
      if let graphic = current.graphic {
        guard graphic.showsGeometry else { return nil }
        // Only a claim on measured ink needs arbitration against other shapes.
        // Ordinary geometry cannot lose to another member: rebuilding the
        // board's claim set here made a projected whole quadratic per lookup.
        if !graphic.sourceInkIDs.isEmpty, !board.graphicPresentation.geometryIDs.contains(current.id) { return nil }
      }
      // The same local ID on a different physical surface is not this host.
      guard current.surface == admitted.surface,current.kind == admitted.kind else { return nil }
      let ref=EditableElementReference.spatial(boardID:boardID,elementID:current.id)
      if let draft=elementCommandDrafts[ref] { return draft.projecting(current) }
      return current
    }
    if board.hasRemovedElement(id: admitted.id) || missingSceneElements[boardID]?.contains(admitted.id) == true { return nil }
    if admitted.surface.kind == .cover {
      return completeSceneCoverOwners.contains(owner) ? nil : admitted
    }
    guard let origin = admitted.worldOrigin else { return nil }
    let bounds = WorkspaceSpatialBounds(origin: origin.offsetBy(x: admitted.frame.x, y: admitted.frame.y),
      width: admitted.frame.width, height: admitted.frame.height)
    return sceneConfirmsAbsence(in: boardID, bounds: bounds) ? nil : admitted
  }

  private func sceneConfirmsAbsence(in boardID: UUID, bounds: WorkspaceSpatialBounds) -> Bool {
    !truncatedSceneBoards.contains(boardID) && sceneCoverage[boardID]?.intersects(bounds) == true
  }

  private func elementPlane(_ element: SpatialElement, boardID: UUID) -> SceneCompositionPlane? {
    switch element.surface.kind {
    case .board: element.surface.ownerID == boardID ? .board(boardID) : nil
    case .cover: element.surface.ownerID.map { .cover(boardID: boardID, itemID: $0) }
    case .page, .codeFragment: nil
    }
  }
}
