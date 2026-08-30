import Foundation

public enum NotebookGeometry {
  public static let width = 834.0
  public static let height = 1_194.0
  /// Visually follows the continuous display corner of a full-size iPad while
  /// leaving the paper slightly squarer than the previous one-centimeter arc.
  public static let cornerRadius = PhysicalPaper.pointsPerCentimeter * 0.8
}

/// Converts the fixed physical notebook into a presentation for a particular
/// viewport. Camera scale is stored relative to this fit, so changing an
/// aspect ratio and changing it back cannot progressively shrink the scene.
public enum NotebookPresentation {
  public static let coverScaleRatio = 0.72

  public static func fitScale(viewport: SpatialPoint) -> Double {
    precondition(viewport.x > 0 && viewport.y > 0)
    return min(
      viewport.x / NotebookGeometry.width,
      viewport.y / NotebookGeometry.height
    )
  }

  public static func coverScale(viewport: SpatialPoint) -> Double {
    fitScale(viewport: viewport) * coverScaleRatio
  }
}

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
  /// progress between the closed cover and the full-page presentation.
  public static func progress(
    cameraScale: Double,
    coverScale: Double,
    pageScale: Double
  ) -> Double {
    guard cameraScale.isFinite && cameraScale > 0,
      coverScale.isFinite && coverScale > 0,
      pageScale.isFinite && pageScale > coverScale
    else { return 0 }
    let progress = log(cameraScale / coverScale)
      / log(pageScale / coverScale)
    return min(max(progress, 0), 1)
  }
}

/// Attracts only the last part of a notebook approach. The raw pinch remains
/// the camera everywhere else, while a nearby, centered page acquires one
/// reversible full-screen docking target.
public enum NotebookDockingField {
  public static let fieldStartScaleRatio = 0.82
  public static let fullStrengthScaleRatio = 0.97
  public static let innerCenterRadiusRatio = 0.015
  public static let outerCenterRadiusRatio = 0.14
  public static let commitStrength = 0.72

  public static func strength(
    camera: SpatialCamera,
    notebookCenter: WorldPoint,
    viewport: SpatialPoint
  ) -> Double {
    guard viewport.x > 0, viewport.y > 0 else { return 0 }
    let pageScale = NotebookPresentation.fitScale(viewport: viewport)
    let scaleStrength = smoothstep(
      from: fieldStartScaleRatio,
      through: fullStrengthScaleRatio,
      value: camera.scale / pageScale
    )
    let projected = camera.worldToScreen(notebookCenter, viewport: viewport)
    let centerDistance = hypot(
      projected.x - viewport.x / 2,
      projected.y - viewport.y / 2
    )
    let shortSide = min(viewport.x, viewport.y)
    let centerStrength = 1 - smoothstep(
      from: innerCenterRadiusRatio * shortSide,
      through: outerCenterRadiusRatio * shortSide,
      value: centerDistance
    )
    return scaleStrength * centerStrength
  }

  public static func attractedCamera(
    _ camera: SpatialCamera,
    toward notebookCenter: WorldPoint,
    viewport: SpatialPoint,
    strength: Double
  ) -> SpatialCamera {
    guard strength.isFinite, strength > 0 else { return camera }
    let weight = pow(min(strength, 1), 2)
    let delta = camera.center.delta(to: notebookCenter)
    let targetScale = NotebookPresentation.fitScale(viewport: viewport)
    let resolvedScale = exp(
      log(camera.scale) + (log(targetScale) - log(camera.scale)) * weight
    )
    return SpatialCamera(
      center: camera.center.offsetBy(
        x: delta.x * weight,
        y: delta.y * weight
      ),
      scale: resolvedScale
    )
  }

  public static func shouldDock(
    strength: Double,
    isApproaching: Bool,
    velocity: Double
  ) -> Bool {
    strength.isFinite && velocity.isFinite
      && strength >= commitStrength
      && isApproaching
      && velocity >= -0.05
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
  /// A notebook receives the opening gesture only after reaching its normal
  /// focused-cover size on screen.
  public static let entryScaleRatio = 1.0
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
    cameraScale < coverScale * 0.9
  }
}

