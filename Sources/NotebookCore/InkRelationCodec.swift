import Foundation

/// A bounded postorder graph: an edge can only name an earlier node. Shared
/// repeat bodies are written once; no logical repeat is expanded by this codec.
/// IEEE fields are bytes, including signed zero, not JSON's numeric transport.
extension InkSampleRelations: Codable {
  public enum CodingError: Error { case invalidSource, limitExceeded }
  private static let signature = Data("NIR1".utf8)
  fileprivate static let maximumBytes = 128 * 1024 * 1024
  private static let maximumNodes = 65_536
  private static let maximumEvents = 1_000_000
  private static let maximumDepth = 128

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(encodedRelations())
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(encodedRelations: container.decode(Data.self))
  }

  public func encodedRelations() throws -> Data {
    guard count <= Self.maximumEvents, span >= 0, span <= Self.maximumEvents,
      frames.count <= Self.maximumNodes, header.sequence <= VersionStamp.maximumCounter,
      header.color.isValid, header.elementTargets?.allSatisfy(\.isValid) ?? true,
      header.elementTargets == nil || header.tool == .eraser else { throw CodingError.invalidSource }
    var out = InkRelationWriter(data: Self.signature)
    out.uuid(sourceID); out.integer(UInt32(span))
    out.byte(header.tool == .pen ? 0 : 1)
    for value in [header.color.red, header.color.green, header.color.blue] { out.double(value) }
    out.integer(header.sequence); out.byte(header.isActive ? 1 : 0)
    let targets = header.elementTargets ?? []
    guard targets.count <= Self.maximumNodes, Set(targets.map(\.elementID)).count == targets.count else { throw CodingError.invalidSource }
    out.byte(header.elementTargets == nil ? 0 : 1); out.integer(UInt32(targets.count))
    for target in targets {
      try out.target(target)
      guard out.data.count <= Self.maximumBytes else { throw CodingError.limitExceeded }
    }
    out.integer(UInt32(frames.count))
    for f in frames { for d in [f.a,f.b,f.c,f.d,f.x,f.y] { out.dyadic(d) } }
    try Self.encodeMeasurements(measurements,into:&out)
    return out.data
  }

  fileprivate static func encodeMeasurements(_ value: InkMeasurements, into out: inout InkRelationWriter) throws {
    guard value.count <= maximumEvents else { throw CodingError.limitExceeded }
    var nodes: [Sequence] = [], indexes: [ObjectIdentifier: Int] = [:], depth: [ObjectIdentifier: Int] = [:]
    func visit(_ node: Sequence, at nesting: Int = 1) throws {
      guard nesting <= Self.maximumDepth else { throw CodingError.limitExceeded }
      let key = ObjectIdentifier(node)
      if indexes[key] != nil { return }
      let children: [Sequence]
      switch node.content {
      case .block: children = []
      case .pair(let a, let b): children = [a,b]
      case .repeated(let body, _, _), .shifted(let body, _): children = [body]
      }
      for child in children { try visit(child, at: nesting + 1) }
      let level = 1 + (children.map { depth[ObjectIdentifier($0)]! }.max() ?? 0)
      guard level <= Self.maximumDepth, nodes.count < Self.maximumNodes else { throw CodingError.limitExceeded }
      depth[key] = level; indexes[key] = nodes.count; nodes.append(node)
    }
    try visit(value.storage.root)
    out.uuid(value.revision)
    out.step(value.storage.exit)
    out.integer(UInt32(nodes.count))
    for node in nodes {
      out.byte(node.pending ? 1 : 0)
      switch node.content {
      case .block(let block):
        guard block.count <= Self.blockSize else { throw CodingError.invalidSource }
        switch block {
        case .literal(let samples):
          out.byte(0); out.integer(UInt32(samples.count))
          for sample in samples.values { guard sample.isValid else { throw CodingError.invalidSource }; out.sample(sample) }
        case .fields(let fields, let count):
          guard Self.valid(fields: fields, count: count) else { throw CodingError.invalidSource }
          out.byte(1); out.integer(UInt32(count))
          for field in fields {
            switch field {
            case .constant(let bits): out.byte(0); out.integer(bits)
            case .progression(let start, let step): out.byte(1); out.dyadic(start); out.dyadic(step)
            case .literal(let bits):
              guard bits.count == count else { throw CodingError.invalidSource }
              out.byte(2); for value in bits { out.integer(value) }
            }
          }
        }
      case .pair(let a, let b):
        out.byte(2); out.integer(UInt32(indexes[ObjectIdentifier(a)]!)); out.integer(UInt32(indexes[ObjectIdentifier(b)]!))
      case .repeated(let body, let n, let step):
        guard n <= Self.maximumEvents else { throw CodingError.limitExceeded }
        out.byte(3); out.integer(UInt32(indexes[ObjectIdentifier(body)]!)); out.integer(UInt32(n)); out.step(step)
      case .shifted(let body, let basis):
        out.byte(4); out.integer(UInt32(indexes[ObjectIdentifier(body)]!)); out.uuid(basis.origin); out.step(basis.step)
      }
      guard out.data.count <= Self.maximumBytes else { throw CodingError.limitExceeded }
    }
  }

  /// Prove affine leaves on their common binary lattice, without walking the
  /// generated events. Only irreducible literal fields need a scalar scan.
  private static func valid(fields: [Field], count: Int) -> Bool {
    guard fields.count == 8, (1...blockSize).contains(count) else { return false }
    for (index, field) in fields.enumerated() {
      let low: Double, high: Double
      switch field {
      case .constant(let bits): low=Double(bitPattern:bits);high=low
      case .literal(let bits):
        guard bits.count == count else { return false }
        var a=Double.infinity,b = -Double.infinity
        for bits in bits {
          let x=Double(bitPattern:bits);guard x.isFinite else { return false }
          a=min(a,x);b=max(b,x)
        }
        low=a;high=b
      case .progression(let start,let step):
        guard let last=step.multiplied(by:count-1),let end=start.adding(last) else { return false }
        if Lattice(start.value)?.shifted(from:.zero,to:last,quantum:step.exponent) == nil {
          // The conservative lattice may decline valid IEEE edge cases. Prove
          // this one <=256-event leaf, not a logical repeat, without rounding.
          for i in 0..<count {
            guard let delta=step.multiplied(by:i),start.adding(delta) != nil else { return false }
          }
        }
        low=min(start.value,end.value);high=max(start.value,end.value)
      }
      guard low.isFinite,high.isFinite else { return false }
      switch index {
      case 2,5: guard low >= 0 else { return false }
      case 3: guard low > 0 else { return false }
      case 4: guard low >= 0,high <= 1 else { return false }
      default: break
      }
    }
    return true
  }

  public init(encodedRelations data: Data) throws {
    guard data.count <= Self.maximumBytes else { throw CodingError.limitExceeded }
    var input = InkRelationReader(data: data)
    guard try input.bytes(4) == Self.signature else { throw CodingError.invalidSource }
    let sourceID = try input.uuid(), span = Int(try input.integer(UInt32.self))
    guard span <= Self.maximumEvents else { throw CodingError.invalidSource }
    let tool = try input.flag() ? SpatialInkTool.eraser : .pen
    let colors = try (0..<3).map { _ in try input.double() }
    guard colors.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CodingError.invalidSource }
    let sequence = try input.integer(UInt64.self), active = try input.flag()
    guard sequence <= VersionStamp.maximumCounter else { throw CodingError.invalidSource }
    let hasTargets = try input.flag(), targetCount = Int(try input.integer(UInt32.self))
    guard targetCount <= Self.maximumNodes, hasTargets || targetCount == 0, !hasTargets || tool == .eraser else { throw CodingError.invalidSource }
    let targets = try (0..<targetCount).map { _ in try input.target() }
    guard Set(targets.map(\.elementID)).count == targetCount else { throw CodingError.invalidSource }
    let frameCount = Int(try input.integer(UInt32.self))
    guard frameCount <= Self.maximumNodes else { throw CodingError.limitExceeded }
    let frames = try (0..<frameCount).map { _ in
      try InkExactFrame(a: input.dyadic(), b: input.dyadic(), c: input.dyadic(), d: input.dyadic(), x: input.dyadic(), y: input.dyadic())
    }
    let measurements=try Self.decodeMeasurements(from:&input)
    guard input.offset == data.count else { throw CodingError.invalidSource }
    self.init(sourceID:sourceID,span:span,measurements:measurements,frames:frames,
      header:.init(tool:tool,color:.init(red:colors[0],green:colors[1],blue:colors[2]),sequence:sequence,isActive:active,
        elementTargets:hasTargets ? targets : nil))
  }

  fileprivate static func decodeMeasurements(from input: inout InkRelationReader) throws -> InkMeasurements {
    let revision=try input.uuid()
    let exit = try input.step()
    let nodeCount = Int(try input.integer(UInt32.self))
    guard nodeCount > 0, nodeCount <= Self.maximumNodes else { throw CodingError.limitExceeded }
    var nodes: [Sequence] = [], depths: [Int] = [], used = Set<Int>()
    struct BasisKey: Hashable { let origin: UUID; let step: InkRepeatStep }
    var bases: [BasisKey: Sequence.Basis] = [:]
    for _ in 0..<nodeCount {
      let pending = try input.flag(), tag = try input.byte()
      var children: [Int] = []
      func child(_ id: Int) throws -> Sequence {
        guard nodes.indices.contains(id) else { throw CodingError.invalidSource }
        children.append(id); used.insert(id); return nodes[id]
      }
      var node: Sequence
      switch tag {
      case 0, 1:
        let count = Int(try input.integer(UInt32.self))
        guard count <= Self.blockSize else { throw CodingError.invalidSource }
        let block: Block
        if tag == 0 {
          block = .literal(.init(try (0..<count).map { _ in try input.sample() }))
        } else {
          guard count > 0 else { throw CodingError.invalidSource }
          let fields: [Field] = try (0..<8).map { _ in
            switch try input.byte() {
            case 0: return .constant(try input.integer(UInt64.self))
            case 1: return .progression(try input.dyadic(), try input.dyadic())
            case 2: return .literal(try (0..<count).map { _ in try input.integer(UInt64.self) })
            default: throw CodingError.invalidSource
            }
          }
          guard Self.valid(fields: fields, count: count) else { throw CodingError.invalidSource }
          block = .fields(fields, count)
        }
        node = Sequence(block: block)
      case 2:
        let a = try child(Int(input.integer(UInt32.self))), b = try child(Int(input.integer(UInt32.self)))
        guard a.count + b.count <= Self.maximumEvents else { throw CodingError.limitExceeded }
        node = Sequence.pair(a,b)
      case 3:
        let body = try child(Int(input.integer(UInt32.self))), n = Int(try input.integer(UInt32.self)), step = try input.step()
        guard n <= Self.maximumEvents, body.count * n <= Self.maximumEvents else { throw CodingError.limitExceeded }
        guard let repeated = Sequence.repeated(body,count:n,step:step) else { throw CodingError.invalidSource }
        node = repeated
      case 4:
        let body = try child(Int(input.integer(UInt32.self))), id = try input.uuid(), step = try input.step()
        let basis: Sequence.Basis
        let key = BasisKey(origin:id,step:step)
        if let found = bases[key] { basis = found }
        else { basis = .init(step,origin:id); bases[key] = basis }
        guard let shifted = body.placing(basis,compose:false) else { throw CodingError.invalidSource }
        node = shifted
      default: throw CodingError.invalidSource
      }
      let depth = 1 + (children.map { depths[$0] }.max() ?? 0)
      guard depth <= Self.maximumDepth else { throw CodingError.limitExceeded }
      if pending { node = node.markPending() }
      depths.append(depth); nodes.append(node)
    }
    guard used.count == nodeCount-1 else { throw CodingError.invalidSource }
    return .init(storage:.init(nodes.last!,exit:exit),revision:revision)
  }

}

