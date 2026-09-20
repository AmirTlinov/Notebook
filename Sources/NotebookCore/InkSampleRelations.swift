import Foundation

/// Immutable accepted measurements and their exact ordered relations. Core owns
/// the source and its codec; display projections never become editable content.
/// Event identity remains (action, original span, revision, logical index).
public struct InkSampleRelations: Sendable {
  public struct RewriteWork: Sendable {
    public var remaining: Int
    public var spent=0, reductions=0, scannedEvents=0, comparedEvents=0, propagatedEvents=0, visitedNodes=0
    public var rules: UInt8=0
    public var deferred=false
    public init(_ limit: Int = 8192) { remaining=max(0,limit) }
    public mutating func spend(_ units: Int) -> Bool {
      guard units <= remaining else { deferred=true;return false }
      remaining -= units;spent += units;return true
    }
    public mutating func applied(_ rule: Int) { reductions += 1;rules |= 1 << (rule-1) }
  }
  public struct EditSummary: Sendable {
    public let affectedEvents: Range<Int>
    public let oldBounds: CGRect, newBounds: CGRect
    public let geometryChanged: Bool, exitChanged: Bool
    public let work: RewriteWork
  }
  public let lastEdit: EditSummary?
  static let blockSize = 256
  public final class Header: Sendable {
    public let tool: SpatialInkTool
    public let color: SpatialInkColor
    public let sequence: UInt64
    public let isActive: Bool
    public let elementTargets: [InkElementTarget]?
    public init(tool: SpatialInkTool, color: SpatialInkColor, sequence: UInt64 = 0,
      isActive: Bool = true, elementTargets: [InkElementTarget]? = nil) {
      self.tool=tool;self.color=color;self.sequence=sequence;self.isActive=isActive;self.elementTargets=elementTargets
    }
    public func equality(to other: Header) -> InkRelationEquality {
      if self === other { return .equal }
      guard tool == other.tool, color.red.bitPattern == other.color.red.bitPattern,
        color.green.bitPattern == other.color.green.bitPattern, color.blue.bitPattern == other.color.blue.bitPattern,
        sequence == other.sequence, isActive == other.isActive else { return .different }
      // Cuts targeted at existing elements are retained intact, never silently
      // equated through an approximate geometric/Float comparison.
      return elementTargets == nil && other.elementTargets == nil ? .equal : .notProven
    }
  }
  public struct Address: Equatable, Sendable {
    public let source: UUID, span: Int, revision: UUID, index: Int
  }
  public enum AccessError: Error { case staleAddress, outsideSource, unsupportedExactTranslation }
  enum Field: Equatable, Sendable {
    case constant(UInt64)
    case progression(InkDyadic, InkDyadic)
    case literal([UInt64])

