import Foundation
import NotebookCore

/// Every editable element carries its physical owner; changing the camera
/// cannot redirect a delayed drag to another board with the same element ID.
enum EditableElementReference: Hashable, Sendable {
  var elementID:String { switch self { case .page(_,let id),.spatial(_,let id): id } }
  case page(pageID: UUID, elementID: String)
  case spatial(boardID: UUID, elementID: String)
}

struct NotebookSelectedItem: Hashable, Sendable { let boardID: UUID; let itemID: UUID }

/// Device-local lasso result. It names vector sources and a region but does
/// not write either journal or scene until Move/Delete/Copy is requested.
struct NotebookRegionSelection: Equatable, Sendable {
  let id:UUID
  let address:NotebookToolAddress
  let polygon:[SpatialPoint]
  let frame:PageRect
  let rawInk:NotebookLassoInkSource.Result?
  let expectedInkRevision:String?
  let graphics:[EditableElementReference]
  var reference:EditableElementReference { address.reference("lasso-"+id.uuidString.lowercased()) }
}

/// Exactly one current choice. Context is evidence for it, not a second selection.
struct NotebookSelectionSession: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case item(boardID: UUID, itemID: UUID)
    case element(EditableElementReference)
    case elements([EditableElementReference], items: [NotebookSelectedItem] = [])
    case context
    case reference(CollaborationReference)
  }

  enum GeometryMode: String, CaseIterable { case transform, vertices, rounding }
  var addingElements = false
  var geometryMode: GeometryMode = .transform

  let id: UUID
  var target: Target?
  var context: NotebookAgentQuestion?
  var preview: CGRect?
  var manipulation: NotebookElementManipulation?
  var nativeText: NotebookNativeTextTarget?
  var region: NotebookRegionSelection?
  var isInteractive = false
  var isResolvingContext = false

  init(target: Target? = nil, context: NotebookAgentQuestion? = nil) {
    id = UUID(); self.target = target; self.context = context
  }

  var element: EditableElementReference? {
    if case .element(let reference) = target { return reference }; return nil
  }
  var elements: [EditableElementReference] {
    switch target { case .element(let ref): [ref]; case .elements(let refs,_): refs; default: [] }
  }
  var items: [NotebookSelectedItem] {
    switch target { case .item(let board,let id): [.init(boardID:board,itemID:id)]; case .elements(_,let items): items; default: [] }
  }
  var count: Int { elements.count+items.count+(region == nil ? 0 : 1) }
  func contains(_ reference: EditableElementReference) -> Bool { elements.contains(reference) || region?.reference == reference }
  /// Direct program/text input does not expose transformation handles.
  var editingElement: EditableElementReference? { isInteractive ? nil : (element ?? region?.reference) }

  func itemID(on boardID: UUID) -> UUID? {
    if case .item(let owner, let id) = target, owner == boardID { return id }; return nil
  }
  var highlightedReference: CollaborationReference? {
    if case .reference(let reference) = target { return reference }; return nil
  }
}

/// The editor is mounted once above the page-turn host. Its initial content and
/// physical address are available at admission, before the insert is durable.
struct NotebookNativeTextTarget: Equatable, Sendable {
  let reference: EditableElementReference
  let address: NotebookToolAddress
  var frame: PageRect
  var source: String
  var style: NativeTextStyle
  var page: AgentElement?
  var spatial: SpatialElement?
  var basis: NotebookElementBasis? = nil
  var localFrame: PageRect { .init(x:0,y:0,width:basis?.size.x ?? frame.width,height:basis?.size.y ?? frame.height) }
  var hasParent: Bool { page?.parentID != nil || spatial?.parentID != nil }
  /// Only a root's authored frame is constrained by the paper. Descendants
  /// may leave their group; the existing surface renderer clips the result.
  var maximumBodyHeight: Double {
    guard !hasParent,let bounds=address.bounds else { return 1_000_000 }
    guard let t=try? basis?.placement(in:frame) ?? CGAffineTransform(translationX:frame.x,y:frame.y) else { return 0 }
    var result=1_000_000.0
    for x in [0.0,localFrame.width] {
      let p=CGPoint(x:x,y:0).applying(t)
      for (start,step,lower,upper) in [(p.x,t.c,bounds.minX,bounds.maxX),(p.y,t.d,bounds.minY,bounds.maxY)] {
        if step>0 { result=min(result,(upper-start)/step) }
        else if step<0 { result=min(result,(lower-start)/step) }
        else if start<lower || start>upper { return 0 }
      }
    }
    return max(0,result)
  }
  mutating func resizeBody(width:Double,height:Double) throws {
    let result=try NotebookElementPlacement.Source(frame:frame,basis:basis).resizingBody(to:.init(x:width,y:height))
    frame=result.frame;basis=result.basis
  }
}
