import Foundation

public struct NotebookQuickShapeFit: Equatable, Sendable {
  public var frame: PageRect
  public let sampleCount: Int
  public var connection: NotebookGraphicConnection?
  public let shape: NotebookGraphic.Shape
  public var precedingStrokeIDs: [UUID] = []
  public init(frame: PageRect, sampleCount: Int, connection: NotebookGraphicConnection? = nil,
    shape: NotebookGraphic.Shape = .ellipse) {
    self.frame = frame; self.sampleCount = sampleCount; self.connection = connection
    self.shape = connection == nil ? shape : .connector
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
    return result
  }
}

/// A bounded geometric fit after an intentional hold. Stroke order and pen
/// lifts are not shape features; all measured points must explain the result.
public enum NotebookQuickShape {
  public static func recognize(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    recognize(strokes: [measured], screenScale: screenScale)
  }

  public static func recognize(strokes: [[SpatialPoint]], screenScale: Double) -> NotebookQuickShapeFit? {
    guard (1...4).contains(strokes.count), valid(strokes, scale: screenScale) else { return nil }
    let paths = strokes.map { resampled($0, count: 96) }
    let points = paths.flatMap { $0 }, count = strokes.last!.count
    if let frame = rectangle(points, scale: screenScale) {
      return .init(frame: frame, sampleCount: count, shape: .rectangle)
    }
    if strokes.count == 1, let fit = ellipse(strokes[0], screenScale: screenScale) { return fit }
    if let frame = plus(points, scale: screenScale) {
      return .init(frame: frame, sampleCount: count, shape: .plus)
    }
    if let fit = arrow(paths, count: count, scale: screenScale) { return fit }
    // Separate strokes must describe one compound figure, never an unrelated
    // bundle of lines. A standalone line still uses its measured direction.
    return strokes.count == 1 ? line(strokes[0], scale: screenScale) : nil
  }

  public static func connector(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    guard valid([measured], scale: screenScale) else { return nil }
    return arrow([resampled(measured, count: 96)], count: measured.count, scale: screenScale)
      ?? line(measured, scale: screenScale)
  }

  private static func valid(_ strokes: [[SpatialPoint]], scale: Double) -> Bool {
    scale.isFinite && scale > 0 && strokes.reduce(0, { $0 + $1.count }) <= 8192
      && strokes.allSatisfy { $0.count >= 2 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        && length($0) * scale >= 8 }
  }
  private static func distance(_ a: SpatialPoint, _ b: SpatialPoint) -> Double { hypot(b.x-a.x, b.y-a.y) }
  private static func length(_ points: [SpatialPoint]) -> Double {
    zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
  }
  private static func bounds(_ points: [SpatialPoint]) -> PageRect {
    let x = points.map(\.x).min()!, y = points.map(\.y).min()!
    return .init(x: x, y: y, width: max(1, points.map(\.x).max()!-x), height: max(1, points.map(\.y).max()!-y))
  }
  private static func deviation(_ point: SpatialPoint, _ a: SpatialPoint, _ b: SpatialPoint) -> Double {
    let dx = b.x-a.x, dy = b.y-a.y, square = dx*dx+dy*dy
    let t = square > 0 ? min(1, max(0, ((point.x-a.x)*dx+(point.y-a.y)*dy)/square)) : 0
    return hypot(point.x-a.x-t*dx, point.y-a.y-t*dy)
  }
  private static func line(_ measured: [SpatialPoint], scale: Double) -> NotebookQuickShapeFit? {
    guard measured.count >= 4, let first = measured.first, let last = measured.last else { return nil }
    let span = distance(first, last), points = resampled(measured, count: 96)
    guard span*scale >= 28, length(measured)/span < 1.22,
      points.allSatisfy({ deviation($0,first,last) < max(3/scale,span*0.045) }) else { return nil }
    return connection(points: measured, tail: first, tip: last, head: .none, count: measured.count)
  }
  private static func connection(points: [SpatialPoint], tail: SpatialPoint, tip: SpatialPoint,
    head: NotebookGraphicConnection.Arrowhead, count: Int) -> NotebookQuickShapeFit {
    let frame = bounds(points)
    return .init(frame: frame, sampleCount: count, connection: .init(
      start: .init(point: .init(x:tail.x-frame.x,y:tail.y-frame.y)),
      end: .init(point: .init(x:tip.x-frame.x,y:tip.y-frame.y)), endArrowhead: head))
  }

