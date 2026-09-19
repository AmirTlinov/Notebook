import Foundation
import NotebookCore

/// User intent, independent of the persisted pen/eraser journal vocabulary.
/// The input adapters translate contacts; they do not interpret these tools.
enum DrawingTool: String, CaseIterable, Codable, Sendable {
  case pen, marker, eraser, lasso, shape, text, connector, ruler, laser
  var drawsInk: Bool { self == .pen || self == .marker }
  var usesInkJournal: Bool { drawsInk || self == .eraser }
  var title: String {
    switch self {
    case .pen: "Ручка"; case .marker: "Маркер"; case .eraser: "Ластик"; case .lasso: "Лассо"
    case .shape: "Фигуры"; case .text: "Текст"; case .connector: "Связь"; case .ruler: "Линейка"; case .laser: "Указка"
    }
  }
  var symbol: String {
    switch self {
    case .pen: "pencil.tip"; case .marker: "highlighter"; case .eraser: "eraser.fill"; case .lasso: "lasso"
    case .shape: "square.on.circle"; case .text: "textformat"; case .connector: "arrow.up.right"
    case .ruler: "ruler"; case .laser: "cursorarrow.rays"
    }
  }
  var accessibilityID: String { self == .pen ? "pen-controls-toggle" : "drawing-tool-" + rawValue }
  static let primary: [Self] = [.pen, .marker, .eraser, .lasso]
  static let additional: [Self] = [.shape, .text, .connector, .ruler, .laser]
}

enum DrawingShape: String, CaseIterable, Codable, Sendable {
  case line, arrow, rectangle, ellipse, triangle
  var title: String {
    switch self { case .line: "Линия"; case .arrow: "Стрелка"; case .rectangle: "Прямоугольник"; case .ellipse: "Эллипс"; case .triangle: "Треугольник" }
  }
  var symbol: String {
    switch self { case .line: "line.diagonal"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .ellipse: "oval"; case .triangle: "triangle" }
  }
}

/// Device-local preferences. Neither selection, a contact nor authored content
/// is kept here. A contact takes one immutable copy before accepting input.
struct NotebookDrawingToolSettings: Codable, Equatable, Sendable {
  var markerColor: PenColor = .yellow
  var markerWidth = 18.0
  var markerOpacity = 0.3
  var shape: DrawingShape = .rectangle
  var shapeColor: PenColor = .blue
  var shapeWidth = 2.0
  var shapeFilled = false
  var preservesAspect = false
  var textColor: PenColor = .black
  var textSize = 24.0
  var connectionColor: PenColor = .blue
  var connectionWidth = 2.0
  var connectionRouting: NotebookGraphicConnection.Routing = .straight
  var rulerAngle = 0.0
  var rulerSnapToGrid = false
  var laserColor: PenColor = .red
  var laserDuration = 1.5
  var lassoAddsToSelection = false

  var isValid: Bool {
    (4...48).contains(markerWidth) && (0.1...0.65).contains(markerOpacity)
      && (1...12).contains(shapeWidth) && (12...72).contains(textSize)
      && (1...12).contains(connectionWidth) && (-180...180).contains(rulerAngle)
      && (0.5...4).contains(laserDuration)
  }
  var marker: PenStyle { .init(color:markerColor,width:markerWidth,minimumOpacity:markerOpacity,kind:.marker) }
}

/// Finite geometry in the contacted owner's coordinates, not screen pixels.
/// This policy is shared by preview, commit and native contract tests.
enum NotebookToolGeometry {
  static func figure(from start: SpatialPoint, to end: SpatialPoint, shape: DrawingShape,
    preservesAspect: Bool, width: Double) -> NotebookQuickShapeFit? {
    guard [start.x,start.y,end.x,end.y,width].allSatisfy(\.isFinite), width > 0 else { return nil }
    var dx = end.x-start.x, dy = end.y-start.y
    if preservesAspect, shape != .line, shape != .arrow {
      let side = max(abs(dx),abs(dy)); dx = (dx < 0 ? -1 : 1)*side; dy = (dy < 0 ? -1 : 1)*side
    }
    guard hypot(dx,dy) > 0.01 else { return nil }
    let x = min(start.x,start.x+dx), y = min(start.y,start.y+dy)
    let frame = PageRect(x:x,y:y,width:max(width,abs(dx)),height:max(width,abs(dy)))
    if shape == .line || shape == .arrow {
      let connection = NotebookGraphicConnection(
        start:.init(point:.init(x:start.x-x,y:start.y-y)),
        end:.init(point:.init(x:start.x+dx-x,y:start.y+dy-y)),
        endArrowhead:shape == .arrow ? .arrow : .none)
      return .init(frame:frame,sampleCount:2,connection:connection,shape:.connector)
    }
    return .init(frame:frame,sampleCount:2,shape:shape == .ellipse ? .ellipse : shape == .triangle ? .triangle : .rectangle)
  }

  static func rulerEnd(from start: SpatialPoint, to point: SpatialPoint, angle: Double, grid: Double?) -> SpatialPoint {
    let radians = angle * .pi/180, axis = SpatialPoint(x:cos(radians),y:sin(radians))
    var distance = (point.x-start.x)*axis.x + (point.y-start.y)*axis.y
    if let grid, grid > 0 { distance = (distance/grid).rounded()*grid }
    return .init(x:start.x+axis.x*distance,y:start.y+axis.y*distance)
  }

  static func contains(_ point: SpatialPoint, polygon: [SpatialPoint]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    for (a,b) in zip(polygon,polygon.dropFirst()+polygon.prefix(1)) where (a.y > point.y) != (b.y > point.y) {
      if point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
    }
    return inside
  }
}
