import Foundation
import CoreGraphics

/// Authored intent. Bound endpoints never store copies of the node's position.
/// Free points belong to the connector's existing element frame / world origin.
public struct NotebookGraphicConnection: Codable, Equatable, Sendable {
  public enum Routing: String, Codable, CaseIterable, Sendable { case straight, elbow, curved }
  public enum ElbowAxis: String, Codable, Sendable { case horizontal, vertical }
  public enum Terminal: String, Codable, CaseIterable, Sendable { case start, end }
  public enum Arrowhead: String, Codable, CaseIterable, Sendable { case none, arrow, triangle, square, dot, pipe, diamond, inverted, bar }
  public struct Binding: Codable, Equatable, Sendable {
    public var elementID: String
    public var normalizedAnchor: SpatialPoint
    public var isExact: Bool
    public var isPrecise: Bool
    public init(elementID: String, normalizedAnchor: SpatialPoint = .init(x: 0.5, y: 0.5),
      isExact: Bool = false, isPrecise: Bool = true) {
      self.elementID = elementID; self.normalizedAnchor = normalizedAnchor
      self.isExact = isExact; self.isPrecise = isPrecise
    }
    var isValid: Bool {
      !elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && elementID.utf16.count <= 120
        && normalizedAnchor.x.isFinite && normalizedAnchor.y.isFinite
        && (0...1).contains(normalizedAnchor.x) && (0...1).contains(normalizedAnchor.y)
    }
  }
  public struct Endpoint: Codable, Equatable, Sendable {
    public var point: SpatialPoint
    public var binding: Binding?
    public init(point: SpatialPoint, binding: Binding? = nil) { self.point = point; self.binding = binding }
    var isValid: Bool {
      point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
        && (binding?.isValid ?? true)
    }
  }
  public var start: Endpoint
  public var end: Endpoint
  /// Signed sagitta of the circular arc. Zero is an exactly straight line.
  public var bend: Double
  /// Signed position of the held point along the endpoint axis; nil is the midpoint.
  /// Clipping an endpoint can leave the held point outside the visible chord.
  public var bendPosition: Double?
  public var routing: Routing?
  /// Nil follows the endpoint axis; detachment retains the already visible route.
  public var elbowAxis: ElbowAxis?
  public var resolvedRouting: Routing { routing ?? (bend == 0 ? .straight : .curved) }
  public var startArrowhead: Arrowhead
  public var endArrowhead: Arrowhead
  public var labelPosition: Double
  public init(start: Endpoint, end: Endpoint, bend: Double = 0,
    startArrowhead: Arrowhead = .none, endArrowhead: Arrowhead = .arrow, labelPosition: Double = 0.5, bendPosition: Double? = nil, routing: Routing? = nil, elbowAxis: ElbowAxis? = nil) {
    self.start = start; self.end = end; self.bend = bend; self.bendPosition = bendPosition; self.routing = routing; self.elbowAxis = elbowAxis
    self.startArrowhead = startArrowhead; self.endArrowhead = endArrowhead; self.labelPosition = labelPosition
  }
  static let causalFields = ["start", "end", "bend", "startArrowhead", "endArrowhead", "labelPosition", "bendPosition", "routing", "elbowAxis"]
  var isValid: Bool {
    start.isValid && end.isValid && bend.isFinite && abs(bend) <= 1_000_000
      && (bendPosition == nil || (bendPosition!.isFinite && abs(bendPosition!) <= 1_000_000))
      && labelPosition.isFinite && (0...1).contains(labelPosition)
  }
  public var bindings: [Binding] { [start.binding, end.binding].compactMap { $0 } }

  func usesHorizontalElbow(from a:SpatialPoint,to b:SpatialPoint)->Bool {
    elbowAxis.map { $0 == .horizontal } ?? (abs(b.x-a.x) >= abs(b.y-a.y))
  }

  /// Resolve detached terminals in one local body. A retained binding still
  /// names its original axis anchor, not its clipped outline contact. Using
  /// that contact as the anchor would bend even the end that remains bound.
  public func detachingEndpoints(in body:NotebookGraphicLayout,retainingBindingsTo selected:Set<String> = [])->Self {
    var result=self
    let keepStart=start.binding.map { selected.contains($0.elementID) } ?? false
    let keepEnd=end.binding.map { selected.contains($0.elementID) } ?? false
    let a=keepStart ? body.axisStart : body.start,b=keepEnd ? body.axisEnd : body.end
    func point(_ p:SpatialPoint)->SpatialPoint { .init(x:body.frame.x+p.x,y:body.frame.y+p.y) }
    if !keepStart { result.start = .init(point:point(a)) }
    if !keepEnd { result.end = .init(point:point(b)) }
    let dx=b.x-a.x,dy=b.y-a.y,length=max(0.001,hypot(dx,dy))
    result.routing=resolvedRouting
    result.bendPosition=((body.bend.x-a.x)*dx+(body.bend.y-a.y)*dy)/(length*length)
    result.bend=(-dy*(body.bend.x-a.x)+dx*(body.bend.y-a.y))/length
    if resolvedRouting == .elbow {
      result.elbowAxis=usesHorizontalElbow(from:body.axisStart,to:body.axisEnd) ? .horizontal : .vertical
    }
    return result
  }
}

