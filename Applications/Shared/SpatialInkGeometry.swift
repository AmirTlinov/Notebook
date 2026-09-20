import NotebookCore
import PencilKit
import simd

/// One compact display geometry feeds the live canvas and the Mac raster.
enum SpatialInkGeometry {
  typealias Vertex = InkStrokeGeometry.Vertex
  typealias Node = InkRenderGeometry.Node
  struct Chunk: Sendable {
    let nodes: Range<Int>
    let bounds: CGRect
    let color: SIMD4<Float>
    let flags: UInt32
    let levels: [InkRenderGeometry.Level]
    var vertexCount: Int { InkRenderGeometry.vertexCount(nodes: nodes.count, flags: flags) }
    var metadataBytes: Int { levels.reduce(0) { $0 + $1.indices.count * 2 } }
    init(
      nodes: Range<Int>, bounds: CGRect, color: SIMD4<Float> = .init(repeating: 1),
      flags: UInt32 = 3,
      levels: [InkRenderGeometry.Level] = []
    ) {
      self.nodes = nodes; self.bounds = bounds; self.color = color; self.flags = flags;
      self.levels = levels
    }
    func intersects(viewport: CGRect, transform: SIMD4<Float>) -> Bool {
      let projected = CGRect(x: Double(bounds.minX) * Double(transform.x) + Double(transform.z),
        y: Double(bounds.minY) * Double(transform.y) + Double(transform.w),
        width: Double(bounds.width) * Double(transform.x), height: Double(bounds.height) * Double(transform.y))
      return projected.intersects(viewport.insetBy(dx: -1, dy: -1))
    }
  }

  /// Immutable bounds tree of upload chunks, built with the mesh off the frame
  /// path. Queries visit intersecting branches before touching chunk geometry.
  struct ChunkIndex: Sendable {
    private let index: InkBoundsIndex
    var byteCount: Int { index.byteCount }
    init(_ chunks: [Chunk]) { index = .init(chunks.map(\.bounds)) }

    func query(viewport: CGRect, transform: SIMD4<Float>) -> (chunks: [Int], visitedNodes: Int) {
      guard transform.x > 0, transform.y > 0 else { return ([], 0) }
      let padded = viewport.insetBy(dx: -1, dy: -1)
      let local = CGRect(x: (padded.minX - Double(transform.z)) / Double(transform.x),
        y: (padded.minY - Double(transform.w)) / Double(transform.y),
        width: padded.width / Double(transform.x), height: padded.height / Double(transform.y))
      let result = index.query(local)
      return (result.indices, result.visitedNodes)
    }
  }


  typealias RenderPoint = InkStrokeGeometry.RenderPoint

  static func chunks(
    for nodes: [Node], color: SIMD4<Float>, eraser: Bool,
    startingSegment: Int = 0, buildLOD: Bool = true
  ) -> [Chunk] {
    guard !nodes.isEmpty else { return [] }
    let last = nodes.count - 1
    return stride(from: startingSegment, to: max(1, last), by: InkRenderGeometry.maximumSegments)
      .map { start in
        let end = min(last, start + InkRenderGeometry.maximumSegments), range = start..<(end + 1)
        let flags: UInt32 = (start == 0 ? 1 : 0) | (end == last ? 2 : 0) | (eraser ? 4 : 0)
        return .init(
          nodes: range, bounds: InkRenderGeometry.bounds(nodes[range]), color: color, flags: flags,
          levels: buildLOD ? InkRenderGeometry.levels(nodes[range], flags: flags) : [])
    }
  }
  static func compact(points: [PKStrokePoint], color: SIMD4<Float>) -> [Node] {
    let normalized = renderPoints(from: points, color: color)
    return normalized.indices.map { InkRenderGeometry.node(at: $0, in: normalized) }
  }

  /// Same compact geometry owner; the source chooses only proved display ranges.
  /// No PencilKit objects or full decoded measurement array are created here.
  static func compact(source: InkSampleRelations, range: Range<Int>? = nil) -> [Node] {
    let c = source.header.color
    let color: SIMD4<Float> = source.header.tool == .eraser ? .init(repeating:1)
      : .init(Float(c.red),Float(c.green),Float(c.blue),1)
    var points: [RenderPoint] = []
    source.forEachDisplayPoint(in:range) { position,radius,opacity in
      let alpha = min(max(opacity*color.w,0),1)
      let p = RenderPoint(position:position,radius:max(radius,0.25),
        premultipliedColor:.init(color.x*alpha,color.y*alpha,color.z*alpha,alpha))
      if let last = points.last, areCoincident(last,p) { points[points.count-1] = p }
      else { points.append(p) }
    }
    return points.indices.map { InkRenderGeometry.node(at:$0,in:points) }
  }

  static var roundCapVertexCount: Int { InkStrokeGeometry.roundCapVertexCount }
  static func areCoincident(_ a: RenderPoint, _ b: RenderPoint) -> Bool { InkStrokeGeometry.areCoincident(a,b) }
  static func appendStrokeVertices(renderPoints: [RenderPoint], roundsStart: Bool = true,
    roundsEnd: Bool = true, eraser: Bool = false, to vertices: inout [Vertex]) {
    if eraser { InkStrokeGeometry.appendEraserVertices(renderPoints:renderPoints,includesStart:roundsStart,to:&vertices) }
    else { InkStrokeGeometry.appendStrokeVertices(renderPoints:renderPoints,roundsStart:roundsStart,roundsEnd:roundsEnd,to:&vertices) }
  }
  static func appendStrokeVertices(
    points: [PKStrokePoint],
    color: SIMD4<Float>,
    roundsStart: Bool = true,
    roundsEnd: Bool = true,
    eraser: Bool = false,
    to vertices: inout [Vertex]
  ) {
    let renderPoints = renderPoints(from: points, color: color)
    appendStrokeVertices(renderPoints: renderPoints, roundsStart: roundsStart,
      roundsEnd: roundsEnd, eraser: eraser, to: &vertices)
  }

  private static func renderPoints(
    from points: [PKStrokePoint],
    color: SIMD4<Float>
  ) -> [RenderPoint] {
    var result: [RenderPoint] = []
    result.reserveCapacity(points.count)

    for (index, point) in points.enumerated() {
      if index.isMultiple(of: 256), Task.isCancelled { return [] }
      let renderPoint = renderPoint(from: point, color: color)

      if let last = result.last,
        areCoincident(last, renderPoint)
      {
        result[result.count - 1] = renderPoint
      } else {
        result.append(renderPoint)
      }
    }
    return result
  }

  static func renderPoint(from point: PKStrokePoint, color: SIMD4<Float>) -> RenderPoint {
    let alpha = min(max(Float(point.opacity) * color.w, 0), 1)
    return .init(position: .init(Float(point.location.x), Float(point.location.y)),
      radius: max(Float(point.size.width / 2), 0.25),
      premultipliedColor: .init(color.x * alpha, color.y * alpha, color.z * alpha, alpha))
  }

}
