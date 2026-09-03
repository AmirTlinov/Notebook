import Foundation
import NotebookCore

enum EditableElementReference: Equatable, Sendable {
  case page(pageID: UUID, elementID: String)
  case spatial(elementID: String)
}

/// The one transient owner of element selection and an unfinished drag.
struct ElementEditingSession: Equatable, Sendable {
  var selection: EditableElementReference?
  var translation: SpatialPoint

  init(
    selection: EditableElementReference? = nil,
    translation: SpatialPoint = .zero
  ) {
    self.selection = selection
    self.translation = translation
  }
}
