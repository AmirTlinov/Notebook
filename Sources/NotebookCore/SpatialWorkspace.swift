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

  /// Already normalized binary source: validate without recomputing local bits.
  init?(exactTileX: Int64, tileY: Int64, localX: Double, localY: Double) {
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
  func projectionOffset(x: Double,y: Double) -> Self? {
    func axis(_ tile: Int64,_ local: Double,_ delta: Double) -> (Int64,Double)? {
      let value=local+delta
      guard value.isFinite,let carry=Int64(exactly:floor(value/Self.tileSize)) else { return nil }
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
  case graphic
  case markdown
  case web
  case group
}

public struct NativeTextStyle: Codable, Equatable, Sendable {
  public let fontSize: Double
  public let weight: Double
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double
  public var format: NativeTextFormat?
  public var runs: [NativeTextRun]?

  public init(
    fontSize: Double = 34,
    weight: Double = 0.45,
    red: Double = 0.09,
    green: Double = 0.09,
    blue: Double = 0.08,
    alpha: Double = 1,
    format: NativeTextFormat? = nil, runs: [NativeTextRun]? = nil
  ) {
    precondition(fontSize.isFinite && fontSize >= 3 && fontSize <= 5760)
    precondition(weight.isFinite && weight >= 0 && weight <= 1)
    precondition([red, green, blue, alpha].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    self.fontSize = fontSize
    self.weight = weight
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
    self.format = format; self.runs = runs
  }

  public static let standard = NativeTextStyle()

  private var validRuns: Bool {
    guard let runs else { return true }
    guard runs.count <= 2048 else { return false }
    var end = 0
    for run in runs {
      guard run.location >= end, run.length > 0, run.location <= 100_000,
        run.length <= 100_000-run.location, run.format.isValid else { return false }
      end = run.location+run.length
    }
    return true
  }
  func isValid(for text: String) -> Bool {
    isValid && (runs?.last.map { $0.location+$0.length <= text.utf16.count } ?? true)
  }

  var isValid: Bool {
    (format?.isValid ?? true) && validRuns && fontSize.isFinite && fontSize >= 3 && fontSize <= 5760
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
  public private(set) var programPackage: String?
  public private(set) var state: JSONValue
  public private(set) var textStyle: NativeTextStyle
  public private(set) var graphic: NotebookGraphic?
  public let parentID: String?
  public let basis: NotebookElementBasis?
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
    programPackage: String? = nil,
    state: JSONValue = .object([:]),
    textStyle: NativeTextStyle = .standard,
    graphic: NotebookGraphic? = nil,
    parentID: String? = nil,
    basis: NotebookElementBasis? = nil,
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
    self.programPackage = programPackage
    self.state = state
    self.textStyle = textStyle
    self.graphic = graphic
    self.parentID = parentID; self.basis = basis
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
      && frame.isValid && state.isValid && textStyle.isValid(for:source)
      && NotebookProgramPackage.validSourceReference(programPackage, isProgram: kind == .web, source: source, html: html, css: css, javaScript: javaScript)
      && (kind == .graphic ? graphic?.isValid == true : graphic == nil)
      && NotebookElementBasis.validParent(parentID,childID:id)
      && (parentID == nil || worldOrigin == nil || worldOrigin == .zero)
      && (kind == .group ? basis?.isValid == true && source.isEmpty && html.isEmpty
        && css.isEmpty && javaScript.isEmpty && state == .object([:]) : (basis?.isValid ?? true))
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
    var versions = collaboration ?? .init()
    versions.materializeVersions(in:.object(["elements":.array([])]),fallback:stamp)
    for element in elements {
      // Only field clocks survive this operation. Do not simultaneously hold
      // the whole board's encoded bytes, JSON tree and flattened content map.
      let prepared=autoreleasepool {
        guard let content=try? JSONValue.encode(element) else { return false }
        versions.materializeVersions(in:.object(["elements":.array([content])]),fallback:stamp)
        return true
      }
      guard prepared else { return }
    }
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
      if key == "elements/order" { fields[key] = try fields[key].map { try $0.joining(version) } ?? version }
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
    let fields = try CollaborativeContent.merge(local: a, incoming: b, localState: collaboration,
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

  /// Projects the same camera into another viewport. Opening chooses a fitted
  /// camera; projection preserves subsequent explicit zoom, including on paper.
  public func adapted(to targetViewport: SpatialPoint, geometry: WorkspaceItemGeometry) -> Self {
    precondition(targetViewport.x > 0 && targetViewport.y > 0)
    if targetViewport == viewport { return self }
    let targetFit = geometry.fitScale(viewport: targetViewport)
    let sourceFit = geometry.fitScale(viewport: viewport)
    let resolvedScale = (camera.scale / sourceFit) * targetFit
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
