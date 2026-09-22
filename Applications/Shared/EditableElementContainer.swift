import NotebookCore
import SwiftUI

/// A drag is measured in its stationary carrier, never in the object whose
/// preview it moves. Each page, cover and board plane defines its own carrier.
enum NotebookManipulationSpace: Hashable { case material, selection }

/// Only the material's presentation lives in this container. The current
/// selection has one screen-space frame, independent of page/cover projections.
struct EditableElementContainer<Content: View>: View {
  @Environment(NotebookAppModel.self) private var model
  let reference: EditableElementReference
  @ViewBuilder let content: Content

  var body: some View {
    content
      .accessibilityAction(named: "Изменить элемент") { model.selectElement(reference) }
      .accessibilityAction(named: "Удалить элемент") { model.selectElement(reference); model.deleteElement(reference) }
      .accessibilityAction(named: "Переместить вправо") { model.moveElementAccessibly(reference, by: .init(x: 20, y: 0)) }
      .accessibilityAction(named: "Переместить влево") { model.moveElementAccessibly(reference, by: .init(x: -20, y: 0)) }
      .accessibilityAction(named: "Переместить вниз") { model.moveElementAccessibly(reference, by: .init(x: 0, y: 20)) }
      .accessibilityAction(named: "Переместить вверх") { model.moveElementAccessibly(reference, by: .init(x: 0, y: -20)) }
      .accessibilityAddTraits(model.selectionSession.contains(reference) ? .isSelected : [])
  }
}
