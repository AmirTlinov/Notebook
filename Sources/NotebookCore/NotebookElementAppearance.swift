import CoreGraphics
import Foundation

/// Disposable current-content projection. The measured erase stays in its one
/// undoable action; it is not a second authored visibility register.
// CGPath lacks Sendable in the SDK. These paths are immutable copies with no
// escaping mutable alias. Remove unchecked when CGPath gains that conformance.
public struct NotebookElementAppearance: @unchecked Sendable {
  public enum State: String, Codable, Sendable { case intact, partial, erased }
  public let state: State
  public let remaining: CGPath
  public let mask: CGPath

  public init(graphic: NotebookGraphic?, layout: NotebookGraphicLayout?, size: CGSize,
    erasures: [InkElementErasure]) {
    if erasures.contains(where: { $0.target.wholeElement }) {
      mask = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
      remaining = CGMutablePath(); state = .erased
      return
    }
    let paint = graphic.map { NotebookGraphicGeometry.paintPath($0,layout:layout,size:size) }
      ?? CGPath(rect:CGRect(origin:.zero,size:size),transform:nil)
    if !erasures.isEmpty && paint.isEmpty {
      mask = CGPath(rect: .zero, transform: nil); remaining = mask; state = .erased
      return
    }
    mask = Self.erasurePath(erasures, size:size,transform:graphic?.transform)
    if mask.isEmpty { remaining = paint.copy()!; state = .intact }
    else {
      remaining = paint.subtracting(mask)
      state = remaining.isEmpty ? .erased : (paint.intersection(mask).isEmpty ? .intact : .partial)
    }
  }

  /// Tolerance expands only surviving paint, never the removed original edge.
  public func contains(_ point: SpatialPoint, tolerance: Double) -> Bool {
    guard state != .erased else { return false }
    let p = CGPoint(x:point.x,y:point.y)
    if mask.contains(p) { return false }
    return remaining.contains(p) || (tolerance > 0 && remaining.copy(strokingWithWidth:tolerance*2,
      lineCap:.round,lineJoin:.round,miterLimit:10).contains(p))
  }
  public func readProjection() -> JSONValue {
    .object(["state":.string(state.rawValue),"sourceIsCompleteAppearance":.bool(state == .intact)])
  }

  /// Exactly the positive-winding triangles that the live renderer erases.
  public static func erasurePath(_ erasures: [InkElementErasure], size: CGSize, transform: NotebookGraphicTransform? = nil) -> CGPath {
    if erasures.contains(where: { $0.target.wholeElement }) {
      return CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
    }
    // Repeated passes can cover the same small area with tens of thousands of
    // overlapping triangles. Never hand that entire triangle soup to Clipper:
    // normalize bounded batches and union them in balanced levels, retaining
    // the same measured coverage rather than simplifying Pencil samples.
    var batch = CGMutablePath()
    var triangles = 0
    var lastTriangle: [CGPoint] = []
    var levels: [CGPath?] = []
    func flush() {
      guard triangles > 0, !Task.isCancelled else { return }
      var merged = batch.normalized()
      var level = 0
      while level < levels.count, let previous = levels[level] {
        merged = previous.union(merged)
        levels[level] = nil
        level += 1
      }
      if level == levels.count { levels.append(merged) }
      else { levels[level] = merged }
      batch = CGMutablePath()
      triangles = 0
      // Shared coverage, not merely touching edges: CoreGraphics quantizes
      // each boolean operand independently. The same last triangle in both
      // batches prevents a numerical crack without enlarging the erase.
      if let first = lastTriangle.first {
        batch.move(to:first)
        for p in lastTriangle.dropFirst() { batch.addLine(to:p) }
        batch.closeSubpath()
      }
    }
    forEachErasureTriangle(erasures, size: size,transform:transform) { triangle in
      lastTriangle = triangle
      batch.move(to: triangle[0])
      for p in triangle.dropFirst() { batch.addLine(to:p) }
      batch.closeSubpath()
      triangles += 1
      if triangles == 128 { flush() }
    }
    flush()
    return levels.compactMap { $0 }.reduce(CGMutablePath() as CGPath) { $0.union($1) }
  }

  /// Nonzero fill of the same positive triangles is already their union.
  /// Painting does not need CoreGraphics boolean normalization. This linear
  /// path is also the exact live eraser while semantic preparation is pending.
  public static func measuredErasurePath(_ erasures: [InkElementErasure], size: CGSize, transform: NotebookGraphicTransform? = nil) -> CGPath {
    if erasures.contains(where: { $0.target.wholeElement }) {
      return CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
    }
    let path = CGMutablePath()
    forEachErasureTriangle(erasures, size: size,transform:transform) { triangle in
      path.move(to:triangle[0])
      for p in triangle.dropFirst() { path.addLine(to:p) }
      path.closeSubpath()
    }
    return path.copy()!
  }

