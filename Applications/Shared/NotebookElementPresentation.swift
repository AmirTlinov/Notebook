import NotebookCore
import SwiftUI

/// The existing placement applied to a specialized body. Text remains TextKit,
/// a program keeps its native host, and pixels remain replaceable output.
struct NotebookElementPresentation: Equatable, Sendable {
  let placement: NotebookElementPlacement
  let localBounds: CGRect
  var bodySize: CGSize { .init(width:placement.localSize.x,height:max(placement.localSize.y,localBounds.maxY)) }
  var bounds: CGRect { localBounds.applying(placement.transform) }
  var frame: PageRect { .init(x:bounds.minX,y:bounds.minY,width:bounds.width,height:bounds.height) }
  var requiresRasterTransform: Bool {
    let t=placement.transform
    return t.b != 0 || t.c != 0 || t.a < 0 || t.d < 0
  }
  var maximumScale: Double {
    Self.maximumScale(placement.transform)
  }
  static func maximumScale(_ t:CGAffineTransform) -> Double {
    let a=t.a*t.a+t.b*t.b,b=t.c*t.c+t.d*t.d,c=t.a*t.c+t.b*t.d
    return sqrt((a+b+hypot(a-b,2*c))/2)
  }
  var transform: CGAffineTransform {
    placement.transform.concatenating(.init(translationX:-bounds.minX,y:-bounds.minY))
  }

  init(placement: NotebookElementPlacement, text: String? = nil, style: NativeTextStyle = .standard) {
    self.placement=placement
    let body=PageRect(x:0,y:0,width:placement.localSize.x,height:placement.localSize.y)
    let local=text.map { NotebookTextTypography.fittingFrame($0,style:style,in:body) } ?? body
    localBounds = .init(x:local.x,y:local.y,width:local.width,height:local.height)
  }

  init(_ element:SpatialElement,placement:NotebookElementPlacement) {
    self.init(placement:placement,text:element.kind == .nativeText ? element.source : nil,style:element.textStyle)
  }
  init(_ element:AgentElement,placement:NotebookElementPlacement) {
    self.init(placement:placement,text:element.kind == .nativeText ? element.source : nil,style:element.textStyle ?? .standard)
  }
}

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
