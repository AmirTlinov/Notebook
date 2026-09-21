import Foundation

/// The only fast repeat admitted here advances paper x/y and seconds by an
/// exact translation. It is not an evaluator for arbitrary dependent programs.
public struct InkRepeatStep: Hashable, Sendable {
  public let x: InkDyadic, y: InkDyadic, time: InkDyadic
  public init(x: InkDyadic, y: InkDyadic, time: InkDyadic) { self.x=x;self.y=y;self.time=time }
  public static let zero = Self(x:.zero,y:.zero,time:.zero)
  public func multiplied(by count: Int) -> Self? {
    guard let x=x.multiplied(by:count), let y=y.multiplied(by:count),
      let time=time.multiplied(by:count) else { return nil }
    return .init(x:x,y:y,time:time)
  }
  public func adding(_ other: Self) -> Self? {
    guard let x=x.adding(other.x), let y=y.adding(other.y), let time=time.adding(other.time) else { return nil }
    return .init(x:x,y:y,time:time)
  }
  public var negated: Self { .init(x:x.negated,y:y.negated,time:time.negated) }
  public func apply(_ value: Double, _ offset: InkDyadic) -> Double {
    // In particular preserve a literal negative zero for the identity relation.
    offset == .zero ? value : InkDyadic(value)!.adding(offset)!.value
  }
  public func applyingIfExact(_ sample: SpatialInkSample) -> SpatialInkSample? {
    if self == .zero { return sample }
    guard sample.worldPoint == nil || (x == .zero && y == .zero) else { return nil }
    func shifted(_ value: Double,_ offset: InkDyadic) -> Double? {
      if offset == .zero { return value }
      return InkDyadic(value)?.adding(offset)?.value
    }
    guard let x=shifted(sample.point.x,x),let y=shifted(sample.point.y,y),
      let time=shifted(sample.timeOffset,time),time >= 0 else { return nil }
    return .init(point:.init(x:x,y:y),worldPoint:sample.worldPoint,timeOffset:time,width:sample.width,opacity:sample.opacity,
      force:sample.force,azimuth:sample.azimuth,altitude:sample.altitude)
  }
  public func apply(_ sample: SpatialInkSample) -> SpatialInkSample {
    .init(point:.init(x:apply(sample.point.x,x),y:apply(sample.point.y,y)),
      worldPoint:sample.worldPoint,timeOffset:apply(sample.timeOffset,time),width:sample.width,opacity:sample.opacity,
      force:sample.force,azimuth:sample.azimuth,altitude:sample.altitude)
  }
}

extension InkSampleRelations {
  /// A conservative common binary lattice. Its bounded integer endpoints prove
  /// EVERY intermediate translation, not just the last reconstructed sample.
  struct Lattice: Sendable {
    let low: Int64, high: Int64, exponent: Int
    init?(_ value: Double) {
      guard let d=InkDyadic(value) else { return nil }
      low=d.coefficient;high=d.coefficient;exponent=d.exponent
    }
    private init(low: Int64, high: Int64, exponent: Int) {
      self.low=low;self.high=high;self.exponent=exponent
    }
    func aligned(to exponent: Int) -> (Int64,Int64)? {
      let shift=self.exponent-exponent
      if low == 0 && high == 0 { return (0,0) }
      guard (0..<63).contains(shift) else { return nil }
      let (a,ao)=low.multipliedReportingOverflow(by:Int64(1)<<shift)
      let (b,bo)=high.multipliedReportingOverflow(by:Int64(1)<<shift)
      return ao || bo ? nil : (a,b)
    }
    func union(_ other: Self) -> Self? {
      let e=min(exponent,other.exponent)
      guard let a=aligned(to:e),let b=other.aligned(to:e) else { return nil }
      return Self.checked(min(a.0,b.0),max(a.1,b.1),e)
    }
    func shifted(from first: InkDyadic, to last: InkDyadic, quantum: Int? = nil) -> Self? {
      if first == .zero && last == .zero { return self }
      let e=min(exponent,quantum ?? min(first.exponent,last.exponent))
      guard let a=aligned(to:e),let b=Self(first.value)?.aligned(to:e),let c=Self(last.value)?.aligned(to:e) else { return nil }
      guard b.0.magnitude <= (1<<53)-1,c.0.magnitude <= (1<<53)-1 else { return nil }
      let (low,lo)=a.0.addingReportingOverflow(min(b.0,c.0))
      let (high,hi)=a.1.addingReportingOverflow(max(b.1,c.1))
      guard !lo,!hi else { return nil }
      return Self.checked(low,high,e)
    }
    private static func checked(_ low: Int64,_ high: Int64,_ exponent: Int) -> Self? {
      let limit: UInt64=(1<<53)-1
      guard low.magnitude <= limit,high.magnitude <= limit,
        InkDyadic(coefficient:low,exponent:exponent) != nil,
        InkDyadic(coefficient:high,exponent:exponent) != nil else { return nil }
      return .init(low:low,high:high,exponent:exponent)
    }
  }

