import Foundation

/// Decoded ink follows the immutable archive bytes shared by PageDocument
/// copies. Persistence may still encode off-main, but live readers never need
/// to decode the same page again merely because a preceding write is pending.
final class PageInkDrawingCache: @unchecked Sendable {
  /// A captured source pins this persistent root, not the live owner's next
  /// root. Lazy archive decoding is still shared by all readers of this source.
  final class Source: @unchecked Sendable {
    let stamp:VersionStamp
    private let lock=NSLock()
    private var value:PageInkDrawing?
    private var bytes:Data?
    init(stamp:VersionStamp,drawing:PageInkDrawing? = nil,data:Data? = nil) {
      self.stamp=stamp;value=drawing;bytes=data
    }
    func drawing() throws -> PageInkDrawing {
      try lock.withLock {
        if let value { return value }
        let decoded=try PageInkDrawing.decode(bytes ?? Data());value=decoded;return decoded
      }
    }
    func data() throws -> Data {
      try lock.withLock {
        if let bytes { return bytes }
        let encoded=try value!.dataRepresentation();bytes=encoded;return encoded
      }
    }
  }
  private let lock=NSLock()
  private var current:Source?
  init(_ drawing:PageInkDrawing? = nil,stamp:VersionStamp? = nil) {
    if let drawing,let stamp { current=Source(stamp:stamp,drawing:drawing) }
  }
  func stamp(fallback:VersionStamp)->VersionStamp { lock.withLock { current?.stamp ?? fallback } }
  func source(data:Data,stamp:VersionStamp)->Source {
    lock.withLock {
      if let current { return current }
      let source=Source(stamp:stamp,data:data);current=source;return source
    }
  }
  func value(for data:Data,stamp:VersionStamp) throws -> PageInkDrawing { try source(data:data,stamp:stamp).drawing() }
  func data(fallback:Data,stamp:VersionStamp) throws -> Data { try source(data:fallback,stamp:stamp).data() }
  func publish(_ change:PreparedPageInkChange)->Bool {
    lock.withLock {
      guard (current?.stamp ?? change.baseStamp) == change.baseStamp else { return false }
      current=Source(stamp:change.stamp,drawing:change.drawing);return true
    }
  }
}

private final class PersistentMapNode<Key: Comparable & Sendable, Value: Sendable>: @unchecked Sendable {
  let key: Key
  let value: Value
  let left: PersistentMapNode?
  let right: PersistentMapNode?
  let height: Int

  init(_ key: Key, _ value: Value, left: PersistentMapNode? = nil, right: PersistentMapNode? = nil) {
    self.key=key;self.value=value;self.left=left;self.right=right
    height=max(left?.height ?? 0,right?.height ?? 0)+1
  }

  func value(for key: Key) -> Value? {
    if key == self.key { return value }
    return key < self.key ? left?.value(for:key) : right?.value(for:key)
  }

  func inserting(_ key: Key, _ value: Value) -> PersistentMapNode {
    if key == self.key { return .init(key,value,left:left,right:right) }
    let node: PersistentMapNode
    if key < self.key { node = .init(self.key,self.value,left:left?.inserting(key,value) ?? .init(key,value),right:right) }
    else { node = .init(self.key,self.value,left:left,right:right?.inserting(key,value) ?? .init(key,value)) }
    return node.balanced()
  }

  private func balanced() -> PersistentMapNode {
    let balance=(left?.height ?? 0)-(right?.height ?? 0)
    if balance > 1,let left {
      let child=(left.left?.height ?? 0) >= (left.right?.height ?? 0) ? left : left.rotatedLeft()
      return PersistentMapNode(key,value,left:child,right:right).rotatedRight()
    }
    if balance < -1,let right {
      let child=(right.right?.height ?? 0) >= (right.left?.height ?? 0) ? right : right.rotatedRight()
      return PersistentMapNode(key,value,left:left,right:child).rotatedLeft()
    }
    return self
  }

  private func rotatedLeft() -> PersistentMapNode {
    guard let right else { return self }
    return .init(right.key,right.value,left:.init(key,value,left:left,right:right.left),right:right.right)
  }

  private func rotatedRight() -> PersistentMapNode {
    guard let left else { return self }
    return .init(left.key,left.value,left:left.left,right:.init(key,value,left:left.right,right:right))
  }

  func values(into result: inout [Value]) {
    left?.values(into:&result);result.append(value);right?.values(into:&result)
  }

