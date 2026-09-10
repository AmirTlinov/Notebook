import Foundation
import Testing
@testable import NotebookCore

@Suite("World addresses survive the complete JSON number path exactly")
struct WorldPointCodingTests {
  @Test(arguments: [Int64(0), 1, -1, WorldPoint.maximumTileIndex, -WorldPoint.maximumTileIndex,
    WorldPoint.maximumTileIndex - 1, -WorldPoint.maximumTileIndex + 1])
  func exactAddressRoundTripThroughJSONValue(tile: Int64) throws {
    let point = WorldPoint(tileX: tile, tileY: -tile, localX: 0.25, localY: WorldPoint.tileSize.nextDown)
    #expect(try JSONValue.encode(point).decode(WorldPoint.self) == point)
    #expect(try JSONDecoder().decode(WorldPoint.self, from: JSONEncoder().encode(point)) == point)
  }

  @Test(arguments: [Int64.max, Int64.min, WorldPoint.maximumTileIndex + 1, WorldPoint.maximumTileIndex + 2,
    -WorldPoint.maximumTileIndex - 1, -WorldPoint.maximumTileIndex - 2])
  func unrepresentableAddressesFailBeforeBecomingRoundedOwners(tile: Int64) throws {
    let point = WorldPoint(tileX: tile, tileY: 0, localX: 0, localY: 0)
    #expect(!point.isValid)
    #expect(throws: EncodingError.self) { try JSONValue.encode(point) }
    let raw = Data("{\"tileX\":\(tile),\"tileY\":0,\"localX\":0,\"localY\":0}".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorldPoint.self, from: raw) }
    let intermediary = try JSONDecoder().decode(JSONValue.self, from: raw)
    #expect(throws: DecodingError.self) { try intermediary.decode(WorldPoint.self) }
  }

  @Test func arbitraryProgramFieldsAreNotMistakenForCoordinates() throws {
    let source: JSONValue = .object(["tileX": .number(1e30), "localX": .number(-100), "note": .string("program data")])
    #expect(source.isValid)
    #expect(try JSONValue.encode(source) == source)
  }

  @Test func endpointsStillAllowExactNearbyOffsetsAndOverflowFreeDeltas() throws {
    let left = WorldPoint(tileX: -WorldPoint.maximumTileIndex, tileY: 0, localX: 0, localY: 0)
    let right = WorldPoint(tileX: WorldPoint.maximumTileIndex, tileY: 0, localX: 0, localY: 0)
    #expect(left.delta(to: right).x.isFinite)
    let adjacent = right.offsetBy(x: -1, y: 1)
    #expect(adjacent.tileX == right.tileX - 1)
    #expect(try JSONValue.encode(adjacent).decode(WorldPoint.self) == adjacent)
  }
}
