import Foundation

/// A point on the unbounded board. The tile keeps nearby calculations small
/// even after the camera has travelled far away from the origin.
public struct WorldPoint: Codable, Equatable, Hashable, Sendable {
  /// 256 half-centimetre cells. Every visible board-grid level therefore
  /// lands on the same line at a tile boundary.
  public static let tileSize = PhysicalPaper.gridSpacing * 256

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

  var isValid: Bool {
    localX.isFinite && localY.isFinite
      && localX >= 0 && localX < Self.tileSize
      && localY >= 0 && localY < Self.tileSize
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

  public mutating func pan(screenX: Double, screenY: Double) {
    precondition(screenX.isFinite && screenY.isFinite)
    center = center.offsetBy(
      x: -screenX / scale,
      y: -screenY / scale
    )
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
    let worldAnchor = screenToWorld(startCentroid, viewport: viewport)
    let upperScale = min(
      max(maximumScale, Self.minimumScale),
      Self.maximumScale
    )
    let resolvedScale = min(
      max(scale * magnification, Self.minimumScale),
      upperScale
    )
    let resolvedCenter = worldAnchor.offsetBy(
      x: -(currentCentroid.x - viewport.x / 2) / resolvedScale,
      y: -(currentCentroid.y - viewport.y / 2) / resolvedScale
    )
    return Self(
      center: resolvedCenter,
      scale: resolvedScale
    )
  }

  var isValid: Bool {
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
    guard correction.centerWeight > 0 || correction.scaleWeight > 0 else {
      return camera
    }
    let delta = camera.center.delta(to: notebookCenter)
    let targetScale = geometry.fitScale(viewport: viewport)
    let resolvedScale = exp(
      log(camera.scale)
        + (log(targetScale) - log(camera.scale)) * correction.scaleWeight
    )
    return SpatialCamera(
      center: camera.center.offsetBy(
        x: delta.x * correction.centerWeight,
        y: delta.y * correction.centerWeight
      ),
      scale: resolvedScale
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

  mutating func move(to center: WorldPoint, zIndex: Int, actor: UUID) -> Bool {
    guard let next = stamp.advanced(by: actor) else { return false }
    self.center = center
    self.zIndex = zIndex
    stamp = next
    return true
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

  mutating func append(_ itemID: UUID, actor: UUID) -> Bool {
    guard itemIDs.count < Self.maximumItemCount,
      !itemIDs.contains(itemID),
      let next = stamp.advanced(by: actor)
    else { return false }
    itemIDs.append(itemID)
    stamp = next
    return true
  }

  mutating func remove(_ itemID: UUID, actor: UUID) -> Bool {
    guard let index = itemIDs.firstIndex(of: itemID),
      let next = stamp.advanced(by: actor)
    else { return false }
    itemIDs.remove(at: index)
    stamp = next
    return true
  }

  mutating func move(to center: WorldPoint, zIndex: Int, actor: UUID) -> Bool {
    guard let next = stamp.advanced(by: actor) else { return false }
    self.center = center
    self.zIndex = zIndex
    stamp = next
    return true
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
    guard cameraScale.isFinite, cameraScale > 0,
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
  public static let formatVersion = 2

  public let format: Int
  public private(set) var freeItems: [FreeItemPlacement]
  public private(set) var stacks: [WorkspaceItemStack]
  public private(set) var elements: [SpatialElement]
  public private(set) var stamp: VersionStamp
  public private(set) var collaboration: CollaborativeContent?

  public init(
    freeItems: [FreeItemPlacement],
    stacks: [WorkspaceItemStack] = [],
    elements: [SpatialElement] = [],
    stamp: VersionStamp
  ) {
    format = Self.formatVersion
    self.freeItems = freeItems
    self.stacks = stacks
    self.elements = elements
    self.stamp = stamp
    collaboration = nil
  }

  public static func initial(itemIDs: [UUID], actor: UUID) -> Self {
    let columns = max(1, min(3, itemIDs.count))
    let horizontalStep = WorkspaceItemGeometry.notebook.width * 1.28
    let verticalStep = WorkspaceItemGeometry.notebook.height * 1.18
    let placements = itemIDs.enumerated().map { index, id in
      let column = index % columns
      let row = index / columns
      return FreeItemPlacement(
        itemID: id,
        center: WorldPoint(
          x: (Double(column) - Double(columns - 1) / 2) * horizontalStep,
          y: Double(row) * verticalStep
        ),
        zIndex: index,
        stamp: VersionStamp(counter: 0, actor: actor)
      )
    }
    return Self(
      freeItems: placements,
      stamp: VersionStamp(counter: 0, actor: actor)
    )
  }

  public var itemIDs: [UUID] {
    freeItems.map(\.itemID) + stacks.flatMap(\.itemIDs)
  }

  /// Reserve the pending mutation's clock, keeping the actual field versions
  /// at their previous frontier even when they were still implicit.
  @discardableResult
  mutating func observeCausalFrontier(_ frontier: VersionStamp) -> Bool {
    guard frontier.counter <= VersionStamp.maximumCounter, stamp < frontier,
      let content = try? JSONValue.encode(self) else { return false }
    var versions = collaboration ?? CollaborativeContent()
    versions.materializeVersions(in: content, fallback: stamp)
    collaboration = versions
    stamp = frontier
    return true
  }

  public var highestZIndex: Int {
    max(
      freeItems.map(\.zIndex).max() ?? 0,
      stacks.map(\.zIndex).max() ?? 0
    )
  }

  public func placement(of itemID: UUID) -> FreeItemPlacement? {
    freeItems.first { $0.itemID == itemID }
  }

  public func stack(containing itemID: UUID) -> WorkspaceItemStack? {
    stacks.first { $0.itemIDs.contains(itemID) }
  }

  public func focusedCenter(of itemID: UUID) -> WorldPoint? {
    if let placement = placement(of: itemID) { return placement.center }
    guard let stack = stack(containing: itemID) else { return nil }
    return WorkspaceItemStackPresentation.focusedCenter(
      of: itemID,
      in: stack
    )
  }

  /// Restores board ownership for catalog items written by releases that only
  /// placed the first notebook. Existing positions remain untouched; each
  /// missing item receives the first free slot in the board's native grid.
  @discardableResult
  public mutating func placeMissingItems(
    _ expectedItemIDs: [UUID],
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    let missing = expectedItemIDs.filter { !itemIDs.contains($0) }
    guard !missing.isEmpty else { return false }

    let horizontalStep = WorkspaceItemGeometry.notebook.width * 1.28
    let verticalStep = WorkspaceItemGeometry.notebook.height * 1.18
    var occupied = freeItems.map(\.center) + stacks.map(\.center)
    var slot = 0

    for itemID in missing {
      var center: WorldPoint
      repeat {
        let column = slot % 3
        let row = slot / 3
        center = WorldPoint(
          x: (Double(column) - 1) * horizontalStep,
          y: Double(row) * verticalStep
        )
        slot += 1
      } while occupied.contains { existing in
        let delta = existing.delta(to: center)
        return abs(delta.x) < horizontalStep * 0.5
          && abs(delta.y) < verticalStep * 0.5
      }

      guard addItem(itemID, near: center, actor: actor) else {
        return false
      }
      occupied.append(center)
    }
    return true
  }

  /// Turns a recoverable publication boundary into one stable board: orphaned
  /// owners leave first, then every missing catalog item receives a place.
  @discardableResult
  public mutating func reconcileItems(
    _ expectedItemIDs: [UUID],
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    let expected = Set(expectedItemIDs)
    let obsolete = itemIDs.filter { !expected.contains($0) }
    var changed = false
    for itemID in obsolete {
      changed = deleteItem(itemID, actor: actor) || changed
    }
    return placeMissingItems(expectedItemIDs, actor: actor) || changed
  }

  @discardableResult
  public mutating func addItem(
    _ itemID: UUID,
    near center: WorldPoint,
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard !itemIDs.contains(itemID),
      let next = stamp.advanced(by: actor)
    else { return false }
    freeItems.append(
      FreeItemPlacement(
        itemID: itemID,
        center: center,
        zIndex: highestZIndex + 1,
        stamp: next
      )
    )
    stamp = next
    return true
  }

  @discardableResult
  public mutating func moveItem(
    _ itemID: UUID,
    to center: WorldPoint,
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard let index = freeItems.firstIndex(where: {
      $0.itemID == itemID
    }), let next = stamp.advanced(by: actor)
    else { return false }
    guard freeItems[index].move(
      to: center,
      zIndex: highestZIndex + 1,
      actor: actor
    ) else { return false }
    stamp = next
    return true
  }

  @discardableResult
  public mutating func createStack(
    moving movingID: UUID,
    onto targetID: UUID,
    actor: UUID,
    stackID: UUID = UUID()
  ) -> UUID? {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard movingID != targetID,
      let movingIndex = freeItems.firstIndex(where: {
        $0.itemID == movingID
      }), let next = stamp.advanced(by: actor)
    else { return nil }

    if let stackIndex = stacks.firstIndex(where: {
      $0.itemIDs.contains(targetID)
    }) {
      guard stacks[stackIndex].append(movingID, actor: actor) else { return nil }
      freeItems.remove(at: movingIndex)
      stamp = next
      return stacks[stackIndex].id
    }

    guard let targetIndex = freeItems.firstIndex(where: {
      $0.itemID == targetID
    }) else { return nil }
    let moving = freeItems[movingIndex]
    let target = freeItems[targetIndex]
    let indexes = [movingIndex, targetIndex].sorted(by: >)
    for index in indexes { freeItems.remove(at: index) }
    stacks.append(
      WorkspaceItemStack(
        id: stackID,
        center: target.center,
        zIndex: max(moving.zIndex, target.zIndex) + 1,
        itemIDs: [targetID, movingID],
        stamp: next
      )
    )
    stamp = next
    return stackID
  }

  @discardableResult
  public mutating func unstackItem(
    _ itemID: UUID,
    at center: WorldPoint,
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard let stackIndex = stacks.firstIndex(where: {
      $0.itemIDs.contains(itemID)
    }), let next = stamp.advanced(by: actor)
    else { return false }
    var stack = stacks[stackIndex]
    guard stack.remove(itemID, actor: actor) else { return false }
    freeItems.append(
      FreeItemPlacement(
        itemID: itemID,
        center: center,
        zIndex: highestZIndex + 1,
        stamp: next
      )
    )
    if stack.itemIDs.count == 1, let remaining = stack.itemIDs.first {
      freeItems.append(
        FreeItemPlacement(
          itemID: remaining,
          center: stack.center,
          zIndex: stack.zIndex,
          stamp: next
        )
      )
      stacks.remove(at: stackIndex)
    } else {
      stacks[stackIndex] = stack
    }
    stamp = next
    return true
  }

  /// Removes a notebook from its single board owner. A two-member stack turns
  /// into one free notebook, and cover elements leave with their cover.
  @discardableResult
  public mutating func deleteItem(
    _ itemID: UUID,
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard itemIDs.contains(itemID),
      let next = stamp.advanced(by: actor)
    else { return false }

    if let index = freeItems.firstIndex(where: {
      $0.itemID == itemID
    }) {
      freeItems.remove(at: index)
    } else if let stackIndex = stacks.firstIndex(where: {
      $0.itemIDs.contains(itemID)
    }) {
      var stack = stacks[stackIndex]
      guard stack.remove(itemID, actor: actor) else { return false }
      if stack.itemIDs.count == 1, let remaining = stack.itemIDs.first {
        freeItems.append(
          FreeItemPlacement(
            itemID: remaining,
            center: stack.center,
            zIndex: stack.zIndex,
            stamp: next
          )
        )
        stacks.remove(at: stackIndex)
      } else {
        stacks[stackIndex] = stack
      }
    } else {
      return false
    }

    elements.removeAll { $0.surface == .cover(itemID) }
    stamp = next
    return true
  }

  @discardableResult
  public mutating func upsertElement(
    _ element: SpatialElement,
    expected: VersionStamp?,
    actor: UUID
  ) -> Bool {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard element.surface.kind != .page,
      let next = stamp.advanced(by: actor)
    else { return false }
    if let index = elements.firstIndex(where: { $0.id == element.id }) {
      if let expected, elements[index].stamp != expected { return false }
      elements[index] = element
    } else {
      guard expected == nil else { return false }
      elements.append(element)
    }
    stamp = next
    return true
  }

  @discardableResult
  public mutating func removeElements(
    ids: Set<String>,
    actor: UUID
  ) -> Int {
    let contentBefore = self
    defer { recordCollaboration(from: contentBefore) }
    guard !ids.isEmpty, let next = stamp.advanced(by: actor) else { return 0 }
    let before = elements.count
    elements.removeAll { ids.contains($0.id) }
    let removed = before - elements.count
    guard removed > 0 else { return 0 }
    stamp = next
    return removed
  }

  private mutating func recordCollaboration(from before: Self) {
    guard stamp != before.stamp,
      let old = try? JSONValue.encode(before), let next = try? JSONValue.encode(self) else { return }
    var metadata = before.collaboration ?? CollaborativeContent()
    metadata.record(before: old, after: next, beforeStamp: before.stamp, stamp: stamp, human: true)
    collaboration = metadata
  }

  public mutating func merge(_ other: Self, itemIDs: Set<UUID>) -> Bool {
    guard other.isValid(itemIDs: itemIDs),
      let local = try? JSONValue.encode(self), let incoming = try? JSONValue.encode(other) else { return false }
    let merged = CollaborativeContent.merge(local: local, incoming: incoming,
      localState: collaboration, incomingState: other.collaboration,
      localStamp: stamp, incomingStamp: other.stamp)
    guard var candidate = try? merged.value.decode(Self.self), candidate.isValid(itemIDs: itemIDs) else {
      guard stamp < other.stamp else { return false }
      self = other
      return true
    }
    candidate.collaboration = merged.state
    candidate.stamp = mergedContentStamp(local: local, incoming: incoming, result: merged.value,
      localStamp: stamp, incomingStamp: other.stamp)
    guard candidate != self else { return false }
    self = candidate
    return true
  }

  public func isValid(itemIDs expectedIDs: Set<UUID>) -> Bool {
    guard format == Self.formatVersion,
      collaboration?.isValid ?? true,
      stamp.counter <= VersionStamp.maximumCounter,
      freeItems.allSatisfy(\.isValid),
      stacks.allSatisfy(\.isValid),
      elements.allSatisfy(\.isValid)
    else { return false }
    let ids = itemIDs
    let ownedIDs = Set(ids)
    guard ownedIDs.count == ids.count,
      expectedIDs.isSubset(of: ownedIDs)
    else { return false }
    let stackIDs = stacks.map(\.id)
    guard Set(stackIDs).count == stackIDs.count else { return false }
    let elementIDs = elements.map(\.id)
    guard Set(elementIDs).count == elementIDs.count else { return false }
    return elements.allSatisfy { element in
      element.surface.kind == .board
        || element.surface.ownerID.map(ownedIDs.contains) == true
    }
  }

  private enum CodingKeys: String, CodingKey {
    case format
    case freeItems
    case stacks
    case elements
    case stamp
    case collaboration
    case legacyFreeNotebooks = "freeNotebooks"
  }

  private struct LegacyFreeNotebookPlacement: Codable {
    let notebookID: UUID
    let center: WorldPoint
    let zIndex: Int
    let stamp: VersionStamp
  }

  private struct LegacyNotebookStack: Codable {
    let id: UUID
    let center: WorldPoint
    let zIndex: Int
    let notebookIDs: [UUID]
    let stamp: VersionStamp
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedFormat = try container.decode(Int.self, forKey: .format)
    format = Self.formatVersion
    elements = try container.decode([SpatialElement].self, forKey: .elements)
    stamp = try container.decode(VersionStamp.self, forKey: .stamp)
    collaboration = try container.decodeIfPresent(CollaborativeContent.self, forKey: .collaboration)

    switch storedFormat {
    case Self.formatVersion:
      freeItems = try container.decode(
        [FreeItemPlacement].self,
        forKey: .freeItems
      )
      stacks = try container.decode(
        [WorkspaceItemStack].self,
        forKey: .stacks
      )
    case 1:
      let legacyFree = try container.decode(
        [LegacyFreeNotebookPlacement].self,
        forKey: .legacyFreeNotebooks
      )
      let legacyStacks = try container.decode(
        [LegacyNotebookStack].self,
        forKey: .stacks
      )
      freeItems = legacyFree.map {
        FreeItemPlacement(
          itemID: $0.notebookID,
          center: $0.center,
          zIndex: $0.zIndex,
          stamp: $0.stamp
        )
      }
      stacks = legacyStacks.map {
        WorkspaceItemStack(
          id: $0.id,
          center: $0.center,
          zIndex: $0.zIndex,
          itemIDs: $0.notebookIDs,
          stamp: $0.stamp
        )
      }
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .format,
        in: container,
        debugDescription: "Unsupported board format: \(storedFormat)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.formatVersion, forKey: .format)
    try container.encode(freeItems, forKey: .freeItems)
    try container.encode(stacks, forKey: .stacks)
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