/// A derived render / hit-test value, never encoded into content or its journal.
/// Points stay in the local body. An optional outer projection places the entire
/// body, including stroke and labels, into its physical frame.
public struct NotebookGraphicLayout: Equatable, Sendable {
  public struct Curve: Equatable, Sendable {
    public let start: SpatialPoint
    public let control1: SpatialPoint
    public let control2: SpatialPoint
    public let end: SpatialPoint
    public func point(at t: Double) -> SpatialPoint {
      let s = 1 - t
      return .init(x: s*s*s*start.x + 3*s*s*t*control1.x + 3*s*t*t*control2.x + t*t*t*end.x,
        y: s*s*s*start.y + 3*s*s*t*control1.y + 3*s*t*t*control2.y + t*t*t*end.y)
    }
    func offset(x: Double, y: Double) -> Self {
      func p(_ point: SpatialPoint) -> SpatialPoint { .init(x: point.x + x, y: point.y + y) }
      return .init(start: p(start), control1: p(control1), control2: p(control2), end: p(end))
    }
  }
  public struct Head: Equatable, Sendable {
    public let points: [SpatialPoint]
    public let filled: Bool
    public let closed: Bool
  }
  public struct Projection: Equatable, Sendable {
    public let size: CGSize
    public let transform: CGAffineTransform
  }
  public var origin: WorldPoint = .zero
  public var projection: Projection? = nil
  public let frame: PageRect
  public let curves: [Curve]
  public let heads: [Head]
  public let label: SpatialPoint
  public let start: SpatialPoint
  public let end: SpatialPoint
  public let bend: SpatialPoint
  public let axisStart: SpatialPoint
  public let axisEnd: SpatialPoint

  /// Strip only a disposable outer placement. Local arrays remain shared.
  public var localLayout: Self {
    let size = projection?.size ?? CGSize(width:frame.width,height:frame.height)
    return .init(frame:.init(x:0,y:0,width:size.width,height:size.height),curves:curves,heads:heads,
      label:label,start:start,end:end,bend:bend,axisStart:axisStart,axisEnd:axisEnd)
  }
  /// Capture only the normalized outer map for measured erasures. It maps
  /// local body units into this frame; its world translation stays in frame.
  public var elementTransform: NotebookGraphicTransform? {
    guard let projection else { return nil }
    let t = projection.transform, size = projection.size
    return .init(a:t.a*size.width/frame.width,b:t.b*size.width/frame.height,
      c:t.c*size.height/frame.width,d:t.d*size.height/frame.height,
      tx:t.tx/frame.width,ty:t.ty/frame.height)
  }
  /// Detach this resolved body from its ancestry without changing its visible
  /// placement. The immutable local body and every relation inside it remain
  /// in one basis; a mask may narrow controls without rewriting that body.
  public func flattenedPlacement()->(frame:PageRect,basis:NotebookElementBasis?)? {
    let outer=CGRect(x:0,y:0,width:frame.width,height:frame.height)
    guard !outer.isNull,!outer.isEmpty else { return nil }
    let size=projection?.size ?? outer.size,t=projection?.transform ?? .identity
    guard size.width > 0,size.height > 0 else { return nil }
    let normalized=NotebookGraphicTransform(
      a:t.a*size.width/outer.width,b:t.b*size.width/outer.height,
      c:t.c*size.height/outer.width,d:t.d*size.height/outer.height,
      tx:t.tx/outer.width,ty:t.ty/outer.height)
    return (frame,projection == nil ? nil : .init(size:.init(x:size.width,y:size.height),transform:normalized))
  }
  /// The clipped region owns its control frame, just as an ordinary erased
  /// body keeps its frame. Interior measured absence never changes that basis
  /// when the region becomes a detached fragment.
  public func selectionFrame(mask:NotebookGraphicMask)->PageRect? {
    let outer=CGRect(x:0,y:0,width:frame.width,height:frame.height)
    let visible=mask.projectedRegionPath(in:outer,projection:projection).boundingBoxOfPath.intersection(outer)
    guard !visible.isNull,!visible.isEmpty else { return nil }
    return .init(x:frame.x+visible.minX,y:frame.y+visible.minY,width:visible.width,height:visible.height)
  }
  public func displayedPoint(_ point: SpatialPoint) -> SpatialPoint {
    let p = CGPoint(x:point.x,y:point.y).applying(projection?.transform ?? .identity)
    return .init(x:p.x,y:p.y)
  }
  /// Contact coordinates enter through the same tiled frame used by paint.
  /// Subtract nearby tiles before touching the local floating-point geometry.
  public func framePoint(_ point: SpatialPoint,from origin: WorldPoint) -> SpatialPoint? {
    guard let own=self.origin.projectionOffset(x:frame.x,y:frame.y) else { return nil }
    let delta=own.delta(to:origin),p=SpatialPoint(x:point.x+delta.x,y:point.y+delta.y)
    return p.x.isFinite && p.y.isFinite ? p : nil
  }
  public func localPoint(_ point: SpatialPoint) -> SpatialPoint? {
    guard let projection else { return point }
    let t=projection.transform,det=t.a*t.d-t.b*t.c
    guard det.isFinite,det != 0 else { return nil }
    let p=CGPoint(x:point.x,y:point.y).applying(t.inverted())
    return p.x.isFinite && p.y.isFinite ? .init(x:p.x,y:p.y) : nil
  }
  func placed(in placement: NotebookElementPlacement,relativeToParent: Bool = false) -> Self? {
    let t = relativeToParent ? placement.localTransform : placement.transform
    let origin = relativeToParent ? placement.parentOrigin : placement.origin
    if t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 {
      guard (frame.x+t.tx).isFinite,(frame.y+t.ty).isFinite else { return nil }
      return .init(origin:origin,frame:.init(x:frame.x+t.tx,y:frame.y+t.ty,width:frame.width,height:frame.height),
        curves:curves,heads:heads,label:label,start:start,end:end,bend:bend,axisStart:axisStart,axisEnd:axisEnd)
    }
    let linear = CGAffineTransform(a:t.a,b:t.b,c:t.c,d:t.d,tx:0,ty:0)
    let bounds = CGRect(x:frame.x,y:frame.y,width:frame.width,height:frame.height).applying(linear)
    guard [bounds.minX+t.tx,bounds.minY+t.ty,bounds.width,bounds.height].allSatisfy(\.isFinite),
      bounds.width>0,bounds.height>0 else { return nil }
    let content = CGAffineTransform(translationX:frame.x,y:frame.y).concatenating(linear)
      .concatenating(.init(translationX:-bounds.minX,y:-bounds.minY))
    return .init(origin:origin,projection:.init(size:.init(width:frame.width,height:frame.height),transform:content),
      frame:.init(x:bounds.minX+t.tx,y:bounds.minY+t.ty,width:bounds.width,height:bounds.height),
      curves:curves,heads:heads,label:label,start:start,end:end,bend:bend,axisStart:axisStart,axisEnd:axisEnd)
  }

