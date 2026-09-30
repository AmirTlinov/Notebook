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
    private let decoding=NSLock()
    private let encoding=NSLock()
    private let preparation=NSLock()
    private var value:PageInkDrawing?
    private var bytes:Data?
    private var erasures:PageInkErasureDirectory?
    private var eraserIndex:InkReadSetBoundsIndex?
    init(stamp:VersionStamp,drawing:PageInkDrawing? = nil,data:Data? = nil,erasures:PageInkErasureDirectory? = nil,eraserIndex:InkReadSetBoundsIndex? = nil) {
      self.stamp=stamp;value=drawing;bytes=data;self.erasures=erasures;self.eraserIndex=eraserIndex
    }
    var prepared:PageInkPreparedProjection? { lock.withLock {
      guard let value,let erasures,let eraserIndex else { return nil };return .init(drawing:value,erasures:erasures,eraserIndex:eraserIndex)
    } }
    func drawing() throws -> PageInkDrawing {
      if let ready=lock.withLock({value}) { return ready }
      return try decoding.withLock {
        if let ready=lock.withLock({value}) { return ready }
        let archive=lock.withLock { bytes ?? Data() }
        let decoded=try PageInkDrawing.decode(archive)
        lock.withLock { value=decoded };return decoded
      }
    }
    func prepare() throws -> PageInkPreparedProjection {
      if let prepared { return prepared }
      return try preparation.withLock {
        if let prepared {return prepared}
        let drawing=try drawing(),directory=PageInkErasureDirectory(drawing)
        let index=InkReadSetBoundsIndex(page:drawing.actions)
        return lock.withLock {
          erasures=directory;eraserIndex=index
          return .init(drawing:drawing,erasures:directory,eraserIndex:index)
        }
      }
    }
    func data() throws -> Data {
      if let ready=lock.withLock({bytes}) {return ready}
      return try encoding.withLock {
        if let ready=lock.withLock({bytes}) {return ready}
        let encoded=try drawing().dataRepresentation()
        lock.withLock {bytes=encoded};return encoded
      }
    }
  }
  private let lock=NSLock()
  private var current:Source?
  init(_ drawing:PageInkDrawing? = nil,stamp:VersionStamp? = nil,erasures:PageInkErasureDirectory? = nil,eraserIndex:InkReadSetBoundsIndex? = nil) {
    if let drawing,let stamp { current=Source(stamp:stamp,drawing:drawing,erasures:erasures,eraserIndex:eraserIndex) }
  }
  init(source:Source) {current=source}
  func stamp(fallback:VersionStamp)->VersionStamp { lock.withLock { current?.stamp ?? fallback } }
  func source(data:Data,stamp:VersionStamp)->Source {
    lock.withLock {
      if let current { return current }
      let source=data.isEmpty ? Source(stamp:stamp,drawing:.init(),data:data,erasures:.init(),eraserIndex:.init()) : Source(stamp:stamp,data:data)
      current=source;return source
    }
  }
  func value(for data:Data,stamp:VersionStamp) throws -> PageInkDrawing { try source(data:data,stamp:stamp).drawing() }
  func data(fallback:Data,stamp:VersionStamp) throws -> Data { try source(data:fallback,stamp:stamp).data() }
  func publish(_ change:PreparedPageInkChange)->Bool {
    lock.withLock {
      guard (current?.stamp ?? change.baseStamp) == change.baseStamp else { return false }
      current=change.source;return true
    }
  }
}

