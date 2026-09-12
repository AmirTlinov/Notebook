import Foundation

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
    guard isValid, x.isFinite, y.isFinite else { return nil }
    func axis(_ tile: Int64, _ local: Double, _ delta: Double) -> (Int64, Double)? {
      let value = local + delta
      guard value.isFinite, let offset = Int64(exactly: floor(value / Self.tileSize)) else { return nil }
      let (next, overflow) = tile.addingReportingOverflow(offset)
      let remainder = value - Double(offset) * Self.tileSize
      guard !overflow, (-Self.maximumTileIndex...Self.maximumTileIndex).contains(next),
        remainder.isFinite, remainder >= 0, remainder < Self.tileSize else { return nil }
      return (next, remainder)
    }
    guard let x = axis(tileX, localX, x), let y = axis(tileY, localY, y) else { return nil }
    return .init(tileX: x.0, tileY: y.0, localX: x.1, localY: y.1)
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
      let whole = Int64(floor(tileDelta)), fraction = tileDelta - floor(tileDelta)
      let local = start.1 + (end.1 - start.1) * progress + fraction * Self.tileSize
      let carry = Int64(floor(local / Self.tileSize))
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
    SpatialPoint(
      x: Double(other.tileX - tileX) * Self.tileSize
        + other.localX - localX,
      y: Double(other.tileY - tileY) * Self.tileSize
        + other.localY - localY
    )
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
    let tileX = Int64(floor(x / tileSize))
    let tileY = Int64(floor(y / tileSize))
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
    let xOffset = Int64(floor(localX / tileSize))
    let yOffset = Int64(floor(localY / tileSize))
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

  var isValid: Bool { x.isFinite && y.isFinite }
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

  var isValid: Bool {
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

public enum NotebookSelectionField {
  /// Elliptical selection strength around a projected cover. This chooses the
  /// notebook; the fingers remain the sole owner of camera movement.
  public static func influence(
    centroid: SpatialPoint,
    cover: SpatialRect,
    halo: Double = 1.5
  ) -> Double {
    guard halo.isFinite && halo > 1 else { return 0 }
    let centerX = cover.x + cover.width / 2
    let centerY = cover.y + cover.height / 2
    let radiusX = cover.width * halo / 2
    let radiusY = cover.height * halo / 2
    let normalized = sqrt(
      pow((centroid.x - centerX) / radiusX, 2)
        + pow((centroid.y - centerY) / radiusY, 2)
    )
    guard normalized < 1 else { return 0 }
    let t = 1 - normalized
    return t * t * (3 - 2 * t)
  }
}

public enum NotebookOpeningTransition {
  /// Converts the multiplicative scale of a pinch into reversible visual
  /// progress between the scale where this cover joined the gesture and the
  /// full-page presentation.
  public static func progress(
    cameraScale: Double,
    openingScale: Double,
    pageScale: Double
  ) -> Double {
    guard cameraScale.isFinite && cameraScale > 0,
      openingScale.isFinite && openingScale > 0,
      pageScale.isFinite && pageScale > openingScale
    else { return 0 }
    let progress = log(cameraScale / openingScale)
      / log(pageScale / openingScale)
    return min(max(progress, 0), 1)
  }

  /// Recovers the beginning of a released partial opening, so the next pinch
  /// continues the same curve rather than replacing it with a new one.
  public static func openingScale(
    cameraScale: Double,
    pageScale: Double,
    progress: Double,
    fallback: Double
  ) -> Double {
    guard cameraScale.isFinite && cameraScale > 0,
      pageScale.isFinite && pageScale > 0,
      progress.isFinite && progress > 0 && progress < 1,
      fallback.isFinite && fallback > 0
    else { return fallback }
    let resolved = exp(
      (log(cameraScale) - progress * log(pageScale)) / (1 - progress)
    )
    guard resolved.isFinite, resolved > 0, resolved < pageScale else {
      return fallback
    }
    return resolved
  }
}

/// Turns an approached notebook into one continuous camera target. The pinch
/// supplies the raw path; once a candidate is visibly near, this field adds a
/// pull toward its center and full-page scale. Centering leads during the board
/// approach; after the cover joins the gesture, center and depth converge
/// together toward the paper.
public struct NotebookDockingCorrection: Equatable, Sendable {
  public let centerWeight: Double
  public let scaleWeight: Double

  public static let zero = Self(centerWeight: 0, scaleWeight: 0)
}

public enum NotebookDockingField {
  public static let fieldStartScaleRatio = 0.52
  public static let fullStrengthScaleRatio = 0.96

  private static let approachCenterResponse = 1.5
  /// The cover's own progress is the magnetic coordinate. The response is
  /// nonzero at the first visible opening and grows continuously toward the
  /// full page without a second capture threshold.
  private static let openingResponse = 1.35

  public static func strength(
    camera: SpatialCamera,
    viewport: SpatialPoint,
    geometry: WorkspaceItemGeometry
  ) -> Double {
    guard viewport.x > 0, viewport.y > 0 else { return 0 }
    let pageScale = geometry.fitScale(viewport: viewport)
    return smoothstep(
      from: fieldStartScaleRatio,
      through: fullStrengthScaleRatio,
      value: camera.scale / pageScale
    )
  }

  public static func attractedCamera(
    _ camera: SpatialCamera,
    toward notebookCenter: WorldPoint,
    viewport: SpatialPoint,
    geometry: WorkspaceItemGeometry,
    correction: NotebookDockingCorrection
  ) -> SpatialCamera {
    guard camera.isValid, viewport.x > 0, viewport.y > 0,
      (0...1).contains(correction.centerWeight), (0...1).contains(correction.scaleWeight),
      correction.centerWeight > 0 || correction.scaleWeight > 0,
      let center = camera.center.interpolatedAddress(to: notebookCenter, amount: correction.centerWeight) else {
      return camera
    }
    let targetScale = geometry.fitScale(viewport: viewport)
    guard targetScale.isFinite, targetScale >= SpatialCamera.minimumScale else { return camera }
    let resolvedScale = exp(
      log(camera.scale)
        + (log(targetScale) - log(camera.scale)) * correction.scaleWeight
    )
    return SpatialCamera(
      center: center,
      scale: min(max(resolvedScale, min(camera.scale, targetScale)), max(camera.scale, targetScale))
    )
  }

  /// Starts a new gesture without re-applying a correction that is already
  /// visible in its starting camera. The remaining field then grows and fades
  /// as a pure function of the current raw camera, so reversing the fingers
  /// retraces the same path.
  public static func approachCorrection(
    currentStrength: Double,
    startingStrength: Double
  ) -> NotebookDockingCorrection {
    guard let strengths = normalizedStrengths(
      current: currentStrength,
      starting: startingStrength
    ) else { return .zero }

    return NotebookDockingCorrection(
      centerWeight: remainingWeight(
        current: approachCenterWeight(strengths.current),
        starting: approachCenterWeight(strengths.starting)
      ),
      scaleWeight: remainingWeight(
        current: strengths.current * strengths.current,
        starting: strengths.starting * strengths.starting
      )
    )
  }

  /// Continues from the exact correction visible when the cover joined the
  /// gesture. The cover's own opening coordinate now drives both center and
  /// depth. A resumed gesture subtracts its already-visible starting response,
  /// so the field never applies the same pull twice.
  public static func openingCorrection(
    currentProgress: Double,
    startingProgress: Double,
    continuingFrom base: NotebookDockingCorrection
  ) -> NotebookDockingCorrection {
    guard let progress = normalizedProgress(
      current: currentProgress,
      starting: startingProgress
    ) else { return base }
    let pull = remainingWeight(
      current: openingWeight(progress.current),
      starting: openingWeight(progress.starting)
    )
    return compose(
      base,
      with: NotebookDockingCorrection(
        centerWeight: pull,
        scaleWeight: pull
      )
    )
  }

  public static func shouldDock(
    openProgress: Double,
    isApproaching: Bool,
    releaseVelocity: Double
  ) -> Bool {
    openProgress.isFinite && releaseVelocity.isFinite
      && openProgress > 0
      && isApproaching
      && releaseVelocity >= -0.12
  }

  /// The first visible opening finishes slowly because the magnetic pull is
  /// still weak. Near the page the same owner settles quickly. Release velocity
  /// shortens that remaining motion without introducing another trajectory.
  public static func settlementDuration(
    openProgress: Double,
    releaseVelocity: Double
  ) -> Double {
    guard openProgress.isFinite, releaseVelocity.isFinite else { return 0.42 }
    let progress = min(max(openProgress, 0), 1)
    let approachingVelocity = min(max(releaseVelocity, 0), 2) / 2
    return min(
      max(0.42 - sqrt(progress) * 0.2 - approachingVelocity * 0.04, 0.18),
      0.42
    )
  }

  private static func remainingWeight(
    current: Double,
    starting: Double
  ) -> Double {
    guard starting < 1, current > starting else { return 0 }
    return (current - starting) / (1 - starting)
  }

  private static func normalizedStrengths(
    current: Double,
    starting: Double
  ) -> (current: Double, starting: Double)? {
    guard current.isFinite, starting.isFinite else { return nil }
    let current = min(max(current, 0), 1)
    let starting = min(max(starting, 0), 1)
    guard current > starting, starting < 1 else { return nil }
    return (current, starting)
  }

  private static func normalizedProgress(
    current: Double,
    starting: Double
  ) -> (current: Double, starting: Double)? {
    guard current.isFinite, starting.isFinite else { return nil }
    let current = min(max(current, 0), 1)
    let starting = min(max(starting, 0), 1)
    guard current > starting, starting < 1 else { return nil }
    return (current, starting)
  }

  private static func approachCenterWeight(_ strength: Double) -> Double {
    1 - pow(1 - strength, approachCenterResponse)
  }

  private static func openingWeight(_ progress: Double) -> Double {
    1 - pow(1 - progress, openingResponse)
  }

  private static func compose(
    _ base: NotebookDockingCorrection,
    with added: NotebookDockingCorrection
  ) -> NotebookDockingCorrection {
    NotebookDockingCorrection(
      centerWeight: 1
        - (1 - base.centerWeight) * (1 - added.centerWeight),
      scaleWeight: 1
        - (1 - base.scaleWeight) * (1 - added.scaleWeight)
    )
  }

  private static func smoothstep(
    from lowerBound: Double,
    through upperBound: Double,
    value: Double
  ) -> Double {
    guard lowerBound.isFinite, upperBound.isFinite, value.isFinite,
      upperBound > lowerBound
    else { return 0 }
    let t = min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)
    return t * t * (3 - 2 * t)
  }
}

