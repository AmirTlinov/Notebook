import Foundation

/// A 512-pixel derivative addresses the same world on every device. Fine cells
/// retain the WorldPoint tile and a local integer cell; large coordinates are
/// never flattened into floating point to choose a tile or its parent.
public struct CompositionTile: Hashable, Codable, Sendable {
  public static let pixelSize = 512
  public static let levels = -12...36
  public let level: Int
  public let column: Int64
  public let row: Int64
  public let localColumn: Int
  public let localRow: Int

  public var worldSize: Double { WorldPoint.tileSize * pow(2, Double(level - 4)) }
  public var origin: WorldPoint {
    if level >= 4 {
      let factor = Int64(1) << (level - 4)
      return .init(tileX: column * factor, tileY: row * factor, localX: 0, localY: 0)
    }
    return .init(tileX: column, tileY: row,
      localX: Double(localColumn) * worldSize, localY: Double(localRow) * worldSize)
  }
  public var bounds: WorkspaceSpatialBounds {
    let maximum: WorldPoint
    if level >= 4 {
      let factor = Int64(1) << (level - 4)
      maximum = .init(tileX: (column + 1) * factor, tileY: (row + 1) * factor, localX: 0, localY: 0)
    } else {
      let count = 1 << (4 - level)
      maximum = .init(tileX: column + (localColumn + 1 == count ? 1 : 0),
        tileY: row + (localRow + 1 == count ? 1 : 0),
        localX: localColumn + 1 == count ? 0 : Double(localColumn + 1) * worldSize,
        localY: localRow + 1 == count ? 0 : Double(localRow + 1) * worldSize)
    }
    return .init(origin: origin, maximum: maximum)
  }
  public var parent: Self? {
    if level >= 4 {
      return .init(level: level + 1, column: Self.floorDiv(column, 2), row: Self.floorDiv(row, 2), localColumn: 0, localRow: 0)
    }
    return .init(level: level + 1, column: column, row: row,
      localColumn: localColumn / 2, localRow: localRow / 2)
  }

  public init?(containing point: WorldPoint, level: Int) {
    guard Self.levels.contains(level) else { return nil }
    if level >= 4 {
      let factor = Int64(1) << (level - 4)
      self.init(level: level, column: Self.floorDiv(point.tileX, factor),
        row: Self.floorDiv(point.tileY, factor), localColumn: 0, localRow: 0)
    } else {
      let span = WorldPoint.tileSize * pow(2, Double(level - 4))
      self.init(level: level, column: point.tileX, row: point.tileY,
        localColumn: Int(floor(point.localX / span)), localRow: Int(floor(point.localY / span)))
    }
  }

  private init?(level: Int, column: Int64, row: Int64, localColumn: Int, localRow: Int) {
    guard Self.levels.contains(level) else { return nil }
    if level >= 4 {
      let factor = Int64(1) << (level - 4)
      for coordinate in [column, row] {
        let start = coordinate.multipliedReportingOverflow(by: factor)
        guard !start.overflow, !start.partialValue.addingReportingOverflow(factor).overflow else { return nil }
      }
      guard localColumn == 0, localRow == 0 else { return nil }
    } else {
      let count = 1 << (4 - level)
      guard (0..<count).contains(localColumn), (0..<count).contains(localRow),
        column < Int64.max, row < Int64.max else { return nil }
    }
    self.level = level; self.column = column; self.row = row
    self.localColumn = localColumn; self.localRow = localRow
  }

  public func offset(columns: Int, rows: Int) -> Self? {
    if level >= 4 {
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
    return .init(level: level, column: cx.partialValue, row: cy.partialValue,
      localColumn: Int(x.partialValue - dx * count), localRow: Int(y.partialValue - dy * count))
  }

  private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
    value / divisor - (value % divisor < 0 ? 1 : 0)
  }

  private enum CodingKeys: String, CodingKey { case level, column, row, localColumn, localRow }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard let tile = Self(level: try values.decode(Int.self, forKey: .level),
      column: try values.decode(Int64.self, forKey: .column), row: try values.decode(Int64.self, forKey: .row),
      localColumn: try values.decode(Int.self, forKey: .localColumn), localRow: try values.decode(Int.self, forKey: .localRow))
    else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid composition tile")) }
    self = tile
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