  private static func forEachErasureTriangle(_ erasures: [InkElementErasure], size: CGSize,transform:NotebookGraphicTransform?,
    visit: ([CGPoint]) -> Void) {
    for erasure in erasures {
      if Task.isCancelled { return }
      var points: [InkStrokeGeometry.RenderPoint] = []
      for sample in erasure.samples {
        let p = erasure.target.localPoint(sample)
        let next = InkStrokeGeometry.RenderPoint(position:.init(Float(p.x),Float(p.y)),
          radius:max(Float(sample.width/2),0.25),premultipliedColor:.init(repeating:1))
        if let last = points.last, InkStrokeGeometry.areCoincident(last,next) { points[points.count-1] = next }
        else { points.append(next) }
      }
      var vertices: [InkStrokeGeometry.Vertex] = []
      InkStrokeGeometry.appendEraserVertices(renderPoints:points,to:&vertices)
      func point(_ p: SIMD2<Float>) -> CGPoint {
        let normalized = SpatialPoint(x:Double(p.x)/erasure.target.frame.width,y:Double(p.y)/erasure.target.frame.height)
        let content = (erasure.target.graphicTransform ?? .identity).unapplying(normalized)
        let current = (transform ?? .identity).applying(content)
        return .init(x:current.x*size.width,y:current.y*size.height)
      }
      for i in stride(from:0,to:vertices.count,by:3) {
        if i.isMultiple(of: 768), Task.isCancelled { return }
        let a = vertices[i].position, b = vertices[i+1].position, c = vertices[i+2].position
        visit([point(a)] + ((b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) >= 0 ? [b,c] : [c,b]).map(point))
      }
    }
  }

}

extension NotebookGraphicGeometry {
  public static func outlinePath(_ graphic: NotebookGraphic, in rect: CGRect) -> CGPath {
    if let basis = graphic.transform {
      var base = graphic; base.transform = nil
      var transform = basis.contentTransform(in:rect)
      return outlinePath(base,in:CGRect(origin:.zero,size:basis.contentSize(in:rect.size))).copy(using:&transform)!
    }
    let path = CGMutablePath()
    func p(_ value: SpatialPoint) -> CGPoint { .init(x:rect.minX+value.x,y:rect.minY+value.y) }
    switch graphic.shape {
    case .ellipse: path.addEllipse(in:rect)
    case .triangle,.rectangle,.diamond:
      let curves = polygonCurves(graphic,width:rect.width,height:rect.height)
      if let first = curves.first { path.move(to:p(first.start)) }
      for c in curves { path.addCurve(to:p(c.end),control1:p(c.control1),control2:p(c.control2)) }
      path.closeSubpath()
    case .plus:
      path.move(to:.init(x:rect.minX,y:rect.midY)); path.addLine(to:.init(x:rect.maxX,y:rect.midY))
      path.move(to:.init(x:rect.midX,y:rect.minY)); path.addLine(to:.init(x:rect.midX,y:rect.maxY))
    case .path: if let vector = graphic.path { path.addPath(vector.path(in:rect)) }
    case .connector, .freehand: break
    }
    return path
  }
  public static func connectionPath(_ layout: NotebookGraphicLayout) -> CGPath {
    let path = CGMutablePath()
    func p(_ value: SpatialPoint) -> CGPoint { .init(x:value.x,y:value.y) }
    if let first = layout.curves.first { path.move(to:p(first.start)) }
    for c in layout.curves { path.addCurve(to:p(c.end),control1:p(c.control1),control2:p(c.control2)) }
    return path
  }
  /// Same stroke/fill paths as native paint. Labels and foreign HTML/text use
  /// their content envelope conservatively; partial source is explicitly marked.
  public static func paintPath(_ graphic: NotebookGraphic, layout: NotebookGraphicLayout?, size: CGSize) -> CGPath {
    guard graphic.showsGeometry else { return CGMutablePath() }
    var result: CGPath = graphic.freehand?.paintPath(size:size,transform:graphic.transform) ?? CGMutablePath()
    let width = graphic.style.strokeWidth
    func add(_ path: CGPath) { result = result.union(path) }
    func stroke(_ path: CGPath, dashed: Bool = true) {
      let dash = dashed ? graphic.style.dashPattern : []
      let line = dash.isEmpty ? path : path.copy(dashingWithPhase:0,lengths:dash)
      add(line.copy(strokingWithWidth:width,lineCap:.round,lineJoin:.round,miterLimit:10))
    }
    if graphic.shape == .connector, let layout {
      stroke(connectionPath(layout))
      for head in layout.heads {
        let path = CGMutablePath()
        if let p = head.points.first { path.move(to:.init(x:p.x,y:p.y)) }
        for p in head.points.dropFirst() { path.addLine(to:.init(x:p.x,y:p.y)) }
        if head.closed { path.closeSubpath() }
        if head.filled { add(path) }; stroke(path,dashed:false)
      }
    } else if graphic.freehand == nil {
      let inset = max(0,min(width/2,min(size.width,size.height)/2-0.01))
      let path = outlinePath(graphic,in:CGRect(origin:.zero,size:size).insetBy(dx:inset,dy:inset))
      if graphic.shape != .plus, graphic.style.fill != nil { add(path) }; stroke(path)
    }
    if !graphic.label.isEmpty {
      let center = layout?.label ?? .init(x:size.width/2,y:size.height/2)
      let lines = graphic.label.split(separator:"\n",omittingEmptySubsequences:false)
      let w = min(size.width,Double(lines.map(\.count).max() ?? 0)*24), h = min(size.height,Double(lines.count)*30)
      add(CGPath(rect:.init(x:center.x-w/2,y:center.y-h/2,width:w,height:h),transform:nil))
    }
    return result
  }
}