public struct FreeNotebookPlacement: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { notebookID }

  public let notebookID: UUID
  public private(set) var center: WorldPoint
  public private(set) var zIndex: Int
  public private(set) var stamp: VersionStamp

  public init(
    notebookID: UUID,
    center: WorldPoint,
    zIndex: Int,
    stamp: VersionStamp
  ) {
    self.notebookID = notebookID
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

public struct NotebookStack: Codable, Equatable, Identifiable, Sendable {
  public static let maximumNotebookCount = 5

  public let id: UUID
  public private(set) var center: WorldPoint
  public private(set) var zIndex: Int
  public private(set) var notebookIDs: [UUID]
  public private(set) var stamp: VersionStamp

  public init(
    id: UUID = UUID(),
    center: WorldPoint,
    zIndex: Int,
    notebookIDs: [UUID],
    stamp: VersionStamp
  ) {
    precondition(
      notebookIDs.count >= 2
        && notebookIDs.count <= Self.maximumNotebookCount
    )
    self.id = id
    self.center = center
    self.zIndex = zIndex
    self.notebookIDs = notebookIDs
    self.stamp = stamp
  }

  mutating func append(_ notebookID: UUID, actor: UUID) -> Bool {
    guard notebookIDs.count < Self.maximumNotebookCount,
      !notebookIDs.contains(notebookID),
      let next = stamp.advanced(by: actor)
    else { return false }
    notebookIDs.append(notebookID)
    stamp = next
    return true
  }

  mutating func remove(_ notebookID: UUID, actor: UUID) -> Bool {
    guard let index = notebookIDs.firstIndex(of: notebookID),
      let next = stamp.advanced(by: actor)
    else { return false }
    notebookIDs.remove(at: index)
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
    center.isValid && zIndex >= 0 && notebookIDs.count >= 2
      && notebookIDs.count <= Self.maximumNotebookCount
      && Set(notebookIDs).count == notebookIDs.count
      && stamp.counter <= VersionStamp.maximumCounter
  }
}

/// Gives every member of a stack one deterministic visual anchor. The board
/// may fan the covers apart as they become readable, while a focused cover or
/// page uses the fully fanned anchor. Camera and renderer therefore ask the
/// same owner where the selected notebook is.
public enum NotebookStackPresentation {
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
    of notebookID: UUID,
    in stack: NotebookStack,
    cameraScale: Double,
    viewport: SpatialPoint
  ) -> WorldPoint? {
    guard cameraScale.isFinite, cameraScale > 0,
      viewport.x.isFinite, viewport.x > 0,
      viewport.y.isFinite, viewport.y > 0,
      let index = stack.notebookIDs.firstIndex(of: notebookID)
    else { return nil }
    let centered = Double(index) - Double(stack.notebookIDs.count - 1) / 2
    let projectedHeight = NotebookGeometry.height * cameraScale
    let coverProjectedHeight = NotebookGeometry.height
      * NotebookPresentation.coverScale(viewport: viewport)
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
    let fanned = fannedOffset(index: index, count: stack.notebookIDs.count)
    return stack.center.offsetBy(
      x: collapsedX + (fanned.x - collapsedX) * fan,
      y: collapsedY + (fanned.y - collapsedY) * fan
    )
  }

  public static func focusedCenter(
    of notebookID: UUID,
    in stack: NotebookStack
  ) -> WorldPoint? {
    guard let index = stack.notebookIDs.firstIndex(of: notebookID) else {
      return nil
    }
    let fanned = fannedOffset(index: index, count: stack.notebookIDs.count)
    return stack.center.offsetBy(
      x: fanned.x,
      y: fanned.y
    )
  }

  private static func fannedOffset(index: Int, count: Int) -> SpatialPoint {
    let spanCount = Double(max(count - 1, 1))
    let centered = Double(index) - Double(count - 1) / 2
    return SpatialPoint(
      x: centered * NotebookGeometry.width
        * fannedHorizontalSpanRatio / spanCount,
      y: abs(centered) * NotebookGeometry.height
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
    precondition((kind == .board) == (ownerID == nil))
    self.kind = kind
    self.ownerID = ownerID
  }

  public static let board = SurfaceID(kind: .board)
  public static func cover(_ notebookID: UUID) -> Self {
    Self(kind: .cover, ownerID: notebookID)
  }
  public static func page(_ pageID: UUID) -> Self {
    Self(kind: .page, ownerID: pageID)
  }

  var isValid: Bool { (kind == .board) == (ownerID == nil) }
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
  public static let formatVersion = 1

  public let format: Int
  public private(set) var freeNotebooks: [FreeNotebookPlacement]
  public private(set) var stacks: [NotebookStack]
  public private(set) var elements: [SpatialElement]
  public private(set) var stamp: VersionStamp

  public init(
    freeNotebooks: [FreeNotebookPlacement],
    stacks: [NotebookStack] = [],
    elements: [SpatialElement] = [],
    stamp: VersionStamp
  ) {
    format = Self.formatVersion
    self.freeNotebooks = freeNotebooks
    self.stacks = stacks
    self.elements = elements
    self.stamp = stamp
  }

  public static func initial(notebookIDs: [UUID], actor: UUID) -> Self {
    let columns = max(1, min(3, notebookIDs.count))
    let horizontalStep = NotebookGeometry.width * 1.28
    let verticalStep = NotebookGeometry.height * 1.18
    let placements = notebookIDs.enumerated().map { index, id in
      let column = index % columns
      let row = index / columns
      return FreeNotebookPlacement(
        notebookID: id,
        center: WorldPoint(
          x: (Double(column) - Double(columns - 1) / 2) * horizontalStep,
          y: Double(row) * verticalStep
        ),
        zIndex: index,
        stamp: VersionStamp(counter: 0, actor: actor)
      )
    }
    return Self(
      freeNotebooks: placements,
      stamp: VersionStamp(counter: 0, actor: actor)
    )
  }

  public var notebookIDs: [UUID] {
    freeNotebooks.map(\.notebookID) + stacks.flatMap(\.notebookIDs)
  }

  public var highestZIndex: Int {
    max(
      freeNotebooks.map(\.zIndex).max() ?? 0,
      stacks.map(\.zIndex).max() ?? 0
    )
  }

  public func placement(of notebookID: UUID) -> FreeNotebookPlacement? {
    freeNotebooks.first { $0.notebookID == notebookID }
  }

  public func stack(containing notebookID: UUID) -> NotebookStack? {
    stacks.first { $0.notebookIDs.contains(notebookID) }
  }

  public func focusedCenter(of notebookID: UUID) -> WorldPoint? {
    if let placement = placement(of: notebookID) { return placement.center }
    guard let stack = stack(containing: notebookID) else { return nil }
    return NotebookStackPresentation.focusedCenter(
      of: notebookID,
      in: stack
    )
  }

  @discardableResult
  public mutating func addNotebook(
    _ notebookID: UUID,
    near center: WorldPoint,
    actor: UUID
  ) -> Bool {
    guard !notebookIDs.contains(notebookID),
      let next = stamp.advanced(by: actor)
    else { return false }
    freeNotebooks.append(
      FreeNotebookPlacement(
        notebookID: notebookID,
        center: center,
        zIndex: highestZIndex + 1,
        stamp: next
      )
    )
    stamp = next
    return true
  }

  @discardableResult
  public mutating func moveNotebook(
    _ notebookID: UUID,
    to center: WorldPoint,
    actor: UUID
  ) -> Bool {
    guard let index = freeNotebooks.firstIndex(where: {
      $0.notebookID == notebookID
    }), let next = stamp.advanced(by: actor)
    else { return false }
    guard freeNotebooks[index].move(
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
    guard movingID != targetID,
      let movingIndex = freeNotebooks.firstIndex(where: {
        $0.notebookID == movingID
      }), let next = stamp.advanced(by: actor)
    else { return nil }

    if let stackIndex = stacks.firstIndex(where: {
      $0.notebookIDs.contains(targetID)
    }) {
      guard stacks[stackIndex].append(movingID, actor: actor) else { return nil }
      freeNotebooks.remove(at: movingIndex)
      stamp = next
      return stacks[stackIndex].id
    }

    guard let targetIndex = freeNotebooks.firstIndex(where: {
      $0.notebookID == targetID
    }) else { return nil }
    let moving = freeNotebooks[movingIndex]
    let target = freeNotebooks[targetIndex]
    let indexes = [movingIndex, targetIndex].sorted(by: >)
    for index in indexes { freeNotebooks.remove(at: index) }
    stacks.append(
      NotebookStack(
        id: stackID,
        center: target.center,
        zIndex: max(moving.zIndex, target.zIndex) + 1,
        notebookIDs: [targetID, movingID],
        stamp: next
      )
    )
    stamp = next
    return stackID
  }

  @discardableResult
  public mutating func unstackNotebook(
    _ notebookID: UUID,
    at center: WorldPoint,
    actor: UUID
  ) -> Bool {
    guard let stackIndex = stacks.firstIndex(where: {
      $0.notebookIDs.contains(notebookID)
    }), let next = stamp.advanced(by: actor)
    else { return false }
    var stack = stacks[stackIndex]
    guard stack.remove(notebookID, actor: actor) else { return false }
    freeNotebooks.append(
      FreeNotebookPlacement(
        notebookID: notebookID,
        center: center,
        zIndex: highestZIndex + 1,
        stamp: next
      )
    )
    if stack.notebookIDs.count == 1, let remaining = stack.notebookIDs.first {
      freeNotebooks.append(
        FreeNotebookPlacement(
          notebookID: remaining,
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

  @discardableResult
  public mutating func upsertElement(
    _ element: SpatialElement,
    expected: VersionStamp?,
    actor: UUID
  ) -> Bool {
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
    guard !ids.isEmpty, let next = stamp.advanced(by: actor) else { return 0 }
    let before = elements.count
    elements.removeAll { ids.contains($0.id) }
    let removed = before - elements.count
    guard removed > 0 else { return 0 }
    stamp = next
    return removed
  }

  @discardableResult
  public mutating func merge(_ other: Self, notebookIDs: Set<UUID>) -> Bool {
    guard stamp < other.stamp, other.isValid(notebookIDs: notebookIDs) else {
      return false
    }
    self = other
    return true
  }

  public func isValid(notebookIDs expectedIDs: Set<UUID>) -> Bool {
    guard format == Self.formatVersion,
      stamp.counter <= VersionStamp.maximumCounter,
      freeNotebooks.allSatisfy(\.isValid),
      stacks.allSatisfy(\.isValid),
      elements.allSatisfy(\.isValid)
    else { return false }
    let ids = notebookIDs
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
}

public enum WorkspaceSemanticMode: String, Codable, Sendable {
  case board
  case cover
  case page
}

public struct SessionPresence: Codable, Equatable, Hashable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public let mode: WorkspaceSemanticMode
  public let camera: SpatialCamera
  public let viewport: SpatialPoint
  public let focusedNotebookID: UUID?
  public let openProgress: Double

  public init(
    mode: WorkspaceSemanticMode,
    camera: SpatialCamera,
    viewport: SpatialPoint,
    focusedNotebookID: UUID? = nil,
    openProgress: Double = 0
  ) {
    precondition(openProgress.isFinite && openProgress >= 0 && openProgress <= 1)
    format = Self.formatVersion
    self.mode = mode
    self.camera = camera
    self.viewport = viewport
    self.focusedNotebookID = focusedNotebookID
    self.openProgress = openProgress
  }

  public var isValid: Bool {
    format == Self.formatVersion && camera.isValid
      && viewport.isValid && viewport.x > 0 && viewport.y > 0
      && openProgress.isFinite && openProgress >= 0 && openProgress <= 1
      && (mode == .board || focusedNotebookID != nil)
  }

  public var isSettled: Bool {
    guard isValid else { return false }
    switch mode {
    case .board:
      return focusedNotebookID == nil && openProgress <= 0.001
    case .cover:
      return focusedNotebookID != nil
    case .page:
      return focusedNotebookID != nil && openProgress >= 0.999
    }
  }

  /// Projects the same camera into another viewport. A docked page has one
  /// canonical scale; every free board or cover position keeps its
  /// dimensionless zoom relative to the notebook fit.
  public func adapted(to targetViewport: SpatialPoint) -> Self {
    precondition(targetViewport.x > 0 && targetViewport.y > 0)
    let targetFit = NotebookPresentation.fitScale(viewport: targetViewport)
    let resolvedScale: Double
    if mode == .page && openProgress >= 0.999 {
      resolvedScale = targetFit
    } else {
      let sourceFit = NotebookPresentation.fitScale(viewport: viewport)
      resolvedScale = camera.scale * targetFit / sourceFit
    }
    return Self(
      mode: mode,
      camera: SpatialCamera(
        center: camera.center,
        scale: max(SpatialCamera.minimumScale, resolvedScale)
      ),
      viewport: targetViewport,
      focusedNotebookID: focusedNotebookID,
      openProgress: openProgress
    )
  }
}
