import PencilKit
import simd

/// Stable segments retain their triangles. Two neighbouring points determine
/// the first affected join; predictions and pressure corrections replace its tail.
struct IncrementalInkMesh {
  private(set) var vertices: [SpatialInkGeometry.Vertex] = []
  private(set) var rebuiltPointCount = 0
  private var pointCount = 0
  private var hasCoincidentPoints = false
  private static var capVertexCount: Int { SpatialInkGeometry.roundCapVertexCount }

  mutating func update(points: [PKStrokePoint], changedFrom: Int, color: SIMD4<Float>) {
    let firstSegment = max(0, min(changedFrom, pointCount) - 2)
    let tailStart = max(0, firstSegment - 1)
    let changedPoints = Array(points.dropFirst(tailStart))
    let tailHasCoincident = zip(changedPoints, changedPoints.dropFirst()).contains { a, b in
      let dx = (Float(a.location.x) - Float(b.location.x))
      let dy = (Float(a.location.y) - Float(b.location.y))
      return dx * dx + dy * dy < 0.0001
    }
    if firstSegment == 0 || pointCount < 3 || points.count < 3 || hasCoincidentPoints
      || tailHasCoincident
    {
      vertices.removeAll(keepingCapacity: true)
      SpatialInkGeometry.appendStrokeVertices(points: points, color: color, to: &vertices)
      rebuiltPointCount = points.count
      hasCoincidentPoints = zip(points, points.dropFirst()).contains { a, b in
        let dx = (Float(a.location.x) - Float(b.location.x))
        let dy = (Float(a.location.y) - Float(b.location.y))
        return dx * dx + dy * dy < 0.0001
      }
    } else {
      let oldCapStart = (pointCount - 1) * 6
      let startCap = Array(vertices[oldCapStart..<(oldCapStart + Self.capVertexCount)])
      var tail: [SpatialInkGeometry.Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(
        points: changedPoints, color: color, roundsStart: false, to: &tail)
      vertices.removeSubrange((firstSegment * 6)...)
      vertices.append(contentsOf: tail.dropFirst(6).dropLast(Self.capVertexCount))
      vertices.append(contentsOf: startCap)
      vertices.append(contentsOf: tail.suffix(Self.capVertexCount))
      rebuiltPointCount = changedPoints.count
    }
    pointCount = points.count
  }
}
