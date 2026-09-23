import NotebookCore
import SwiftUI
import UIKit

/// The native editor lives outside the sheet stack. A page curl cannot
/// take its selection gestures, and creation does not wait for store publication.
struct NotebookNativeTextEditingOverlay: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  let contextMenus: NotebookContextMenus
  var body: some View {
    if model.selectionSession.isInteractive, let target = model.selectionSession.nativeText,
      target.reference == model.selectionSession.element, let presentation=model.nativeTextEditingPresentation(target), let frame = NotebookAttentionProjection.nativeTextEditingFrame(target,model:model,presence:presence) {
      let scale = presence.camera.scale
      NotebookPlacedElement(presentation:presentation) {
      NotebookNativeTextView(source:target.source,style:target.style,reference:target.reference,
        isEditing:true,onEditingEnded:{ [selectionID = model.selectionSession.id] in
          model.finishInteractiveElementInput(target.reference,selectionID:selectionID)
        },retainedPage:target.page,retainedSpatial:target.spatial,ownsEditor:true,draftTarget:target,contextMenus:contextMenus)
        .id(model.selectionSession.id)
      }
        .scaleEffect(scale,anchor:.topLeading)
        .frame(width:presentation.bounds.width*scale,height:presentation.bounds.height*scale,alignment:.topLeading)
        .background(NotebookControlRegion(gate:model.inputGate))
        .position(x:frame.midX,y:frame.midY)
    }
  }
}
