/// A tiled board address. The continuous tile range is exactly representable
/// in both Swift JSONValue and JavaScript; nearby arithmetic stays tile-local.
public struct WorldPoint: Codable, Equatable, Hashable, Sendable {
  /// 256 half-centimetre cells. Every visible board-grid level therefore
  /// lands on the same line at a tile boundary.
  public static let tileSize = PhysicalPaper.gridSpacing * 256
  public static let maximumTileIndex: Int64 = 9_007_199_254_740_991

  public let tileX: Int64
  public let tileY: Int64
  public let localX: Double
  public let localY: Double

  public init(x: Double, y: Double) {
    precondition(x.isFinite && y.isFinite)
    let normalized = Self.normalize(x: x, y: y)
    tileX = normalized.tileX
    tileY = normalized.tileY
    localX = normalized.localX
    localY = normalized.localY
  }

  public init(
    tileX: Int64,
    tileY: Int64,
    localX: Double,
    localY: Double
  ) {
    precondition(localX.isFinite && localY.isFinite)
    let normalized = Self.normalize(
      tileX: tileX,
      tileY: tileY,
      localX: localX,
      localY: localY
    )
    self.tileX = normalized.tileX
    self.tileY = normalized.tileY
    self.localX = normalized.localX
    self.localY = normalized.localY
  }

  /// Already normalized binary source: validate without recomputing local bits.
  package init?(exactTileX: Int64, tileY: Int64, localX: Double, localY: Double) {
    self.tileX=exactTileX;self.tileY=tileY;self.localX=localX;self.localY=localY
    guard isValid else { return nil }
  }

  public static let zero = WorldPoint(x: 0, y: 0)

  public func offsetBy(x: Double, y: Double) -> Self {
    precondition(x.isFinite && y.isFinite)
    return Self(
      tileX: tileX,
      tileY: tileY,
      localX: localX + x,
      localY: localY + y
    )
  }

  /// Admission for a new physical address. Projection geometry may extend
  /// beyond the stored world; a camera center or measured sample may not.
  public func addressOffset(x: Double, y: Double) -> Self? {
    guard isValid, let result=projectionOffset(x:x,y:y),result.isValid else { return nil }
    return result
  }

  /// Derived bounds may exceed the JSON address domain, but never Int64.
  /// An unrepresentable projection is refused before a normalizing conversion.
  package func projectionOffset(x: Double,y: Double) -> Self? {
    func axis(_ tile: Int64,_ local: Double,_ delta: Double) -> (Int64,Double)? {
      let value=local+delta
      guard value.isFinite,let carry=Int64(exactly:(value/Self.tileSize).rounded(.down)) else { return nil }
      let (next,overflow)=tile.addingReportingOverflow(carry)
      let remainder=value-Double(carry)*Self.tileSize
      guard !overflow,remainder.isFinite,remainder>=0,remainder<Self.tileSize else { return nil }
      return (next,remainder)
    }
    guard let x=axis(tileX,localX,x),let y=axis(tileY,localY,y) else { return nil }
    return .init(tileX:x.0,tileY:y.0,localX:x.1,localY:y.1)
  }

  /// Interpolates an admitted address without flattening its tiles into a
  /// world-sized Double. Rounding stays inside each pair of endpoint axes;
  /// it cannot turn a convex camera trajectory into an out-of-world address.
  public func interpolatedAddress(to other: Self, amount: Double) -> Self? {
    guard isValid, other.isValid, amount.isFinite, (0...1).contains(amount) else { return nil }
    if amount == 0 { return self }
    if amount == 1 { return other }
    func axis(_ a: (Int64, Double), _ b: (Int64, Double)) -> (Int64, Double) {
      let (start, end, progress) = amount <= 0.5 ? (a, b, amount) : (b, a, 1 - amount)
      // At most half the valid tile span is converted to an integer. The
      // local interpolation never loses its bits in a huge world offset.
      let tileDelta = Double(end.0 - start.0) * progress
      let whole = Int64(tileDelta.rounded(.down)), fraction = tileDelta - tileDelta.rounded(.down)
      let local = start.1 + (end.1 - start.1) * progress + fraction * Self.tileSize
      let carry = Int64((local / Self.tileSize).rounded(.down))
      let result = (start.0 + whole + carry, local - Double(carry) * Self.tileSize)
      // Like a bounded scalar lerp, cap arithmetic rounding at the exact
      // endpoints, not at a guessed global-coordinate epsilon.
      func before(_ left: (Int64, Double), _ right: (Int64, Double)) -> Bool {
        left.0 < right.0 || (left.0 == right.0 && left.1 < right.1)
      }
      let (lower, upper) = before(a, b) ? (a, b) : (b, a)
      return before(result, lower) ? lower : before(upper, result) ? upper : result
    }
    let x = axis((tileX, localX), (other.tileX, other.localX))
    let y = axis((tileY, localY), (other.tileY, other.localY))
    return .init(tileX: x.0, tileY: y.0, localX: x.1, localY: y.1)
  }

