import Foundation

/// An eraser contact freezes only the elements it could see, in their installed
/// local basis. The measured path stays in its ink action, not in a second
/// document or an element field with a competing last-writer-wins history.
public struct InkElementTarget: Codable, Equatable, Sendable {
  public let elementID: String
  public let frame: PageRect
  public let worldOrigin: WorldPoint?

  public init(elementID: String, frame: PageRect, worldOrigin: WorldPoint? = nil) {
    self.elementID = elementID; self.frame = frame; self.worldOrigin = worldOrigin
    precondition(isValid)
  }

  var isValid: Bool {
    !elementID.isEmpty && elementID.count <= 120
      && [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
      && frame.width > 0 && frame.height > 0 && (worldOrigin?.isValid ?? true)
  }

  public func localPoint(_ sample: SpatialInkSample) -> SpatialPoint {
    let point = worldOrigin.flatMap { origin in sample.worldPoint.map { origin.delta(to: $0) } } ?? sample.point
    return .init(x: point.x - frame.x, y: point.y - frame.y)
  }

  /// Broad phase includes swept segments, not just endpoints. Empty interiors
  /// are harmless: the mask removes pixels, never the whole bounding rectangle.
  public func intersects(_ samples: [SpatialInkSample]) -> Bool {
    var previous: (SpatialPoint, Double)?
    for sample in samples {
      let point = localPoint(sample), radius = sample.width / 2
      let a = previous?.0 ?? point, padding = max(radius, previous?.1 ?? radius)
      if min(a.x, point.x) - padding <= frame.width && max(a.x, point.x) + padding >= 0
        && min(a.y, point.y) - padding <= frame.height && max(a.y, point.y) + padding >= 0 { return true }
      previous = (point, radius)
    }
    return false
  }
}

/// A disposable paint projection. Deactivating its one ink action undoes both
/// raw-ink erasure and element erasure; merge/replay cannot apply it twice.
public struct InkElementErasure: Equatable, Sendable {
  public let target: InkElementTarget
  public let samples: [SpatialInkSample]
  public init(target: InkElementTarget, samples: [SpatialInkSample]) {
    self.target = target; self.samples = samples
  }
}

extension PageInkDrawing {
  public var elementErasures: [String: [InkElementErasure]] {
    var result: [String: [InkElementErasure]] = [:]
    for action in actions where action.isActive && action.tool == .eraser {
      for target in action.elementTargets ?? [] {
        result[target.elementID, default: []].append(.init(target: target, samples: action.samples))
      }
    }
    return result
  }
}

extension SpatialInkJournal {
  public func elementErasures(on surface: SurfaceID) -> [String: [InkElementErasure]] {
    var result: [String: [InkElementErasure]] = [:]
    for action in actions where action.isActive && action.tool == .eraser {
      for span in action.spans where span.surface == surface {
        for target in span.elementTargets ?? [] {
          result[target.elementID, default: []].append(.init(target: target, samples: span.samples))
        }
      }
    }
    return result
  }
}
