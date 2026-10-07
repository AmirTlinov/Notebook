import Foundation

/// A spatial address references its existing content owner; it never carries source data.
public enum WorkspaceSpatialID: Hashable, Sendable {
  case item(UUID)
  case element(String)
}

public struct WorkspaceSpatialKinds: OptionSet, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let items = Self(rawValue: 1 << 0)
  public static let elements = Self(rawValue: 1 << 1)
  public static let all: Self = [.items, .elements]
}

/// Axis-aligned world bounds retain tiled endpoints even when an index node spans distant tiles.
public struct WorkspaceSpatialBounds: Codable, Equatable, Sendable {
  public let origin: WorldPoint
  public let width: Double
  public let height: Double
  public let maximum: WorldPoint

  // These endpoints describe derived geometry, not a persistable item or
  // camera address. Decimal tile strings preserve every Int64 through JSON
  // without extending WorldPoint's physical, safe-integer admission range.
  private struct Endpoint: Codable {
    let tileX: String
    let tileY: String
    let localX: Double
    let localY: Double

    init(_ point: WorldPoint) {
      tileX = String(point.tileX); tileY = String(point.tileY)
      localX = point.localX; localY = point.localY
    }

    func point() throws -> WorldPoint {
      guard let x = Int64(tileX), String(x) == tileX,
        let y = Int64(tileY), String(y) == tileY,
        localX.isFinite, localY.isFinite,
        localX >= 0, localX < WorldPoint.tileSize,
        localY >= 0, localY < WorldPoint.tileSize else {
        throw NotebookStorageError.invalidTransaction("spatial projection endpoint")
      }
      return .init(tileX: x, tileY: y, localX: localX, localY: localY)
    }
  }