  /// Display rejection and neighbour independence belong to the same source
  /// tree. A world box stays relative to an exact tiled origin, never a large
  /// absolute Double. Mixed coordinate kinds deliberately have unknown bounds.
  public struct Geometry: Sendable {
    enum Coordinate: Equatable, Sendable {
      case paper(SpatialPoint), world(WorldPoint)
      init(_ sample: SpatialInkSample) {
        if let world=sample.worldPoint { self = .world(world) } else { self = .paper(sample.point) }
      }
      var origin: WorldPoint? { if case .world(let p)=self { return p };return nil }
      func relative(to origin: WorldPoint?) -> SpatialPoint? {
        switch (self,origin) {
        case (.paper(let p),nil): return p
        case (.world(let p),.some(let o)): return o.delta(to:p)
        default: return nil
        }
      }
      func distance(to other: Self) -> Double {
        let d: SpatialPoint
        switch (self,other) {
        case (.paper(let a),.paper(let b)): d = .init(x:b.x-a.x,y:b.y-a.y)
        case (.world(let a),.world(let b)): d=a.delta(to:b)
        default: return 0
        }
        return max(0,hypot(d.x,d.y).nextDown)
      }
      func shifted(_ step: InkRepeatStep) -> Self {
        switch self {
        case .paper(let p): return .paper(.init(x:step.apply(p.x,step.x),y:step.apply(p.y,step.y)))
        case .world: precondition(step.x == .zero && step.y == .zero);return self
        }
      }
    }
    /// A proof about the painted strip, not equality of measured events.
    /// The direction mask admits a singleton in either axis; a join must prove
    /// a strictly monotone connection and identical width/opacity. Folds and
    /// coincident seams cannot silently lose their accumulated paint.
    private struct AxisStrip: Sendable {
      let directions: UInt8
      let width: Double,opacity: Double
      init(directions: UInt8,width: Double,opacity: Double) {
        self.directions=directions;self.width=width;self.opacity=opacity
      }
      static func directions(from a: Coordinate?,to b: Coordinate?) -> UInt8 {
        switch (a,b) {
        case (.paper(let a),.paper(let b)):
          if a.y == b.y { return a.x < b.x ? 1 : a.x > b.x ? 2 : 0 }
          if a.x == b.x { return a.y < b.y ? 4 : a.y > b.y ? 8 : 0 }
        case (.world(let a),.world(let b)):
          // Compare normalized tile addresses, never a flattened world Double.
          // Nearby local detail remains exact even at the admitted world edge.
          let x=(a.tileX,a.localX),y=(a.tileY,a.localY)
          let nextX=(b.tileX,b.localX),nextY=(b.tileY,b.localY)
          if y == nextY { return x < nextX ? 1 : x > nextX ? 2 : 0 }
          if x == nextX { return y < nextY ? 4 : y > nextY ? 8 : 0 }
        default: break
        }
        return 0
      }
      init?(_ block: Block) {
        guard block.count > 0 else { return nil }
        switch block {
        case .fields(let f,_):
          guard case .constant(let w)=f[3],case .constant(let a)=f[4] else { return nil }
          var direction: UInt8
          switch (f[0],f[1]) {
          case (.progression(_,let step),.constant): direction=step.value > 0 ? 1 : step.value < 0 ? 2 : 0
          case (.constant,.progression(_,let step)): direction=step.value > 0 ? 4 : step.value < 0 ? 8 : 0
          default:
            // A literal coordinate (including a preserved negative zero) can
            // still prove this display property. Scan only this bounded leaf.
            direction=15
            var previous=Coordinate.paper(.init(x:f[0].value(at:0),y:f[1].value(at:0)))
            for i in 1..<block.count {
              let point=Coordinate.paper(.init(x:f[0].value(at:i),y:f[1].value(at:i)))
              direction &= Self.directions(from:previous,to:point)
              guard direction != 0 else { return nil };previous=point
            }
          }
          guard direction != 0 else { return nil }
          self.init(directions:direction,width:Double(bitPattern:w),opacity:Double(bitPattern:a))
        case .literal(let samples):
          let first=samples[0]
          var directions: UInt8=15,previous=Coordinate(first)
          for i in 1..<samples.count {
            let next=samples[i],point=Coordinate(next)
            guard next.width.bitPattern == first.width.bitPattern,next.opacity.bitPattern == first.opacity.bitPattern else { return nil }
            directions &= Self.directions(from:previous,to:point)
            guard directions != 0 else { return nil };previous=point
          }
          self.init(directions:directions,width:first.width,opacity:first.opacity)
        }
      }
      func joined(_ other: Self,from a: Coordinate?,to b: Coordinate?) -> Self? {
        guard width.bitPattern == other.width.bitPattern,opacity.bitPattern == other.opacity.bitPattern else { return nil }
        let direction=directions & other.directions & Self.directions(from:a,to:b)
        return direction == 0 ? nil : .init(directions:direction,width:width,opacity:opacity)
      }
    }
    /// Disposable contour certificate in the existing source hierarchy. It
    /// bounds centers against the endpoint line and all directed tangents; it
    /// is not a simplified source or another spatial index.
    struct Curve: Sendable {
      let error: Double
      let tangentLow,tangentHigh: SIMD2<Double>
      let minimumWidth,maximumWidth: Double
      static func point(_ p: SpatialPoint) -> SIMD2<Double> { .init(p.x,p.y) }
      static func distance(_ p: SIMD2<Double>,from a: SIMD2<Double>,to b: SIMD2<Double>) -> Double {
        let d=b-a,length=hypot(d.x,d.y)
        guard length > 0 else { return hypot(p.x-a.x,p.y-a.y) }
        return abs((p.x-a.x)*(d.y/length)-(p.y-a.y)*(d.x/length)).nextUp
      }
      private static func segmentDistance(_ p: SIMD2<Double>,from a: SIMD2<Double>,to b: SIMD2<Double>) -> Double {
        let d=b-a,length=d.x*d.x+d.y*d.y
        guard length > 0,length.isFinite else { return hypot(p.x-a.x,p.y-a.y) }
        let t=min(1,max(0,((p.x-a.x)*d.x+(p.y-a.y)*d.y)/length))
        return hypot(p.x-a.x-d.x*t,p.y-a.y-d.y*t).nextUp
      }
      init?(block: Block,first: Coordinate,last: Coordinate) {
        // Translucent composition has no coarse certificate here. Do not pay
        // for contour summaries that its display cannot use.
        switch block {
        case .fields(let fields,_):
          guard case .constant(let alpha)=fields[4],alpha == Double(1).bitPattern else { return nil }
        case .literal(let samples): guard samples.values.allSatisfy({ $0.opacity == 1 }) else { return nil }
        }
        guard let begin=first.relative(to:first.origin),let end=last.relative(to:first.origin) else { return nil }
        let a=Self.point(begin),b=Self.point(end)
        var low=SIMD2<Double>(repeating:.infinity),high = -low,error=Double.zero
        var minWidth=Double.infinity,maxWidth=Double.zero
        var previous: SIMD2<Double>?
        for i in 0..<block.count {
          let p: SIMD2<Double>,width: Double
          if case .fields(let fields,_)=block {
            p = .init(fields[0].value(at:i),fields[1].value(at:i));width=fields[3].value(at:i)
          } else {
            let sample=block.sample(at:i)
            guard let local=Coordinate(sample).relative(to:first.origin) else { return nil }
            p=Self.point(local);width=sample.width
          }
          error=max(error,Self.segmentDistance(p,from:a,to:b))
          minWidth=min(minWidth,width);maxWidth=max(maxWidth,width)
          if let previous {
            let d=p-previous,length=hypot(d.x,d.y)
            guard length > 0,length.isFinite else { return nil }
            let unit=d/length
            low = .init(min(low.x,unit.x.nextDown),min(low.y,unit.y.nextDown))
            high = .init(max(high.x,unit.x.nextUp),max(high.y,unit.y.nextUp))
          }
          previous=p
        }
        self.init(error:error,tangentLow:low,tangentHigh:high,minimumWidth:minWidth,maximumWidth:maxWidth)
      }
      init(error: Double,tangentLow: SIMD2<Double>,tangentHigh: SIMD2<Double>,minimumWidth: Double,
        maximumWidth: Double) {
        self.error=error;self.tangentLow=tangentLow;self.tangentHigh=tangentHigh
        self.minimumWidth=minimumWidth;self.maximumWidth=maximumWidth
      }
      func joined(_ other: Self,a: SIMD2<Double>,b: SIMD2<Double>,c: SIMD2<Double>,d: SIMD2<Double>) -> Self? {
        let seam=c-b,length=hypot(seam.x,seam.y)
        guard length > 0,length.isFinite else { return nil }
        let u=seam/length
        let low=SIMD2<Double>(min(tangentLow.x,other.tangentLow.x,u.x.nextDown),min(tangentLow.y,other.tangentLow.y,u.y.nextDown))
        let high=SIMD2<Double>(max(tangentHigh.x,other.tangentHigh.x,u.x.nextUp),max(tangentHigh.y,other.tangentHigh.y,u.y.nextUp))
        // The distance to a line is convex along each child chord. Its
        // endpoint envelope plus the child's deviation encloses every center.
        let error=max(self.error+max(Self.segmentDistance(a,from:a,to:d),Self.segmentDistance(b,from:a,to:d)),
          other.error+max(Self.segmentDistance(c,from:a,to:d),Self.segmentDistance(d,from:a,to:d))).nextUp
        return .init(error:error,tangentLow:low,tangentHigh:high,minimumWidth:min(minimumWidth,other.minimumWidth),
          maximumWidth:max(maximumWidth,other.maximumWidth))
      }
    }
    let first: Coordinate?,last: Coordinate?
    private let axisStrip: AxisStrip?
    let curve: Curve?
    var isUniformAxisStrip: Bool { axisStrip != nil }
    func canReduceAxisStrip(minimumSpacing: Double,maximumSpan: Double) -> Bool {
      isUniformAxisStrip && self.minimumSpacing > minimumSpacing && max(bounds.width,bounds.height) < maximumSpan
    }
    public let bounds: CGRect
    public let minimumSpacing: Double
    public let stationary: Bool
    public var origin: WorldPoint? { first?.origin }
    init(block: Block,includingCurve: Bool = true) {
      axisStrip=AxisStrip(block)
      guard block.count > 0 else { first=nil;last=nil;curve=nil;bounds = .null;minimumSpacing = .infinity;stationary=true;return }
      first=Coordinate(block.sample(at:0));last=Coordinate(block.sample(at:block.count-1))
      if !includingCurve { curve=nil }
      else if let axisStrip,axisStrip.opacity == 1 {
        let direction: SIMD2<Double>
        switch axisStrip.directions {
        case 1: direction = .init(1,0)
        case 2: direction = .init(-1,0)
        case 4: direction = .init(0,1)
        case 8: direction = .init(0,-1)
        default: direction = .zero
        }
        curve = .init(error:0,tangentLow:block.count == 1 ? .init(repeating:.infinity) : direction,
          tangentHigh:block.count == 1 ? .init(repeating:-.infinity) : direction,minimumWidth:axisStrip.width,maximumWidth:axisStrip.width)
      } else { curve=Curve(block:block,first:first!,last:last!) }
      var cost=AccessCost()
      bounds=Self.bounds(block,in:0..<block.count,origin:first?.origin,cost:&cost)
      if case .fields(let fields,_)=block {
        func step(_ f: Field) -> Double? {
          switch f { case .constant: return 0;case .progression(_,let d): return d.value;case .literal: return nil }
        }
        if let x=step(fields[0]),let y=step(fields[1]) {
          minimumSpacing=block.count == 1 ? .infinity : max(0,hypot(x,y).nextDown);stationary=x == 0 && y == 0;return
        }
      }
      var spacing=Double.infinity,previous=first!,same=true
      for i in 1..<block.count {
        let next: Coordinate
        if case .fields(let f,_)=block { next = .paper(.init(x:f[0].value(at:i),y:f[1].value(at:i))) }
        else { next=Coordinate(block.sample(at:i)) }
        spacing=min(spacing,previous.distance(to:next));same = same && previous == next;previous=next
      }
      minimumSpacing=spacing;stationary=same
    }
    private init(first: Coordinate?,last: Coordinate?,bounds: CGRect,minimumSpacing: Double,stationary: Bool,axisStrip: AxisStrip?,curve: Curve?) {
      self.first=first;self.last=last;self.bounds=bounds;self.minimumSpacing=minimumSpacing;self.stationary=stationary;self.axisStrip=axisStrip;self.curve=curve
    }
    static func bounds(_ block: Block,in range: Range<Int>,origin: WorldPoint?,cost: inout AccessCost) -> CGRect {
      guard let origin else {
        return block.bounds(in:range,cost:&cost)
      }
      var result=CGRect.null
      for i in range {
        cost.decodedSamples += 1
        let sample=block.sample(at:i)
        guard let world=sample.worldPoint else { return .infinite }
        let point=origin.delta(to:world)
        result=result.union(Sequence.pointBounds(point.x,point.y,sample.width))
      }
      return result
    }
    func placing(_ rect: CGRect,from origin: WorldPoint?) -> CGRect {
      if rect.isNull { return rect }
      switch (self.origin,origin) {
      case (nil,nil): return rect
      case (.some(let a),.some(let b)):
        let delta=a.delta(to:b)
        return Self.offset(rect,x:delta.x,y:delta.y)
      default: return .infinite
      }
    }
    public static func offset(_ rect: CGRect,x: Double,y: Double) -> CGRect {
      guard !rect.isNull,x != 0 || y != 0 else { return rect }
      let left=(rect.minX+x).nextDown,top=(rect.minY+y).nextDown
      return .init(x:left,y:top,width:((rect.maxX+x).nextUp-left).nextUp,height:((rect.maxY+y).nextUp-top).nextUp)
    }
    func joined(_ other: Self) -> Self {
      guard let end=last else { return other };guard let begin=other.first else { return self }
      return .init(first:first,last:other.last,bounds:bounds.union(placing(other.bounds,from:other.origin)),
        minimumSpacing:min(minimumSpacing,other.minimumSpacing,end.distance(to:begin)),stationary:stationary && other.stationary && end == begin,
        axisStrip:axisStrip.flatMap { a in other.axisStrip.flatMap { a.joined($0,from:end,to:begin) } },
        curve:joinedCurve(other))
    }
    private func joinedCurve(_ other: Self) -> Curve? {
      guard let curve,let next=other.curve,let a=first?.relative(to:origin),let b=last?.relative(to:origin),
        let c=other.first?.relative(to:origin),let d=other.last?.relative(to:origin) else { return nil }
      return curve.joined(next,a:Curve.point(a),b:Curve.point(b),c:Curve.point(c),d:Curve.point(d))
    }
    func shifted(_ step: InkRepeatStep) -> Self {
      .init(first:first?.shifted(step),last:last?.shifted(step),bounds:Self.offset(bounds,x:step.x.value,y:step.y.value),minimumSpacing:minimumSpacing,stationary:stationary,axisStrip:axisStrip,curve:curve)
    }
    private func repeatedCurve(_ end: Self,step: InkRepeatStep) -> Curve? {
      guard let envelope=joinedCurve(end),let seam=joinedCurve(shifted(step)) else { return nil }
      return .init(error:envelope.error,tangentLow:seam.tangentLow,tangentHigh:seam.tangentHigh,
        minimumWidth:envelope.minimumWidth,maximumWidth:envelope.maximumWidth)
    }
    func repeated(count: Int,step: InkRepeatStep) -> Self {
      guard count > 1,let first,let last else { return self }
      let end=shifted(step.multiplied(by:count-1)!)
      return .init(first:first,last:end.last,bounds:bounds.union(end.bounds),
        minimumSpacing:min(minimumSpacing,last.distance(to:first.shifted(step))),stationary:stationary && step.x == .zero && step.y == .zero,
        axisStrip:axisStrip.flatMap { $0.joined($0,from:last,to:first.shifted(step)) },curve:repeatedCurve(end,step:step))
    }
  }

