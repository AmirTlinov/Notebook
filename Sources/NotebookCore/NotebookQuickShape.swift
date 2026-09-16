import Foundation

public struct NotebookQuickShapeFit: Equatable, Sendable {
  public var frame: PageRect
  public let sampleCount: Int
  public var connection: NotebookGraphicConnection?
  public var resolvedLayout: NotebookGraphicLayout?
  public var shape: NotebookGraphic.Shape { connection == nil ? .ellipse : .connector }
  public init(frame: PageRect, sampleCount: Int, connection: NotebookGraphicConnection? = nil) {
    self.frame = frame; self.sampleCount = sampleCount; self.connection = connection
  }
  public func scaled(by scale: Double, frameOrigin: SpatialPoint) -> Self {
    var value = self
    value.frame = .init(x:frameOrigin.x,y:frameOrigin.y,width:frame.width*scale,height:frame.height*scale)
    if var connection {
      connection.start.point = .init(x:connection.start.point.x*scale,y:connection.start.point.y*scale)
      connection.end.point = .init(x:connection.end.point.x*scale,y:connection.end.point.y*scale)
      connection.bend *= scale
      value.connection = connection
    }
    value.resolvedLayout = nil
    return value
  }
  public func binding(in graph: NotebookGraphicGraph, surface: SurfaceID, origin: WorldPoint = .zero,
    tolerance: Double) -> Self {
    guard var connection else { return self }
    for terminal in NotebookGraphicConnection.Terminal.allCases {
      var endpoint = terminal == .start ? connection.start : connection.end
      endpoint.binding = graph.binding(at:.init(x:frame.x+endpoint.point.x,y:frame.y+endpoint.point.y),
        origin:origin,surface:surface,tolerance:tolerance)
      if terminal == .start { connection.start = endpoint } else { connection.end = endpoint }
    }
    var result = self; result.connection = connection
    let id = UUID().uuidString
    let candidate = NotebookGraphicGraph.Node(id:id,graphic:.init(shape:.connector,connection:connection),frame:frame,
      origin:origin,surface:surface,shown:true)
    result.resolvedLayout = NotebookGraphicGraph(Array(graph.nodes.values)+[candidate]).resolve(id).layout
    return result
  }
  public var layout: NotebookGraphicLayout? {
    if let resolvedLayout { return resolvedLayout }
    return NotebookGraphicGraph([.init(id:"preview",graphic:.init(shape:shape,connection:connection),frame:frame,
      surface:.board(UUID()),shown:true)]).resolve("preview").layout
  }
}

/// Runs once after a deliberate hold, never in the normal handwriting loop.
/// This fit is deliberately conservative: a miss retains all measured ink.
public enum NotebookQuickShape {
  public static func recognize(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    ellipse(measured,screenScale:screenScale) ?? connector(measured,screenScale:screenScale)
  }