  public func hitTest(_ point: SpatialPoint, graphic: NotebookGraphic, tolerance: Double) -> Bool {
    if projection != nil || graphic.mask != nil {
      return NotebookElementAppearance(graphic:graphic,layout:self,
        size:.init(width:frame.width,height:frame.height),erasures:[]).contains(point,tolerance:tolerance)
    }
    if graphic.shape != .connector {
      return NotebookGraphicGeometry.hitTest(graphic, width: frame.width, height: frame.height,
        x: point.x, y: point.y, tolerance: tolerance)
    }
    if !graphic.label.isEmpty, abs(point.x - label.x) <= Double(graphic.label.count) * 8 + tolerance,
      abs(point.y - label.y) <= 16 + tolerance { return true }
    let threshold = tolerance + graphic.style.strokeWidth / 2
    func near(_ a: SpatialPoint, _ b: SpatialPoint) -> Bool {
      let dx = b.x - a.x, dy = b.y - a.y, length = dx*dx + dy*dy
      let t = length > 0 ? min(1, max(0, ((point.x-a.x)*dx + (point.y-a.y)*dy) / length)) : 0
      return hypot(point.x-a.x-t*dx, point.y-a.y-t*dy) <= threshold
    }
    func nearCurve(_ curve: Curve, depth: Int = 0) -> Bool {
      let points = [curve.start,curve.control1,curve.control2,curve.end]
      guard point.x >= points.map(\.x).min()!-threshold, point.x <= points.map(\.x).max()!+threshold,
        point.y >= points.map(\.y).min()!-threshold, point.y <= points.map(\.y).max()!+threshold else { return false }
      let dx = curve.end.x-curve.start.x, dy = curve.end.y-curve.start.y, length = max(0.001,hypot(dx,dy))
      func flatness(_ p: SpatialPoint) -> Double { abs(dx*(p.y-curve.start.y)-dy*(p.x-curve.start.x))/length }
      if depth == 16 || max(flatness(curve.control1),flatness(curve.control2)) <= max(0.001,threshold/2) {
        return near(curve.start,curve.end)
      }
      func mid(_ a: SpatialPoint,_ b: SpatialPoint) -> SpatialPoint { .init(x:(a.x+b.x)/2,y:(a.y+b.y)/2) }
      let a = mid(curve.start,curve.control1), b = mid(curve.control1,curve.control2), c = mid(curve.control2,curve.end)
      let d = mid(a,b), e = mid(b,c), f = mid(d,e)
      return nearCurve(.init(start:curve.start,control1:a,control2:d,end:f),depth:depth+1)
        || nearCurve(.init(start:f,control1:e,control2:c,end:curve.end),depth:depth+1)
    }
    if curves.contains(where:{ nearCurve($0) }) { return true }
    for head in heads {
      for (a, b) in zip(head.points, head.points.dropFirst()) where near(a, b) { return true }
      if head.closed, let first = head.points.first, let last = head.points.last, near(last,first) { return true }
      if head.filled {
        var inside = false
        for (a,b) in zip(head.points,head.points.dropFirst()+head.points.prefix(1)) where (a.y > point.y) != (b.y > point.y) {
          if point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
        }
        if inside { return true }
      }
    }
    return false
  }
}

public enum NotebookGraphicResolution: Equatable, Sendable {
  case geometry(NotebookGraphicLayout)
  case hidden
  /// Not membership in a viewport. The reader must resolve these exact IDs.
  case pending(Set<String>)
  public var layout: NotebookGraphicLayout? { if case .geometry(let value) = self { return value }; return nil }
}