    init(_ bits: [UInt64]) {
      if bits.allSatisfy({ $0 == bits[0] }) { self = .constant(bits[0]); return }
      if bits.count > 2, let start = InkDyadic(Double(bitPattern:bits[0])), let next = InkDyadic(Double(bitPattern:bits[1])),
        let step = next.adding(start.negated), bits.indices.allSatisfy({ i in
          guard let delta = step.multiplied(by:i), let value = start.adding(delta) else { return false }
          return value.value.bitPattern == bits[i]
        }) {
        self = .progression(start,step)
      } else { self = .literal(bits) }
    }
    func value(at i: Int) -> Double {
      switch self {
      case .constant(let bits): return Double(bitPattern:bits)
      case .progression(let start,let step): return start.adding(step.multiplied(by:i)!)!.value
      case .literal(let bits): return Double(bitPattern:bits[i])
      }
    }
    var payloadBytes: Int { if case .literal(let bits) = self { return bits.count * 8 }; return 0 }
  }
  /// Canonical arrays are immutable COW buffers. Literal blocks share one
  /// buffer instead of making another copy of incompressible measurements.
  final class SampleBuffer: Sendable {
    let samples: [SpatialInkSample]
    init(_ samples: [SpatialInkSample]) { self.samples=samples }
    var byteCount: Int { 64+samples.capacity*MemoryLayout<SpatialInkSample>.stride }
  }
  struct Samples: Sendable {
    let buffer: SampleBuffer
    let range: Range<Int>
    init(_ samples: [SpatialInkSample]) { buffer = .init(samples);range=0..<samples.count }
    init(buffer: SampleBuffer,range: Range<Int>) { self.buffer=buffer;self.range=range }
    var values: ArraySlice<SpatialInkSample> { buffer.samples[range] }
    var count: Int { range.count }
    subscript(_ index: Int) -> SpatialInkSample { buffer.samples[range.lowerBound+index] }
  }
  enum Block: Sendable {
    case literal(Samples)
    case fields([Field], Int)
    var count: Int { switch self { case .literal(let a): a.count; case .fields(_,let n): n } }
    init(_ samples: ArraySlice<SpatialInkSample>) { self.init(Samples(Array(samples))) }
    init(_ view: Samples) {
      let samples=view.values
      // Tiled coordinates are already a relative, exact type. Preserve them as
      // literals until their range proof is implemented, never flatten the tile.
      guard samples.count >= 4, samples.allSatisfy({ $0.worldPoint == nil }) else {
        self = .literal(view); return
      }
      // Direct field access avoids dynamic key-path traversal for every event
      // in this cold path. The exact recognition/proof remains field-local.
      let x=Field(samples.map { $0.point.x.bitPattern }),y=Field(samples.map { $0.point.y.bitPattern })
      let fields: [Field] = [x,y,
        .init(samples.map { $0.timeOffset.bitPattern }), .init(samples.map { $0.width.bitPattern }),
        .init(samples.map { $0.opacity.bitPattern }), .init(samples.map { $0.force.bitPattern }),
        .init(samples.map { $0.azimuth.bitPattern }), .init(samples.map { $0.altitude.bitPattern })]

      let bytes = fields.count * MemoryLayout<Field>.stride + fields.reduce(0) { $0 + $1.payloadBytes }
      self = bytes < samples.count * MemoryLayout<SpatialInkSample>.stride ? .fields(fields,samples.count) : .literal(view)
    }
    func sample(at i: Int) -> SpatialInkSample {
      switch self {
      case .literal(let a): return a[i]
      case .fields(let f,_):
        return .init(point:.init(x:f[0].value(at:i),y:f[1].value(at:i)),timeOffset:f[2].value(at:i),
          width:f[3].value(at:i),opacity:f[4].value(at:i),force:f[5].value(at:i),
          azimuth:f[6].value(at:i),altitude:f[7].value(at:i))
      }
    }
    /// Bounds need only position and width, not time/pressure/orientation. A
    /// verified affine field has its extrema at the range endpoints; width's
    /// minimum-radius clamp keeps the left/top concave and right/bottom convex.
    func bounds(in range: Range<Int>,cost: inout AccessCost) -> CGRect {
      if range.isEmpty { return .null }
      switch self {
      case .literal(let samples):
        var result=CGRect.null
        for i in range {
          let p=samples[i];cost.decodedSamples += 1
          guard p.worldPoint == nil else { return .infinite }
          result=result.union(Sequence.pointBounds(p.point.x,p.point.y,p.width))
        }
        return result
      case .fields(let fields,_):
        let affine=[0,1,3].allSatisfy { if case .literal=fields[$0] { return false };return true }
        let indices=affine ? [range.lowerBound,range.upperBound-1] : Array(range)
        var result=CGRect.null
        for i in indices {
          cost.decodedSamples += 1
          result=result.union(Sequence.pointBounds(fields[0].value(at:i),fields[1].value(at:i),fields[3].value(at:i)))
        }
        return result
      }
    }
    var hasGenerator: Bool {
      guard case .fields(let fields,_)=self else { return false }
      return fields.contains { if case .literal=$0 { return false };return true }
    }
    var payloadBytes: Int {
      switch self {
      case .literal(let a): return a.count * MemoryLayout<SpatialInkSample>.stride
      case .fields(let f,_): return f.count * MemoryLayout<Field>.stride + f.reduce(0) { $0 + $1.payloadBytes }
      }
    }
  }
  final class Storage: Sendable {
    let root: Sequence
    /// Exit of the typed translation state, independent of the last emitted
    /// measurement. Empty event bodies may still carry a nonzero exit.
    let exit: InkRepeatStep
    init(_ root: Sequence, exit: InkRepeatStep = .zero) { self.root=root;self.exit=exit }
    var byteCount: Int { MemoryLayout<InkRepeatStep>.stride+32 }
  }
  public let sourceID: UUID
  public let span: Int
  public let header: Header
  public let measurements: InkMeasurements
  public var revision: UUID { measurements.revision }
  public var count: Int { measurements.count }
  var storage: Storage { measurements.storage }
  public var geometry: Geometry { storage.root.geometry }
  public func forEachSample(in range: Range<Int>, _ emit: (SpatialInkSample) -> Void) {
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    storage.root.forEachSample(in: range, emit)
  }
  public let frames: [InkExactFrame]
  public init(sourceID: UUID, span: Int = 0, revision: UUID, samples: [SpatialInkSample], header: Header) {
    self.init(sourceID:sourceID,span:span,measurements:.init(samples,revision:revision),header:header)
  }
  public init(sourceID: UUID, span: Int = 0, measurements: InkMeasurements, frames: [InkExactFrame] = [], header: Header) {
    self.sourceID=sourceID;self.span=span;self.measurements=measurements;self.header=header;self.frames=frames;lastEdit=nil
  }
  public init(_ action: PageInkAction) {
    self.init(sourceID:action.id,measurements:action.samples,
      header:.init(tool:action.tool,color:action.color,sequence:action.sequence,
        isActive:action.isActive,elementTargets:action.elementTargets))
  }
  public func restoredAction() -> PageInkAction {
    // Journal actions own local measurements. Whole placement belongs to the
    // existing graphic/group owner, not a second pose hidden inside ink data.
    precondition(frames.isEmpty, "Persist the enclosing whole, not a flattened placed action")
    return .init(id:sourceID,tool:header.tool,color:header.color,measurements:measurements,sequence:header.sequence,
      isActive:header.isActive,elementTargets:header.elementTargets)
  }
  init(sourceID: UUID, span: Int, revision: UUID, count: Int, storage: Storage, frames: [InkExactFrame], header: Header, lastEdit: EditSummary? = nil) {
    precondition(count == storage.root.count)
    self.lastEdit=lastEdit
    self.sourceID=sourceID;self.span=span;self.header=header;self.frames=frames
    measurements = .init(storage:storage,revision:revision)
  }
  /// Frames surround the WHOLE source. No measured event may sit between two
  /// entries in this list; separate painted sources keep separate frame scopes.
  /// R2/R6/R7 therefore cannot cancel a drawn loop or cross a paint/erase barrier.
  public func transformed(by outer: InkExactFrame) -> Self {
    var next = frames
    if outer != .identity {
      if let inner = next.last, let joined = outer.composed(after:inner) {
        next.removeLast(); if joined != .identity { next.append(joined) }
      } else { next.append(outer) }
    }
    return .init(sourceID:sourceID,span:span,revision:revision,count:count,storage:storage,frames:next,header:header)
  }

