import NotebookCore
import SwiftUI

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
    let movement = model.elementMovement(reference)
    content
      .accessibilityAction(named: "Изменить элемент") { model.selectElement(reference) }
      .accessibilityAction(named: "Удалить элемент") { model.selectElement(reference); model.deleteElement(reference) }
      .accessibilityAction(named: "Переместить вправо") { model.moveElementAccessibly(reference, by: .init(x: 20, y: 0)) }
      .accessibilityAction(named: "Переместить влево") { model.moveElementAccessibly(reference, by: .init(x: -20, y: 0)) }
      .accessibilityAction(named: "Переместить вниз") { model.moveElementAccessibly(reference, by: .init(x: 0, y: 20)) }
      .accessibilityAction(named: "Переместить вверх") { model.moveElementAccessibly(reference, by: .init(x: 0, y: -20)) }
      #if os(macOS)
      .onTapGesture { model.selectElement(reference) }
      .gesture(DragGesture(minimumDistance: 3)
        .onChanged { value in
          if contact == nil { model.selectElement(reference); contact = model.beginElementManipulation(reference, kind: .move) }
          if let contact { model.updateElementManipulation(contact, translation: .init(x: value.translation.width / coordinateScale, y: value.translation.height / coordinateScale)) }
        }
        .onEnded { value in
          if let contact { model.finishElementManipulation(contact, translation: .init(x: value.translation.width / coordinateScale, y: value.translation.height / coordinateScale)) }
          contact = nil
        })
      .onDisappear { if let contact { model.cancelElementManipulation(contact) }; contact = nil }
      #endif
      .offset(x: movement.x * coordinateScale, y: movement.y * coordinateScale)
      .accessibilityAddTraits(model.selectionSession.element == reference ? .isSelected : [])
  }
}
