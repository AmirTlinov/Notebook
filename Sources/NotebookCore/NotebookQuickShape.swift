import Foundation
import CoreGraphics

public struct NotebookQuickShapeFit: Equatable, Sendable {
  public var frame: PageRect
  public let sampleCount: Int
  public var connection: NotebookGraphicConnection?
  public let shape: NotebookGraphic.Shape
  public var vertices: [SpatialPoint]?
  public var precedingStrokeIDs: [UUID] = []
  public init(frame: PageRect, sampleCount: Int, connection: NotebookGraphicConnection? = nil,
    shape: NotebookGraphic.Shape = .ellipse, vertices: [SpatialPoint]? = nil) {
    self.frame = frame; self.sampleCount = sampleCount; self.connection = connection
    self.shape = connection == nil ? shape : .connector; self.vertices = vertices
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
    tolerance: Double, erasures: [String: [InkElementErasure]] = [:],
    appearance: (String, NotebookGraphic, CGSize, [InkElementErasure]) -> NotebookElementAppearance? = { _, graphic, size, cuts in
      .init(graphic:graphic,layout:nil,size:size,erasures:cuts)
    }) -> Self {
    guard var connection else { return self }
    for terminal in NotebookGraphicConnection.Terminal.allCases {
      var endpoint = terminal == .start ? connection.start : connection.end
      let point = SpatialPoint(x:frame.x+endpoint.point.x,y:frame.y+endpoint.point.y)
      endpoint.binding = nil
      if var binding = graph.binding(at:point,origin:origin,surface:surface,tolerance:tolerance,erasures:erasures,appearance:appearance),
        let node = graph.nodes[collaborationIdentity(binding.elementID)] {
        let offset = origin.delta(to:node.origin)
        let anchor = SpatialPoint(x:(point.x-offset.x-node.frame.x)/node.frame.width,
          y:(point.y-offset.y-node.frame.y)/node.frame.height)
        // Pencil authors the endpoint, not the magnet. Attach at that exact
        // position only; proximity outside a node must not pull ink off the nib.
        if (-0.000001...1.000001).contains(anchor.x), (-0.000001...1.000001).contains(anchor.y) {
          binding.normalizedAnchor = .init(x:min(1,max(0,anchor.x)),y:min(1,max(0,anchor.y))); binding.isExact = true; binding.isPrecise = true
          endpoint.binding = binding
        }
      }
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
    if let fit = polygon(points, count: count, scale: screenScale) { return fit }
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
        && length($0) * scale >= 4 }
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
    guard span*scale >= 6, length(measured)/span < 2 else { return nil }
    let ux = (last.x-first.x)/span, uy = (last.y-first.y)/span
    for point in points {
      let x = point.x-first.x, y = point.y-first.y, along = x*ux+y*uy
      guard abs(-x*uy+y*ux) <= max(0.65/scale,span*0.08),
        along >= -max(3/scale,span*0.4), along <= span+max(3/scale,span*0.4) else { return nil }
    }
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
    // Fit the four measured sides, not the extrema of an axis-aligned box.
    // A bowed side or a small closing overshoot must not move the template
    // away from the other three sides (or turn a rectangle into an ellipse).
    guard let sides = fittedSides(normalized, offsets: [0,1,1,0], aspect: w/h) else { return nil }
    let corners = [intersection(sides[0],sides[3]), intersection(sides[0],sides[1]),
      intersection(sides[2],sides[1]), intersection(sides[2],sides[3])]
    guard corners[0].x < corners[1].x, corners[3].x < corners[2].x,
      corners[0].y < corners[3].y, corners[1].y < corners[2].y else { return nil }
    // A smooth oval also admits four approximate lines. Require actual corner
    // evidence: three tight corners and a fourth that may be rounded/open.
    let cornerErrors = corners.map { corner in normalized.map { distance($0,corner) }.min()! }
    guard cornerErrors.allSatisfy({ $0 < 0.16 }), cornerErrors.filter({ $0 < 0.09 }).count >= 3 else { return nil }
    var coverage = Array(repeating: Set<Int>(), count: 4), error = 0.0
    for p in normalized {
      let distances = corners.indices.map { deviation(p,corners[$0],corners[($0+1)%4]) }
      let side = distances.indices.min { distances[$0] < distances[$1] }!
      let d = distances[side]; error += d*d
      guard d < 0.20 else { return nil }
      let a = corners[side], b = corners[(side+1)%4], dx = b.x-a.x, dy = b.y-a.y
      let position = ((p.x-a.x)*dx+(p.y-a.y)*dy)/(dx*dx+dy*dy)
      coverage[side].insert(min(7,max(0,Int(position*8))))
    }
    guard sqrt(error/Double(points.count)) < 0.06, coverage.allSatisfy({ $0.count >= 6 }) else { return nil }
    let left = (corners[0].x+corners[3].x)/2, right = (corners[1].x+corners[2].x)/2
    let top = (corners[0].y+corners[1].y)/2, bottom = (corners[2].y+corners[3].y)/2
    var width = (right-left)*w, height = (bottom-top)*h
    guard min(width,height)*scale >= 24, max(width,height)/min(width,height) <= 8 else { return nil }
    if max(width,height)/min(width,height) < 1.18 {
      let side = (width+height)/2; width = side; height = side
    }
    return .init(x:frame.x+(left+right)*w/2-width/2,y:frame.y+(top+bottom)*h/2-height/2,width:width,height:height)
  }

