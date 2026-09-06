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

  static func capture(start: CGPoint, end: CGPoint, model: NotebookAppModel, presence: SessionPresence) -> NotebookAttentionSelection? {
    guard let workspace = model.workspace, let hierarchy = model.boardHierarchy, let ink = model.spatialInk else { return nil }
    let fragments = fragments(start: start, end: end, model: model, presence: presence)
    guard !fragments.isEmpty else { return nil }
    return .init(fragments: fragments, workspace: workspace, hierarchy: hierarchy, ink: ink,
      pages: model.pages, documents: model.documents, states: model.documentStates)
  }

  private static func fragments(start: CGPoint, end: CGPoint, model: NotebookAppModel, presence: SessionPresence) -> [NotebookAttentionSelection.Fragment] {
    guard presence.mode == .board, hypot(end.x - start.x, end.y - start.y) > 8,
      let index = model.sceneIndex, !model.scenePreparationPending else {
      return fragment(start: start, end: end, model: model, presence: presence).map { [$0] } ?? []
    }
    let selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    var result = fragment(start: start, end: end, model: model, presence: presence).map { [$0] } ?? []
    for item in index.workset(presence: presence).items {
      let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
      let intersection = selection.intersection(CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
      guard !intersection.isNull, intersection.width > 0, intersection.height > 0,
        !result.contains(where: { $0.target.id == item.id }), result.count < 32 else { continue }
      if let reference = fragment(start: .init(x: intersection.minX, y: intersection.minY),
        end: .init(x: intersection.maxX, y: intersection.maxY), model: model, presence: presence, ownerID: item.id) {
        result.append(reference)
      }
    }
    return result
  }

  private static func fragment(start: CGPoint, end: CGPoint, model: NotebookAppModel, presence: SessionPresence, ownerID: UUID? = nil) -> NotebookAttentionSelection.Fragment? {
    guard !model.scenePreparationPending, let index = model.sceneIndex,
      let workspace = model.workspace, let board = index.board(id: presence.boardID) else { return nil }
    let dragged = hypot(end.x-start.x,end.y-start.y) > 8
    let rect = CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:max(1,abs(end.x-start.x)),height:max(1,abs(end.y-start.y)))
    let admitted = index.workset(presence: presence)
    let items = ownerID.map { id in index.renderedItem(id: id, presence: presence).map { [$0] } ?? [] } ?? admitted.items
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
      if presence.focusedItemID == item.id && presence.mode == .page, let pageID = workspace.selectedPageID {
        target = .init(kind:.page,id:pageID)
        if !dragged { elementID = model.pages[pageID]?.elements.last { CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height).contains(CGPoint(x:region.x,y:region.y)) }?.id }
      } else if presence.focusedItemID == item.id && presence.mode == .document,
        let document = model.documents[item.id], let state = model.documentStates[item.id] {
        target = .init(kind:.document,id:item.id); pageIndex = presence.documentPageIndex
        elementID = DocumentRenderRegistry.shared.regions(document:document,state:state).first { $0.pageIndex == pageIndex && CGRect(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height).intersects(CGRect(x:region.x,y:region.y,width:region.width,height:region.height)) }?.id
      } else {
        target = .init(kind:.cover,id:item.id,boardID:presence.boardID)
        if !dragged {
          elementID = board.elements.last { $0.surface == .cover(item.id) && $0.frame.contains(.init(x:region.x,y:region.y)) }?.id
          if elementID == nil { region = .init(x:0,y:0,width:item.geometry.width,height:item.geometry.height) }
        }
      }
    } else {
      origin = presence.camera.screenToWorld(.init(x:rect.minX,y:rect.minY),viewport:presence.viewport)
      region = .init(x:0,y:0,width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if !dragged, let origin {
        for element in admitted.elements.reversed() where element.surface == .board(presence.boardID) {
          let delta = (element.worldOrigin ?? .zero).delta(to:origin)
          if element.frame.contains(delta) { elementID = element.id; break }
        }
      }
    }
    return .init(target:target,elementID:elementID,region:region,worldOrigin:origin,pageIndex:pageIndex,
      label:dragged ? "Амир указал область" : elementID == nil ? "Амир указал место" : "Амир указал фрагмент")
  }
}
