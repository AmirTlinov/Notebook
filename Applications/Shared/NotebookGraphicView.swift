import NotebookCore
import SwiftUI

/// No WebKit, retained program or independent camera. The parent installs the
/// physical frame; this view paints only that object's local content.
struct NotebookGraphicView: View {
  let graphic: NotebookGraphic
  var layout: NotebookGraphicLayout? = nil
  var erasures: [InkElementErasure] = []
  var appearance: NotebookElementAppearance? = nil
  var live = true
  var paintsMeasuredBody = true
  var layer:PaintLayer = .content
  var body: some View {
    // Retire the accessibility node together with the material, not only its pixels.
    if appearance?.state != .erased {
      Group {
        if live {
          ZStack {
            if let ink = graphic.freehand, graphic.showsGeometry {
              if layer != .fillMask,paintsMeasuredBody {
                NotebookInkMaterialView(freehand:ink,transform:graphic.transform,layout:layout,mask:graphic.mask)
              }
              if layer != .fillMask,!graphic.label.isEmpty {
                Canvas { context, size in
                  var context = context
                  if let projection = layout?.projection { context.concatenate(projection.transform) }
                  let size = layout?.projection?.size ?? size
                  context.draw(Text(graphic.label).font(.system(size:24)).foregroundStyle(graphic.style.stroke.swiftUIColor),
                    at:.init(x:size.width/2,y:size.height/2))
                }
              }
            } else {
              Canvas { context, size in Self.paint(graphic, layout:layout, in:context, size:size,layer:layer,clipVisibility:false,paintsMeasuredBody:paintsMeasuredBody) }
            }
          }
          .clipShape(NotebookGraphicMaskShape(mask:graphic.mask,projection:layout?.projection),style:FillStyle(eoFill:true))
          .erased(by:erasures,appearance:appearance,transform:graphic.transform,layout:layout,visibility:graphic.mask)
        } else {
          Canvas { context, size in Self.paint(graphic, layout:layout, in:context, size:size, erasures:erasures, appearance:appearance,layer:layer,paintsMeasuredBody:paintsMeasuredBody) }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(graphic.label.isEmpty ? graphic.shape.displayName : graphic.label)
      .accessibilityAddTraits(.isImage)
    }
  }

  enum PaintLayer { case content, inkMask, fillMask }

  static func paint(_ graphic: NotebookGraphic, layout: NotebookGraphicLayout?,
    in context: GraphicsContext, size: CGSize, erasures: [InkElementErasure] = [],
    appearance: NotebookElementAppearance? = nil, layer: PaintLayer = .content,clipVisibility:Bool = true,paintsMeasuredBody:Bool = true) {
      guard graphic.showsGeometry, appearance?.state != .erased else { return }
      var context = context
      if let layout, let projection = layout.projection {
        if let appearance { context.clip(to:Path(appearance.mask),options:.inverse) }
        context.concatenate(projection.transform)
        paint(graphic,layout:layout.localLayout,in:context,size:projection.size,
          erasures:appearance == nil ? erasures : [],layer:layer,clipVisibility:clipVisibility,paintsMeasuredBody:paintsMeasuredBody)
        return
      }
      if let appearance { context.clip(to:Path(appearance.mask),options:.inverse) }
      else { NotebookElementErasurePaint.clip(erasures, context: &context, size: size,transform:graphic.transform) }
      if clipVisibility,let mask=graphic.mask { context.clip(to:Path(mask.path(in:.init(origin:.zero,size:size))),style:.init(eoFill:true)) }
      if let ink = graphic.freehand {
        if layer != .fillMask,paintsMeasuredBody { NotebookFreehandPaint.paint(ink,transform:graphic.transform,context:context,size:size,mask:layer != .content) }
        if !graphic.label.isEmpty, layer != .fillMask {
          context.draw(Text(graphic.label).font(.system(size:24)).foregroundStyle(graphic.style.stroke.swiftUIColor),at:.init(x:size.width/2,y:size.height/2))
        }
        return
      }
      let stroke = layer == .content ? graphic.style.stroke.swiftUIColor : .white
      let width = graphic.style.strokeWidth
      let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: graphic.style.dashPattern)
      if graphic.shape != .connector {
        let inset = min(width / 2, min(size.width, size.height) / 2 - 0.01)
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: max(0, inset), dy: max(0, inset))
        let path = outline(graphic, in:rect)
        if layer != .inkMask, graphic.shape != .plus, let fill = graphic.style.fill { context.fill(path, with: .color(layer == .content ? fill.swiftUIColor : .white)) }
        if layer != .fillMask { context.stroke(path, with: .color(stroke), style: style) }
      } else if let layout, layer != .fillMask {
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
      if !graphic.label.isEmpty, layer != .fillMask {
        context.draw(Text(graphic.label).font(.system(size: 24)).foregroundStyle(stroke),
          at: layout?.label.cgPoint ?? CGPoint(x: size.width / 2, y: size.height / 2))
      }
  }
  static func path(_ layout: NotebookGraphicLayout) -> Path {
    Path(NotebookGraphicGeometry.connectionPath(layout))
  }
  private static func outline(_ graphic: NotebookGraphic, in rect: CGRect) -> Path {
    Path(NotebookGraphicGeometry.outlinePath(graphic,in:rect))
  }
}

private struct NotebookGraphicMaskShape:Shape {
  let mask:NotebookGraphicMask?
  let projection:NotebookGraphicLayout.Projection?
  func path(in rect:CGRect)->Path { Path(mask?.projectedRegionPath(in:rect,projection:projection) ?? CGPath(rect:rect,transform:nil)) }
}

extension NotebookGraphic.Shape {
  var displayName: String {
    switch self { case .ellipse: "Эллипс"; case .rectangle: "Прямоугольник"; case .triangle: "Треугольник"; case .diamond: "Ромб"; case .plus: "Плюс"; case .connector: "Стрелка"; case .freehand: "Рукопись"; case .path: "Контур" }
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
  var erasures:[InkElementErasure] = []
  var appearance:NotebookElementAppearance? = nil
  var paintsMeasuredBody = true
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
      NotebookGraphicView(graphic: editing ? unlabelled : graphic, layout: layout,erasures:erasures,appearance:appearance,paintsMeasuredBody:paintsMeasuredBody)
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
