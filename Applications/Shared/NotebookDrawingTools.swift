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
    case .shape: "Фигуры"; case .text: "Текст"; case .connector: "Стрелка"; case .ruler: "Линейка"; case .laser: "Указка"
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
  case rectangle, ellipse, triangle
  var title: String {
    switch self { case .rectangle: "Прямоугольник"; case .ellipse: "Эллипс"; case .triangle: "Треугольник" }
  }
  var symbol: String {
    switch self { case .rectangle: "square"; case .ellipse: "circle"; case .triangle: "triangle" }
  }
}

enum NotebookShapeOperation: String, Codable, CaseIterable, Sendable {
  case normal, union, subtract, intersect, exclude
  var title: String {
    switch self { case .normal: "Обычный"; case .union: "Объединение"; case .subtract: "Вычитание";
    case .intersect: "Пересечение"; case .exclude: "Исключение" }
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
  var shapeFillColor: PenColor?
  var shapeOperation: NotebookShapeOperation?
  var preservesAspect = false
  var textColor: PenColor = .black
  var textSize = 24.0
  var textFontName: String?
  var connectionColor: PenColor = .blue
  var connectionWidth = 2.0
  var connectionDash: NotebookGraphic.Style.Dash?
  var connectionStart: NotebookGraphicConnection.Arrowhead?
  var connectionEnd: NotebookGraphicConnection.Arrowhead?
  var connectionRouting: NotebookGraphicConnection.Routing = .straight
  var rulerAngle = 0.0
  var rulerSnapToGrid = false
  var laserColor: PenColor = .red
  var laserTrailLifetime: Double?
  var laserDuration: Double {
    get { laserTrailLifetime ?? 0.6 }
    set { laserTrailLifetime = newValue }
  }
  var lassoAddsToSelection = false
  init() {}
  private var lassoInk: Bool?
  private var lassoObjects: Bool?
  var lassoSelectsInk: Bool {
    get { lassoInk ?? true }
    set { lassoInk = newValue }
  }
  var lassoSelectsObjects: Bool {
    get { lassoObjects ?? true }
    set { lassoObjects = newValue }
  }

  var isValid: Bool {
    (0.5...128).contains(markerWidth) && (0.1...0.65).contains(markerOpacity)
      && (0.25...128).contains(shapeWidth) && (12...72).contains(textSize)
      && (0.25...128).contains(connectionWidth) && (-180...180).contains(rulerAngle)
      && (0.2...4).contains(laserDuration)
  }
  var marker: PenStyle { .init(color:markerColor,width:markerWidth,minimumOpacity:markerOpacity,kind:.marker) }
}

/// Finite geometry in the contacted owner's coordinates, not screen pixels.
/// This policy is shared by preview, commit and native contract tests.
enum NotebookToolGeometry {
  /// Retains corners and loops within a screen-derived error bound. A hard
  /// processing budget increases that bound and recomputes the geometry;
  /// index-based sampling is deliberately avoided because it drops features.
  static func simplifiedPath(_ points: [SpatialPoint], tolerance: Double, maximumCount: Int) -> [SpatialPoint] {
    guard points.count > maximumCount, maximumCount >= 3 else { return points }
    func distanceSquared(_ point: SpatialPoint, from a: SpatialPoint, to b: SpatialPoint) -> Double {
      let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
      guard length > 0 else { return pow(point.x-a.x,2)+pow(point.y-a.y,2) }
      let t=min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/length))
      return pow(point.x-(a.x+t*dx),2)+pow(point.y-(a.y+t*dy),2)
    }
    func simplify(_ threshold: Double) -> [SpatialPoint] {
      var retained=Array(repeating:false,count:points.count),stack=[(0,points.count-1)]
      retained[0]=true;retained[points.count-1]=true
      let thresholdSquared=threshold*threshold
      while let (start,end)=stack.popLast(),end > start+1 {
        var furthest=start+1,maximum=0.0
        for index in (start+1)..<end {
          let distance=distanceSquared(points[index],from:points[start],to:points[end])
          if distance > maximum { maximum=distance;furthest=index }
        }
        if maximum > thresholdSquared {
          retained[furthest]=true;stack.append((start,furthest));stack.append((furthest,end))
        }
      }
      var result=points.indices.compactMap { retained[$0] ? points[$0] : nil }
      if result.count < 3 {
        let index=(1..<(points.count-1)).max {
          distanceSquared(points[$0],from:points[0],to:points.last!)
            < distanceSquared(points[$1],from:points[0],to:points.last!)
        }!
        result=[points[0],points[index],points.last!]
      }
      return result
    }
    var threshold=max(0.000_001,tolerance),result=simplify(max(0.000_001,tolerance))
    while result.count > maximumCount { threshold *= 2;result=simplify(threshold) }
    return result
  }

  static func figure(from start: SpatialPoint, to end: SpatialPoint, shape: DrawingShape,
    preservesAspect: Bool, width: Double) -> NotebookQuickShapeFit? {
    guard [start.x,start.y,end.x,end.y,width].allSatisfy(\.isFinite), width > 0 else { return nil }
    var dx = end.x-start.x, dy = end.y-start.y
    if preservesAspect {
      let side = max(abs(dx),abs(dy)); dx = (dx < 0 ? -1 : 1)*side; dy = (dy < 0 ? -1 : 1)*side
    }
    guard hypot(dx,dy) > 0.01 else { return nil }
    let x = min(start.x,start.x+dx), y = min(start.y,start.y+dy)
    let frame = PageRect(x:x,y:y,width:max(width,abs(dx)),height:max(width,abs(dy)))
    return .init(frame:frame,sampleCount:2,shape:shape == .ellipse ? .ellipse : shape == .triangle ? .triangle : .rectangle)
  }

  static func connection(from start: SpatialPoint, to end: SpatialPoint, width: Double) -> NotebookQuickShapeFit? {
    guard [start.x,start.y,end.x,end.y,width].allSatisfy(\.isFinite), width > 0 else { return nil }
    let x = min(start.x,end.x), y = min(start.y,end.y)
    return .init(frame:.init(x:x,y:y,width:max(width,abs(end.x-start.x)),height:max(width,abs(end.y-start.y))),
      sampleCount:2,connection:.init(start:.init(point:.init(x:start.x-x,y:start.y-y)),
        end:.init(point:.init(x:end.x-x,y:end.y-y))),shape:.connector)
  }

  static func intersects(_ rect: CGRect, polygon: [SpatialPoint]) -> Bool {
    let corners = [SpatialPoint(x:rect.minX,y:rect.minY), .init(x:rect.maxX,y:rect.minY),
      .init(x:rect.maxX,y:rect.maxY), .init(x:rect.minX,y:rect.maxY)]
    return corners.contains { contains($0,polygon:polygon) }
      || polygon.contains { rect.contains(CGPoint(x:$0.x,y:$0.y)) }
      || zip(corners,corners.dropFirst()+corners.prefix(1)).contains { intersects(from:$0,to:$1,polygon:polygon) }
  }

  static func intersects(from a: SpatialPoint, to b: SpatialPoint, polygon: [SpatialPoint]) -> Bool {
    if contains(a,polygon:polygon) || contains(b,polygon:polygon) { return true }
    func cross(_ p: SpatialPoint, _ q: SpatialPoint, _ r: SpatialPoint) -> Double {
      (q.x-p.x)*(r.y-p.y)-(q.y-p.y)*(r.x-p.x)
    }
    return zip(polygon,polygon.dropFirst()+polygon.prefix(1)).contains { c,d in
      guard max(a.x,b.x) >= min(c.x,d.x), max(c.x,d.x) >= min(a.x,b.x),
        max(a.y,b.y) >= min(c.y,d.y), max(c.y,d.y) >= min(a.y,b.y) else { return false }
      return cross(a,b,c)*cross(a,b,d) <= 0 && cross(c,d,a)*cross(c,d,b) <= 0
    }
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