  /// Convex hull corners, bounded by 384 resampled points. Every side needs
  /// measured coverage; an open V, oval or disconnected note is not a polygon.
  private static func polygon(_ points: [SpatialPoint], count: Int, scale: Double) -> NotebookQuickShapeFit? {
    let frame = bounds(points), size = min(frame.width,frame.height)
    guard size*scale >= 20, max(frame.width,frame.height)/size < 6 else { return nil }
    func cross(_ a: SpatialPoint,_ b: SpatialPoint,_ c: SpatialPoint) -> Double {
      (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func half(_ points: [SpatialPoint]) -> [SpatialPoint] {
      var result: [SpatialPoint] = []
      for point in points {
        while result.count >= 2 && cross(result[result.count-2],result.last!,point) <= 0 { result.removeLast() }
        result.append(point)
      }
      return result
    }
    let hull = Array(half(sorted).dropLast()) + half(sorted.reversed()).dropLast()
    for sides in [3,4] {
      var corners = hull
      while corners.count > sides {
        let i = corners.indices.min { a,b in
          abs(cross(corners[(a+corners.count-1)%corners.count],corners[a],corners[(a+1)%corners.count]))
            < abs(cross(corners[(b+corners.count-1)%corners.count],corners[b],corners[(b+1)%corners.count]))
        }!
        corners.remove(at:i)
      }
      guard corners.count == sides else { continue }
      let area = abs(corners.indices.reduce(0.0) { total,i in
        let a = corners[i], b = corners[(i+1)%sides]; return total+a.x*b.y-a.y*b.x
      })/2
      guard area > frame.width*frame.height*0.22 else { continue }
      // Hull corners initialize the sides; orthogonal least squares removes
      // outward bowing without changing orientation or inventing a fourth edge.
      var refined = true
      for _ in 0..<3 {
        var groups = Array(repeating:[SpatialPoint](),count:sides)
        for point in points {
          let i = corners.indices.min { deviation(point,corners[$0],corners[($0+1)%sides])
            < deviation(point,corners[$1],corners[($1+1)%sides]) }!
          groups[i].append(point)
        }
        var lines: [(SpatialPoint,SpatialPoint)] = []
        for group in groups {
          guard group.count >= 4 else { refined = false; break }
          let center = SpatialPoint(x:group.reduce(0) { $0+$1.x }/Double(group.count),
            y:group.reduce(0) { $0+$1.y }/Double(group.count))
          var xx = 0.0, yy = 0.0, xy = 0.0
          for point in group { let x = point.x-center.x, y = point.y-center.y; xx += x*x; yy += y*y; xy += x*y }
          let angle = atan2(2*xy,xx-yy)/2
          lines.append((center,.init(x:cos(angle),y:sin(angle))))
        }
        guard refined else { break }
        var next: [SpatialPoint] = []
        for i in corners.indices {
          let (a,u) = lines[(i+sides-1)%sides], (b,v) = lines[i], divisor = u.x*v.y-u.y*v.x
          guard abs(divisor) > 0.15 else { refined = false; break }
          let t = ((b.x-a.x)*v.y-(b.y-a.y)*v.x)/divisor
          next.append(.init(x:a.x+t*u.x,y:a.y+t*u.y))
        }
        guard refined else { break }; corners = next
      }
      guard refined, corners.allSatisfy({ corner in points.map { distance($0,corner) }.min()! < size*0.18 }) else { continue }
      var coverage = Array(repeating:Set<Int>(),count:sides), error = 0.0, maximum = 0.0
      for point in points {
        let distances = corners.indices.map { deviation(point,corners[$0],corners[($0+1)%sides]) }
        let i = distances.indices.min { distances[$0] < distances[$1] }!, d = distances[i]/size
        error += d*d; maximum = max(maximum,d)
        let a = corners[i], b = corners[(i+1)%sides], dx = b.x-a.x, dy = b.y-a.y
        let t = ((point.x-a.x)*dx+(point.y-a.y)*dy)/(dx*dx+dy*dy)
        coverage[i].insert(min(7,max(0,Int(t*8))))
      }
      guard sqrt(error/Double(points.count)) < (sides == 3 ? 0.075 : 0.065), maximum < 0.23,
        coverage.allSatisfy({ $0.count >= 6 }) else { continue }
      if sides == 4 {
        let a = corners[0], b = corners[1], c = corners[2], d = corners[3]
        let ux = c.x-a.x, uy = c.y-a.y, vx = d.x-b.x, vy = d.y-b.y
        let u = hypot(ux,uy), v = hypot(vx,vy)
        guard abs(ux*vx+uy*vy)/(u*v) < 0.48,
          hypot(a.x+c.x-b.x-d.x,a.y+c.y-b.y-d.y)/2 < min(u,v)*0.28 else { continue }
        let center = SpatialPoint(x:(a.x+b.x+c.x+d.x)/4,y:(a.y+b.y+c.y+d.y)/4)
        let sign = ux*vy-uy*vx > 0 ? 1.0 : -1.0
        let wx = -uy/u*v/2*sign, wy = ux/u*v/2*sign
        corners = [.init(x:center.x-ux/2,y:center.y-uy/2),.init(x:center.x-wx,y:center.y-wy),
          .init(x:center.x+ux/2,y:center.y+uy/2),.init(x:center.x+wx,y:center.y+wy)]
      }
      let fitted = bounds(corners)
      return .init(frame:fitted,sampleCount:count,shape:sides == 3 ? .triangle : .diamond,
        vertices:corners.map { .init(x:($0.x-fitted.x)/fitted.width,y:($0.y-fitted.y)/fitted.height) })
    }
    return nil
  }

  private static func plus(_ points: [SpatialPoint], scale: Double) -> PageRect? {
    let frame = bounds(points), w = frame.width, h = frame.height
    guard min(w,h)*scale >= 16, max(w,h)*scale >= 24, max(w,h)/min(w,h) < 2.3 else { return nil }
    let normalized = points.map { SpatialPoint(x:($0.x-frame.x)/w,y:($0.y-frame.y)/h) }
    guard let sides = fittedSides(normalized, offsets: [0.5,0.5], aspect: w/h) else { return nil }
    let center = intersection(sides[0],sides[1])
    // The crossing need not be the bounding-box center, but all four arms
    // must exist. In particular, a T or handwriting tail is not a plus.
    guard (0.2...0.8).contains(center.x), (0.2...0.8).contains(center.y) else { return nil }
    var coverage = Array(repeating: Set<Int>(), count: 4), error = 0.0
    for point in normalized {
      let horizontalError = sides[0].distance(point,horizontal:true)
      let verticalError = sides[1].distance(point,horizontal:false)
      let horizontal = horizontalError < verticalError, d = min(horizontalError,verticalError)
      guard d < 0.18 else { return nil }; error += d*d
      let origin = horizontal ? center.x : center.y
      let position = (horizontal ? point.x : point.y)-origin
      let extent = position < 0 ? origin : 1-origin
      let arm = (horizontal ? 0 : 2)+(position < 0 ? 0 : 1)
      coverage[arm].insert(min(3,max(0,Int(abs(position)/extent*4))))
    }
    guard sqrt(error/Double(points.count)) < 0.045, coverage.allSatisfy({ $0.count >= 3 }) else { return nil }
    return frame
  }

  private struct Side {
    var offset: Double
    var slope = 0.0
    func distance(_ point: SpatialPoint, horizontal: Bool) -> Double {
      let u = horizontal ? point.x : point.y, v = horizontal ? point.y : point.x
      return abs(v-offset-slope*u)/hypot(1,slope)
    }
  }

  /// Four fixed refinement passes over at most 384 length-resampled points.
  /// Even sides are horizontal, odd sides vertical; slight tilt/skew is fitted
  /// but a diagonal diamond is not silently straightened into a rectangle.
  private static func fittedSides(_ points: [SpatialPoint], offsets: [Double], aspect: Double) -> [Side]? {
    var sides = offsets.map { Side(offset:$0) }
    for _ in 0..<4 {
      var groups = Array(repeating:[SpatialPoint](),count:sides.count)
      for point in points {
        let side = sides.indices.min { sides[$0].distance(point,horizontal:$0%2 == 0)
          < sides[$1].distance(point,horizontal:$1%2 == 0) }!
        groups[side].append(point)
      }
      for index in sides.indices {
        let group = groups[index], horizontal = index%2 == 0
        guard group.count >= 4 else { return nil }
        let u = group.reduce(0) { $0+(horizontal ? $1.x : $1.y) }/Double(group.count)
        let v = group.reduce(0) { $0+(horizontal ? $1.y : $1.x) }/Double(group.count)
        var variance = 0.0, covariance = 0.0
        for point in group {
          let du = (horizontal ? point.x : point.y)-u, dv = (horizontal ? point.y : point.x)-v
          variance += du*du; covariance += du*dv
        }
        guard variance > 0.000001 else { return nil }
        let slope = covariance/variance
        sides[index] = .init(offset:v-slope*u,slope:slope)
      }
    }
    guard sides.indices.allSatisfy({ abs(sides[$0].slope*($0%2 == 0 ? 1/aspect : aspect)) < 0.45 }) else { return nil }
    return sides
  }

  private static func intersection(_ horizontal: Side, _ vertical: Side) -> SpatialPoint {
    let x = (vertical.offset+vertical.slope*horizontal.offset)/(1-horizontal.slope*vertical.slope)
    return .init(x:x,y:horizontal.offset+horizontal.slope*x)
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
        guard span*scale >= 28 else { continue }
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
          max(l.y,-r.y)/min(l.y,-r.y) < 4 else { continue }
        let segments = [(tail,tip),(tip,left),(tip,right)]
        var coverage = Array(repeating:Set<Int>(),count:3), error = 0.0, fits = true
        for point in points {
          let errors = segments.map { deviation(point,$0.0,$0.1) }
          let index = errors.indices.min { errors[$0] < errors[$1] }!, d = errors[index]
          if d > max(5/scale,span*0.12) { fits = false; break }
          error += d*d
          // At the junction a measured point supports more than one segment.
          // Exclusive nearest-side assignment starved a short/uneven wing and
          // converted just its last stroke to a line, leaving the shaft behind.
          for segment in segments.indices {
            let (a,b) = segments[segment], dx = b.x-a.x, dy = b.y-a.y
            let t = ((point.x-a.x)*dx+(point.y-a.y)*dy)/(dx*dx+dy*dy)
            if (-0.05...1.05).contains(t), errors[segment] <= max(2/scale,hypot(dx,dy)*0.18) {
              coverage[segment].insert(min(7,max(0,Int(t*8))))
            }
          }
        }
        let rms = sqrt(error/Double(points.count))/span
        guard fits, rms < 0.06, coverage.allSatisfy({ $0.count >= 5 }) else { continue }
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
