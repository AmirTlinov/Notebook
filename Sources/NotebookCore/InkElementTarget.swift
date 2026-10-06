import Foundation

/// An eraser contact freezes only the elements it could see, in their installed
/// local basis. Programs are whole objects; native paint keeps measured cuts.
/// The erase stays in its ink action, not in a second
/// document or an element field with a competing last-writer-wins history.
public struct InkElementTarget: Codable, Equatable, Sendable {
  public struct WriteAllowance: Equatable, Sendable {
    public var retainedBytes: Int
    public var wireBytes: Int
    public var jsonTokens: Int
    public static let zero = Self(retainedBytes: 0, wireBytes: 0, jsonTokens: 0)
    public init(retainedBytes: Int, wireBytes: Int, jsonTokens: Int) {
      self.retainedBytes = retainedBytes; self.wireBytes = wireBytes; self.jsonTokens = jsonTokens
    }
    public mutating func add(_ next: Self) {
      retainedBytes += next.retainedBytes; wireBytes += next.wireBytes; jsonTokens += next.jsonTokens
    }
  }

  /// The target's actual optional schema owns this footprint. Counting does
  /// not construct JSON or encode another target. Doubles need at most 32 wire
  /// bytes; dictionary capacity and string backing are conservatively doubled.
  public var writeAllowance: WriteAllowance {
    func stringBytes(_ text: String) -> Int {
      2 + text.utf8.reduce(0) { $0 + ($1 < 0x20 ? 6 : $1 == 0x22 || $1 == 0x5c || $1 == 0x2f ? 2 : 1) }
    }
    func object(_ keys: [String], scalarBytes: Int) -> WriteAllowance {
      .init(retainedBytes: MemoryLayout<JSONValue>.stride
        + (keys.count * 2 + 1) * (MemoryLayout<String>.stride + MemoryLayout<JSONValue>.stride + 32)
        + keys.reduce(0) { $0 + $1.utf8.count * 2 },
        wireBytes: 2 + keys.reduce(0) { $0 + stringBytes($1) + 2 } + scalarBytes,
        jsonTokens: 1 + keys.count * 2)
    }
    var keys = ["elementID", "frame"]
    if worldOrigin != nil { keys.append("worldOrigin") }
    if graphicTransform != nil { keys.append("graphicTransform") }
    if elementTransform != nil { keys.append("elementTransform") }
    if wholeElement { keys.append("wholeElement") }
    var result = object(keys, scalarBytes: stringBytes(elementID) + (wholeElement ? 4 : 0))
    result.retainedBytes += elementID.utf8.count * 2
    // Nested objects replace the scalar token already counted for their field.
    result.add(object(["x", "y", "width", "height"], scalarBytes: 4 * 32)); result.jsonTokens -= 1
    if worldOrigin != nil {
      result.add(object(["tileX", "tileY", "localX", "localY"], scalarBytes: 4 * 32)); result.jsonTokens -= 1
    }
    for transform in [graphicTransform, elementTransform] where transform != nil {
      result.add(object(["a", "b", "c", "d", "tx", "ty"], scalarBytes: 6 * 32)); result.jsonTokens -= 1
    }
    return result
  }
  public let elementID: String
  public let frame: PageRect
  public let worldOrigin: WorldPoint?
  public let wholeElement: Bool
  public let graphicTransform: NotebookGraphicTransform?
  /// Whole-body basis at contact, normalized into the captured physical frame.
  /// Source contour transform stays separate: their order is not interchangeable.
  public let elementTransform: NotebookGraphicTransform?

  public init(elementID: String, frame: PageRect, worldOrigin: WorldPoint? = nil, wholeElement: Bool = false, graphicTransform: NotebookGraphicTransform? = nil, elementTransform: NotebookGraphicTransform? = nil) {
    self.elementID = elementID; self.frame = frame; self.worldOrigin = worldOrigin
    self.wholeElement = wholeElement; self.graphicTransform = graphicTransform; self.elementTransform = elementTransform
    precondition(isValid)
  }

