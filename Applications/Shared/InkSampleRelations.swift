import Foundation
import NotebookCore

/// A derived, immutable description of accepted measurements. No durable format,
/// causal action or independently editable raster lives here. Block identity is
/// physical; event identity remains (action, revision, logical index).
struct InkSampleRelations: Sendable {
  static let blockSize = 256
  final class Header: Sendable {
    let tool: SpatialInkTool
    let color: SpatialInkColor
    let sequence: UInt64
    let isActive: Bool
    let elementTargets: [InkElementTarget]?
    init(tool: SpatialInkTool, color: SpatialInkColor, sequence: UInt64 = 0,
      isActive: Bool = true, elementTargets: [InkElementTarget]? = nil) {
      self.tool=tool;self.color=color;self.sequence=sequence;self.isActive=isActive;self.elementTargets=elementTargets
    }
    func equality(to other: Header) -> InkRelationEquality {
      if self === other { return .equal }
      guard tool == other.tool, color.red.bitPattern == other.color.red.bitPattern,
        color.green.bitPattern == other.color.green.bitPattern, color.blue.bitPattern == other.color.blue.bitPattern,
        sequence == other.sequence, isActive == other.isActive else { return .different }
      // Cuts targeted at existing elements are retained intact, never silently
      // equated through an approximate geometric/Float comparison.
      return elementTargets == nil && other.elementTargets == nil ? .equal : .notProven
    }
  }
  struct Address: Equatable, Sendable { let source: UUID; let revision: UUID; let index: Int }
  enum AccessError: Error { case staleAddress, outsideSource }
  enum Field: Equatable, Sendable {
    case constant(UInt64)
    case progression(InkDyadic, InkDyadic)
    case literal([UInt64])