/// Constraint projection after the causal register, shared by SQL indexes,
/// native scenes and exact renders. It does not author graph repairs.
public struct NotebookGraphicGraph: Sendable {
  public struct Node: Sendable {
    public let id: String
    public let graphic: NotebookGraphic
    public let frame: PageRect
    public let origin: WorldPoint
    public let placement: NotebookElementPlacement
    public let surface: SurfaceID
    public let shown: Bool
    public init(id: String, graphic: NotebookGraphic, frame: PageRect, origin: WorldPoint = .zero,
      surface: SurfaceID, shown: Bool, placement: NotebookElementPlacement? = nil) {
      let placement = placement ?? .init(id:id,frame:frame,origin:origin)
      self.id = id; self.graphic = graphic; self.frame = frame; self.origin = placement.origin; self.placement = placement
      self.surface = surface; self.shown = shown
    }
  }
  struct ElementSource: Sendable {
    let source:NotebookElementPlacement.Source
    let surface:SurfaceID
    var text:String? = nil
    var textStyle:NativeTextStyle = .standard
  }
  private final class Source: @unchecked Sendable {
    private let lock=NSLock()
    private var visibility:[SurfaceID:NotebookGraphicVisibility]=[:]
    func visibility(_ surface:SurfaceID,graph:NotebookGraphicGraph) -> NotebookGraphicVisibility {
      lock.lock();defer { lock.unlock() }
      if let value=visibility[surface] { return value }
      let value=NotebookGraphicVisibility(surface:surface,graph:graph,nodes:Array(nodes.values),
        groups:groups,elements:elements)
      visibility[surface]=value;return value
    }
    let nodes:[String:Node]
    let groups:[String:ElementSource]
    let elements:[String:ElementSource]
    init(_ nodes:[Node],groups:[String:ElementSource],elements:[String:ElementSource]) {
      self.nodes=Dictionary(nodes.map { (collaborationIdentity($0.id),$0) },uniquingKeysWith:{ first,_ in first })
      self.groups=groups;self.elements=elements
    }
  }
  /// Only the small edit dictionaries belong to a new projection. The retained
  /// node/body dictionaries remain shared; no descendant is visited until read.
  private final class Projection: @unchecked Sendable {
    let sources:[String:NotebookElementPlacement.Source]
    let graphics:[String:NotebookGraphic]
    let additions:[String:Node]
    let rebuildParents:Bool
    private var placementsRead=0
    private let lock=NSLock()
    private var resolvers:[SurfaceID:NotebookElementPlacement.Resolver]=[:]
    init(sources:[String:NotebookElementPlacement.Source],graphics:[String:NotebookGraphic],additions:[String:Node],rebuildParents:Bool = false,resolvers:[SurfaceID:NotebookElementPlacement.Resolver] = [:]) {
      self.sources=sources;self.graphics=graphics;self.additions=additions;self.rebuildParents=rebuildParents;self.resolvers=resolvers
    }
    var placementReadCount:Int { lock.lock();defer { lock.unlock() };return placementsRead }
    func placement(_ id:String,source:NotebookElementPlacement.Source,surface:SurfaceID,base:Source) -> NotebookElementPlacement? {
      lock.lock();defer { lock.unlock() }
      placementsRead += 1
      let resolver:NotebookElementPlacement.Resolver
      if let found=resolvers[surface] { resolver=found }
      else {
        let overrides=sources
        resolver = .init { id in
          let key=collaborationIdentity(id)
          guard let group=base.groups[key],group.surface == surface else { return nil }
          return overrides[key] ?? group.source
        }
        resolvers[surface]=resolver
      }
      return try? resolver.resolve(id,source:source)
    }
  }
  private let base:Source
  private let projection:Projection?
  public struct Nodes: Sendable {
    fileprivate let graph:NotebookGraphicGraph
    public subscript(_ id:String) -> Node? { graph.node(id) }
    public var count:Int { graph.base.nodes.count+(graph.projection?.additions.keys.filter { graph.base.nodes[$0] == nil }.count ?? 0) }
    public var values:AnySequence<Node> {
      AnySequence {
        var original=graph.base.nodes.makeIterator(),added=(graph.projection?.additions ?? [:]).makeIterator()
        return AnyIterator<Node> {
          while let (id,_)=original.next() { if let node=graph.node(id) { return node } }
          while let (id,_)=added.next() { if graph.base.nodes[id] == nil,let node=graph.node(id) { return node } }
          return nil
        }
      }
    }
  }
  public struct Groups: Sendable {
    fileprivate let graph:NotebookGraphicGraph
    public var count:Int { graph.base.groups.count }
    public var isEmpty:Bool { graph.base.groups.isEmpty }
    public subscript(_ id:String) -> NotebookElementPlacement? {
      let key=collaborationIdentity(id)
      guard let group=graph.base.groups[key] else { return nil }
      return graph.placementResolver.placement(key,source:graph.source(id)!,surface:group.surface,base:graph.base)
    }
  }
  // The base graph also needs one shared group resolver for addressed group
  // reads. Its empty projection is retained, not rebuilt by a property getter.
  private let baseResolver:Projection
  private var placementResolver:Projection { projection.flatMap { $0.rebuildParents ? $0 : nil } ?? baseResolver }
  public var nodes:Nodes { .init(graph:self) }
  public var groups:Groups { .init(graph:self) }
  public init(_ nodes:[Node]) { self.init(nodes,groupSources:[:]) }
  init(_ nodes:[Node],groupSources:[String:ElementSource],elementSources:[String:ElementSource] = [:],resolvers:[SurfaceID:NotebookElementPlacement.Resolver] = [:]) {
    base=Source(nodes,groups:groupSources,elements:elementSources);projection=nil
    baseResolver=Projection(sources:[:],graphics:[:],additions:[:],resolvers:resolvers)
  }
  private init(base:Source,projection:Projection?,baseResolver:Projection) { self.base=base;self.projection=projection;self.baseResolver=baseResolver }
  public func source(_ id:String) -> NotebookElementPlacement.Source? {
    let key=collaborationIdentity(id)
    if let override=projection?.sources[key] { return override }
    if let element=base.groups[key] ?? base.elements[key] { return element.source }
    guard let node=projection?.additions[key] ?? base.nodes[key] else { return nil }
    return .init(frame:node.frame,origin:node.placement.parentID == nil ? node.origin : .zero,
      parentID:node.placement.parentID,basis:node.placement.basis)
  }
  public func node(_ id:String) -> Node? {
    let key=collaborationIdentity(id)
    guard let raw=projection?.additions[key] ?? base.nodes[key] else { return nil }
    guard let projection else { return raw }
    let graphic=projection.graphics[key] ?? raw.graphic
    if !projection.rebuildParents {
      let source=projection.sources[key]
      guard let placement=source.map({ try? raw.placement.updating(frame:$0.frame,basis:$0.basis) }) ?? raw.placement else { return nil }
      return .init(id:raw.id,graphic:graphic,frame:source?.frame ?? raw.frame,surface:raw.surface,shown:raw.shown && graphic.showsGeometry,placement:placement)
    }
    guard let source=source(key),let placement=projection.placement(key,source:source,surface:raw.surface,base:base) else { return nil }
    return .init(id:raw.id,graphic:graphic,frame:source.frame,surface:raw.surface,shown:raw.shown && graphic.showsGeometry,placement:placement)
  }
  public func placement(_ id:String) -> NotebookElementPlacement? {
    if let placement=node(id)?.placement ?? groups[id] { return placement }
    let key=collaborationIdentity(id)
    guard let element=base.elements[key],let source=source(key) else { return nil }
    return placementResolver.placement(key,source:source,surface:element.surface,base:base)
  }
  /// Exact native body from the same retained graph cut used by broad phase.
  /// Selection does not need to return to the mutable page or scene model.
  public func elementPresentation(_ id:String) -> NotebookElementPresentation? {
    let key=collaborationIdentity(id)
    guard let element=base.elements[key],let placement=placement(key) else { return nil }
    return .init(placement:placement,text:element.text,style:element.textStyle)
  }
  public func projecting(placements:[String:NotebookElementPlacement.Source] = [:],graphics:[String:NotebookGraphic] = [:],adding:[Node] = []) -> Self {
    guard !placements.isEmpty || !graphics.isEmpty || !adding.isEmpty else { return self }
    var sources=projection?.sources ?? [:],bodies=projection?.graphics ?? [:],additions=projection?.additions ?? [:]
    for (id,source) in placements { sources[collaborationIdentity(id)]=source }
    for (id,graphic) in graphics { bodies[collaborationIdentity(id)]=graphic }
    for node in adding { additions[collaborationIdentity(node.id)]=node }
    let rebuild=sources.contains { key,value in
      guard !value.isGroup,let raw=additions[key] ?? base.nodes[key] else { return true }
      let parent=raw.placement.parentID
      return parent.map(collaborationIdentity) != value.parentID.map(collaborationIdentity)
        || (parent == nil && value.origin != raw.origin)
    }
    return .init(base:base,projection:Projection(sources:sources,graphics:bodies,additions:additions,rebuildParents:rebuild),baseResolver:baseResolver)
  }
  /// A retained contact can prove that copying this value did not copy the
  /// original node dictionary. No address or implementation type is exposed.
  public func sharesSource(with other:Self) -> Bool { base === other.base }
  public var projectedPlacementReadCount:Int { projection?.placementReadCount ?? 0 }
  /// Exact broad-phase candidates in the existing page coordinate system.
  /// Original nodes remain addressable even when no pixel query visits them.
  public func visiblePageGraphics(_ pageID:UUID,in area:CGRect,
    limit:Int = .max) -> NotebookGraphicVisibilityResult {
    let original=Self(base:base,projection:nil,baseResolver:baseResolver)
    let index=base.visibility(.page(pageID),graph:original)
    var changed=Set(projection?.sources.keys.map { $0 } ?? [])
    changed.formUnion(projection?.graphics.keys.map { $0 } ?? [])
    changed.formUnion(projection?.additions.keys.map { $0 } ?? [])
    return index.query(area,graph:self,changed:changed,limit:limit)
  }

