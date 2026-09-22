import CoreGraphics
import Foundation
import simd

/// One vector owner for triangle primitives, circular sweeps and measured ink.
/// A measured layer borrows the same virtual-range geometry as the live canvas.
public final class NotebookFreehandGeometry: Sendable {
  public struct Chunk: Sendable {
    public let layer: Int
    public let range: Range<Int>
    public let bounds: CGRect
    public let sourceSize: CGSize
    public let flags: UInt32
  }
  public struct Prepared: Sendable {
    public let descriptor: Chunk
    public let geometry: SpatialInkGeometry.PreparedChunk
  }
  private enum Body: Sendable {
    case primitives([Chunk],InkBoundsIndex)
    case measured(SpatialInkGeometry.Source,CGSize)
    var count: Int { switch self { case .primitives(let c,_):c.count;case .measured(let s,_):s.chunkCount } }
    var bounds: CGRect {
      switch self {
      case .primitives(_,let index): return index.bounds
      case .measured(let source,let size): return Self.normalized(source.bounds,size:size)
      }
    }
    static func normalized(_ rect: CGRect,size: CGSize) -> CGRect {
      .init(x:rect.minX/size.width,y:rect.minY/size.height,width:rect.width/size.width,height:rect.height/size.height)
    }
  }
  public let sourceNodeCount: Int
  public let chunkCount: Int
  public let preparedNodeCount: Int
  private let layers: [NotebookFreehand.Layer]
  private let erasers: [[InkStrokeGeometry.RenderPoint]]
  private let bodies: [Body]
  private let starts: [Int]
  private let layerIndex: InkBoundsIndex

