import CoreGraphics
import Foundation
import NotebookCore

/// Pins accepted vector content, never a screenshot or a visibility mask.
enum NotebookLassoInkSource: Sendable {
  case page(PageDocument, pending: [PageInkMutation] = [])
  case spatial(SpatialInkJournal, Set<UUID>)
  var revision: String {
    switch self {
    case .page(let p, let pending):
      guard !pending.isEmpty else { return p.drawingStamp.revision }
      return p.drawingStamp.revision + ":" + pending.map(Self.mutationIdentity).joined(separator: ",")
    case .spatial(let j,_): return j.stamp.revision
    }
  }
  var suppressed: Set<UUID> {
    switch self {
    case .page(let p, _): p.graphicPresentation.suppressedInkIDs
    case .spatial(_,let ids): ids
    }
  }
  private static func mutationIdentity(_ mutation: PageInkMutation) -> String {
    switch mutation {
    case .append(let action): "a:\(action.id.uuidString)"
    case .remove(let ids): "r:" + ids.map(\.uuidString).sorted().joined(separator: "+")
    }
  }
  func cacheKey(surface: SurfaceID) -> String {
    var key = "\(surface)|\(revision)"
    if case .spatial(let journal,_) = self {
      // A spatial read window can gain members without changing the owner's
      // maximum stamp. Key its actual immutable membership, not only that stamp.
      key += "|" + journal.actions.map { "\($0.id):\($0.stamp.revision):\($0.stateStamp.revision)" }.joined(separator:",")
    }
    return key
  }
  struct Result: Sendable {
    struct Piece: Sendable {
      let frame: PageRect
      let graphic: NotebookGraphic
    }
    let selected: Piece
    let remainder: Piece?
    var frame: PageRect { selected.frame }
    var graphic: NotebookGraphic { selected.graphic }
    /// Candidate traversal only; excludes exact semantic geometry preparation.
    let candidateSampleCount: Int
    let sourceSampleCount: Int
  }
  func selection(polygon: [SpatialPoint], surface: SurfaceID, origin: WorldPoint?, bounds: CGRect?) throws -> Result? {
    try prepare(surface:surface,origin:origin).selection(polygon:polygon,surface:surface,origin:origin,bounds:bounds)
  }
  func prepare(surface: SurfaceID, origin: WorldPoint?) throws -> Prepared {
    let suppressed = suppressed
    let entries: [Prepared.Entry]
    switch self {
    case .page(let page, let pending):
      var drawing = try page.inkDrawing()
      for mutation in pending {
        switch mutation {
        case .append(let action): drawing = try drawing.appending(action)
        case .remove(let ids): drawing = drawing.removing(ids)
        }
      }
      entries = drawing.actions.filter { $0.isActive }.map {
        .init(id:$0.id,tool:$0.tool,color:$0.color,sources:[.init($0)])
      }
    case .spatial(let journal,_):
      entries = journal.actions.filter { $0.isActive
        && ($0.tool == .eraser || $0.spans.allSatisfy { $0.surface == surface }) }.compactMap { action in
          let spans=action.spans.enumerated().filter { $0.element.surface == surface }.map { index,span in
            InkSampleRelations(sourceID:action.id,span:index,measurements:span.samples,
              header:.init(tool:action.tool,color:action.color))
          }
          return spans.isEmpty ? nil : .init(id:action.id,tool:action.tool,color:action.color,sources:spans)
        }
    }
    return try Prepared(revision:revision,entries:entries,surface:surface,origin:origin,excluding:suppressed)
  }