/// The page source owns this projection alongside its persistent action root.
/// Cold construction happens on the read worker; accepted changes touch only
/// the addressed eraser targets. UI consumers never reconstruct the history.
struct PageInkPreparedProjection:Sendable {
  let drawing:PageInkDrawing
  let erasures:PageInkErasureDirectory
  let eraserIndex:InkReadSetBoundsIndex
}
struct PageInkErasureDirectory:Sendable {
  private var targets:InkActionMapNode<String,[String]>?
  private(set) var values=InkElementErasureMap()
  init() {}
  init(_ drawing:PageInkDrawing) {
    for action in drawing.actions where action.isActive && action.tool == .eraser {append(action)}
  }
  private mutating func append(_ action:PageInkAction) {
    guard action.isActive,action.tool == .eraser else {return}
    let targets=action.elementTargets ?? []
    for target in targets {
      values.insert(.init(target:target,measurements:action.samples),at:action.sequence,actionID:action.id,for:target.elementID)
    }
    if !targets.isEmpty {
      let id=action.id.uuidString
      self.targets=self.targets?.inserting(id,targets.map(\.elementID)) ?? .init(id,targets.map(\.elementID))
    }
  }
  func applying(_ mutation:PageInkMutation,drawing:PageInkDrawing)->Self {
    var next=self
    switch mutation {
    case .append(let action):next.append(action)
    case .setActive(let ids,let active):
      for id in ids {
        guard let action=drawing.action(id:id) else {continue}
        for target in next.targets?.value(for:id.uuidString) ?? [] {next.values.remove(at:action.sequence,actionID:action.id,for:target)}
        next.targets=next.targets?.removing(id.uuidString)
        if active {next.append(action)}
      }
    }
    return next
  }
}

/// Immutable roots make one accepted contact O(log history). Older page
/// snapshots retain their roots without copying the action array.
fileprivate final class PageInkActionCursorToken: @unchecked Sendable {}

private final class PageInkActionStorage: @unchecked Sendable {
  let order: InkActionMapNode<Int,PageInkAction>?
  let ids: InkActionMapNode<String,Int>?
  let count: Int
  let activeCount: Int
  let maximumSequence: UInt64
  let cursorToken:PageInkActionCursorToken
  let predecessorToken:PageInkActionCursorToken?
  let predecessorCount:Int?
  let isValid: Bool

  init(_ input: [PageInkAction]) {
    let actions=input.enumerated().map { index,action in
      action.sequence == 0 ? action.ordered(UInt64(index+1)) : action
    }
    let identifiers=actions.enumerated().map { ($0.element.id.uuidString.lowercased(),$0.offset) }.sorted { $0.0 < $1.0 }
    let unique=zip(identifiers,identifiers.dropFirst()).allSatisfy { $0.0.0 != $0.1.0 }
    order=InkActionMapNode.balanced(Array(actions.enumerated().map { ($0.offset,$0.element) }),0,actions.count)
    ids=InkActionMapNode.balanced(identifiers,0,identifiers.count)
    count=actions.count;activeCount=actions.reduce(0) { $0+($1.isActive ? 1:0) }
    maximumSequence=actions.map(\.sequence).max() ?? 0
    cursorToken = .init();predecessorToken=nil;predecessorCount=nil
    isValid=unique && actions.allSatisfy(\.isValid)
  }

