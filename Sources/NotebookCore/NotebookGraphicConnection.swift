import Foundation

/// Authored intent. Bound endpoints never store copies of the node's position.
/// Free points belong to the connector's existing element frame / world origin.
public struct NotebookGraphicConnection: Codable, Equatable, Sendable {
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
  public var startArrowhead: Arrowhead
  public var endArrowhead: Arrowhead
  public var labelPosition: Double
  public init(start: Endpoint, end: Endpoint, bend: Double = 0,
    startArrowhead: Arrowhead = .none, endArrowhead: Arrowhead = .arrow, labelPosition: Double = 0.5) {
    self.start = start; self.end = end; self.bend = bend
    self.startArrowhead = startArrowhead; self.endArrowhead = endArrowhead; self.labelPosition = labelPosition
  }
  static let causalFields = ["start", "end", "bend", "startArrowhead", "endArrowhead", "labelPosition"]
  var isValid: Bool {
    start.isValid && end.isValid && bend.isFinite && abs(bend) <= 1_000_000
      && labelPosition.isFinite && (0...1).contains(labelPosition)
  }
  public var bindings: [Binding] { [start.binding, end.binding].compactMap { $0 } }
}

/// A derived render / hit-test value, never encoded into content or its journal.
/// Every point is local to `frame`; frame remains in the physical owner's units.
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
  public let frame: PageRect
  public let curves: [Curve]
  public let heads: [Head]
  public let label: SpatialPoint
  public let start: SpatialPoint
  public let end: SpatialPoint
  public let bend: SpatialPoint

  public func hitTest(_ point: SpatialPoint, graphic: NotebookGraphic, tolerance: Double) -> Bool {
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
    public let surface: SurfaceID
    public let shown: Bool
    public init(id: String, graphic: NotebookGraphic, frame: PageRect, origin: WorldPoint = .zero,
      surface: SurfaceID, shown: Bool) {
      self.id = id; self.graphic = graphic; self.frame = frame; self.origin = origin
      self.surface = surface; self.shown = shown
    }
  }
  public let nodes: [String: Node]
  public init(_ nodes: [Node]) {
    self.nodes = Dictionary(nodes.map { (collaborationIdentity($0.id), $0) }, uniquingKeysWith: { first, _ in first })
  }
  /// Contours do not magnetize their empty interior. Prefer the nearest small
  /// node; an ambiguous overlapping pair remains a free endpoint.
  public func binding(at point: SpatialPoint, origin: WorldPoint = .zero, surface: SurfaceID,
    excluding id: String? = nil, tolerance: Double) -> NotebookGraphicConnection.Binding? {
    var candidates: [(Node, Double)] = []
    for node in nodes.values where node.shown && node.graphic.shape != .connector && node.surface == surface && node.id != id {
      let delta = origin.delta(to:node.origin), frame = node.frame
      let x = point.x-delta.x-frame.x-frame.width/2, y = point.y-delta.y-frame.y-frame.height/2
      let edge = NotebookGraphicGeometry.outlineDistance(node.graphic,width:frame.width,height:frame.height,
        x:x+frame.width/2,y:y+frame.height/2), center = hypot(x,y)
      guard edge <= tolerance || center <= tolerance else { continue }
      candidates.append((node,min(edge,center)))
    }
    if let nearest = candidates.map(\.1).min() { candidates.removeAll { $0.1 > nearest+tolerance/4 } }
    candidates.sort {
      let a = $0.0.frame.width*$0.0.frame.height, b = $1.0.frame.width*$1.0.frame.height
      return a == b ? $0.0.id < $1.0.id : a < b
    }
    guard let first = candidates.first else { return nil }
    if candidates.count > 1, abs(candidates[1].1-first.1) < tolerance/4,
      candidates[1].0.frame.width*candidates[1].0.frame.height < first.0.frame.width*first.0.frame.height*1.25 { return nil }
    return .init(elementID:first.0.id,normalizedAnchor:.init(x:0.5,y:0.5),isExact:false,isPrecise:false)
  }
  public func resolve(_ id: String) -> NotebookGraphicResolution {
    guard let node = nodes[collaborationIdentity(id)] else { return .pending([id]) }
    guard node.shown else { return .hidden }
    let frame = node.frame, graphic = node.graphic
    guard let connection = graphic.connection else {
      return .geometry(.init(frame: frame, curves: [], heads: [], label: .init(x: frame.width/2, y: frame.height/2),
        start: .zero, end: .zero, bend: .zero))
    }
    let missing = Set(connection.bindings.filter { nodes[collaborationIdentity($0.elementID)] == nil }.map(\.elementID))
    guard missing.isEmpty else { return .pending(missing) }
    for binding in connection.bindings {
      guard let target = nodes[collaborationIdentity(binding.elementID)], target.shown,
        target.surface == node.surface, target.graphic.shape != .connector else { return .hidden }
    }
    func anchor(_ endpoint: NotebookGraphicConnection.Endpoint) -> SpatialPoint {
      guard let binding = endpoint.binding, let target = nodes[collaborationIdentity(binding.elementID)] else {
        return .init(x: frame.x + endpoint.point.x, y: frame.y + endpoint.point.y)
      }
      let offset = node.origin.delta(to: target.origin)
      let a = binding.isPrecise ? binding.normalizedAnchor : .init(x: 0.5, y: 0.5)
      return .init(x: offset.x + target.frame.x + target.frame.width*a.x,
        y: offset.y + target.frame.y + target.frame.height*a.y)
    }
    let a = anchor(connection.start), b = anchor(connection.end)
    let distance = hypot(b.x-a.x, b.y-a.y)
    guard distance > 0.001 else { return .hidden }
    let normal = SpatialPoint(x: -(b.y-a.y)/distance, y: (b.x-a.x)/distance)
    let middle = SpatialPoint(x: (a.x+b.x)/2 + normal.x*connection.bend, y: (a.y+b.y)/2 + normal.y*connection.bend)
    func clipped(_ endpoint: NotebookGraphicConnection.Endpoint, anchor: SpatialPoint, toward: SpatialPoint) -> SpatialPoint {
      guard let binding = endpoint.binding, !binding.isExact,
        let target = nodes[collaborationIdentity(binding.elementID)] else { return anchor }
      let delta = node.origin.delta(to: target.origin)
      let center = SpatialPoint(x: delta.x+target.frame.x+target.frame.width/2, y: delta.y+target.frame.y+target.frame.height/2)
      let rx = target.frame.width/2, ry = target.frame.height/2
      let px = (anchor.x-center.x)/rx, py = (anchor.y-center.y)/ry
      let dx = (toward.x-anchor.x)/rx, dy = (toward.y-anchor.y)/ry
      if target.graphic.shape == .plus { return anchor }
      if let vertices = NotebookGraphicGeometry.polygon(target.graphic) {
        let intersections = zip(vertices,vertices.dropFirst()+vertices.prefix(1)).compactMap { a,b -> Double? in
          let ax = a.x*2-1, ay = a.y*2-1, ex = (b.x-a.x)*2, ey = (b.y-a.y)*2
          let cross = dx*ey-dy*ex
          guard abs(cross) > 0.000001 else { return nil }
          let t = ((ax-px)*ey-(ay-py)*ex)/cross
          let u = ((ax-px)*dy-(ay-py)*dx)/cross
          return t >= 0 && (-0.000001...1.000001).contains(u) ? t : nil
        }
        guard let t = intersections.min() else { return anchor }
        return .init(x:anchor.x+(toward.x-anchor.x)*t,y:anchor.y+(toward.y-anchor.y)*t)
      }
      let aa = dx*dx+dy*dy, bb = 2*(px*dx+py*dy), cc = px*px+py*py-1
      let discriminant = bb*bb-4*aa*cc
      guard aa > 0, discriminant >= 0 else { return anchor }
      let t = max(0, (-bb + sqrt(discriminant))/(2*aa))
      return .init(x: anchor.x+(toward.x-anchor.x)*t, y: anchor.y+(toward.y-anchor.y)*t)
    }
    let start = clipped(connection.start, anchor: a, toward: middle)
    let end = clipped(connection.end, anchor: b, toward: middle)
    return .geometry(Self.connectionLayout(graphic: graphic, start: start, end: end, middle: middle))
  }

  private static func connectionLayout(graphic: NotebookGraphic, start: SpatialPoint, end: SpatialPoint,
    middle: SpatialPoint) -> NotebookGraphicLayout {
    let connection = graphic.connection!
    let dx = end.x-start.x, dy = end.y-start.y
    let cross = dx*(middle.y-start.y)-dy*(middle.x-start.x)
    var curves: [NotebookGraphicLayout.Curve] = []
    // The circumcircle through start, held bend and end. Split into <=90° cubics.
    if abs(cross) > 0.001, hypot(dx,dy) > 0.01 {
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
      label: local(label), start: local(start), end: local(end), bend: local(middle))
  }
}

extension PageDocument {
  public func graphicGraph(frames: [String: PageRect] = [:], connections: [String: NotebookGraphicConnection] = [:]) -> NotebookGraphicGraph {
    let shown = graphicPresentation.geometryIDs
    return .init(elements.compactMap { element in
      guard var graphic = element.graphic else { return nil }
      if let connection = connections[element.id] { graphic.connection = connection }
      return .init(id: element.id, graphic: graphic, frame: frames[element.id] ?? element.frame,
        surface: .page(id), shown: shown.contains(element.id))
    })
  }
}
extension BoardDocument {
  public func graphicGraph(frames: [String: PageRect] = [:], connections: [String: NotebookGraphicConnection] = [:]) -> NotebookGraphicGraph {
    let shown = graphicPresentation.geometryIDs
    return .init(elements.compactMap { element in
      guard var graphic = element.graphic else { return nil }
      if let connection = connections[element.id] { graphic.connection = connection }
      return .init(id: element.id, graphic: graphic,
        frame: frames[element.id] ?? .init(x: element.frame.x,y: element.frame.y,width: element.frame.width,height: element.frame.height),
        origin: element.worldOrigin ?? .zero, surface: element.surface, shown: shown.contains(element.id))
    })
  }
}
