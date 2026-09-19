import CoreGraphics
import Foundation

/// A retained vector presentation of measured ink. The immutable measurements
/// stay in the journal; this mesh is produced by its one shared tessellator.
/// Copies carry the mesh, not another claim on the original measurements.
public struct NotebookFreehand: Codable, Equatable, Sendable {
  public struct Vertex: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let opacity: Double
    public init(x: Double, y: Double, opacity: Double) { self.x = x; self.y = y; self.opacity = opacity }
    var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 1_000_000 && abs(y) <= 1_000_000 && (0...1).contains(opacity) }
  }
  /// Cuts retain their measured circular sweep, not 78 redundant triangle
  /// vertices per sample. The same tessellator expands them only for painting.
  public struct Eraser: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
      public let point: SpatialPoint
      public let width: Double
      public init(point: SpatialPoint, width: Double) { self.point = point; self.width = width }
    }
    public let size: SpatialPoint
    public let samples: [Sample]
    public init(size: SpatialPoint, samples: [Sample]) { self.size = size; self.samples = samples }
    var isValid: Bool {
      size.x.isFinite && size.y.isFinite && size.x > 0 && size.y > 0 && size.x <= 1_000_000 && size.y <= 1_000_000
        && !samples.isEmpty && samples.count <= 100_000 && samples.allSatisfy {
          $0.point.x.isFinite && $0.point.y.isFinite && $0.width.isFinite && $0.width > 0 && $0.width <= 1_000_000
            && abs($0.point.x) <= 1_000_000 && abs($0.point.y) <= 1_000_000
        }
    }
    private var measuredSamples: [SpatialInkSample] {
      samples.map { .init(point:$0.point,timeOffset:0,width:$0.width,opacity:1,force:1,azimuth:0,altitude:.pi/2) }
    }
    var vertices: [Vertex] {
      NotebookFreehand.mesh(samples:measuredSamples,frame:.init(x:0,y:0,width:size.x,height:size.y),origin:nil,tool:.eraser)
    }
    func normalizedPath(size destination: CGSize, transform: NotebookGraphicTransform?) -> CGPath {
      NotebookElementAppearance.erasurePath([.init(target:.init(elementID:"retained-ink",
        frame:.init(x:0,y:0,width:size.x,height:size.y)),samples:measuredSamples)],size:destination,transform:transform)
    }
  }
  public struct Layer: Codable, Equatable, Sendable {
    public let tool: SpatialInkTool
    public let color: SpatialInkColor
    public let vertices: [Vertex]
    public let eraser: Eraser?
    public init(tool: SpatialInkTool = .pen, color: SpatialInkColor, vertices: [Vertex]) {
      self.tool = tool; self.color = color; self.vertices = vertices; eraser = nil
    }
    public init(eraser: Eraser) { tool = .eraser; color = .black; vertices = []; self.eraser = eraser }
    public var renderVertices: [Vertex] { eraser?.vertices ?? vertices }
    var isValid: Bool {
      if let eraser { return tool == .eraser && color.isValid && vertices.isEmpty && eraser.isValid }
      return color.isValid && !vertices.isEmpty && vertices.count % 3 == 0 && vertices.allSatisfy(\.isValid)
    }
  }
  public let layers: [Layer]
  public init(layers: [Layer]) { self.layers = layers }
  public static let maximumVertices = 65_536
  public var isValid: Bool {
    !layers.isEmpty && layers.count <= 2048 && layers.first?.tool == .pen
      && layers.reduce(0) { $0 + $1.vertices.count } <= Self.maximumVertices
      && layers.reduce(0) { $0 + ($1.eraser?.samples.count ?? 0) } <= 100_000
      && layers.allSatisfy(\.isValid)
  }
  public static func mesh(samples: [SpatialInkSample], frame: PageRect, origin: WorldPoint?, tool: SpatialInkTool = .pen) -> [Vertex] {
    var points: [InkStrokeGeometry.RenderPoint] = []
    for sample in samples {
      let p = origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
      let alpha = Float(sample.opacity)
      let next = InkStrokeGeometry.RenderPoint(position:.init(Float(p.x-frame.x),Float(p.y-frame.y)),
        radius:max(0.25,Float(sample.width/2)),premultipliedColor:.init(repeating:alpha))
      if let last = points.last, InkStrokeGeometry.areCoincident(last,next) { points[points.count-1] = next }
      else { points.append(next) }
    }
    var vertices: [InkStrokeGeometry.Vertex] = []
    if tool == .eraser { InkStrokeGeometry.appendEraserVertices(renderPoints:points,to:&vertices) }
    else { InkStrokeGeometry.appendStrokeVertices(renderPoints:points,to:&vertices) }
    return vertices.map { .init(x:Double($0.position.x)/frame.width,y:Double($0.position.y)/frame.height,opacity:Double($0.premultipliedColor.w)) }
  }
  public static func path(_ vertices: [Vertex], size: CGSize, transform: NotebookGraphicTransform? = nil) -> CGPath {
    let path = CGMutablePath()
    for index in stride(from:0,to:vertices.count,by:3) {
      let p = vertices[index..<index+3].map { vertex -> CGPoint in
        let p = (transform ?? .identity).applying(.init(x:vertex.x,y:vertex.y))
        return .init(x:p.x*size.width,y:p.y*size.height)
      }
      path.move(to:p[0])
      let cross = (p[1].x-p[0].x)*(p[2].y-p[0].y)-(p[1].y-p[0].y)*(p[2].x-p[0].x)
      for point in cross >= 0 ? [p[1],p[2]] : [p[2],p[1]] { path.addLine(to:point) }
      path.closeSubpath()
    }
    return path
  }
  /// Hit testing walks paint order, not a Boolean union of every measured
  /// triangle. A later cut removes only earlier paint; later pen still wins.
  public func contains(_ point: CGPoint, size: CGSize, transform: NotebookGraphicTransform?, tolerance: Double = 0) -> Bool {
    guard CGRect(origin:.zero,size:size).insetBy(dx:-tolerance,dy:-tolerance).contains(point) else { return false }
    for layer in layers.reversed() {
      // One point needs triangle containment/distance, not an enormous
      // overlapping CGPath plus its stroked Boolean outline on the UI thread.
      let vertices = layer.renderVertices
      let padding = layer.tool == .pen ? max(0,tolerance) : 0
      func projected(_ vertex: Vertex) -> CGPoint {
        let p = (transform ?? .identity).applying(.init(x:vertex.x,y:vertex.y))
        return .init(x:p.x*size.width,y:p.y*size.height)
      }
      func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Double {
        (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
      }
      func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
        let t = length > 0 ? min(1,max(0,((point.x-a.x)*dx+(point.y-a.y)*dy)/length)) : 0
        return hypot(point.x-a.x-t*dx,point.y-a.y-t*dy) <= padding
      }
      for i in stride(from:0,to:vertices.count,by:3) {
        let a = projected(vertices[i]), b = projected(vertices[i+1]), c = projected(vertices[i+2])
        guard point.x >= min(a.x,b.x,c.x)-padding, point.x <= max(a.x,b.x,c.x)+padding,
          point.y >= min(a.y,b.y,c.y)-padding, point.y <= max(a.y,b.y,c.y)+padding else { continue }
        let ab = cross(a,b,point), bc = cross(b,c,point), ca = cross(c,a,point)
        let inside = abs(cross(a,b,c)) > 1e-12
          && ((ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0))
        if inside || (padding > 0 && (near(a,b) || near(b,c) || near(c,a))) { return layer.tool != .eraser }
      }
    }
    return false
  }
  public func paintPath(size: CGSize, transform: NotebookGraphicTransform?) -> CGPath {
    var result: CGPath = CGMutablePath()
    for layer in layers {
      let path = layer.eraser?.normalizedPath(size:size,transform:transform) ?? Self.path(layer.vertices,size:size,transform:transform)
      result = layer.tool == .eraser ? result.subtracting(path) : result.union(path)
    }
    return result.intersection(CGPath(rect:CGRect(origin:.zero,size:size),transform:nil))
  }
}

