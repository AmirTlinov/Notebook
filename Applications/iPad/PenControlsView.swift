import SwiftUI

struct PenControlsView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var isExpanded = false

  var body: some View {
    HStack(spacing: 2) {
      tool("pencil.tip", title: "Ручка", id: "pen-controls-toggle", selected: isPenSelected) {
        model.selectDrawingTool(.pen)
      }
      tool("eraser.fill", title: "Ластик", id: "drawing-tool-eraser", selected: isEraserSelected) {
        model.selectDrawingTool(.eraser)
      }
      tool("hand.point.up.left", title: "Указать", id: "drawing-tool-pointer", selected: model.isPointing) {
        model.isPointing.toggle()
      }
      Divider().frame(height: 22).padding(.horizontal, 4)
      Button { isExpanded = true } label: {
        Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Настройки инструмента")
      .accessibilityIdentifier("pen-settings")
      .popover(isPresented: $isExpanded, arrowEdge: .top) {
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Text(model.drawingTool == .pen ? "Ручка" : "Ластик").font(.headline)
            Spacer()
            Button { isExpanded = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
              .accessibilityLabel("Закрыть настройки").buttonStyle(.plain)
          }
          if model.drawingTool == .pen {
            colorChoices
            PenStrokePreview(style: model.penStyle).frame(height: 52)
          }
          widthControl
          if model.drawingTool == .pen { opacityControl }
        }
        .padding(20).frame(minWidth: 300)
        .presentationCompactAdaptation(.popover)
      }
    }
    .padding(4)
    .background(.regularMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
  }

  private var isPenSelected: Bool { model.drawingTool == .pen && !model.isElementEditingEnabled && !model.isPointing }
  private var isEraserSelected: Bool { model.drawingTool == .eraser && !model.isElementEditingEnabled && !model.isPointing }

  private func tool(_ icon: String, title: String, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .background(selected ? Color.primary : .clear, in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var colorChoices: some View {
    HStack(spacing: 0) {
      ForEach(PenColor.allCases) { color in
        Button { model.selectPenColor(color) } label: {
          Circle().fill(color.displayColor).frame(width: 22, height: 22)
            .padding(4)
            .overlay { Circle().stroke(color == model.penStyle.color ? Color.primary : .clear, lineWidth: 2) }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(color.name) ручка")
        .accessibilityAddTraits(color == model.penStyle.color ? .isSelected : [])
        .accessibilityIdentifier("pen-color-\(color.rawValue)")
      }
    }
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
