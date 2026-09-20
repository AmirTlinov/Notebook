import Foundation

import simd

/// One compact display geometry feeds the live canvas and the Mac raster.
public enum SpatialInkGeometry {
  /// Queries also serve exact vector point/edge contact, not just pixel rectangles.
  private static func overlaps(_ a: CGRect,_ b: CGRect) -> Bool {
    !a.isNull && !b.isNull && a.maxX >= b.minX && a.minX <= b.maxX && a.maxY >= b.minY && a.minY <= b.maxY
  }
  public typealias Vertex = InkStrokeGeometry.Vertex
  public typealias Node = InkRenderGeometry.Node
  public struct Chunk: Sendable {
    public let nodes: Range<Int>
    public let bounds: CGRect
    public let color: SIMD4<Float>
    public let flags: UInt32
    public let levels: [InkRenderGeometry.Level]
    public var vertexCount: Int { InkRenderGeometry.vertexCount(nodes: nodes.count, flags: flags) }
    public var metadataBytes: Int { levels.reduce(0) { $0 + $1.indices.count * 2 } }
    public init(
      nodes: Range<Int>, bounds: CGRect, color: SIMD4<Float> = .init(repeating: 1),
      flags: UInt32 = 3,
      levels: [InkRenderGeometry.Level] = []
    ) {
      self.nodes = nodes; self.bounds = bounds; self.color = color; self.flags = flags;
      self.levels = levels
    }
    public func intersects(viewport: CGRect, transform: SIMD4<Float>) -> Bool {
      let projected = CGRect(x: Double(bounds.minX) * Double(transform.x) + Double(transform.z),
        y: Double(bounds.minY) * Double(transform.y) + Double(transform.w),
        width: Double(bounds.width) * Double(transform.x), height: Double(bounds.height) * Double(transform.y))
      return projected.intersects(viewport.insetBy(dx: -1, dy: -1))
    }
  }

  /// Immutable bounds tree of upload chunks, built with the mesh off the frame
  /// path. Queries visit intersecting branches before touching chunk geometry.
  public struct ChunkIndex: Sendable {
    private let index: InkBoundsIndex
    public var byteCount: Int { index.byteCount }
    public init(_ chunks: [Chunk]) { index = .init(chunks.map(\.bounds)) }

    public func query(viewport: CGRect, transform: SIMD4<Float>) -> (chunks: [Int], visitedNodes: Int) {
      guard transform.x > 0, transform.y > 0 else { return ([], 0) }
      let padded = viewport.insetBy(dx: -1, dy: -1)
      let local = CGRect(x: (padded.minX - Double(transform.z)) / Double(transform.x),
        y: (padded.minY - Double(transform.w)) / Double(transform.y),
        width: padded.width / Double(transform.x), height: padded.height / Double(transform.y))
      let result = index.query(local)
      return (result.indices, result.visitedNodes)
    }
  }


  public typealias RenderPoint = InkStrokeGeometry.RenderPoint

