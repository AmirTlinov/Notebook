import NotebookCore
import SwiftUI

/// Placement changes this transform, not the body's layout width or identity.
struct NotebookPlacedElement<Content:View>: View {
  let presentation: NotebookElementPresentation?
  @ViewBuilder let content: () -> Content
  var body: some View {
    if let presentation {
      content()
        .frame(width:presentation.bodySize.width,height:presentation.bodySize.height,alignment:.topLeading)
        .transformEffect(presentation.transform)
        .frame(width:presentation.bounds.width,height:presentation.bounds.height,alignment:.topLeading)
    } else { content() }
  }
}

extension NotebookAppModel {
  func textWidthControls(_ reference:EditableElementReference,screenFrame:CGRect,scale:Double) -> NotebookTextWidthControls? {
    guard nativeTextTarget(reference) != nil,let presentation=elementPresentation(reference) else { return nil }
    return .init(presentation:presentation,screenFrame:screenFrame,scale:scale)
  }

  func nativeTextEditingPresentation(_ target:NotebookNativeTextTarget) -> NotebookElementPresentation? {
    let original=editingGraphicGraph(target.reference)?.placement(target.reference.elementID)
    let placement:NotebookElementPlacement
    if let original {
      guard let updated=try? original.updating(frame:target.frame,basis:target.basis) else { return nil }
      placement=updated
    } else {
      guard target.page == nil,target.spatial == nil else { return nil }
      placement = .init(id:target.reference.elementID,frame:target.frame,origin:target.address.worldOrigin ?? .zero)
    }
    return .init(placement:placement)
  }

  func elementPresentation(_ reference:EditableElementReference,graph:NotebookGraphicGraph? = nil) -> NotebookElementPresentation? {
    guard elementCommandDrafts[reference]?.removed != true,
      let source=nativeElementSource(reference),source.page?.graphic == nil,source.spatial?.graphic == nil,
      source.placementSource?.isGroup == false,
      let placement=(graph ?? editingGraphicGraph(reference))?.placement(reference.elementID) else { return nil }
    if let text=nativeTextTarget(reference) {
      #if os(macOS)
      if selectionSession.isInteractive,selectionSession.element == reference,
        let editing=try? placement.updating(frame:text.frame,basis:text.basis) { return .init(placement:editing) }
      #endif
      return .init(placement:placement,text:text.source,style:text.style)
    }
    return .init(placement:placement)
  }
}
