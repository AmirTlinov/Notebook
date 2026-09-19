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
    private struct Node: Sendable {
      let bounds: CGRect
      let left: Int
      let right: Int
      let chunk: Int
    }
    private let nodes: [Node]
    var byteCount: Int { nodes.count * MemoryLayout<Node>.stride }

    init(_ chunks: [Chunk]) {
      var nodes: [Node] = []
      nodes.reserveCapacity(max(0, chunks.count * 2 - 1))
      func build(_ ids: [Int]) -> Int {
        let id = nodes.count
        let bounds = ids.reduce(CGRect.null) { $0.union(chunks[$1].bounds) }
        nodes.append(.init(bounds: bounds, left: -1, right: -1, chunk: -1))
        if ids.count == 1 {
          nodes[id] = .init(bounds: bounds, left: -1, right: -1, chunk: ids[0])
        } else {
          let horizontal = bounds.width >= bounds.height
          let ordered = ids.sorted {
            let a = horizontal ? chunks[$0].bounds.midX : chunks[$0].bounds.midY
            let b = horizontal ? chunks[$1].bounds.midX : chunks[$1].bounds.midY
            return a == b ? $0 < $1 : a < b
          }
          let middle = ordered.count / 2
          let left = build(Array(ordered[..<middle])), right = build(Array(ordered[middle...]))
          nodes[id] = .init(bounds: bounds, left: left, right: right, chunk: -1)
        }
        return id
      }
      if !chunks.isEmpty { _ = build(Array(chunks.indices)) }
      self.nodes = nodes
    }

    func query(viewport: CGRect, transform: SIMD4<Float>) -> (chunks: [Int], visitedNodes: Int) {
      guard !nodes.isEmpty, transform.x > 0, transform.y > 0 else { return ([], 0) }
      let padded = viewport.insetBy(dx: -1, dy: -1)
      let local = CGRect(x: (padded.minX - Double(transform.z)) / Double(transform.x),
        y: (padded.minY - Double(transform.w)) / Double(transform.y),
        width: padded.width / Double(transform.x), height: padded.height / Double(transform.y))
      var pending = [0], found: [Int] = [], visited = 0
      while let id = pending.popLast() {
        let node = nodes[id]; visited += 1
        guard node.bounds.intersects(local) else { continue }
        if node.chunk >= 0 { found.append(node.chunk) }
        else { pending.append(node.right); pending.append(node.left) }
      }
      // Spatial traversal must never reorder translucent ink or an eraser.
      return (found.sorted(), visited)
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
