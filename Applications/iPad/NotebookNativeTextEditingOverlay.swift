import NotebookCore
import SwiftUI
import UIKit

/// The native editor is not a child of UIPageViewController. A page curl cannot
/// take its selection gestures, and creation does not wait for store publication.
struct NotebookNativeTextEditingOverlay: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  @State private var panelHost = NotebookTextPanelHost.View()
  var body: some View {
    ZStack {
      if model.selectionSession.isInteractive, let target = model.selectionSession.nativeText,
        target.reference == model.selectionSession.element, let frame = NotebookAttentionProjection.nativeTextEditingFrame(target,model:model,presence:presence) {
        let scale = presence.camera.scale
        NotebookNativeTextView(source:target.source,style:target.style,reference:target.reference,
          frame:target.frame,maximumHeight:target.address.bounds.map { $0.maxY-target.frame.y } ?? .greatestFiniteMagnitude,
          isEditing:true,onEditingEnded:{ [selectionID = model.selectionSession.id] in
            model.finishInteractiveElementInput(target.reference,selectionID:selectionID)
          },retainedPage:target.page,retainedSpatial:target.spatial,ownsEditor:true,selectionPanelHost:panelHost)
          .id(model.selectionSession.id)
          .frame(width:target.frame.width,height:target.frame.height,alignment:.topLeading)
          .scaleEffect(scale,anchor:.topLeading)
          .frame(width:target.frame.width*scale,height:target.frame.height*scale,alignment:.topLeading)
          .background(NotebookControlRegion(gate:model.inputGate))
          .position(x:frame.midX,y:frame.midY)
      }
      NotebookTextPanelHost(view:panelHost)
    }
  }
}

/// SwiftUI owns the native overlay's placement. Only panel descendants receive
/// hits; the rest of the canvas remains available to its original input owner.
private struct NotebookTextPanelHost: UIViewRepresentable {
  let view: View
  func makeUIView(context: Context) -> View { view }
  func updateUIView(_ view: View, context: Context) {}
  final class View: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let hit = super.hitTest(point,with:event)
      return hit === self ? nil : hit
    }
  }
}