/// No action metadata is copied into the body. The one graph codec above is
/// shared by journal bodies and full addressed relation snapshots.
extension InkMeasurements: Codable {
  public func encodedRelations() throws -> Data {
    var output=InkRelationWriter(data:Data("NIM1".utf8))
    try InkSampleRelations.encodeMeasurements(self,into:&output)
    return output.data
  }
  public init(encodedRelations: Data) throws {
    guard encodedRelations.count <= InkSampleRelations.maximumBytes else { throw InkSampleRelations.CodingError.limitExceeded }
    var input=InkRelationReader(data:encodedRelations)
    guard try input.bytes(4) == Data("NIM1".utf8) else { throw InkSampleRelations.CodingError.invalidSource }
    self=try InkSampleRelations.decodeMeasurements(from:&input)
    guard input.offset == encodedRelations.count else { throw InkSampleRelations.CodingError.invalidSource }
  }
  public func encode(to encoder: any Encoder) throws {
    var container=encoder.singleValueContainer();try container.encode(encodedRelations())
  }
  public init(from decoder: any Decoder) throws {
    let container=try decoder.singleValueContainer();try self.init(encodedRelations:container.decode(Data.self))
  }
}

private struct InkRelationWriter {
  var data: Data
  mutating func byte(_ x: UInt8) { data.append(x) }
  mutating func integer<T: FixedWidthInteger>(_ value: T) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }
  mutating func double(_ x: Double) { integer(x.bitPattern) }
  mutating func uuid(_ x: UUID) { var x=x.uuid; withUnsafeBytes(of:&x) { data.append(contentsOf:$0) } }
  mutating func dyadic(_ x: InkDyadic) { integer(x.coefficient); integer(Int16(x.exponent)) }
  mutating func step(_ s: InkRepeatStep) { dyadic(s.x);dyadic(s.y);dyadic(s.time) }
  mutating func world(_ p: WorldPoint?) {
    byte(p == nil ? 0 : 1)
    if let p { integer(p.tileX);integer(p.tileY);double(p.localX);double(p.localY) }
  }
  mutating func sample(_ p: SpatialInkSample) {
    double(p.point.x);double(p.point.y);double(p.timeOffset);double(p.width)
    double(p.opacity);double(p.force);double(p.azimuth);double(p.altitude);world(p.worldPoint)
  }
  mutating func transform(_ t: NotebookGraphicTransform?) {
    byte(t == nil ? 0 : 1)
    if let t { for x in [t.a,t.b,t.c,t.d,t.tx,t.ty] { double(x) } }
  }
  mutating func target(_ t: InkElementTarget) throws {
    let name=Data(t.elementID.utf8)
    guard name.count <= 65_536 else { throw InkSampleRelations.CodingError.limitExceeded }
    integer(UInt32(name.count));data.append(name)
    for x in [t.frame.x,t.frame.y,t.frame.width,t.frame.height] { double(x) }
    world(t.worldOrigin);byte(t.wholeElement ? 1 : 0);transform(t.graphicTransform);transform(t.elementTransform)
  }
}

