import SwiftUI

struct PenControlsView: View {
  @Environment(NotebookAppModel.self) private var model
  @State private var settingsTool: DrawingTool?
  var inkOnly = false
  private var primary: [DrawingTool] { inkOnly ? [.pen,.marker,.eraser] : DrawingTool.primary }
  private var displayedTools: [DrawingTool] {
    primary + (!inkOnly && !primary.contains(model.drawingTool) ? [model.drawingTool] : [])
  }
  private var settingsAnchor: UnitPoint {
    let index = displayedTools.firstIndex(of:settingsTool ?? model.drawingTool) ?? 0
    return .init(x:(Double(index)+0.5)/Double(displayedTools.count+(inkOnly ? 0 : 1)),y:1)
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(displayedTools, id: \.self) { tool in toolButton(tool) }
      if !inkOnly { Menu {
        ForEach(DrawingTool.additional, id: \.self) { tool in
          Button { model.selectDrawingTool(tool) } label: { Label(tool.title,systemImage:tool.symbol) }
            .accessibilityIdentifier(tool.accessibilityID)
        }
      } label: {
        Image(systemName:"plus").font(NotebookChrome.iconFont)
          .frame(width:44,height:44).contentShape(Rectangle())
      }
      .accessibilityLabel("Другие инструменты").accessibilityIdentifier("drawing-tools-more")
      }
    }
    .notebookBar()
    .popover(isPresented:Binding(get:{ settingsTool != nil },set:{ if !$0 { settingsTool = nil } }),
      attachmentAnchor:.point(settingsAnchor),arrowEdge:.top) { settings }
    .onChange(of:model.drawingTool) { _,_ in settingsTool = nil }
    .onChange(of:inkOnly,initial:true) { _,onlyInk in
      if onlyInk && !model.drawingTool.usesInkJournal { settingsTool = nil; model.selectDrawingTool(.pen) }
    }

  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(model.drawingTool.title).font(.headline)
        Spacer()
        Button { settingsTool = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
          .accessibilityLabel("Закрыть настройки").buttonStyle(.plain)
      }
      switch model.drawingTool {
      case .pen:
        colorChoices
        PenStrokePreview(style: model.penStyle).frame(height: 52)
        penWidthControl
        opacityControl
      case .eraser: eraserWidthControl
      default: NotebookDrawingToolSettingsView(tool:model.drawingTool)
      }
    }
    .padding(20).frame(minWidth: 300)
    .presentationCompactAdaptation(.popover).presentationBackground(NotebookChrome.surface)
  }

  private func toolButton(_ drawingTool: DrawingTool) -> some View {
    let selected = model.drawingTool == drawingTool
    return Button {
      if selected {
        settingsTool = drawingTool
      } else {
        settingsTool = nil
        model.selectDrawingTool(drawingTool)
      }
    } label: {
      Image(systemName: drawingTool.symbol)
        .font(NotebookChrome.iconFont)
        .foregroundStyle(Color.primary)
        .frame(width: 32, height: 32)
        .background(selected ? NotebookChrome.selectionSurface : .clear, in: RoundedRectangle(cornerRadius:8))
        .frame(width:44,height:44).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(drawingTool.title)
    .accessibilityIdentifier(drawingTool.accessibilityID)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint(selected ? "Нажмите ещё раз, чтобы открыть настройки" : "Выбрать инструмент")
  }

  private var colorChoices: some View {
    HStack(spacing: 0) {
      ForEach(PenColor.allCases) { color in
        Button { model.selectPenColor(color) } label: {
          Circle().fill(color.displayColor).frame(width: 22, height: 22)
            .padding(4)
            .overlay { Circle().stroke(color == model.penStyle.color ? Color.primary : .clear, lineWidth: 2) }
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(color.name) ручка")
        .accessibilityAddTraits(color == model.penStyle.color ? .isSelected : [])
        .accessibilityIdentifier("pen-color-\(color.rawValue)")
      }
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