  /// One bounded snapshot is retained by the tool controller. Its top-level
  /// index addresses whole spans; their canonical range tree rejects hidden
  /// measurements, including on the first gesture after reopening a repeat.
  final class Prepared: Sendable {
    struct Entry: Sendable {
      let id: UUID
      let tool: SpatialInkTool
      let color: SpatialInkColor
      let sources: [InkSampleRelations]
    }
    struct Span: Sendable {
      let entry: Int
      let span: Int
      let bounds: CGRect
    }
    let revision: String
    let sourceSampleCount: Int
    private let index: InkBoundsIndex
    private let entries: [Entry]
    private let spans: [Span]
    var indexedSpanCount: Int { spans.count }
    let preparationSampleCount: Int
    private let entryBounds: [CGRect]
    private let surface: SurfaceID
    private let origin: WorldPoint?
    private let excluded: Set<UUID>
    // Changing presentation claims must not rebuild unchanged measured source.
    func excluding(_ ids: Set<UUID>) -> Prepared {
      ids == excluded ? self : Prepared(reusing:self,excluding:ids)
    }
    private init(reusing source: Prepared, excluding ids: Set<UUID>) {
      revision = source.revision; entries = source.entries; surface = source.surface; origin = source.origin
      sourceSampleCount = source.sourceSampleCount; index = source.index
      spans = source.spans; entryBounds = source.entryBounds; excluded = ids
      preparationSampleCount = source.preparationSampleCount
    }
    init(revision: String, entries: [Entry], surface: SurfaceID, origin: WorldPoint?, excluding: Set<UUID>) throws {
      self.revision = revision; self.entries = entries; self.surface = surface; self.origin = origin; excluded = excluding
      var spans: [Span] = [], boxes: [CGRect] = [], count = 0, prepared = 0
      for (e, entry) in entries.enumerated() {
        try Task.checkCancellation()
        var box = CGRect.null
        for (s,source) in entry.sources.enumerated() {
          count += source.count
          let result=try source.bounds(in:0..<source.count)
          prepared += result.cost.decodedSamples
          let bounds=Self.projected(result.bounds,source:source,origin:origin)
          box = box.union(bounds)
          spans.append(.init(entry:e,span:s,bounds:bounds))
        }
        boxes.append(box)
      }
      self.spans = spans; entryBounds = boxes; sourceSampleCount = count;preparationSampleCount = prepared
      index = .init(spans.map(\.bounds))
    }
    private static func projected(_ box: CGRect,source: InkSampleRelations,origin: WorldPoint?) -> CGRect {
      guard let origin,let sourceOrigin=source.geometry.origin else { return box }
      let delta=origin.delta(to:sourceOrigin)
      return InkSampleRelations.Geometry.offset(box,x:delta.x,y:delta.y)
    }
    private func ranges(_ span: Span, intersecting box: CGRect,examined: inout Int) throws -> [Range<Int>] {
      let source=entries[span.entry].sources[span.span]
      let query=try source.querySegments(maximumSegments:64,intersecting: {
        let b=Self.projected($0,source:source,origin:origin)
        return !b.isNull && b.maxX >= box.minX && b.minX <= box.maxX && b.maxY >= box.minY && b.minY <= box.maxY
      })
      examined += query.cost.decodedSamples
      return query.segments.map { ($0.lowerBound*64)..<min(source.count,$0.upperBound*64+1) }
    }
    private static func point(_ sample: SpatialInkSample, origin: WorldPoint?) -> SpatialPoint {
      origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
    }
    func selection(polygon: [SpatialPoint], surface: SurfaceID, origin queryOrigin: WorldPoint?, bounds: CGRect?) throws -> Result? {
      guard surface == self.surface, polygon.count >= 3 else { return nil }
      let delta = origin.flatMap { o in queryOrigin.map { o.delta(to:$0) } } ?? .zero
      let polygon = polygon.map { SpatialPoint(x:$0.x+delta.x,y:$0.y+delta.y) }
      let region = polygon.reduce(CGRect.null) { $0.union(.init(x:$1.x,y:$1.y,width:0,height:0)) }
      var chosen = Set<Int>(), examined = 0
      for id in index.query(region).indices {
        let f = spans[id], entry = entries[f.entry]
        guard entry.tool == .pen, !excluded.contains(entry.id), !chosen.contains(f.entry) else { continue }
        try Task.checkCancellation()
        for candidate in try ranges(f,intersecting:region,examined:&examined) {
          let samples=entry.sources[f.span].decoded(in:candidate),range=samples.indices
          examined += range.count
          func point(_ i: Int) -> SpatialPoint { Self.point(samples[i],origin:origin) }
          let intersects = range.contains { i in
            let p = point(i), r = max(0.25,samples[i].width/2)*Double(InkStrokeGeometry.maximumCrossSectionScale)
            return NotebookToolGeometry.intersects(.init(x:p.x-r,y:p.y-r,width:max(0.01,2*r),height:max(0.01,2*r)),polygon:polygon)
          } || range.dropLast().contains { NotebookToolGeometry.intersects(from:point($0),to:point($0+1),polygon:polygon) }
          if intersects { chosen.insert(f.entry);break }
        }
      }
      guard let first = chosen.min() else { return nil }
      guard chosen.count <= 1024 else {
        throw CollaborationError("selection_limit","Выделите меньшую часть рукописи: это выделение слишком большое.")
      }
      var box = chosen.reduce(CGRect.null) { $0.union(entryBounds[$1]) }
      if let bounds { box = box.intersection(bounds.offsetBy(dx:delta.x,dy:delta.y)) }
      guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
      let frame = PageRect(x:box.minX,y:box.minY,width:box.width,height:box.height)
      // Select eraser spans through the same range tree, then retain their
      // original body. The graphic's frame clips display, not source measurements.
      var cuts: [Int:Set<Int>] = [:]
      for id in index.query(box).indices {
        let f=spans[id]
        if f.entry > first,entries[f.entry].tool == .eraser,
          try !ranges(f,intersecting:box,examined:&examined).isEmpty {
          cuts[f.entry,default:[]].insert(f.span)
        }
      }
      var layers:[NotebookFreehand.Layer]=[]
      for e in Set(chosen).union(cuts.keys).sorted() {
        try Task.checkCancellation()
        let entry=entries[e]
        for (span,source) in entry.sources.enumerated() where chosen.contains(e) || cuts[e]?.contains(span) == true {
          layers.append(.init(tool:entry.tool,color:entry.color,
            measured:.init(sourceID:source.sourceID,span:source.span,measurements:source.measurements,frame:frame,origin:origin)))
        }
      }
      let ink = NotebookFreehand(layers:layers)
      guard ink.isValid else { throw CollaborationError("selection_limit","Выделите меньшую часть рукописи.") }
      let split = try ink.partitioned(by:polygon.map { CGPoint(x:$0.x,y:$0.y) },in:frame)
      guard let selected = split.inside else { return nil }
      func piece(_ value: NotebookFreehand.Partition) -> Result.Piece {
        .init(frame:.init(x:value.frame.x-delta.x,y:value.frame.y-delta.y,
            width:value.frame.width,height:value.frame.height),
          graphic:.init(shape:.freehand,sourceInkIDs:value.insideSource ? chosen.sorted().map { entries[$0].id } : [],
            freehand:value.ink))
      }
      return .init(selected:piece(selected),remainder:split.outside.map(piece),
        candidateSampleCount:examined,sourceSampleCount:sourceSampleCount)
    }
  }
}