  public struct AccessCost: Sendable {
    public var visitedNodes: Int, jumps: Int, decodedSamples: Int
    public init(visitedNodes: Int = 0, jumps: Int = 0, decodedSamples: Int = 0) {
      self.visitedNodes=visitedNodes;self.jumps=jumps;self.decodedSamples=decodedSamples
    }
  }

  /// A persistent sequence index, not a second scene/spatial index. At most one
  /// literal leaf per 256 measurements; repeats share the same immutable body.
  final class Sequence: Sendable {
    /// One immutable basis owner can have several index bindings. Balancing
    /// copies bindings, not the semantic transform; normalization must not
    /// repeatedly rediscover/factor the same already-shared owner.
    final class Basis: Sendable {
      let step: InkRepeatStep
      // A composed binding retains its outer scope's identity. Rebalancing may
      // fuse local offsets, but cannot turn that one scope into new independent
      // semantic frames and start R5 again. Equality still checks the full step.
      let origin: UUID
      init(_ step: InkRepeatStep,origin: UUID = UUID()) { self.step=step;self.origin=origin }
    }
    enum Content: Sendable {
      case block(Block)
      case pair(Sequence,Sequence)
      case repeated(Sequence,Int,InkRepeatStep)
      case shifted(Sequence,Basis)
    }
    let content: Content
    let count: Int
    let height: Int
    let pending: Bool
    // A <=3-event primitive has no internal range to index. Keep just that
    // primitive; derive its bounded facts only when a consumer needs them.
    private final class Summary: Sendable {
      let geometry: Geometry
      let worldEvents: Int
      let hasVisibleInk: Bool
      let domain: [Lattice?]
      init(geometry: Geometry,worldEvents: Int,hasVisibleInk: Bool,domain: [Lattice?]) {
        self.geometry=geometry;self.worldEvents=worldEvents;self.hasVisibleInk=hasVisibleInk;self.domain=domain
      }
    }
    private let summary: Summary?
    private var primitive: Block {
      guard case .block(let block)=content else { preconditionFailure("An aggregate must retain its summary") }
      return block
    }
    var geometry: Geometry { summary?.geometry ?? Geometry(block:primitive,includingCurve:false) }
    // A tiny primitive has no internal detail to skip. Build its certificate
    // only when composing an aggregate that can actually benefit from it.
    private var composableGeometry: Geometry { summary?.geometry ?? Geometry(block:primitive) }
    var worldEvents: Int { summary?.worldEvents ?? Self.worldEvents(in:primitive) }
    var hasVisibleInk: Bool { summary?.hasVisibleInk ?? Self.hasVisibleInk(in:primitive) }
    var bounds: CGRect { geometry.bounds }
    var domain: [Lattice?] { summary?.domain ?? Self.domain(of:primitive) }
    var hasStoredSummary: Bool { summary != nil }
    static let empty=Sequence(block:.literal(.init([])))

