import NotebookCore
import SwiftUI

/// A stateless projection of the shared editing session around one element.
struct EditableElementContainer<Content: View>: View {
  let isEditingEnabled: Bool
  let isSelected: Bool
  let coordinateScale: Double
  let translation: SpatialPoint
  let onSelect: () -> Void
  let onDragChanged: (SpatialPoint) -> Void
  let onDragEnded: (SpatialPoint) -> Void
  let onDelete: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
        .allowsHitTesting(!isEditingEnabled)

      if isEditingEnabled {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture(perform: onSelect)
          .gesture(moveGesture)

        if isSelected {
          Rectangle()
            .stroke(
              Color.accentColor,
              style: StrokeStyle(lineWidth: 2, dash: [8, 5])
            )
            .allowsHitTesting(false)

          Button(role: .destructive) {
            onDelete()
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 38, height: 38)
              .background(Color.red, in: Circle())
              .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
          }
          .buttonStyle(.plain)
          .offset(x: 16, y: -16)
          .accessibilityLabel("Удалить элемент")
          .accessibilityIdentifier("delete-agent-element")
        }
      }
    }
    .offset(
      x: translation.x * coordinateScale,
      y: translation.y * coordinateScale
    )
    .zIndex(isSelected ? 1_000 : 0)
  }

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        onSelect()
        onDragChanged(logicalTranslation(value.translation))
      }
      .onEnded { value in
        let logical = logicalTranslation(value.translation)
        guard hypot(logical.x, logical.y) >= 1 else { return }
        onDragEnded(logical)
      }
  }

  private func logicalTranslation(_ translation: CGSize) -> SpatialPoint {
    let scale = max(coordinateScale, 0.001)
    return SpatialPoint(
      x: translation.width / scale,
      y: translation.height / scale
    )
  }
}
