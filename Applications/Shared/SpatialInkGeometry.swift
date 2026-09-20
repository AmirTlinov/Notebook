import Foundation

import NotebookCore
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
  /// Same compact geometry owner; the source chooses only proved display ranges.
  /// No PencilKit objects or full decoded measurement array are created here.
  static func compact(source: InkSampleRelations, range: Range<Int>? = nil,
    origin: WorldPoint? = nil, offset: SpatialPoint = .zero, scale: Double = 1) -> [Node] {
    let c = source.header.color
    let color: SIMD4<Float> = source.header.tool == .eraser ? .init(repeating:1)
      : .init(Float(c.red),Float(c.green),Float(c.blue),1)
    var points: [RenderPoint] = []
    source.forEachDisplayPoint(in:range,origin:origin,offset:offset,scale:scale) { position,radius,opacity in
      let alpha = min(max(opacity*color.w,0),1)
      let p = RenderPoint(position:position,radius:max(radius,0.25),
        premultipliedColor:.init(color.x*alpha,color.y*alpha,color.z*alpha,alpha))
      if let last = points.last, areCoincident(last,p) { points[points.count-1] = p }
      else { points.append(p) }
    }
    return points.indices.map { InkRenderGeometry.node(at:$0,in:points) }
  }

  static func areCoincident(_ a: RenderPoint, _ b: RenderPoint) -> Bool { InkStrokeGeometry.areCoincident(a,b) }

  static func renderPoint(from sample: SpatialInkSample, color: SIMD4<Float>,
    projection: InkSampleProjection = .init()) -> RenderPoint {
    let p=projection.origin.flatMap { origin in sample.worldPoint.map { origin.delta(to:$0) } } ?? sample.point
    let alpha=min(max(Float(sample.opacity)*color.w,0),1)
    return .init(position:.init(Float(p.x*projection.scale+projection.offset.x),Float(p.y*projection.scale+projection.offset.y)),
      radius:max(Float(sample.width*projection.scale/2),0.25),
      premultipliedColor:.init(color.x*alpha,color.y*alpha,color.z*alpha,alpha))
  }

}

/// Frozen physical input-to-canvas projection. It never rewrites measurements.
struct InkSampleProjection: Sendable {
  var origin: WorldPoint? = nil
  var offset: SpatialPoint = .zero
  var scale: Double = 1
}

extension SpatialInkGeometry {
  struct PreparedChunk: Sendable {
    let nodes: ArraySlice<Node>
    let descriptor: Chunk
    private let ownedStorageBytes: Int
    init(nodes: [Node],descriptor: Chunk) {
      self.nodes=nodes[...];self.descriptor=descriptor
      ownedStorageBytes=nodes.capacity*MemoryLayout<Node>.stride+descriptor.metadataBytes
    }
    init(sharedNodes: ArraySlice<Node>,descriptor: Chunk) {
      nodes=sharedNodes;self.descriptor=descriptor;ownedStorageBytes=0
    }
    var byteCount: Int { MemoryLayout<Self>.stride+ownedStorageBytes }
    func selected(level: Int) -> ArraySlice<Node> {
      level >= 0 ? descriptor.levels[level].indices.map { nodes[nodes.startIndex+Int($0)] }[...] : nodes
    }
  }

