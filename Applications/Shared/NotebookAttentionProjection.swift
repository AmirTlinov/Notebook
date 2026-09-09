import NotebookCore
import SwiftUI

/// References use owner-local points. This projection follows the same item
/// centers and stack fan as the visible scene, so moving an item moves its mark.
@MainActor
enum NotebookAttentionProjection {
  static func frame(_ reference: CollaborationReference, model: NotebookAppModel, presence: SessionPresence) -> CGRect? {
    guard let workspace = model.workspace, let index = model.sceneIndex else { return nil }
    var local = reference.region ?? PageRect(x:0,y:0,width:1,height:1)
    let target = reference.target
    if target.kind == .board {
      guard target.id == presence.boardID else { return nil }
      var origin = reference.worldOrigin ?? .zero
      if let id = reference.elementID {
        guard let element = index.element(id: id, boardID: presence.boardID),
          element.surface == .board(target.id) else { return nil }
        local = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
        origin = element.worldOrigin ?? .zero
      }
      let top = presence.camera.worldToScreen(origin.offsetBy(x:local.x,y:local.y),viewport:presence.viewport)
      return .init(x:top.x,y:top.y,width:max(8,local.width * presence.camera.scale),height:max(8,local.height * presence.camera.scale))
    }
    let itemID: UUID
    if target.kind == .page {
      guard let ownerID = index.pageOwner(pageID: target.id),
        workspace.selectedPageID == target.id, presence.mode == .page else { return nil }
      itemID = ownerID
      if let id = reference.elementID, let element = model.pages[target.id]?.elements.first(where: { $0.id == id }) { local = element.frame }
    } else {
      itemID = target.id
      if target.kind == .document {
        guard presence.mode == .document, presence.focusedItemID == itemID else { return nil }
        if let id = reference.elementID, let document = model.documents[itemID], let state = model.documentStates[itemID] {
          guard let region = DocumentRenderRegistry.shared.regions(document:document,state:state).first(where: { $0.id == id && $0.pageIndex == presence.documentPageIndex }) else { return nil }
          local = region.frame
        } else if let page = reference.pageIndex, page != presence.documentPageIndex { return nil }
      } else if target.kind == .cover {
        guard presence.mode == .board || presence.mode == .cover else { return nil }
        if let id = reference.elementID {
          guard let element = index.element(id: id, boardID: presence.boardID),
            element.surface == .cover(itemID) else { return nil }
          local = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
        }
      } else { return nil }
    }
    guard let rendered = index.renderedItem(id: itemID, presence: presence) else { return nil }
    let box = rendered.geometry.screenFrame(center:rendered.center,camera:presence.camera,viewport:presence.viewport)
    if reference.region == nil && reference.elementID == nil { local = .init(x:0,y:0,width:rendered.geometry.width,height:rendered.geometry.height) }
    return .init(x:box.x + local.x * presence.camera.scale,y:box.y + local.y * presence.camera.scale,
      width:max(8,local.width * presence.camera.scale),height:max(8,local.height * presence.camera.scale))
  }

  private struct CaptureSources {
    let index: WorkspaceSceneIndex
    let workset: WorkspaceSceneWorkset
    let workspace: WorkspaceIndex
    let hierarchy: BoardHierarchy
    let ink: SpatialInkJournal
    var pages: [UUID: PageDocument]
    var documents: [UUID: DocumentDocument]
    var states: [UUID: DocumentStateJournal]
    let selectedPageID: UUID?
  }