/// Decides when an already-recognized outward pinch is close enough to hand
/// one notebook from the board camera to the opening transition.
public enum NotebookOpeningIntent {
  /// The page renderer moves to the approached notebook while the opaque cover
  /// still hides it, leaving enough camera travel to finish preparation.
  public static let pagePreparationScaleRatio = 0.55
  /// A cover joins the already-recognized pinch while it still occupies about
  /// sixty percent of a fitted page. This leaves visible travel before it
  /// reaches the former focused-cover size.
  public static let entryScaleRatio = 0.84
  /// Hysteresis keeps a newly engaged cover from blinking between board and
  /// cover while the fingers hover around the entry scale.
  public static let exitScaleRatio = 0.76
  public static let selectionHalo = 1.12
  /// A candidate survives small centroid noise while the camera approaches it,
  /// but is released once the fingers clearly leave the cover.
  public static let candidateRetentionHalo = 1.32

  public static func shouldEngage(
    isApproaching: Bool,
    cameraScale: Double,
    coverScale: Double
  ) -> Bool {
    guard isApproaching, cameraScale.isFinite,
      coverScale.isFinite, coverScale > 0,
      cameraScale >= coverScale * entryScaleRatio
    else { return false }
    return true
  }

  public static func shouldDisengage(
    cameraScale: Double,
    coverScale: Double
  ) -> Bool {
    cameraScale < coverScale * exitScaleRatio
  }
}