  /// Prepare the immutable local-frame tree with the scene rather than on the
  /// first Pencil contact.
  public func prepareVisibility(on surface:SurfaceID) {
    let original=Self(base:base,projection:nil,baseResolver:baseResolver)
    _=base.visibility(surface,graph:original)
  }

  /// Broad phase for a whole whose placement changed after the retained scene
  /// cut. Membership and leaf bodies stay in the shared source.
  public func visibleGroupCandidates(_ groupID:String,on surface:SurfaceID,
    in area:CGRect,limit:Int = .max) -> NotebookGraphicCandidateResult {
    let original=Self(base:base,projection:nil,baseResolver:baseResolver)
    let index=base.visibility(surface,graph:original)
    var changed=Set(projection?.sources.keys.map { $0 } ?? [])
    changed.formUnion(projection?.graphics.keys.map { $0 } ?? [])
    changed.formUnion(projection?.additions.keys.map { $0 } ?? [])
    return index.candidates(in:groupID,area:area,graph:self,changed:changed,limit:limit)
  }

  public func groupIsSelfContained(_ id:String) -> Bool {
    guard base.groups[collaborationIdentity(id)] != nil else { return false }
    for member in nodes.values where member.shown && member.placement.descends(from:id) {
      for binding in member.graphic.connection?.bindings ?? [] {
        guard let target=node(binding.elementID),target.placement.descends(from:id) else { return false }
      }
    }
    return true
  }
  /// Selection bounds include escaped members, not the original basis rectangle.
  /// This resolves only the admitted graph, not a new stored descendant list.
  public func groupBounds(_ id: String) -> CGRect? {
    let key=collaborationIdentity(id)
    guard groups[key] != nil else { return nil }
    var bounds=CGRect.null
    for node in nodes.values where node.shown && node.placement.descends(from:key) {
      guard let layout=resolve(node.id).layout else { continue }
      bounds=bounds.union(.init(x:layout.frame.x,y:layout.frame.y,width:layout.frame.width,height:layout.frame.height))
    }
    for (id,element) in base.elements {
      guard let placement=placement(id),placement.descends(from:key) else { continue }
      bounds=bounds.union(NotebookElementPresentation(placement:placement,text:element.text,style:element.textStyle).bounds)
    }
    return bounds.isNull ? nil : bounds
  }
  /// The whole closed node is a binding target; empty bounding-box corners are
  /// not. Prefer the innermost target and retain it at its edge during a drag.
  public func binding(at point: SpatialPoint, origin: WorldPoint = .zero, surface: SurfaceID,
    excluding id: String? = nil, tolerance: Double, retaining retainedID: String? = nil, erasures: [String: [InkElementErasure]] = [:],
    appearance: (String, NotebookGraphic, NotebookGraphicLayout, CGSize, [InkElementErasure]) -> NotebookElementAppearance? = { _,graphic,layout,size,cuts in
      .init(graphic:graphic,layout:layout,size:size,erasures:cuts)
    }) -> NotebookGraphicConnection.Binding? {
    var candidates: [(id:String,distance:Double,inside:Bool,area:Double,anchor:SpatialPoint)] = []
    let near:AnySequence<Node>
    if surface.kind == .page,let pageID=surface.ownerID,origin == .zero,tolerance.isFinite,tolerance>=0 {
      let radius=tolerance*1.5
      let hits=visiblePageGraphics(pageID,in:.init(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2))
      near=AnySequence(hits.layouts.keys.lazy.compactMap { node($0) })
    } else { near=nodes.values }
    for node in near where node.shown && ![.connector,.freehand].contains(node.graphic.shape)
      && node.surface == surface && collaborationIdentity(node.id) != id.map(collaborationIdentity) {
      guard let layout=resolve(node.id).layout,let p=layout.framePoint(point,from:origin) else { continue }
      let retained=collaborationIdentity(node.id) == retainedID.map(collaborationIdentity)
      let threshold=tolerance*(retained ? 1.5 : 1),size=node.placement.localSize
      guard p.x>=(-threshold),p.y>=(-threshold),p.x<=layout.frame.width+threshold,p.y<=layout.frame.height+threshold else { continue }
      let contact=NotebookGraphicGeometry.outlineContact(node.graphic,size:.init(width:size.x,height:size.y),
        transform:layout.projection?.transform ?? .identity,point:p,tolerance:threshold)
      guard contact.inside || contact.distance<=threshold else { continue }
      if let cuts=erasures[node.id],!cuts.isEmpty {
        guard let prepared=appearance(node.id,node.graphic,layout,.init(width:layout.frame.width,height:layout.frame.height),cuts),
          prepared.contains(p,tolerance:tolerance) else { continue }
      }
      guard let local=layout.localPoint(contact.inside ? p : contact.point) else { continue }
      let t=node.placement.transform,area=abs(t.a*t.d-t.b*t.c)*size.x*size.y
      candidates.append((node.id,contact.distance,contact.inside,area,
        .init(x:min(1,max(0,local.x/size.x)),y:min(1,max(0,local.y/size.y)))))
    }
    candidates.sort {
      if $0.inside != $1.inside { return $0.inside }
      if $0.inside,$0.area != $1.area { return $0.area<$1.area }
      let a=collaborationIdentity($0.id) == retainedID.map(collaborationIdentity)
      let b=collaborationIdentity($1.id) == retainedID.map(collaborationIdentity)
      if a != b { return a }
      if $0.distance != $1.distance { return $0.distance<$1.distance }
      return $0.id<$1.id
    }
    guard let chosen=candidates.first else { return nil }
    return .init(elementID:chosen.id,normalizedAnchor:chosen.anchor,isExact:!chosen.inside,isPrecise:true)
  }
  public enum Space { case surface, parent, body }
  public func resolve(_ id: String,space: Space = .surface) -> NotebookGraphicResolution {
    guard let node = nodes[collaborationIdentity(id)] else { return .pending([id]) }
    guard node.shown else { return .hidden }
    let size = node.placement.localSize, graphic = node.graphic
    guard let connection = graphic.connection else {
      let local = NotebookGraphicLayout(frame:.init(x:0,y:0,width:size.x,height:size.y),curves:[],heads:[],
        label:.init(x:size.x/2,y:size.y/2),start:.zero,end:.zero,bend:.zero,axisStart:.zero,axisEnd:.zero)
      if space == .body { return .geometry(local) }
      guard let placed = local.placed(in:node.placement,relativeToParent:space == .parent) else { return .pending([id]) }
      return .geometry(placed)
    }
    let missing = Set(connection.bindings.filter { nodes[collaborationIdentity($0.elementID)] == nil }.map(\.elementID))
    guard missing.isEmpty else { return .pending(missing) }
    for binding in connection.bindings {
      guard let target = nodes[collaborationIdentity(binding.elementID)], target.shown,
        target.surface == node.surface, target.graphic.shape != .connector else { return .hidden }
    }
    func anchor(_ endpoint: NotebookGraphicConnection.Endpoint) -> SpatialPoint? {
      guard let binding = endpoint.binding, let target = nodes[collaborationIdentity(binding.elementID)] else {
        return endpoint.point
      }
      let a = binding.isPrecise ? binding.normalizedAnchor : .init(x: 0.5, y: 0.5)
      let size = target.placement.localSize
      return node.placement.point(.init(x:size.x*a.x,y:size.y*a.y),from:target.placement)
    }
    guard let a = anchor(connection.start), let b = anchor(connection.end) else { return .hidden }
    let distance = hypot(b.x-a.x, b.y-a.y)
    guard distance > 0.001 else { return .hidden }
    let normal = SpatialPoint(x: -(b.y-a.y)/distance, y: (b.x-a.x)/distance)
    let position = connection.bendPosition ?? 0.5
    let bend = connection.resolvedRouting == .straight ? 0 : connection.bend
    let middle = SpatialPoint(x: a.x+(b.x-a.x)*position + normal.x*bend, y: a.y+(b.y-a.y)*position + normal.y*bend)
    func clipped(_ endpoint: NotebookGraphicConnection.Endpoint, anchor: SpatialPoint, toward: SpatialPoint) -> SpatialPoint {
      guard let binding = endpoint.binding, !binding.isExact,
        let target = nodes[collaborationIdentity(binding.elementID)] else { return anchor }
      guard let localAnchor = target.placement.point(anchor,from:node.placement),
        let localToward = target.placement.point(toward,from:node.placement) else { return anchor }
      let size = target.placement.localSize
      guard let contact = NotebookGraphicGeometry.outlineRayContact(target.graphic,
        size:.init(width:size.x,height:size.y),from:localAnchor,toward:localToward) else { return anchor }
      return node.placement.point(contact,from:target.placement) ?? anchor
    }
    let horizontal = connection.usesHorizontalElbow(from:a,to:b)
    let startToward = connection.resolvedRouting == .elbow ? (horizontal ? SpatialPoint(x:middle.x,y:a.y) : SpatialPoint(x:a.x,y:middle.y)) : middle
    let endToward = connection.resolvedRouting == .elbow ? (horizontal ? SpatialPoint(x:b.x,y:middle.y) : SpatialPoint(x:middle.x,y:b.y)) : middle
    let start = clipped(connection.start, anchor: a, toward: startToward)
    let end = clipped(connection.end, anchor: b, toward: endToward)
    // Resolve in the node's local basis. Translating a connector must not round
    // its local curves differently and invalidate an otherwise identical mask.
    let local = Self.connectionLayout(graphic: graphic, start: start, end: end, middle: middle, axisStart: a, axisEnd: b)
    if space == .body { return .geometry(local) }
    guard let placed = local.placed(in:node.placement,relativeToParent:space == .parent) else { return .pending([id]) }
    return .geometry(placed)
  }