  private enum CodingKeys: String, CodingKey { case elementID, frame, worldOrigin, wholeElement, graphicTransform, elementTransform }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    elementID = try values.decode(String.self, forKey: .elementID)
    frame = try values.decode(PageRect.self, forKey: .frame)
    worldOrigin = try values.decodeIfPresent(WorldPoint.self, forKey: .worldOrigin)
    graphicTransform = try values.decodeIfPresent(NotebookGraphicTransform.self,forKey:.graphicTransform)
    elementTransform = try values.decodeIfPresent(NotebookGraphicTransform.self,forKey:.elementTransform)
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
    try values.encodeIfPresent(elementTransform,forKey:.elementTransform)
    if wholeElement { try values.encode(true, forKey: .wholeElement) }
  }

  var isValid: Bool {
    !elementID.isEmpty && elementID.count <= 120
      && [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
      && frame.width > 0 && frame.height > 0 && (worldOrigin?.isValid ?? true) && (graphicTransform?.isValid ?? true) && (elementTransform?.isValid ?? true)
  }

  public func localPoint(_ sample: SpatialInkSample) -> SpatialPoint {
    let point = worldOrigin.flatMap { origin in sample.worldPoint.map { origin.delta(to: $0) } } ?? sample.point
    return .init(x: point.x - frame.x, y: point.y - frame.y)
  }

  /// Native masks need only a broad phase. Whole objects require an actual
  /// swept contact: a diagonal bounding box must not delete untouched programs.
  public func intersects(_ samples: some Sequence<SpatialInkSample>) -> Bool {
    var previous: (SpatialPoint, Double)?
    for sample in samples {
      let point = localPoint(sample), radius = sample.width / 2
      let a = previous?.0 ?? point, padding = max(radius, previous?.1 ?? radius)
      if min(a.x, point.x) - padding <= frame.width && max(a.x, point.x) + padding >= 0
        && min(a.y, point.y) - padding <= frame.height && max(a.y, point.y) + padding >= 0 {
        if !wholeElement || touchesBody(from: a, to: point, radius: padding) { return true }
      }
      previous = (point, radius)
    }
    return false
  }

  private func touchesBody(from a: SpatialPoint, to b: SpatialPoint, radius: Double) -> Bool {
    let transform=elementTransform ?? .identity
    func body(_ p:SpatialPoint) -> SpatialPoint {
      transform.unapplying(.init(x:p.x/frame.width,y:p.y/frame.height))
    }
    let first=body(a),last=body(b)
    // Clip in body coordinates, but measure the circular eraser in physical
    // coordinates below. An inverse circle would be wrong under shear/scale.
    var enter=0.0,leave=1.0
    func clip(_ start:Double,_ delta:Double) -> Bool {
      if delta == 0 { return start >= 0 && start <= 1 }
      let first = -start/delta,last=(1-start)/delta
      enter=max(enter,min(first,last));leave=min(leave,max(first,last))
      return enter <= leave
    }
    if clip(first.x,last.x-first.x) && clip(first.y,last.y-first.y) { return true }
    func distanceSquared(_ p:SpatialPoint,_ a:SpatialPoint,_ b:SpatialPoint) -> Double {
      let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
      let t=length == 0 ? 0 : max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length))
      let x=a.x+t*dx-p.x,y=a.y+t*dy-p.y
      return x*x+y*y
    }
    let corners=[SpatialPoint.zero,.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)].map {
      let p=transform.applying($0)
      return SpatialPoint(x:p.x*frame.width,y:p.y*frame.height)
    }
    for i in corners.indices {
      let c=corners[i],d=corners[(i+1)%corners.count]
      if min(distanceSquared(a,c,d),distanceSquared(b,c,d),distanceSquared(c,a,b)) <= radius*radius { return true }
    }
    return false
  }

}

/// A disposable paint projection. Deactivating its one ink action undoes both
/// raw-ink erasure and element erasure; merge/replay cannot apply it twice.
public struct InkElementErasure: Codable, Equatable, Sendable {
  public let target: InkElementTarget
  public let samples: InkMeasurements
  public init(target: InkElementTarget, samples: [SpatialInkSample]) {
    self.init(target:target,measurements:.init(samples))
  }
  public init(target: InkElementTarget, measurements: InkMeasurements) {
    self.target=target;self.samples=measurements
  }
}

extension PageInkDrawing {
  public var elementErasures:InkElementErasureMap {PageInkErasureDirectory(self).values}
}

extension SpatialInkJournal {
  public func elementErasures(on surface: SurfaceID) -> InkElementErasureMap {
    var result:[String:[InkElementErasure]]=[:]
    for action in orderedActions where action.isActive && action.tool == .eraser {
      for span in action.spans where span.surface == surface {
        for target in span.elementTargets ?? [] {
          result[target.elementID, default: []].append(.init(target: target, measurements: span.samples))
        }
      }
    }
    return .init(dictionary:result)
  }
}