public struct FreeItemPlacement: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { itemID }

  public let itemID: UUID
  public private(set) var center: WorldPoint
  public private(set) var zIndex: Int
  public private(set) var stamp: VersionStamp

  public init(
    itemID: UUID,
    center: WorldPoint,
    zIndex: Int,
    stamp: VersionStamp
  ) {
    self.itemID = itemID
    self.center = center
    self.zIndex = zIndex
    self.stamp = stamp
  }

  var isValid: Bool {
    center.isValid && zIndex >= 0
      && stamp.counter <= VersionStamp.maximumCounter
  }
}

public struct WorkspaceItemStack: Codable, Equatable, Identifiable, Sendable {
  public static let maximumItemCount = 5

  public let id: UUID
  public private(set) var center: WorldPoint
  public private(set) var zIndex: Int
  public private(set) var itemIDs: [UUID]
  public private(set) var stamp: VersionStamp

  public init(
    id: UUID = UUID(),
    center: WorldPoint,
    zIndex: Int,
    itemIDs: [UUID],
    stamp: VersionStamp
  ) {
    precondition(
      itemIDs.count >= 2
        && itemIDs.count <= Self.maximumItemCount
    )
    self.id = id
    self.center = center
    self.zIndex = zIndex
    self.itemIDs = itemIDs
    self.stamp = stamp
  }

  var isValid: Bool {
    center.isValid && zIndex >= 0 && itemIDs.count >= 2
      && itemIDs.count <= Self.maximumItemCount
      && Set(itemIDs).count == itemIDs.count
      && stamp.counter <= VersionStamp.maximumCounter
  }
}

/// Gives every member of a stack one deterministic visual anchor. The board
/// may fan the covers apart as they become readable, while a focused cover or
/// page uses the fully fanned anchor. Camera and renderer therefore ask the
/// same owner where the selected notebook is.
public enum WorkspaceItemStackPresentation {
  private static let collapsedHorizontalSpacing = 9.0
  private static let collapsedVerticalSpacing = 7.0
  /// The whole fan occupies one bounded envelope regardless of whether it
  /// contains two or five covers. More members expose narrower, still
  /// tappable strips instead of pushing the outer notebooks off screen.
  private static let fannedHorizontalSpanRatio = 0.62
  private static let fannedVerticalSpanRatio = 0.08
  private static let fanStartProjectedHeight = 160.0
  private static let fanEndProjectedHeight = 600.0

  public static func boardCenter(
    of itemID: UUID,
    in stack: WorkspaceItemStack,
    cameraScale: Double,
    viewport: SpatialPoint
  ) -> WorldPoint? {
    guard cameraScale.isFinite, (SpatialCamera.minimumScale...SpatialCamera.maximumScale).contains(cameraScale),
      viewport.x.isFinite, viewport.x > 0,
      viewport.y.isFinite, viewport.y > 0,
      let index = stack.itemIDs.firstIndex(of: itemID)
    else { return nil }
    let centered = Double(index) - Double(stack.itemIDs.count - 1) / 2
    let projectedHeight = WorkspaceItemGeometry.notebook.height * cameraScale
    let coverProjectedHeight = WorkspaceItemGeometry.notebook.height
      * WorkspaceItemGeometry.notebook.coverScale(viewport: viewport)
    let fanEnd = min(fanEndProjectedHeight, coverProjectedHeight)
    let fanStart = min(fanStartProjectedHeight, fanEnd * 0.75)
    guard fanEnd.isFinite, fanEnd > fanStart else { return nil }
    let fan = min(
      max(
        (projectedHeight - fanStart) / (fanEnd - fanStart),
        0
      ),
      1
    )
    let collapsedX = centered * collapsedHorizontalSpacing / cameraScale
    let collapsedY = -Double(index) * collapsedVerticalSpacing / cameraScale
    let fanned = fannedOffset(index: index, count: stack.itemIDs.count)
    return stack.center.offsetBy(
      x: collapsedX + (fanned.x - collapsedX) * fan,
      y: collapsedY + (fanned.y - collapsedY) * fan
    )
  }

