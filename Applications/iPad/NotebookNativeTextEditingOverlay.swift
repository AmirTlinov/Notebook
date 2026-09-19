import NotebookCore
import SwiftUI

/// The native editor is not a child of UIPageViewController. A page curl cannot
/// take its selection gestures, and creation does not wait for store publication.
struct NotebookNativeTextEditingOverlay: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    if model.selectionSession.isInteractive, let target = model.selectionSession.nativeText,
      target.reference == model.selectionSession.element, let origin = origin(target) {
      let scale = presence.camera.scale
      NotebookNativeTextView(source:target.source,style:target.style,reference:target.reference,
        frame:target.frame,maximumHeight:target.address.bounds.map { $0.maxY-target.frame.y } ?? .greatestFiniteMagnitude,
        isEditing:true,onEditingEnded:{ [selectionID = model.selectionSession.id] in
          model.finishInteractiveElementInput(target.reference,selectionID:selectionID)
        },retainedPage:target.page,retainedSpatial:target.spatial,ownsEditor:true)
        .id(model.selectionSession.id)
        .frame(width:target.frame.width,height:target.frame.height,alignment:.topLeading)
        .scaleEffect(scale,anchor:.topLeading)
        .frame(width:target.frame.width*scale,height:target.frame.height*scale,alignment:.topLeading)
        .background(NotebookControlRegion(gate:model.inputGate))
        .position(x:origin.x+target.frame.width*scale/2,y:origin.y+target.frame.height*scale/2)
    }
  }
  private func origin(_ target: NotebookNativeTextTarget) -> CGPoint? {
    let scale = presence.camera.scale
    if target.address.surface.kind == .board {
      guard target.address.boardID == presence.boardID else { return nil }
      let p = presence.camera.worldToScreen(target.address.worldOrigin ?? .zero,viewport:presence.viewport)
      return .init(x:p.x+target.frame.x*scale,y:p.y+target.frame.y*scale)
    }
    guard let frame = NotebookAttentionProjection.frame(.init(target:target.address.target,revision:""),model:model,presence:presence) else { return nil }
    return .init(x:frame.minX+target.frame.x*scale,y:frame.minY+target.frame.y*scale)
  }
}
