import Foundation
import Testing
@testable import NotebookCore

@Suite("Workspace spatial index")
struct WorkspaceSpatialIndexTests {
  private func entry(
    _ id: Int, x: Double = 0, y: Double = 0,
    width: Double = 20, height: Double = 20, z: Double = 0,
    origin: WorldPoint? = nil
  ) -> WorkspaceSpatialEntry {
    WorkspaceSpatialEntry(
      id: .element("element-\(id)"),
      bounds: WorkspaceSpatialBounds(origin: origin ?? WorldPoint(x: x, y: y), width: width, height: height),
      zIndex: z
    )
  }

  @Test("Boundary contact is included without flattening world coordinates")
  func boundariesAndDistantTiles() {
    let distant = WorldPoint(tileX: 1 << 54, tileY: -(1 << 54), localX: 13.125, localY: 28.25)
    let entries = [entry(0, origin: distant), entry(1, origin: distant.offsetBy(x: 20.25, y: 0))]
    let index = WorkspaceSpatialIndex(entries: entries)
    let atRightEdge = WorkspaceSpatialBounds(origin: distant.offsetBy(x: 20, y: 5), width: 0, height: 0)
    let edge = index.query(bounds: atRightEdge, minimumProjectedExtent: 0)
    #expect(edge.entries.map(\.id) == [.element("element-0")])
    #expect(edge.aggregates.isEmpty)
    let between = index.query(
      bounds: WorkspaceSpatialBounds(origin: distant.offsetBy(x: 20.125, y: 5), width: 0, height: 0),
      minimumProjectedExtent: 0
    )
    #expect(between.entries.isEmpty)
    #expect(between.aggregates.isEmpty)
  }

  @Test("Bounds preserve exact endpoints across distant positive and negative tiles")
  func distantUnionEndpoints() {
    let a = WorldPoint(tileX: -(1 << 54), tileY: 1 << 54, localX: 23.125, localY: 5)
    let b = WorldPoint(tileX: 1 << 54, tileY: 1 << 54, localX: 77.25, localY: 5)
    let sources = [entry(0, origin: a), entry(1, origin: b)]
    let index = WorkspaceSpatialIndex(entries: sources)
    for source in sources {
      let result = index.query(bounds: source.bounds, minimumProjectedExtent: 0)
      #expect(result.entries.map(\.id) == [source.id])
    }
    let result = index.query(bounds: sources[1].bounds, limit: 1, minimumProjectedExtent: 0)
    #expect(result.aggregates.count == 1)
    #expect(result.aggregates.first?.bounds.maximum == b.offsetBy(x: 20, y: 20))
    #expect(result.aggregates.first?.count == 2)
  }