private extension NotebookFreehand {
  struct Partition {
    let frame: PageRect
    let ink: NotebookFreehand
    let insideSource: Bool
  }

  /// Materialize only the intersected source actions into two exact vector
  /// pieces. The selected piece claims the original journal IDs; the outside
  /// piece is ordinary vector geometry, so moving the selection cannot drag
  /// content that was never inside the loop.
  func partitioned(by polygon: [CGPoint], in frame: PageRect) throws
    -> (inside: Partition?, outside: Partition?) {
    guard frame.width > 0, frame.height > 0 else { return (nil,nil) }
    let clip = polygon.map { CGPoint(x:($0.x-frame.x)/frame.width,y:($0.y-frame.y)/frame.height) }
    guard let ears = lassoTriangles(clip) else {
      throw CollaborationError("invalid_lasso","Контур лассо пересёк сам себя. Обведите область одним простым контуром.")
    }
    let geometry = geometry
    var inside = Array(repeating:[Vertex](),count:layers.count)
    var outside = Array(repeating:[Vertex](),count:layers.count)
    let query = geometry.query(.init(x:0,y:0,width:1,height:1),allowRangeCoalescing:false).indices
    for id in query {
      try Task.checkCancellation()
      guard geometry.tool(at:id) == .pen else { continue }
      let layer = geometry.layer(at:id), vertices = geometry.vertices(at:id)
      for start in stride(from:0,to:vertices.count-2,by:3) {
        let source = Array(vertices[start..<start+3])
        let points = source.map { CGPoint(x:$0.x,y:$0.y) }
        guard abs(lassoCross(points[0],points[1],points[2])) > Double.ulpOfOne else { continue }
        for ear in ears {
          let value = lassoClip(points,to:ear)
          lassoAppend(value,source:source,to:&inside[layer])
        }
        var fragments = [points]
        for ear in ears where !fragments.isEmpty {
          fragments = fragments.flatMap { lassoSubtract($0,triangle:ear) }
        }
        for value in fragments { lassoAppend(value,source:source,to:&outside[layer]) }
      }
    }
    func make(_ values:[[Vertex]],insideSource:Bool) throws -> Partition? {
      guard values.reduce(0,{ $0+$1.count }) <= NotebookFreehand.maximumVertices else {
        throw CollaborationError("selection_limit","Выделите меньшую часть рукописи: точный векторный разрез слишком большой.")
      }
      var bounds=CGRect.null
      for (index,vertices) in values.enumerated() where layers[index].tool == .pen {
        for vertex in vertices where vertex.opacity > 0 {
          bounds=bounds.union(.init(x:vertex.x,y:vertex.y,width:0,height:0))
        }
      }
      guard !bounds.isNull,bounds.width > Double.ulpOfOne,bounds.height > Double.ulpOfOne else { return nil }
      let physical=PageRect(x:frame.x+bounds.minX*frame.width,y:frame.y+bounds.minY*frame.height,
        width:bounds.width*frame.width,height:bounds.height*frame.height)
      var result:[Layer]=[]
      for (index,layer) in layers.enumerated() {
        if layer.tool == .pen {
          guard !values[index].isEmpty else { continue }
          let rebased=values[index].map { Vertex(x:($0.x-bounds.minX)/bounds.width,
            y:($0.y-bounds.minY)/bounds.height,opacity:$0.opacity) }
          result.append(.init(tool:.pen,color:layer.color,vertices:rebased))
        } else if let measured=layer.measured {
          result.append(.init(tool:.eraser,color:layer.color,measured:.init(sourceID:measured.sourceID,
            span:measured.span,measurements:measured.measurements,frame:physical,origin:measured.origin)))
        } else if let eraser=layer.eraser {
          let dx=frame.x-physical.x,dy=frame.y-physical.y
          result.append(.init(eraser:.init(size:.init(x:physical.width,y:physical.height),samples:eraser.samples.map {
            .init(point:.init(x:$0.point.x+dx,y:$0.point.y+dy),width:$0.width)
          })))
        } else if !layer.vertices.isEmpty {
          let rebased=layer.vertices.map { Vertex(x:($0.x-bounds.minX)/bounds.width,
            y:($0.y-bounds.minY)/bounds.height,opacity:$0.opacity) }
          result.append(.init(tool:.eraser,color:layer.color,vertices:rebased))
        }
      }
      let ink=NotebookFreehand(layers:result)
      let viewport=[CGPoint(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]
      guard ink.isValid,ink.geometry.intersects(viewport,clippedTo:viewport) else { return nil }
      return .init(frame:physical,ink:ink,insideSource:insideSource)
    }
    guard let selected=try make(inside,insideSource:true) else { return (nil,nil) }
    return (selected,try make(outside,insideSource:false))
  }
}

private func lassoCross(_ a:CGPoint,_ b:CGPoint,_ p:CGPoint)->Double {
  (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
}

private func lassoArea(_ polygon:[CGPoint])->Double {
  zip(polygon,polygon.dropFirst()+polygon.prefix(1)).reduce(0) { $0+$1.0.x*$1.1.y-$1.1.x*$1.0.y }/2
}

private func lassoTriangles(_ input:[CGPoint])->[[CGPoint]]? {
  var polygon:[CGPoint]=[]
  for point in input where point.x.isFinite && point.y.isFinite {
    if let last=polygon.last,hypot(last.x-point.x,last.y-point.y) <= Double.ulpOfOne { continue }
    polygon.append(point)
  }
  if polygon.count > 2,let first=polygon.first,let last=polygon.last,
    hypot(first.x-last.x,first.y-last.y) <= Double.ulpOfOne { polygon.removeLast() }
  var removed=true
  while removed,polygon.count > 3 {
    removed=false
    for index in polygon.indices {
      let a=polygon[(index+polygon.count-1)%polygon.count],b=polygon[index],c=polygon[(index+1)%polygon.count]
      if abs(lassoCross(a,b,c)) <= 1e-14 {
        polygon.remove(at:index);removed=true;break
      }
    }
  }
  guard polygon.count >= 3,abs(lassoArea(polygon)) > Double.ulpOfOne else { return nil }
  let orientation=lassoArea(polygon) > 0 ? 1.0 : -1.0
  var ids=Array(polygon.indices),result:[[CGPoint]]=[]
  func contains(_ p:CGPoint,_ triangle:[CGPoint])->Bool {
    let a=lassoCross(triangle[0],triangle[1],p)*orientation
    let b=lassoCross(triangle[1],triangle[2],p)*orientation
    let c=lassoCross(triangle[2],triangle[0],p)*orientation
    return a > 1e-14 && b > 1e-14 && c > 1e-14
  }
  while ids.count > 3 {
    var ear:Int?
    for position in ids.indices {
      let previous=ids[(position+ids.count-1)%ids.count],current=ids[position],next=ids[(position+1)%ids.count]
      let triangle=[polygon[previous],polygon[current],polygon[next]]
      guard lassoCross(triangle[0],triangle[1],triangle[2])*orientation > 1e-14 else { continue }
      if ids.contains(where:{ $0 != previous && $0 != current && $0 != next && contains(polygon[$0],triangle) }) { continue }
      ear=position;result.append(triangle);break
    }
    guard let ear else { return nil }
    ids.remove(at:ear)
  }
  result.append(ids.map { polygon[$0] })
  return result
}

private func lassoClip(_ polygon:[CGPoint],to clip:[CGPoint])->[CGPoint] {
  guard polygon.count >= 3,clip.count == 3 else { return [] }
  let orientation=lassoCross(clip[0],clip[1],clip[2]) >= 0 ? 1.0 : -1.0
  var result=polygon
  for (a,b) in zip(clip,clip.dropFirst()+clip.prefix(1)) {
    var next:[CGPoint]=[]
    for (p,q) in zip(result,result.dropFirst()+result.prefix(1)) {
      let x=lassoCross(a,b,p)*orientation,y=lassoCross(a,b,q)*orientation
      if x >= 0 { next.append(p) }
      if (x > 0 && y < 0)||(x < 0 && y > 0) {
        let t=x/(x-y);next.append(.init(x:p.x+(q.x-p.x)*t,y:p.y+(q.y-p.y)*t))
      }
    }
    result=next
    if result.isEmpty { break }
  }
  return result
}

private func lassoSubtract(_ polygon:[CGPoint],triangle:[CGPoint])->[[CGPoint]] {
  let orientation=lassoCross(triangle[0],triangle[1],triangle[2])
  guard polygon.count >= 3,orientation != 0 else { return polygon.count >= 3 ? [polygon] : [] }
  var inside=polygon,result:[[CGPoint]]=[]
  func clipped(_ value:[CGPoint],_ a:CGPoint,_ b:CGPoint,inside keep:Bool)->[CGPoint] {
    guard value.count >= 3 else { return [] }
    var output:[CGPoint]=[]
    let sign=(orientation > 0 ? 1.0 : -1.0)*(keep ? 1 : -1)
    for (p,q) in zip(value,value.dropFirst()+value.prefix(1)) {
      let x=lassoCross(a,b,p)*sign,y=lassoCross(a,b,q)*sign
      if x >= 0 { output.append(p) }
      if (x > 0 && y < 0)||(x < 0 && y > 0) {
        let t=x/(x-y);output.append(.init(x:p.x+(q.x-p.x)*t,y:p.y+(q.y-p.y)*t))
      }
    }
    return output
  }
  func hasArea(_ value:[CGPoint])->Bool { value.count >= 3 && abs(lassoArea(value)) > 1e-14 }
  for (a,b) in zip(triangle,triangle.dropFirst()+triangle.prefix(1)) {
    let outside=clipped(inside,a,b,inside:false)
    if hasArea(outside) { result.append(outside) }
    inside=clipped(inside,a,b,inside:true)
    if !hasArea(inside) { break }
  }
  return result
}

private func lassoAppend(_ polygon:[CGPoint],source:[NotebookFreehand.Vertex],to output:inout [NotebookFreehand.Vertex]) {
  guard polygon.count >= 3,abs(lassoArea(polygon)) > 1e-14 else { return }
  let a=CGPoint(x:source[0].x,y:source[0].y),b=CGPoint(x:source[1].x,y:source[1].y),c=CGPoint(x:source[2].x,y:source[2].y)
  let denominator=lassoCross(a,b,c)
  guard denominator != 0 else { return }
  func vertex(_ p:CGPoint)->NotebookFreehand.Vertex {
    let wa=lassoCross(b,c,p)/denominator,wb=lassoCross(c,a,p)/denominator,wc=1-wa-wb
    return .init(x:p.x,y:p.y,opacity:min(1,max(0,wa*source[0].opacity+wb*source[1].opacity+wc*source[2].opacity)))
  }
  for index in 1..<polygon.count-1 {
    output.append(vertex(polygon[0]));output.append(vertex(polygon[index]));output.append(vertex(polygon[index+1]))
  }
}
