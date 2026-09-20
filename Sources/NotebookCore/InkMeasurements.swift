import Foundation

/// The accepted body of an ink action/span. It owns the same immutable relation
/// tree used by contact, editing and display, never a parallel flat sample array.
/// Action identity, tool, color and activity belong to the enclosing journal.
public struct InkMeasurements: RandomAccessCollection, ExpressibleByArrayLiteral, Equatable, Sendable {
  public typealias Index = Int
  public typealias Element = SpatialInkSample
  let storage: InkSampleRelations.Storage
  public let revision: UUID
  public var startIndex: Int { 0 }
  public var endIndex: Int { storage.root.count }
  public var count: Int { endIndex }
  public func index(after i: Int) -> Int { i+1 }
  public func index(before i: Int) -> Int { i-1 }
  public subscript(i: Int) -> SpatialInkSample {
    precondition((0..<count).contains(i))
    var cost=InkSampleRelations.AccessCost();return storage.root.sample(at:i,cost:&cost)
  }
  public init(arrayLiteral elements: SpatialInkSample...) { self.init(elements) }
  public init(_ samples: [SpatialInkSample], revision: UUID = UUID(uuid:(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) {
    precondition(samples.allSatisfy(\.isValid))
    if samples.isEmpty { storage = .init(.empty) }
    else {
      let buffer=InkSampleRelations.SampleBuffer(samples)
      if samples.count <= InkSampleRelations.blockSize {
        storage = .init(.init(block:.init(.init(buffer:buffer,range:samples.indices))))
      } else {
        var blocks: [InkSampleRelations.Block] = stride(from:0,to:samples.count,by:InkSampleRelations.blockSize).map {
          .init(.init(buffer:buffer,range:$0..<Swift.min(samples.count,$0+InkSampleRelations.blockSize)))
        }
        let literalCount=blocks.reduce(0) { count,block in
          if case .literal(let view)=block { return count+view.count };return count
        }
        if literalCount > 0,literalCount < samples.count {
          // A short residual must not pin the entire pre-compression array.
          // All residual leaves still share ONE immutable literal buffer.
          var residuals: [SpatialInkSample]=[];residuals.reserveCapacity(literalCount)
          for case .literal(let view) in blocks { residuals.append(contentsOf:view.values) }
          let retained=InkSampleRelations.SampleBuffer(residuals)
          var offset=0
          for i in blocks.indices {
            if case .literal(let view)=blocks[i] {
              blocks[i] = .literal(.init(buffer:retained,range:offset..<(offset+view.count)));offset += view.count
            }
          }
        }
        storage = .init(.from(blocks))
      }
    }
    self.revision=revision
  }
  init(storage: InkSampleRelations.Storage, revision: UUID) {
    self.storage=storage;self.revision=revision
  }
  public var isPaper: Bool { storage.root.worldEvents == 0 }
  public var isWorld: Bool { storage.root.worldEvents == count }
  public var hasVisibleInk: Bool { storage.root.hasVisibleInk }
  public var payloadBytes: Int {
    var seen=Set<ObjectIdentifier>()
    return MemoryLayout<Self>.stride+storage.byteCount+storage.root.allocationSummary(seen:&seen).bytes
  }
  public func materialized(in range: Range<Int>? = nil) -> [SpatialInkSample] {
    let range=range ?? 0..<count
    precondition(range.lowerBound >= 0 && range.upperBound <= count)
    var result:[SpatialInkSample]=[];result.reserveCapacity(range.count)
    storage.root.forEachSample(in:range) { result.append($0) };return result
  }
  public struct Iterator: IteratorProtocol {
    let source: InkMeasurements
    var nextIndex=0,offset=0
    var leaf:[SpatialInkSample]=[]
    public mutating func next() -> SpatialInkSample? {
      if offset == leaf.count {
        guard nextIndex < source.count else { return nil }
        let end=Swift.min(source.count,nextIndex+InkSampleRelations.blockSize)
        leaf.removeAll(keepingCapacity:true)
        source.storage.root.forEachSample(in:nextIndex..<end) { leaf.append($0) }
        nextIndex=end;offset=0
      }
      defer { offset += 1 };return leaf[offset]
    }
  }
  public func makeIterator() -> Iterator { .init(source:self) }
  public static func == (a: Self,b: Self) -> Bool {
    guard a.count == b.count,a.storage.exit == b.storage.exit else { return false }
    if a.storage.root === b.storage.root { return true }
    if a.storage.root.sameRepresentation(as:b.storage.root) { return true }
    return zip(a,b).allSatisfy(InkSampleRelations.sameBits)
  }
}

extension InkSampleRelations.Sequence {
  /// Exact structural proof visits shared bodies once. Different encodings are
  /// not declared unequal here; the caller can compare their emitted events.
  func sameRepresentation(as other: InkSampleRelations.Sequence) -> Bool {
    struct Pair: Hashable { let a:ObjectIdentifier,b:ObjectIdentifier }
    var seen=Set<Pair>()
    func equal(_ a:InkSampleRelations.Sequence,_ b:InkSampleRelations.Sequence) -> Bool {
      if a === b { return true }
      guard a.count == b.count else { return false }
      let pair=Pair(a:ObjectIdentifier(a),b:ObjectIdentifier(b))
      if seen.contains(pair) { return true }
      let same:Bool
      switch (a.content,b.content) {
      case (.block(.fields(let a,let n)),.block(.fields(let b,let m))): same=n == m && a == b
      case (.block(.literal(let a)),.block(.literal(let b))):
        same=a.count == b.count && zip(a.values,b.values).allSatisfy(InkSampleRelations.sameBits)
      case (.pair(let a,let b),.pair(let c,let d)): same=equal(a,c) && equal(b,d)
      case (.repeated(let a,let n,let s),.repeated(let b,let m,let t)): same=n == m && s == t && equal(a,b)
      case (.shifted(let a,let s),.shifted(let b,let t)): same=s.step == t.step && equal(a,b)
      default: same=false
      }
      if same { seen.insert(pair) };return same
    }
    return equal(self,other)
  }
}
