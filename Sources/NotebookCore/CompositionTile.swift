import Foundation

/// One centred grid at every density. Its 512-pixel cells keep WorldPoint's
/// integer tile address; the zero axis is not a permanent four-cell boundary.
/// Levels are independent caches, not a quadtree: a new whole coverage replaces
/// the old one, so no parent-cell relation is used by rendering or admission.
public struct CompositionTile: Hashable, Codable, Sendable {
  public static let pixelSize = 512
  public static let levels = -12...36
  private static let format = 2
  public let level: Int
  public let column: Int64
  public let row: Int64
  public let localColumn: Int
  public let localRow: Int

  public var worldSize: Double { WorldPoint.tileSize * pow(2, Double(level - 4)) }
  public var origin: WorldPoint { corner(maximum: false) }
  public var bounds: WorkspaceSpatialBounds { .init(origin: origin, maximum: corner(maximum: true)) }

  private func corner(maximum: Bool) -> WorldPoint {
    let sign = maximum ? 1.0 : -1.0
    if level > 4 {
      let factor = Int64(1) << (level - 4), half = factor / 2
      return .init(tileX: column * factor + (maximum ? half : -half),
        tileY: row * factor + (maximum ? half : -half), localX: 0, localY: 0)
    }
    let count = 1 << (4 - level), span = worldSize
    func edge(_ local: Int) -> Double {
      // Match the adjacent cell's normalised negative half-cell exactly at
      // a WorldPoint boundary, rather than two differently rounded products.
      maximum && local + 1 == count ? WorldPoint.tileSize - span / 2 : (Double(local) + sign / 2) * span
    }
    return .init(tileX: column, tileY: row, localX: edge(localColumn), localY: edge(localRow))
  }

  public init?(containing point: WorldPoint, level: Int) {
    guard Self.levels.contains(level),
      let x = Self.coordinate(tile: point.tileX, local: point.localX, level: level),
      let y = Self.coordinate(tile: point.tileY, local: point.localY, level: level) else { return nil }
    self.init(level: level, column: x.0, row: y.0, localColumn: x.1, localRow: y.1)
  }

  private static func coordinate(tile: Int64, local: Double, level: Int) -> (Int64, Int)? {
    if level > 4 {
      let factor = Int64(1) << (level - 4)
      // A nonnegative remainder avoids flattening a distant Int64 address.
      let remainder = tile % factor
      let positiveRemainder = remainder < 0 ? remainder + factor : remainder
      let center = floorDiv(tile, factor).addingReportingOverflow(positiveRemainder >= factor / 2 ? 1 : 0)
      return center.overflow ? nil : (center.partialValue, 0)
    }
    let count = 1 << (4 - level), span = WorldPoint.tileSize / Double(count)
    let cell = Int(floor(local / span + 0.5))
    if cell == count {
      let next = tile.addingReportingOverflow(1)
      return next.overflow ? nil : (next.partialValue, 0)
    }
    return (tile, cell)
  }

  private init?(level: Int, column: Int64, row: Int64, localColumn: Int, localRow: Int) {
    guard Self.levels.contains(level) else { return nil }
    if level > 4 {
      let factor = Int64(1) << (level - 4), half = factor / 2
      for coordinate in [column, row] {
        let center = coordinate.multipliedReportingOverflow(by: factor)
        guard !center.overflow, !center.partialValue.subtractingReportingOverflow(half).overflow,
          !center.partialValue.addingReportingOverflow(half).overflow else { return nil }
      }
      guard localColumn == 0, localRow == 0 else { return nil }
    } else {
      let count = 1 << (4 - level)
      guard (0..<count).contains(localColumn), (0..<count).contains(localRow),
        column > Int64.min || localColumn > 0, row > Int64.min || localRow > 0 else { return nil }
    }
    self.level = level; self.column = column; self.row = row
    self.localColumn = localColumn; self.localRow = localRow
  }

