import Foundation

/// An eraser contact freezes only the elements it could see, in their installed
/// local basis. Programs are whole objects; native paint keeps measured cuts.
/// The erase stays in its ink action, not in a second
/// document or an element field with a competing last-writer-wins history.
public struct InkElementTarget: Codable, Equatable, Sendable {
  public let elementID: String
  public let frame: PageRect
  public let worldOrigin: WorldPoint?
  public let wholeElement: Bool
  public let graphicTransform: NotebookGraphicTransform?

  public init(elementID: String, frame: PageRect, worldOrigin: WorldPoint? = nil, wholeElement: Bool = false, graphicTransform: NotebookGraphicTransform? = nil) {
    self.elementID = elementID; self.frame = frame; self.worldOrigin = worldOrigin
    self.wholeElement = wholeElement; self.graphicTransform = graphicTransform
    precondition(isValid)
  }

  private enum CodingKeys: String, CodingKey { case elementID, frame, worldOrigin, wholeElement, graphicTransform }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    elementID = try values.decode(String.self, forKey: .elementID)
    frame = try values.decode(PageRect.self, forKey: .frame)
    worldOrigin = try values.decodeIfPresent(WorldPoint.self, forKey: .worldOrigin)
    graphicTransform = try values.decodeIfPresent(NotebookGraphicTransform.self,forKey:.graphicTransform)
    wholeElement = try values.decodeIfPresent(Bool.self, forKey: .wholeElement) ?? false
    guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
      debugDescription: "Invalid eraser target")) }
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(elementID, forKey: .elementID)
    try values.encode(frame, forKey: .frame)
    try values.encodeIfPresent(worldOrigin, forKey: .worldOrigin)
    try values.encodeIfPresent(graphicTransform,forKey:.graphicTransform)
    if wholeElement { try values.encode(true, forKey: .wholeElement) }
  }

  var isValid: Bool {
    !elementID.isEmpty && elementID.count <= 120
      && [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
      && frame.width > 0 && frame.height > 0 && (worldOrigin?.isValid ?? true) && (graphicTransform?.isValid ?? true)
  }

  public func localPoint(_ sample: SpatialInkSample) -> SpatialPoint {
    let point = worldOrigin.flatMap { origin in sample.worldPoint.map { origin.delta(to: $0) } } ?? sample.point
    return .init(x: point.x - frame.x, y: point.y - frame.y)
  }

  /// Native masks need only a broad phase. Whole objects require an actual
  /// swept contact: a diagonal bounding box must not delete untouched programs.
  public func intersects(_ samples: [SpatialInkSample]) -> Bool {
    var previous: (SpatialPoint, Double)?
    for sample in samples {
      let point = localPoint(sample), radius = sample.width / 2
      let a = previous?.0 ?? point, padding = max(radius, previous?.1 ?? radius)
      if min(a.x, point.x) - padding <= frame.width && max(a.x, point.x) + padding >= 0
        && min(a.y, point.y) - padding <= frame.height && max(a.y, point.y) + padding >= 0 {
        if !wholeElement || touchesRectangle(from: a, to: point, radius: padding) { return true }
      }
      previous = (point, radius)
    }
    return false
  }

  private func touchesRectangle(from a: SpatialPoint, to b: SpatialPoint, radius: Double) -> Bool {
    func distanceToRectangle(_ p: SpatialPoint) -> Double {
      let x = max(0, max(-p.x, p.x - frame.width)), y = max(0, max(-p.y, p.y - frame.height))
      return x*x + y*y
    }
    if min(distanceToRectangle(a), distanceToRectangle(b)) <= radius*radius { return true }
    let dx = b.x-a.x, dy = b.y-a.y
    var enter = 0.0, leave = 1.0
    func clip(_ start: Double, _ delta: Double, _ extent: Double) -> Bool {
      if abs(delta) < 1e-12 { return start >= 0 && start <= extent }
      let first = -start/delta, last = (extent-start)/delta
      enter = max(enter, min(first, last)); leave = min(leave, max(first, last))
      return enter <= leave
    }
    if clip(a.x, dx, frame.width) && clip(a.y, dy, frame.height) { return true }
    let lengthSquared = dx*dx + dy*dy
    guard lengthSquared > 0 else { return false }
    // If the segment misses the rectangle, its nearest interior point is
    // paired with a corner; endpoint-to-edge distances were handled above.
    for corner in [SpatialPoint.zero, .init(x: frame.width, y: 0),
      .init(x: 0, y: frame.height), .init(x: frame.width, y: frame.height)] {
      let t = max(0, min(1, ((corner.x-a.x)*dx + (corner.y-a.y)*dy)/lengthSquared))
      let x = a.x+t*dx-corner.x, y = a.y+t*dy-corner.y
      if x*x + y*y <= radius*radius { return true }
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
