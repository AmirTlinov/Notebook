import Foundation
import NotebookCore

/// Every editable element carries its physical owner; changing the camera
/// cannot redirect a delayed drag to another board with the same element ID.
enum EditableElementReference: Hashable, Sendable {
  case page(pageID: UUID, elementID: String)
  case spatial(boardID: UUID, elementID: String)
}

struct NotebookSelectedItem: Hashable, Sendable { let boardID: UUID; let itemID: UUID }

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
  var count: Int { elements.count+items.count }
  func contains(_ reference: EditableElementReference) -> Bool { elements.contains(reference) }
  /// Direct program/text input does not expose transformation handles.
  var editingElement: EditableElementReference? { isInteractive ? nil : element }

  func itemID(on boardID: UUID) -> UUID? {
    if case .item(let owner, let id) = target, owner == boardID { return id }; return nil
  }
  var highlightedReference: CollaborationReference? {
    if case .reference(let reference) = target { return reference }; return nil
  }
}