  private enum CodingKeys: String, CodingKey { case origin, maximum }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(Endpoint(origin), forKey: .origin)
    try values.encode(Endpoint(maximum), forKey: .maximum)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let origin = try values.decode(Endpoint.self, forKey: .origin).point()
    let maximum = try values.decode(Endpoint.self, forKey: .maximum).point()
    guard Self.compare(origin.tileX, origin.localX, maximum.tileX, maximum.localX) <= 0,
      Self.compare(origin.tileY, origin.localY, maximum.tileY, maximum.localY) <= 0 else {
      throw NotebookStorageError.invalidTransaction("spatial projection bounds")
    }
    self.init(origin: origin, maximum: maximum)
  }

  public init(origin: WorldPoint, width: Double, height: Double) {
    precondition(width.isFinite && height.isFinite && width >= 0 && height >= 0)
    self.origin = origin
    self.width = width
    self.height = height
    maximum = origin.offsetBy(x: width, y: height)
  }

  public init(origin: WorldPoint, maximum: WorldPoint) {
    precondition(Self.compare(origin.tileX, origin.localX, maximum.tileX, maximum.localX) <= 0
      && Self.compare(origin.tileY, origin.localY, maximum.tileY, maximum.localY) <= 0)
    self.origin = origin
    self.maximum = maximum
    width = Self.distance(origin.tileX, origin.localX, maximum.tileX, maximum.localX)
    height = Self.distance(origin.tileY, origin.localY, maximum.tileY, maximum.localY)
  }

  public func intersects(_ other: Self) -> Bool {
    Self.compare(origin.tileX, origin.localX, other.maximum.tileX, other.maximum.localX) <= 0
      && Self.compare(maximum.tileX, maximum.localX, other.origin.tileX, other.origin.localX) >= 0
      && Self.compare(origin.tileY, origin.localY, other.maximum.tileY, other.maximum.localY) <= 0
      && Self.compare(maximum.tileY, maximum.localY, other.origin.tileY, other.origin.localY) >= 0
  }

  public func contains(_ other: Self) -> Bool {
    Self.compare(origin.tileX, origin.localX, other.origin.tileX, other.origin.localX) <= 0
      && Self.compare(maximum.tileX, maximum.localX, other.maximum.tileX, other.maximum.localX) >= 0
      && Self.compare(origin.tileY, origin.localY, other.origin.tileY, other.origin.localY) <= 0
      && Self.compare(maximum.tileY, maximum.localY, other.maximum.tileY, other.maximum.localY) >= 0
  }

  /// Clip tiled endpoints before projecting. A coarse node can span more
  /// than Int64 signed tile distance even though its visible fragment is small.
  public func intersection(_ other: Self) -> Self? {
    guard intersects(other) else { return nil }
    let minX = Self.compare(origin.tileX, origin.localX, other.origin.tileX, other.origin.localX) >= 0
    let minY = Self.compare(origin.tileY, origin.localY, other.origin.tileY, other.origin.localY) >= 0
    let maxX = Self.compare(maximum.tileX, maximum.localX, other.maximum.tileX, other.maximum.localX) <= 0
    let maxY = Self.compare(maximum.tileY, maximum.localY, other.maximum.tileY, other.maximum.localY) <= 0
    return Self(
      origin: WorldPoint(tileX: minX ? origin.tileX : other.origin.tileX,
        tileY: minY ? origin.tileY : other.origin.tileY,
        localX: minX ? origin.localX : other.origin.localX,
        localY: minY ? origin.localY : other.origin.localY),
      maximum: WorldPoint(tileX: maxX ? maximum.tileX : other.maximum.tileX,
        tileY: maxY ? maximum.tileY : other.maximum.tileY,
        localX: maxX ? maximum.localX : other.maximum.localX,
        localY: maxY ? maximum.localY : other.maximum.localY))
  }

  func union(_ other: Self) -> Self {
    let minX = Self.compare(origin.tileX, origin.localX, other.origin.tileX, other.origin.localX) <= 0
    let minY = Self.compare(origin.tileY, origin.localY, other.origin.tileY, other.origin.localY) <= 0
    let maxX = Self.compare(maximum.tileX, maximum.localX, other.maximum.tileX, other.maximum.localX) >= 0
    let maxY = Self.compare(maximum.tileY, maximum.localY, other.maximum.tileY, other.maximum.localY) >= 0
    return Self(
      origin: WorldPoint(
        tileX: minX ? origin.tileX : other.origin.tileX,
        tileY: minY ? origin.tileY : other.origin.tileY,
        localX: minX ? origin.localX : other.origin.localX,
        localY: minY ? origin.localY : other.origin.localY
      ),
      maximum: WorldPoint(
        tileX: maxX ? maximum.tileX : other.maximum.tileX,
        tileY: maxY ? maximum.tileY : other.maximum.tileY,
        localX: maxX ? maximum.localX : other.maximum.localX,
        localY: maxY ? maximum.localY : other.maximum.localY
      )
    )
  }

  fileprivate static func compare(_ tile: Int64, _ local: Double, _ otherTile: Int64, _ otherLocal: Double) -> Int {
    if tile != otherTile { return tile < otherTile ? -1 : 1 }
    if local == otherLocal { return 0 }
    return local < otherLocal ? -1 : 1
  }

  private static func distance(_ tile: Int64, _ local: Double, _ otherTile: Int64, _ otherLocal: Double) -> Double {
    // Unsigned subtraction preserves the distance across zero without overflowing Int64.
    let tiles = UInt64(bitPattern: otherTile) &- UInt64(bitPattern: tile)
    return Double(tiles) * WorldPoint.tileSize + otherLocal - local
  }
}

public struct WorkspaceSpatialEntry: Equatable, Sendable {
  public let id: WorkspaceSpatialID
  public let bounds: WorkspaceSpatialBounds
  public let zIndex: Double

  public init(id: WorkspaceSpatialID, bounds: WorkspaceSpatialBounds, zIndex: Double) {
    precondition(zIndex.isFinite)
    self.id = id
    self.bounds = bounds
    self.zIndex = zIndex
  }
}

