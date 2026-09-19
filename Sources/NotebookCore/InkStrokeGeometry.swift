import Foundation
import simd

/// One measured stroke tessellator for Metal, erasure paint and semantic picking.
public enum InkStrokeGeometry {
  public struct Vertex: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var premultipliedColor: SIMD4<Float>
    public init(position: SIMD2<Float>, premultipliedColor: SIMD4<Float>) {
      self.position = position; self.premultipliedColor = premultipliedColor
    }
  }
  public struct RenderPoint: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var radius: Float
    public var premultipliedColor: SIMD4<Float>
    public init(position: SIMD2<Float>, radius: Float, premultipliedColor: SIMD4<Float>) {
      self.position = position; self.radius = radius; self.premultipliedColor = premultipliedColor
    }
  }
  private static let capSegments = 12
  public static var roundCapVertexCount: Int { capSegments * 3 }
  private static let minimumDistanceSquared: Float = 0.0001
  /// Consumes the single normalization shared with the incremental tail.
  /// A second normalization could collapse a distinct pair after near samples
  /// moved the last point back towards its preceding neighbour.
  public static func appendStrokeVertices(
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

  public static var roundDiskVertexCount: Int { capSegments * 6 }
  public static var roundSweepSegmentVertexCount: Int { 6 + roundDiskVertexCount }

  /// A round eraser sweeps disks, never the pen's mitered cross sections.
  /// The fixed segment layout also lets the live mesh replace only its tail.
  public static func appendEraserVertices(renderPoints: [RenderPoint], includesStart: Bool = true,
    to vertices: inout [Vertex]) {
    guard let first = renderPoints.first else { return }
    if includesStart { appendDisk(at:first,to:&vertices) }
    for index in 1..<renderPoints.count {
      if index.isMultiple(of:256), Task.isCancelled { return }
      let a = renderPoints[index-1], b = renderPoints[index]
      let direction = unitDirection(from:a.position,to:b.position)
      let normal = SIMD2<Float>(-direction.y,direction.x)
      let al = vertex(at:a.position+normal*a.radius,color:a.premultipliedColor)
      let ar = vertex(at:a.position-normal*a.radius,color:a.premultipliedColor)
      let bl = vertex(at:b.position+normal*b.radius,color:b.premultipliedColor)
      let br = vertex(at:b.position-normal*b.radius,color:b.premultipliedColor)
      vertices.append(contentsOf:[al,ar,bl,ar,br,bl])
      appendDisk(at:b,to:&vertices)
    }
  }

  public static func areCoincident(_ first: RenderPoint, _ second: RenderPoint) -> Bool {
    distanceSquared(first.position, second.position) < minimumDistanceSquared
  }

  private static func crossSectionOffsets(for points: [RenderPoint]) -> [SIMD2<Float>] {
    var result: [SIMD2<Float>] = []
    result.reserveCapacity(points.count)
    for index in points.indices {
      if index.isMultiple(of: 256), Task.isCancelled { return [] }
      result.append(crossSectionOffset(at: index, in: points))
    }
    return result
  }

  public static func crossSectionOffset(at index: Int, in points: [RenderPoint]) -> SIMD2<Float> {
    guard points.count > 1 else { return .init(points[index].radius, 0) }
    let incoming =
      index == 0
      ? unitDirection(from: points[0].position, to: points[1].position)
      : unitDirection(from: points[index - 1].position, to: points[index].position)
    let outgoing =
      index == points.count - 1
      ? incoming
      : unitDirection(from: points[index].position, to: points[index + 1].position)
    let outgoingNormal = SIMD2<Float>(-outgoing.y, outgoing.x)
    let sum = SIMD2<Float>(-incoming.y, incoming.x) + outgoingNormal
    let normal = lengthSquared(sum) > 0.0001 ? normalize(sum) : outgoingNormal
    let denominator = max(abs(dot(normal, outgoingNormal)), 0.55)
    return normal * min(points[index].radius / denominator, points[index].radius * 1.8)
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
      // Close a disk with the identical first vertex. sin(2π) in Float leaves
      // a microscopic wedge that boolean subtraction otherwise retains.
      let secondAngle = segment == segments-1 && sweep == 2 * .pi ? startAngle : startAngle
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
