import CoreGraphics
import NotebookCore
import simd

/// Raw measurements map to the single normalized strip. A coincident sample
/// replaces the final point without invalidating the already sealed prefix.
struct IncrementalInkMesh {
  private var geometry = IncrementalInkGeometry()
  var nodes: [SpatialInkGeometry.Node] { geometry.nodes }
  private(set) var chunks: [SpatialInkGeometry.Chunk] = []
  private(set) var chunkRevisions: [UInt64] = []
  /// Both sides of a rebuilt tail, including pixels vacated by a correction.
  private(set) var changedBounds = CGRect.null
  private var revision: UInt64 = 0
  var rebuiltPointCount: Int { geometry.rebuiltPointCount }
  var rebuiltNodeStart: Int { geometry.rebuiltNodeStart }
  private var color: SIMD4<Float>?
  let eraser: Bool
  init(eraser: Bool = false) { self.eraser = eraser }

  mutating func update(measured: InkSampleRelations.Contact,predicted: [SpatialInkSample] = [],
    changedFrom: Int,color: SIMD4<Float>,projection: InkSampleProjection = .init()) {
    update(count:measured.count+predicted.count,
      sample:{ $0 < measured.count ? measured.sample(at:$0) : predicted[$0-measured.count] },
      forEach:{ range,emit in
        if range.lowerBound < measured.count { measured.forEach(in:range.lowerBound..<min(range.upperBound,measured.count),emit) }
        if range.upperBound > measured.count { for i in max(0,range.lowerBound-measured.count)..<(range.upperBound-measured.count) { emit(predicted[i]) } }
      },changedFrom:changedFrom,color:color,projection:projection)
  }

  mutating func update(count: Int,sample: (Int)->SpatialInkSample,
    forEach: (Range<Int>,(SpatialInkSample)->Void)->Void,
    changedFrom: Int,color: SIMD4<Float>,projection: InkSampleProjection) {
    let start = self.color == color ? changedFrom : 0
    self.color = color
    geometry.update(count: count, changedFrom: start,
      point: { SpatialInkGeometry.renderPoint(from: sample($0), color: color, projection: projection) },
      forEach: { range, emit in
        // Both traversals are synchronous. Borrow the callback across the
        // projection closure without materializing another sample buffer.
        withoutActuallyEscaping(emit) { borrowed in
          forEach(range) { borrowed(SpatialInkGeometry.renderPoint(from: $0, color: color, projection: projection)) }
        }
      })
    let firstSegment = max(0, rebuiltNodeStart - 1)
    let chunkIndex = min(firstSegment / InkRenderGeometry.maximumSegments, chunks.count)
    changedBounds = chunks[chunkIndex...].reduce(CGRect.null) { $0.union($1.bounds) }
    chunks.removeSubrange(chunkIndex...)
    chunkRevisions.removeSubrange(chunkIndex...)
    revision &+= 1
    let fresh = SpatialInkGeometry.chunks(
      for: nodes, color: color, eraser: eraser,
      startingSegment: chunkIndex * InkRenderGeometry.maximumSegments, buildLOD: false)
    for chunk in fresh {
      changedBounds = changedBounds.union(chunk.bounds)
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