  /// Returns `other - self` without first flattening both coordinates into
  /// huge floating-point numbers.
  public func delta(to other: Self) -> SpatialPoint {
    func distance(_ a: Int64,_ b: Int64) -> Double {
      let (difference,overflow)=b.subtractingReportingOverflow(a)
      guard overflow else { return Double(difference) }
      return b>a ? Double(UInt64(bitPattern:b) &- UInt64(bitPattern:a))
        : -Double(UInt64(bitPattern:a) &- UInt64(bitPattern:b))
    }
    return SpatialPoint(x:distance(tileX,other.tileX)*Self.tileSize+other.localX-localX,
      y:distance(tileY,other.tileY)*Self.tileSize+other.localY-localY)
  }

  public var isValid: Bool {
    (-Self.maximumTileIndex...Self.maximumTileIndex).contains(tileX)
      && (-Self.maximumTileIndex...Self.maximumTileIndex).contains(tileY)
      && localX.isFinite && localY.isFinite
      && localX >= 0 && localX < Self.tileSize
      && localY >= 0 && localY < Self.tileSize
  }

  private enum CodingKeys: String, CodingKey { case tileX, tileY, localX, localY }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    tileX = try values.decode(Int64.self, forKey: .tileX)
    tileY = try values.decode(Int64.self, forKey: .tileY)
    localX = try values.decode(Double.self, forKey: .localX)
    localY = try values.decode(Double.self, forKey: .localY)
    guard isValid else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
        debugDescription: "WorldPoint requires exact safe-integer tiles and normalized local coordinates"))
    }
  }

  public func encode(to encoder: Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
        debugDescription: "WorldPoint is outside its exact JSON address range"))
    }
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(tileX, forKey: .tileX); try values.encode(tileY, forKey: .tileY)
    try values.encode(localX, forKey: .localX); try values.encode(localY, forKey: .localY)
  }

  private static func normalize(x: Double, y: Double) -> (
    tileX: Int64,
    tileY: Int64,
    localX: Double,
    localY: Double
  ) {
    let tileX = Int64((x / tileSize).rounded(.down))
    let tileY = Int64((y / tileSize).rounded(.down))
    return (
      tileX,
      tileY,
      x - Double(tileX) * tileSize,
      y - Double(tileY) * tileSize
    )
  }

  private static func normalize(
    tileX: Int64,
    tileY: Int64,
    localX: Double,
    localY: Double
  ) -> (tileX: Int64, tileY: Int64, localX: Double, localY: Double) {
    let xOffset = Int64((localX / tileSize).rounded(.down))
    let yOffset = Int64((localY / tileSize).rounded(.down))
    return (
      tileX + xOffset,
      tileY + yOffset,
      localX - Double(xOffset) * tileSize,
      localY - Double(yOffset) * tileSize
    )
  }
}

public struct SpatialPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    precondition(x.isFinite && y.isFinite)
    self.x = x
    self.y = y
  }

  public static let zero = SpatialPoint(x: 0, y: 0)

  package var isValid: Bool { x.isFinite && y.isFinite }
}

