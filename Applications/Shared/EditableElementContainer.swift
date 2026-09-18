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
  let coordinateScale: Double
  @ViewBuilder let content: Content
  #if os(macOS)
  @State private var contact: UUID?
  #endif

  var body: some View {
    content
      .accessibilityAction(named: "Изменить элемент") { model.selectElement(reference) }
      .accessibilityAction(named: "Удалить элемент") { model.selectElement(reference); model.deleteElement(reference) }
      .accessibilityAction(named: "Переместить вправо") { model.moveElementAccessibly(reference, by: .init(x: 20, y: 0)) }
      .accessibilityAction(named: "Переместить влево") { model.moveElementAccessibly(reference, by: .init(x: -20, y: 0)) }
      .accessibilityAction(named: "Переместить вниз") { model.moveElementAccessibly(reference, by: .init(x: 0, y: 20)) }
      .accessibilityAction(named: "Переместить вверх") { model.moveElementAccessibly(reference, by: .init(x: 0, y: -20)) }
      #if os(macOS)
      .onTapGesture(count: 2) { model.selectElement(reference); model.editSelectedElement(reference) }
      .onTapGesture { model.selectElement(reference) }
      .contextMenu {
        Button("Редактировать") { model.selectElement(reference); model.editSelectedElement(reference) }
        Button("Удалить", role: .destructive) { model.selectElement(reference); model.deleteElement(reference) }
      }
      .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(NotebookManipulationSpace.material))
        .onChanged { value in
          if contact == nil { model.selectElement(reference); contact = model.beginElementManipulation(reference, kind: .move) }
          if let contact { model.updateElementManipulation(contact, translation: .init(x: value.translation.width / coordinateScale, y: value.translation.height / coordinateScale)) }
        }
        .onEnded { value in
          if let contact { model.finishElementManipulation(contact, translation: .init(x: value.translation.width / coordinateScale, y: value.translation.height / coordinateScale)) }
          contact = nil
        }, including: model.selectionSession.isInteractive && model.selectionSession.element == reference ? .subviews : .all)
      .onDisappear { if let contact { model.cancelElementManipulation(contact) }; contact = nil }
      #endif
      .accessibilityAddTraits(model.selectionSession.contains(reference) ? .isSelected : [])
  }
}
