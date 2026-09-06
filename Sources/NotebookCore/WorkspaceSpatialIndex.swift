import Foundation

/// A spatial address references its existing content owner; it never carries source data.
public enum WorkspaceSpatialID: Hashable, Sendable {
  case item(UUID)
  case element(String)
}

/// Axis-aligned world bounds retain tiled endpoints even when an index node spans distant tiles.
public struct WorkspaceSpatialBounds: Equatable, Sendable {
  public let origin: WorldPoint
  public let width: Double
  public let height: Double
  public let maximum: WorldPoint

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

  fileprivate func union(_ other: Self) -> Self {
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

/// A cursor names one immutable index and one physical query. Its stack is a
/// depth-first path, bounded by tree depth rather than by the number of sources.
public struct WorkspaceSpatialReadCursor: Sendable {
  fileprivate let generation: UUID
  fileprivate let bounds: WorkspaceSpatialBounds
  fileprivate let pending: [Int]
}

public enum WorkspaceSpatialReadError: Error, Equatable { case cursorMismatch }

public struct WorkspaceSpatialReadPage: Sendable {
  public let entries: [WorkspaceSpatialEntry]
  public let next: WorkspaceSpatialReadCursor?
  public let visitedNodes: Int
}

/// Immutable derived geometry. Build once per geometry revision, query without reading content.
/// Query work and returned primitives are bounded even when every source overlaps the viewport.
public struct WorkspaceSpatialIndex: Sendable {
  private struct Node: Sendable {
    var bounds: WorkspaceSpatialBounds
    var range: Range<Int>
    var children: (Int, Int)?
  }

  private let generation = UUID()
  private let paintEntries: [WorkspaceSpatialEntry]
  private let paintNodes: [Node]
  private let entries: [WorkspaceSpatialEntry]
  private let positions: [WorkspaceSpatialID: Int]
  private let nodes: [Node]

  public init(entries source: [WorkspaceSpatialEntry]) {
    var entries = source
    precondition(Set(source.map(\.id)).count == source.count, "Spatial addresses must be unique")
    var nodes: [Node] = []
    nodes.reserveCapacity(source.count * 2)
    if !entries.isEmpty {
      Self.build(entries: &entries, range: entries.indices, nodes: &nodes)
    }
    self.entries = entries
    self.nodes = nodes
    let ordered = source.sorted(by: Self.detailOrder)
    var orderedNodes: [Node] = []
    if !ordered.isEmpty { Self.buildPaint(entries: ordered, range: ordered.indices, nodes: &orderedNodes) }
    paintEntries = ordered
    paintNodes = orderedNodes
    positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
  }

  public func entry(id: WorkspaceSpatialID) -> WorkspaceSpatialEntry? {
    positions[id].map { entries[$0] }
  }

  /// Exact, stable painter order for sequential raster preparation. Each call
  /// bounds both output and traversal, including sparse and fully overlapping
  /// compositions. An empty page with a cursor is progress, not an empty region.
  public func readPaintOrder(in bounds: WorkspaceSpatialBounds,
    after cursor: WorkspaceSpatialReadCursor? = nil, limit: Int = 64,
    maximumVisits: Int = 512) throws -> WorkspaceSpatialReadPage {
    precondition(limit > 0 && limit <= 1024 && maximumVisits > 0 && maximumVisits <= 8192)
    if let cursor, cursor.generation != generation || cursor.bounds != bounds {
      throw WorkspaceSpatialReadError.cursorMismatch
    }
    var pending = cursor?.pending ?? (paintNodes.isEmpty ? [] : [0])
    var result: [WorkspaceSpatialEntry] = []
    var visits = 0
    while visits < maximumVisits, result.count < limit, let id = pending.popLast() {
      let node = paintNodes[id]
      visits += 1
      guard node.bounds.intersects(bounds) else { continue }
      if let children = node.children {
        pending.append(children.1)
        pending.append(children.0)
      } else {
        result.append(paintEntries[node.range.lowerBound])
      }
    }
    return .init(entries: result, next: pending.isEmpty ? nil : .init(generation: generation,
      bounds: bounds, pending: pending), visitedNodes: visits)
  }

  @discardableResult
  private static func buildPaint(entries: [WorkspaceSpatialEntry], range: Range<Int>, nodes: inout [Node]) -> Int {
    let id = nodes.count
    nodes.append(.init(bounds: entries[range.lowerBound].bounds, range: range, children: nil))
    if range.count > 1 {
      let middle = range.lowerBound + range.count / 2
      let left = buildPaint(entries: entries, range: range.lowerBound..<middle, nodes: &nodes)
      let right = buildPaint(entries: entries, range: middle..<range.upperBound, nodes: &nodes)
      nodes[id].bounds = nodes[left].bounds.union(nodes[right].bounds)
      nodes[id].children = (left, right)
    }
    return id
  }

  /// `limit` bounds ordinary details plus aggregates. Explicit pinned owners are returned
  /// additionally, including outside the viewport, and never counted again in an aggregate.
  /// A zero minimum extent requests exact details whenever the primitive budget permits.
  public func query(
    bounds: WorkspaceSpatialBounds,
    limit: Int = 256,
    minimumProjectedExtent: Double = 12,
    scale: Double = 1,
    pinned: Set<WorkspaceSpatialID> = []
  ) -> WorkspaceSpatialQuery {
    precondition(limit > 0 && scale.isFinite && scale > 0)
    precondition(minimumProjectedExtent.isFinite && minimumProjectedExtent >= 0)
    let pinnedPositions = pinned.compactMap { positions[$0] }.sorted()
    var details = pinnedPositions.map { entries[$0] }
    guard !nodes.isEmpty else {
      return WorkspaceSpatialQuery(entries: [], aggregates: [], statistics: .init(visitedNodes: 0, examinedEntries: 0))
    }
    var visited = 1
    var examined = 0
    let maximumVisits = max(64, limit.multipliedReportingOverflow(by: 8).overflow ? Int.max : limit * 8)
    var frontier: [Int] = nodes[0].bounds.intersects(bounds) ? [0] : []
    var aggregates: [WorkspaceSpatialAggregate] = []
    var ordinaryCount = 0

    var next = 0
    while next < frontier.count {
      let nodeID = frontier[next]
      next += 1
      let node = nodes[nodeID]
      let pinnedCount = Self.lowerBound(pinnedPositions, node.range.upperBound)
        - Self.lowerBound(pinnedPositions, node.range.lowerBound)
      let count = node.range.count - pinnedCount
      guard count > 0 else { continue }
      let available = limit - ordinaryCount - aggregates.count - (frontier.count - next)
      let extent = max(node.bounds.width, node.bounds.height) * scale
      // Do not draw many identical overview labels for coincident sources.
      // An uncapped query can still ask for every individual source.
      let refinementSeparatesSpace = node.children.map {
        nodes[$0.0].bounds != node.bounds || nodes[$0.1].bounds != node.bounds
      } ?? false
      if node.range.count == 1 {
        examined += 1
        let entry = entries[node.range.lowerBound]
        if entry.bounds.intersects(bounds) {
          if extent >= minimumProjectedExtent {
            details.append(entry)
            ordinaryCount += 1
          } else {
            aggregates.append(.init(id: nodeID, bounds: node.bounds, count: 1))
          }
        }
      } else if extent >= minimumProjectedExtent, available >= 2,
                (refinementSeparatesSpace || count <= available),
                visited <= maximumVisits - 2, let children = node.children {
        visited += 2
        // The frontier contains disjoint subtrees, so a failed refinement can always be
        // represented by one aggregate without dropping hidden descendants.
        if nodes[children.0].bounds.intersects(bounds) { frontier.append(children.0) }
        if nodes[children.1].bounds.intersects(bounds) { frontier.append(children.1) }
      } else {
        aggregates.append(.init(id: nodeID, bounds: node.bounds, count: count))
      }
    }
    details.sort(by: Self.detailOrder)
    aggregates.sort { $0.id < $1.id }
    return WorkspaceSpatialQuery(
      entries: details,
      aggregates: aggregates,
      statistics: .init(visitedNodes: visited, examinedEntries: examined)
    )
  }

  @discardableResult
  private static func build(entries: inout [WorkspaceSpatialEntry], range: Range<Int>, nodes: inout [Node]) -> Int {
    var bounds = entries[range.lowerBound].bounds
    for index in range.dropFirst() { bounds = bounds.union(entries[index].bounds) }
    let nodeID = nodes.count
    nodes.append(Node(bounds: bounds, range: range, children: nil))
    if range.count > 1 {
      let horizontal = bounds.width >= bounds.height
      let middle = range.lowerBound + range.count / 2
      partition(entries: &entries, range: range, middle: middle, horizontal: horizontal)
      let left = build(entries: &entries, range: range.lowerBound..<middle, nodes: &nodes)
      let right = build(entries: &entries, range: middle..<range.upperBound, nodes: &nodes)
      nodes[nodeID].children = (left, right)
    }
    return nodeID
  }

  /// In-place median selection avoids allocating or sorting a second geometry tree.
  private static func partition(entries: inout [WorkspaceSpatialEntry], range: Range<Int>, middle: Int, horizontal: Bool) {
    var lower = range.lowerBound
    var upper = range.upperBound - 1
    while lower < upper {
      let pivot = entries[lower + (upper - lower) / 2]
      var left = lower
      var right = upper
      while left <= right {
        while spatialOrder(entries[left], pivot, horizontal: horizontal) { left += 1 }
        while spatialOrder(pivot, entries[right], horizontal: horizontal) { right -= 1 }
        if left <= right {
          entries.swapAt(left, right)
          left += 1
          right -= 1
        }
      }
      if middle <= right { upper = right }
      else if middle >= left { lower = left }
      else { return }
    }
  }

  private static func spatialOrder(_ lhs: WorkspaceSpatialEntry, _ rhs: WorkspaceSpatialEntry, horizontal: Bool) -> Bool {
    let a = lhs.bounds.origin
    let b = rhs.bounds.origin
    let order = horizontal
      ? WorkspaceSpatialBounds.compare(a.tileX, a.localX, b.tileX, b.localX)
      : WorkspaceSpatialBounds.compare(a.tileY, a.localY, b.tileY, b.localY)
    if order != 0 { return order < 0 }
    return idOrder(lhs.id, rhs.id)
  }

  private static func detailOrder(_ lhs: WorkspaceSpatialEntry, _ rhs: WorkspaceSpatialEntry) -> Bool {
    if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
    return idOrder(lhs.id, rhs.id)
  }

  private static func idOrder(_ lhs: WorkspaceSpatialID, _ rhs: WorkspaceSpatialID) -> Bool {
    switch (lhs, rhs) {
    case (.item(let a), .item(let b)): return a.uuidString < b.uuidString
    case (.element(let a), .element(let b)): return a < b
    case (.item, .element): return true
    case (.element, .item): return false
    }
  }

  private static func lowerBound(_ positions: [Int], _ value: Int) -> Int {
    var lower = 0
    var upper = positions.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if positions[middle] < value { lower = middle + 1 } else { upper = middle }
    }
    return lower
  }
}