  public func address(at index: Int) -> Address { .init(source:sourceID,span:span,revision:revision,index:index) }
  public func sample(at address: Address) throws -> SpatialInkSample {
    guard address.source == sourceID, address.span == span, address.revision == revision else { throw AccessError.staleAddress }
    guard (0..<count).contains(address.index) else { throw AccessError.outsideSource }
    return sample(at:address.index)
  }
  public func sample(at i: Int) -> SpatialInkSample {
    precondition((0..<count).contains(i))
    var cost=AccessCost()
    return storage.root.sample(at:i,cost:&cost)
  }
  /// Only a uniform monotone axis-aligned pen strip is reduced here. Its
  /// interior emits no cap/disk, so opacity does not accumulate per sample.
  /// Eraser disks and every unproved shape retain all events for display.
  public func forEachDisplayPoint(in range: Range<Int>? = nil, origin: WorldPoint? = nil,
    offset: SpatialPoint = .zero, scale: Double = 1, _ body: (SIMD2<Float>,Float,Float) -> Void) {
    forEachIndexedDisplayPoint(in:range,origin:origin,offset:offset,scale:scale) { _,p,r,a in body(p,r,a) }
  }
  public func forEachIndexedDisplayPoint(in range: Range<Int>? = nil,origin: WorldPoint? = nil,
    offset: SpatialPoint = .zero,scale: Double = 1,_ body: (Int,SIMD2<Float>,Float,Float)->Void) {
    let range=range ?? 0..<count
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    // Reduction must not skip samples that the shared Float normalizer would
    // coalesce. Its threshold lives with that normalizer. Bound Float rounding
    // over the whole projected source, including repeated/shifted ranges.
    let box=storage.root.bounds
    let magnitude=[box.minX*scale+offset.x,box.maxX*scale+offset.x,
      box.minY*scale+offset.y,box.maxY*scale+offset.y].map { abs(Float($0)) }.max() ?? .infinity
    let spacing=(Double(InkStrokeGeometry.minimumDistanceSquared.squareRoot())+2*Double(magnitude.ulp))/abs(scale)
    storage.root.forEachDisplayPoint(in:range,reduce:header.tool == .pen,origin:origin,minimumSpacing:spacing,
      maximumSpan:Double(Float.greatestFiniteMagnitude.squareRoot())/4/abs(scale)) { index,x,y,width,opacity in
      body(index,.init(Float(x*scale+offset.x),Float(y*scale+offset.y)),Float(width*scale/2),Float(opacity))
    }
  }
  public func decoded(in range: Range<Int>? = nil) -> [SpatialInkSample] {
    let range=range ?? 0..<count
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    var output:[SpatialInkSample]=[];output.reserveCapacity(range.count)
    storage.root.forEachSample(in:range) { output.append($0) }
    return output
  }
  public func access(_ address: Address) throws -> (sample: SpatialInkSample,cost: AccessCost) {
    guard address.source == sourceID, address.span == span, address.revision == revision else { throw AccessError.staleAddress }
    guard (0..<count).contains(address.index) else { throw AccessError.outsideSource }
    var cost=AccessCost()
    let value=storage.root.sample(at:address.index,cost:&cost)
    return (value,cost)
  }
  public func bounds(in range: Range<Int>) throws -> (bounds: CGRect,cost: AccessCost) {
    guard range.lowerBound >= 0,range.upperBound <= count else { throw AccessError.outsideSource }
    var cost=AccessCost()
    let bounds=storage.root.bounds(in:range,cost:&cost)
    guard !bounds.isNull else { return (bounds,cost) }
    // Projection to Float is display-only, but range rejection must still
    // enclose its rounding after a distant repeated translation. Screen AA and
    // the whole-object transform remain the caller's projection responsibility.
    let quantum=[bounds.minX,bounds.minY,bounds.maxX,bounds.maxY].map { Double(Float($0).ulp) }.max()!
    return (quantum.isFinite ? bounds.insetBy(dx:-8*quantum,dy:-8*quantum) : .infinite,cost)
  }
  /// Shared range traversal for display and tools. Virtual segments overlap at
  /// their endpoint so a crossing between two measurements cannot disappear.
  /// No per-segment index or expanded repeated body is constructed.
  public func querySegments(maximumSegments: Int,
    intersecting overlaps: (CGRect) -> Bool
  ) throws -> (segments: [Int],cost: AccessCost) {
    precondition(maximumSegments > 0)
    guard count > 0 else { return ([],.init()) }
    let segments=max(1,(count-2)/maximumSegments+1)
    var selected:[Int]=[],cost=AccessCost()
    func visit(_ range: Range<Int>) throws {
      try Task.checkCancellation()
      let lower=range.lowerBound*maximumSegments
      let upper=range.upperBound == segments ? count : range.upperBound*maximumSegments+1
      let result=try bounds(in:lower..<upper)
      cost.visitedNodes += result.cost.visitedNodes;cost.jumps += result.cost.jumps;cost.decodedSamples += result.cost.decodedSamples
      guard overlaps(result.bounds) else { return }
      if range.count == 1 { selected.append(range.lowerBound);return }
      let mid=range.lowerBound+range.count/2
      try visit(range.lowerBound..<mid);try visit(mid..<range.upperBound)
    }
    try visit(0..<segments)
    return (selected,cost)
  }
  /// An explicit body-state edit. Changing its exit is distinct from replacing
  /// an emitted measurement; nested repeats inherit this exit, never override it.
  public func settingExit(_ exit: InkRepeatStep, revision: UUID) -> Self {
    precondition(revision != self.revision)
    return .init(sourceID:sourceID,span:span,revision:revision,count:count,
      storage:.init(storage.root,exit:exit),frames:frames,header:header)
  }
  /// Constructor for a typed, declared repeat. Recognition in measured data is
  /// separate and fully verified (R8). B's exact exit defines jump(B,q,s).
  public func repeated(_ repetitions: Int, revision: UUID) -> Self? {
    precondition(revision != self.revision)
    let step=storage.exit
    guard let exit=step.multiplied(by:repetitions),
      let root=Sequence.repeated(storage.root,count:repetitions,step:step) else { return nil }
    return .init(sourceID:sourceID,span:span,revision:revision,count:root.count,storage:.init(root,exit:exit),frames:frames,header:header)
  }
  public func editing(_ address: Address, to value: SpatialInkSample, revision: UUID, normalizationBudget: Int = 8192) throws -> Self {
    _ = try sample(at:address)
    precondition(revision != self.revision)
    var work=RewriteWork(normalizationBudget)
    let root=storage.root.edited(at:address.index,to:value,work:&work)
    let range=max(0,address.index-1)..<min(count,address.index+2)
    return editedSource(root,exit:storage.exit,revision:revision,range:range,geometryChanged:true,work:work)
  }
  /// The selected body's changed output is an explicit delta at its logical
  /// boundary. This remains addressable after earlier edits/normalization; it
  /// does not depend on the root still being encoded as one Repeat node.
  public func propagatingExitDelta(_ delta: InkRepeatStep, from address: Address, revision: UUID,
    normalizationBudget: Int = 8192) throws -> Self {
    guard address.source == sourceID,address.span == span,address.revision == self.revision else { throw AccessError.staleAddress }
    guard (0...count).contains(address.index) else { throw AccessError.outsideSource }
    precondition(revision != self.revision)
    var work=RewriteWork(normalizationBudget)
    guard let exit=storage.exit.adding(delta),
      let suffix=storage.root.slice(address.index..<count).translated(delta,work:&work) else {
      throw AccessError.unsupportedExactTranslation
    }
    let root=Sequence.join(storage.root.slice(0..<address.index),suffix,work:&work)
    let geometryChanged=delta.x != .zero || delta.y != .zero
    let range=geometryChanged ? max(0,address.index-1)..<count : address.index..<address.index
    return editedSource(root,exit:exit,revision:revision,range:range,geometryChanged:geometryChanged,work:work)
  }
  private func editedSource(_ root: Sequence,exit: InkRepeatStep,revision: UUID,range: Range<Int>,
    geometryChanged: Bool,work: RewriteWork) -> Self {
    let result=Self(sourceID:sourceID,span:span,revision:revision,count:count,storage:.init(root,exit:exit),frames:frames,header:header)
    let old=try! bounds(in:range).bounds,new=try! result.bounds(in:range).bounds
    let summary=EditSummary(affectedEvents:range,oldBounds:old,newBounds:new,geometryChanged:geometryChanged,
      exitChanged:exit != storage.exit,work:work)
    return .init(sourceID:sourceID,span:span,revision:revision,count:count,storage:result.storage,frames:frames,header:header,lastEdit:summary)
  }
  public func normalizingPending(budget: Int) -> Self {
    var work=RewriteWork(budget)
    let root=storage.root.normalized(work:&work)
    let summary=EditSummary(affectedEvents:0..<0,oldBounds:.null,newBounds:.null,geometryChanged:false,exitChanged:false,work:work)
    return .init(sourceID:sourceID,span:span,revision:revision,count:count,storage:.init(root,exit:storage.exit),frames:frames,header:header,lastEdit:summary)
  }
  /// Returns notProven when the caller's explicit comparison budget is exhausted.
  /// No structural hash can turn different encodings into unequal content.
  public func equality(to other: Self, eventBudget: Int) -> InkRelationEquality {
    guard sourceID == other.sourceID, span == other.span, revision == other.revision, count == other.count else { return .different }
    let context = header.equality(to:other.header)
    guard context == .equal else { return context }
    guard storage.exit == other.storage.exit else { return .different }
    guard frames == other.frames else { return .notProven }
    if storage.root === other.storage.root { return .equal }
    let n = min(count,max(0,eventBudget))
    for i in 0..<n where !Self.sameBits(sample(at:i),other.sample(at:i)) { return .different }
    return n == count ? .equal : .notProven
  }
  public static func sameBits(_ a: SpatialInkSample, _ b: SpatialInkSample) -> Bool {
    let fields: [KeyPath<SpatialInkSample,Double>] = [\.point.x,\.point.y,\.timeOffset,\.width,\.opacity,\.force,\.azimuth,\.altitude]
    guard fields.allSatisfy({ a[keyPath:$0].bitPattern == b[keyPath:$0].bitPattern }) else { return false }
    switch (a.worldPoint,b.worldPoint) {
    case (nil,nil): return true
    case (.some(let x),.some(let y)):
      return x.tileX == y.tileX && x.tileY == y.tileY && x.localX.bitPattern == y.localX.bitPattern && x.localY.bitPattern == y.localY.bitPattern
    default: return false
    }
  }
  public var allocationSummary: (nodes: Int, bytes: Int) {
    var seen=Set<ObjectIdentifier>()
    let tree=storage.root.allocationSummary(seen:&seen)
    return (tree.nodes,storage.byteCount+tree.bytes)
  }
  public var payloadBytes: Int {
    MemoryLayout<Self>.stride + frames.count * MemoryLayout<InkExactFrame>.stride + allocationSummary.bytes
  }
  /// Extra binding retained beside the canonical body; that body is counted
  /// once by its journal, not again by every display view that borrows it.
  public var auxiliaryBytes: Int { MemoryLayout<Self>.stride+frames.count*MemoryLayout<InkExactFrame>.stride }

}