  private static func connectionLayout(graphic: NotebookGraphic, start: SpatialPoint, end: SpatialPoint,
    middle: SpatialPoint, axisStart: SpatialPoint, axisEnd: SpatialPoint) -> NotebookGraphicLayout {
    let connection = graphic.connection!
    let dx = end.x-start.x, dy = end.y-start.y
    let cross = dx*(middle.y-start.y)-dy*(middle.x-start.x)
    var curves: [NotebookGraphicLayout.Curve] = []
    func segment(_ a: SpatialPoint,_ b: SpatialPoint) -> NotebookGraphicLayout.Curve {
      .init(start:a,control1:.init(x:a.x+(b.x-a.x)/3,y:a.y+(b.y-a.y)/3),
        control2:.init(x:a.x+(b.x-a.x)*2/3,y:a.y+(b.y-a.y)*2/3),end:b)
    }
    if connection.resolvedRouting == .elbow {
      // The held waypoint remains on the line and follows both axes. Redundant
      // collinear/zero segments collapse; no second authored points array.
      let horizontal = connection.usesHorizontalElbow(from:axisStart,to:axisEnd)
      let points: [SpatialPoint] = horizontal
        ? [start,.init(x:middle.x,y:start.y),middle,.init(x:end.x,y:middle.y),end]
        : [start,.init(x:start.x,y:middle.y),middle,.init(x:middle.x,y:end.y),end]
      for (a,b) in zip(points,points.dropFirst()) where hypot(b.x-a.x,b.y-a.y) > 0.001 { curves.append(segment(a,b)) }
      if curves.isEmpty { curves = [segment(start,end)] }
    // The circumcircle through start, held bend and end. Split into <=90° cubics.
    } else if connection.resolvedRouting == .curved, abs(cross) > 0.001, hypot(dx,dy) > 0.01 {
      let mx = middle.x-start.x, my = middle.y-start.y
      let q = dx*dx+dy*dy, r = mx*mx+my*my
      let center = SpatialPoint(x: start.x+(q*my-r*dy)/(2*cross), y: start.y+(dx*r-mx*q)/(2*cross))
      let radius = hypot(start.x-center.x,start.y-center.y)
      let first = atan2(start.y-center.y,start.x-center.x), last = atan2(end.y-center.y,end.x-center.x)
      var sweep = last-first
      if cross > 0 { while sweep >= 0 { sweep -= 2 * .pi } }
      else { while sweep <= 0 { sweep += 2 * .pi } }
      let count = max(1, Int(ceil(abs(sweep)/(.pi/2))))
      for i in 0..<count {
        let a = first+sweep*Double(i)/Double(count), b = first+sweep*Double(i+1)/Double(count)
        let k = 4/3 * tan((b-a)/4)
        let p = SpatialPoint(x: center.x+radius*cos(a), y: center.y+radius*sin(a))
        let e = SpatialPoint(x: center.x+radius*cos(b), y: center.y+radius*sin(b))
        curves.append(.init(start: p, control1: .init(x: p.x-k*radius*sin(a), y: p.y+k*radius*cos(a)),
          control2: .init(x: e.x+k*radius*sin(b), y: e.y-k*radius*cos(b)), end: e))
      }
    } else {
      curves = [.init(start: start, control1: .init(x: start.x+dx/3,y: start.y+dy/3),
        control2: .init(x: end.x-dx/3,y: end.y-dy/3), end: end)]
    }
    let t = connection.labelPosition * Double(curves.count), index = min(curves.count-1, Int(t))
    let label = curves[index].point(at: t-Double(index))
    let size = max(10, graphic.style.strokeWidth*4)
    func head(_ kind: NotebookGraphicConnection.Arrowhead, at point: SpatialPoint, toward: SpatialPoint) -> NotebookGraphicLayout.Head? {
      guard kind != .none else { return nil }
      let length = max(0.001,hypot(toward.x-point.x,toward.y-point.y))
      let ux = (toward.x-point.x)/length, uy = (toward.y-point.y)/length
      func p(_ x: Double, _ y: Double) -> SpatialPoint { .init(x: point.x+size*(x*ux-y*uy), y: point.y+size*(x*uy+y*ux)) }
      let points: [SpatialPoint], filled: Bool, closed: Bool
      switch kind {
      case .none: return nil
      case .arrow: points = [p(1,-0.5),point,p(1,0.5)]; filled = false; closed = false
      case .triangle: points = [point,p(1,-0.5),p(1,0.5)]; filled = true; closed = true
      case .inverted: points = [p(0,-0.5),p(1,0),p(0,0.5)]; filled = false; closed = false
      case .pipe: points = [p(0,-0.5),p(0,0.5)]; filled = false; closed = false
      case .bar: points = [p(0,-0.5),p(0.25,-0.5),p(0.25,0.5),p(0,0.5)]; filled = true; closed = true
      case .square: points = [p(0,-0.5),p(1,-0.5),p(1,0.5),p(0,0.5)]; filled = true; closed = true
      case .diamond: points = [point,p(0.5,-0.5),p(1,0),p(0.5,0.5)]; filled = true; closed = true
      case .dot: points = (0..<24).map { let a = Double($0)/24*2 * .pi; return p(0.5+0.5*cos(a),0.5*sin(a)) }; filled = true; closed = true
      }
      return .init(points: points, filled: filled, closed: closed)
    }
    let heads = [head(connection.startArrowhead, at: start, toward: curves[0].control1),
      head(connection.endArrowhead, at: end, toward: curves.last!.control2)].compactMap { $0 }
    let points = curves.flatMap { [$0.start,$0.control1,$0.control2,$0.end] } + heads.flatMap(\.points) + [middle]
    let pad = max(2,graphic.style.strokeWidth/2)
    let labelWidth = graphic.label.isEmpty ? 0 : Double(graphic.label.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max() ?? 0)*8+8
    let labelHeight = graphic.label.isEmpty ? 0 : Double(graphic.label.filter { $0 == "\n" }.count+1)*16+4
    let x = min(points.map(\.x).min()!,label.x-labelWidth)-pad, y = min(points.map(\.y).min()!,label.y-labelHeight)-pad
    let right = max(points.map(\.x).max()!,label.x+labelWidth)+pad, bottom = max(points.map(\.y).max()!,label.y+labelHeight)+pad
    func local(_ p: SpatialPoint) -> SpatialPoint { .init(x: p.x-x,y: p.y-y) }
    return .init(frame: .init(x: x,y: y,width: max(1,right-x),height: max(1,bottom-y)),
      curves: curves.map { $0.offset(x: -x,y: -y) },
      heads: heads.map { .init(points: $0.points.map(local), filled: $0.filled, closed: $0.closed) },
      label: local(label), start: local(start), end: local(end), bend: local(middle), axisStart: local(axisStart), axisEnd: local(axisEnd))
  }
}

