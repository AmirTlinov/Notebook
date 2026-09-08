import PencilKit
import simd

/// Raw measurements map to the single normalized strip. A coincident sample
/// replaces the final point without invalidating the already sealed prefix.
struct IncrementalInkMesh {
  private(set) var vertices: [SpatialInkGeometry.Vertex] = []
  private(set) var chunks: [SpatialInkGeometry.Chunk] = []
  private(set) var rebuiltPointCount = 0
  private(set) var rebuiltVertexStart = 0
  private var normalized: [SpatialInkGeometry.RenderPoint] = []
  private var rawToNormalized: [Int] = []
  private var color: SIMD4<Float>?
  private static var capVertexCount: Int { SpatialInkGeometry.roundCapVertexCount }

  mutating func update(points: [PKStrokePoint], changedFrom: Int, color: SIMD4<Float>) {
    update(count: points.count, point: { points[$0] }, changedFrom: changedFrom, color: color)
  }

  mutating func update(measured: [PKStrokePoint], predicted: [PKStrokePoint],
    changedFrom: Int, color: SIMD4<Float>) {
    update(count: measured.count + predicted.count,
      point: { $0 < measured.count ? measured[$0] : predicted[$0 - measured.count] },
      changedFrom: changedFrom, color: color)
  }

  private mutating func update(count: Int, point: (Int) -> PKStrokePoint,
    changedFrom: Int, color: SIMD4<Float>) {
    let oldCount = normalized.count
    let start = self.color == color ? max(0, min(changedFrom, rawToNormalized.count, count)) : 0
    self.color = color
    var changed: Int
    if start == 0 {
      normalized.removeAll(keepingCapacity: true)
      rawToNormalized.removeAll(keepingCapacity: true)
      changed = 0
    } else {
      let last = rawToNormalized[start - 1]
      let restored = SpatialInkGeometry.renderPoint(from: point(start - 1), color: color)
      changed = normalized[last] == restored ? last + 1 : last
      normalized.removeSubrange((last + 1)...)
      normalized[last] = restored
      rawToNormalized.removeSubrange(start...)
    }
    for index in start..<count {
      let next = SpatialInkGeometry.renderPoint(from: point(index), color: color)
      if let last = normalized.last, SpatialInkGeometry.areCoincident(last, next) {
        changed = min(changed, normalized.count - 1)
        normalized[normalized.count - 1] = next
      } else {
        normalized.append(next)
      }
      rawToNormalized.append(normalized.count - 1)
    }

    let firstSegment = max(0, min(changed, oldCount) - 2)
    if firstSegment == 0 || oldCount < 3 || normalized.count < 3 {
      vertices.removeAll(keepingCapacity: true)
      SpatialInkGeometry.appendStrokeVertices(renderPoints: normalized, to: &vertices)
      rebuiltPointCount = normalized.count
      rebuiltVertexStart = 0
    } else {
      let tailStart = firstSegment - 1
      let capStart = (oldCount - 1) * 6
      let startCap = Array(vertices[capStart..<(capStart + Self.capVertexCount)])
      var tail: [SpatialInkGeometry.Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(renderPoints: Array(normalized.dropFirst(tailStart)),
        roundsStart: false, to: &tail)
      rebuiltVertexStart = firstSegment * 6
      vertices.removeSubrange(rebuiltVertexStart...)
      vertices.append(contentsOf: tail.dropFirst(6).dropLast(Self.capVertexCount))
      vertices.append(contentsOf: startCap)
      vertices.append(contentsOf: tail.suffix(Self.capVertexCount))
      rebuiltPointCount = normalized.count - tailStart
    }
    let chunkIndex = min(rebuiltVertexStart / SpatialInkGeometry.Chunk.maximumVertexCount, chunks.count)
    chunks.removeSubrange(chunkIndex...)
    chunks.append(contentsOf: SpatialInkGeometry.chunks(for: vertices,
      startingAt: chunkIndex * SpatialInkGeometry.Chunk.maximumVertexCount))
  }
}
