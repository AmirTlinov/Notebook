import Foundation
import NotebookCore

/// The only fast repeat admitted here advances paper x/y and seconds by an
/// exact translation. It is not an evaluator for arbitrary dependent programs.
struct InkRepeatStep: Equatable, Sendable {
  let x: InkDyadic, y: InkDyadic, time: InkDyadic
  static let zero = Self(x:.zero,y:.zero,time:.zero)
  func multiplied(by count: Int) -> Self? {
    guard let x=x.multiplied(by:count), let y=y.multiplied(by:count),
      let time=time.multiplied(by:count) else { return nil }
    return .init(x:x,y:y,time:time)
  }
  func adding(_ other: Self) -> Self? {
    guard let x=x.adding(other.x), let y=y.adding(other.y), let time=time.adding(other.time) else { return nil }
    return .init(x:x,y:y,time:time)
  }
  var negated: Self { .init(x:x.negated,y:y.negated,time:time.negated) }
  func apply(_ value: Double, _ offset: InkDyadic) -> Double {
    // In particular preserve a literal negative zero for the identity relation.
    offset == .zero ? value : InkDyadic(value)!.adding(offset)!.value
  }
  func applyingIfExact(_ sample: SpatialInkSample) -> SpatialInkSample? {
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
  func apply(_ sample: SpatialInkSample) -> SpatialInkSample {
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

  struct AccessCost { var visitedNodes=0;var jumps=0;var decodedSamples=0 }

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
    let bounds: CGRect
    let pending: Bool
    let domain: [Lattice?] // x, y, time; nil means no admitted nonzero translation
    static let empty=Sequence(block:.literal([]))

    init(block: Block,pending: Bool = false) {
      self.pending=pending
      content = .block(block);count=block.count;height=1
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
          for bits in bits.dropFirst() { guard let next=Lattice(Double(bitPattern:bits)) else { return nil };result=result?.union(next) }
          return result
        }
      }
      switch block {
      case .fields(let fields,_):
        domain=(0..<3).map { fieldDomain(fields[$0]) }
        var rect=CGRect.null
        for i in 0..<block.count { rect=rect.union(Self.pointBounds(fields[0].value(at:i),fields[1].value(at:i),fields[3].value(at:i))) }
        bounds=rect
      case .literal(let samples):
        var rect=CGRect.null,ranges=[Lattice?](repeating:nil,count:3),valid=[true,true,true]
        for (i,p) in samples.enumerated() {
          if p.worldPoint != nil { valid=[false,false,false] }
          for (j,value) in [p.point.x,p.point.y,p.timeOffset].enumerated() where valid[j] {
            if let r=Lattice(value) { ranges[j] = i == 0 ? r : ranges[j]?.union(r) }
            else { valid[j]=false }
          }
          rect=rect.union(Self.pointBounds(p.point.x,p.point.y,p.width))
        }
        domain=(0..<3).map { valid[$0] ? ranges[$0] : nil };bounds=rect
      }
    }
    private static func pointBounds(_ x: Double,_ y: Double,_ width: Double) -> CGRect {
      let r=max(width/2,0.25)*Double(InkStrokeGeometry.maximumCrossSectionScale),left=(x-r).nextDown,top=(y-r).nextDown
      return CGRect(x:left,y:top,width:((x+r).nextUp-left).nextUp,height:((y+r).nextUp-top).nextUp)
    }
    private init(_ content: Content,count: Int,height: Int,bounds: CGRect,domain: [Lattice?],pending: Bool = false) {
      switch content {
      case .block: self.pending=pending
      case .pair(let a,let b): self.pending=pending || a.pending || b.pending
      case .shifted(let body,_),.repeated(let body,_,_): self.pending=pending || body.pending
      }
      self.content=content;self.count=count;self.height=height;self.bounds=bounds;self.domain=domain
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
    private static func pair(_ a: Sequence,_ b: Sequence) -> Sequence {
      if a.count == 0 { return b };if b.count == 0 { return a }
      return .init(.pair(a,b),count:a.count+b.count,height:max(a.height,b.height)+1,
        bounds:a.bounds.union(b.bounds),domain:(0..<3).map { i in
          guard let x=a.domain[i],let y=b.domain[i] else { return nil };return x.union(y)
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
      var result=domain
      for i in 0..<3 where a[i] != .zero || b[i] != .zero {
        guard let d=domain[i]?.shifted(from:a[i],to:b[i],quantum:quantum?[i]) else { return nil };result[i]=d
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
        bounds:body.bounds.union(offset(body.bounds,last)),domain:domain)
    }
    func shifted(_ step: InkRepeatStep) -> Sequence? {
      if step == .zero || count == 0 { return self }
      return placing(Basis(step),compose:true)
    }
    private func placing(_ basis: Basis,compose: Bool = true) -> Sequence? {
      let step=basis.step
      if step == .zero || count == 0 { return self }
      if compose,case .shifted(let body,let previous)=content,let combined=previous.step.adding(step),
        let merged=body.placing(Basis(combined,origin:basis.origin)) { return merged }
      guard let domain=shiftedDomain(first:step,last:step) else { return nil }
      return .init(.shifted(self,basis),count:count,height:height,bounds:Self.offset(bounds,step),domain:domain)
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
    private static let nodeBytes=MemoryLayout<Content>.stride+MemoryLayout<CGRect>.stride+MemoryLayout<Lattice?>.stride*3+48
    private func markPending() -> Sequence {
      if pending { return self }
      return .init(content,count:count,height:height,bounds:bounds,domain:domain,pending:true)
    }
    private static func repack(_ samples: [SpatialInkSample],work: inout RewriteWork) -> Sequence {
      guard samples.count >= 4,samples.allSatisfy({ $0.worldPoint == nil }) else { return Sequence(block:.literal(samples)) }
      guard work.spend(samples.count*8) else { return Sequence(block:.literal(samples),pending:true) }
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
        return Self.join(Self.join(slice(0..<index),Sequence(block:.literal([value])),work:&work),
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
        var samples:[SpatialInkSample]=[];appendDecoded(in:0..<count,to:&samples)
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
        var rect=CGRect.null
        for i in range {
          cost.decodedSamples += 1
          let p=b.sample(at:i)
          rect=rect.union(Self.pointBounds(p.point.x,p.point.y,p.width))
        }
        return rect
      case .pair(let a,let b):
        var result=CGRect.null
        if range.lowerBound < a.count { result=a.bounds(in:range.lowerBound..<min(a.count,range.upperBound),cost:&cost) }
        if range.upperBound > a.count { result=result.union(b.bounds(in:max(0,range.lowerBound-a.count)..<(range.upperBound-a.count),cost:&cost)) }
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
    func appendDecoded(in range: Range<Int>,to output: inout [SpatialInkSample]) {
      if range.isEmpty { return }
      switch content {
      case .block(let block): for i in range { output.append(block.sample(at:i)) }
      case .pair(let a,let b):
        if range.lowerBound < a.count { a.appendDecoded(in:range.lowerBound..<min(a.count,range.upperBound),to:&output) }
        if range.upperBound > a.count { b.appendDecoded(in:max(0,range.lowerBound-a.count)..<(range.upperBound-a.count),to:&output) }
      case .shifted(let body,let basis):
        let step=basis.step
        let start=output.count;body.appendDecoded(in:range,to:&output)
        for i in start..<output.count { output[i]=step.apply(output[i]) }
      case .repeated(let body,_,let step):
        for q in range.lowerBound/body.count...(range.upperBound-1)/body.count {
          let start=output.count,shift=step.multiplied(by:q)!
          body.appendDecoded(in:max(0,range.lowerBound-q*body.count)..<min(body.count,range.upperBound-q*body.count),to:&output)
          if shift != .zero { for i in start..<output.count { output[i]=shift.apply(output[i]) } }
        }
      }
    }
    func forEachDisplayPoint(in range: Range<Int>,reduce: Bool,origin: WorldPoint? = nil,minimumSpacing: Double,_ emit: (Double,Double,Double,Double)->Void) {
      if range.isEmpty { return }
      switch content {
      case .block(let block):
        func point(_ i: Int) {
          switch block {
          case .literal(let a):
            let p=a[i], local=origin.flatMap { start in p.worldPoint.map { start.delta(to:$0) } } ?? p.point
            emit(local.x,local.y,p.width,p.opacity)
          case .fields(let f,_): emit(f[0].value(at:i),f[1].value(at:i),f[3].value(at:i),f[4].value(at:i))
          }
        }
        if reduce && block.isUniformAxisStrip(minimumSpacing:minimumSpacing) && range.count > 4 {
          for i in [range.lowerBound,range.lowerBound+1,range.upperBound-2,range.upperBound-1] { point(i) }
        } else { for i in range { point(i) } }
      case .pair(let a,let b):
        if range.lowerBound < a.count { a.forEachDisplayPoint(in:range.lowerBound..<min(a.count,range.upperBound),reduce:reduce,origin:origin,minimumSpacing:minimumSpacing,emit) }
        if range.upperBound > a.count { b.forEachDisplayPoint(in:max(0,range.lowerBound-a.count)..<(range.upperBound-a.count),reduce:reduce,origin:origin,minimumSpacing:minimumSpacing,emit) }
      case .shifted(let body,let basis):
        let step=basis.step
        body.forEachDisplayPoint(in:range,reduce:reduce,origin:origin,minimumSpacing:minimumSpacing) { x,y,w,o in emit(step.apply(x,step.x),step.apply(y,step.y),w,o) }
      case .repeated(let body,_,let step):
        for q in range.lowerBound/body.count...(range.upperBound-1)/body.count {
          let shift=step.multiplied(by:q)!
          body.forEachDisplayPoint(in:max(0,range.lowerBound-q*body.count)..<min(body.count,range.upperBound-q*body.count),reduce:reduce,origin:origin,minimumSpacing:minimumSpacing) {
            x,y,w,o in emit(shift.apply(x,shift.x),shift.apply(y,shift.y),w,o)
          }
        }
      }
    }
    func allocationSummary(seen: inout Set<ObjectIdentifier>) -> (nodes: Int,bytes: Int) {
      guard seen.insert(ObjectIdentifier(self)).inserted else { return (0,0) }
      var total=(nodes:1,bytes:MemoryLayout<Content>.stride+MemoryLayout<CGRect>.stride+MemoryLayout<Lattice?>.stride*3+48)
      switch content {
      case .block(let b): total.bytes += b.payloadBytes
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