  private static func rectangle(_ points: [SpatialPoint], scale: Double) -> PageRect? {
    let frame = bounds(points), w = frame.width, h = frame.height
    guard min(w,h)*scale >= 24, max(w,h)/min(w,h) <= 8 else { return nil }
    let normalized = points.map { SpatialPoint(x:($0.x-frame.x)/w,y:($0.y-frame.y)/h) }
    let corners = [SpatialPoint(x:0,y:0), .init(x:1,y:0), .init(x:1,y:1), .init(x:0,y:1)]
    guard corners.allSatisfy({ corner in normalized.contains { distance($0,corner) < 0.19 } }) else { return nil }
    var coverage = Array(repeating: Set<Int>(), count: 4), error = 0.0
    for p in normalized {
      let distances = [abs(p.y),abs(1-p.x),abs(1-p.y),abs(p.x)]
      let side = distances.indices.min { distances[$0] < distances[$1] }!
      let d = distances[side]; error += d*d
      guard d < 0.14 else { return nil }
      let position = side % 2 == 0 ? p.x : p.y
      coverage[side].insert(min(7,max(0,Int(position*8))))
    }
    guard sqrt(error/Double(points.count)) < 0.065, coverage.allSatisfy({ $0.count >= 6 }) else { return nil }
    if max(w,h)/min(w,h) < 1.18 {
      let side = (w+h)/2
      return .init(x:frame.x+(w-side)/2,y:frame.y+(h-side)/2,width:side,height:side)
    }
    return frame
  }

  private static func plus(_ points: [SpatialPoint], scale: Double) -> PageRect? {
    let frame = bounds(points), w = frame.width, h = frame.height
    guard min(w,h)*scale >= 24, max(w,h)/min(w,h) < 2.3 else { return nil }
    let center = SpatialPoint(x:frame.x+w/2,y:frame.y+h/2)
    var coverage = Array(repeating: Set<Int>(), count: 4), error = 0.0
    for point in points {
      let x = (point.x-center.x)/w, y = (point.y-center.y)/h
      let horizontal = abs(y) < abs(x), d = min(abs(x),abs(y))
      guard d < 0.12 else { return nil }; error += d*d
      let position = horizontal ? x : y
      let arm = (horizontal ? 0 : 2)+(position < 0 ? 0 : 1)
      coverage[arm].insert(min(3,max(0,Int(abs(position)*8))))
    }
    guard sqrt(error/Double(points.count)) < 0.045, coverage.allSatisfy({ $0.count >= 3 }) else { return nil }
    return frame
  }