/// A bounded overview primitive representing every unpinned entry in one index subtree.
/// Its count covers the whole aggregate bounds, not an exact count inside the viewport.
public struct WorkspaceSpatialAggregate: Equatable, Identifiable, Sendable {
  public let id: Int
  public let bounds: WorkspaceSpatialBounds
  public let count: Int
}

public struct WorkspaceSpatialQueryStatistics: Equatable, Sendable {
  public let visitedNodes: Int
  public let examinedEntries: Int
}

public struct WorkspaceSpatialQuery: Equatable, Sendable {
  public let entries: [WorkspaceSpatialEntry]
  public let aggregates: [WorkspaceSpatialAggregate]
  public let statistics: WorkspaceSpatialQueryStatistics
}

/// Exact broad-phase owners. `overflow` is explicit: callers must narrow the
/// gesture instead of treating an aggregate or a truncated prefix as selected.
public struct WorkspaceSpatialIntersectionQuery: Equatable, Sendable {
  public let entries: [WorkspaceSpatialEntry]
  public let overflow: Bool
  public let statistics: WorkspaceSpatialQueryStatistics
}

/// A cursor names one immutable index and one physical query. Its stack is a
/// depth-first path, bounded by tree depth rather than by the number of sources.
public struct WorkspaceSpatialReadCursor: Sendable {
  fileprivate let generation: UUID
  fileprivate let bounds: WorkspaceSpatialBounds
  fileprivate let pending: [WorkspaceSpatialIndex.PaintStep]
}

public enum WorkspaceSpatialReadError: Error, Equatable { case cursorMismatch }

public struct WorkspaceSpatialReadPage: Sendable {
  public let entries: [WorkspaceSpatialEntry]
  public let next: WorkspaceSpatialReadCursor?
  public let visitedNodes: Int
}

/// One immutable spatial and painter index. Addressed updates share unchanged
/// tree nodes; readers retain their exact geometry and generation.
public struct WorkspaceSpatialIndex: Sendable {
  fileprivate struct Identifier: Comparable, Sendable {
    let id: WorkspaceSpatialID
    static func < (a: Self, b: Self) -> Bool { WorkspaceSpatialIndex.idOrder(a.id, b.id) }
  }
  fileprivate struct SpatialKey: Comparable, Sendable {
    let origin: WorldPoint
    let id: WorkspaceSpatialID
    init(_ entry: WorkspaceSpatialEntry) { origin = entry.bounds.origin; id = entry.id }
    static func < (a: Self, b: Self) -> Bool {
      // Signed tiles remain exact through the full Int64 range. Local doubles
      // are positive monotone bit patterns; normalize the two spellings of zero.
      func interleaved(_ ax: UInt64, _ ay: UInt64, _ bx: UInt64, _ by: UInt64) -> Bool? {
        let x = ax ^ bx, y = ay ^ by
        guard x != 0 || y != 0 else { return nil }
        return x.leadingZeroBitCount <= y.leadingZeroBitCount ? ax < bx : ay < by
      }
      let sign: UInt64 = 1 << 63
      if let order = interleaved(UInt64(bitPattern: a.origin.tileX) ^ sign,
        UInt64(bitPattern: a.origin.tileY) ^ sign, UInt64(bitPattern: b.origin.tileX) ^ sign,
        UInt64(bitPattern: b.origin.tileY) ^ sign) { return order }
      if let order = interleaved(a.origin.localX == 0 ? 0 : a.origin.localX.bitPattern,
        a.origin.localY == 0 ? 0 : a.origin.localY.bitPattern,
        b.origin.localX == 0 ? 0 : b.origin.localX.bitPattern,
        b.origin.localY == 0 ? 0 : b.origin.localY.bitPattern) { return order }
      return WorkspaceSpatialIndex.idOrder(a.id, b.id)
    }
  }
  fileprivate struct PaintKey: Comparable, Sendable {
    let z: Double
    let id: WorkspaceSpatialID
    init(_ entry: WorkspaceSpatialEntry) { z = entry.zIndex; id = entry.id }
    static func < (a: Self, b: Self) -> Bool {
      a.z == b.z ? WorkspaceSpatialIndex.idOrder(a.id, b.id) : a.z < b.z
    }
  }
  fileprivate struct BoundsSummary: InkActionTreeSummary {
    let bounds: WorkspaceSpatialBounds
    let kinds: WorkspaceSpatialKinds
    init(value: WorkspaceSpatialEntry, left: Self?, right: Self?) {
      var bounds = value.bounds, kinds = WorkspaceSpatialIndex.kind(of: value.id)
      if let left { bounds = bounds.union(left.bounds); kinds.formUnion(left.kinds) }
      if let right { bounds = bounds.union(right.bounds); kinds.formUnion(right.kinds) }
      self.bounds = bounds; self.kinds = kinds
    }
  }
  fileprivate typealias SpatialNode = InkActionTreeNode<SpatialKey, WorkspaceSpatialEntry, BoundsSummary>
  fileprivate typealias PaintNode = InkActionTreeNode<PaintKey, WorkspaceSpatialEntry, BoundsSummary>
  fileprivate enum PaintStep: Sendable {
    case tree(PaintNode)
    case entry(WorkspaceSpatialEntry)
  }
  private enum SpatialStep {
    case tree(SpatialNode, lower: Int)
    case entry(WorkspaceSpatialEntry, rank: Int)
    var bounds: WorkspaceSpatialBounds {
      switch self { case .tree(let node, _): node.summary.bounds; case .entry(let entry, _): entry.bounds }
    }
    var range: Range<Int> {
      switch self { case .tree(let node, let lower): lower..<(lower+node.count); case .entry(_, let rank): rank..<(rank+1) }
    }
  }

