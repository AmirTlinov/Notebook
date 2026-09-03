import SwiftUI

/// Gives a person temporary ownership of an agent-authored element. The normal
/// content keeps its own taps until the element tool is selected; that tool
/// then owns selection, movement and deletion in one visible layer.
struct EditableElementContainer<Content: View>: View {
  let isEditingEnabled: Bool
  let isSelected: Bool
  let coordinateScale: Double
  let onSelect: () -> Void
  let onMove: (CGSize) -> Void
  let onDelete: () -> Void
  @ViewBuilder let content: Content

  @State private var dragTranslation = CGSize.zero

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
    .offset(dragTranslation)
    .zIndex(isSelected ? 1_000 : 0)
    .onChange(of: isEditingEnabled) { _, enabled in
      if !enabled { dragTranslation = .zero }
    }
  }

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        onSelect()
        dragTranslation = value.translation
      }
      .onEnded { value in
        let scale = max(coordinateScale, 0.001)
        let logical = CGSize(
          width: value.translation.width / scale,
          height: value.translation.height / scale
        )
        dragTranslation = .zero
        guard hypot(logical.width, logical.height) >= 1 else { return }
        onMove(logical)
      }
  }
}