  public static func chunks(
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
  public static func compact(source: InkSampleRelations, range: Range<Int>? = nil,
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

  public static func areCoincident(_ a: RenderPoint, _ b: RenderPoint) -> Bool { InkStrokeGeometry.areCoincident(a,b) }

  public static func renderPoint(from sample: SpatialInkSample, color: SIMD4<Float>,
    projection: InkSampleProjection = .init()) -> RenderPoint {
    let p=projection.origin.flatMap { origin in sample.worldPoint.map { origin.delta(to:$0) } } ?? sample.point
    let alpha=min(max(Float(sample.opacity)*color.w,0),1)
    return .init(position:.init(Float(p.x*projection.scale+projection.offset.x),Float(p.y*projection.scale+projection.offset.y)),
      radius:max(Float(sample.width*projection.scale/2),0.25),
      premultipliedColor:.init(color.x*alpha,color.y*alpha,color.z*alpha,alpha))
  }

}

/// Frozen physical input-to-canvas projection. It never rewrites measurements.
public struct InkSampleProjection: Sendable {
  public init(origin: WorldPoint? = nil,offset: SpatialPoint = .zero,scale: Double = 1) { self.origin=origin;self.offset=offset;self.scale=scale }
  public var origin: WorldPoint? = nil
  public var offset: SpatialPoint = .zero
  public var scale: Double = 1
}

extension SpatialInkGeometry {
  public struct PreparedChunk: Sendable {
    public let nodes: ArraySlice<Node>
    public let descriptor: Chunk
    private let ownedStorageBytes: Int
    public init(nodes: [Node],descriptor: Chunk) {
      self.nodes=nodes[...];self.descriptor=descriptor
      ownedStorageBytes=nodes.capacity*MemoryLayout<Node>.stride+descriptor.metadataBytes
    }
    public init(sharedNodes: ArraySlice<Node>,descriptor: Chunk) {
      nodes=sharedNodes;self.descriptor=descriptor;ownedStorageBytes=0
    }
    public var byteCount: Int { MemoryLayout<Self>.stride+ownedStorageBytes }
    public func selected(level: Int) -> ArraySlice<Node> {
      level >= 0 ? descriptor.levels[level].indices.map { nodes[nodes.startIndex+Int($0)] }[...] : nodes
    }
  }

  /// Virtual chunks use the source's range tree; there is no second bounds tree
  /// or per-event display array. Coalescing-ambiguous input uses the same existing
  /// full normalizer instead: omitting its prefix state would change the stroke.
  public struct RelativeSource: Sendable {
    public let source: InkSampleRelations
    public let projection: InkSampleProjection
    public var bounds: CGRect { projected(source.geometry.bounds) }
    public var chunkCount: Int { source.count == 0 ? 0 : source.geometry.stationary ? 1 : max(1,(source.count-2)/InkRenderGeometry.maximumSegments+1) }
    public init?(_ source: InkSampleRelations,projection: InkSampleProjection) {
      self.source=source;self.projection=projection
      let geometry=source.geometry
      guard geometry.origin == nil || projection.origin != nil else { return nil }
      let box=projected(geometry.bounds)
      let magnitude=[box.minX,box.minY,box.maxX,box.maxY].map { abs(Float($0)) }.max() ?? .infinity
      let error=4*Double(magnitude.ulp)
      guard source.count <= 1 || geometry.stationary || (error.isFinite && geometry.minimumSpacing*abs(projection.scale)
        > Double(InkStrokeGeometry.minimumDistanceSquared.squareRoot())+error) else { return nil }
    }
    public func range(at id: Int) -> Range<Int> {
      precondition((0..<chunkCount).contains(id))
      if source.geometry.stationary { return (source.count-1)..<source.count }
      let start=id*InkRenderGeometry.maximumSegments
      return start..<(start+min(source.count-start,InkRenderGeometry.maximumSegments+1))
    }
    private func projected(_ box: CGRect) -> CGRect {
      var box=box
      if let origin=source.geometry.origin,let target=projection.origin {
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
    public func query(viewport: CGRect,affine: InkAffine = .init()) -> (chunks: [Int],cost: InkSampleRelations.AccessCost) {
      guard chunkCount > 0 else { return ([],.init()) }
      func overlaps(_ rect: CGRect) -> Bool {
        let bounds=affine.bounds(projected(rect))
        let magnitude=[bounds.minX,bounds.minY,bounds.maxX,bounds.maxY].map { abs(Float($0)) }.max() ?? .infinity
        let padding=8*Double(magnitude.ulp)
        return !padding.isFinite || SpatialInkGeometry.overlaps(bounds.insetBy(dx:-padding,dy:-padding),viewport)
      }
      if source.geometry.stationary {
        let result=try! source.bounds(in:0..<source.count)
        return (overlaps(result.bounds) ? [0] : [],result.cost)
      }
      // Cancellation stops an obsolete frame, not an alternative renderer.
      guard let query=try? source.querySegments(maximumSegments:InkRenderGeometry.maximumSegments,intersecting:overlaps) else {
        return ([],.init())
      }
      return (query.segments,query.cost)
    }
    public func prepare(_ id: Int) -> (chunk: PreparedChunk,decodedPoints: Int) {
      let range=range(at:id)
      let halo=source.geometry.stationary ? range : max(0,range.lowerBound-1)..<(range.upperBound+(range.upperBound < source.count ? 1 : 0))
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

extension SpatialInkGeometry {
  public struct Source: Sendable {
    public enum Storage: Sendable {
      case prepared([SpatialInkGeometry.Node],[SpatialInkGeometry.Chunk],SpatialInkGeometry.ChunkIndex?)
      case relative(SpatialInkGeometry.RelativeSource)
    }
    public let storage: Storage
    public let bounds: CGRect
    public init(nodes: [SpatialInkGeometry.Node],chunks: [SpatialInkGeometry.Chunk]) {
      storage = .prepared(nodes,chunks,chunks.count > 1 ? .init(chunks) : nil);bounds=chunks.reduce(.null) { $0.union($1.bounds) }
    }
    public init(source: InkSampleRelations,projection: InkSampleProjection) {
      if source.count > InkRenderGeometry.maximumSegments,
        let relative=SpatialInkGeometry.RelativeSource(source,projection:projection) {
        storage = .relative(relative);bounds=relative.bounds
      } else {
        let c=source.header.color
        let color: SIMD4<Float> = source.header.tool == .eraser ? .init(repeating:1) : .init(Float(c.red),Float(c.green),Float(c.blue),1)
        let nodes=SpatialInkGeometry.compact(source:source,origin:projection.origin,offset:projection.offset,scale:projection.scale)
        let chunks=SpatialInkGeometry.chunks(for:nodes,color:color,eraser:source.header.tool == .eraser)
        storage = .prepared(nodes,chunks,chunks.count > 1 ? .init(chunks) : nil);bounds=chunks.reduce(.null) { $0.union($1.bounds) }
      }
    }
    public var chunkCount: Int { switch storage { case .prepared(_,let c,_): c.count;case .relative(let r): r.chunkCount } }
    public var sourceNodeCount: Int { switch storage { case .prepared(let n,_,_): n.count;case .relative(let r): r.source.count } }
    public var preparedNodeCount: Int { if case .prepared(let n,_,_)=storage { return n.count };return 0 }
    public var byteCount: Int {
      switch storage {
      case .prepared(let n,let c,let index): return n.count*MemoryLayout<SpatialInkGeometry.Node>.stride+(index?.byteCount ?? 0)
        + c.reduce(0) { $0+MemoryLayout<Chunk>.stride+$1.metadataBytes }
      case .relative(let r): return r.source.payloadBytes+MemoryLayout<InkSampleProjection>.stride
      }
    }
    public var auxiliaryBytes: Int {
      if case .relative(let r)=storage { return r.source.auxiliaryBytes+MemoryLayout<InkSampleProjection>.stride }
      return byteCount
    }
    public func query(viewport: CGRect,affine: InkAffine) -> (chunks: [Int],cost: InkSampleRelations.AccessCost) {
      switch storage {
      case .relative(let r): return r.query(viewport:viewport,affine:affine)
      case .prepared(_,let chunks,let index):
        // Native canvas uses positive diagonal camera transforms. General
        // raster transforms keep the same conservative per-chunk rejection.
        if let index,affine.x.y == 0,affine.y.x == 0,affine.x.x > 0,affine.y.y > 0 {
          let q=index.query(viewport:viewport,transform:.init(affine.x.x,affine.y.y,affine.x.z,affine.y.z))
          return (q.chunks,.init(visitedNodes:q.visitedNodes))
        }
        return (chunks.indices.filter { SpatialInkGeometry.overlaps(affine.bounds(chunks[$0].bounds),viewport) },.init(visitedNodes:chunks.count))
      }
    }
    public func prepare(_ id: Int) -> (chunk: SpatialInkGeometry.PreparedChunk,decodedPoints: Int) {
      switch storage {
      case .relative(let r): return r.prepare(id)
      case .prepared(let nodes,let chunks,_):
        let c=chunks[id],local=nodes[c.nodes]
        return (.init(sharedNodes:local,descriptor:.init(nodes:0..<local.count,bounds:c.bounds,color:c.color,flags:c.flags,levels:c.levels)),0)
      }
    }
  }
}