/// Unit-square affine basis. Frame is the physical envelope; this basis keeps
/// rotation in content rather than a view-only effect that export cannot see.
public struct NotebookGraphicTransform: Codable, Equatable, Sendable {
  public let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
  public static let identity = Self(a:1,b:0,c:0,d:1,tx:0,ty:0)
  public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
    self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
  }
  var isValid: Bool {
    [a,b,c,d,tx,ty].allSatisfy(\.isFinite) && abs(a*d-b*c) > 1e-12
      && [SpatialPoint.zero,.init(x:1,y:0),.init(x:0,y:1),.init(x:1,y:1)].map(applying).allSatisfy {
        (-1e-8...1+1e-8).contains($0.x) && (-1e-8...1+1e-8).contains($0.y)
      }
  }
  public func applying(_ p: SpatialPoint) -> SpatialPoint { .init(x:a*p.x+c*p.y+tx,y:b*p.x+d*p.y+ty) }
  public func unapplying(_ p: SpatialPoint) -> SpatialPoint {
    let x = p.x-tx, y = p.y-ty, determinant = a*d-b*c
    return .init(x:(d*x-c*y)/determinant,y:(a*y-b*x)/determinant)
  }
  public func contentSize(in size: CGSize) -> CGSize {
    .init(width:hypot(a*size.width,b*size.height),height:hypot(c*size.width,d*size.height))
  }
  public func contentTransform(in rect: CGRect) -> CGAffineTransform {
    let source = contentSize(in:rect.size)
    return .init(a:a*rect.width/source.width,b:b*rect.height/source.width,
      c:c*rect.width/source.height,d:d*rect.height/source.height,
      tx:rect.minX+tx*rect.width,ty:rect.minY+ty*rect.height)
  }
}