  public static func focusedCenter(
    of itemID: UUID,
    in stack: WorkspaceItemStack
  ) -> WorldPoint? {
    guard let index = stack.itemIDs.firstIndex(of: itemID) else {
      return nil
    }
    let fanned = fannedOffset(index: index, count: stack.itemIDs.count)
    // This is projection geometry, including the fan's outside edge. A
    // physical camera destination must separately admit this exact center.
    return stack.center.offsetBy(
      x: fanned.x,
      y: fanned.y
    )
  }

  private static func fannedOffset(index: Int, count: Int) -> SpatialPoint {
    let spanCount = Double(max(count - 1, 1))
    let centered = Double(index) - Double(count - 1) / 2
    return SpatialPoint(
      x: centered * WorkspaceItemGeometry.notebook.width
        * fannedHorizontalSpanRatio / spanCount,
      y: abs(centered) * WorkspaceItemGeometry.notebook.height
        * fannedVerticalSpanRatio / spanCount
    )
  }
}

public enum SurfaceKind: String, Codable, Sendable {
  case board
  case cover
  case page
  case codeFragment
}

public struct SurfaceID: Codable, Equatable, Hashable, Sendable {
  public let kind: SurfaceKind
  public let ownerID: UUID?

  public init(kind: SurfaceKind, ownerID: UUID? = nil) {
    precondition(ownerID != nil)
    self.kind = kind
    self.ownerID = ownerID
  }

  public static let board = SurfaceID(
    kind: .board,
    ownerID: WorkspaceRoot.boardID
  )
  public static func board(_ boardID: UUID) -> Self {
    Self(kind: .board, ownerID: boardID)
  }
  public static func cover(_ itemID: UUID) -> Self {
    Self(kind: .cover, ownerID: itemID)
  }
  public static func codeFragment(_ id: UUID) -> SurfaceID { .init(kind: .codeFragment, ownerID: id) }

  public static func page(_ pageID: UUID) -> Self {
    Self(kind: .page, ownerID: pageID)
  }

  var isValid: Bool { ownerID != nil }

  private enum CodingKeys: String, CodingKey {
    case kind
    case ownerID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(SurfaceKind.self, forKey: .kind)
    let storedOwner = try container.decodeIfPresent(UUID.self, forKey: .ownerID)
    ownerID = kind == .board && storedOwner == nil
      ? WorkspaceRoot.boardID
      : storedOwner
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(ownerID, forKey: .ownerID)
  }
}

public enum SpatialElementKind: String, Codable, Sendable {
  case nativeText
  case markdown
  case web
}

public struct NativeTextStyle: Codable, Equatable, Sendable {
  public let fontSize: Double
  public let weight: Double
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(
    fontSize: Double = 34,
    weight: Double = 0.45,
    red: Double = 0.09,
    green: Double = 0.09,
    blue: Double = 0.08,
    alpha: Double = 1
  ) {
    precondition(fontSize.isFinite && fontSize >= 8 && fontSize <= 240)
    precondition(weight.isFinite && weight >= 0 && weight <= 1)
    precondition([red, green, blue, alpha].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    self.fontSize = fontSize
    self.weight = weight
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let standard = NativeTextStyle()

  var isValid: Bool {
    fontSize.isFinite && fontSize >= 8 && fontSize <= 240
      && weight.isFinite && weight >= 0 && weight <= 1
      && [red, green, blue, alpha].allSatisfy {
        $0.isFinite && $0 >= 0 && $0 <= 1
      }
  }
}

public struct SpatialElement: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let surface: SurfaceID
  public let kind: SpatialElementKind
  public private(set) var frame: SpatialRect
  /// Board elements keep their tiled origin here. Their frame then describes
  /// size and local offset without flattening the unbounded board.
  public private(set) var worldOrigin: WorldPoint?
  public private(set) var source: String
  public private(set) var html: String
  public private(set) var css: String
  public private(set) var javaScript: String
  public private(set) var state: JSONValue
  public private(set) var textStyle: NativeTextStyle
  public private(set) var stamp: VersionStamp

  public init(
    id: String,
    surface: SurfaceID,
    kind: SpatialElementKind,
    frame: SpatialRect,
    worldOrigin: WorldPoint? = nil,
    source: String,
    html: String = "",
    css: String = "",
    javaScript: String = "",
    state: JSONValue = .object([:]),
    textStyle: NativeTextStyle = .standard,
    stamp: VersionStamp
  ) {
    precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.id = id
    self.surface = surface
    self.kind = kind
    self.frame = frame
    self.worldOrigin = worldOrigin
    self.source = source
    self.html = html
    self.css = css
    self.javaScript = javaScript
    self.state = state
    self.textStyle = textStyle
    self.stamp = stamp
    precondition(isValid)
  }

  public mutating func update(
    source: String? = nil,
    html: String? = nil,
    css: String? = nil,
    javaScript: String? = nil,
    state: JSONValue? = nil,
    frame: SpatialRect? = nil,
    worldOrigin: WorldPoint? = nil,
    textStyle: NativeTextStyle? = nil,
    actor: UUID
  ) -> Bool {
    guard let next = stamp.advanced(by: actor) else { return false }
    if let source { self.source = source }
    if let html { self.html = html }
    if let css { self.css = css }
    if let javaScript { self.javaScript = javaScript }
    if let state { self.state = state }
    if let frame { self.frame = frame }
    if let worldOrigin { self.worldOrigin = worldOrigin }
    if let textStyle { self.textStyle = textStyle }
    stamp = next
    return isValid
  }

  var isValid: Bool {
    !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && surface.isValid && surface.kind != .page
      && frame.isValid && state.isValid && textStyle.isValid
      && (surface.kind == .board
        ? worldOrigin?.isValid == true
        : worldOrigin == nil)
      && stamp.counter <= VersionStamp.maximumCounter
  }
}

public struct BoardDocument: Codable, Equatable, Sendable {
  public static let formatVersion = 3