  @Test("Tile-range extremes do not overflow broad-phase comparisons")
  func extremeTileRange() {
    let a = WorldPoint(tileX: Int64.min + 1, tileY: 0, localX: 0, localY: 0)
    let b = WorldPoint(tileX: Int64.max - 1, tileY: 0, localX: 100, localY: 0)
    let sources = [entry(0, origin: a), entry(1, origin: b)]
    let index = WorkspaceSpatialIndex(entries: sources)
    for source in sources {
      let result = index.query(bounds: source.bounds, minimumProjectedExtent: 0)
      #expect(result.entries == [source])
      #expect(result.aggregates.isEmpty)
      let coarse = index.query(bounds: source.bounds, limit: 1)
      let clipped = coarse.aggregates.first?.bounds.intersection(source.bounds)
      #expect(clipped == source.bounds,
        "Projection clips tiled endpoints before taking a signed camera delta")
    }
  }

  @Test("Exact uncapped queries match a brute-force oracle and deterministic z order")
  func randomOracle() {
    var random = Random(seed: 91)
    let sources = (0..<1_200).map { id in
      entry(
        id, x: random.value(20_000) - 10_000, y: random.value(20_000) - 10_000,
        width: random.value(180) + 1, height: random.value(240) + 1,
        z: Double(id % 13)
      )
    }
    let index = WorkspaceSpatialIndex(entries: sources)
    for _ in 0..<40 {
      let viewport = WorkspaceSpatialBounds(
        origin: WorldPoint(x: random.value(20_000) - 10_000, y: random.value(20_000) - 10_000),
        width: 2_000, height: 2_000
      )
      let expected = sources.filter { $0.bounds.intersects(viewport) }.sorted {
        $0.zIndex == $1.zIndex ? elementID($0.id) < elementID($1.id) : $0.zIndex < $1.zIndex
      }
      let actual = index.query(bounds: viewport, limit: sources.count, minimumProjectedExtent: 0)
      #expect(actual.entries == expected)
      #expect(actual.aggregates.isEmpty)
    }
  }

  @Test("Rebuilt geometry reflects moves and removals without changing the previous generation")
  func generations() {
    let before = WorkspaceSpatialIndex(entries: [entry(0), entry(1, x: 40)])
    let after = WorkspaceSpatialIndex(entries: [entry(0, x: 200)])
    let viewport = WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)
    #expect(before.query(bounds: viewport, minimumProjectedExtent: 0).entries.count == 2)
    #expect(after.query(bounds: viewport, minimumProjectedExtent: 0).entries.isEmpty)
    #expect(before.entry(id: .element("element-0"))?.bounds.origin == .zero)
    #expect(after.entry(id: .element("element-0"))?.bounds.origin == WorldPoint(x: 200, y: 0))
    #expect(after.entry(id: .element("element-1")) == nil)
  }

  @Test("Empty indices and absent pins return no fabricated owners")
  func emptyIndex() {
    let index = WorkspaceSpatialIndex(entries: [])
    let query = index.query(
      bounds: .init(origin: .zero, width: 1, height: 1),
      pinned: [.element("missing")]
    )
    #expect(query.entries.isEmpty && query.aggregates.isEmpty)
    #expect(query.statistics.visitedNodes == 0)
    #expect(index.entry(id: .element("missing")) == nil)
  }

  @Test("Pinned owners survive culling and are never counted inside an aggregate")
  func pinnedOwners() {
    let sources = (0..<100).map { entry($0) } + [entry(100, x: 4_000)]
    let index = WorkspaceSpatialIndex(entries: sources)
    let pinned: Set<WorkspaceSpatialID> = [.element("element-0"), .element("element-99"), .element("element-100")]
    let query = index.query(
      bounds: .init(origin: .zero, width: 20, height: 20), limit: 1,
      minimumProjectedExtent: 0, pinned: pinned
    )
    #expect(Set(query.entries.map(\.id)) == pinned)
    #expect(query.aggregates.count == 1)
    #expect(query.aggregates.first?.count == 98)
    #expect(query.entries.count + query.aggregates.reduce(0) { $0 + $1.count } == 101)
    #expect(query.aggregates.first?.bounds.contains(sources[100].bounds) == true)
  }

  @Test("Small projected objects are represented, not silently dropped")
  func projectedExtent() {
    let sources = (0..<100).map { entry($0, x: Double($0 * 30)) }
    let index = WorkspaceSpatialIndex(entries: sources)
    let viewport = WorkspaceSpatialBounds(origin: .zero, width: 4_000, height: 100)
    let coarse = index.query(bounds: viewport, scale: 0.000_1)
    #expect(coarse.entries.isEmpty)
    #expect(coarse.aggregates.count == 1)
    #expect(coarse.aggregates.first?.count == 100)
    let detailed = index.query(bounds: viewport, minimumProjectedExtent: 0)
    #expect(detailed.entries.count == 100)
    #expect(detailed.aggregates.isEmpty)
  }

  @Test("Aggregate identities and membership are deterministic across equivalent generations")
  func deterministicAggregates() {
    let sources = (0..<500).map { entry($0, x: Double($0 % 20) * 30, y: Double($0 / 20) * 30) }
    let viewport = WorkspaceSpatialBounds(origin: .zero, width: 1_000, height: 1_000)
    let first = WorkspaceSpatialIndex(entries: sources)
    let second = WorkspaceSpatialIndex(entries: sources.reversed())
    let a = first.query(bounds: viewport, limit: 20)
    #expect(a == first.query(bounds: viewport, limit: 20))
    #expect(a == second.query(bounds: viewport, limit: 20))
  }

  @Test("One hundred thousand sparse sources keep local and overview work bounded")
  func sparseHundredThousand() {
    let sources = (0..<100_000).map { entry($0, x: Double($0 % 1_000) * 100, y: Double($0 / 1_000) * 100) }
    let index = WorkspaceSpatialIndex(entries: sources)
    let local = index.query(
      bounds: .init(origin: WorldPoint(x: 54_800, y: 6_700), width: 220, height: 220),
      minimumProjectedExtent: 0
    )
    #expect(local.entries.count == 9)
    #expect(local.aggregates.isEmpty)
    #expect(local.statistics.visitedNodes < 256)
    #expect(local.statistics.examinedEntries == 9)
    let overview = index.query(
      bounds: .init(origin: WorldPoint(x: -1, y: -1), width: 100_100, height: 10_100),
      limit: 96, minimumProjectedExtent: 0
    )
    #expect(overview.entries.count + overview.aggregates.count <= 96)
    #expect(overview.entries.count + overview.aggregates.reduce(0) { $0 + $1.count } == sources.count)
    #expect(overview.statistics.visitedNodes <= 96 * 8)
    #expect(overview.statistics.examinedEntries <= 96)
  }

  @Test("One hundred thousand overlapping sources respect the same primitive and work budgets")
  func denseHundredThousand() {
    let sources = (0..<100_000).map { entry($0, z: Double($0 % 7)) }
    let index = WorkspaceSpatialIndex(entries: sources)
    let pinned: Set<WorkspaceSpatialID> = [.element("element-1"), .element("element-99999")]
    let query = index.query(
      bounds: sources[0].bounds, limit: 96, minimumProjectedExtent: 0, pinned: pinned
    )
    #expect(Set(query.entries.map(\.id)).isSuperset(of: pinned))
    #expect(query.entries.count + query.aggregates.count <= 96 + pinned.count)
    #expect(query.aggregates.count == 1,
      "Coincident sources form one overview, not 96 indistinguishable labels")
    #expect(query.entries.count + query.aggregates.reduce(0) { $0 + $1.count } == sources.count)
    #expect(query.statistics.visitedNodes <= 96 * 8)
    #expect(query.statistics.examinedEntries <= 96)
    #expect(query.entries.map(\.id).count == Set(query.entries.map(\.id)).count)
  }

  private func elementID(_ id: WorkspaceSpatialID) -> String {
    if case .element(let value) = id { value } else { "" }
  }

  private struct Random {
    var seed: UInt64
    mutating func value(_ maximum: Double) -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Double(seed >> 11) / Double(UInt64.max >> 11) * maximum
    }
  }
}