  public static func ellipse(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    guard measured.count >= 8, valid([measured], scale: screenScale) else { return nil }
    let points = resampled(measured, count: 128), frame = bounds(points)
    let width = frame.width, height = frame.height
    guard min(width,height)*screenScale >= 24, max(width,height)/min(width,height) <= 8,
      distance(measured.first!,measured.last!) < min(width,height)*0.36,
      rectangle(points,scale:screenScale) == nil else { return nil }
    var error = 0.0, winding = 0.0, reversed = 0.0, prior: Double?
    for point in points {
      let x = (point.x-frame.x-width/2)*2/width, y = (point.y-frame.y-height/2)*2/height
      error += pow(hypot(x,y)-1,2)
      let angle = atan2(y,x)
      if let prior {
        var delta = angle-prior
        if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }
        winding += delta; reversed += abs(delta)
      }
      prior = angle
    }
    let a = width/2, b = height/2
    let circumference = Double.pi*(3*(a+b)-sqrt((3*a+b)*(a+3*b)))
    guard sqrt(error/Double(points.count)) < 0.145,
      abs(winding) > 5.0, abs(winding) < 7.5, reversed < abs(winding)*1.35,
      length(points)/circumference > 0.76, length(points)/circumference < 1.3 else { return nil }
    return .init(frame:frame,sampleCount:measured.count)
  }

  private static func arrow(_ paths: [[SpatialPoint]], count: Int, scale: Double) -> NotebookQuickShapeFit? {
    let points = paths.flatMap { $0 }, frame = bounds(points)
    let tolerance = max(2.5/scale,hypot(frame.width,frame.height)*0.018)
    func simplify(_ points: ArraySlice<SpatialPoint>, depth: Int = 0) -> [SpatialPoint] {
      guard points.count > 2, depth < 10, let a = points.first, let b = points.last else { return Array(points) }
      let index = points.indices.dropFirst().dropLast().max { deviation(points[$0],a,b) < deviation(points[$1],a,b) }!
      guard deviation(points[index],a,b) > tolerance else { return [a,b] }
      return simplify(points[...index],depth:depth+1).dropLast()+simplify(points[index...],depth:depth+1)
    }
    let vertices = paths.flatMap { simplify($0[...]) }
    guard (3...24).contains(vertices.count) else { return nil }
    // Candidate axes come from the sketch itself, not five prescribed turns.
    let pairs = vertices.indices.flatMap { a in vertices.indices.filter { $0 > a }.map { (vertices[a],vertices[$0]) } }
      .sorted { distance($0.0,$0.1) > distance($1.0,$1.1) }.prefix(16)
    var best: (Double,SpatialPoint,SpatialPoint)?
    for (a,b) in pairs {
      for (tail,tip) in [(a,b),(b,a)] {
        let span = distance(tail,tip)
        guard span*scale >= 40 else { continue }
        let ux = (tip.x-tail.x)/span, uy = (tip.y-tail.y)/span
        func coordinate(_ p: SpatialPoint) -> SpatialPoint {
          let x = p.x-tail.x, y = p.y-tail.y
          return .init(x:(x*ux+y*uy)/span,y:(-x*uy+y*ux)/span)
        }
        let side = points.filter { coordinate($0).x > 0.45 && coordinate($0).x < 1.08 }
        guard let left = side.max(by:{ coordinate($0).y < coordinate($1).y }),
          let right = side.min(by:{ coordinate($0).y < coordinate($1).y }) else { continue }
        let l = coordinate(left), r = coordinate(right)
        guard (0.045...0.45).contains(l.y), (-0.45 ... -0.045).contains(r.y),
          (0.45...0.96).contains(l.x), (0.45...0.96).contains(r.x),
          max(l.y,-r.y)/min(l.y,-r.y) < 3 else { continue }
        let segments = [(tail,tip),(tip,left),(tip,right)]
        var coverage = Array(repeating:Set<Int>(),count:3), error = 0.0, fits = true
        for point in points {
          let errors = segments.map { deviation(point,$0.0,$0.1) }
          let index = errors.indices.min { errors[$0] < errors[$1] }!, d = errors[index]
          if d > max(4/scale,span*0.055) { fits = false; break }
          error += d*d
          let (a,b) = segments[index], dx = b.x-a.x, dy = b.y-a.y
          let t = ((point.x-a.x)*dx+(point.y-a.y)*dy)/(dx*dx+dy*dy)
          coverage[index].insert(min(7,max(0,Int(t*8))))
        }
        let rms = sqrt(error/Double(points.count))/span
        guard fits, rms < 0.028, coverage.allSatisfy({ $0.count >= 5 }) else { continue }
        if best == nil || rms < best!.0 { best = (rms,tail,tip) }
      }
    }
    guard let (_,tail,tip) = best else { return nil }
    return connection(points:points,tail:tail,tip:tip,head:.arrow,count:count)
  }

  private static func resampled(_ points: [SpatialPoint], count: Int) -> [SpatialPoint] {
    var distances = [0.0]
    for index in 1..<points.count { distances.append(distances.last!+distance(points[index-1],points[index])) }
    guard let total = distances.last, total > 0 else { return [] }
    var result: [SpatialPoint] = [], segment = 1
    for index in 0..<count {
      let target = total*Double(index)/Double(count-1)
      while segment < distances.count-1 && distances[segment] < target { segment += 1 }
      let span = distances[segment]-distances[segment-1]
      let t = span > 0 ? (target-distances[segment-1])/span : 0
      result.append(.init(x:points[segment-1].x+(points[segment].x-points[segment-1].x)*t,
        y:points[segment-1].y+(points[segment].y-points[segment-1].y)*t))
    }
    return result
  }
}