  public func offset(columns: Int, rows: Int) -> Self? {
    if level > 4 {
      let x = column.addingReportingOverflow(Int64(columns)), y = row.addingReportingOverflow(Int64(rows))
      guard !x.overflow, !y.overflow else { return nil }
      return .init(level: level, column: x.partialValue, row: y.partialValue, localColumn: 0, localRow: 0)
    }
    let count = Int64(1) << (4 - level)
    let x = Int64(localColumn).addingReportingOverflow(Int64(columns))
    let y = Int64(localRow).addingReportingOverflow(Int64(rows))
    guard !x.overflow, !y.overflow else { return nil }
    let dx = Self.floorDiv(x.partialValue, count), dy = Self.floorDiv(y.partialValue, count)
    let cx = column.addingReportingOverflow(dx), cy = row.addingReportingOverflow(dy)
    guard !cx.overflow, !cy.overflow else { return nil }
    let lx = x.partialValue % count, ly = y.partialValue % count
    return .init(level: level, column: cx.partialValue, row: cy.partialValue,
      localColumn: Int(lx < 0 ? lx + count : lx), localRow: Int(ly < 0 ? ly + count : ly))
  }

  private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
    value / divisor - (value % divisor < 0 ? 1 : 0)
  }

  private enum CodingKeys: String, CodingKey { case format, level, column, row, localColumn, localRow }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .format) == Self.format,
      let tile = Self(level: try values.decode(Int.self, forKey: .level),
        column: try values.decode(Int64.self, forKey: .column), row: try values.decode(Int64.self, forKey: .row),
        localColumn: try values.decode(Int.self, forKey: .localColumn), localRow: try values.decode(Int.self, forKey: .localRow))
    else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid centred composition tile")) }
    self = tile
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(Self.format, forKey: .format)
    try values.encode(level, forKey: .level)
    try values.encode(column, forKey: .column); try values.encode(row, forKey: .row)
    try values.encode(localColumn, forKey: .localColumn); try values.encode(localRow, forKey: .localRow)
  }
}

public enum CompositionTileError: Error, Equatable { case projectionUnavailable }

public struct CompositionTileCoverage: Equatable, Sendable {
  public let level: Int
  public let tiles: [CompositionTile]

  /// Hysteresis keeps the prepared level through a small reversed pinch. A
  /// finite tile budget can coarsen the result, never grow an unbounded queue.
  public init(bounds: WorkspaceSpatialBounds, pixelsPerWorldPoint: Double,
    previousLevel: Int? = nil, maximumTiles: Int = 32) throws {
    precondition(pixelsPerWorldPoint.isFinite && pixelsPerWorldPoint > 0 && (1...256).contains(maximumTiles))
    let target = log2(Double(CompositionTile.pixelSize) * 16 / WorldPoint.tileSize) - log2(pixelsPerWorldPoint)
    var chosen = max(CompositionTile.levels.lowerBound, min(CompositionTile.levels.upperBound, Int(floor(target))))
    if let previousLevel, CompositionTile.levels.contains(previousLevel) {
      let ratio = WorldPoint.tileSize * pow(2, Double(previousLevel - 4)) * pixelsPerWorldPoint / Double(CompositionTile.pixelSize)
      if (0.6...1.6).contains(ratio) { chosen = previousLevel }
    }
    var prepared: [CompositionTile] = []
    while let first = CompositionTile(containing: bounds.origin, level: chosen) {
      let inset = first.origin.delta(to: bounds.origin)
      let columns = ceil((inset.x + bounds.width) / first.worldSize)
      let rows = ceil((inset.y + bounds.height) / first.worldSize)
      if columns.isFinite, rows.isFinite, columns <= Double(maximumTiles), rows <= Double(maximumTiles),
        max(1, columns) * max(1, rows) <= Double(maximumTiles) {
        for row in 0..<max(1, Int(rows)) {
          for column in 0..<max(1, Int(columns)) {
            if let tile = first.offset(columns: column, rows: row) { prepared.append(tile) }
          }
        }
        break
      }
      guard chosen < CompositionTile.levels.upperBound else { break }
      chosen += 1
    }
    guard let first = prepared.first, let last = prepared.last,
      WorkspaceSpatialBounds(origin: first.origin, maximum: last.bounds.maximum).contains(bounds)
    else { throw CompositionTileError.projectionUnavailable }
    level = chosen
    tiles = prepared
  }
}