  func values(from lowerBound: Key, into result: inout [Value]) {
    if key >= lowerBound {
      left?.values(from:lowerBound,into:&result)
      result.append(value)
    }
    right?.values(from:lowerBound,into:&result)
  }

  static func balanced(_ entries: [(Key,Value)], _ lower: Int, _ upper: Int) -> PersistentMapNode? {
    guard lower < upper else { return nil }
    let middle=lower+(upper-lower)/2,entry=entries[middle]
    return .init(entry.0,entry.1,left:balanced(entries,lower,middle),right:balanced(entries,middle+1,upper))
  }
}

/// Immutable roots make one accepted contact O(log history). Older page
/// snapshots retain their roots without copying the action array.
fileprivate final class PageInkActionCursorToken: @unchecked Sendable {}

private final class PageInkActionStorage: @unchecked Sendable {
  let order: PersistentMapNode<Int,PageInkAction>?
  let ids: PersistentMapNode<String,Int>?
  let count: Int
  let activeCount: Int
  let maximumSequence: UInt64
  let cursorToken:PageInkActionCursorToken
  let predecessorToken:PageInkActionCursorToken?
  let predecessorCount:Int?
  let isValid: Bool
  let hasOrderedActions:Bool

  init(_ input: [PageInkAction]) {
    let actions=input.enumerated().map { index,action in
      action.sequence == 0 ? action.ordered(UInt64(index+1)) : action
    }
    let identifiers=actions.enumerated().map { ($0.element.id.uuidString.lowercased(),$0.offset) }.sorted { $0.0 < $1.0 }
    let unique=zip(identifiers,identifiers.dropFirst()).allSatisfy { $0.0.0 != $0.1.0 }
    order=PersistentMapNode.balanced(Array(actions.enumerated().map { ($0.offset,$0.element) }),0,actions.count)
    ids=PersistentMapNode.balanced(identifiers,0,identifiers.count)
    count=actions.count;activeCount=actions.reduce(0) { $0+($1.isActive ? 1:0) }
    maximumSequence=actions.map(\.sequence).max() ?? 0
    cursorToken = .init();predecessorToken=nil;predecessorCount=nil
    isValid=unique && actions.allSatisfy(\.isValid)
    hasOrderedActions=actions.allSatisfy { $0.sequence > 0 }
  }

  private init(order: PersistentMapNode<Int,PageInkAction>?, ids: PersistentMapNode<String,Int>?,
    count:Int,activeCount:Int,maximumSequence:UInt64,cursorToken:PageInkActionCursorToken,
    predecessorToken:PageInkActionCursorToken?,predecessorCount:Int?) {
    self.order=order;self.ids=ids;self.count=count;self.activeCount=activeCount
    self.maximumSequence=maximumSequence;self.cursorToken=cursorToken
    self.predecessorToken=predecessorToken;self.predecessorCount=predecessorCount;isValid=true
    hasOrderedActions=true
  }

  var actions: [PageInkAction] { var result:[PageInkAction]=[];result.reserveCapacity(count);order?.values(into:&result);return result }
  func actions(from position:Int)->[PageInkAction] {
    guard position < count else { return [] }
    var result:[PageInkAction]=[];result.reserveCapacity(count-position)
    order?.values(from:position,into:&result);return result
  }
  func action(_ id:UUID) -> PageInkAction? { ids?.value(for:id.uuidString.lowercased()).flatMap { order?.value(for:$0) } }

  func appending(_ action:PageInkAction) throws -> PageInkActionStorage {
    if let accepted=self.action(action.id) {
      guard accepted.hasSameMeasurement(as:action) else { throw PageInkDrawing.InkError.actionIDConflict }
      return self
    }
    guard maximumSequence < VersionStamp.maximumCounter else { throw PageInkDrawing.InkError.sequenceExhausted }
    let accepted=action.ordered(maximumSequence+1),position=count
    return .init(order:order?.inserting(position,accepted) ?? .init(position,accepted),
      ids:ids?.inserting(accepted.id.uuidString.lowercased(),position) ?? .init(accepted.id.uuidString.lowercased(),position),
      count:count+1,activeCount:activeCount+(accepted.isActive ? 1:0),maximumSequence:accepted.sequence,
      cursorToken:.init(),predecessorToken:cursorToken,predecessorCount:count)
  }

  func removing(_ identifiers:Set<UUID>) -> PageInkActionStorage {
    var root=order,active=activeCount
    for id in identifiers {
      guard let position=ids?.value(for:id.uuidString.lowercased()),let action=root?.value(for:position),action.isActive else { continue }
      root=root?.inserting(position,action.deactivated());active-=1
    }
    guard root !== order else { return self }
    return .init(order:root,ids:ids,count:count,activeCount:active,maximumSequence:maximumSequence,
      cursorToken:.init(),predecessorToken:nil,predecessorCount:nil)
  }
}