  public let format: Int
  public private(set) var placements: [WorkspacePlacement]
  public private(set) var elements: [SpatialElement]
  public private(set) var stamp: VersionStamp
  public private(set) var collaboration: CollaborativeContent?
  private var layout: WorkspacePlacementLayout
  public var freeItems: [FreeItemPlacement] { layout.freeItems }
  public var stacks: [WorkspaceItemStack] { layout.stacks }

  public init(freeItems: [FreeItemPlacement], stacks: [WorkspaceItemStack] = [],
    elements: [SpatialElement] = [], stamp: VersionStamp) {
    var placements = freeItems.map { item in
      WorkspacePlacement(itemID: item.id, heads: [.init(
        pose: .init(center: item.center, zIndex: item.zIndex),
        version: .init(stamp: item.stamp, human: true))])
    }
    placements += stacks.flatMap { stack in
      stack.itemIDs.enumerated().map { offset, id in
        WorkspacePlacement(itemID: id, heads: [.init(
          pose: .init(center: stack.center, zIndex: stack.zIndex, stackID: stack.id, stackOrder: offset),
          version: .init(stamp: stack.stamp, human: true))])
      }
    }
    self.init(placements: placements, elements: elements, stamp: stamp, collaboration: nil)
  }

  init(placements: [WorkspacePlacement], elements: [SpatialElement], stamp: VersionStamp,
    collaboration: CollaborativeContent?) {
    format = Self.formatVersion
    self.placements = placements.sorted { $0.id.uuidString < $1.id.uuidString }
    self.elements = elements; self.stamp = stamp; self.collaboration = collaboration
    layout = .init(self.placements)
    materializeElementVersions()
  }

  private mutating func materializeElementVersions() {
    guard let content = try? JSONValue.encode(elements) else { return }
    var versions = collaboration ?? .init()
    versions.materializeVersions(in: .object(["elements": content]), fallback: stamp)
    collaboration = versions
  }

  public static func initial(itemIDs: [UUID], actor: UUID) -> Self {
    let columns = max(1, min(3, itemIDs.count))
    let horizontalStep = WorkspaceItemGeometry.notebook.width * 1.28
    let verticalStep = WorkspaceItemGeometry.notebook.height * 1.18
    return Self(freeItems: itemIDs.enumerated().map { offset, id in
      .init(itemID: id, center: .init(
        x: (Double(offset % columns) - Double(columns - 1) / 2) * horizontalStep,
        y: Double(offset / columns) * verticalStep), zIndex: offset,
        stamp: .init(counter: 0, actor: actor))
    }, stamp: .init(counter: 0, actor: actor))
  }

  public var itemIDs: [UUID] { placements.compactMap { $0.pose == nil ? nil : $0.id } }

  /// A latent singleton or a losing concurrent head still names its stack.
  /// Independent imports must not assign that UUID to a second group.
  public var claimedStackIDs: Set<UUID> {
    Set(placements.flatMap(\.heads).compactMap { $0.pose?.stackID })
  }

  public func hasRemovedElement(id: String) -> Bool {
    let identity = collaborationIdentity(id)
    return !elements.contains { collaborationIdentity($0.id) == identity }
      && collaboration?.fields[fieldKey(["elements", identity, "exists"])] != nil
  }

  /// A frozen projection retains the exact admitted intent rows, including a
  /// singleton's latent stack membership. It never manufactures authored heads.
  public func projecting(placements: [WorkspacePlacement], elements: [SpatialElement]) -> Self {
    Self(placements: placements, elements: elements, stamp: stamp, collaboration: collaboration)
  }

  public func importingIndependent(_ other: Self, actor: UUID) throws -> Self {
    guard isValid(itemIDs: []), other.isValid(itemIDs: []),
      Set(placements.map(\.id)).isDisjoint(with: other.placements.map(\.id)),
      claimedStackIDs.isDisjoint(with: other.claimedStackIDs),
      Set(elements.map(\.id)).isDisjoint(with: other.elements.map(\.id)),
      let next = max(stamp, other.stamp).advanced(by: actor) else {
      throw CollaborationError("import_collision", "Импорт добавляет независимых владельцев, не заменяя существующих.")
    }
    var local = collaboration ?? .init(), incoming = other.collaboration ?? .init()
    try local.materializeVersions(in: .encode(self), fallback: stamp)
    try incoming.materializeVersions(in: .encode(other), fallback: other.stamp)
    var fields = local.fields
    for (key, version) in incoming.fields {
      if key == "elements/order" { fields[key] = fields[key].map { $0.joining(version) } ?? version }
      else {
        guard fields[key] == nil else { throw CollaborationError("import_collision", "Владелец поля уже присутствует на доске.") }
        fields[key] = version
      }
    }
    var metadata = CollaborativeContent(fields: fields)
    metadata.recordField("elements/order", stamp: next, human: true)
    for element in other.elements {
      metadata.recordField(fieldKey(["elements", collaborationIdentity(element.id), "exists"]), stamp: next, human: true)
    }
    return Self(placements: placements + other.placements, elements: elements + other.elements,
      stamp: next, collaboration: metadata)
  }