  private var generation = UUID()
  private var spatial: SpatialNode?
  private var paint: PaintNode?
  private var entries: InkActionMap<Identifier, WorkspaceSpatialEntry>
  private var identifierBytes: Int

  // The three roots contain separate fixed node fields; immutable string
  // payload is shared by their entry/key values and is charged only once.
  var retainedMetadataBytes: Int {
    256 + (spatial?.count ?? 0)*SpatialNode.retainedNodeBytes
      + (paint?.count ?? 0)*PaintNode.retainedNodeBytes
      + entries.count*InkActionMapNode<Identifier,WorkspaceSpatialEntry>.retainedNodeBytes
      + identifierBytes
  }

  public init(entries source: [WorkspaceSpatialEntry]) {
    precondition(Set(source.map(\.id)).count == source.count, "Spatial addresses must be unique")
    let located = source.map { (SpatialKey($0), $0) }.sorted { $0.0 < $1.0 }
    let ordered = source.map { (PaintKey($0), $0) }.sorted { $0.0 < $1.0 }
    spatial = SpatialNode.balanced(located, 0, located.count)
    paint = PaintNode.balanced(ordered, 0, ordered.count)
    entries = .init(entries: source.map { (Identifier(id: $0.id), $0) })
    identifierBytes = source.reduce(0) { $0+Self.identifierBytes($1.id) }
  }

  public func entry(id: WorkspaceSpatialID) -> WorkspaceSpatialEntry? { entries[Identifier(id: id)] }

  /// Each supplied address replaces or removes exactly that entry. No spatial
  /// override list, old generation, or whole-index rebuild follows a pose.
  public func replacing(_ ids: Set<WorkspaceSpatialID>, with source: [WorkspaceSpatialEntry]) -> Self {
    precondition(source.allSatisfy { ids.contains($0.id) })
    let next = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
    var result = self, changed = false
    for id in ids {
      let key = Identifier(id: id), old = entries[key], value = next[id]
      guard old != value else { continue }
      changed = true
      if let old {
        if value.map({ SpatialKey($0) != SpatialKey(old) }) ?? true {
          result.spatial = result.spatial?.removing(SpatialKey(old))
        }
        if value.map({ PaintKey($0) != PaintKey(old) }) ?? true {
          result.paint = result.paint?.removing(PaintKey(old))
        }
      }
      if let value {
        result.spatial = result.spatial?.inserting(SpatialKey(value), value) ?? .init(SpatialKey(value), value)
        result.paint = result.paint?.inserting(PaintKey(value), value) ?? .init(PaintKey(value), value)
      }
      result.entries[key] = value
      if old == nil { result.identifierBytes += Self.identifierBytes(id) }
      if value == nil { result.identifierBytes -= Self.identifierBytes(id) }
    }
    if changed { result.generation = UUID() }
    return result
  }

