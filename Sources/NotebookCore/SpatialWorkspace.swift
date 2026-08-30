import Foundation

public enum NotebookGeometry {
  public static let width = 834.0
  public static let height = 1_194.0
  public static let cornerRadius = 34.0
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
  public static let minimumScale = 0.055
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

/// Decides when a board pinch becomes an instruction to open one notebook.
/// Until this policy sees deliberate evidence, the board camera remains the
/// semantic owner of the same fingers.
public enum NotebookOpeningIntent {
  public enum Engagement: Equatable, Sendable {
    case deliberate
    case sharp
  }

  /// A 50% spread is large enough to be an intentional second-stage action,
  /// while a short inspection pinch remains ordinary board zoom.
  public static let deliberateMagnification = 1.5
  /// Scale units per second measured over the recognizer's recent 80 ms.
  public static let sharpVelocity = 2.4
  /// Velocity alone is noisy during the first hardware samples. A sharp pinch
  /// must also create a visible 28% spread before it can acquire a notebook.
  public static let sharpMinimumMagnification = 1.28
  /// One raw touch sample cannot own a semantic transition. This interval is
  /// the same size as the recognizer's velocity window.
  public static let minimumEvidenceDuration = 0.08
  /// Once engaged, another 50% spread reveals the complete page.
  public static let openingMagnificationRatio = 1.5
  public static let selectionHalo = 1.12

  public static func engagement(
    magnification: Double,
    velocity: Double,
    elapsed: TimeInterval
  ) -> Engagement? {
    guard magnification.isFinite, magnification >= 1,
      velocity.isFinite, elapsed.isFinite,
      elapsed >= minimumEvidenceDuration
    else { return nil }
    if magnification >= sharpMinimumMagnification,
      velocity >= sharpVelocity
    {
      return .sharp
    }
    if magnification >= deliberateMagnification { return .deliberate }
    return nil
  }

  /// Opening begins at zero on the exact frame that acquires the notebook.
  /// Continuing or reversing the same pinch then changes this value
  /// continuously, even if the board camera has reached its own zoom limit.
  public static func progress(
    magnification: Double,
    engagedAt engagementMagnification: Double
  ) -> Double {
    NotebookOpeningTransition.progress(
      cameraScale: magnification,
      coverScale: engagementMagnification,
      pageScale: engagementMagnification * openingMagnificationRatio
    )
  }

  public static func shouldDisengage(
    magnification: Double,
    engagedAt engagementMagnification: Double
  ) -> Bool {
    magnification < engagementMagnification * 0.9
  }

  /// Every completed gesture lands on one whole semantic state. A sharp
  /// outward motion commits to the page; a barely crossed deliberate threshold
  /// may rest on the closed cover; reversing the motion returns to the board.
  public static func releaseMode(
    progress: Double,
    magnification: Double,
    engagedAt engagementMagnification: Double,
    engagement: Engagement,
    velocity: Double
  ) -> WorkspaceSemanticMode {
    guard progress.isFinite, magnification.isFinite,
      engagementMagnification.isFinite, engagementMagnification > 0,
      velocity.isFinite
    else { return .board }
    let retainedEngagement = magnification >= engagementMagnification * 0.96
    if !retainedEngagement && progress < 0.08 { return .board }
    if progress >= 0.42 || velocity >= 0.9
      || (engagement == .sharp && retainedEngagement)
    {
      return .page
    }
    return .cover
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
    precondition(notebookIDs.count >= 2)
    self.id = id
    self.center = center
    self.zIndex = zIndex
    self.notebookIDs = notebookIDs
    self.stamp = stamp
  }

  mutating func append(_ notebookID: UUID, actor: UUID) -> Bool {
    guard !notebookIDs.contains(notebookID),
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
      && Set(notebookIDs).count == notebookIDs.count
      && stamp.counter <= VersionStamp.maximumCounter
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
  public let focusedStackID: UUID?
  public let openProgress: Double

  public init(
    mode: WorkspaceSemanticMode,
    camera: SpatialCamera,
    viewport: SpatialPoint,
    focusedNotebookID: UUID? = nil,
    focusedStackID: UUID? = nil,
    openProgress: Double = 0
  ) {
    precondition(openProgress.isFinite && openProgress >= 0 && openProgress <= 1)
    format = Self.formatVersion
    self.mode = mode
    self.camera = camera
    self.viewport = viewport
    self.focusedNotebookID = focusedNotebookID
    self.focusedStackID = focusedStackID
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
      return focusedNotebookID != nil && openProgress <= 0.001
    case .page:
      return focusedNotebookID != nil && openProgress >= 0.999
    }
  }

  /// Projects the same semantic scene into another viewport. Stable cover and
  /// page states have one canonical scale; transitional and board states keep
  /// their dimensionless zoom relative to the notebook fit.
  public func adapted(to targetViewport: SpatialPoint) -> Self {
    precondition(targetViewport.x > 0 && targetViewport.y > 0)
    let targetFit = NotebookPresentation.fitScale(viewport: targetViewport)
    let resolvedScale: Double
    if mode == .page && openProgress >= 0.999 {
      resolvedScale = targetFit
    } else if mode == .cover && openProgress <= 0.001 {
      resolvedScale = targetFit * NotebookPresentation.coverScaleRatio
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
      focusedStackID: focusedStackID,
      openProgress: openProgress
    )
  }
}
