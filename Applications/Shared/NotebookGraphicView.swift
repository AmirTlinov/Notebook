import NotebookCore
import SwiftUI

/// No WebKit, retained program or independent camera. The parent installs the
/// physical frame; this view paints only that object's local content.
struct NotebookGraphicView: View {
  let graphic: NotebookGraphic
  var layout: NotebookGraphicLayout? = nil
  var body: some View {
    Canvas { context, size in Self.paint(graphic, layout: layout, in: context, size: size) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(graphic.label.isEmpty ? graphic.shape.displayName : graphic.label)
    .accessibilityAddTraits(.isImage)
  }
  static func paint(_ graphic: NotebookGraphic, layout: NotebookGraphicLayout?,
    in context: GraphicsContext, size: CGSize) {
      guard graphic.showsGeometry else { return }
      let stroke = graphic.style.stroke.swiftUIColor
      let width = graphic.style.strokeWidth
      let dash: [CGFloat] = switch graphic.style.dash ?? .solid {
      case .solid: []
      case .dashed: [width*4, width*3]
      case .dotted: [0, width*3]
      }
      let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
      if graphic.shape != .connector {
        let inset = min(width / 2, min(size.width, size.height) / 2 - 0.01)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: max(0, inset), dy: max(0, inset))
        let path = outline(graphic.shape, in:rect)
        if graphic.shape != .plus, let fill = graphic.style.fill { context.fill(path, with: .color(fill.swiftUIColor)) }
        context.stroke(path, with: .color(stroke), style: style)
      } else if let layout {
        var lineContext = context
        if !graphic.label.isEmpty {
          let text = context.resolve(Text(graphic.label).font(.system(size:24)))
          let measured = text.measure(in:size)
          var mask = Path(CGRect(origin:.zero,size:size))
          mask.addRect(.init(x:layout.label.x-measured.width/2-4,y:layout.label.y-measured.height/2-2,
            width:measured.width+8,height:measured.height+4))
          lineContext.clip(to:mask,style:.init(eoFill:true))
        }
        lineContext.stroke(Self.path(layout), with: .color(stroke), style: style)
        for head in layout.heads {
          var path = Path()
          if let first = head.points.first { path.move(to: first.cgPoint) }
          for point in head.points.dropFirst() { path.addLine(to: point.cgPoint) }
          if head.closed { path.closeSubpath() }
          if head.filled { context.fill(path, with: .color(stroke)) }
          context.stroke(path, with: .color(stroke), style: .init(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
      }
      if !graphic.label.isEmpty {
        context.draw(Text(graphic.label).font(.system(size: 24)).foregroundStyle(graphic.style.stroke.swiftUIColor),
          at: layout?.label.cgPoint ?? CGPoint(x: size.width / 2, y: size.height / 2))
      }
  }
  static func path(_ layout: NotebookGraphicLayout) -> Path {
    var path = Path()
    if let first = layout.curves.first { path.move(to: first.start.cgPoint) }
    for curve in layout.curves {
      path.addCurve(to: curve.end.cgPoint, control1: curve.control1.cgPoint, control2: curve.control2.cgPoint)
    }
    return path
  }
  private static func outline(_ shape: NotebookGraphic.Shape, in rect: CGRect) -> Path {
    switch shape {
    case .ellipse: return Path(ellipseIn:rect)
    case .rectangle: return Path(rect)
    case .plus:
      var path = Path()
      path.move(to:.init(x:rect.minX,y:rect.midY)); path.addLine(to:.init(x:rect.maxX,y:rect.midY))
      path.move(to:.init(x:rect.midX,y:rect.minY)); path.addLine(to:.init(x:rect.midX,y:rect.maxY))
      return path
    case .connector: return Path()
    }
  }
}

extension NotebookGraphic.Shape {
  var displayName: String {
    switch self { case .ellipse: "Эллипс"; case .rectangle: "Прямоугольник"; case .plus: "Плюс"; case .connector: "Связь" }
  }
}

extension SpatialPoint { var cgPoint: CGPoint { .init(x: x, y: y) } }

extension SpatialInkColor {
  var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}

struct NotebookGraphicElementView: View {
  @Environment(NotebookAppModel.self) private var model
  let graphic: NotebookGraphic
  let reference: EditableElementReference
  var layout: NotebookGraphicLayout? = nil
  @State private var draft = ""
  @State private var original = ""
  @State private var hasDraft = false
  @FocusState private var focused: Bool

  private var editing: Bool {
    switch (reference, model.interactiveElementFocus) {
    case (.page(let page, let id), .page(let owner, let element)): return page == owner && id == element
    case (.spatial(let board, let id), .board(let owner, let element)): return board == owner && id == element
    default: return false
    }
  }
  var body: some View {
    ZStack {
      NotebookGraphicView(graphic: editing ? unlabelled : graphic, layout: layout)
      if editing {
        TextField("Подпись", text: $draft, axis: .vertical)
          .font(.system(size: 24)).multilineTextAlignment(.center)
          .textFieldStyle(.plain).padding(8).focused($focused)
          .accessibilityIdentifier("graphic-label-editor")
          .onSubmit { finish() }
          .onChange(of: focused) { _, value in if !value { finish() } }
          .onDisappear { finish() }
          .offset(x: (layout?.label.x ?? 0) - (layout?.frame.width ?? 0)/2,
            y: (layout?.label.y ?? 0) - (layout?.frame.height ?? 0)/2)
      }
    }
    .task(id: editing) {
      if editing { original = graphic.label; draft = original; hasDraft = true; focused = true }
    }
    .onChange(of: editing) { _, value in if !value { finish() } }
  }
  private var unlabelled: NotebookGraphic { var value = graphic; value.label = ""; return value }
  private func finish() {
    guard hasDraft else { return }
    hasDraft = false
    model.setGraphicLabel(draft, reference: reference, replacing: original)
    if editing { model.interactiveElementFocus = nil }
  }
}