private struct InkRelationReader {
  let data: Data
  var offset = 0
  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, count <= data.count-offset else { throw InkSampleRelations.CodingError.invalidSource }
    defer { offset += count }; return data.subdata(in:(data.startIndex+offset)..<(data.startIndex+offset+count))
  }
  mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
    let size=MemoryLayout<T>.size
    guard size <= data.count-offset else { throw InkSampleRelations.CodingError.invalidSource }
    defer { offset += size }
    return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset:offset,as:T.self)) }
  }
  mutating func byte() throws -> UInt8 { try integer(UInt8.self) }
  mutating func flag() throws -> Bool {
    let value=try byte();guard value<=1 else { throw InkSampleRelations.CodingError.invalidSource };return value==1
  }
  mutating func double() throws -> Double { Double(bitPattern: try integer(UInt64.self)) }
  mutating func uuid() throws -> UUID {
    let bytes=try bytes(16)
    return bytes.withUnsafeBytes { UUID(uuid:$0.loadUnaligned(as:uuid_t.self)) }
  }
  mutating func dyadic() throws -> InkDyadic {
    let c=try integer(Int64.self),e=Int(try integer(Int16.self))
    guard let value=InkDyadic(coefficient:c,exponent:e),value.coefficient==c,value.exponent==e else { throw InkSampleRelations.CodingError.invalidSource }
    return value
  }
  mutating func step() throws -> InkRepeatStep { try .init(x:dyadic(),y:dyadic(),time:dyadic()) }
  mutating func world() throws -> WorldPoint? {
    guard try flag() else { return nil }
    let x=try integer(Int64.self),y=try integer(Int64.self),a=try double(),b=try double()
    guard let value=WorldPoint(exactTileX:x,tileY:y,localX:a,localY:b) else { throw InkSampleRelations.CodingError.invalidSource }
    return value
  }
  mutating func sample() throws -> SpatialInkSample {
    let x=try double(),y=try double(),time=try double(),width=try double(),opacity=try double(),
      force=try double(),azimuth=try double(),altitude=try double(),world=try world()
    guard x.isFinite,y.isFinite,time.isFinite,time>=0,width.isFinite,width>0,
      opacity.isFinite,(0...1).contains(opacity),force.isFinite,force>=0,azimuth.isFinite,altitude.isFinite
      else { throw InkSampleRelations.CodingError.invalidSource }
    return .init(point:.init(x:x,y:y),worldPoint:world,timeOffset:time,width:width,opacity:opacity,
      force:force,azimuth:azimuth,altitude:altitude)
  }
  mutating func transform() throws -> NotebookGraphicTransform? {
    guard try flag() else { return nil }
    let v=try (0..<6).map { _ in try double() }
    let t=NotebookGraphicTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5])
    guard t.isValid else { throw InkSampleRelations.CodingError.invalidSource };return t
  }
  mutating func target() throws -> InkElementTarget {
    let length=Int(try integer(UInt32.self))
    guard length<=65_536,let name=String(data:try bytes(length),encoding:.utf8),!name.isEmpty,name.count<=120 else { throw InkSampleRelations.CodingError.invalidSource }
    let v=try (0..<4).map { _ in try double() },origin=try world(),whole=try flag(),graphic=try transform(),element=try transform()
    guard v.allSatisfy(\.isFinite),v[2]>0,v[3]>0 else { throw InkSampleRelations.CodingError.invalidSource }
    return .init(elementID:name,frame:.init(x:v[0],y:v[1],width:v[2],height:v[3]),worldOrigin:origin,wholeElement:whole,graphicTransform:graphic,elementTransform:element)
  }
}
