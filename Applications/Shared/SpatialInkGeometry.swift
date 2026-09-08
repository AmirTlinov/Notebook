import PencilKit
import simd

/// One triangle geometry feeds the live iPad canvas and the Mac raster.
enum SpatialInkGeometry {
  struct Vertex: Equatable, Sendable {
    var position: SIMD2<Float>
    var premultipliedColor: SIMD4<Float>
  }

  /// Splitting the already generated triangles does not introduce stroke caps
  /// or another alpha blend. A chunk is only an upload/culling boundary.
  struct Chunk: Sendable {
    static let maximumVertexCount = 4_092
    let vertices: Range<Int>
    let bounds: CGRect

    func intersects(viewport: CGRect, transform: SIMD4<Float>) -> Bool {
      let projected = CGRect(x: Double(bounds.minX) * Double(transform.x) + Double(transform.z),
        y: Double(bounds.minY) * Double(transform.y) + Double(transform.w),
        width: Double(bounds.width) * Double(transform.x), height: Double(bounds.height) * Double(transform.y))
      return projected.intersects(viewport.insetBy(dx: -1, dy: -1))
    }
  }


  struct RenderPoint: Equatable, Sendable {
    var position: SIMD2<Float>
    var radius: Float
    var premultipliedColor: SIMD4<Float>
  }

  static func chunks(for vertices: [Vertex], startingAt start: Int = 0) -> [Chunk] {
    var chunks: [Chunk] = []
    for start in stride(from: start, to: vertices.count, by: Chunk.maximumVertexCount) {
      let end = min(start + Chunk.maximumVertexCount, vertices.count)
      var minX = Float.infinity, minY = Float.infinity
      var maxX = -Float.infinity, maxY = -Float.infinity
      for index in start..<end {
        let point = vertices[index].position
        minX = min(minX, point.x); minY = min(minY, point.y)
        maxX = max(maxX, point.x); maxY = max(maxY, point.y)
      }
      chunks.append(.init(vertices: start..<end,
        bounds: .init(x: Double(minX), y: Double(minY), width: Double(maxX) - Double(minX), height: Double(maxY) - Double(minY))))
    }
    return chunks
  }

  private static let capSegments = 12
  static var roundCapVertexCount: Int { capSegments * 3 }
  private static let minimumDistanceSquared: Float = 0.0001
  static func appendStrokeVertices(
    points: [PKStrokePoint],
    color: SIMD4<Float>,
    roundsStart: Bool = true,
    roundsEnd: Bool = true,
    to vertices: inout [Vertex]
  ) {
    let renderPoints = renderPoints(from: points, color: color)
    appendStrokeVertices(renderPoints: renderPoints, roundsStart: roundsStart,
      roundsEnd: roundsEnd, to: &vertices)
  }