  @discardableResult
  mutating func observeCausalFrontier(_ frontier: VersionStamp) -> Bool {
    guard frontier.counter <= VersionStamp.maximumCounter, stamp < frontier,
      let content = try? JSONValue.encode(self) else { return false }
    var versions = collaboration ?? CollaborativeContent()
    versions.materializeVersions(in: content, fallback: stamp)
    collaboration = versions; stamp = frontier
    return true
  }

  public var highestZIndex: Int {
    placements.compactMap { $0.pose?.zIndex }.max() ?? 0
  }

  public func placement(of itemID: UUID) -> FreeItemPlacement? { freeItems.first { $0.id == itemID } }
  public func stack(containing itemID: UUID) -> WorkspaceItemStack? { stacks.first { $0.itemIDs.contains(itemID) } }
  public func focusedCenter(of itemID: UUID) -> WorldPoint? {
    if let value = placement(of: itemID) { return value.center }
    guard let stack = stack(containing: itemID) else { return nil }
    return WorkspaceItemStackPresentation.focusedCenter(of: itemID, in: stack)
  }

  @discardableResult
  public mutating func placeMissingItems(_ expectedItemIDs: [UUID], actor: UUID) -> Bool {
    let missing = expectedItemIDs.filter { !itemIDs.contains($0) }
    guard !missing.isEmpty else { return false }
    let dx = WorkspaceItemGeometry.notebook.width * 1.28
    let dy = WorkspaceItemGeometry.notebook.height * 1.18
    var occupied = freeItems.map(\.center) + stacks.map(\.center), slot = 0
    for id in missing {
      var center: WorldPoint
      repeat {
        center = .init(x: (Double(slot % 3) - 1) * dx, y: Double(slot / 3) * dy)
        slot += 1
      } while occupied.contains { point in
        let delta = point.delta(to: center)
        return abs(delta.x) < dx * 0.5 && abs(delta.y) < dy * 0.5
      }
      guard addItem(id, near: center, actor: actor) else { return false }
      occupied.append(center)
    }
    return true
  }

  @discardableResult
  public mutating func reconcileItems(_ expectedItemIDs: [UUID], actor: UUID) -> Bool {
    let expected = Set(expectedItemIDs)
    var changed = false
    for id in itemIDs where !expected.contains(id) { changed = deleteItem(id, actor: actor) || changed }
    return placeMissingItems(expectedItemIDs, actor: actor) || changed
  }

  private mutating func author(_ poses: [UUID: WorkspacePlacementPose?], actor: UUID) -> Bool {
    guard !poses.isEmpty, let next = stamp.advanced(by: actor) else { return false }
    var values = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
    do {
      for (id, pose) in poses {
        values[id] = try .authored(itemID: id, pose: pose, stamp: next, human: true, previous: values[id])
      }
    } catch { return false }
    placements = values.values.sorted { $0.id.uuidString < $1.id.uuidString }
    layout = .init(placements); stamp = next
    return true
  }

  /// Causal undo is a new intent observing the retained frontier, never a
  /// replacement of the register with an older saved JSON value.
  @discardableResult
  mutating func restorePlacement(_ itemID: UUID, pose: WorkspacePlacementPose?, actor: UUID) -> Bool {
    author([itemID: pose], actor: actor)
  }

  @discardableResult
  public mutating func addItem(_ itemID: UUID, near center: WorldPoint, actor: UUID) -> Bool {
    guard center.isValid, !itemIDs.contains(itemID) else { return false }
    return author([itemID: .init(center: center, zIndex: highestZIndex + 1)], actor: actor)
  }

  @discardableResult
  public mutating func moveItem(_ itemID: UUID, to center: WorldPoint, actor: UUID) -> Bool {
    guard center.isValid, placement(of: itemID) != nil else { return false }
    return author([itemID: .init(center: center, zIndex: highestZIndex + 1)], actor: actor)
  }

  @discardableResult
  public mutating func createStack(moving movingID: UUID, onto targetID: UUID,
    actor: UUID, stackID: UUID = UUID()) -> UUID? {
    guard movingID != targetID, let moving = placement(of: movingID) else { return nil }
    if let stack = stack(containing: targetID) {
      guard stack.itemIDs.count < WorkspaceItemStack.maximumItemCount else { return nil }
      let order = placements.filter { $0.pose?.stackID == stack.id }.compactMap { $0.pose?.stackOrder }.max() ?? 0
      guard order < Int.max, author([movingID: .init(center: stack.center, zIndex: stack.zIndex,
        stackID: stack.id, stackOrder: order + 1)], actor: actor) else { return nil }
      return stack.id
    }
    guard let target = placement(of: targetID),
      !placements.contains(where: { $0.pose?.stackID == stackID }) else { return nil }
    let z = max(moving.zIndex, target.zIndex) + 1
    guard author([
      targetID: .init(center: target.center, zIndex: z, stackID: stackID, stackOrder: 0),
      movingID: .init(center: target.center, zIndex: z, stackID: stackID, stackOrder: 1)
    ], actor: actor) else { return nil }
    return stackID
  }

  @discardableResult
  public mutating func unstackItem(_ itemID: UUID, at center: WorldPoint, actor: UUID) -> Bool {
    guard center.isValid, placements.contains(where: { $0.id == itemID && $0.pose?.stackID != nil }) else { return false }
    return author([itemID: .init(center: center, zIndex: highestZIndex + 1)], actor: actor)
  }

