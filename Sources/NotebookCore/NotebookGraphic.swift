import Foundation

/// Native content on a physical page or board, not an embedded document.
/// Measurements remain in that owner's ink journal; presentation only names them.
public struct NotebookGraphic: Codable, Equatable, Sendable {
  public enum Shape: String, Codable, Sendable { case ellipse, connector }
  public enum Representation: String, Codable, Sendable { case ink, geometry }
  public struct Style: Codable, Equatable, Sendable {
    public enum Dash: String, Codable, Sendable { case solid, dashed, dotted }
    public var stroke: SpatialInkColor
    public var strokeWidth: Double
    public var fill: SpatialInkColor?
    public var dash: Dash?
    public init(stroke: SpatialInkColor = .black, strokeWidth: Double = 2, fill: SpatialInkColor? = nil, dash: Dash? = nil) {
      self.stroke = stroke; self.strokeWidth = strokeWidth; self.fill = fill; self.dash = dash
    }
    var isValid: Bool {
      stroke.isValid && (fill?.isValid ?? true)
        && strokeWidth.isFinite && strokeWidth > 0 && strokeWidth <= 1_000_000
    }
  }
  public var shape: Shape
  public var style: Style
  public var label: String
  public var representation: Representation
  public var visible: Bool
  public let sourceInkIDs: [UUID]
  public var connection: NotebookGraphicConnection?

  public init(shape: Shape = .ellipse, style: Style = .init(), label: String = "",
    representation: Representation = .geometry, visible: Bool = true, sourceInkIDs: [UUID] = [],
    connection: NotebookGraphicConnection? = nil) {
    self.shape = shape; self.style = style; self.label = label
    self.representation = representation; self.visible = visible; self.sourceInkIDs = sourceInkIDs
    self.connection = connection
  }

  static let causalFields = ["shape", "style", "label", "representation", "visible", "sourceInkIDs"]
  static let allCausalPaths = causalFields.map { [$0] } + NotebookGraphicConnection.causalFields.map { ["connection", $0] }
  var causalPaths: [[String]] {
    Self.causalFields.map { [$0] } + (connection == nil ? [] : NotebookGraphicConnection.causalFields.map { ["connection", $0] })
  }
  public var showsGeometry: Bool { visible && representation == .geometry }
  var isValid: Bool {
    style.isValid && label.utf16.count <= 100_000 && sourceInkIDs.count <= 16
      && Set(sourceInkIDs).count == sourceInkIDs.count
      && (representation != .ink || !sourceInkIDs.isEmpty)
      && (shape == .connector ? connection?.isValid == true : connection == nil)
  }
}

/// The same normalized outline serves native paint, hit testing and anchors.
/// Camera / page placement belongs to the installed scene, never this geometry.
public enum NotebookGraphicGeometry {
  public static func hitTest(_ graphic: NotebookGraphic, width: Double, height: Double,
    x: Double, y: Double, tolerance: Double) -> Bool {
    guard graphic.showsGeometry, graphic.shape == .ellipse, width > 0, height > 0 else { return false }
    let dx = (x - width / 2) / (width / 2), dy = (y - height / 2) / (height / 2)
    let radius = hypot(dx, dy)
    if !graphic.label.isEmpty, abs(x - width / 2) <= min(width / 2, Double(graphic.label.count) * 8 + tolerance),
      abs(y - height / 2) <= 16 + tolerance { return true }
    if graphic.style.fill != nil { return radius <= 1 + tolerance / min(width, height) * 2 }
    // A contour must not steal its empty interior from enclosed nodes.
    return abs(radius - 1) * min(width, height) / 2 <= tolerance + graphic.style.strokeWidth / 2
  }
}

/// Whole-candidate arbitration: a shared stroke can never be half-converted or
/// appear through two shapes. Hidden winners still suppress their measurements.
public struct NotebookGraphicPresentation: Equatable, Sendable {
  public struct Candidate: Sendable {
    public let id: String
    public let graphic: NotebookGraphic
    public let version: ContentFieldVersion
    public init(id: String, graphic: NotebookGraphic, version: ContentFieldVersion) {
      self.id = id; self.graphic = graphic; self.version = version
    }
  }
  public let geometryIDs: Set<String>
  public let suppressedInkIDs: Set<UUID>
  public init(_ candidates: [Candidate]) {
    let ordered = candidates.sorted { a, b in
      if a.version.human != b.version.human { return a.version.human }
      if a.version.stamp != b.version.stamp { return a.version.stamp > b.version.stamp }
      return a.id > b.id
    }
    var claimed = Set<UUID>(), geometry = Set<String>(), suppressed = Set<UUID>()
    for candidate in ordered {
      let graphic = candidate.graphic, sources = Set(graphic.sourceInkIDs)
      if graphic.visible && graphic.representation == .ink { continue }
      guard claimed.isDisjoint(with: sources) else { continue }
      claimed.formUnion(sources)
      if !graphic.visible || graphic.representation == .geometry { suppressed.formUnion(sources) }
      if graphic.showsGeometry { geometry.insert(candidate.id) }
    }
    geometryIDs = geometry; suppressedInkIDs = suppressed
  }
}

extension PageInkDrawing {
  /// A render value only. It never goes through save/merge or changes isActive.
  public func presenting(excluding ids: Set<UUID>) -> Self {
    guard !ids.isEmpty else { return self }
    return .init(baselinePNG: baselinePNG, baselineActionCount: baselineActionCount,
      actions: actions.filter { !ids.contains($0.id) })
  }
}

extension SpatialInkJournal {
  public func presenting(excluding ids: Set<UUID>) -> Self {
    guard !ids.isEmpty else { return self }
    return .init(actions: actions.filter { !ids.contains($0.id) }, stamp: stamp)
  }
}

extension PageDocument {
  public var graphicPresentation: NotebookGraphicPresentation {
    .init(elements.compactMap { element in
      guard let graphic = element.graphic else { return nil }
      return .init(id: element.id, graphic: graphic,
        version: collaboration?.fields[fieldKey(["elements", collaborationIdentity(element.id), "graphic", "sourceInkIDs"])]
          ?? .init(stamp: agentStamp, human: true))
    })
  }
}

extension BoardDocument {
  public var graphicPresentation: NotebookGraphicPresentation {
    .init(elements.compactMap { element in
      guard let graphic = element.graphic else { return nil }
      return .init(id: element.id, graphic: graphic,
        version: collaboration?.fields[fieldKey(["elements", collaborationIdentity(element.id), "graphic", "sourceInkIDs"])]
          ?? .init(stamp: element.stamp, human: true))
    })
  }
}