extension PageDocument {
  public func graphicGraph() -> NotebookGraphicGraph { elementProjection.graph }
  func makeGraphicGraph(shown:Set<String>) -> NotebookGraphicGraph {
    let groups=Dictionary(elements.filter { $0.kind == .group }.map {
      (collaborationIdentity($0.id),NotebookElementPlacement.Source(frame:$0.frame,parentID:$0.parentID,basis:$0.basis,isGroup:true))
    },uniquingKeysWith:{ first,_ in first })
    let resolver=NotebookElementPlacement.Resolver { groups[collaborationIdentity($0)] }
    let nodes:[NotebookGraphicGraph.Node]=elements.compactMap { element in
      guard let graphic=element.graphic else { return nil }
      let source=NotebookElementPlacement.Source(frame:element.frame,parentID:element.parentID,basis:element.basis)
      guard let placement=try? resolver.resolve(element.id,source:source) else { return nil }
      return .init(id:element.id,graphic:graphic,frame:source.frame,surface:.page(id),shown:shown.contains(element.id),placement:placement)
    }
    return .init(nodes,groupSources:groups.mapValues { .init(source:$0,surface:.page(id)) },elementSources:Dictionary(elements.filter { $0.kind != .group && $0.graphic == nil }.map {
      (collaborationIdentity($0.id),.init(source:.init(frame:$0.frame,parentID:$0.parentID,basis:$0.basis),surface:.page(id),text:$0.kind == .nativeText ? $0.source : nil,textStyle:$0.textStyle ?? .standard))
    },uniquingKeysWith:{ first,_ in first }),resolvers:[.page(id):resolver])
  }
}
extension BoardDocument {
  /// A retained native host needs only its addressed body and ancestors. Do
  /// not reconstruct the complete board graph for the next local contact.
  public func graphicNodes(ids:Set<String>) -> [NotebookGraphicGraph.Node] {
    guard !ids.isEmpty else { return [] }
    let requested=interactionElements(ids:ids)
    let claimed=requested.contains { $0.graphic?.sourceInkIDs.isEmpty == false }
      ? graphicPresentation.geometryIDs : nil
    var resolvers:[SurfaceID:NotebookElementPlacement.Resolver]=[:]
    return requested.compactMap { element in
      let resolver:NotebookElementPlacement.Resolver
      if let existing=resolvers[element.surface] { resolver=existing }
      else {
        resolver = .init { id in
          guard let group=self.element(id:id),group.kind == .group,group.surface == element.surface else { return nil }
          return .init(frame:.init(x:group.frame.x,y:group.frame.y,width:group.frame.width,height:group.frame.height),
            origin:group.worldOrigin ?? .zero,parentID:group.parentID,basis:group.basis,isGroup:true)
        }
        resolvers[element.surface]=resolver
      }
      return graphicNode(element,resolver:resolver,
        shown:claimed?.contains(element.id) ?? (element.graphic?.showsGeometry == true))
    }
  }

