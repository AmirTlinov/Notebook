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
    let manipulations: [[Double]]
    let pressure: [[Double]]
    let ink: [InkUpdate]
  }
  struct InkUpdate: Decodable {
    let changedFrom: Int
    let tail: [Float]
  }
  struct InkResult: Encodable {
    let first: Int
    let vertices: Int
    let nodes: [Float]
  }
  struct Results: Encodable {
    let cameras: [[Double]]
    let offsets: [[Double]?]
    let deltas: [[Double]]
    let strokes: [[Float]]
    let manipulations: [[Double]?]
    let pressure: [[Double]]
    let ink: [InkResult]
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
    var ink = IncrementalInkGeometry(), raw: [Float] = []
    let inkResults = cases.ink.map { update in
      raw.replaceSubrange((update.changedFrom * 7)..., with: update.tail)
      func point(_ i: Int) -> InkStrokeGeometry.RenderPoint {
        let i = i * 7
        return .init(position: .init(raw[i], raw[i+1]), radius: raw[i+2],
          premultipliedColor: .init(raw[i+3], raw[i+4], raw[i+5], raw[i+6]))
      }
      ink.update(count: raw.count / 7, changedFrom: update.changedFrom, point: point,
        forEach: { range, emit in for i in range { emit(point(i)) } })
      return InkResult(first: ink.rebuiltNodeStart,
        vertices: InkRenderGeometry.vertexCount(nodes: ink.nodes.count, flags: 3),
        nodes: ink.nodes.flatMap { [$0.position.x, $0.position.y, $0.edge.x, $0.edge.y, $0.radius, $0.alpha] })
    }
    let result = Results(
      cameras: cases.cameras.map { v in
        let start = SpatialCamera(admitting: point(v[0..<4]), scale: v[4])!
        let camera = CameraGestureTrajectory(startingCamera: start,
          startingCentroid: .init(x: v[7], y: v[8]), viewport: .init(x: v[5], y: v[6]))
          .camera(at: v[11], centroid: .init(x: v[9], y: v[10]))
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
      },
      manipulations: cases.manipulations.map { v in
        func frame(_ offset: Int) -> SpatialRect {
          .init(x: v[offset], y: v[offset+1], width: v[offset+2], height: v[offset+3])
        }
        let kind: SurfaceFrameManipulation.Kind = v[0] == 0 ? .move : .resize(NotebookElementResizeHandle.allCases[Int(v[0])-1])
        return SurfaceFrameManipulation(kind: kind, original: frame(1), bounds: v[7] == 1 ? frame(8) : nil)?
          .frame(at: .init(x: v[5], y: v[6])).map { [$0.x, $0.y, $0.width, $0.height] }
      },
      pressure: cases.pressure.map { v in
        let force = PencilPressureSmoothing.value(force: v[0], previous: v[1] < 0 ? nil : v[1], elapsed: v[2])
        let style = PenStyle.standard, color = style.color.components
        return [style.width, style.opacity(force: force), force, color.red, color.green, color.blue]
      },
      ink: inkResults)
    FileHandle.standardOutput.write(try JSONEncoder().encode(result))
  }
}
