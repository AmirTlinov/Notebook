import CoreGraphics
import Foundation
import NotebookCore

enum WorkspaceMagnificationPhase: Equatable {
  case began(centroid: CGPoint, isOpeningApproach: Bool)
  case changed(
    scale: CGFloat,
    velocity: CGFloat,
    elapsed: TimeInterval,
    centroid: CGPoint
  )
  case ended(
    scale: CGFloat,
    velocity: CGFloat,
    elapsed: TimeInterval,
    centroid: CGPoint
  )
  case cancelled
}

struct SpatialWorkspaceItemSurface: Equatable, Identifiable {
  let itemID: UUID
  let center: WorldPoint
  let zIndex: Double

  var id: UUID { itemID }
}

struct SpatialScreenSurface: Equatable {
  let id: SurfaceID
  let frame: CGRect
  let zIndex: Double
}

struct SpatialSurfaceInterval: Equatable {
  let lowerBound: CGFloat
  let upperBound: CGFloat
  let surface: SurfaceID
}

/// Splits one sampled Pencil segment at every crossed cover edge. This also
/// catches a fast board-to-board sample that passed through a cover between
/// the two hardware measurements.
enum SpatialSurfaceRouter {
  static func intervals(
    from start: CGPoint,
    to end: CGPoint,
    covers: [SpatialScreenSurface]
  ) -> [SpatialSurfaceInterval] {
    var breaks: [CGFloat] = [0, 1]
    for cover in covers {
      guard let range = intersectionRange(
        from: start,
        to: end,
        rectangle: cover.frame
      ) else { continue }
      breaks.append(range.lowerBound)
      breaks.append(range.upperBound)
    }
    breaks.sort()
    var unique: [CGFloat] = []
    for value in breaks where unique.last.map({ abs($0 - value) > 0.000_001 }) ?? true {
      unique.append(value)
    }

    var result: [SpatialSurfaceInterval] = []
    for pair in zip(unique, unique.dropFirst()) where pair.1 - pair.0 > 0.000_001 {
      let midpoint = (pair.0 + pair.1) / 2
      let point = CGPoint(
        x: start.x + (end.x - start.x) * midpoint,
        y: start.y + (end.y - start.y) * midpoint
      )
      let surface = surface(at: point, covers: covers)
      if let last = result.last, last.surface == surface {
        result[result.count - 1] = SpatialSurfaceInterval(
          lowerBound: last.lowerBound,
          upperBound: pair.1,
          surface: surface
        )
      } else {
        result.append(
          SpatialSurfaceInterval(
            lowerBound: pair.0,
            upperBound: pair.1,
            surface: surface
          )
        )
      }
    }
    return result
  }

  static func surface(
    at point: CGPoint,
    covers: [SpatialScreenSurface]
  ) -> SurfaceID {
    covers
      .filter { $0.frame.contains(point) }
      .max { $0.zIndex < $1.zIndex }?.id ?? .board
  }

  private static func intersectionRange(
    from start: CGPoint,
    to end: CGPoint,
    rectangle: CGRect
  ) -> ClosedRange<CGFloat>? {
    var lower: CGFloat = 0
    var upper: CGFloat = 1
    let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
    guard clip(
      origin: start.x,
      delta: delta.x,
      minimum: rectangle.minX,
      maximum: rectangle.maxX,
      lower: &lower,
      upper: &upper
    ), clip(
      origin: start.y,
      delta: delta.y,
      minimum: rectangle.minY,
      maximum: rectangle.maxY,
      lower: &lower,
      upper: &upper
    ), lower <= upper
    else { return nil }
    return max(0, lower)...min(1, upper)
  }

  private static func clip(
    origin: CGFloat,
    delta: CGFloat,
    minimum: CGFloat,
    maximum: CGFloat,
    lower: inout CGFloat,
    upper: inout CGFloat
  ) -> Bool {
    guard abs(delta) > 0.000_001 else {
      return origin >= minimum && origin <= maximum
    }
    let first = (minimum - origin) / delta
    let second = (maximum - origin) / delta
    lower = max(lower, min(first, second))
    upper = min(upper, max(first, second))
    return lower <= upper
  }
}