  private func graphicNode(_ element:SpatialElement,resolver:NotebookElementPlacement.Resolver,
    shown:Bool) -> NotebookGraphicGraph.Node? {
    guard let graphic=element.graphic else { return nil }
    let source=NotebookElementPlacement.Source(frame:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height),
      origin:element.worldOrigin ?? .zero,parentID:element.parentID,basis:element.basis)
    guard let placement=try? resolver.resolve(element.id,source:source) else { return nil }
    return .init(id:element.id,graphic:graphic,frame:source.frame,surface:element.surface,shown:shown,placement:placement)
  }

  public func graphicGraph() -> NotebookGraphicGraph {
    let shown=graphicPresentation.geometryIDs
    let groups=Dictionary(elements.filter { $0.kind == .group }.map { (collaborationIdentity($0.id),$0) },uniquingKeysWith:{ first,_ in first })
    var resolvers:[SurfaceID:NotebookElementPlacement.Resolver]=[:]
    func resolver(_ surface: SurfaceID) -> NotebookElementPlacement.Resolver {
      if let value=resolvers[surface] { return value }
      let value=NotebookElementPlacement.Resolver { id in
        guard let group=groups[collaborationIdentity(id)],group.surface == surface else { return nil }
        return .init(frame:.init(x:group.frame.x,y:group.frame.y,width:group.frame.width,height:group.frame.height),
          origin:group.worldOrigin ?? .zero,parentID:group.parentID,basis:group.basis,isGroup:true)
      }
      resolvers[surface]=value;return value
    }
    let nodes:[NotebookGraphicGraph.Node]=elements.compactMap { element in
      graphicNode(element,resolver:resolver(element.surface),shown:shown.contains(element.id))
    }
    return .init(nodes,groupSources:groups.mapValues { group in
      .init(source:.init(frame:.init(x:group.frame.x,y:group.frame.y,width:group.frame.width,height:group.frame.height),
        origin:group.worldOrigin ?? .zero,parentID:group.parentID,basis:group.basis,isGroup:true),surface:group.surface)
    },elementSources:Dictionary(elements.filter { $0.kind != .group && $0.graphic == nil }.map {
      (collaborationIdentity($0.id),.init(source:.init(frame:.init(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height),
        origin:$0.worldOrigin ?? .zero,parentID:$0.parentID,basis:$0.basis),surface:$0.surface,text:$0.kind == .nativeText ? $0.source : nil,textStyle:$0.textStyle))
    },uniquingKeysWith:{ first,_ in first }),resolvers:resolvers)
  }
}
