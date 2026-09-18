import Foundation

/// Native content on a physical page or board, not an embedded document.
/// Measurements remain in that owner's ink journal; presentation only names them.
public struct NotebookGraphic: Codable, Equatable, Sendable {
  public enum Shape: String, Codable, Sendable { case ellipse, rectangle, triangle, diamond, plus, connector }
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
  /// Normalized convex corners preserve the drawn polygon orientation on resize.
  public var vertices: [SpatialPoint]?
  /// Circular corner radius in physical owner points. Nil leaves sharp corners.
  public var cornerRadius: Double?

  public init(shape: Shape = .ellipse, style: Style = .init(), label: String = "",
    representation: Representation = .geometry, visible: Bool = true, sourceInkIDs: [UUID] = [],
    connection: NotebookGraphicConnection? = nil, vertices: [SpatialPoint]? = nil, cornerRadius: Double? = nil) {
    self.shape = shape; self.style = style; self.label = label
    self.representation = representation; self.visible = visible; self.sourceInkIDs = sourceInkIDs
    self.connection = connection; self.vertices = vertices; self.cornerRadius = cornerRadius
  }

  /// A native accepted edit and a delivered action interpret the same field
  /// patch. It never changes source-ink ownership or authors a second action.
  public func applying(_ patch: JSONValue) throws -> Self {
    guard !patch.object.isEmpty,
      Set(patch.object.keys).isSubset(of: Set(Self.causalFields + ["connection"]).subtracting(["sourceInkIDs"])) else {
      throw CollaborationError("invalid_operation", "Правка геометрии не меняет её исходные измерения.")
    }
    var value = try JSONValue.encode(self)
    for (part, supplied) in patch.object {
      if part == "connection", let previous = value[part] {
        guard !supplied.object.isEmpty, Set(supplied.object.keys).isSubset(of: Set(NotebookGraphicConnection.causalFields)) else {
          throw CollaborationError("invalid_operation", "Правка связи называет её концы, изгиб, наконечники или положение подписи.")
        }
        value = value.setting(part, .object(previous.object.merging(supplied.object) { _, latest in latest }))
      } else { value = value.setting(part, ["vertices", "cornerRadius"].contains(part) && supplied == .null ? nil : supplied) }
    }
    let result = try value.decode(Self.self)
    guard result.isValid else { throw CollaborationError("invalid_operation", "Недопустимая геометрия.") }
    return result
  }

  static let causalFields = ["shape", "style", "label", "representation", "visible", "sourceInkIDs", "vertices", "cornerRadius"]
  static let allCausalPaths = causalFields.map { [$0] } + NotebookGraphicConnection.causalFields.map { ["connection", $0] }
  var causalPaths: [[String]] {
    Self.causalFields.filter { ($0 != "vertices" || vertices != nil) && ($0 != "cornerRadius" || cornerRadius != nil) }.map { [$0] } + (connection == nil ? [] : NotebookGraphicConnection.causalFields.filter { ($0 != "bendPosition" || connection?.bendPosition != nil) && ($0 != "routing" || connection?.routing != nil) }.map { ["connection", $0] })
  }
  public var showsGeometry: Bool { visible && representation == .geometry }
  var isValid: Bool {
    style.isValid && label.utf16.count <= 100_000 && sourceInkIDs.count <= 16
      && Set(sourceInkIDs).count == sourceInkIDs.count
      && (representation != .ink || !sourceInkIDs.isEmpty)
      && (shape == .connector ? connection?.isValid == true : connection == nil)
      && validVertices
      && (cornerRadius == nil || (NotebookGraphicGeometry.polygon(self) != nil && cornerRadius!.isFinite && (0...1_000_000).contains(cornerRadius!)))
  }
  private var validVertices: Bool {
    guard let vertices else { return true }
    guard (shape == .triangle && vertices.count == 3) || ([.diamond, .rectangle].contains(shape) && vertices.count == 4),
      vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
    return NotebookGraphicGeometry.isConvex(vertices)
  }

}

/// The same normalized outline serves native paint, hit testing and anchors.
/// Camera / page placement belongs to the installed scene, never this geometry.
public enum NotebookGraphicGeometry {
  /// Interior picking is separate from painted-ink hit testing. A hollow node
  /// can be selected or bound inside without occluding a smaller object there.
  public static func containsInterior(_ graphic: NotebookGraphic, width: Double, height: Double,
    x: Double, y: Double) -> Bool {
    guard graphic.showsGeometry, width > 0, height > 0 else { return false }
    if graphic.shape == .ellipse { return hypot((x-width/2)/(width/2),(y-height/2)/(height/2)) <= 1 }
    guard let vertices = outlinePolygon(graphic, width: width, height: height) else { return false }
    var inside = false
    for (a,b) in zip(vertices,vertices.dropFirst()+vertices.prefix(1)) where (a.y*height > y) != (b.y*height > y) {
      if x < (b.x-a.x)*width*(y-a.y*height)/((b.y-a.y)*height)+a.x*width { inside.toggle() }
    }
    return inside
  }
  public static func polygon(_ graphic: NotebookGraphic) -> [SpatialPoint]? {
    switch graphic.shape {
    case .triangle: return graphic.vertices ?? [.init(x:0.5,y:0),.init(x:1,y:1),.init(x:0,y:1)]
    case .diamond: return graphic.vertices ?? [.init(x:0.5,y:0),.init(x:1,y:0.5),.init(x:0.5,y:1),.init(x:0,y:0.5)]
    case .rectangle: return graphic.vertices ?? [.init(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]
    case .ellipse, .plus, .connector: return nil
    }
  }
  public static func hitTest(_ graphic: NotebookGraphic, width: Double, height: Double,
    x: Double, y: Double, tolerance: Double) -> Bool {
    guard graphic.showsGeometry, graphic.shape != .connector, width > 0, height > 0 else { return false }
    let dx = (x - width / 2) / (width / 2), dy = (y - height / 2) / (height / 2)
    let radius = hypot(dx, dy)
    if !graphic.label.isEmpty, abs(x - width / 2) <= min(width / 2, Double(graphic.label.count) * 8 + tolerance),
      abs(y - height / 2) <= 16 + tolerance { return true }
    if graphic.style.fill != nil {
      if graphic.shape == .ellipse { return radius <= 1 + tolerance / min(width, height) * 2 }
      if containsInterior(graphic,width:width,height:height,x:x,y:y) { return true }
    }
    // A contour must not steal its empty interior from enclosed nodes.
    return outlineDistance(graphic,width:width,height:height,x:x,y:y) <= tolerance + graphic.style.strokeWidth / 2
  }

  public static func outlineDistance(_ graphic: NotebookGraphic, width: Double, height: Double,
    x: Double, y: Double) -> Double {
    func segment(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
      let dx = bx-ax, dy = by-ay, square = dx*dx+dy*dy
      let t = square > 0 ? min(1,max(0,((x-ax)*dx+(y-ay)*dy)/square)) : 0
      return hypot(x-ax-t*dx,y-ay-t*dy)
    }
    switch graphic.shape {
    case .ellipse:
      return abs(hypot((x-width/2)/(width/2),(y-height/2)/(height/2))-1)*min(width,height)/2
    case .rectangle, .triangle, .diamond:
      let vertices = outlinePolygon(graphic, width: width, height: height)!
      return zip(vertices,vertices.dropFirst()+vertices.prefix(1)).map {
        segment($0.x*width,$0.y*height,$1.x*width,$1.y*height)
      }.min()!
    case .plus:
      return min(segment(0,height/2,width,height/2),segment(width/2,0,width/2,height))
    case .connector: return .infinity
    }
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
