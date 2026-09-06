import Foundation
import Testing
@testable import NotebookCore

struct CompositionTileTests {
  @Test func cellsKeepTheirWorldAddressAcrossNegativeAndVeryDistantCoordinates() throws {
    for center in [WorldPoint.zero, .init(x: -0.1, y: -10),
      .init(tileX: 9_000_000_000_000, tileY: -9_000_000_000_000, localX: 723.1, localY: 71.3)] {
      for level in -10...20 {
        let tile = try #require(CompositionTile(containing: center, level: level))
        #expect(tile.bounds.contains(.init(origin: center, width: 0, height: 0)))
        let right = try #require(tile.offset(columns: 1, rows: 0))
        #expect(abs(tile.origin.delta(to: right.origin).x - tile.worldSize) < tile.worldSize * 1e-10)
        #expect(right.offset(columns: -1, rows: 0) == tile)
        #expect(tile.parent?.bounds.contains(tile.bounds) == true, "level \(level), point \(center), tile \(tile), parent \(String(describing: tile.parent))")
        #expect(try JSONDecoder().decode(CompositionTile.self, from: JSONEncoder().encode(tile)) == tile)
      }
    }
  }

  @Test func aSmallReversedPinchKeepsThePreparedLevelAndTileCountIsBounded() throws {
    let bounds = WorkspaceSpatialBounds(origin: .init(x: -4000, y: -1000), width: 12000, height: 8000)
    let initial = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: 0.2)
    for scale in [0.19, 0.2, 0.21, 0.195, 0.2] {
      let next = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: scale, previousLevel: initial.level)
      #expect(next.level == initial.level)
      #expect(next.tiles == initial.tiles)
    }
    for limit in [4, 8, 16, 32] {
      let coverage = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: 20, maximumTiles: limit)
      #expect(!coverage.tiles.isEmpty)
      #expect(coverage.tiles.count <= limit)
      #expect(coverage.tiles.contains { $0.bounds.contains(.init(origin: bounds.origin, width: 0, height: 0)) })
      #expect(coverage.tiles.contains { $0.bounds.contains(.init(origin: bounds.maximum, width: 0, height: 0)) })
    }
  }

  @Test func unrepresentableCoverageIsNotReportedAsAnEmptyBoard() throws {
    let bounds = WorkspaceSpatialBounds(origin: .init(x: -1, y: -1), width: 2, height: 2)
    #expect(throws: CompositionTileError.projectionUnavailable) {
      try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: 1, maximumTiles: 1)
    }
    for density in [Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
      let coverage = try CompositionTileCoverage(bounds: bounds, pixelsPerWorldPoint: density)
      #expect(!coverage.tiles.isEmpty)
      #expect(coverage.tiles.count <= 32)
    }
  }

  @Test func painterPagesBoundWorkAndPreserveExactOrderWithoutDroppingCoincidentSources() throws {
    let bounds = WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)
    let entries = (0..<100_000).reversed().map {
      WorkspaceSpatialEntry(id: .element("source-\($0)"), bounds: bounds, zIndex: Double($0))
    }
    let index = WorkspaceSpatialIndex(entries: entries)
    var cursor: WorkspaceSpatialReadCursor?
    var count = 0
    repeat {
      let page = try index.readPaintOrder(in: bounds, after: cursor, limit: 37, maximumVisits: 64)
      #expect(page.entries.count <= 37)
      #expect(page.visitedNodes <= 64)
      for entry in page.entries {
        #expect(entry.id == .element("source-\(count)"))
        count += 1
      }
      cursor = page.next
    } while cursor != nil
    #expect(count == 100_000)
    let first = try index.readPaintOrder(in: bounds, limit: 1)
    let different = WorkspaceSpatialIndex(entries: entries)
    #expect(throws: WorkspaceSpatialReadError.cursorMismatch) {
      try different.readPaintOrder(in: bounds, after: first.next)
    }
  }
}