/// A page owns the ordered pen and eraser operations that produced its pixels.
/// A converted page starts with the final visible PNG of its previous drawing.
public struct PageInkDrawing: Codable, Equatable, Sendable {
  public struct ActionCursor:Equatable,Sendable {
    fileprivate let token:PageInkActionCursorToken
    fileprivate let count:Int
    public static func ==(lhs:Self,rhs:Self)->Bool { lhs.token === rhs.token && lhs.count == rhs.count }
  }
  private static let signature = Data("NotebookInk/3\n".utf8)
  public let baselinePNG: Data?
  public let baselineActionCount: Int
  private let storage: PageInkActionStorage
  public var actions: [PageInkAction] { storage.actions }

  public init(baselinePNG: Data? = nil, baselineActionCount: Int = 0, actions: [PageInkAction] = [])
  {
    self.baselinePNG = baselinePNG
    self.baselineActionCount = baselineActionCount
    storage = .init(actions)
    precondition(isValid)
  }

  public var activeActions: [PageInkAction] { actions.filter(\.isActive) }
  public var actionCount: Int { baselineActionCount + storage.activeCount }
  public var actionCursor:ActionCursor {
    .init(token:storage.cursorToken,count:storage.count)
  }
  /// Returns only actions appended after a retained runtime cursor. Tombstones,
  /// reopen and merge invalidate the cursor instead of pretending a prefix is
  /// unchanged.
  public func appendedActions(after cursor:ActionCursor)->[PageInkAction]? {
    if cursor.token === storage.cursorToken,cursor.count == storage.count { return [] }
    guard let predecessorToken=storage.predecessorToken,let predecessorCount=storage.predecessorCount,
      cursor.token === predecessorToken,cursor.count == predecessorCount else { return nil }
    return storage.actions(from:cursor.count)
  }
  public var isEmpty: Bool { baselinePNG == nil && storage.activeCount == 0 }
  public func action(id:UUID) -> PageInkAction? { storage.action(id) }
  public var isValid: Bool {
    baselineActionCount >= 0 && baselineActionCount <= 1_000_000
      && (baselinePNG.map {
        $0.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && $0.count <= 64 * 1024 * 1024
      } ?? true)
      && storage.isValid
  }

  private enum CodingKeys:String,CodingKey { case baselinePNG,baselineActionCount,actions }
  public init(from decoder:Decoder) throws {
    let values=try decoder.container(keyedBy:CodingKeys.self)
    baselinePNG=try values.decodeIfPresent(Data.self,forKey:.baselinePNG)
    baselineActionCount=try values.decode(Int.self,forKey:.baselineActionCount)
    storage = .init(try values.decode([PageInkAction].self,forKey:.actions))
    guard isValid else { throw InkError.invalidDrawing }
  }
  public func encode(to encoder:Encoder) throws {
    var values=encoder.container(keyedBy:CodingKeys.self)
    try values.encodeIfPresent(baselinePNG,forKey:.baselinePNG)
    try values.encode(baselineActionCount,forKey:.baselineActionCount)
    try values.encode(actions,forKey:.actions)
  }
  public static func ==(left:Self,right:Self)->Bool {
    left.baselinePNG == right.baselinePNG && left.baselineActionCount == right.baselineActionCount
      && (left.storage === right.storage || left.actions == right.actions)
  }

  public static func decode(_ data: Data) throws -> Self {
    if data.isEmpty { return Self() }
    guard data.starts(with: signature) else { throw InkError.invalidDrawing }
    let decoded = try InkRelationDecoding.decoder().decode(Self.self, from: data.dropFirst(signature.count))
    guard decoded.isValid, decoded.storage.hasOrderedActions else { throw InkError.invalidDrawing }
    return decoded
  }