  @discardableResult
  public mutating func deleteItem(_ itemID: UUID, actor: UUID) -> Bool {
    guard itemIDs.contains(itemID) else { return false }
    let before = self
    guard author([itemID: nil], actor: actor) else { return false }
    elements.removeAll { $0.surface == .cover(itemID) }
    recordCollaboration(from: before)
    return true
  }

  @discardableResult
  public mutating func upsertElement(_ element: SpatialElement, expected: VersionStamp?, actor: UUID) -> Bool {
    let before = self
    guard element.surface.kind != .page, let next = stamp.advanced(by: actor) else { return false }
    if let index = elements.firstIndex(where: { $0.id == element.id }) {
      if let expected, elements[index].stamp != expected { return false }
      elements[index] = element
    } else {
      guard expected == nil else { return false }
      elements.append(element)
    }
    stamp = next; recordCollaboration(from: before)
    return true
  }

  @discardableResult
  public mutating func removeElements(ids: Set<String>, actor: UUID) -> Int {
    let before = self
    guard !ids.isEmpty, let next = stamp.advanced(by: actor) else { return 0 }
    elements.removeAll { ids.contains($0.id) }
    let removed = before.elements.count - elements.count
    guard removed > 0 else { return 0 }
    stamp = next; recordCollaboration(from: before)
    return removed
  }

  private mutating func recordCollaboration(from before: Self) {
    guard stamp != before.stamp, let old = try? JSONValue.encode(before), let next = try? JSONValue.encode(self) else { return }
    var metadata = before.collaboration ?? .init()
    metadata.record(before: old, after: next, beforeStamp: before.stamp, stamp: stamp, human: true)
    collaboration = metadata
  }

  mutating func recordPlacementPreference(from before: Self, human: Bool) {
    let previous = Dictionary(uniqueKeysWithValues: before.placements.map { ($0.id, $0) })
    placements = placements.map { $0.authoredPreference(human: human, since: previous[$0.id]) }
    layout = .init(placements)
  }

  public mutating func merge(_ other: Self, itemIDs expectedIDs: Set<UUID>) throws -> Bool {
    guard isValid(itemIDs: []), other.isValid(itemIDs: []) else {
      throw CollaborationError("invalid_content", "Доска требует одного причинного владельца каждого предмета.")
    }
    var values = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
    for incoming in other.placements { values[incoming.id] = try values[incoming.id]?.merging(incoming) ?? incoming }
    let a = try JSONValue.encode(self), b = try JSONValue.encode(other)
    let fields = CollaborativeContent.merge(local: a, incoming: b, localState: collaboration,
      incomingState: other.collaboration, localStamp: stamp, incomingStamp: other.stamp)
    var result = try fields.value.decode(Self.self)
    result.placements = values.values.sorted { $0.id.uuidString < $1.id.uuidString }
    result.layout = .init(result.placements); result.collaboration = fields.state
    // Receiving a join is not another authored action. The next local write
    // advances this admitted frontier; equal heads yield equal headers now.
    result.stamp = max(stamp, other.stamp)
    guard result.isValid(itemIDs: expectedIDs) else {
      throw CollaborationError("ownership_conflict", "Объединённая доска должна сохранить каждого живого владельца.")
    }
    guard result != self else { return false }
    self = result
    return true
  }

  public func isValid(itemIDs expectedIDs: Set<UUID>) -> Bool {
    guard format == Self.formatVersion, stamp.counter <= VersionStamp.maximumCounter,
      collaboration?.isValid ?? true, Set(placements.map(\.id)).count == placements.count,
      placements.allSatisfy({ (try? $0.validate()) != nil && $0.heads.allSatisfy { $0.version.stamp.counter <= stamp.counter } }),
      elements.allSatisfy(\.isValid), Set(elements.map(\.id)).count == elements.count,
      expectedIDs.isSubset(of: Set(itemIDs)) else { return false }
    // A stack UUID names a fixed anchor, not a mutable group-pose owner.
    var anchors: [UUID: WorkspacePlacementPose] = [:]
    for placement in placements {
      guard let pose = placement.pose, let id = pose.stackID else { continue }
      if let anchor = anchors[id], anchor.center != pose.center || anchor.zIndex != pose.zIndex { return false }
      anchors[id] = pose
    }
    let owned = Set(itemIDs)
    return elements.allSatisfy { $0.surface.kind == .board || $0.surface.ownerID.map(owned.contains) == true }
  }

  private enum CodingKeys: String, CodingKey { case format, placements, elements, stamp, collaboration }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    format = try container.decode(Int.self, forKey: .format)
    guard format == Self.formatVersion else {
      throw DecodingError.dataCorruptedError(forKey: .format, in: container,
        debugDescription: "Board placement intents require an explicit version-two migration")
    }
    placements = try container.decode([WorkspacePlacement].self, forKey: .placements)
    elements = try container.decode([SpatialElement].self, forKey: .elements)
    stamp = try container.decode(VersionStamp.self, forKey: .stamp)
    collaboration = try container.decodeIfPresent(CollaborativeContent.self, forKey: .collaboration)
    layout = .init(placements)
    materializeElementVersions()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(format, forKey: .format)
    try container.encode(placements, forKey: .placements)
    try container.encode(elements, forKey: .elements)
    try container.encode(stamp, forKey: .stamp)
    try container.encodeIfPresent(collaboration, forKey: .collaboration)
  }
}

public enum WorkspaceSemanticMode: String, Codable, Sendable {
  case board
  case cover
  case page
  case document
}

public struct SessionPresence: Codable, Equatable, Hashable, Sendable {
  public static let formatVersion = 5