  /// Virtual chunks use the source's range tree; there is no second bounds tree
  /// or per-event display array. Coalescing-ambiguous input uses the same existing
  /// full normalizer instead: omitting its prefix state would change the stroke.
  struct RelativeSource: Sendable {
    let source: InkSampleRelations
    let projection: InkSampleProjection
    var bounds: CGRect { projected(source.storage.root.geometry.bounds) }
    var chunkCount: Int { source.count == 0 ? 0 : source.storage.root.geometry.stationary ? 1 : max(1,(source.count-2)/InkRenderGeometry.maximumSegments+1) }
    init?(_ source: InkSampleRelations,projection: InkSampleProjection) {
      self.source=source;self.projection=projection
      let geometry=source.storage.root.geometry
      guard geometry.origin == nil || projection.origin != nil else { return nil }
      let box=projected(geometry.bounds)
      let magnitude=[box.minX,box.minY,box.maxX,box.maxY].map { abs(Float($0)) }.max() ?? .infinity
      let error=4*Double(magnitude.ulp)
      guard source.count <= 1 || geometry.stationary || (error.isFinite && geometry.minimumSpacing*abs(projection.scale)
        > Double(InkStrokeGeometry.minimumDistanceSquared.squareRoot())+error) else { return nil }
    }
    func range(at id: Int) -> Range<Int> {
      precondition((0..<chunkCount).contains(id))
      if source.storage.root.geometry.stationary { return (source.count-1)..<source.count }
      let start=id*InkRenderGeometry.maximumSegments
      return start..<(start+min(source.count-start,InkRenderGeometry.maximumSegments+1))
    }
    private func projected(_ box: CGRect) -> CGRect {
      var box=box
      if let origin=source.storage.root.geometry.origin,let target=projection.origin {
        let d=target.delta(to:origin);box=InkSampleRelations.Geometry.offset(box,x:d.x,y:d.y)
      }
      let x=box.minX*projection.scale+projection.offset.x,y=box.minY*projection.scale+projection.offset.y
      let endX=box.maxX*projection.scale+projection.offset.x,endY=box.maxY*projection.scale+projection.offset.y
      let projected=CGRect(x:min(x,endX),y:min(y,endY),width:abs(endX-x),height:abs(endY-y))
      let magnitude=[x,y,endX,endY].map { abs(Float($0)) }.max() ?? .infinity
      let padding=8*Double(magnitude.ulp)
      let radiusFloor=max(0,1-abs(projection.scale))*0.25*Double(InkStrokeGeometry.maximumCrossSectionScale)
      return padding.isFinite ? projected.insetBy(dx:-padding-radiusFloor,dy:-padding-radiusFloor) : .infinite
    }
    func query(viewport: CGRect,affine: InkAffine = .init()) -> (chunks: [Int],cost: InkSampleRelations.AccessCost) {
      var selected:[Int]=[],cost=InkSampleRelations.AccessCost()
      func visit(_ chunks: Range<Int>) {
        guard !chunks.isEmpty else { return }
        let lower=chunks.lowerBound*InkRenderGeometry.maximumSegments
        let upper=chunks.upperBound == chunkCount ? source.count : chunks.upperBound*InkRenderGeometry.maximumSegments+1
        let result=try! source.bounds(in:lower..<upper)
        cost.visitedNodes += result.cost.visitedNodes;cost.jumps += result.cost.jumps;cost.decodedSamples += result.cost.decodedSamples
        let bounds=affine.bounds(projected(result.bounds))
        let magnitude=[bounds.minX,bounds.minY,bounds.maxX,bounds.maxY].map { abs(Float($0)) }.max() ?? .infinity
        let padding=8*Double(magnitude.ulp)
        if padding.isFinite && !bounds.insetBy(dx:-padding,dy:-padding).intersects(viewport) { return }
        if chunks.count == 1 { selected.append(chunks.lowerBound);return }
        let mid=chunks.lowerBound+chunks.count/2
        visit(chunks.lowerBound..<mid);visit(mid..<chunks.upperBound)
      }
      visit(0..<chunkCount);return (selected,cost)
    }
    func prepare(_ id: Int) -> (chunk: PreparedChunk,decodedPoints: Int) {
      let range=range(at:id)
      let halo=source.storage.root.geometry.stationary ? range : max(0,range.lowerBound-1)..<(range.upperBound+(range.upperBound < source.count ? 1 : 0))
      let c=source.header.color,erase=source.header.tool == .eraser
      let color: SIMD4<Float> = erase ? .init(repeating:1) : .init(Float(c.red),Float(c.green),Float(c.blue),1)
      var points:[RenderPoint]=[],owned:[Int]=[]
      source.forEachIndexedDisplayPoint(in:halo,origin:projection.origin,offset:projection.offset,scale:projection.scale) { index,p,r,a in
        let alpha=min(max(a,0),1)
        if range.contains(index) { owned.append(points.count) }
        points.append(.init(position:p,radius:max(r,0.25),premultipliedColor:.init(color.x*alpha,color.y*alpha,color.z*alpha,alpha)))
      }
      let nodes=owned.map { InkRenderGeometry.node(at:$0,in:points) }
      let flags:UInt32=(id == 0 ? 1 : 0) | (id == chunkCount-1 ? 2 : 0) | (erase ? 4 : 0)
      let descriptor=Chunk(nodes:0..<nodes.count,bounds:InkRenderGeometry.bounds(nodes[...]),color:color,flags:flags,
        levels:InkRenderGeometry.levels(nodes[...],flags:flags))
      return (.init(nodes:nodes,descriptor:descriptor),points.count)
    }
  }
}