  init(_ layers: [NotebookFreehand.Layer]) {
    self.layers=layers
    var bodies:[Body]=[],erasers:[[InkStrokeGeometry.RenderPoint]]=[],starts:[Int]=[]
    var count=0,prepared=0,chunksCount=0
    for (layerID,layer) in layers.enumerated() {
      starts.append(chunksCount)
      var chunks:[Chunk]=[]
      if let measured=layer.measured {
        // Only metadata and local placement are new. The exact source body is
        // shared with the journal and survives copies and whole-pose edits.
        let source=InkSampleRelations(sourceID:measured.sourceID,span:measured.span,measurements:measured.measurements,
          header:.init(tool:layer.tool,color:layer.color))
        let body=SpatialInkGeometry.Source(source:source,projection:.init(origin:measured.origin,
          offset:.init(x:-measured.frame.x,y:-measured.frame.y)))
        bodies.append(.measured(body,.init(width:measured.frame.width,height:measured.frame.height)))
        erasers.append([]);count += measured.measurements.count;prepared += body.preparedNodeCount
      } else if let eraser=layer.eraser {
        var points:[InkStrokeGeometry.RenderPoint]=[]
        for s in eraser.samples {
          let p=InkStrokeGeometry.RenderPoint(position:.init(Float(s.point.x),Float(s.point.y)),radius:max(0.25,Float(s.width/2)),premultipliedColor:.init(repeating:1))
          if let last=points.last,InkStrokeGeometry.areCoincident(last,p) { points[points.count-1]=p } else { points.append(p) }
        }
        erasers.append(points);count += points.count;prepared += points.count
        let size=CGSize(width:eraser.size.x,height:eraser.size.y),last=points.count-1
        for start in stride(from:0,to:max(1,last),by:64) where !points.isEmpty {
          let end=min(last,start+64),range=start..<(end+1)
          let box=range.reduce(CGRect.null) { box,i in
            let p=points[i],r=Double(p.radius)
            return box.union(.init(x:(Double(p.position.x)-r)/size.width,y:(Double(p.position.y)-r)/size.height,width:2*r/size.width,height:2*r/size.height))
          }
          chunks.append(.init(layer:layerID,range:range,bounds:box,sourceSize:size,flags:4 | (start == 0 ? 1 : 0)))
        }
        bodies.append(.primitives(chunks,.init(chunks.map(\.bounds))))
      } else {
        erasers.append([]);count += layer.vertices.count
        for start in stride(from:0,to:layer.vertices.count,by:192) {
          let range=start..<min(layer.vertices.count,start+192)
          let box=range.reduce(CGRect.null) { box,i in
            let v=layer.vertices[i];return box.union(.init(x:v.x,y:v.y,width:0,height:0))
          }
          chunks.append(.init(layer:layerID,range:range,bounds:box,sourceSize:.init(width:1,height:1),flags:8))
        }
        bodies.append(.primitives(chunks,.init(chunks.map(\.bounds))))
      }
      chunksCount += bodies.last!.count
    }
    self.bodies=bodies;self.erasers=erasers;self.starts=starts
    sourceNodeCount=count;chunkCount=chunksCount;preparedNodeCount=prepared
    layerIndex = .init(bodies.map(\.bounds))
  }
  private func location(_ selection: Range<Int>) -> (layer: Int,chunk: Range<Int>) {
    precondition(!selection.isEmpty && selection.lowerBound >= 0 && selection.upperBound <= chunkCount)
    let id=selection.lowerBound
    var low=0,high=starts.count
    while low+1 < high { let mid=(low+high)/2;if starts[mid] <= id { low=mid } else { high=mid } }
    return (low,(id-starts[low])..<(selection.upperBound-starts[low]))
  }
  public func layer(at id: Range<Int>) -> Int { location(id).layer }
  public func tool(at id: Range<Int>) -> SpatialInkTool { layers[layer(at:id)].tool }
  public func color(at id: Range<Int>) -> SpatialInkColor { layers[layer(at:id)].color }
  public func query(_ area: CGRect,allowRangeCoalescing: Bool = true,detail: ((CGSize) -> InkRenderGeometry.Detail)? = nil,admitting: ((CGRect,CGSize) -> Bool)? = nil) -> (indices: [Range<Int>],visitedNodes: Int) {
    let candidates=layerIndex.query(area)
    var result:[Range<Int>]=[],visits=candidates.visitedNodes
    for layer in candidates.indices {
      switch bodies[layer] {
      case .primitives(let chunks,let index):
        let q=index.query(area)
        let selected=q.indices.filter { id in
          let c=chunks[id],b=c.bounds,u=c.sourceSize
          return admitting?(CGRect(x:b.minX*u.width,y:b.minY*u.height,width:b.width*u.width,height:b.height*u.height),u) != false
        }
        result.append(contentsOf:selected.map { (starts[layer]+$0)..<(starts[layer]+$0+1) });visits += q.visitedNodes
      case .measured(let source,let size):
        let q=source.query(viewport:.init(x:area.minX*size.width,y:area.minY*size.height,width:area.width*size.width,height:area.height*size.height),affine:.init(),allowRangeCoalescing:allowRangeCoalescing,detail:detail?(size),
          admitting:admitting.map { filter in { filter($0,size) } })
        result.append(contentsOf:q.chunks.map { (starts[layer]+$0.lowerBound)..<(starts[layer]+$0.upperBound) });visits += q.cost.visitedNodes
      }
    }
    return (result,visits)
  }
  public func prepared(at id: Range<Int>) -> Prepared {
    let at=location(id)
    switch bodies[at.layer] {
    case .measured(let source,let size):
      let prepared=source.prepare(at.chunk).chunk,c=prepared.descriptor
      let range:Range<Int>
      if case .relative(let r)=source.storage { range=r.range(at:at.chunk) } else { range=c.nodes }
      return .init(descriptor:.init(layer:at.layer,range:range,bounds:Body.normalized(c.bounds,size:size),sourceSize:size,flags:c.flags),geometry:prepared)
    case .primitives(let chunks,_):
      precondition(at.chunk.count == 1)
      let c=chunks[at.chunk.lowerBound],nodes:[InkRenderGeometry.Node]
      if c.flags & 4 != 0 {
        nodes=c.range.map { let p=erasers[c.layer][$0];return .init(position:p.position,edge:.zero,radius:p.radius,alpha:1) }
      } else {
        nodes=c.range.map { let p=layers[c.layer].vertices[$0];return .init(position:.init(Float(p.x),Float(p.y)),edge:.zero,radius:0,alpha:Float(p.opacity)) }
      }
      return .init(descriptor:c,geometry:.init(nodes:nodes,descriptor:.init(nodes:0..<nodes.count,bounds:InkRenderGeometry.bounds(nodes[...]),flags:c.flags)))
    }
  }
  /// Original triangle primitives keep their Double coordinates. Measured
  /// ranges use the same halo-resolved nodes as GPU, never a full-source mesh.
  public func vertices(at id: Range<Int>) -> [NotebookFreehand.Vertex] {
    let at=location(id)
    if case .primitives(let chunks,_)=bodies[at.layer],layers[at.layer].eraser == nil {
      return Array(layers[at.layer].vertices[chunks[at.chunk.lowerBound].range])
    }
    let p=prepared(at:id),c=p.descriptor,nodes=p.geometry.nodes
    var vertices:[InkStrokeGeometry.Vertex]=[]
    if c.flags & 4 != 0 {
      InkStrokeGeometry.appendEraserVertices(renderPoints:nodes.map {
        .init(position:$0.position,radius:$0.radius,premultipliedColor:.init(repeating:$0.alpha))
      },includesStart:c.flags & 1 != 0,to:&vertices)
    } else {
      InkStrokeGeometry.appendStrokeVertices(nodes:nodes,roundsStart:c.flags & 1 != 0,roundsEnd:c.flags & 2 != 0,to:&vertices)
    }
    return vertices.map { .init(x:Double($0.position.x)/c.sourceSize.width,y:Double($0.position.y)/c.sourceSize.height,opacity:Double($0.premultipliedColor.w)) }
  }
  public func paintPath(size: CGSize,transform: NotebookGraphicTransform?) -> CGPath {
    var result:CGPath=CGMutablePath()
    for id in query(Self.sourceBounds(CGRect(origin:.zero,size:size),size:size,transform:transform)).indices {
      let path=NotebookFreehand.path(vertices(at:id),size:size,transform:transform)
      result = tool(at:id) == .eraser ? result.subtracting(path) : result.union(path)
    }
    return result.intersection(CGPath(rect:CGRect(origin:.zero,size:size),transform:nil))
  }
  public static func sourceBounds(_ region: CGRect, size: CGSize, transform: NotebookGraphicTransform?) -> CGRect {
    let t = transform ?? .identity
    return [CGPoint(x:region.minX,y:region.minY),.init(x:region.maxX,y:region.minY),
      .init(x:region.minX,y:region.maxY),.init(x:region.maxX,y:region.maxY)].reduce(CGRect.null) { box, p in
        let q = t.unapplying(.init(x:p.x/size.width,y:p.y/size.height))
        return box.union(.init(x:q.x,y:q.y,width:0,height:0))
      }
  }
  public func contains(_ point: CGPoint, size: CGSize, transform: NotebookGraphicTransform?, tolerance: Double = 0) -> Bool {
    contains(point,size:size,transform:transform,tolerance:tolerance,clipsToSize:true)
  }
  private func contains(_ point: CGPoint,size:CGSize,transform:NotebookGraphicTransform?,tolerance:Double,clipsToSize:Bool) -> Bool {
    guard size.width > 0, size.height > 0,
      !clipsToSize || CGRect(origin:.zero,size:size).insetBy(dx:-tolerance,dy:-tolerance).contains(point) else { return false }
    let area = Self.sourceBounds(.init(x:point.x-tolerance,y:point.y-tolerance,width:tolerance*2,height:tolerance*2),size:size,transform:transform)
    let t = transform ?? .identity
    for id in query(area,allowRangeCoalescing:false).indices.reversed() {
      let cut = tool(at:id) == .eraser, padding = cut ? 0 : max(0,tolerance)
      let vertices = vertices(at:id)
      for start in stride(from:0,to:vertices.count-2,by:3) {
        let source = Array(vertices[start..<start+3])
        let p = source.map { v -> CGPoint in
          let q = t.applying(.init(x:v.x,y:v.y)); return .init(x:q.x*size.width,y:q.y*size.height)
        }
        let a = cross(p[0],p[1],p[2])
        let ab = cross(p[0],p[1],point), bc = cross(p[1],p[2],point), ca = cross(p[2],p[0],point)
        let inside = a != 0 && ((ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0))
        if inside {
          let alpha = (source[0].opacity*bc+source[1].opacity*ca+source[2].opacity*ab)/a
          if cut { if source.allSatisfy({ $0.opacity == 1 }) || alpha >= 1 { return false } }
          else if alpha > 0 { return true }
        }
        if !cut, source.contains(where:{ $0.opacity > 0 }), padding > 0,
          (near(point,p[0],p[1],padding) || near(point,p[1],p[2],padding) || near(point,p[2],p[0],padding)) { return true }
      }
    }
    return false
  }
  /// Vector set difference on bounded convex fragments, in Double precision.
  /// Avoid both pixel masks and CGPath boolean quantization: a subpixel sliver
  /// is still authored geometry, while a fully covered one must disappear.
  /// A captured cut borrows the same indexed measured geometry as its GPU
  /// layer. The affine maps that captured basis into this graphic's source.
  public struct Cut: Sendable {
    let geometry: NotebookFreehandGeometry
    let basis: CGAffineTransform
    public init(_ cut: InkElementErasure,transform:NotebookGraphicTransform? = nil) {
      geometry = NotebookFreehand(layers:[.init(tool:.eraser,color:.black,measured:.init(
        sourceID:cut.samples.revision,measurements:cut.samples,frame:cut.target.frame,origin:cut.target.worldOrigin))]).geometry
      func point(_ p:SpatialPoint) -> CGPoint {
        let body=cut.target.elementTransform?.unapplying(p) ?? p
        let source=(cut.target.graphicTransform ?? .identity).unapplying(body)
        let q=(transform ?? .identity).applying(source)
        return .init(x:q.x,y:q.y)
      }
      let a=point(.zero),b=point(.init(x:1,y:0)),c=point(.init(x:0,y:1))
      basis = .init(a:b.x-a.x,b:b.y-a.y,c:c.x-a.x,d:c.y-a.y,tx:a.x,ty:a.y)
    }
    func triangles(in area:CGRect, visit:([CGPoint]) -> Bool) -> Bool {
      var prepared:[Range<Int>:[NotebookFreehand.Vertex]]=[:]
      return triangles(in:area,prepared:&prepared,visit:visit)
    }
    func triangles(in area:CGRect,prepared:inout [Range<Int>:[NotebookFreehand.Vertex]],visit:([CGPoint])->Bool)->Bool {
      // A covered range may contain millions of repeated measurements. A
      // query needs a witness, not one expanded mesh for that entire range.
      for id in geometry.query(area.applying(basis.inverted()),allowRangeCoalescing:false).indices {
        if Task.isCancelled { return false }
        let v:[NotebookFreehand.Vertex]
        if let cached=prepared[id] { v=cached } else { v=geometry.vertices(at:id);prepared[id]=v }
        for start in stride(from:0,to:v.count-2,by:3) {
          let triangle=v[start..<start+3].map { CGPoint(x:$0.x,y:$0.y).applying(basis) }
          if polygonBounds(triangle).intersects(area),visit(triangle) { return true }
        }
      }
      return false
    }
    /// Explicit whole-source output streams the same bounded chunks used by
    /// local queries and Metal. It never retains a full triangle expansion.
    func forEachTriangle(_ visit:([CGPoint])->Void) {
      for id in 0..<geometry.chunkCount {
        if Task.isCancelled { return }
        let vertices=geometry.vertices(at:id..<(id+1))
        for start in stride(from:0,to:vertices.count-2,by:3) {
          visit(vertices[start..<start+3].map { CGPoint(x:$0.x,y:$0.y).applying(basis) })
        }
      }
    }
    func contains(_ point:CGPoint) -> Bool {
      // A zero-area CGRect intersection is empty; one ulp admits boundary
      // candidates without enlarging the exact triangle test.
      let pad=max(abs(point.x).ulp,abs(point.y).ulp,Double.ulpOfOne)
      return triangles(in:.init(x:point.x-pad,y:point.y-pad,width:pad*2,height:pad*2)) { polygonContains(point,$0) }
    }
  }