  /// Exact spatial candidates without overview primitives. Matching bounds
  /// and kinds prune whole immutable subtrees before an entry is disclosed.
  public func intersections(in bounds: WorkspaceSpatialBounds,
    kinds: WorkspaceSpatialKinds = .all, limit: Int = 4_096) -> WorkspaceSpatialIntersectionQuery {
    precondition(limit > 0)
    guard let spatial, !kinds.isEmpty else {
      return .init(entries: [], overflow: false, statistics: .init(visitedNodes: 0, examinedEntries: 0))
    }
    var pending = [spatial], result: [WorkspaceSpatialEntry] = []
    var visits = 0, examined = 0, overflow = false
    while let node = pending.popLast() {
      visits += 1
      guard !node.summary.kinds.intersection(kinds).isEmpty, node.summary.bounds.intersects(bounds) else { continue }
      if let right = node.right { pending.append(right) }
      if let left = node.left { pending.append(left) }
      let value = node.value
      guard Self.kind(of: value.id).isSubset(of: kinds) else { continue }
      examined += 1
      guard value.bounds.intersects(bounds) else { continue }
      if result.count == limit { overflow = true; break }
      result.append(value)
    }
    result.sort(by: Self.detailOrder)
    return .init(entries: result, overflow: overflow,
      statistics: .init(visitedNodes: visits, examinedEntries: examined))
  }

  /// Bounded painter-order traversal retains only a search path. A cursor
  /// names this exact immutable generation and physical query rectangle.
  public func readPaintOrder(in bounds: WorkspaceSpatialBounds,
    after cursor: WorkspaceSpatialReadCursor? = nil, limit: Int = 64,
    maximumVisits: Int = 512) throws -> WorkspaceSpatialReadPage {
    precondition(limit > 0 && limit <= 1024 && maximumVisits > 0 && maximumVisits <= 8192)
    if let cursor, cursor.generation != generation || cursor.bounds != bounds {
      throw WorkspaceSpatialReadError.cursorMismatch
    }
    var pending = cursor?.pending ?? paint.map { [PaintStep.tree($0)] } ?? []
    var result: [WorkspaceSpatialEntry] = [], visits = 0
    while visits < maximumVisits, result.count < limit, let step = pending.popLast() {
      visits += 1
      switch step {
      case .tree(let node):
        guard node.summary.bounds.intersects(bounds) else { continue }
        if let right = node.right { pending.append(.tree(right)) }
        if node.value.bounds.intersects(bounds) { pending.append(.entry(node.value)) }
        if let left = node.left { pending.append(.tree(left)) }
      case .entry(let value): result.append(value)
      }
    }
    return .init(entries: result, next: pending.isEmpty ? nil : .init(generation: generation,
      bounds: bounds, pending: pending), visitedNodes: visits)
  }