    init(block: Block,pending: Bool = false) {
      self.pending=pending
      content = .block(block);count=block.count;height=1
      summary=block.count < 4 ? nil : .init(geometry:Geometry(block:block),
        worldEvents:Self.worldEvents(in:block),hasVisibleInk:Self.hasVisibleInk(in:block),domain:Self.domain(of:block))
    }
    private static func worldEvents(in block: Block) -> Int {
      if case .literal(let samples)=block { return samples.values.reduce(0) { $0+($1.worldPoint == nil ? 0 : 1) } }
      return 0
    }
    private static func hasVisibleInk(in block: Block) -> Bool {
      switch block {
      case .literal(let samples): return samples.values.contains { $0.opacity > 0 }
      case .fields(let fields,let count):
        switch fields[4] {
        case .literal(let bits): return bits.contains { Double(bitPattern:$0) > 0 }
        default: return count > 0 && (fields[4].value(at:0) > 0 || fields[4].value(at:count-1) > 0)
        }
      }
    }
    private static func domain(of block: Block) -> [Lattice?] {
      func fieldDomain(_ field: Field) -> Lattice? {
        switch field {
        case .constant(let bits): return Lattice(Double(bitPattern:bits))
        case .progression(let start,let step):
          guard let last=step.multiplied(by:block.count-1) else { return nil }
          // Include the step's lattice, not just endpoints (even endpoints can
          // hide an odd intermediate coefficient).
          return Lattice(start.value)?.shifted(from:.zero,to:last,quantum:step.exponent)
        case .literal(let bits):
          var result=Lattice(Double(bitPattern:bits[0]))
          for bits in bits.dropFirst() {
            guard let current=result,let next=Lattice(Double(bitPattern:bits)) else { return nil }
            result=current.union(next)
          }
          return result
        }
      }
      switch block {
      case .fields(let fields,_):
        return (0..<3).map { fieldDomain(fields[$0]) }
      case .literal(let samples):
        var ranges=[Lattice?](repeating:nil,count:3),valid=[true,true,true]
        for (i,p) in samples.values.enumerated() {
          if p.worldPoint != nil { valid=[false,false,false] }
          for (j,value) in [p.point.x,p.point.y,p.timeOffset].enumerated() where valid[j] {
            if let r=Lattice(value) {
              ranges[j] = i == 0 ? r : ranges[j]?.union(r)
              if ranges[j] == nil { valid[j]=false }
            } else { valid[j]=false }
          }
        }
        return (0..<3).map { valid[$0] ? ranges[$0] : nil }
      }
    }
    static func pointBounds(_ x: Double,_ y: Double,_ width: Double) -> CGRect {
      let r=max(width/2,0.25)*Double(InkStrokeGeometry.maximumCrossSectionScale),left=(x-r).nextDown,top=(y-r).nextDown
      return CGRect(x:left,y:top,width:((x+r).nextUp-left).nextUp,height:((y+r).nextUp-top).nextUp)
    }
    private init(_ content: Content,count: Int,height: Int,domain: [Lattice?],pending: Bool = false) {
      let geometry: Geometry,worldEvents: Int,hasVisibleInk: Bool
      switch content {
      case .block(let b): self.pending=pending;geometry=Geometry(block:b)
      case .pair(let a,let b): self.pending=pending || a.pending || b.pending;geometry=a.composableGeometry.joined(b.composableGeometry)
      case .shifted(let body,let basis): self.pending=pending || body.pending;geometry=body.composableGeometry.shifted(basis.step)
      case .repeated(let body,let n,let step): self.pending=pending || body.pending;geometry=body.composableGeometry.repeated(count:n,step:step)
      }
      switch content {
      case .block(let b):
        worldEvents=Self.worldEvents(in:b);hasVisibleInk=Self.hasVisibleInk(in:b)
      case .pair(let a,let b): worldEvents=a.worldEvents+b.worldEvents;hasVisibleInk=a.hasVisibleInk || b.hasVisibleInk
      case .repeated(let body,let n,_): worldEvents=body.worldEvents*n;hasVisibleInk=n > 0 && body.hasVisibleInk
      case .shifted(let body,_): worldEvents=body.worldEvents;hasVisibleInk=body.hasVisibleInk
      }
      self.content=content;self.count=count;self.height=height
      if case .block(let block)=content,block.count < 4 { summary=nil }
      else { summary = .init(geometry:geometry,worldEvents:worldEvents,hasVisibleInk:hasVisibleInk,domain:domain) }
    }
    static func from(_ blocks: [Block]) -> Sequence {
      func build(_ range: Range<Int>) -> Sequence {
        if range.isEmpty { return empty }
        if range.count == 1 { return Sequence(block:blocks[range.lowerBound]) }
        let mid=range.lowerBound+range.count/2
        return pair(build(range.lowerBound..<mid),build(mid..<range.upperBound))
      }
      return build(blocks.indices)
    }
    static func pair(_ a: Sequence,_ b: Sequence) -> Sequence {
      if a.count == 0 { return b };if b.count == 0 { return a }
      let left=a.domain,right=b.domain
      return .init(.pair(a,b),count:a.count+b.count,height:max(a.height,b.height)+1,
        domain:(0..<3).map { i in
          guard let x=left[i],let y=right[i] else { return nil };return x.union(y)
        })
    }
    /// AVL join copies only the path. Repeated bodies are atomic in this outer
    /// sequence; nested-body access costs are reported separately by traversal.
    private var children: (Sequence,Sequence)? {
      switch content {
      case .pair(let a,let b): return (a,b)
      case .shifted(let body,let basis):
        guard let (a,b)=body.children else { return nil }
        return (a.placing(basis)!,b.placing(basis)!)
      default: return nil
      }
    }
    static func balance(_ a: Sequence,_ b: Sequence) -> Sequence {
      if a.height > b.height+1, let (l,r)=a.children {
        let result=balanced(l,balance(r,b));return a.pending || b.pending ? result.markPending() : result
      }
      if b.height > a.height+1, let (l,r)=b.children {
        let result=balanced(balance(a,l),r);return a.pending || b.pending ? result.markPending() : result
      }
      return pair(a,b)
    }
    private static func balanced(_ a: Sequence,_ b: Sequence) -> Sequence {
      if a.height > b.height+1,let (l,r)=a.children {
        if l.height >= r.height { return pair(l,pair(r,b)) }
        if let (rl,rr)=r.children { return pair(pair(l,rl),pair(rr,b)) }
      }
      if b.height > a.height+1,let (l,r)=b.children {
        if r.height >= l.height { return pair(pair(a,l),r) }
        if let (ll,lr)=l.children { return pair(pair(a,ll),pair(lr,r)) }
      }
      return pair(a,b)
    }
    private func shiftedDomain(first: InkRepeatStep,last: InkRepeatStep,quantum: InkRepeatStep? = nil) -> [Lattice?]? {
      let a=[first.x,first.y,first.time],b=[last.x,last.y,last.time]
      let quantum=quantum.map { [$0.x.exponent,$0.y.exponent,$0.time.exponent] }
      let original=domain
      var result=original
      for i in 0..<3 where a[i] != .zero || b[i] != .zero {
        guard let d=original[i]?.shifted(from:a[i],to:b[i],quantum:quantum?[i]) else { return nil };result[i]=d
      }
      if let time=result[2], time.low < 0 { return nil }
      return result
    }
    static func repeated(_ body: Sequence,count: Int,step: InkRepeatStep) -> Sequence? {
      guard count >= 0 else { return nil }
      let (total,overflow)=body.count.multipliedReportingOverflow(by:count)
      guard !overflow else { return nil }
      if count == 0 || body.count == 0 { return empty }
      if count == 1 { return body } // R1: Storage retains the exit state
      if case .repeated(let inner,let n,let innerStep)=body.content,
        innerStep.multiplied(by:n) == step {
        let (combined,overflow)=n.multipliedReportingOverflow(by:count)
        if !overflow,let flattened=repeated(inner,count:combined,step:innerStep) { return flattened }
      }
      guard body.bounds.minX.isFinite,body.bounds.minY.isFinite,body.bounds.width.isFinite,body.bounds.height.isFinite,
        let last=step.multiplied(by:count-1),let domain=body.shiftedDomain(first:.zero,last:last,quantum:step) else { return nil }
      return .init(.repeated(body,count,step),count:total,height:1,
        domain:domain)
    }
    func shifted(_ step: InkRepeatStep) -> Sequence? {
      if step == .zero || count == 0 { return self }
      return placing(Basis(step),compose:true)
    }
    func placing(_ basis: Basis,compose: Bool = true) -> Sequence? {
      let step=basis.step
      if step == .zero || count == 0 { return self }
      if compose,case .shifted(let body,let previous)=content,let combined=previous.step.adding(step),
        let merged=body.placing(Basis(combined,origin:basis.origin)) { return merged }
      guard let domain=shiftedDomain(first:step,last:step) else { return nil }
      return .init(.shifted(self,basis),count:count,height:height,domain:domain)
    }
    static func offset(_ bounds: CGRect,_ step: InkRepeatStep) -> CGRect {
      guard !bounds.isNull,step.x != .zero || step.y != .zero else { return bounds }
      let x=(bounds.minX+step.x.value).nextDown,y=(bounds.minY+step.y.value).nextDown
      let right=(bounds.maxX+step.x.value).nextUp,bottom=(bounds.maxY+step.y.value).nextUp
      return CGRect(x:x,y:y,width:(right-x).nextUp,height:(bottom-y).nextUp)
    }
    /// The index may rebalance; semantic rewrites only REMOVE a node or reduce
    /// leaf storage. No inverse rewrite/search cycle is present.
    static func join(_ a: Sequence,_ b: Sequence,work: inout RewriteWork) -> Sequence {
      if a.count == 0 { work.applied(2);return b }
      if b.count == 0 { work.applied(2);return a }
      guard work.spend(1) else { return balance(a,b).markPending() }
      if let reduced=reducePair(a,b,work:&work) { return reduced }
      func edge(_ node: Sequence,last: Bool) -> Sequence {
        var node=node
        while let (a,b)=node.children { work.visitedNodes += 1;node=last ? b : a }
        return node
      }
      let left=edge(a,last:true),right=edge(b,last:false)
      if (left !== a || right !== b),let reduced=reducePair(left,right,work:&work) {
        let prefix=a.slice(0..<(a.count-left.count)),suffix=b.slice(right.count..<b.count)
        return join(join(prefix,reduced,work:&work),suffix,work:&work)
      }
      let result=balance(a,b)
      return work.deferred ? result.markPending() : result
    }
    private static func reducePair(_ a: Sequence,_ b: Sequence,work: inout RewriteWork) -> Sequence? {
      func run(_ node: Sequence) -> (Sequence,Int,InkRepeatStep,InkRepeatStep)? {
        switch node.content {
        case .repeated(let body,let n,let step): return (body,n,step,.zero)
        case .shifted(let body,let basis):
          if let (base,n,step,previous)=run(body),let offset=previous.adding(basis.step) { return (base,n,step,offset) }
          return nil
        default: return nil
        }
      }
      // R3: same body/context AND contiguous phase. A structural mismatch is
      // not proof of inequality; unknown equality simply refuses this rewrite.
      if let (ab,an,step,ao)=run(a),let (bb,bn,bs,bo)=run(b),step == bs,
        let displacement=step.multiplied(by:an),ao.adding(displacement) == bo,
        sameEvents(ab,bb,work:&work) == .equal {
        let (n,overflow)=an.addingReportingOverflow(bn)
        if !overflow,let combined=repeated(ab,count:n,step:step),let placed=combined.shifted(ao) {
          work.applied(3);return placed
        }
      }
      // R5: merge equal immutable basis owners within this one action. Two
      // bindings of the SAME owner are already factored; index reassociation
      // must never restart this rewrite or multiply the transform's state.
      if case .shifted(let x,let ax)=a.content,case .shifted(let y,let by)=b.content,
        ax.origin != by.origin,ax.step == by.step,let combined=balance(x,y).markPending().placing(ax) {
        work.deferred=true;work.applied(5);return combined
      }
      // R8: bounded local candidate, followed by the existing full bit proof.
      if case .block(let x)=a.content,case .block(let y)=b.content,a.count+b.count <= blockSize {
        guard work.spend((a.count+b.count)*8) else { return nil }
        let samples=(0..<x.count).map { x.sample(at:$0) }+(0..<y.count).map { y.sample(at:$0) }
        work.scannedEvents += samples.count
        let block=Block(samples[...])
        if block.hasGenerator && block.payloadBytes < x.payloadBytes+y.payloadBytes+nodeBytes {
          work.applied(8);return Sequence(block:block)
        }
      }
      return nil
    }
    static func sameEvents(_ a: Sequence,_ b: Sequence,work: inout RewriteWork) -> InkRelationEquality {
      if a === b { return .equal }
      if a.count != b.count { return .different }
      // Large shared bodies use identity. An unbounded comparison is not hidden
      // in a supposedly constant-time rewrite.
      guard a.count <= blockSize else { return .notProven }
      for i in 0..<a.count {
        guard work.spend(1+a.height+b.height) else { return .notProven }
        var cost=AccessCost()
        let x=a.sample(at:i,cost:&cost),y=b.sample(at:i,cost:&cost)
        work.visitedNodes += cost.visitedNodes;work.comparedEvents += 1
        if !InkSampleRelations.sameBits(x,y) { return .different }
      }
      return .equal
    }
    private static let nodeBytes=MemoryLayout<Content>.stride+MemoryLayout<Geometry>.stride+MemoryLayout<Lattice?>.stride*3+64
    func markPending() -> Sequence {
      if pending { return self }
      return .init(content,count:count,height:height,domain:domain,pending:true)
    }
    private static func repack(_ samples: [SpatialInkSample],work: inout RewriteWork) -> Sequence {
      guard samples.count >= 4,samples.allSatisfy({ $0.worldPoint == nil }) else { return Sequence(block:.literal(.init(samples))) }
      guard work.spend(samples.count*8) else { return Sequence(block:.literal(.init(samples)),pending:true) }
      work.scannedEvents += samples.count
      let block=Block(samples[...])
      if block.hasGenerator { work.applied(8) }
      return Sequence(block:block)
    }
    func edited(at index: Int,to value: SpatialInkSample,work: inout RewriteWork) -> Sequence {
      work.visitedNodes += 1
      switch content {
      case .block(let b):
        var samples=(0..<b.count).map { b.sample(at:$0) };samples[index]=value
        return Self.repack(samples,work:&work)
      case .pair(let a,let b):
        return index < a.count
          ? Self.join(a.edited(at:index,to:value,work:&work),b,work:&work)
          : Self.join(a,b.edited(at:index-a.count,to:value,work:&work),work:&work)
      case .repeated(let body,let n,let step):
        let q=index/body.count,r=index%body.count
        let prefix=Self.repeated(body,count:q,step:step)!
        let middle=body.shifted(step.multiplied(by:q)!)!.edited(at:r,to:value,work:&work)
        let suffix=Self.repeated(body,count:n-q-1,step:step)!.shifted(step.multiplied(by:q+1)!)!
        return Self.join(Self.join(prefix,middle,work:&work),suffix,work:&work)
      case .shifted(let body,let basis):
        let step=basis.step
        if let local=step.negated.applyingIfExact(value),let checked=step.applyingIfExact(local),
          InkSampleRelations.sameBits(checked,value) {
          let edited=body.edited(at:index,to:local,work:&work)
          if let result=edited.translated(step,work:&work) { return result }
        }
        // A new global literal need not have a representable local inverse.
        // Retain both unchanged ranges instead of rounding its provenance.
        return Self.join(Self.join(slice(0..<index),Sequence(block:.literal(.init([value]))),work:&work),
          slice((index+1)..<count),work:&work)
      }
    }
    /// Semantic propagation is atomic, separate from optional normalization.
    /// If a shared range proof fails, descend within THIS owner. The worst case
    /// really visits/materializes every event; one unsupported event rejects it.
    func translated(_ step: InkRepeatStep,work: inout RewriteWork) -> Sequence? {
      work.visitedNodes += 1
      if let fast=shifted(step) { return fast }
      switch content {
      case .pair(let a,let b):
        guard let x=a.translated(step,work:&work),let y=b.translated(step,work:&work) else { return nil }
        return Self.join(x,y,work:&work)
      case .block(let block):
        var samples:[SpatialInkSample]=[];samples.reserveCapacity(block.count)
        for i in 0..<block.count {
          guard let p=step.applyingIfExact(block.sample(at:i)) else { return nil }
          samples.append(p);work.propagatedEvents += 1
        }
        return Self.repack(samples,work:&work)
      case .shifted,.repeated:
        // Split by logical ranges, not by replaying preceding state. This path
        // is explicitly expensive when no shared translation proof exists.
        if count > blockSize {
          let mid=count/2
          guard let a=slice(0..<mid).translated(step,work:&work),
            let b=slice(mid..<count).translated(step,work:&work) else { return nil }
          return Self.join(a,b,work:&work)
        }
        var samples:[SpatialInkSample]=[];forEachSample(in:0..<count) { samples.append($0) }
        for i in samples.indices {
          guard let p=step.applyingIfExact(samples[i]) else { return nil };samples[i]=p;work.propagatedEvents += 1
        }
        return Self.repack(samples,work:&work)
      }
    }
    func normalized(work: inout RewriteWork) -> Sequence {
      guard pending else { return self }
      guard work.spend(1) else { return self }
      work.visitedNodes += 1
      switch content {
      case .block(let b): return Self.repack((0..<b.count).map { b.sample(at:$0) },work:&work)
      case .pair(let a,let b): return Self.join(a.normalized(work:&work),b.normalized(work:&work),work:&work)
      case .shifted(let body,let basis): return body.normalized(work:&work).placing(basis,compose:true)!
      case .repeated(let body,let n,let step): return Self.repeated(body.normalized(work:&work),count:n,step:step)!
      }
    }
    func sample(at index: Int,cost: inout AccessCost) -> SpatialInkSample {
      cost.visitedNodes += 1
      switch content {
      case .block(let b): cost.decodedSamples += 1;return b.sample(at:index)
      case .pair(let a,let b): return index < a.count ? a.sample(at:index,cost:&cost) : b.sample(at:index-a.count,cost:&cost)
      case .repeated(let body,_,let step):
        cost.jumps += 1
        return step.multiplied(by:index/body.count)!.apply(body.sample(at:index%body.count,cost:&cost))
      case .shifted(let body,let basis): return basis.step.apply(body.sample(at:index,cost:&cost))
      }
    }
    func bounds(in range: Range<Int>,cost: inout AccessCost) -> CGRect {
      cost.visitedNodes += 1
      if range.isEmpty { return .null }
      if range == 0..<count { return bounds }
      switch content {
      case .block(let b):
        return Geometry.bounds(b,in:range,origin:geometry.origin,cost:&cost)
      case .pair(let a,let b):
        var result=CGRect.null
        if range.lowerBound < a.count { result=a.bounds(in:range.lowerBound..<min(a.count,range.upperBound),cost:&cost) }
        if range.upperBound > a.count { result=result.union(geometry.placing(b.bounds(in:max(0,range.lowerBound-a.count)..<(range.upperBound-a.count),cost:&cost),from:b.geometry.origin)) }
        return result
      case .shifted(let body,let basis): return Self.offset(body.bounds(in:range,cost:&cost),basis.step)
      case .repeated(let body,_,let step):
        let first=range.lowerBound/body.count,last=(range.upperBound-1)/body.count
        cost.jumps += first == last ? 1 : 2
        if first == last { return Self.offset(body.bounds(in:range.lowerBound%body.count..<(range.upperBound-1)%body.count+1,cost:&cost),step.multiplied(by:first)!) }
        var result=Self.offset(body.bounds(in:range.lowerBound%body.count..<body.count,cost:&cost),step.multiplied(by:first)!)
        result=result.union(Self.offset(body.bounds(in:0..<(range.upperBound-1)%body.count+1,cost:&cost),step.multiplied(by:last)!))
        if last > first+1 {
          cost.jumps += 2
          result=result.union(Self.offset(body.bounds,step.multiplied(by:first+1)!))
            .union(Self.offset(body.bounds,step.multiplied(by:last-1)!))
        }
        return result
      }
    }
    /// A conservative cover may include the unused part of a boundary leaf.
    /// It costs no measurement reads and can only make display rejection stricter.
    func geometryCovering(_ range: Range<Int>,cost: inout AccessCost) -> Geometry {
      cost.visitedNodes += 1
      if range == 0..<count { return geometry }
      switch content {
      case .block: return geometry
      case .pair(let a,let b):
        if range.upperBound <= a.count { return a.geometryCovering(range,cost:&cost) }
        if range.lowerBound >= a.count { return b.geometryCovering((range.lowerBound-a.count)..<(range.upperBound-a.count),cost:&cost) }
        return a.geometryCovering(range.lowerBound..<a.count,cost:&cost)
          .joined(b.geometryCovering(0..<(range.upperBound-a.count),cost:&cost))
      case .shifted(let body,let basis): return body.geometryCovering(range,cost:&cost).shifted(basis.step)
      case .repeated(let body,_,let step):
        let first=range.lowerBound/body.count,last=(range.upperBound-1)/body.count
        cost.jumps += first == last ? 1 : 2
        if first == last { return body.geometryCovering((range.lowerBound%body.count)..<((range.upperBound-1)%body.count+1),cost:&cost).shifted(step.multiplied(by:first)!) }
        var result=body.geometryCovering((range.lowerBound%body.count)..<body.count,cost:&cost).shifted(step.multiplied(by:first)!)
        if last > first+1 { result=result.joined(body.geometry.repeated(count:last-first-1,step:step).shifted(step.multiplied(by:first+1)!)) }
        return result.joined(body.geometryCovering(0..<((range.upperBound-1)%body.count+1),cost:&cost).shifted(step.multiplied(by:last)!))
      }
    }
    /// Only a cached proof covering this interval admits early display reduction.
    /// A range crossing an unproved join stays detailed; no samples are inspected
    /// just to guess a cheaper representation during camera work.
    func canReduceAxisStrip(in range: Range<Int>,minimumSpacing: Double,maximumSpan: Double,cost: inout AccessCost) -> Bool {
      cost.visitedNodes += 1
      if geometry.canReduceAxisStrip(minimumSpacing:minimumSpacing,maximumSpan:maximumSpan) { return true }
      switch content {
      case .block: return false
      case .pair(let a,let b):
        if range.upperBound <= a.count { return a.canReduceAxisStrip(in:range,minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,cost:&cost) }
        if range.lowerBound >= a.count { return b.canReduceAxisStrip(in:(range.lowerBound-a.count)..<(range.upperBound-a.count),minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,cost:&cost) }
        return false
      case .shifted(let body,_): return body.canReduceAxisStrip(in:range,minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,cost:&cost)
      case .repeated(let body,_,_):
        let first=range.lowerBound/body.count,last=(range.upperBound-1)/body.count
        guard first == last else { return false }
        cost.jumps += 1
        return body.canReduceAxisStrip(in:(range.lowerBound%body.count)..<((range.upperBound-1)%body.count+1),minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,cost:&cost)
      }
    }
    func slice(_ range: Range<Int>) -> Sequence {
      if range.isEmpty { return Self.empty };if range == 0..<count { return self }
      switch content {
      case .block(let b): return Sequence(block:.init(range.map { b.sample(at:$0) }[...]))
      case .pair(let a,let b):
        if range.upperBound <= a.count { return a.slice(range) }
        if range.lowerBound >= a.count { return b.slice((range.lowerBound-a.count)..<(range.upperBound-a.count)) }
        return Self.balance(a.slice(range.lowerBound..<a.count),b.slice(0..<(range.upperBound-a.count)))
      case .shifted(let body,let basis): return body.slice(range).placing(basis)!
      case .repeated(let body,_,let step):
        let first=range.lowerBound/body.count,last=(range.upperBound-1)/body.count
        if first == last { return body.slice(range.lowerBound%body.count..<(range.upperBound-1)%body.count+1).shifted(step.multiplied(by:first)!)! }
        let prefix=body.slice(range.lowerBound%body.count..<body.count).shifted(step.multiplied(by:first)!)!
        let suffix=body.slice(0..<(range.upperBound-1)%body.count+1).shifted(step.multiplied(by:last)!)!
        let middle=Self.repeated(body,count:last-first-1,step:step)!.shifted(step.multiplied(by:first+1)!)!
        return Self.balance(Self.balance(prefix,middle),suffix)
      }
    }
    /// Full export pays for every output event, but never re-descends the
    /// sequence index once per event. No extra expanded intermediate array.
    func forEachSample(in range: Range<Int>,_ emit: (SpatialInkSample)->Void) {
      if range.isEmpty { return }
      switch content {
      case .block(let block): for i in range { emit(block.sample(at:i)) }
      case .pair(let a,let b):
        if range.lowerBound < a.count { a.forEachSample(in:range.lowerBound..<min(a.count,range.upperBound),emit) }
        if range.upperBound > a.count { b.forEachSample(in:max(0,range.lowerBound-a.count)..<(range.upperBound-a.count),emit) }
      case .shifted(let body,let basis):
        body.forEachSample(in:range) { emit(basis.step.apply($0)) }
      case .repeated(let body,_,let step):
        for q in range.lowerBound/body.count...(range.upperBound-1)/body.count {
          let shift=step.multiplied(by:q)!
          body.forEachSample(in:max(0,range.lowerBound-q*body.count)..<min(body.count,range.upperBound-q*body.count)) { emit(shift.apply($0)) }
        }
      }
    }
    func forEachDisplayPoint(in range: Range<Int>,reduce: Bool,origin: WorldPoint? = nil,minimumSpacing: Double,maximumSpan: Double,base: Int = 0,_ emit: (Int,Double,Double,Double,Double)->Void) {
      if range.isEmpty { return }
      if reduce,range.count > 4,geometry.origin == nil || origin != nil,geometry.canReduceAxisStrip(minimumSpacing:minimumSpacing,maximumSpan:maximumSpan) {
        // Stop at this proved aggregate before visiting any of its children.
        // Keep cap neighbours; their original tangent is also used after an
        // outer reflection, shear or anisotropic transform.
        var cost=AccessCost()
        for i in [range.lowerBound,range.lowerBound+1,range.upperBound-2,range.upperBound-1] {
          let p=sample(at:i,cost:&cost)
          let local=origin.flatMap { start in p.worldPoint.map { start.delta(to:$0) } } ?? p.point
          emit(base+i,local.x,local.y,p.width,p.opacity)
        }
        return
      }
      switch content {
      case .block(let block):
        func point(_ i: Int) {
          switch block {
          case .literal(let a):
            let p=a[i], local=origin.flatMap { start in p.worldPoint.map { start.delta(to:$0) } } ?? p.point
            emit(base+i,local.x,local.y,p.width,p.opacity)
          case .fields(let f,_): emit(base+i,f[0].value(at:i),f[1].value(at:i),f[3].value(at:i),f[4].value(at:i))
          }
        }
        for i in range { point(i) }
      case .pair(let a,let b):
        if range.lowerBound < a.count { a.forEachDisplayPoint(in:range.lowerBound..<min(a.count,range.upperBound),reduce:reduce,origin:origin,minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,base:base,emit) }
        if range.upperBound > a.count { b.forEachDisplayPoint(in:max(0,range.lowerBound-a.count)..<(range.upperBound-a.count),reduce:reduce,origin:origin,minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,base:base+a.count,emit) }
      case .shifted(let body,let basis):
        let step=basis.step
        body.forEachDisplayPoint(in:range,reduce:reduce,origin:origin,minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,base:base) { i,x,y,w,o in emit(i,step.apply(x,step.x),step.apply(y,step.y),w,o) }
      case .repeated(let body,_,let step):
        for q in range.lowerBound/body.count...(range.upperBound-1)/body.count {
          let shift=step.multiplied(by:q)!
          body.forEachDisplayPoint(in:max(0,range.lowerBound-q*body.count)..<min(body.count,range.upperBound-q*body.count),reduce:reduce,origin:origin,minimumSpacing:minimumSpacing,maximumSpan:maximumSpan,base:base+q*body.count) {
            i,x,y,w,o in emit(i,shift.apply(x,shift.x),shift.apply(y,shift.y),w,o)
          }
        }
      }
    }
    func allocationSummary(seen: inout Set<ObjectIdentifier>) -> (nodes: Int,bytes: Int) {
      guard seen.insert(ObjectIdentifier(self)).inserted else { return (0,0) }
      var total=(nodes:1,bytes:MemoryLayout<Content>.stride+64)
      if summary != nil { total.bytes += MemoryLayout<Geometry>.stride+MemoryLayout<Lattice?>.stride*3+80 }
      switch content {
      case .block(let b):
        if case .literal(let samples)=b {
          if seen.insert(ObjectIdentifier(samples.buffer)).inserted {
            total.bytes += samples.buffer.byteCount
          }
        } else { total.bytes += b.payloadBytes }
      case .pair(let a,let b):
        for child in [a,b] { let c=child.allocationSummary(seen:&seen);total.nodes += c.nodes;total.bytes += c.bytes }
      case .repeated(let body,_,_):
        let c=body.allocationSummary(seen:&seen);total.nodes += c.nodes;total.bytes += c.bytes
      case .shifted(let body,let basis):
        let c=body.allocationSummary(seen:&seen);total.nodes += c.nodes;total.bytes += c.bytes
        if seen.insert(ObjectIdentifier(basis)).inserted { total.nodes += 1;total.bytes += MemoryLayout<InkRepeatStep>.stride+MemoryLayout<UUID>.stride+16 }
      }
      return total
    }
  }
}
