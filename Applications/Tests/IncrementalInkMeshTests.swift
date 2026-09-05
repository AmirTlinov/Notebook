import PencilKit
import XCTest

@testable import Notebook

final class IncrementalInkMeshTests: XCTestCase {
  func testAppendPredictionsAndCorrectionsMatchTheCompleteGeometry() {
    let color = SIMD4<Float>(0, 0.19, 0.78, 1)
    var points: [PKStrokePoint] = []
    var mesh = IncrementalInkMesh()
    func point(_ i: Int, opacity: CGFloat = 0.4) -> PKStrokePoint {
      PKStrokePoint(
        location: .init(x: i * 2, y: 60 + i % 19), timeOffset: Double(i) / 240,
        size: .init(width: 2.2, height: 2.2), opacity: opacity, force: 0.2, azimuth: 0, altitude: 1)
    }
    func assertExact() {
      var full: [SpatialInkGeometry.Vertex] = []
      SpatialInkGeometry.appendStrokeVertices(points: points, color: color, to: &full)
      XCTAssertEqual(mesh.vertices, full)
    }
    for i in 0..<2400 {
      points.append(point(i))
      mesh.update(points: points, changedFrom: i, color: color)
      if i % 100 == 0 { assertExact() }
    }
    XCTAssertLessThanOrEqual(
      mesh.rebuiltPointCount, 4, "Длинная линия пересчитывает только её подвижный конец")
    points[2390] = point(2390, opacity: 0.9)
    mesh.update(points: points, changedFrom: 2390, color: color)
    assertExact()
    points.removeLast(5)
    mesh.update(points: points, changedFrom: points.count, color: color)
    assertExact()
    points.append(points.last!)
    mesh.update(points: points, changedFrom: points.count - 1, color: color)
    assertExact()
  }
}
