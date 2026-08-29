import SwiftUI

struct PenControlsView: View {
  @Environment(TetradAppModel.self) private var model
  @State private var isExpanded = false

  var body: some View {
    HStack(spacing: 8) {
      if isExpanded {
        colorChoices
        eraserChoice

        Rectangle()
          .fill(.primary.opacity(0.12))
          .frame(width: 1, height: 24)

        widthControl
      }

      Button {
        withAnimation(.smooth(duration: 0.18)) {
          isExpanded.toggle()
        }
      } label: {
        Image(systemName: controlIcon)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(controlColor)
          .frame(width: 44, height: 44)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Закрыть выбор ручки" : "Настроить ручку")
      .accessibilityIdentifier("pen-controls-toggle")
    }
    .padding(isExpanded ? 7 : 0)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
  }

  private var colorChoices: some View {
    HStack(spacing: 2) {
      ForEach(PenColor.allCases) { color in
        Button {
          model.selectPenColor(color)
        } label: {
          ZStack {
            Circle()
              .stroke(
                color == model.penStyle.color && model.drawingTool == .pen
                  ? Color.primary.opacity(0.7)
                  : .clear,
                lineWidth: 2
              )
              .frame(width: 29, height: 29)
            Circle()
              .fill(color.displayColor)
              .frame(width: 19, height: 19)
          }
          .frame(width: 36, height: 36)
          .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(color.name) ручка")
        .accessibilityAddTraits(
          color == model.penStyle.color && model.drawingTool == .pen
            ? .isSelected
            : []
        )
        .accessibilityIdentifier("pen-color-\(color.rawValue)")
      }
    }
  }

  private var eraserChoice: some View {
    Button {
      model.selectDrawingTool(.eraser)
    } label: {
      ZStack {
        Circle()
          .fill(
            model.drawingTool == .eraser
              ? Color.primary.opacity(0.12)
              : .clear
          )
          .frame(width: 31, height: 31)
        Image(systemName: "eraser.fill")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.primary)
      }
      .frame(width: 36, height: 36)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Ластик")
    .accessibilityAddTraits(
      model.drawingTool == .eraser ? .isSelected : []
    )
    .accessibilityIdentifier("drawing-tool-eraser")
  }

  private var widthControl: some View {
    HStack(spacing: 9) {
      Capsule()
        .fill(model.penStyle.color.displayColor)
        .frame(
          width: 26,
          height: CGFloat(max(PenStyle.minimumWidth, model.penStyle.width))
        )

      Slider(
        value: Binding(
          get: { model.penStyle.width },
          set: model.selectPenWidth
        ),
        in: PenStyle.minimumWidth ... PenStyle.maximumWidth
      )
      .tint(model.penStyle.color.displayColor)
      .frame(width: 112)
      .accessibilityLabel("Толщина ручки")
      .accessibilityIdentifier("pen-width")
    }
  }

  private var controlIcon: String {
    if isExpanded { return "xmark" }
    return model.drawingTool == .pen ? "pencil.tip" : "eraser.fill"
  }

  private var controlColor: Color {
    model.drawingTool == .pen ? model.penStyle.color.displayColor : .primary
  }
}
