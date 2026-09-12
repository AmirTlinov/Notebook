import Foundation
import NotebookCore

/// Every editable element carries its physical owner; changing the camera
/// cannot redirect a delayed drag to another board with the same element ID.
enum EditableElementReference: Equatable, Sendable {
  case page(pageID: UUID, elementID: String)
  case spatial(boardID: UUID, elementID: String)
}

/// Exactly one current choice. The durable context is evidence for that choice,
/// not another selection which can paint a second set of frames.
struct NotebookSelectionSession: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case item(boardID: UUID, itemID: UUID)
    case element(EditableElementReference)
    case context
    case reference(CollaborationReference)
  }

  let id: UUID
  var target: Target?
  var context: NotebookAgentQuestion?
  var preview: CGRect?
  var translation: SpatialPoint = .zero
  var resizeDelta: SpatialPoint = .zero
  var isInteractive = false
  var isResolvingContext = false

  init(target: Target? = nil, context: NotebookAgentQuestion? = nil) {
    id = UUID(); self.target = target; self.context = context
  }

  var element: EditableElementReference? {
    if case .element(let reference) = target { return reference }; return nil
  }
  /// Direct program/text input does not expose transformation handles.
  var editingElement: EditableElementReference? { isInteractive ? nil : element }

  func itemID(on boardID: UUID) -> UUID? {
    if case .item(let owner, let id) = target, owner == boardID { return id }; return nil
  }
  var highlightedReference: CollaborationReference? {
    if case .reference(let reference) = target { return reference }; return nil
  }
}