extension InkSampleRelations {
  /// The sole accepted-event buffer while a contact is moving. Sealed blocks
  /// share the immutable sequence; only the <=256-event tail stays mutable.
  /// Predictions never enter this owner. Freezing/export is explicit.
  public struct Contact: Sendable {
    public let sourceID: UUID
    public let span: Int
    public let header: Header
    public private(set) var revision=UUID()
    private var prefix=Sequence.empty
    private var tail: [SpatialInkSample]=[]
    public private(set) var preparedEventCount=0
    public var count: Int { prefix.count+tail.count }
    public init(sourceID: UUID = UUID(),span: Int = 0,header: Header) {
      self.sourceID=sourceID;self.span=span;self.header=header
    }
    public mutating func replaceTail(from start: Int,with samples: [SpatialInkSample]) {
      precondition((0...count).contains(start))
      preparedEventCount=0
      if start < prefix.count {
        let end=start/blockSize*blockSize
        tail=[]
        prefix.forEachSample(in:end..<start) { tail.append($0) }
        prefix=prefix.slice(0..<end)
      } else { tail.removeSubrange((start-prefix.count)...) }
      var offset=0
      while offset < samples.count {
        let end=min(samples.count,offset+blockSize-tail.count)
        tail.append(contentsOf:samples[offset..<end]);offset=end
        if tail.count == blockSize {
          prefix=Sequence.balance(prefix,Sequence(block:Block(tail[...])))
          preparedEventCount += tail.count
          tail.removeAll(keepingCapacity:true)
        }
      }
      revision=UUID()
    }
    public func sample(at index: Int) -> SpatialInkSample {
      precondition((0..<count).contains(index))
      if index >= prefix.count { return tail[index-prefix.count] }
      var cost=AccessCost();return prefix.sample(at:index,cost:&cost)
    }
    public func forEach(in range: Range<Int>,_ emit: (SpatialInkSample)->Void) {
      precondition(range.lowerBound >= 0 && range.upperBound <= count)
      if range.lowerBound < prefix.count { prefix.forEachSample(in:range.lowerBound..<min(prefix.count,range.upperBound),emit) }
      if range.upperBound > prefix.count {
        for i in max(0,range.lowerBound-prefix.count)..<(range.upperBound-prefix.count) { emit(tail[i]) }
      }
    }
    public func decoded(in range: Range<Int>? = nil) -> [SpatialInkSample] {
      let range=range ?? 0..<count
      var result:[SpatialInkSample]=[];result.reserveCapacity(range.count)
      forEach(in:range) { result.append($0) };return result
    }
    public func frozen(through end: Int? = nil) -> InkSampleRelations {
      let end=end ?? count
      precondition((0...count).contains(end))
      let whole=tail.isEmpty ? prefix : Sequence.balance(prefix,Sequence(block:Block(tail[...])))
      let root=end == count ? whole : whole.slice(0..<end)
      return .init(sourceID:sourceID,span:span,revision:revision,count:end,
        storage:.init(root),frames:[],header:header)
    }
  }
}