  /// Consumes the single normalization shared with the incremental tail.
  /// A second normalization could collapse a distinct pair after near samples
  /// moved the last point back towards its preceding neighbour.
  static func appendStrokeVertices(
    renderPoints: [RenderPoint], roundsStart: Bool = true, roundsEnd: Bool = true,
    to vertices: inout [Vertex]
  ) {
    guard let first = renderPoints.first else { return }

    guard renderPoints.count > 1 else {
      appendDisk(at: first, to: &vertices)
      return
    }

    let offsets = crossSectionOffsets(for: renderPoints)
    guard offsets.count == renderPoints.count else { return }
    for index in 0..<(renderPoints.count - 1) {
      if index.isMultiple(of: 256), Task.isCancelled { return }
      let start = renderPoints[index]
      let end = renderPoints[index + 1]
      let startOffset = offsets[index]
      let endOffset = offsets[index + 1]

      let startLeft = vertex(
        at: start.position + startOffset,
        color: start.premultipliedColor
      )
      let startRight = vertex(
        at: start.position - startOffset,
        color: start.premultipliedColor
      )
      let endLeft = vertex(
        at: end.position + endOffset,
        color: end.premultipliedColor
      )
      let endRight = vertex(
        at: end.position - endOffset,
        color: end.premultipliedColor
      )

      vertices.append(contentsOf: [
        startLeft, startRight, endLeft,
        startRight, endRight, endLeft,
      ])
    }

    if roundsStart {
      let firstDirection = unitDirection(
        from: renderPoints[0].position,
        to: renderPoints[1].position
      )
      appendRoundCap(
        at: first,
        outward: -firstDirection,
        to: &vertices
      )
    }
    if roundsEnd, let last = renderPoints.last {
      let lastDirection = unitDirection(
        from: renderPoints[renderPoints.count - 2].position,
        to: last.position
      )
      appendRoundCap(at: last, outward: lastDirection, to: &vertices)
    }
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

  static func areCoincident(_ first: RenderPoint, _ second: RenderPoint) -> Bool {
    distanceSquared(first.position, second.position) < minimumDistanceSquared
  }

  private static func crossSectionOffsets(
    for points: [RenderPoint]
  ) -> [SIMD2<Float>] {
    var offsets: [SIMD2<Float>] = []
    offsets.reserveCapacity(points.count)

    for index in points.indices {
      if index.isMultiple(of: 256), Task.isCancelled { return [] }
      let incoming: SIMD2<Float>
      let outgoing: SIMD2<Float>
      if index == points.startIndex {
        outgoing = unitDirection(
          from: points[index].position,
          to: points[index + 1].position
        )
        incoming = outgoing
      } else if index == points.index(before: points.endIndex) {
        incoming = unitDirection(
          from: points[index - 1].position,
          to: points[index].position
        )
        outgoing = incoming
      } else {
        incoming = unitDirection(
          from: points[index - 1].position,
          to: points[index].position
        )
        outgoing = unitDirection(
          from: points[index].position,
          to: points[index + 1].position
        )
      }

      let incomingNormal = SIMD2<Float>(-incoming.y, incoming.x)
      let outgoingNormal = SIMD2<Float>(-outgoing.y, outgoing.x)
      let normalSum = incomingNormal + outgoingNormal
      let normal = lengthSquared(normalSum) > 0.0001
        ? normalize(normalSum)
        : outgoingNormal
      let denominator = max(abs(dot(normal, outgoingNormal)), 0.55)
      let miterLength = min(
        points[index].radius / denominator,
        points[index].radius * 1.8
      )
      offsets.append(normal * miterLength)
    }
    return offsets
  }

  private static func appendDisk(
    at point: RenderPoint,
    to vertices: inout [Vertex]
  ) {
    appendArc(
      at: point,
      startAngle: 0,
      sweep: 2 * .pi,
      segments: Self.capSegments * 2,
      to: &vertices
    )
  }

  private static func appendRoundCap(
    at point: RenderPoint,
    outward: SIMD2<Float>,
    to vertices: inout [Vertex]
  ) {
    let middleAngle = atan2(outward.y, outward.x)
    appendArc(
      at: point,
      startAngle: middleAngle - (.pi / 2),
      sweep: .pi,
      segments: Self.capSegments,
      to: &vertices
    )
  }

  private static func appendArc(
    at point: RenderPoint,
    startAngle: Float,
    sweep: Float,
    segments: Int,
    to vertices: inout [Vertex]
  ) {
    let center = vertex(
      at: point.position,
      color: point.premultipliedColor
    )
    for segment in 0..<segments {
      let firstAngle = startAngle
        + (Float(segment) / Float(segments)) * sweep
      let secondAngle = startAngle
        + (Float(segment + 1) / Float(segments)) * sweep
      let first = point.position + SIMD2(
        cos(firstAngle) * point.radius,
        sin(firstAngle) * point.radius
      )
      let second = point.position + SIMD2(
        cos(secondAngle) * point.radius,
        sin(secondAngle) * point.radius
      )
      vertices.append(center)
      vertices.append(vertex(at: first, color: point.premultipliedColor))
      vertices.append(vertex(at: second, color: point.premultipliedColor))
    }
  }

  private static func vertex(
    at position: SIMD2<Float>,
    color: SIMD4<Float>
  ) -> Vertex {
    Vertex(position: position, premultipliedColor: color)
  }

  private static func unitDirection(
    from start: SIMD2<Float>,
    to end: SIMD2<Float>
  ) -> SIMD2<Float> {
    let delta = end - start
    guard lengthSquared(delta) > Self.minimumDistanceSquared else {
      return SIMD2(1, 0)
    }
    return normalize(delta)
  }

  private static func distanceSquared(
    _ first: SIMD2<Float>,
    _ second: SIMD2<Float>
  ) -> Float {
    lengthSquared(first - second)
  }

  private static func lengthSquared(_ value: SIMD2<Float>) -> Float {
    dot(value, value)
  }

}
