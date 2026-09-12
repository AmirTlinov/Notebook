import NotebookCore
import SwiftUI

/// Editing handles publish their actual layout bounds. The question composer
/// may avoid these controls without owning the element's selection or camera.
struct ElementEditingControlFrames: PreferenceKey {
  static let defaultValue: [CGRect] = []
  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue())
  }
}

private struct ElementEditingControlBounds: View {
  var body: some View {
    GeometryReader { geometry in
      Color.clear.preference(key: ElementEditingControlFrames.self,
        value: [geometry.frame(in: .global)])
    }.allowsHitTesting(false)
  }
}

/// The content accepts its own controls; explicit frame handles own editing gestures.
struct EditableElementContainer<Content: View>: View {
  let isSelected: Bool
  let coordinateScale: Double
  let translation: SpatialPoint
  let onSelect: () -> Void
  let onDragChanged: (SpatialPoint) -> Void
  let onDragEnded: (SpatialPoint) -> Void
  let onResizeChanged: (SpatialPoint) -> Void
  let onResizeEnded: (SpatialPoint) -> Void
  let resizeDelta: SpatialPoint
  let onDelete: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
        .accessibilityAction(named: "Изменить элемент", onSelect)
        #if os(macOS)
        .onTapGesture(perform: onSelect)
        #endif
      if isSelected {
        Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5])).allowsHitTesting(false)
        HStack(spacing: 6) {
          Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            .contentShape(Circle()).gesture(moveGesture)
            .accessibilityLabel("Переместить элемент").accessibilityIdentifier("move-agent-element")
            .accessibilityAction(named: "Вправо") { onDragEnded(.init(x: 20, y: 0)) }
            .accessibilityAction(named: "Влево") { onDragEnded(.init(x: -20, y: 0)) }
            .accessibilityAction(named: "Вниз") { onDragEnded(.init(x: 0, y: 20)) }
            .accessibilityAction(named: "Вверх") { onDragEnded(.init(x: 0, y: -20)) }
          Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash").frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
          }.buttonStyle(.plain).accessibilityLabel("Удалить элемент").accessibilityIdentifier("delete-agent-element")
        }.font(.system(size: 17, weight: .medium))
          .background(ElementEditingControlBounds())
          .background(ElementEditingInputRegion().accessibilityHidden(true)).offset(x: 16, y: -48)
      }
    }
    .overlay {
      if isSelected && resizeDelta != .zero {
        GeometryReader { geometry in
          Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .frame(width: max(44, geometry.size.width + resizeDelta.x * coordinateScale), height: max(44, geometry.size.height + resizeDelta.y * coordinateScale))
        }.allowsHitTesting(false)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if isSelected {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .frame(width: 44, height: 44).background(.regularMaterial, in: Circle()).contentShape(Circle())
          .background(ElementEditingControlBounds())
          .background(ElementEditingInputRegion().accessibilityHidden(true))
          .offset(x: 16 + resizeDelta.x * coordinateScale, y: 16 + resizeDelta.y * coordinateScale)
          .gesture(DragGesture(minimumDistance: 3)
            .onChanged { onResizeChanged(logicalTranslation($0.translation)) }
            .onEnded { onResizeEnded(logicalTranslation($0.translation)) })
          .accessibilityLabel("Изменить размер элемента").accessibilityIdentifier("resize-agent-element")
          .accessibilityAction(named: "Увеличить") { onResizeEnded(.init(x: 20, y: 20)) }
          .accessibilityAction(named: "Уменьшить") { onResizeEnded(.init(x: -20, y: -20)) }
      }
    }
    .offset(x: translation.x * coordinateScale, y: translation.y * coordinateScale)
    .zIndex(isSelected ? 1_000 : 0)
  }

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in onSelect(); onDragChanged(logicalTranslation(value.translation)) }
      .onEnded { value in
        let logical = logicalTranslation(value.translation)
        guard hypot(logical.x, logical.y) >= 1 else { return }
        onDragEnded(logical)
      }
  }
  private func logicalTranslation(_ translation: CGSize) -> SpatialPoint {
    let scale = max(coordinateScale, 0.001)
    return .init(x: translation.width / scale, y: translation.height / scale)
  }
}

private struct ElementEditingInputRegion: View {
  @Environment(NotebookAppModel.self) private var model
  var body: some View {
    #if os(iOS)
      NotebookControlRegion(gate: model.inputGate)
    #else
      Color.clear.allowsHitTesting(false)
    #endif
  }
}