  /// One measured stroke only. A five-turn continuous arrow is unambiguous;
  /// multi-stroke source selection belongs to the later recognition slice.
  public static func connector(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    guard (8...8192).contains(measured.count), screenScale.isFinite, screenScale > 0,
      measured.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
    let points = resampled(measured,count:128)
    guard let first = points.first, let last = points.last else { return nil }
    func distance(_ a: SpatialPoint,_ b: SpatialPoint) -> Double { hypot(b.x-a.x,b.y-a.y) }
    func deviation(_ point: SpatialPoint,_ a: SpatialPoint,_ b: SpatialPoint) -> Double {
      let length = distance(a,b)
      guard length > 0 else { return distance(point,a) }
      let t = min(1,max(0,((point.x-a.x)*(b.x-a.x)+(point.y-a.y)*(b.y-a.y))/(length*length)))
      return hypot(point.x-a.x-t*(b.x-a.x),point.y-a.y-t*(b.y-a.y))
    }
    func simplify(_ points: ArraySlice<SpatialPoint>, depth: Int = 0) -> [SpatialPoint] {
      guard points.count > 2, depth < 12, let a = points.first, let b = points.last else { return Array(points) }
      let furthest = points.indices.dropFirst().dropLast().max { deviation(points[$0],a,b) < deviation(points[$1],a,b) }!
      guard deviation(points[furthest],a,b)*screenScale > 3 else { return [a,b] }
      return simplify(points[...furthest],depth:depth+1).dropLast() + simplify(points[furthest...],depth:depth+1)
    }
    let length = distance(first,last)
    let travelled = zip(points,points.dropFirst()).reduce(0.0) { $0+distance($1.0,$1.1) }
    let end: SpatialPoint, head: NotebookGraphicConnection.Arrowhead
    if length*screenScale >= 40, travelled/length < 1.08,
      points.allSatisfy({ deviation($0,first,last)*screenScale < max(3,length*screenScale*0.025) }) {
      end = last; head = .none
    } else {
      let vertices = simplify(points[...])
      guard vertices.count == 5 else { return nil }
      let tip = vertices[1], shaft = distance(first,tip)
      guard shaft*screenScale > 48, distance(tip,vertices[3])*screenScale < max(8,shaft*screenScale*0.06) else { return nil }
      let ux = (tip.x-first.x)/shaft, uy = (tip.y-first.y)/shaft
      func wing(_ point: SpatialPoint) -> (along:Double,across:Double) {
        let x = point.x-tip.x,y = point.y-tip.y
        return ((x*ux+y*uy)/shaft,(-x*uy+y*ux)/shaft)
      }
      let a = wing(vertices[2]), b = wing(vertices[4])
      guard (-0.4 ... -0.06).contains(a.along),(-0.4 ... -0.06).contains(b.along),
        (0.06...0.35).contains(abs(a.across)),(0.06...0.35).contains(abs(b.across)),a.across*b.across < 0,
        max(abs(a.across),abs(b.across))/min(abs(a.across),abs(b.across)) < 2.5 else { return nil }
      end = tip; head = .arrow
    }
    let x = measured.map(\.x).min()!,y = measured.map(\.y).min()!
    let frame = PageRect(x:x,y:y,width:max(1,measured.map(\.x).max()!-x),height:max(1,measured.map(\.y).max()!-y))
    return .init(frame:frame,sampleCount:measured.count,connection:.init(
      start:.init(point:.init(x:first.x-x,y:first.y-y)),end:.init(point:.init(x:end.x-x,y:end.y-y)),endArrowhead:head))
  }
  public static func ellipse(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    guard measured.count >= 12, measured.count <= 8192, screenScale.isFinite, screenScale > 0,
      measured.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
    let minX = measured.map(\.x).min()!, maxX = measured.map(\.x).max()!
    let minY = measured.map(\.y).min()!, maxY = measured.map(\.y).max()!
    let width = maxX - minX, height = maxY - minY
    guard min(width, height) * screenScale >= 24, max(width, height) / min(width, height) <= 8 else { return nil }
    let first = measured.first!, last = measured.last!
    guard hypot(last.x - first.x, last.y - first.y) < min(width, height) * 0.23 else { return nil }
    // Arc-length sampling prevents a long stationary hold or slow corner from
    // outweighing the rest of a square/scribble and turning it into a circle.
    let points = resampled(measured, count: 128)
    guard points.count == 128 else { return nil }
    var radialError = 0.0, travelled = 0.0, winding = 0.0, reversed = 0.0
    var priorAngle: Double?, prior: SpatialPoint?
    for point in points {
      let x = (point.x - (minX + maxX) / 2) * 2 / width
      let y = (point.y - (minY + maxY) / 2) * 2 / height
      radialError += pow(hypot(x, y) - 1, 2)
      let angle = atan2(y, x)
      if let priorAngle {
        var delta = angle - priorAngle
        if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }
        winding += delta; reversed += abs(delta)
      }
      if let prior { travelled += hypot(point.x - prior.x, point.y - prior.y) }
      priorAngle = angle; prior = point
    }
    let a = width / 2, b = height / 2
    let circumference = .pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
    guard sqrt(radialError / Double(points.count)) < 0.09,
      abs(winding) > 5.5, abs(winding) < 7, reversed < abs(winding) * 1.15,
      travelled / circumference > 0.83, travelled / circumference < 1.2 else { return nil }
    return .init(frame: .init(x: minX, y: minY, width: width, height: height), sampleCount: measured.count)
  }
  private static func resampled(_ points: [SpatialPoint], count: Int) -> [SpatialPoint] {
    var distances = [0.0]
    for index in 1..<points.count {
      distances.append(distances.last! + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
    }
    guard let total = distances.last, total > 0 else { return [] }
    var result: [SpatialPoint] = [], segment = 1
    for index in 0..<count {
      let distance = total * Double(index) / Double(count - 1)
      while segment < distances.count - 1 && distances[segment] < distance { segment += 1 }
      let span = distances[segment] - distances[segment - 1]
      let t = span > 0 ? (distance - distances[segment - 1]) / span : 0
      result.append(.init(x: points[segment - 1].x + (points[segment].x - points[segment - 1].x) * t,
        y: points[segment - 1].y + (points[segment].y - points[segment - 1].y) * t))
    }
    return result
  }

}
