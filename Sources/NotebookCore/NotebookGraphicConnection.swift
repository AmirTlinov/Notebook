import Foundation
import CoreGraphics

/// Authored intent. Bound endpoints never store copies of the node's position.
/// Free points belong to the connector's existing element frame / world origin.
public struct NotebookGraphicConnection: Codable, Equatable, Sendable {
  public enum Routing: String, Codable, CaseIterable, Sendable { case straight, elbow, curved }
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
  /// Position of the held curve point along the endpoint axis; nil is the midpoint.
  public var bendPosition: Double?
  public var routing: Routing?
  public var resolvedRouting: Routing { routing ?? (bend == 0 ? .straight : .curved) }
  public var startArrowhead: Arrowhead
  public var endArrowhead: Arrowhead
  public var labelPosition: Double
  public init(start: Endpoint, end: Endpoint, bend: Double = 0,
    startArrowhead: Arrowhead = .none, endArrowhead: Arrowhead = .arrow, labelPosition: Double = 0.5, bendPosition: Double? = nil, routing: Routing? = nil) {
    self.start = start; self.end = end; self.bend = bend; self.bendPosition = bendPosition; self.routing = routing
    self.startArrowhead = startArrowhead; self.endArrowhead = endArrowhead; self.labelPosition = labelPosition
  }
  static let causalFields = ["start", "end", "bend", "startArrowhead", "endArrowhead", "labelPosition", "bendPosition", "routing"]
  var isValid: Bool {
    start.isValid && end.isValid && bend.isFinite && abs(bend) <= 1_000_000
      && (bendPosition == nil || (bendPosition!.isFinite && (0...1).contains(bendPosition!)))
      && labelPosition.isFinite && (0...1).contains(labelPosition)
  }
  public var bindings: [Binding] { [start.binding, end.binding].compactMap { $0 } }
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
    if projection != nil {
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
  public let nodes: [String: Node]
  public init(_ nodes: [Node]) {
    self.nodes = Dictionary(nodes.map { (collaborationIdentity($0.id), $0) }, uniquingKeysWith: { first, _ in first })
  }
  /// The whole closed node is a binding target; empty bounding-box corners are
  /// not. Prefer the innermost target and retain it at its edge during a drag.
  public func binding(at point: SpatialPoint, origin: WorldPoint = .zero, surface: SurfaceID,
    excluding id: String? = nil, tolerance: Double, retaining retainedID: String? = nil, erasures: [String: [InkElementErasure]] = [:],
    appearance: (String, NotebookGraphic, NotebookGraphicLayout, CGSize, [InkElementErasure]) -> NotebookElementAppearance? = { _,graphic,layout,size,cuts in
      .init(graphic:graphic,layout:layout,size:size,erasures:cuts)
    }) -> NotebookGraphicConnection.Binding? {
    var candidates: [(id:String,distance:Double,inside:Bool,area:Double,anchor:SpatialPoint)] = []
    for node in nodes.values where node.shown && ![.connector,.freehand].contains(node.graphic.shape)
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
  public func node(_ id: String) -> Node? { nodes[collaborationIdentity(id)] }
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
    let horizontal = abs(b.x-a.x) >= abs(b.y-a.y)
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
      let horizontal = abs(axisEnd.x-axisStart.x) >= abs(axisEnd.y-axisStart.y)
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
  public func graphicGraph(frames: [String: PageRect] = [:], connections: [String: NotebookGraphicConnection] = [:]) -> NotebookGraphicGraph {
    let shown = graphicPresentation.geometryIDs
    let sources = Dictionary(elements.filter { $0.kind == .group }.map { (collaborationIdentity($0.id),$0) },uniquingKeysWith:{ first,_ in first })
    let resolver = NotebookElementPlacement.Resolver { id in
      sources[collaborationIdentity(id)].map {
        .init(frame:frames[$0.id] ?? $0.frame,origin:.zero,parentID:$0.parentID,basis:$0.basis,isGroup:$0.kind == .group)
      }
    }
    return .init(elements.compactMap { element in
      guard var graphic = element.graphic,let placement = try? resolver.resolve(element.id,
        source:.init(frame:frames[element.id] ?? element.frame,origin:.zero,parentID:element.parentID,basis:element.basis,isGroup:false)) else { return nil }
      if let connection = connections[element.id] { graphic.connection = connection }
      return .init(id:element.id,graphic:graphic,frame:frames[element.id] ?? element.frame,
        surface:.page(id),shown:shown.contains(element.id),placement:placement)
    })
  }
}
extension BoardDocument {
  public func graphicGraph(frames: [String: PageRect] = [:], connections: [String: NotebookGraphicConnection] = [:]) -> NotebookGraphicGraph {
    let shown = graphicPresentation.geometryIDs
    let sources = Dictionary(elements.filter { $0.kind == .group }.map { (collaborationIdentity($0.id),$0) },uniquingKeysWith:{ first,_ in first })
    // Separate surfaces cannot share a parent, even in a partially delivered cut.
    var resolvers: [SurfaceID:NotebookElementPlacement.Resolver] = [:]
    return .init(elements.compactMap { element in
      guard var graphic = element.graphic else { return nil }
      let surface = element.surface
      let resolver = resolvers[surface] ?? NotebookElementPlacement.Resolver { id in
        guard let value = sources[collaborationIdentity(id)],value.surface == surface else { return nil }
        return .init(frame:frames[value.id] ?? .init(x:value.frame.x,y:value.frame.y,width:value.frame.width,height:value.frame.height),
          origin:value.worldOrigin ?? .zero,parentID:value.parentID,basis:value.basis,isGroup:value.kind == .group)
      }
      resolvers[element.surface] = resolver
      let frame = frames[element.id] ?? PageRect(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height)
      guard let placement = try? resolver.resolve(element.id,
        source:.init(frame:frame,origin:element.worldOrigin ?? .zero,parentID:element.parentID,basis:element.basis,isGroup:false)) else { return nil }
      if let connection = connections[element.id] { graphic.connection = connection }
      return .init(id:element.id,graphic:graphic,
        frame:frame,surface:element.surface,shown:shown.contains(element.id),placement:placement)
    })
  }
}