    init(_ samples: ArraySlice<SpatialInkSample>, field: KeyPath<SpatialInkSample,Double>) {
      let bits = samples.map { $0[keyPath:field].bitPattern }
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
  enum Block: Sendable {
    case literal([SpatialInkSample])
    case fields([Field], Int)
    var count: Int { switch self { case .literal(let a): a.count; case .fields(_,let n): n } }
    init(_ samples: ArraySlice<SpatialInkSample>) {
      // Tiled coordinates are already a relative, exact type. Preserve them as
      // literals until their range proof is implemented, never flatten the tile.
      guard samples.count >= 4, samples.allSatisfy({ $0.worldPoint == nil }) else {
        self = .literal(Array(samples)); return
      }
      let keys: [KeyPath<SpatialInkSample,Double>] = [\.point.x,\.point.y,\.timeOffset,\.width,\.opacity,\.force,\.azimuth,\.altitude]
      let fields = keys.map { key in Field(samples,field:key) }
      let bytes = fields.count * MemoryLayout<Field>.stride + fields.reduce(0) { $0 + $1.payloadBytes }
      self = bytes < samples.count * MemoryLayout<SpatialInkSample>.stride
        ? .fields(fields,samples.count) : .literal(Array(samples))
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
    var isUniformAxisStrip: Bool {
      guard case .fields(let f,let n) = self, n > 4,
        case .constant = f[3], case .constant = f[4] else { return false }
      switch (f[0],f[1]) {
      case (.progression(_,let step),.constant),(.constant,.progression(_,let step)):
        return step.coefficient != 0
      default: return false
      }
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
  }
  let sourceID: UUID
  let header: Header
  let revision: UUID
  let count: Int
  let storage: Storage
  let frames: [InkExactFrame]
  init(sourceID: UUID, revision: UUID, samples: [SpatialInkSample], header: Header) {
    self.sourceID = sourceID; self.header = header; self.revision = revision; count = samples.count; frames = []
    storage = .init(Sequence.from(stride(from:0,to:samples.count,by:Self.blockSize).map {
      Block(samples[$0..<min(samples.count,$0+Self.blockSize)])
    }))
  }
  init(_ action: PageInkAction, revision: UUID) {
    self.init(sourceID:action.id,revision:revision,samples:action.samples,
      header:.init(tool:action.tool,color:action.color,sequence:action.sequence,
        isActive:action.isActive,elementTargets:action.elementTargets))
  }
  /// Full materialization is explicit and paid at the existing persistence/export
  /// boundary. A pose does not rewrite the provenance of accepted measurements.
  func restoredAction() -> PageInkAction {
    .init(id:sourceID,tool:header.tool,color:header.color,samples:decoded(),sequence:header.sequence,
      isActive:header.isActive,elementTargets:header.elementTargets)
  }
  private init(sourceID: UUID, revision: UUID, count: Int, storage: Storage, frames: [InkExactFrame], header: Header) {
    self.sourceID = sourceID; self.revision = revision; self.count = count; self.storage = storage; self.frames = frames; self.header = header
  }
  /// Frames surround the WHOLE source. No measured event may sit between two
  /// entries in this list; separate painted sources keep separate frame scopes.
  /// R2/R6/R7 therefore cannot cancel a drawn loop or cross a paint/erase barrier.
  func transformed(by outer: InkExactFrame) -> Self {
    var next = frames
    if outer != .identity {
      if let inner = next.last, let joined = outer.composed(after:inner) {
        next.removeLast(); if joined != .identity { next.append(joined) }
      } else { next.append(outer) }
    }
    return .init(sourceID:sourceID,revision:revision,count:count,storage:storage,frames:next,header:header)
  }

  /// GPU approximation only. Keeping an ordered exact description is distinct
  /// from reducing its display matrix; failure to compose exactly retains frames.
  var displayAffine: InkAffine {
    var a = InkAffine()
    for frame in frames {
      let x = SIMD4<Float>(Float(frame.a.value),Float(frame.c.value),Float(frame.x.value),0)
      let y = SIMD4<Float>(Float(frame.b.value),Float(frame.d.value),Float(frame.y.value),0)
      a = .init(x:.init(x.x*a.x.x+x.y*a.y.x,x.x*a.x.y+x.y*a.y.y,x.x*a.x.z+x.y*a.y.z+x.z,0),
        y:.init(y.x*a.x.x+y.y*a.y.x,y.x*a.x.y+y.y*a.y.y,y.x*a.x.z+y.y*a.y.z+y.z,0))
    }
    return a
  }
  func address(at index: Int) -> Address { .init(source:sourceID,revision:revision,index:index) }
  func sample(at address: Address) throws -> SpatialInkSample {
    guard address.source == sourceID, address.revision == revision else { throw AccessError.staleAddress }
    guard (0..<count).contains(address.index) else { throw AccessError.outsideSource }
    return sample(at:address.index)
  }
  func sample(at i: Int) -> SpatialInkSample {
    precondition((0..<count).contains(i))
    var cost=AccessCost()
    return storage.root.sample(at:i,cost:&cost)
  }
  /// Only a uniform monotone axis-aligned pen strip is reduced here. Its
  /// interior emits no cap/disk, so opacity does not accumulate per sample.
  /// Eraser disks and every unproved shape retain all events for display.
  func forEachDisplayPoint(in range: Range<Int>? = nil, _ body: (SIMD2<Float>,Float,Float) -> Void) {
    let range=range ?? 0..<count
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    storage.root.forEachDisplayPoint(in:range,reduce:header.tool == .pen) { x,y,width,opacity in
      body(.init(Float(x),Float(y)),Float(width/2),Float(opacity))
    }
  }
  func decoded(in range: Range<Int>? = nil) -> [SpatialInkSample] {
    let range=range ?? 0..<count
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    var output:[SpatialInkSample]=[];output.reserveCapacity(range.count)
    storage.root.appendDecoded(in:range,to:&output)
    return output
  }
  func access(_ address: Address) throws -> (sample: SpatialInkSample,cost: AccessCost) {
    guard address.source == sourceID, address.revision == revision else { throw AccessError.staleAddress }
    guard (0..<count).contains(address.index) else { throw AccessError.outsideSource }
    var cost=AccessCost()
    let value=storage.root.sample(at:address.index,cost:&cost)
    return (value,cost)
  }
  func bounds(in range: Range<Int>) throws -> (bounds: CGRect,cost: AccessCost) {
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
  /// An explicit body-state edit. Changing its exit is distinct from replacing
  /// an emitted measurement; nested repeats inherit this exit, never override it.
  func settingExit(_ exit: InkRepeatStep, revision: UUID) -> Self {
    precondition(revision != self.revision)
    return .init(sourceID:sourceID,revision:revision,count:count,
      storage:.init(storage.root,exit:exit),frames:frames,header:header)
  }
  /// Constructor for a typed, declared repeat. Recognition in measured data is
  /// separate and fully verified (R8). B's exact exit defines jump(B,q,s).
  func repeated(_ repetitions: Int, revision: UUID) -> Self? {
    precondition(revision != self.revision)
    let step=storage.exit
    guard let exit=step.multiplied(by:repetitions),
      let root=Sequence.repeated(storage.root,count:repetitions,step:step) else { return nil }
    return .init(sourceID:sourceID,revision:revision,count:root.count,storage:.init(root,exit:exit),frames:frames,header:header)
  }
  func editing(_ address: Address, to value: SpatialInkSample, revision: UUID) throws -> Self {
    _ = try sample(at:address)
    precondition(revision != self.revision)
    let prefix=storage.root.slice(0..<address.index), suffix=storage.root.slice((address.index+1)..<count)
    let root=Sequence.join(Sequence.join(prefix,Sequence(block:.literal([value]))),suffix)
    return .init(sourceID:sourceID,revision:revision,count:count,storage:.init(root,exit:storage.exit),frames:frames,header:header)
  }
  /// Explicitly change one occurrence's EXIT, not its last measurement. In this
  /// translation-only domain the entire suffix accepts one exact basis change.
  /// Unsupported precision rejects the operation without altering the source.
  func changingRepeatExit(at occurrence: Int, to step: InkRepeatStep, revision: UUID) -> Self? {
    precondition(revision != self.revision)
    guard case .repeated(let body,let n,let oldStep)=storage.root.content,
      (0..<n).contains(occurrence),let delta=step.adding(oldStep.negated),
      let exit=storage.exit.adding(delta) else { return nil }
    let boundary=(occurrence+1)*body.count
    guard let suffix=storage.root.slice(boundary..<count).shifted(delta) else { return nil }
    let root=Sequence.join(storage.root.slice(0..<boundary),suffix)
    return .init(sourceID:sourceID,revision:revision,count:count,storage:.init(root,exit:exit),frames:frames,header:header)
  }
  /// Returns notProven when the caller's explicit comparison budget is exhausted.
  /// No structural hash can turn different encodings into unequal content.
  func equality(to other: Self, eventBudget: Int) -> InkRelationEquality {
    guard sourceID == other.sourceID, revision == other.revision, count == other.count else { return .different }
    let context = header.equality(to:other.header)
    guard context == .equal else { return context }
    guard storage.exit == other.storage.exit else { return .different }
    guard frames == other.frames else { return .notProven }
    if storage === other.storage { return .equal }
    let n = min(count,max(0,eventBudget))
    for i in 0..<n where !Self.sameBits(sample(at:i),other.sample(at:i)) { return .different }
    return n == count ? .equal : .notProven
  }
  static func sameBits(_ a: SpatialInkSample, _ b: SpatialInkSample) -> Bool {
    let fields: [KeyPath<SpatialInkSample,Double>] = [\.point.x,\.point.y,\.timeOffset,\.width,\.opacity,\.force,\.azimuth,\.altitude]
    guard fields.allSatisfy({ a[keyPath:$0].bitPattern == b[keyPath:$0].bitPattern }) else { return false }
    switch (a.worldPoint,b.worldPoint) {
    case (nil,nil): return true
    case (.some(let x),.some(let y)):
      return x.tileX == y.tileX && x.tileY == y.tileY && x.localX.bitPattern == y.localX.bitPattern && x.localY.bitPattern == y.localY.bitPattern
    default: return false
    }
  }
  var allocationSummary: (nodes: Int, bytes: Int) {
    var seen=Set<ObjectIdentifier>()
    return storage.root.allocationSummary(seen:&seen)
  }
  var payloadBytes: Int {
    MemoryLayout<Self>.stride + frames.count * MemoryLayout<InkExactFrame>.stride + allocationSummary.bytes
  }
}
