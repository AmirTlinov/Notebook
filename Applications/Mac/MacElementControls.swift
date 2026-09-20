import NotebookCore
import SwiftUI

struct MacElementControls: View {
  @Environment(NotebookAppModel.self) private var model
  let reference: EditableElementReference
  let frame: CGRect
  let scale: Double
  @State private var contact: UUID?

  var body: some View {
    let rect = frame, availableLayers = model.availableLayerMoves, isGroup=model.isElementGroup(reference)
    ZStack(alignment: .topLeading) {
      Rectangle().stroke(.tint, lineWidth: 1).frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
      ForEach(NotebookElementResizeHandle.visible(in: rect.size), id: \.self) { handle in
        let point = handle.point(in: rect)
        Rectangle().fill(.background).overlay { Rectangle().stroke(.tint, lineWidth: 1) }
          .frame(width: 8, height: 8).padding(5).contentShape(Rectangle())
          .position(point)
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(NotebookManipulationSpace.selection)).onChanged { value in
            if contact == nil { contact = model.beginElementManipulation(reference, kind: .resize(handle)) }
            if let contact { model.updateElementManipulation(contact, translation: .init(x: value.translation.width / scale, y: value.translation.height / scale)) }
          }.onEnded { value in
            if let contact { model.finishElementManipulation(contact, translation: .init(x: value.translation.width / scale, y: value.translation.height / scale)) }
            contact = nil
          })
          .accessibilityLabel("Изменить размер за \(handle.label)")
      }
      if isGroup {
        Image(systemName:"arrow.up.and.down.and.arrow.left.and.right").padding(8).background(.regularMaterial,in:Circle())
          .position(x:rect.midX,y:rect.midY)
          .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named(NotebookManipulationSpace.selection)).onChanged { value in
            if contact == nil { contact=model.beginElementManipulation(reference,kind:.move) }
            if let contact { model.updateElementManipulation(contact,translation:.init(x:value.translation.width/scale,y:value.translation.height/scale)) }
          }.onEnded { value in
            if let contact { model.finishElementManipulation(contact,translation:.init(x:value.translation.width/scale,y:value.translation.height/scale)) };contact=nil
          }).accessibilityLabel("Переместить группу")
      }
      HStack(spacing: 8) {
        if !isGroup {
        Button { model.editSelectedElement(reference) } label: { Image(systemName: "pencil") }.help("Редактировать")
        Menu {
          ForEach(NotebookElementLayerMove.allCases,id:\.self) { move in
            Button(move.title) {
              guard model.selectionSession.element == reference else { return }
              model.arrangeSelection(move)
            }.disabled(!availableLayers.contains(move))
          }
        } label: { Image(systemName:"square.3.layers.3d") }.help("Порядок слоёв")
        Button(role: .destructive) { model.deleteElement(reference) } label: { Image(systemName: "trash") }.help("Удалить")
        }
        Menu {
          if let parent=model.parentGroup(reference) { Button("Выбрать группу") { model.selectElement(parent) } }
          if isGroup {
            Button("Повернуть на 90°") { model.transformGraphicSelection(radians:.pi/2) }
            Button("Увеличить") { model.transformGraphicSelection(scale:1.25) }
            Button("Уменьшить") { model.transformGraphicSelection(scale:0.8) }
            Button("Выбрать участника") { model.clearSelection() }
          } else if model.graphicElement(reference) != nil {
            Button("Выбрать несколько") { model.beginMultipleSelection() }
          }
        } label: { Image(systemName:"ellipsis") }.help("Действия с группой")
      }.buttonStyle(.borderless).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .position(x: max(70, rect.midX), y: max(22, rect.minY - 24))
    }
    .coordinateSpace(name: NotebookManipulationSpace.selection)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onDisappear { if let contact { model.cancelElementManipulation(contact) }; contact = nil }
  }
}
