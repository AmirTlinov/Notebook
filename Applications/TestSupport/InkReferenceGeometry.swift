import NotebookCore
import PencilKit
@testable import Notebook

/// Unreduced pre-integration oracle, test-only. Production never constructs a
/// PencilKit array from accepted source measurements to prepare settled ink.
extension SpatialInkGeometry {
  static func renderPoint(from point: PKStrokePoint, color: SIMD4<Float>) -> RenderPoint {
    let alpha = min(max(Float(point.opacity) * color.w, 0), 1)
    return .init(position: .init(Float(point.location.x), Float(point.location.y)),
      radius: max(Float(point.size.width / 2), 0.25),
      premultipliedColor: .init(color.x * alpha, color.y * alpha, color.z * alpha, alpha))
  }
  static func compact(points: [PKStrokePoint], color: SIMD4<Float>) -> [Node] {
    let normalized = renderPoints(from: points, color: color)
    return normalized.indices.map { InkRenderGeometry.node(at: $0, in: normalized) }
  }

  static var roundCapVertexCount: Int { InkStrokeGeometry.roundCapVertexCount }
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

}

extension SpatialInkMesh {
  static func referencePage(_ drawing: PageInkDrawing) -> Self {
    .init(batches:drawing.activeActions.map { action in
      let points=action.samples.map { PKStrokePoint(location:.init(x:$0.point.x,y:$0.point.y),
        timeOffset:$0.timeOffset,size:.init(width:$0.width,height:$0.width),opacity:$0.opacity,
        force:$0.force,azimuth:$0.azimuth,altitude:$0.altitude) }
      let c=action.color, color: SIMD4<Float> = action.tool == .eraser ? .init(repeating:1)
        : .init(Float(c.red),Float(c.green),Float(c.blue),1)
      return .init(tool:action.tool,nodes:SpatialInkGeometry.compact(points:points,color:color),color:color,projection:.local)
    })
  }
}

extension SpatialInkRenderLayer {
  static func ink(points: [PKStrokePoint], color: SpatialInkColor) -> Self { fixture(points,tool:.pen,color:color) }
  static func erase(points: [PKStrokePoint]) -> Self { fixture(points,tool:.eraser,color:.black) }
  private static func fixture(_ points: [PKStrokePoint], tool: SpatialInkTool, color: SpatialInkColor) -> Self {
    let samples=points.map { SpatialInkSample(point:.init(x:$0.location.x,y:$0.location.y),timeOffset:$0.timeOffset,
      width:$0.size.width,opacity:$0.opacity,force:$0.force,azimuth:$0.azimuth,altitude:$0.altitude) }
    return .init(source:.init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:tool,color:color)))
  }
}


// Test adapters preserve the existing PK fixtures, not a second app input path.
extension IncrementalInkMesh {
  mutating func update(points: [PKStrokePoint],changedFrom: Int,color: SIMD4<Float>) {
    update(measured:points,predicted:[],changedFrom:changedFrom,color:color)
  }
  mutating func update(measured: [PKStrokePoint],predicted: [PKStrokePoint],changedFrom: Int,color: SIMD4<Float>) {
    func sample(_ i: Int) -> SpatialInkSample { .init(i < measured.count ? measured[i] : predicted[i-measured.count]) }
    update(count:measured.count+predicted.count,sample:sample,forEach:{ range,emit in for i in range { emit(sample(i)) } },
      changedFrom:changedFrom,color:color,projection:.init())
  }
}
@MainActor extension ActiveInkStroke {
  func replaceMeasuredTail(from start: Int,with points: [PKStrokePoint]) { replaceMeasuredTail(from:start,with:points.map(SpatialInkSample.init)) }
}
@MainActor extension ActiveEraserStroke {
  func replaceMeasuredTail(from start: Int,with points: [PKStrokePoint]) { replaceMeasuredTail(from:start,with:points.map(SpatialInkSample.init)) }
}

// Explicit full materialization for independent geometry assertions, never a
// compatibility property that a runtime caller could accidentally expand.
extension SpatialInkMesh.Batch {
  func expandedForTesting() -> (nodes: [SpatialInkGeometry.Node],chunks: [SpatialInkGeometry.Chunk]) {
    var nodes:[SpatialInkGeometry.Node]=[],chunks:[SpatialInkGeometry.Chunk]=[]
    for id in 0..<chunkCount {
      let prepared=prepareChunk(id).chunk,c=prepared.descriptor
      let shared=c.flags & 1 == 0 && chunks.last.map { $0.flags & 2 == 0 } == true && nodes.last == prepared.nodes.first
      let start=nodes.count-(shared ? 1 : 0)
      nodes.append(contentsOf:shared ? prepared.nodes.dropFirst() : prepared.nodes)
      chunks.append(.init(nodes:start..<nodes.count,bounds:c.bounds,color:c.color,flags:c.flags,levels:c.levels))
    }
    return (nodes,chunks)
  }
}