  public let format: Int
  public let boardID: UUID
  public let mode: WorkspaceSemanticMode
  public let camera: SpatialCamera
  public let viewport: SpatialPoint
  public let focusedItemID: UUID?
  public let openProgress: Double
  /// Selection is session state, never a catalog mutation. It survives a
  /// camera that has left the selected item and returned to its board.
  public let selectedItemID: UUID?
  public let notebookPageID: UUID?
  public let documentPageIndex: Int

  public init(
    boardID: UUID = WorkspaceRoot.boardID,
    mode: WorkspaceSemanticMode,
    camera: SpatialCamera,
    viewport: SpatialPoint,
    focusedItemID: UUID? = nil,
    openProgress: Double = 0,
    documentPageIndex: Int = 0,
    selectedItemID: UUID? = nil,
    notebookPageID: UUID? = nil
  ) {
    precondition(
      openProgress.isFinite && openProgress >= 0 && openProgress <= 1
        && documentPageIndex >= 0
    )
    format = Self.formatVersion
    self.boardID = boardID
    self.mode = mode
    self.camera = camera
    self.viewport = viewport
    self.focusedItemID = focusedItemID
    self.openProgress = openProgress
    self.selectedItemID = selectedItemID ?? focusedItemID
    self.notebookPageID = notebookPageID
    self.documentPageIndex = documentPageIndex
  }

  public var isValid: Bool {
    format == Self.formatVersion && camera.isValid
      && viewport.isValid && viewport.x > 0 && viewport.y > 0
      && openProgress.isFinite && openProgress >= 0 && openProgress <= 1
      && documentPageIndex >= 0
      && (notebookPageID == nil || selectedItemID != nil)
      && (mode == .board || focusedItemID != nil)
      && (mode == .cover || mode == .document || documentPageIndex == 0)
  }

  public var isSettled: Bool {
    guard isValid else { return false }
    switch mode {
    case .board:
      return focusedItemID == nil && openProgress <= 0.001
    case .cover:
      return focusedItemID != nil
    case .page, .document:
      return focusedItemID != nil && openProgress >= 0.999
    }
  }

  /// Projects the same camera into another viewport. A docked page has one
  /// canonical scale; every free board or cover position keeps its
  /// dimensionless zoom relative to its owner's physical rectangle.
  public func adapted(to targetViewport: SpatialPoint, geometry: WorkspaceItemGeometry) -> Self {
    precondition(targetViewport.x > 0 && targetViewport.y > 0)
    let targetFit = geometry.fitScale(viewport: targetViewport)
    let resolvedScale: Double
    if (mode == .page || mode == .document) && openProgress >= 0.999 {
      resolvedScale = targetFit
    } else {
      let sourceFit = geometry.fitScale(viewport: viewport)
      resolvedScale = camera.scale * targetFit / sourceFit
    }
    return Self(
      boardID: boardID,
      mode: mode,
      camera: SpatialCamera(
        center: camera.center,
        scale: max(SpatialCamera.minimumScale, resolvedScale)
      ),
      viewport: targetViewport,
      focusedItemID: focusedItemID,
      openProgress: openProgress,
      documentPageIndex: documentPageIndex,
      selectedItemID: selectedItemID,
      notebookPageID: notebookPageID
    )
  }

  public func selecting(itemID: UUID?, pageID: UUID?) -> Self {
    Self(boardID: boardID, mode: mode, camera: camera, viewport: viewport,
      focusedItemID: focusedItemID, openProgress: openProgress,
      documentPageIndex: documentPageIndex, selectedItemID: itemID, notebookPageID: pageID)
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case boardID
    case mode
    case camera
    case viewport
    case focusedItemID
    case openProgress
    case documentPageIndex
    case selectedItemID
    case notebookPageID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedFormat = try container.decode(Int.self, forKey: .format)
    guard storedFormat == Self.formatVersion else {
      throw DecodingError.dataCorruptedError(forKey: .format, in: container,
        debugDescription: "Presence requires an externally converted checkpoint")
    }
    format = storedFormat
    mode = try container.decode(WorkspaceSemanticMode.self, forKey: .mode)
    camera = try container.decode(SpatialCamera.self, forKey: .camera)
    viewport = try container.decode(SpatialPoint.self, forKey: .viewport)
    openProgress = try container.decode(Double.self, forKey: .openProgress)
    boardID = try container.decode(UUID.self, forKey: .boardID)
    focusedItemID = try container.decodeIfPresent(UUID.self, forKey: .focusedItemID)
    selectedItemID = try container.decodeIfPresent(UUID.self, forKey: .selectedItemID)
    notebookPageID = try container.decodeIfPresent(UUID.self, forKey: .notebookPageID)
    documentPageIndex = try container.decode(Int.self, forKey: .documentPageIndex)
    guard isValid else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
        debugDescription: "Invalid session selection or geometry"))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.formatVersion, forKey: .format)
    try container.encode(boardID, forKey: .boardID)
    try container.encode(mode, forKey: .mode)
    try container.encode(camera, forKey: .camera)
    try container.encode(viewport, forKey: .viewport)
    try container.encodeIfPresent(focusedItemID, forKey: .focusedItemID)
    try container.encode(openProgress, forKey: .openProgress)
    try container.encode(documentPageIndex, forKey: .documentPageIndex)
    try container.encodeIfPresent(selectedItemID, forKey: .selectedItemID)
    try container.encodeIfPresent(notebookPageID, forKey: .notebookPageID)
  }
}
