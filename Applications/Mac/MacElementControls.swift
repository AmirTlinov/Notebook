import NotebookCore
import SwiftUI

struct MacElementControls: View {
  @Environment(NotebookAppModel.self) private var model
  let reference: EditableElementReference?
  var selectionID:UUID? = nil
  let frame: CGRect
  let scale: Double
  @State private var contact: UUID?

  var body: some View {
    let rect=frame,isGroup=reference.map { model.isElementGroup($0) } ?? (selectionID != nil)
    let text=reference.flatMap { model.textWidthControls($0,screenFrame:rect,scale:scale) }
    let availableLayers=isGroup ? [] : model.availableLayerMoves
    ZStack(alignment: .topLeading) {
      Path { path in
        if let points=text?.corners { path.addLines(points);path.closeSubpath() }
        else { path.addRect(rect) }
      }.stroke(.tint,lineWidth:1).allowsHitTesting(false)
      ForEach(text == nil ? NotebookElementResizeHandle.visible(in:rect.size) : NotebookElementResizeHandle.textWidth,id: \.self) { handle in
        let point = text?.point(handle) ?? handle.point(in: rect)
        Rectangle().fill(.background).overlay { Rectangle().stroke(.tint, lineWidth: 1) }
          .frame(width: text == nil ? 8 : 6,height:text == nil ? 8 : 18)
          .rotationEffect(.radians(text?.angle ?? 0)).padding(5).contentShape(Rectangle())
          .position(point)
          .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(NotebookManipulationSpace.selection)).onChanged { value in
            if contact == nil { contact = begin(.resize(handle)) }
            if let contact { model.updateElementManipulation(contact, translation: .init(x: value.translation.width / scale, y: value.translation.height / scale)) }
          }.onEnded { value in
            if let contact { model.finishElementManipulation(contact, translation: .init(x: value.translation.width / scale, y: value.translation.height / scale)) }
            contact = nil
          })
          .accessibilityLabel(text == nil ? "Изменить размер за \(handle.label)" : "Ширина текста: \(handle.leading ? "начало" : "конец") строки")
          .accessibilityIdentifier("resize-agent-element-"+handle.rawValue)
      }
      if isGroup {
        Image(systemName:"arrow.up.and.down.and.arrow.left.and.right").padding(8).background(.regularMaterial,in:Circle())
          .position(x:rect.midX,y:rect.midY)
          .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named(NotebookManipulationSpace.selection)).onChanged { value in
            if contact == nil { contact=begin(.move) }
            if let contact { model.updateElementManipulation(contact,translation:.init(x:value.translation.width/scale,y:value.translation.height/scale)) }
          }.onEnded { value in
            if let contact { model.finishElementManipulation(contact,translation:.init(x:value.translation.width/scale,y:value.translation.height/scale)) };contact=nil
          }).accessibilityLabel("Переместить группу")
      }
      HStack(spacing: 8) {
        if !isGroup,let reference {
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
        if let reference { Menu {
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
        } else {
          Button("Дублировать") { model.duplicateSelectedContent() }.disabled(!model.canExportSelection)
          Button("Удалить",role:.destructive) { model.deleteSelectedContent() }.disabled(!model.canDeleteSelection)
          Button("Снять выделение") { model.clearSelection() }
        }
      }.buttonStyle(.borderless).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .position(x: max(70, rect.midX), y: max(22, rect.minY - 24))
    }
    .coordinateSpace(name: NotebookManipulationSpace.selection)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onDisappear { if let contact { model.cancelElementManipulation(contact) }; contact = nil }
  }
  private func begin(_ kind:NotebookElementManipulation.Kind) -> UUID? {
    if let reference { return model.beginElementManipulation(reference,kind:kind) }
    guard selectionID == model.selectionSession.id else { return nil }
    return model.beginSelectionManipulation(kind:kind)
  }

}