  public func contains(_ point:CGPoint,basis:CGAffineTransform,tolerance:Double,subtracting cuts:[Cut],clippedTo viewport:[CGPoint],accepting:(([CGPoint])->Bool)? = nil) -> Bool {
    let source=point.applying(basis.inverted())
    guard !cuts.contains(where:{ $0.contains(source) }) else { return false }
    if tolerance <= 0 { return polygonContains(source,viewport) && contains(source,size:.init(width:1,height:1),transform:nil,tolerance:0,clipsToSize:false) }
    let r=CGRect(x:point.x-tolerance,y:point.y-tolerance,width:tolerance*2,height:tolerance*2)
    let polygon=rectangleCorners(r).map { $0.applying(basis.inverted()) }
    return intersects(polygon,subtracting:cuts,clippedTo:viewport,accepting:{ fragment in
      guard accepting?(fragment) != false else { return false }
      let p=fragment.map { $0.applying(basis) }
      if p.count == 1 { return hypot(p[0].x-point.x,p[0].y-point.y) <= tolerance }
      return polygonContains(point,p) || zip(p,p.dropFirst()+p.prefix(1)).contains { near(point,$0.0,$0.1,tolerance) }
    })
  }

  public func intersects(_ polygon: [CGPoint], subtracting external:[Cut] = [],clippedTo viewport:[CGPoint]? = nil) -> Bool {
    intersects(polygon,subtracting:external,clippedTo:viewport,accepting:nil)
  }
  /// Exact state witnesses; no global triangle union or pixel approximation.
  public func appearance(in viewport:[CGPoint],subtracting cuts:[Cut],accepting:(([CGPoint])->Bool)? = nil) -> NotebookElementAppearance.State {
    guard intersects(viewport,subtracting:cuts,clippedTo:viewport,accepting:accepting) else { return .erased }
    let area=polygonBounds(viewport)
    for cut in cuts {
      if cut.triangles(in:area,visit:{ triangle in
        let clipped=clipConvex(triangle,to:viewport)
        return clipped.count >= 3 && self.intersects(clipped,subtracting:[],clippedTo:viewport,accepting:accepting)
      }) { return .partial }
    }
    return .intact
  }

