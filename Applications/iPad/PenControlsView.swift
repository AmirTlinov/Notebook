import SwiftUI

struct PenControlsView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var isExpanded = false

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        if isExpanded {
          colorChoices
          elementChoice
          Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 24)

          if !model.isElementEditingEnabled {
            widthControl
            if model.drawingTool == .pen {
              opacityControl
            }
          }
        }

        Button {
          if isExpanded || isPenSelected {
            withAnimation(.smooth(duration: 0.18)) {
              isExpanded.toggle()
            }
          } else {
            model.selectDrawingTool(.pen)
          }
        } label: {
          Image(systemName: controlIcon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(controlColor)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          isExpanded ? "Закрыть выбор ручки" : isPenSelected ? "Настроить ручку" : "Ручка"
        )
        .accessibilityAddTraits(isPenSelected ? .isSelected : [])
        .accessibilityIdentifier("pen-controls-toggle")
      }
      .padding(isExpanded ? 7 : 0)
      .background(.ultraThinMaterial, in: Capsule())
      .shadow(color: .black.opacity(0.1), radius: 10, y: 3)

      eraserChoice
      Button { model.isPointing.toggle(); isExpanded = false } label: {
        Image(systemName:"hand.point.up.left")
          .font(.system(size:18,weight:.medium))
          .foregroundStyle(model.isPointing ? Color.indigo : Color.primary)
          .frame(width:44,height:44)
      }.buttonStyle(.plain)
        .background(.ultraThinMaterial,in:Circle())
        .accessibilityLabel("Указать")
        .accessibilityIdentifier("drawing-tool-pointer")
        .accessibilityAddTraits(model.isPointing ? .isSelected : [])
    }
  }

  private var isPenSelected: Bool {
    model.drawingTool == .pen && !model.isElementEditingEnabled && !model.isPointing
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
      .frame(width: 44, height: 44)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Ластик")
    .accessibilityAddTraits(
      model.drawingTool == .eraser ? .isSelected : []
    )
    .accessibilityIdentifier("drawing-tool-eraser")
    .background(.ultraThinMaterial, in: Circle())
    .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
  }

  private var controlIcon: String {
    if isExpanded { return "xmark" }
    if model.isElementEditingEnabled { return "square.dashed" }
    return "pencil.tip"
  }

  private var controlColor: Color {
    if model.isElementEditingEnabled { return .accentColor }
    return model.drawingTool == .pen
      ? model.penStyle.color.displayColor
      : .primary
  }

  private var elementChoice: some View {
    Button {
      model.selectElementTool()
    } label: {
      ZStack {
        Circle()
          .fill(
            model.isElementEditingEnabled
              ? Color.accentColor.opacity(0.16)
              : .clear
          )
          .frame(width: 31, height: 31)
        Image(systemName: "square.dashed")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(model.isElementEditingEnabled ? Color.accentColor : .primary)
      }
      .frame(width: 36, height: 36)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Элементы")
    .accessibilityHint("Выберите, переместите или удалите элемент на листе")
    .accessibilityAddTraits(model.isElementEditingEnabled ? .isSelected : [])
    .accessibilityIdentifier("element-editing-tool")
  }

  @ViewBuilder
  private var widthControl: some View {
    if model.drawingTool == .pen {
      penWidthControl
    } else {
      eraserWidthControl
    }
  }

  private var penWidthControl: some View {
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
        in: PenStyle.minimumWidth...PenStyle.maximumWidth
      )
      .tint(model.penStyle.color.displayColor)
      .frame(width: 112)
      .accessibilityLabel("Толщина ручки")
      .accessibilityIdentifier("pen-width")
    }
  }

  private var eraserWidthControl: some View {
    HStack(spacing: 9) {
      ZStack {
        Circle()
          .fill(.primary.opacity(0.14))
          .frame(
            width: eraserPreviewWidth,
            height: eraserPreviewWidth
          )
      }
      .frame(width: 26, height: 26)

      Slider(
        value: Binding(
          get: { model.eraserStyle.maximumWidth },
          set: model.selectEraserWidth
        ),
        in: EraserStyle.minimumSelectableWidth...EraserStyle.maximumSelectableWidth
      )
      .tint(.primary)
      .frame(width: 112)
      .accessibilityLabel("Толщина ластика")
      .accessibilityValue(
        "\(Int(model.eraserStyle.maximumWidth.rounded())) пунктов"
      )
      .accessibilityIdentifier("eraser-width")
    }
  }

  private var opacityControl: some View {
    HStack(spacing: 9) {
      Circle()
        .fill(
          model.penStyle.color.displayColor.opacity(
            model.penStyle.minimumOpacity
          )
        )
        .overlay {
          Circle()
            .stroke(.primary.opacity(0.18), lineWidth: 1)
        }
        .frame(width: 24, height: 24)

      Slider(
        value: Binding(
          get: { model.penStyle.minimumOpacity },
          set: model.selectPenMinimumOpacity
        ),
        in: PenStyle.lowestMinimumOpacity...PenStyle.highestMinimumOpacity
      )
      .tint(model.penStyle.color.displayColor)
      .frame(width: 96)
      .accessibilityLabel("Непрозрачность слабого нажима")
      .accessibilityValue(
        "\(Int((model.penStyle.minimumOpacity * 100).rounded())) процентов"
      )
      .accessibilityIdentifier("pen-minimum-opacity")
    }
  }

  private var eraserPreviewWidth: CGFloat {
    let progress =
      (model.eraserStyle.maximumWidth - EraserStyle.minimumSelectableWidth)
      / (EraserStyle.maximumSelectableWidth - EraserStyle.minimumSelectableWidth)
    return CGFloat(6 + (18 * progress))
  }
}