  private init(order: InkActionMapNode<Int,PageInkAction>?, ids: InkActionMapNode<String,Int>?,
    count:Int,activeCount:Int,maximumSequence:UInt64,cursorToken:PageInkActionCursorToken,
    predecessorToken:PageInkActionCursorToken?,predecessorCount:Int?) {
    self.order=order;self.ids=ids;self.count=count;self.activeCount=activeCount
    self.maximumSequence=maximumSequence;self.cursorToken=cursorToken
    self.predecessorToken=predecessorToken;self.predecessorCount=predecessorCount;isValid=true
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

  func settingVisibility(_ visibility: PageInkVisibility, for identifiers:Set<UUID>) throws -> PageInkActionStorage {
    var root=order,active=activeCount
    for id in identifiers {
      guard let position=ids?.value(for:id.uuidString.lowercased()),let action=root?.value(for:position) else { continue }
      let next = try action.visibility.merging(visibility)
      guard next != action.visibility else { continue }
      root=root?.inserting(position,action.settingVisibility(next))
      active += (next.isActive ? 1 : 0) - (action.isActive ? 1 : 0)
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
    let actions=try values.decode([PageInkAction].self,forKey:.actions)
    // Only a newly measured contact may receive an ordinal. Loading damaged
    // accepted material must not silently invent a new painter order.
    guard actions.allSatisfy({ $0.sequence > 0 }) else { throw InkError.invalidDrawing }
    storage = .init(actions)
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
    guard decoded.isValid else { throw InkError.invalidDrawing }
    return decoded
  }

  public func dataRepresentation() throws -> Data {
    guard isValid else { throw InkError.invalidDrawing }
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

  /// A causal gate keeps identity, painter order and the shared measurement
  /// root. Old copies cannot overwrite either Undo or its explicit inverse.
  public func settingActive(_ active: Bool, for ids: Set<UUID>, stamp: VersionStamp) throws -> Self {
    let next=try storage.settingVisibility(.init(isActive:active,stateStamp:stamp),for:ids)
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
        byID[incoming.id] = current.settingVisibility(try current.visibility.merging(incoming.visibility))
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
  public let stateStamp: VersionStamp?
  public var visibility: PageInkVisibility { .init(isActive:isActive,stateStamp:stateStamp) }

  public init(
    id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    samples: [SpatialInkSample], sequence: UInt64 = 0, isActive: Bool = true,
    elementTargets: [InkElementTarget]? = nil, stateStamp: VersionStamp? = nil
  ) {
    self.init(id:id,tool:tool,color:color,measurements:.init(samples),sequence:sequence,isActive:isActive,elementTargets:elementTargets,stateStamp:stateStamp)
  }

  public init(id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    measurements: InkMeasurements, sequence: UInt64 = 0, isActive: Bool = true,
    elementTargets: [InkElementTarget]? = nil, stateStamp: VersionStamp? = nil) {
    self.id = id
    self.tool = tool
    self.color = color
    self.samples = measurements
    self.sequence = sequence
    self.elementTargets = elementTargets?.isEmpty == false ? elementTargets : nil
    self.isActive = isActive
    self.stateStamp = stateStamp
    precondition(isValid)
  }

  public var isValid: Bool {
    sequence <= VersionStamp.maximumCounter && visibility.isValid && color.isValid && !samples.isEmpty && samples.count <= 1_000_000
      && samples.isPaper
      && (elementTargets == nil || (tool == .eraser
        && elementTargets!.allSatisfy { $0.isValid && $0.worldOrigin == nil }
        && Set(elementTargets!.map(\.elementID)).count == elementTargets!.count))
  }

  private enum CodingKeys: String, CodingKey { case id, tool, color, samples, sequence, isActive, elementTargets, stateStamp }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    tool = try values.decode(SpatialInkTool.self, forKey: .tool)
    color = try values.decode(SpatialInkColor.self, forKey: .color)
    samples = try values.decode(InkMeasurements.self, forKey: .samples)
    sequence = try values.decode(UInt64.self, forKey: .sequence)
    isActive = try values.decode(Bool.self, forKey: .isActive)
    stateStamp = try values.decodeIfPresent(VersionStamp.self, forKey: .stateStamp)
    elementTargets = try values.decodeIfPresent([InkElementTarget].self, forKey: .elementTargets)
    guard isValid else { throw PageInkDrawing.InkError.invalidDrawing }
  }

  fileprivate func ordered(_ sequence: UInt64) -> Self {
    Self(id: id, tool: tool, color: color, measurements: samples, sequence: sequence, isActive: isActive, elementTargets: elementTargets,stateStamp:stateStamp)
  }

  fileprivate func hasSameMeasurement(as other: Self) -> Bool {
    tool == other.tool && color == other.color && samples == other.samples && elementTargets == other.elementTargets
  }

  func settingVisibility(_ visibility: PageInkVisibility) -> Self {
    Self(id:id,tool:tool,color:color,measurements:samples,sequence:sequence,
      isActive:visibility.isActive,elementTargets:elementTargets,stateStamp:visibility.stateStamp)
  }
}
