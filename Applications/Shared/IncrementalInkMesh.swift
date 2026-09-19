import NotebookCore
import PencilKit
import simd

/// Raw measurements map to the single normalized strip. A coincident sample
/// replaces the final point without invalidating the already sealed prefix.
struct IncrementalInkMesh {
  private(set) var nodes: [SpatialInkGeometry.Node] = []
  private(set) var chunks: [SpatialInkGeometry.Chunk] = []
  private(set) var chunkRevisions: [UInt64] = []
  private var revision: UInt64 = 0
  private(set) var rebuiltPointCount = 0
  private(set) var rebuiltNodeStart = 0
  private var normalized: [SpatialInkGeometry.RenderPoint] = []
  private var rawToNormalized: [Int] = []
  private var color: SIMD4<Float>?
  let eraser: Bool
  init(eraser: Bool = false) { self.eraser = eraser }

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

    rebuiltNodeStart = max(0, min(changed, oldCount) - 1)
    nodes.removeSubrange(min(rebuiltNodeStart, nodes.count)...)
    for i in rebuiltNodeStart..<normalized.count {
      nodes.append(InkRenderGeometry.node(at: i, in: normalized))
    }
    rebuiltPointCount = normalized.count - rebuiltNodeStart
    let firstSegment = max(0, rebuiltNodeStart - 1)
    let chunkIndex = min(firstSegment / InkRenderGeometry.maximumSegments, chunks.count)
    chunks.removeSubrange(chunkIndex...)
    chunkRevisions.removeSubrange(chunkIndex...)
    revision &+= 1
    let fresh = SpatialInkGeometry.chunks(
      for: nodes, color: color, eraser: eraser,
      startingSegment: chunkIndex * InkRenderGeometry.maximumSegments, buildLOD: false)
    for chunk in fresh {
      chunkRevisions.append(revision)
      let sealed = chunk.nodes.upperBound < nodes.count
      chunks.append(
        .init(
          nodes: chunk.nodes, bounds: chunk.bounds, color: chunk.color, flags: chunk.flags,
          levels: sealed ? InkRenderGeometry.levels(nodes[chunk.nodes], flags: chunk.flags) : []))
    }
  }
  var committedChunks: [SpatialInkGeometry.Chunk] {
    guard let last = chunks.last else { return [] }
    var result = chunks
    result[result.count - 1] = .init(
      nodes: last.nodes, bounds: last.bounds, color: last.color, flags: last.flags,
      levels: InkRenderGeometry.levels(nodes[last.nodes], flags: last.flags))
    return result
  }
  var vertexCount: Int { chunks.reduce(0) { $0 + $1.vertexCount } }
  var strokeColor: SIMD4<Float> { color ?? .init(repeating: 1) }
}