  func intersects(_ polygon: [CGPoint], subtracting external:[Cut], clippedTo viewport:[CGPoint]?, accepting:(([CGPoint]) -> Bool)?) -> Bool {
    guard polygon.count >= 3 else { return false }
    let region=polygonBounds(polygon)
    let area=viewport.map { region.intersection(polygonBounds($0)) } ?? region
    guard !area.isNull else { return false }
    var cuts: [Range<Int>:[NotebookFreehand.Vertex]] = [:]
    // A local query resolves each measured erase chunk once, not once for
    // every pen triangle meeting it. This storage dies with the query.
    var externalPrepared=Array(repeating:[Range<Int>:[NotebookFreehand.Vertex]](),count:external.count)
    func erased(_ point:CGPoint,after layer:Int)->Bool {
      let pad=max(abs(point.x).ulp,abs(point.y).ulp,Double.ulpOfOne)
      for id in query(.init(x:point.x-pad,y:point.y-pad,width:pad*2,height:pad*2),allowRangeCoalescing:false).indices
        where self.layer(at:id) > layer && tool(at:id) == .eraser {
        let vertices:[NotebookFreehand.Vertex]
        if let cached=cuts[id] { vertices=cached } else { vertices=self.vertices(at:id);cuts[id]=vertices }
        for start in stride(from:0,to:vertices.count-2,by:3) {
          if triangleOpacity(at:point,vertices[start..<start+3]) >= 1 { return true }
        }
      }
      return false
    }
    for id in query(area,allowRangeCoalescing:false).indices.reversed() where tool(at:id) == .pen {
      if Task.isCancelled { return false }
      let v = vertices(at:id)
      for start in stride(from:0,to:v.count-2,by:3) {
        let triangle = Array(v[start..<start+3])
        guard triangle.contains(where:{ $0.opacity > 0 }) else { continue }
        let original = triangle.map { CGPoint(x:$0.x,y:$0.y) }
        let p=viewport.map { clipConvex(original,to:$0) } ?? original
        guard p.count >= 3,polygonIntersects(p,polygon) else { continue }
        // A surviving vector point is a proof, not a sampling approximation:
        // only a positive result exits here; absence still uses exact clipping.
        // Usually a long stroke has an untouched endpoint, so dense unrelated
        // cuts must not force thousands of polygon subtractions to find it.
        let center = CGPoint(x:p.reduce(0) { $0+$1.x }/Double(p.count),y:p.reduce(0) { $0+$1.y }/Double(p.count))
        let witnesses = p + [center] + polygon.prefix(16).filter { polygonContains($0,p) }
        if external.isEmpty,witnesses.contains(where: { point in polygonContains(point,polygon)
          && triangleOpacity(at:point,triangle[...]) > 0 && !erased(point,after:layer(at:id))
          && (accepting?([point]) ?? true) }) { return true }
        var remaining = [p]
        for cut in query(polygonBounds(p).intersection(area),allowRangeCoalescing:false).indices
        where layer(at:cut) > layer(at:id) && tool(at:cut) == .eraser {
          let e: [NotebookFreehand.Vertex]
          if let cached = cuts[cut] { e = cached } else { e = vertices(at:cut); cuts[cut] = e }
          for j in stride(from:0,to:e.count-2,by:3) {
            let tri = Array(e[j..<j+3])
            guard tri.allSatisfy({ $0.opacity >= 1 }) else { continue }
            let erase = tri.map { CGPoint(x:$0.x,y:$0.y) }, box = polygonBounds(erase)
            remaining = remaining.flatMap { fragment in
              polygonBounds(fragment).intersects(box) ? subtractTriangle(fragment,erase) : [fragment]
            }.filter { polygonIntersects($0,polygon) }
            if remaining.isEmpty { break }
          }
          if remaining.isEmpty { break }
          if Task.isCancelled { return false }
        }
        for index in external.indices where !remaining.isEmpty {
          _ = external[index].triangles(in:polygonBounds(p).intersection(area),prepared:&externalPrepared[index]) { erase in
            let box=polygonBounds(erase)
            remaining=remaining.flatMap { fragment in
              polygonBounds(fragment).intersects(box) ? subtractTriangle(fragment,erase) : [fragment]
            }.filter { polygonIntersects($0,polygon) }
            return remaining.isEmpty || Task.isCancelled
          }
        }
        if remaining.contains(where:{ accepting?($0) ?? true }) { return true }
      }
    }
    return false
  }

}

