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

@Suite("Camera transitions admit exact centers before publication")
struct CameraWorldAddressTests {
  @Test(arguments: [Int64(-1), 1])
  func edgePanAndPinchRefuseWholeTransitionsAndAllowTheReturn(sign: Int64) throws {
    for axis in ["x", "y"] {
      let point = WorldPoint(tileX: axis == "x" ? sign * WorldPoint.maximumTileIndex : 0,
        tileY: axis == "y" ? sign * WorldPoint.maximumTileIndex : 0,
        localX: axis == "x" && sign > 0 ? WorldPoint.tileSize - 1 : 0,
        localY: axis == "y" && sign > 0 ? WorldPoint.tileSize - 1 : 0)
      let original = SpatialCamera(center: point, scale: 1), viewport = SpatialPoint(x: 100, y: 100)
      let dx = axis == "x" ? Double(sign) * 2 : 0, dy = axis == "y" ? Double(sign) * 2 : 0
      var camera = original
      let refused = camera.pan(screenX: -dx, screenY: -dy)
      #expect(!refused && camera == original)
      let pinch = camera.pinched(by: 2, from: .init(x: 50, y: 50),
        to: .init(x: 50 - dx * 2, y: 50 - dy * 2), viewport: viewport)
      #expect(pinch == original)
      let accepted = camera.pan(screenX: dx, screenY: dy)
      #expect(accepted)
      #expect(camera.center == point.offsetBy(x: -dx, y: -dy))
      #expect(try JSONValue.encode(camera).decode(SpatialCamera.self) == camera)
    }
  }

  @Test func extremeFloatingPointDeltasNeverReachAnIntegerConversionTrap() {
    let original = SpatialCamera()
    for value in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
      var camera = original
      let accepted = camera.pan(screenX: value, screenY: value)
      #expect(!accepted && camera == original)
      #expect(WorldPoint.zero.addressOffset(x: value, y: 0) == nil)
    }
    #expect(original.pinched(by: 1, from: .zero,
      to: .init(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude), viewport: .init(x: 100, y: 100)) == original)
  }

  @Test func anOutsideFingerAnchorDoesNotRejectARepresentableCameraCenter() {
    let point = WorldPoint(tileX: WorldPoint.maximumTileIndex, tileY: 0,
      localX: WorldPoint.tileSize - 1, localY: 0)
    let camera = SpatialCamera(center: point, scale: 1)
    let result = camera.pinched(by: 2, from: .init(x: 100, y: 50), to: .init(x: 150, y: 50), viewport: .init(x: 100, y: 100))
    #expect(result.center == point && result.scale == 2)
  }
}
