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
  let geometry: WorkspaceItemGeometry
  let center: WorldPoint
  let zIndex: Double

  var id: UUID { itemID }
}

struct SpatialScreenSurface: Equatable {
  let id: SurfaceID
  let localBounds: CGRect
  let localToScreen: CGAffineTransform
  let zIndex: Double
  let liftRank: Double?

  init(id: SurfaceID, localBounds: CGRect, localToScreen: CGAffineTransform, zIndex: Double, liftRank: Double? = nil) {
    self.id = id; self.localBounds = localBounds; self.localToScreen = localToScreen
    self.zIndex = zIndex; self.liftRank = liftRank
  }

  func isPaintedBelow(_ other: Self) -> Bool {
    // The published lift tier is above the complete static composition, not a
    // durable z coordinate. Resting ties use the renderer's one painter order.
    switch (liftRank, other.liftRank) {
    case (.some(let left), .some(let right)) where left != right: return left < right
    case (.none, .some): return true
    case (.some, .none): return false
    default:
      return ScenePaintPosition(layer: .covers, zIndex: zIndex, key: id.ownerID?.uuidString ?? "")
        < ScenePaintPosition(layer: .covers, zIndex: other.zIndex, key: other.id.ownerID?.uuidString ?? "")
    }
  }

  init(id: SurfaceID, frame: CGRect, zIndex: Double) {
    self.init(id: id, localBounds: frame, localToScreen: .identity, zIndex: zIndex)
  }

  var frame: CGRect { localBounds.applying(localToScreen) }
  var screenScale: CGFloat { hypot(localToScreen.a, localToScreen.b) }
  func localPoint(_ point: CGPoint) -> CGPoint { point.applying(localToScreen.inverted()) }
  func contains(_ point: CGPoint) -> Bool {
    localToScreen.isFiniteAndInvertible && localBounds.contains(localPoint(point))
  }
  func localAzimuth(_ angle: CGFloat) -> CGFloat {
    let inverse = localToScreen.inverted(), x = cos(angle), y = sin(angle)
    return atan2(inverse.b * x + inverse.d * y, inverse.a * x + inverse.c * y)
  }
}

extension CGAffineTransform {
  var isFiniteAndInvertible: Bool {
    [a, b, c, d, tx, ty].allSatisfy(\.isFinite) && abs(a * d - b * c) > 1e-12
  }
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
    covers: [SpatialScreenSurface],
    board: SurfaceID = .board
  ) -> [SpatialSurfaceInterval] {
    var breaks: [CGFloat] = [0, 1]
    for cover in covers {
      guard cover.localToScreen.isFiniteAndInvertible else { continue }
      guard let range = intersectionRange(
        from: cover.localPoint(start),
        to: cover.localPoint(end),
        rectangle: cover.localBounds
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
      let surface = surface(at: point, covers: covers, board: board)
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
    covers: [SpatialScreenSurface],
    board: SurfaceID = .board
  ) -> SurfaceID {
    covers
      .filter { $0.contains(point) }
      .max { $0.isPaintedBelow($1) }?.id ?? board
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
