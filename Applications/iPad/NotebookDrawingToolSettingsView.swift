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
      colors(\.markerColor)
      slider("Толщина маркера", path: \.markerWidth, range: 4...48, id:"marker-width")
      slider("Непрозрачность маркера", path: \.markerOpacity, range: 0.1...0.65, id:"marker-opacity")
    case .lasso:
      Toggle("Добавлять к выделению",isOn:binding(\.lassoAddsToSelection))
        .accessibilityIdentifier("lasso-adds-selection")
    case .shape:
      Picker("Фигура",selection:binding(\.shape)) {
        ForEach(DrawingShape.allCases,id:\.self) { shape in Label(shape.title,systemImage:shape.symbol).tag(shape) }
      }.accessibilityIdentifier("drawing-shape-kind")
      colors(\.shapeColor)
      slider("Толщина контура",path:\.shapeWidth,range:1...12,id:"shape-width")
      Toggle("Заливка",isOn:binding(\.shapeFilled)).accessibilityIdentifier("shape-fill")
      Toggle("Круг / квадрат",isOn:binding(\.preservesAspect)).accessibilityIdentifier("shape-aspect")
    case .text:
      colors(\.textColor)
      slider("Размер текста",path:\.textSize,range:12...72,id:"text-size")
    case .connector:
      colors(\.connectionColor)
      slider("Толщина связи",path:\.connectionWidth,range:1...12,id:"connector-width")
      Picker("Линия",selection:binding(\.connectionRouting)) {
        Text("Прямая").tag(NotebookGraphicConnection.Routing.straight)
        Text("Угловая").tag(NotebookGraphicConnection.Routing.elbow)
        Text("Кривая").tag(NotebookGraphicConnection.Routing.curved)
      }.accessibilityIdentifier("connector-routing")
    case .ruler:
      slider("Угол: \(Int(model.drawingToolSettings.rulerAngle))°",path:\.rulerAngle,range:-180...180,id:"ruler-angle",step:1)
      HStack {
        ForEach([0.0,45,90],id:\.self) { angle in
          Button("\(Int(angle))°") { model.drawingToolSettings.rulerAngle = angle }
        }
      }
      Toggle("Привязка длины к сетке",isOn:binding(\.rulerSnapToGrid)).accessibilityIdentifier("ruler-grid")
      Text("Проведите пером вдоль выбранного направления. Цвет и толщина — как у ручки.")
        .font(.caption).foregroundStyle(.secondary)
    case .laser:
      colors(\.laserColor)
      slider("След: \(String(format:"%.1f",model.drawingToolSettings.laserDuration)) с",path:\.laserDuration,range:0.5...4,id:"laser-duration",step:0.5)
    case .pen, .eraser: EmptyView()
    }
  }

  private func binding<T>(_ path: WritableKeyPath<NotebookDrawingToolSettings,T>) -> Binding<T> {
    .init(get:{ model.drawingToolSettings[keyPath:path] },set:{ model.drawingToolSettings[keyPath:path] = $0 })
  }
  private func colors(_ path: WritableKeyPath<NotebookDrawingToolSettings,PenColor>) -> some View {
    HStack {
      ForEach(PenColor.allCases) { color in
        Button { model.drawingToolSettings[keyPath:path] = color } label: {
          Circle().fill(color.displayColor).frame(width:22,height:22).padding(4)
            .overlay { Circle().stroke(color == model.drawingToolSettings[keyPath:path] ? Color.primary : .clear,lineWidth:2) }
            .frame(width:44,height:44).contentShape(Rectangle())
        }
        .accessibilityLabel(color.name)
        .accessibilityIdentifier(tool.rawValue + "-color-" + color.rawValue)
        .accessibilityAddTraits(color == model.drawingToolSettings[keyPath:path] ? .isSelected : [])
      }
    }
  }
  private func slider(_ title: String, path: WritableKeyPath<NotebookDrawingToolSettings,Double>, range: ClosedRange<Double>, id: String, step: Double = 0.01) -> some View {
    VStack(alignment:.leading,spacing:6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Slider(value:binding(path),in:range,step:step).accessibilityLabel(title).accessibilityIdentifier(id)
    }
  }
}