public struct SpatialRect: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    precondition(
      x.isFinite && y.isFinite && width.isFinite && height.isFinite
        && width > 0 && height > 0
    )
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public func contains(_ point: SpatialPoint) -> Bool {
    point.x >= x && point.x <= x + width
      && point.y >= y && point.y <= y + height
  }

  package var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && width > 0 && height > 0
  }
}

public struct SpatialCamera: Codable, Equatable, Hashable, Sendable {
  /// The board remains useful at overview scale: a notebook can shrink to
  /// roughly ten screen points without exhausting the tiled coordinates.
  public static let minimumScale = 0.0125
  public static let maximumScale = 4.0

  public private(set) var center: WorldPoint
  public private(set) var scale: Double

  public init(center: WorldPoint = .zero, scale: Double = 0.22) {
    precondition(scale.isFinite && scale >= Self.minimumScale)
    self.center = center
    self.scale = min(scale, Self.maximumScale)
  }

  /// Platform unit conversion can round a limit by one ULP. Admit a finite,
  /// positive request through the same canonical zoom limits before a gesture.
  public init?(admitting center: WorldPoint, scale: Double) {
    guard center.isValid, scale.isFinite, scale > 0 else { return nil }
    self.init(center: center, scale: max(scale, Self.minimumScale))
  }

  public func worldToScreen(
    _ point: WorldPoint,
    viewport: SpatialPoint
  ) -> SpatialPoint {
    let delta = center.delta(to: point)
    return SpatialPoint(
      x: viewport.x / 2 + delta.x * scale,
      y: viewport.y / 2 + delta.y * scale
    )
  }

  public func screenToWorld(
    _ point: SpatialPoint,
    viewport: SpatialPoint
  ) -> WorldPoint {
    center.offsetBy(
      x: (point.x - viewport.x / 2) / scale,
      y: (point.y - viewport.y / 2) / scale
    )
  }

  /// A measured contact or new physical owner needs an admitted address.
  /// Rendering may use screenToWorld for geometry beyond the finite world.
  public func worldAddress(at point: SpatialPoint, viewport: SpatialPoint) -> WorldPoint? {
    guard isValid, point.isValid, viewport.isValid else { return nil }
    return center.addressOffset(x: (point.x - viewport.x / 2) / scale,
      y: (point.y - viewport.y / 2) / scale)
  }

  /// Refuses an unrepresentable center without publishing part of a gesture.
  @discardableResult
  public mutating func pan(screenX: Double, screenY: Double) -> Bool {
    guard let next = center.addressOffset(x: -screenX / scale, y: -screenY / scale) else { return false }
    center = next
    return true
  }

  /// Solves the complete two-finger camera transform from the gesture's
  /// starting camera. The world point beneath `startCentroid` is projected
  /// beneath `currentCentroid`, so the fingers determine the path independently
  /// of frame rate and semantic focus.
  public func pinched(
    by magnification: Double,
    from startCentroid: SpatialPoint,
    to currentCentroid: SpatialPoint,
    viewport: SpatialPoint,
    maximumScale: Double = SpatialCamera.maximumScale
  ) -> Self {
    guard magnification.isFinite && magnification > 0,
      maximumScale.isFinite && maximumScale > 0
    else { return self }
    let upperScale = min(
      max(maximumScale, Self.minimumScale),
      Self.maximumScale
    )
    let resolvedScale = min(
      max(scale * magnification, Self.minimumScale),
      upperScale
    )
    // Solve the local displacement before normalizing a world address. The
    // finger anchor may lie beyond the edge while the final center is valid.
    guard let resolvedCenter = center.addressOffset(
      x: (startCentroid.x - viewport.x / 2) / scale - (currentCentroid.x - viewport.x / 2) / resolvedScale,
      y: (startCentroid.y - viewport.y / 2) / scale - (currentCentroid.y - viewport.y / 2) / resolvedScale
    ) else { return self }
    return Self(
      center: resolvedCenter,
      scale: resolvedScale
    )
  }

  public var isValid: Bool {
    center.isValid && scale.isFinite
      && scale >= Self.minimumScale && scale <= Self.maximumScale
  }
}