  public func dataRepresentation() throws -> Data {
    guard isValid, storage.hasOrderedActions else { throw InkError.invalidDrawing }
    if baselinePNG == nil && storage.count == 0 && baselineActionCount == 0 { return Data() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return Self.signature + (try encoder.encode(self))
  }

  public func appending(_ action: PageInkAction) throws -> Self {
    let next=try storage.appending(action)
    guard next !== storage else { return self }
    return Self(baselinePNG:baselinePNG,baselineActionCount:baselineActionCount,storage:next)
  }

  /// An undo retains a tombstone: an older device cannot resurrect the stroke.
  public func removing(_ ids: Set<UUID>) -> Self {
    let next=storage.removing(ids)
    guard next !== storage else { return self }
    return Self(baselinePNG:baselinePNG,baselineActionCount:baselineActionCount,storage:next)
  }

  private init(baselinePNG:Data?,baselineActionCount:Int,storage:PageInkActionStorage) {
    self.baselinePNG=baselinePNG;self.baselineActionCount=baselineActionCount;self.storage=storage
  }

  public func merging(_ other: Self) throws -> Self {
    guard baselinePNG == other.baselinePNG, baselineActionCount == other.baselineActionCount else {
      throw InkError.incompatibleBaseline
    }
    var byID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    for incoming in other.actions {
      if let current = byID[incoming.id] {
        guard current.sequence == incoming.sequence, current.hasSameMeasurement(as: incoming) else { throw InkError.actionIDConflict }
        byID[incoming.id] = current.isActive ? incoming : current
      } else { byID[incoming.id] = incoming }
    }
    return Self(baselinePNG: baselinePNG, baselineActionCount: baselineActionCount,
      actions: byID.values.sorted {
        $0.sequence == $1.sequence ? $0.id.uuidString < $1.id.uuidString : $0.sequence < $1.sequence
      })
  }

  public enum InkError: Error, LocalizedError {
    case invalidDrawing, incompatibleBaseline, actionIDConflict, sequenceExhausted
    public var errorDescription: String? {
      switch self {
      case .invalidDrawing: "Чернила не соответствуют формату и границам листа."
      case .incompatibleBaseline: "Нельзя объединить штрихи с разной растровой основой."
      case .actionIDConflict: "UUID штриха уже относится к другому измерению."
      case .sequenceExhausted: "Достигнут предел порядка штрихов этого листа."
      }
    }
  }
}

public struct PageInkAction: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let tool: SpatialInkTool
  public let color: SpatialInkColor
  public let samples: InkMeasurements
  public let sequence: UInt64
  public let elementTargets: [InkElementTarget]?
  public let isActive: Bool

  public init(
    id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    samples: [SpatialInkSample], sequence: UInt64 = 0, isActive: Bool = true,
    elementTargets: [InkElementTarget]? = nil
  ) {
    self.init(id:id,tool:tool,color:color,measurements:.init(samples),sequence:sequence,isActive:isActive,elementTargets:elementTargets)
  }

  public init(id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    measurements: InkMeasurements, sequence: UInt64 = 0, isActive: Bool = true,
    elementTargets: [InkElementTarget]? = nil) {
    self.id = id
    self.tool = tool
    self.color = color
    self.samples = measurements
    self.sequence = sequence
    self.elementTargets = elementTargets?.isEmpty == false ? elementTargets : nil
    self.isActive = isActive
    precondition(isValid)
  }

  public var isValid: Bool {
    sequence <= VersionStamp.maximumCounter && color.isValid && !samples.isEmpty && samples.count <= 1_000_000
      && samples.isPaper
      && (elementTargets == nil || (tool == .eraser
        && elementTargets!.allSatisfy { $0.isValid && $0.worldOrigin == nil }
        && Set(elementTargets!.map(\.elementID)).count == elementTargets!.count))
  }

  private enum CodingKeys: String, CodingKey { case id, tool, color, samples, sequence, isActive, elementTargets }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    tool = try values.decode(SpatialInkTool.self, forKey: .tool)
    color = try values.decode(SpatialInkColor.self, forKey: .color)
    samples = try values.decode(InkMeasurements.self, forKey: .samples)
    sequence = try values.decode(UInt64.self, forKey: .sequence)
    isActive = try values.decode(Bool.self, forKey: .isActive)
    elementTargets = try values.decodeIfPresent([InkElementTarget].self, forKey: .elementTargets)
    guard isValid else { throw PageInkDrawing.InkError.invalidDrawing }
  }

  fileprivate func ordered(_ sequence: UInt64) -> Self {
    Self(id: id, tool: tool, color: color, measurements: samples, sequence: sequence, isActive: isActive, elementTargets: elementTargets)
  }

  fileprivate func hasSameMeasurement(as other: Self) -> Bool {
    tool == other.tool && color == other.color && samples == other.samples && elementTargets == other.elementTargets
  }

  fileprivate func deactivated() -> Self {
    isActive ? Self(id: id, tool: tool, color: color, measurements: samples, sequence: sequence, isActive: false, elementTargets: elementTargets) : self
  }
}
