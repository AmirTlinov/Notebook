import PencilKit
import XCTest
@testable import Tetrad

final class InkStrokeGeometryTests: XCTestCase {
  func testRendererUsesOnlyThePathRangesLeftByTheEraser() {
    let source = PKDrawing(strokes: [
      stroke(
        points: stride(from: 0.0, through: 200.0, by: 10.0).map {
          point(x: $0, y: 100, width: 4)
        }
      )
    ])
    let eraser = PKStrokePath(
      controlPoints: [point(x: 100, y: 100, width: 30)],
      creationDate: Date()
    )

    let erased = source.erasingPath(eraser)
    let runs = erased.strokes.flatMap(InkStrokeGeometry.visibleRuns)

    XCTAssertGreaterThanOrEqual(runs.count, 2)
    XCTAssertTrue(
      runs.allSatisfy { run in
        let xs = run.points.map(\.location.x)
        guard let minimum = xs.min(), let maximum = xs.max() else {
          return false
        }
        return maximum < 90 || minimum > 110
      },
      "Видимая геометрия не должна снова соединять края через стёртый центр"
    )
  }

  func testUnmaskedStrokeKeepsItsOriginalPointsAndRoundEnds() {
    let source = stroke(points: [
      point(x: 10, y: 20, width: 4),
      point(x: 40, y: 20, width: 4),
    ])

    let runs = InkStrokeGeometry.visibleRuns(for: source)

    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(runs[0].points.map(\.location.x), [10, 40])
    XCTAssertTrue(runs[0].roundsStart)
    XCTAssertTrue(runs[0].roundsEnd)
  }

  private func stroke(points: [PKStrokePoint]) -> PKStroke {
    PKStroke(
      ink: PKInk(.monoline, color: .black),
      path: PKStrokePath(controlPoints: points, creationDate: Date())
    )
  }

  private func point(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: CGPoint(x: x, y: y),
      timeOffset: 0,
      size: CGSize(width: width, height: width),
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }
}
