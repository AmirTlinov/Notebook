import Foundation

extension NotebookGraphicGeometry {
  public static func isConvex(_ vertices: [SpatialPoint], sameWindingAs original: [SpatialPoint]? = nil) -> Bool {
    guard vertices.count >= 3 else { return false }
    let turns = vertices.indices.map { i in
      let a = vertices[i], b = vertices[(i+1)%vertices.count], c = vertices[(i+2)%vertices.count]
      return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
    }
    if let original, original.count >= 3 {
      let a = original[0], b = original[1], c = original[2]
      let winding = (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
      guard turns[0]*winding > 0 else { return false }
    }
    return turns.allSatisfy { $0 > 0.0001 } || turns.allSatisfy { $0 < -0.0001 }
  }

  public struct Corner {
    public let vertex: SpatialPoint
    public let incoming: SpatialPoint
    public let outgoing: SpatialPoint
    public let bisector: SpatialPoint
    public let sine: Double
    public let cotangent: Double
  }
  public static func corners(_ graphic: NotebookGraphic, width: Double, height: Double) -> [Corner] {
    guard let polygon = polygon(graphic) else { return [] }
    let points = polygon.map { SpatialPoint(x:$0.x*width,y:$0.y*height) }
    return points.indices.map { index in
      let p = points[index], a = points[(index+points.count-1)%points.count], b = points[(index+1)%points.count]
      func unit(_ q: SpatialPoint) -> SpatialPoint {
        let length = max(0.000001,hypot(q.x-p.x,q.y-p.y))
        return .init(x:(q.x-p.x)/length,y:(q.y-p.y)/length)
      }
      let u = unit(a), v = unit(b), dot = min(1,max(-1,u.x*v.x+u.y*v.y))
      let sine = max(0.000001,sqrt((1-dot)/2)), cosine = sqrt((1+dot)/2)
      let length = max(0.000001,hypot(u.x+v.x,u.y+v.y))
      return .init(vertex:p,incoming:u,outgoing:v,bisector:.init(x:(u.x+v.x)/length,y:(u.y+v.y)/length),
        sine:sine,cotangent:cosine/sine)
    }
  }
  public static func maximumCornerRadius(_ graphic: NotebookGraphic, width: Double, height: Double) -> Double {
    let corners = corners(graphic,width:width,height:height)
    return corners.indices.map { i in
      let a = corners[i], b = corners[(i+1)%corners.count]
      return hypot(a.vertex.x-b.vertex.x,a.vertex.y-b.vertex.y)/max(0.000001,a.cotangent+b.cotangent)
    }.min() ?? 0
  }

  /// One physical contour for paint, interior picking and connector anchors.
  /// Adjacent circular fillets share one bounded radius; they cannot cross.
  public static func polygonCurves(_ graphic: NotebookGraphic, width: Double, height: Double) -> [NotebookGraphicLayout.Curve] {
    let corners = corners(graphic,width:width,height:height)
    guard !corners.isEmpty else { return [] }
    let radius = min(graphic.cornerRadius ?? 0,maximumCornerRadius(graphic,width:width,height:height))
    func tangent(_ corner: Corner, _ unit: SpatialPoint) -> SpatialPoint {
      .init(x:corner.vertex.x+unit.x*radius*corner.cotangent,y:corner.vertex.y+unit.y*radius*corner.cotangent)
    }
    var result: [NotebookGraphicLayout.Curve] = []
    for (index, corner) in corners.enumerated() {
      let previous = corners[(index+corners.count-1)%corners.count]
      let a = tangent(previous,previous.outgoing), b = tangent(corner,corner.incoming)
      result.append(.init(start:a,control1:.init(x:(2*a.x+b.x)/3,y:(2*a.y+b.y)/3),
        control2:.init(x:(a.x+2*b.x)/3,y:(a.y+2*b.y)/3),end:b))
      guard radius > 0.000001 else { continue }
      let end = tangent(corner,corner.outgoing)
      let center = SpatialPoint(x:corner.vertex.x+corner.bisector.x*radius/corner.sine,
        y:corner.vertex.y+corner.bisector.y*radius/corner.sine)
      let startAngle = atan2(b.y-center.y,b.x-center.x)
      let sweep = atan2((b.x-center.x)*(end.y-center.y)-(b.y-center.y)*(end.x-center.x),
        (b.x-center.x)*(end.x-center.x)+(b.y-center.y)*(end.y-center.y))
      let count = max(1,Int(ceil(abs(sweep)/(.pi/2))))
      for piece in 0..<count {
        let first = startAngle+sweep*Double(piece)/Double(count), last = startAngle+sweep*Double(piece+1)/Double(count)
        let k = 4/3*tan((last-first)/4)
        let p = SpatialPoint(x:center.x+radius*cos(first),y:center.y+radius*sin(first))
        let q = SpatialPoint(x:center.x+radius*cos(last),y:center.y+radius*sin(last))
        result.append(.init(start:p,control1:.init(x:p.x-k*radius*sin(first),y:p.y+k*radius*cos(first)),
          control2:.init(x:q.x+k*radius*sin(last),y:q.y-k*radius*cos(last)),end:q))
      }
    }
    return result
  }

  /// Flatten the same cubics only for geometric queries, within 0.1 owner point.
  public static func outlinePolygon(_ graphic: NotebookGraphic, width: Double, height: Double) -> [SpatialPoint]? {
    if let transform = graphic.transform {
      var base = graphic; base.transform = nil
      if base.shape == .ellipse {
        let segments = max(32,min(4096,Int(ceil(.pi*sqrt(max(width,height)/0.05)))))
        return (0..<segments).map { index in
          let angle = Double(index)*2 * .pi/Double(segments)
          return transform.applying(.init(x:(1+cos(angle))/2,y:(1+sin(angle))/2))
        }
      }
      let size = transform.contentSize(in:.init(width:width,height:height))
      return outlinePolygon(base,width:size.width,height:size.height)?.map(transform.applying)
    }
    guard let polygon = polygon(graphic), width > 0, height > 0 else { return nil }
    guard (graphic.cornerRadius ?? 0) > 0 else { return polygon }
    var points: [SpatialPoint] = []
    func flatten(_ curve: NotebookGraphicLayout.Curve, _ start: Double, _ end: Double, _ depth: Int = 0) {
      let a = curve.point(at:start), b = curve.point(at:end), mid = curve.point(at:(start+end)/2)
      if depth < 12, hypot(mid.x-(a.x+b.x)/2,mid.y-(a.y+b.y)/2) > 0.1 {
        flatten(curve,start,(start+end)/2,depth+1); flatten(curve,(start+end)/2,end,depth+1)
      } else { points.append(.init(x:a.x/width,y:a.y/height)) }
    }
    for curve in polygonCurves(graphic,width:width,height:height) { flatten(curve,0,1) }
    return points
  }
}
