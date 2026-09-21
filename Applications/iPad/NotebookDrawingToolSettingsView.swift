import NotebookCore
import SwiftUI

/// Controls edit only device-local preferences. Commands and gestures live in
/// the tool controller; changing a slider never writes page/board content.
struct NotebookDrawingToolSettingsView: View {
  @Environment(NotebookAppModel.self) private var model
  let tool: DrawingTool

  var body: some View {
    switch tool {
    case .marker:
      slider("Толщина маркера", path: \.markerWidth, range: 0.5...128, id:"marker-width",logarithmic:true)
      slider("Непрозрачность маркера", path: \.markerOpacity, range: 0.1...0.65, id:"marker-opacity")
    case .lasso:
      Picker("Режим",selection:binding(\.lassoMode)) {
        ForEach(NotebookLassoMode.allCases,id:\.self) { mode in Text(mode.title).tag(mode) }
      }
      .pickerStyle(.segmented).accessibilityIdentifier("lasso-mode")
      if model.drawingToolSettings.lassoMode == .elements {
        Toggle("Добавлять к выделению",isOn:binding(\.lassoAddsToSelection))
          .accessibilityIdentifier("lasso-adds-selection")
      } else {
        Text("Выделяет только рукопись внутри обведённой области.")
          .font(.caption).foregroundStyle(.secondary)
      }
    case .shape:
      HStack {
        Picker("Фигура",selection:binding(\.shape)) {
          ForEach(DrawingShape.allCases,id:\.self) { shape in Label(shape.title,systemImage:shape.symbol).tag(shape) }
        }
        .pickerStyle(.menu).labelsHidden().labelStyle(.iconOnly)
        .accessibilityValue(model.drawingToolSettings.shape.title)
        .accessibilityIdentifier("drawing-shape-kind")
        Spacer(minLength:12)
        Picker("Наложение",selection:Binding(get:{ model.drawingToolSettings.shapeOperation ?? .normal },set:{ model.drawingToolSettings.shapeOperation = $0 })) {
          ForEach(NotebookShapeOperation.allCases,id:\.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden()
        .accessibilityIdentifier("shape-operation")
      }
      slider("Толщина контура",path:\.shapeWidth,range:0.25...128,id:"shape-width",logarithmic:true)
      Toggle("Заливка",isOn:binding(\.shapeFilled)).accessibilityIdentifier("shape-fill")
      if model.drawingToolSettings.shapeFilled {
        Text("Цвет заливки").font(.caption)
        NotebookToolColorPalette(selection:Binding(get:{ model.drawingToolSettings.shapeFillColor ?? .yellow },set:{ model.drawingToolSettings.shapeFillColor = $0 }),prefix:"shape-fill")
      }
      Toggle("Фиксированные пропорции",isOn:binding(\.preservesAspect)).accessibilityIdentifier("shape-aspect")
    case .text:
      Picker("Шрифт новых надписей",selection:Binding(get:{ model.drawingToolSettings.textFontName ?? "" },set:{ model.drawingToolSettings.textFontName = $0.isEmpty ? nil : $0 })) {
        ForEach(NotebookTextTypography.fonts,id:\.title) { font in Text(font.title).tag(font.name ?? "") }
      }.accessibilityIdentifier("text-default-font")
      slider("Размер текста",path:\.textSize,range:12...72,id:"text-size")
    case .connector:
      slider("Толщина стрелки",path:\.connectionWidth,range:0.25...128,id:"connector-width",logarithmic:true)
      HStack(spacing:8) {
        arrowhead("Начало",path:\.connectionStart,defaultValue:.none,terminal:.start)
        arrowhead("Конец",path:\.connectionEnd,defaultValue:.arrow,terminal:.end)
      }
      HStack(spacing:0) {
        ForEach(NotebookGraphicConnection.Routing.allCases,id:\.self) { routing in
          glyphChoice(NotebookConnectionGlyph.image(routing:routing,size:.init(width:48,height:22)),
            title:routing.controlTitle,id:"connector-routing-"+routing.rawValue,
            selected:model.drawingToolSettings.connectionRouting == routing) { model.drawingToolSettings.connectionRouting = routing }
        }
      }
      HStack(spacing:0) {
        ForEach(NotebookGraphic.Style.Dash.allCases,id:\.self) { dash in
          glyphChoice(NotebookConnectionGlyph.image(dash:dash,size:.init(width:42,height:22)),
            title:dash.controlTitle,id:"connector-dash-"+dash.rawValue,
            selected:(model.drawingToolSettings.connectionDash ?? .solid) == dash) { model.drawingToolSettings.connectionDash = dash }
        }
      }
    case .ruler:
      slider("Угол: \(Int(model.drawingToolSettings.rulerAngle))°",path:\.rulerAngle,range:-180...180,id:"ruler-angle",step:1)
      HStack {
        ForEach([0.0,45,90],id:\.self) { angle in
          Button("\(Int(angle))°") { model.drawingToolSettings.rulerAngle = angle }
        }
      }
      Toggle("Привязка длины к сетке",isOn:binding(\.rulerSnapToGrid)).accessibilityIdentifier("ruler-grid")
      Text("Пальцем перемещайте линейку; круглый конец поворачивает. 1 см = 2 клетки.")
        .font(.caption).foregroundStyle(.secondary)
        .onChange(of:model.drawingToolSettings.rulerAngle) { _,angle in model.drawingTools.ruler?.angle = angle }
    case .laser:
      slider("След: \(String(format:"%.1f",model.drawingToolSettings.laserDuration)) с",path:\.laserDuration,range:0.2...2,id:"laser-duration",step:0.1)
    case .pen, .eraser: EmptyView()
    }
  }

  private func binding<T>(_ path: WritableKeyPath<NotebookDrawingToolSettings,T>) -> Binding<T> {
    .init(get:{ model.drawingToolSettings[keyPath:path] },set:{ model.drawingToolSettings[keyPath:path] = $0 })
  }
  private func glyphChoice(_ image: UIImage, title: String, id: String, selected: Bool,
    action: @escaping () -> Void) -> some View {
    Button(action:action) {
      Image(uiImage:image).frame(maxWidth:.infinity,minHeight:40)
        .background(selected ? NotebookChrome.selectionSurface : .clear,in:RoundedRectangle(cornerRadius:6))
        .contentShape(Rectangle())
    }
    .accessibilityLabel(title).accessibilityIdentifier(id)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func arrowhead(_ title: String, path: WritableKeyPath<NotebookDrawingToolSettings,NotebookGraphicConnection.Arrowhead?>,
    defaultValue: NotebookGraphicConnection.Arrowhead, terminal: NotebookGraphicConnection.Terminal) -> some View {
    let current = model.drawingToolSettings[keyPath:path] ?? defaultValue
    return Menu {
      Picker(title,selection:Binding(get:{ model.drawingToolSettings[keyPath:path] ?? defaultValue },set:{ model.drawingToolSettings[keyPath:path] = $0 })) {
        ForEach(NotebookGraphicConnection.Arrowhead.allCases,id:\.self) { head in
          Label { Text(head.controlTitle) } icon: {
            Image(uiImage:NotebookConnectionGlyph.image(start:terminal == .start ? head : .none,
              end:terminal == .end ? head : .none,size:.init(width:48,height:20)))
          }.tag(head)
        }
      }.pickerStyle(.inline)
    } label: {
      HStack(spacing:6) {
        Image(uiImage:NotebookConnectionGlyph.image(start:terminal == .start ? current : .none,
          end:terminal == .end ? current : .none,size:.init(width:68,height:22)))
        Image(systemName:"chevron.up.chevron.down").font(.caption2)
      }.frame(maxWidth:.infinity,minHeight:40).contentShape(Rectangle())
    }
    .accessibilityLabel(title).accessibilityValue(current.controlTitle)
    .accessibilityIdentifier("connector-head-"+terminal.rawValue)
  }
  private func slider(_ title: String, path: WritableKeyPath<NotebookDrawingToolSettings,Double>, range: ClosedRange<Double>, id: String, step: Double = 0.01, logarithmic: Bool = false) -> some View {
    VStack(alignment:.leading,spacing:6) {
      HStack { Text(title); Spacer(); Text(model.drawingToolSettings[keyPath:path],format:.number.precision(.fractionLength(0...2))).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
      Slider(value:Binding(get:{ logarithmic ? log2(model.drawingToolSettings[keyPath:path]) : model.drawingToolSettings[keyPath:path] },
        set:{ model.drawingToolSettings[keyPath:path] = logarithmic ? pow(2,$0) : $0 }),
        in:logarithmic ? log2(range.lowerBound)...log2(range.upperBound) : range,step:step).accessibilityLabel(title).accessibilityIdentifier(id)
    }
  }
}

struct NotebookToolColorPalette: View {
  @Binding var selection: PenColor
  let prefix: String
  var body: some View {
    HStack(spacing:0) {
      ForEach(PenColor.allCases) { color in
        Button { selection = color } label: {
          Circle().fill(color.displayColor).frame(width:22,height:22).padding(4)
            .overlay { Circle().stroke(color == selection ? Color.primary : .clear,lineWidth:1) }
            .frame(maxWidth:.infinity,minHeight:40).contentShape(Rectangle())
        }
        .accessibilityLabel(color.name).accessibilityIdentifier(prefix+"-color-"+color.rawValue)
        .accessibilityAddTraits(color == selection ? .isSelected : [])
      }
    }
  }
}
