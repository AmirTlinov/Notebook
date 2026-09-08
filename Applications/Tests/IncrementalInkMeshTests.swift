import PencilKit
import XCTest

@testable import Notebook

final class IncrementalInkMeshTests: XCTestCase {
  func testEarlyCoincidentSampleNeverRebuildsTheLongSealedPrefix() {
    let color = SIMD4<Float>(0, 0, 0, 1)
    var points = (0..<20_000).map { sample($0) }
    points[1] = points[0]
    var mesh = IncrementalInkMesh()
    mesh.update(points: points, changedFrom: 0, color: color)
    for index in 20_000..<20_240 {
      points.append(sample(index))
      mesh.update(points: points, changedFrom: index, color: color)
      XCTAssertLessThanOrEqual(mesh.rebuiltPointCount, 4,
        "Раннее совпадение точек не превращает каждый отсчёт в полную перестройку")
      if index.isMultiple(of: 40) { assertGeometry(mesh, points: points, color: color) }
    }
    assertGeometry(mesh, points: points, color: color)
  }

  func testCoincidentChainNormalizesOnceAndRestoresMeasuredPrefixAfterPredictions() {
    let color = SIMD4<Float>(0.1, 0.3, 0.7, 0.6)
    var measured: [PKStrokePoint] = []
    var mesh = IncrementalInkMesh()
    for x in [0.0, 0.020, 0.011, 0.002, 0.5, 1, 2, 3] {
      measured.append(sample(measured.count, x: x))
      mesh.update(points: measured, changedFrom: measured.count - 1, color: color)
      assertGeometry(mesh, points: measured, color: color)
    }
    for prediction in [[sample(8, x: 3.005), sample(9, x: 4)],
      [sample(8, x: 3.003)], []] {
      mesh.update(measured: measured, predicted: prediction, changedFrom: measured.count, color: color)
      assertGeometry(mesh, points: measured + prediction, color: color)
    }
    measured[2] = sample(2, x: 0.4)
    mesh.update(points: measured, changedFrom: 2, color: color)
    assertGeometry(mesh, points: measured, color: color)
    measured.removeLast(4)
    mesh.update(points: measured, changedFrom: measured.count, color: color)
    assertGeometry(mesh, points: measured, color: color)
  }

  func testLongCoincidentRunKeepsTheLatestPressureWithoutScanningItsHistory() {
    let color = SIMD4<Float>(0, 0, 0, 1)
    var points: [PKStrokePoint] = []
    var mesh = IncrementalInkMesh()
    for index in 0..<10_000 {
      points.append(sample(index, x: 20))
      mesh.update(points: points, changedFrom: index, color: color)
      XCTAssertEqual(mesh.rebuiltPointCount, 1)
    }
    assertGeometry(mesh, points: points, color: color)
  }

  private func sample(_ index: Int, x: Double? = nil) -> PKStrokePoint {
    .init(location: .init(x: x ?? Double(index) * 0.1, y: x == nil ? 100 + sin(Double(index) / 10) : 50),
      timeOffset: Double(index) / 240, size: .init(width: 2 + Double(index % 7) / 10, height: 2),
      opacity: Double(index % 9 + 1) / 10, force: 1, azimuth: 0, altitude: 1)
  }

  private func assertGeometry(_ mesh: IncrementalInkMesh, points: [PKStrokePoint],
    color: SIMD4<Float>, file: StaticString = #filePath, line: UInt = #line) {
    var full: [SpatialInkGeometry.Vertex] = []
    SpatialInkGeometry.appendStrokeVertices(points: points, color: color, to: &full)
    XCTAssertEqual(mesh.vertices, full, file: file, line: line)
  }

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
