import Foundation

/// Native oracle for the browser ABI check. Compiled with the surface sources,
/// including Apple's SIMD implementation, without building the application.
@main
enum SurfaceParity {
  struct Cases: Decodable {
    let cameras: [[Double]]
    let offsets: [[Double]]
    let deltas: [[Double]]
    let strokes: [[Float]]
  }
  struct Results: Encodable {
    let cameras: [[Double]]
    let offsets: [[Double]?]
    let deltas: [[Double]]
    let strokes: [[Float]]
  }
  static func point(_ values: ArraySlice<Double>) -> WorldPoint {
    let v = Array(values)
    return WorldPoint(exactTileX: Int64(v[0]), tileY: Int64(v[1]), localX: v[2], localY: v[3])!
  }
  static func address(_ point: WorldPoint) -> [Double] {
    [Double(point.tileX), Double(point.tileY), point.localX, point.localY]
  }
  static func main() throws {
    let cases = try JSONDecoder().decode(Cases.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let result = Results(
      cameras: cases.cameras.map { v in
        let camera = SpatialCamera(center: point(v[0..<4]), scale: v[4]).pinched(
          by: v[11], from: .init(x: v[7], y: v[8]), to: .init(x: v[9], y: v[10]),
          viewport: .init(x: v[5], y: v[6]))
        return address(camera.center) + [camera.scale]
      },
      offsets: cases.offsets.map { v in
        point(v[0..<4]).addressOffset(x: v[4], y: v[5]).map(address)
      },
      deltas: cases.deltas.map { v in
        let delta = point(v[0..<4]).delta(to: point(v[4..<8]))
        return [delta.x, delta.y]
      },
      strokes: cases.strokes.map { values in
        let points = stride(from: 0, to: values.count, by: 7).map { i in
          InkStrokeGeometry.RenderPoint(position: .init(values[i], values[i+1]), radius: values[i+2],
            premultipliedColor: .init(values[i+3], values[i+4], values[i+5], values[i+6]))
        }
        var vertices: [InkStrokeGeometry.Vertex] = []
        InkStrokeGeometry.appendStrokeVertices(renderPoints: points, to: &vertices)
        return vertices.flatMap {
          [$0.position.x, $0.position.y, $0.premultipliedColor.x, $0.premultipliedColor.y,
            $0.premultipliedColor.z, $0.premultipliedColor.w]
        }
      })
    FileHandle.standardOutput.write(try JSONEncoder().encode(result))
  }
}
