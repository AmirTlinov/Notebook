import NotebookCore
import SwiftUI

/// References use owner-local points. This projection follows the same item
/// centers and stack fan as the visible scene, so moving an item moves its mark.
@MainActor
enum NotebookAttentionProjection {
  static func frame(_ reference: CollaborationReference, model: NotebookAppModel, presence: SessionPresence) -> CGRect? {
    guard let workspace = model.workspace, let board = model.boardHierarchy?.board(presence.boardID) else { return nil }
    var local = reference.region ?? PageRect(x:0,y:0,width:1,height:1)
    let target = reference.target
    if target.kind == .board {
      guard target.id == presence.boardID else { return nil }
      var origin = reference.worldOrigin ?? .zero
      if let id = reference.elementID, let element = board.elements.first(where: { $0.id == id && $0.surface == .board(target.id) }) {
        local = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
        origin = element.worldOrigin ?? .zero
      }
      let top = presence.camera.worldToScreen(origin.offsetBy(x:local.x,y:local.y),viewport:presence.viewport)
      return .init(x:top.x,y:top.y,width:max(8,local.width * presence.camera.scale),height:max(8,local.height * presence.camera.scale))
    }
    let itemID: UUID
    if target.kind == .page {
      guard let item = workspace.items.first(where: { $0.pageIDs.contains(target.id) }),
        workspace.selectedPageID == target.id, presence.mode == .page else { return nil }
      itemID = item.id
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
        if let id = reference.elementID, let element = board.elements.first(where: { $0.id == id && $0.surface == .cover(itemID) }) {
          local = .init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
        }
      } else { return nil }
    }
    guard let rendered = WorkspaceSceneProjection.items(workspace:workspace,board:board,presence:presence,documents:model.documents).first(where: { $0.id == itemID }) else { return nil }
    let box = rendered.geometry.screenFrame(center:rendered.center,camera:presence.camera,viewport:presence.viewport)
    if reference.region == nil && reference.elementID == nil { local = .init(x:0,y:0,width:rendered.geometry.width,height:rendered.geometry.height) }
    return .init(x:box.x + local.x * presence.camera.scale,y:box.y + local.y * presence.camera.scale,
      width:max(8,local.width * presence.camera.scale),height:max(8,local.height * presence.camera.scale))
  }

  static func reference(start: CGPoint, end: CGPoint, model: NotebookAppModel, presence: SessionPresence) -> CollaborationReference? {
    guard let content = model.collaborationContent, let files = try? content.sourceFiles(),
      let board = content.hierarchy.board(presence.boardID) else { return nil }
    let dragged = hypot(end.x-start.x,end.y-start.y) > 8
    let rect = CGRect(x:min(start.x,end.x),y:min(start.y,end.y),width:max(1,abs(end.x-start.x)),height:max(1,abs(end.y-start.y)))
    let items = WorkspaceSceneProjection.items(workspace:content.workspace,board:board,presence:presence,documents:model.documents)
    var target = CollaborationTarget(kind:.board,id:presence.boardID)
    var region: PageRect
    var origin: WorldPoint?
    var elementID: String?
    var pageIndex: Int?
    if let item = items.reversed().first(where: { item in
      let frame = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      return CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height).contains(rect)
    }) {
      let box = item.geometry.screenFrame(center:item.center,camera:presence.camera,viewport:presence.viewport)
      region = .init(x:max(0,(rect.minX-box.x)/presence.camera.scale),y:max(0,(rect.minY-box.y)/presence.camera.scale),
        width:rect.width/presence.camera.scale,height:rect.height/presence.camera.scale)
      if presence.focusedItemID == item.id && presence.mode == .page, let pageID = content.workspace.selectedPageID {
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
        for element in board.elements.reversed() where element.surface == .board(presence.boardID) {
          let delta = (element.worldOrigin ?? .zero).delta(to:origin)
          if element.frame.contains(delta) { elementID = element.id; break }
        }
      }
    }
    guard let revision = try? NotebookStore.referenceRevision(target:target,elementID:elementID,files:files) else { return nil }
    return .init(target:target,elementID:elementID,region:region,worldOrigin:origin,pageIndex:pageIndex,revision:revision,
      label:dragged ? "Амир указал область" : elementID == nil ? "Амир указал место" : "Амир указал фрагмент")
  }
}