  static func capture(start: CGPoint, end: CGPoint, model: NotebookAppModel, presence: SessionPresence,
    cohort: SceneCompositionCohort, installedInk: [SurfaceID: SpatialInkInstalledSource]) -> NotebookAttentionSelection? {
    guard !model.scenePreparationPending, cohort.plan.presentations[.board(presence.boardID)] != nil else { return nil }
    let index = cohort.frame.index
    var sources = CaptureSources(index: index, workset: cohort.frame.workset(boardID: presence.boardID),
      workspace: index.capturedWorkspace, hierarchy: index.capturedHierarchy, ink: cohort.liveData.ink,
      pages: cohort.liveData.pages, documents: cohort.liveData.documents, states: cohort.liveData.states,
      selectedPageID: presence.notebookPageID ?? model.workspace?.selectedPageID)
    if let focused = presence.focusedItemID, cohort.plan.allowsLive(.item(focused), in: .board(presence.boardID)) {
      if presence.mode == .page, let id = sources.selectedPageID, let page = model.pages[id] {
        sources.pages[id] = page
      } else if presence.mode == .document, let document = model.documents[focused], let state = model.documentStates[focused] {
        guard DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: presence.documentPageIndex) else { return nil }
        sources.documents[focused] = document; sources.states[focused] = state
      }
    }
    let fragments = fragments(start: start, end: end, sources: sources, presence: presence)
    guard !fragments.isEmpty else { return nil }
    let visuals = NotebookFrozenVisualSources.capture(fragments: fragments, hierarchy: sources.hierarchy,
      pages: sources.pages, documents: sources.documents, states: sources.states)
    var requiredInk = Set<SurfaceID>()
    for fragment in fragments where fragment.elementID == nil {
      if fragment.target.kind == .board {
        requiredInk.insert(.board(fragment.target.id))
        let descendants = sources.hierarchy.descendantBoardIDs(including: fragment.target.id)
        for owner in cohort.plan.liveOwners where descendants.contains(owner.plane.boardID) {
          if case .item(let id) = owner.id { requiredInk.insert(.cover(id)) }
        }
      } else if fragment.target.kind == .cover,
        cohort.plan.allowsLive(.item(fragment.target.id), in: .board(fragment.target.boardID ?? presence.boardID)) {
        requiredInk.insert(.cover(fragment.target.id))
      }
    }
    return .init(fragments: fragments, workspace: sources.workspace, hierarchy: sources.hierarchy, ink: sources.ink,
      pages: sources.pages, documents: sources.documents, states: sources.states, visuals: visuals,
      referenceIdentities: cohort.liveData.referenceIdentities,
      installedInk: installedInk.filter { requiredInk.contains($0.key) }, requiredInk: requiredInk,
      inkBasis: cohort.liveData.referenceInkBasis)
  }

  private static func fragments(start: CGPoint, end: CGPoint, sources: CaptureSources, presence: SessionPresence) -> [NotebookAttentionSelection.Fragment] {
    let dragged = hypot(end.x - start.x, end.y - start.y) > 8
    guard presence.mode == .board, dragged else {
      return fragment(start: start, end: end, sources: sources, presence: presence, dragged: dragged).map { [$0] } ?? []
    }
    let selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    var result = fragment(start: start, end: end, sources: sources, presence: presence, dragged: dragged).map { [$0] } ?? []
    for item in sources.workset.items {
      let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
      let intersection = selection.intersection(CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
      guard !intersection.isNull, intersection.width > 0, intersection.height > 0,
        !result.contains(where: { $0.target.id == item.id }), result.count < 32 else { continue }
      if let reference = fragment(start: .init(x: intersection.minX, y: intersection.minY),
        end: .init(x: intersection.maxX, y: intersection.maxY), sources: sources, presence: presence, ownerID: item.id, dragged: dragged) {
        result.append(reference)
      }
    }
    return result
  }

  private static func fragment(start: CGPoint, end: CGPoint, sources: CaptureSources, presence: SessionPresence,
    ownerID: UUID? = nil, dragged: Bool) -> NotebookAttentionSelection.Fragment? {
    guard let board = sources.index.board(id: presence.boardID) else { return nil }
    // Clipping an area to a tiny owner intersection never turns the original
    // drag into a tap that authorizes the whole element or physical cover.
    let width = abs(end.x - start.x), height = abs(end.y - start.y)
    guard !dragged || (width > 0 && height > 0) else { return nil }
    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
      width: dragged ? width : max(1, width), height: dragged ? height : max(1, height))
    let admitted = sources.workset
    let items = ownerID.map { id in admitted.items.first(where: { $0.id == id }).map { [$0] } ?? [] } ?? admitted.items
    var target = CollaborationTarget(kind:.board,id:presence.boardID)
    var region: PageRect
    var origin: WorldPoint?
    var elementID: String?
    var pageIndex: Int?
    if let item = items.reversed().first(where: { item in
      if let ownerID { return item.id == ownerID }
      let frame = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      return CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height).contains(rect)
    }) {
      let box = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      region = .init(x:max(0,(rect.minX-box.x)/presence.camera.scale),y:max(0,(rect.minY-box.y)/presence.camera.scale),
        width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if presence.focusedItemID == item.id && presence.mode == .page, let pageID = sources.selectedPageID {
        target = .init(kind:.page,id:pageID)
        if !dragged, let element = sources.pages[pageID]?.elements.last(where: {
          CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)
            .contains(CGPoint(x: region.x, y: region.y))
        }) {
          elementID = element.id; region = element.frame
        }
      } else if presence.focusedItemID == item.id && presence.mode == .document,
        let document = sources.documents[item.id], let state = sources.states[item.id] {
        target = .init(kind:.document,id:item.id); pageIndex = presence.documentPageIndex
        if !dragged, let block = DocumentRenderRegistry.shared.regions(document: document, state: state).first(where: {
          $0.pageIndex == pageIndex && CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)
            .contains(CGPoint(x: region.x, y: region.y))
        }) {
          elementID = block.id; region = block.frame
        }
      } else {
        target = .init(kind:.cover,id:item.id,boardID:presence.boardID)
        if !dragged {
          if let element = board.elements.last(where: { $0.surface == .cover(item.id) && $0.frame.contains(.init(x:region.x,y:region.y)) }) {
            elementID = element.id
            region = .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
          }
          if elementID == nil { region = .init(x:0,y:0,width:item.geometry.width,height:item.geometry.height) }
        }
      }
    } else {
      origin = presence.camera.screenToWorld(.init(x:rect.minX,y:rect.minY),viewport:presence.viewport)
      region = .init(x:0,y:0,width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if !dragged, let pointOrigin = origin {
        for element in admitted.elements.reversed() where element.surface == .board(presence.boardID) {
          let delta = (element.worldOrigin ?? .zero).delta(to: pointOrigin)
          if element.frame.contains(delta) {
            elementID = element.id
            region = .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
            origin = element.worldOrigin ?? .zero
            break
          }
        }
      }
    }
    return .init(target:target,elementID:elementID,region:region,worldOrigin:origin,pageIndex:pageIndex,
      label:dragged ? "Амир указал область" : elementID == nil ? "Амир указал место" : "Амир указал фрагмент")
  }

}
