import SwiftUI
import NotebookCore

struct PenControlsView: View {
  @Environment(NotebookAppModel.self) private var model
  private enum Panel: Equatable { case tool(DrawingTool), color }
  @State private var panel: Panel?
  var inkOnly = false
  private var primary: [DrawingTool] { inkOnly ? [.pen,.marker,.eraser] : DrawingTool.primary }
  private var displayedTools: [DrawingTool] {
    primary + (!inkOnly && !primary.contains(model.drawingTool) ? [model.drawingTool] : [])
  }
  private var colorEnabled: Bool { ![DrawingTool.eraser,.lasso].contains(model.drawingTool) }
  private var settingsAnchor: UnitPoint {
    let count = displayedTools.count+(inkOnly ? 0 : 1)+1
    let index = panel == .color ? count-1 : displayedTools.firstIndex(of:model.drawingTool) ?? 0
    return .init(x:(Double(index)+0.5)/Double(count),y:1)
  }
  var embedded = false

  var body: some View {
    HStack(spacing:0) {
      ForEach(displayedTools,id:\.self) { tool in toolButton(tool) }
      if !inkOnly {
        Menu {
          ForEach(DrawingTool.additional,id:\.self) { tool in
            Button { model.selectDrawingTool(tool) } label: { Label(tool.title,systemImage:tool.symbol) }
              .accessibilityIdentifier(tool.accessibilityID)
          }
        } label: {
          Image(systemName:"plus").font(NotebookChrome.iconFont)
            .frame(width:44,height:44).contentShape(Rectangle())
        }
        .accessibilityLabel("Другие инструменты").accessibilityIdentifier("drawing-tools-more")
      }
      Button { panel = panel == .color ? nil : .color } label: {
        Circle().fill(model.drawingColor.displayColor).frame(width:22,height:22)
          .overlay { Circle().strokeBorder(.primary.opacity(0.18),lineWidth:0.5) }
          .frame(width:44,height:44).contentShape(Rectangle())
      }
      .disabled(!colorEnabled).opacity(colorEnabled ? 1 : 0.35)
      .accessibilityLabel("Основной цвет").accessibilityValue(model.drawingColor.name)
      .accessibilityIdentifier("drawing-primary-color")
    }
    .font(NotebookChrome.iconFont).buttonStyle(.plain)
    .background { if !embedded { NotebookSurface(radius: NotebookChrome.barHeight / 2).padding(.vertical, 2) } }
    .anchorPreference(key:NotebookToolPanelPreference.self,value:.bounds) { toolbar in
      panel == nil ? nil : .init(toolbar:toolbar,anchor:settingsAnchor,
        content:AnyView(settings.environment(model)),dismiss:{ panel = nil })
    }
    .onChange(of:model.drawingTool) { _,_ in panel = nil }
    .onChange(of:inkOnly,initial:true) { _,onlyInk in
      if onlyInk && !model.drawingTool.usesInkJournal { panel = nil; model.selectDrawingTool(.pen) }
    }
  }

  private var settings: some View {
    VStack(alignment:.leading,spacing:10) {
      if panel == .color {
        NotebookToolColorPalette(selection:Binding(get:{ model.drawingColor },set:{ model.selectDrawingColor($0); panel = nil }),prefix:"drawing")
      } else {
        switch model.drawingTool {
        case .pen:
          PenStrokePreview(style:model.penStyle).frame(height:28)
          sizeControl(title:"Толщина",value:Binding(get:{ model.penStyle.width },set:model.selectPenWidth),
            range:PenStyle.minimumWidth...PenStyle.maximumWidth,id:"pen-width")
          VStack(alignment:.leading,spacing:2) {
            HStack { Text("Непрозрачность слабого нажима"); Spacer(); Text("\(Int(model.penStyle.minimumOpacity*100))%") }.font(.caption)
            Slider(value:Binding(get:{ model.penStyle.minimumOpacity },set:model.selectPenMinimumOpacity),
              in:PenStyle.lowestMinimumOpacity...PenStyle.highestMinimumOpacity)
              .accessibilityLabel("Непрозрачность слабого нажима").accessibilityIdentifier("pen-minimum-opacity")
          }
        case .eraser:
          sizeControl(title:"Диаметр",value:Binding(get:{ model.eraserStyle.maximumWidth },set:model.selectEraserWidth),
            range:EraserStyle.minimumSelectableWidth...EraserStyle.maximumSelectableWidth,id:"eraser-width")
          HStack(spacing:0) {
            ForEach([8.0,16,32,64],id:\.self) { width in
              Button("\(Int(width))") { model.selectEraserWidth(width) }
                .frame(maxWidth:.infinity,minHeight:36)
                .accessibilityLabel("Диаметр \(Int(width)) пунктов")
                .accessibilityIdentifier("eraser-size-\(Int(width))")
            }
          }
        default: NotebookDrawingToolSettingsView(tool:model.drawingTool)
        }
      }
    }
    .font(.system(size:13)).tint(.primary).buttonStyle(.plain).controlSize(.small)
    .padding(12).frame(width:264).fixedSize(horizontal:false,vertical:true)
    .accessibilityElement(children:.contain).accessibilityIdentifier("drawing-tool-options")
    .accessibilityAction(.escape) { panel = nil }
  }

  private func toolButton(_ drawingTool: DrawingTool) -> some View {
    let selected = model.drawingTool == drawingTool
    return Button {
      if selected { panel = panel == .tool(drawingTool) ? nil : .tool(drawingTool) }
      else { panel = nil; model.selectDrawingTool(drawingTool) }
    } label: {
      Group {
        if drawingTool == .connector {
          Image(uiImage:NotebookConnectionGlyph.image(routing:model.drawingToolSettings.connectionRouting,
            start:model.drawingToolSettings.connectionStart ?? .none,end:model.drawingToolSettings.connectionEnd ?? .arrow,size:.init(width:30,height:26)))
        } else { Image(systemName:drawingTool.symbol) }
      }
      .font(NotebookChrome.iconFont).foregroundStyle(Color.primary).frame(width:32,height:32)
      .background(selected ? NotebookChrome.selectionSurface : .clear,in:RoundedRectangle(cornerRadius:8))
      .frame(width:44,height:44).contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel(drawingTool.title).accessibilityIdentifier(drawingTool.accessibilityID)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint(selected ? "Нажмите ещё раз, чтобы открыть настройки" : "Выбрать инструмент")
  }

  private func sizeControl(title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
    VStack(alignment:.leading,spacing:2) {
      HStack {
        Text(title); Spacer()
        Text(value.wrappedValue,format:.number.precision(.fractionLength(0...1))).monospacedDigit()
        Text("пт").foregroundStyle(.secondary)
      }.font(.caption)
      Slider(value:Binding(get:{ log2(value.wrappedValue) },set:{ value.wrappedValue = pow(2,$0) }),in:log2(range.lowerBound)...log2(range.upperBound))
        .accessibilityLabel(title).accessibilityIdentifier(id)
        .accessibilityValue("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) пунктов")
    }
  }
}