  /// Overview primitives and explicit pins share the same current geometry.
  /// The finite frontier always partitions its unpinned source entries.
  public func query(bounds: WorkspaceSpatialBounds, limit: Int = 256,
    minimumProjectedExtent: Double = 12, scale: Double = 1,
    pinned: Set<WorkspaceSpatialID> = []) -> WorkspaceSpatialQuery {
    precondition(limit > 0 && scale.isFinite && scale > 0)
    precondition(minimumProjectedExtent.isFinite && minimumProjectedExtent >= 0)
    let pinnedEntries = pinned.compactMap { entry(id: $0) }
    let pinnedRanks = pinnedEntries.compactMap { rank(of: SpatialKey($0)) }.sorted()
    var details = pinnedEntries
    guard let spatial else {
      return .init(entries: [], aggregates: [], statistics: .init(visitedNodes: 0, examinedEntries: 0))
    }
    var visited = 1, examined = 0, ordinaryCount = 0, next = 0
    let maximumVisits = max(64, limit.multipliedReportingOverflow(by: 8).overflow ? Int.max : limit*8)
    var frontier: [SpatialStep] = spatial.summary.bounds.intersects(bounds) ? [.tree(spatial, lower: 0)] : []
    var aggregates: [WorkspaceSpatialAggregate] = []
    while next < frontier.count {
      let step = frontier[next]; next += 1
      let range = step.range
      let pinnedCount = Self.lowerBound(pinnedRanks, range.upperBound)-Self.lowerBound(pinnedRanks, range.lowerBound)
      let count = range.count-pinnedCount
      guard count > 0 else { continue }
      let available = limit-ordinaryCount-aggregates.count-(frontier.count-next)
      let extent = max(step.bounds.width, step.bounds.height)*scale
      let leaf: WorkspaceSpatialEntry?
      var children: [SpatialStep] = []
      switch step {
      case .entry(let entry, _): leaf = entry
      case .tree(let node, let lower):
        examined += 1
        if node.count == 1 { leaf = node.value }
        else {
          leaf = nil
          let leftCount = node.left?.count ?? 0
          if let left = node.left { children.append(.tree(left, lower: lower)) }
          children.append(.entry(node.value, rank: lower+leftCount))
          if let right = node.right { children.append(.tree(right, lower: lower+leftCount+1)) }
        }
      }
      if let leaf {
        if extent >= minimumProjectedExtent { details.append(leaf); ordinaryCount += 1 }
        else { aggregates.append(.init(id: range.lowerBound, bounds: step.bounds, count: 1)) }
      } else if extent >= minimumProjectedExtent, available >= children.count,
        children.contains(where: { $0.bounds != step.bounds }) || count <= available,
        visited <= maximumVisits-children.count {
        visited += children.count
        frontier.append(contentsOf: children.filter { $0.bounds.intersects(bounds) })
      } else {
        aggregates.append(.init(id: range.lowerBound, bounds: step.bounds, count: count))
      }
    }
    details.sort(by: Self.detailOrder); aggregates.sort { $0.id < $1.id }
    return .init(entries: details, aggregates: aggregates,
      statistics: .init(visitedNodes: visited, examinedEntries: examined))
  }

  private func rank(of key: SpatialKey) -> Int? {
    var node = spatial, offset = 0
    while let current = node {
      if key < current.key { node = current.left }
      else if key > current.key { offset += (current.left?.count ?? 0)+1; node = current.right }
      else { return offset+(current.left?.count ?? 0) }
    }
    return nil
  }
  private static func identifierBytes(_ id: WorkspaceSpatialID) -> Int {
    if case .element(let text) = id { return text.utf8.count*2+64 }
    return 0
  }
  private static func detailOrder(_ a: WorkspaceSpatialEntry, _ b: WorkspaceSpatialEntry) -> Bool {
    a.zIndex == b.zIndex ? idOrder(a.id, b.id) : a.zIndex < b.zIndex
  }
  private static func idOrder(_ a: WorkspaceSpatialID, _ b: WorkspaceSpatialID) -> Bool {
    switch (a, b) {
    case (.item(let x), .item(let y)): x < y
    case (.element(let x), .element(let y)): x < y
    case (.item, .element): true
    case (.element, .item): false
    }
  }
  private static func kind(of id: WorkspaceSpatialID) -> WorkspaceSpatialKinds {
    switch id { case .item: .items; case .element: .elements }
  }
  private static func lowerBound(_ positions: [Int], _ value: Int) -> Int {
    var lower = 0, upper = positions.count
    while lower < upper {
      let middle = lower+(upper-lower)/2
      if positions[middle] < value { lower = middle+1 } else { upper = middle }
    }
    return lower
  }
}
