import Foundation

public struct NotebookQuickShapeFit: Equatable, Sendable {
  public var frame: PageRect
  public let sampleCount: Int
  public init(frame: PageRect, sampleCount: Int) { self.frame = frame; self.sampleCount = sampleCount }
}

/// Runs once after a deliberate hold, never in the normal handwriting loop.
/// This fit is deliberately conservative: a miss retains all measured ink.
public enum NotebookQuickShape {
  public static func ellipse(_ measured: [SpatialPoint], screenScale: Double) -> NotebookQuickShapeFit? {
    guard measured.count >= 12, measured.count <= 8192, screenScale.isFinite, screenScale > 0,
      measured.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
    let minX = measured.map(\.x).min()!, maxX = measured.map(\.x).max()!
    let minY = measured.map(\.y).min()!, maxY = measured.map(\.y).max()!
    let width = maxX - minX, height = maxY - minY
    guard min(width, height) * screenScale >= 24, max(width, height) / min(width, height) <= 8 else { return nil }
    let first = measured.first!, last = measured.last!
    guard hypot(last.x - first.x, last.y - first.y) < min(width, height) * 0.23 else { return nil }
    // Arc-length sampling prevents a long stationary hold or slow corner from
    // outweighing the rest of a square/scribble and turning it into a circle.
    let points = resampled(measured, count: 128)
    guard points.count == 128 else { return nil }
    var radialError = 0.0, travelled = 0.0, winding = 0.0, reversed = 0.0
    var priorAngle: Double?, prior: SpatialPoint?
    for point in points {
      let x = (point.x - (minX + maxX) / 2) * 2 / width
      let y = (point.y - (minY + maxY) / 2) * 2 / height
      radialError += pow(hypot(x, y) - 1, 2)
      let angle = atan2(y, x)
      if let priorAngle {
        var delta = angle - priorAngle
        if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }
        winding += delta; reversed += abs(delta)
      }
      if let prior { travelled += hypot(point.x - prior.x, point.y - prior.y) }
      priorAngle = angle; prior = point
    }
    let a = width / 2, b = height / 2
    let circumference = .pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
    guard sqrt(radialError / Double(points.count)) < 0.09,
      abs(winding) > 5.5, abs(winding) < 7, reversed < abs(winding) * 1.15,
      travelled / circumference > 0.83, travelled / circumference < 1.2 else { return nil }
    return .init(frame: .init(x: minX, y: minY, width: width, height: height), sampleCount: measured.count)
  }
  private static func resampled(_ points: [SpatialPoint], count: Int) -> [SpatialPoint] {
    var distances = [0.0]
    for index in 1..<points.count {
      distances.append(distances.last! + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
    }
    guard let total = distances.last, total > 0 else { return [] }
    var result: [SpatialPoint] = [], segment = 1
    for index in 0..<count {
      let distance = total * Double(index) / Double(count - 1)
      while segment < distances.count - 1 && distances[segment] < distance { segment += 1 }
      let span = distances[segment] - distances[segment - 1]
      let t = span > 0 ? (distance - distances[segment - 1]) / span : 0
      result.append(.init(x: points[segment - 1].x + (points[segment].x - points[segment - 1].x) * t,
        y: points[segment - 1].y + (points[segment].y - points[segment - 1].y) * t))
    }
    return result
  }

}
