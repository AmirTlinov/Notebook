import NotebookCore
import Testing

@Suite struct IncrementalInkGeometryTests {
  private func point(_ x: Float, _ y: Float = 0, radius: Float = 1, alpha: Float = 0.5) -> InkStrokeGeometry.RenderPoint {
    .init(position: .init(x, y), radius: radius, premultipliedColor: .init(repeating: alpha))
  }

  private func update(_ geometry: inout IncrementalInkGeometry,
    _ points: [InkStrokeGeometry.RenderPoint], from: Int) {
    geometry.update(count: points.count, changedFrom: from, point: { points[$0] },
      forEach: { range, emit in for i in range { emit(points[i]) } })
  }

  @Test func removingCoincidentPredictionRestoresTheMeasuredTip() {
    let measured = [point(0), point(10, radius: 2, alpha: 0.3)]
    var geometry = IncrementalInkGeometry()
    update(&geometry, measured + [point(10.004, 0.003, radius: 3, alpha: 0.9), point(20, 5)], from: 0)
    #expect(geometry.nodes.count == 3)
    #expect(geometry.nodes[1].radius == 3)
    update(&geometry, measured, from: measured.count)
    #expect(geometry.nodes.count == 2)
    #expect(geometry.nodes[1].position == measured[1].position)
    #expect(geometry.nodes[1].radius == 2)
    #expect(geometry.nodes[1].alpha == 0.3)
    #expect(geometry.nodes[1].edge == .init(0, 2))
    update(&geometry, measured + [point(15, -5)], from: measured.count)
    #expect(geometry.nodes.count == 3)
    #expect(geometry.nodes.last?.position == .init(15, -5))
  }

  @Test func longAppendKeepsTheSealedPrefix() {
    var points = (0..<4096).map { point(Float($0), Float($0 % 11)) }
    var geometry = IncrementalInkGeometry()
    update(&geometry, points, from: 0)
    let prefix = Array(geometry.nodes.dropLast())
    points.append(point(4096, 4))
    update(&geometry, points, from: 4096)
    #expect(geometry.rebuiltNodeStart == 4095)
    #expect(geometry.rebuiltPointCount == 2)
    #expect(Array(geometry.nodes.prefix(prefix.count)) == prefix)
    #expect(geometry.nodes.count == points.count)
  }
}