/// A witness belongs to its known pen triangle; only later opaque erasers
/// can revoke it. Do not re-expand the entire source for every candidate point.
private func triangleOpacity(at point:CGPoint,_ v:ArraySlice<NotebookFreehand.Vertex>)->Double {
  let a=v[v.startIndex],b=v[v.startIndex+1],c=v[v.startIndex+2]
  let p=CGPoint(x:a.x,y:a.y),q=CGPoint(x:b.x,y:b.y),r=CGPoint(x:c.x,y:c.y)
  let area=cross(p,q,r),ab=cross(p,q,point),bc=cross(q,r,point),ca=cross(r,p,point)
  guard area != 0, (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0) else { return 0 }
  if a.opacity == b.opacity,b.opacity == c.opacity { return a.opacity }
  return (a.opacity*bc+b.opacity*ca+c.opacity*ab)/area
}

private func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Double {
  (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
}
private func near(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ padding: Double) -> Bool {
  let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
  let t = length > 0 ? min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
  return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy) <= padding
}

private func polygonBounds(_ p: [CGPoint]) -> CGRect {
  p.reduce(CGRect.null) { $0.union(.init(x:$1.x,y:$1.y,width:0,height:0)) }
}
private func polygonContains(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
  var inside = false
  for (a,b) in zip(polygon,polygon.dropFirst()+polygon.prefix(1)) {
    if cross(a,b,point) == 0 && point.x >= min(a.x,b.x) && point.x <= max(a.x,b.x)
      && point.y >= min(a.y,b.y) && point.y <= max(a.y,b.y) { return true }
    if (a.y > point.y) != (b.y > point.y), point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
  }
  return inside
}
private func polygonIntersects(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
  guard a.count >= 3, b.count >= 3 else { return false }
  let x = polygonBounds(a), y = polygonBounds(b)
  guard x.maxX >= y.minX, x.minX <= y.maxX, x.maxY >= y.minY, x.minY <= y.maxY else { return false }
  if a.contains(where:{ polygonContains($0,b) }) || b.contains(where:{ polygonContains($0,a) }) { return true }
  for (p,q) in zip(a,a.dropFirst()+a.prefix(1)) {
    for (r,s) in zip(b,b.dropFirst()+b.prefix(1)) {
      let c1 = cross(p,q,r), c2 = cross(p,q,s), c3 = cross(r,s,p), c4 = cross(r,s,q)
      if ((c1 > 0 && c2 < 0) || (c1 < 0 && c2 > 0))
        && ((c3 > 0 && c4 < 0) || (c3 < 0 && c4 > 0)) { return true }
    }
  }
  return false
}
private func subtractTriangle(_ polygon: [CGPoint], _ triangle: [CGPoint]) -> [[CGPoint]] {
  let direction = cross(triangle[0],triangle[1],triangle[2])
  guard direction != 0 else { return [polygon] }
  var inside = polygon, result: [[CGPoint]] = []
  func clipped(_ p: [CGPoint], _ a: CGPoint, _ b: CGPoint, keepInside: Bool) -> [CGPoint] {
    var output: [CGPoint] = []
    let sign = (direction > 0 ? 1.0 : -1.0) * (keepInside ? 1 : -1)
    for (start,end) in zip(p,p.dropFirst()+p.prefix(1)) {
      let x = cross(a,b,start)*sign, y = cross(a,b,end)*sign
      if x >= 0 { output.append(start) }
      if (x > 0 && y < 0) || (x < 0 && y > 0) {
        let t = x/(x-y)
        output.append(.init(x:start.x+(end.x-start.x)*t,y:start.y+(end.y-start.y)*t))
      }
    }
    return output
  }
  func hasArea(_ p: [CGPoint]) -> Bool {
    guard p.count >= 3 else { return false }
    // Translation-invariant fan avoids catastrophic cancellation at large coordinates.
    let area = abs((1..<p.count-1).reduce(0.0) { $0+cross(p[0],p[$1],p[$1+1]) })
    let length = p.reduce(0.0) { max($0,abs($1.x-p[0].x),abs($1.y-p[0].y)) }
    // Error is bounded by coordinate ulps, not by a screen-pixel tolerance.
    let magnitude = p.reduce(length) { max($0,abs($1.x),abs($1.y)) }
    return area > length*magnitude*Double.ulpOfOne*16
  }
  for (a,b) in zip(triangle,triangle.dropFirst()+triangle.prefix(1)) {
    let outside = clipped(inside,a,b,keepInside:false)
    if hasArea(outside) { result.append(outside) }
    inside = clipped(inside,a,b,keepInside:true)
    if !hasArea(inside) { break }
  }
  return result
}

private func rectangleCorners(_ r:CGRect) -> [CGPoint] {
  [.init(x:r.minX,y:r.minY),.init(x:r.maxX,y:r.minY),.init(x:r.maxX,y:r.maxY),.init(x:r.minX,y:r.maxY)]
}
private func clipConvex(_ polygon:[CGPoint],to clip:[CGPoint]) -> [CGPoint] {
  guard clip.count >= 3 else { return [] }
  let direction=cross(clip[0],clip[1],clip[2]) >= 0 ? 1.0 : -1.0
  var result=polygon
  for (a,b) in zip(clip,clip.dropFirst()+clip.prefix(1)) {
    var next:[CGPoint]=[]
    for (p,q) in zip(result,result.dropFirst()+result.prefix(1)) {
      let x=cross(a,b,p)*direction,y=cross(a,b,q)*direction
      if x >= 0 { next.append(p) }
      if (x > 0 && y < 0) || (x < 0 && y > 0) {
        let t=x/(x-y);next.append(.init(x:p.x+(q.x-p.x)*t,y:p.y+(q.y-p.y)*t))
      }
    }
    result=next
    if result.isEmpty { break }
  }
  return result
}
