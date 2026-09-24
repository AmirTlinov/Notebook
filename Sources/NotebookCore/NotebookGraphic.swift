import Foundation
import CoreGraphics

/// Native content on a physical page or board, not an embedded document.
/// Measurements remain in that owner's ink journal; presentation only names them.
public struct NotebookGraphic: Codable, Equatable, Sendable {
  public enum Shape: String, Codable, Sendable { case ellipse, rectangle, triangle, diamond, plus, connector, freehand, path }
  public enum Representation: String, Codable, Sendable { case ink, geometry }
  public struct Style: Codable, Equatable, Sendable {
    public enum Dash: String, Codable, CaseIterable, Sendable { case solid, dashed, dotted, dashDot }
    public var dashPattern: [CGFloat] {
      switch dash ?? .solid {
      case .solid: []
      case .dashed: [strokeWidth*4,strokeWidth*3]
      case .dotted: [0,strokeWidth*3]
      case .dashDot: [strokeWidth*4,strokeWidth*3,0,strokeWidth*3]
      }
    }
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
  public var freehand: NotebookFreehand?
  public var path: NotebookVectorPath?
  public var transform: NotebookGraphicTransform?
  /// Ordered vector set operations in the element's normalized basis.
  public var mask: NotebookGraphicMask?

  public init(shape: Shape = .ellipse, style: Style = .init(), label: String = "",
    representation: Representation = .geometry, visible: Bool = true, sourceInkIDs: [UUID] = [],
    connection: NotebookGraphicConnection? = nil, vertices: [SpatialPoint]? = nil, cornerRadius: Double? = nil, freehand: NotebookFreehand? = nil, transform: NotebookGraphicTransform? = nil, path: NotebookVectorPath? = nil,
    mask: NotebookGraphicMask? = nil) {
    self.shape = shape; self.style = style; self.label = label
    self.representation = representation; self.visible = visible; self.sourceInkIDs = sourceInkIDs
    self.connection = connection; self.vertices = vertices; self.cornerRadius = cornerRadius; self.freehand = freehand; self.transform = transform; self.path = path; self.mask = mask
  }

  /// A native accepted edit and a delivered action interpret the same field
  /// patch. It never changes source-ink ownership or authors a second action.
  public func applying(_ patch: JSONValue) throws -> Self {
    guard !patch.object.isEmpty,
      Set(patch.object.keys).isSubset(of: Set(Self.causalFields + ["connection"]).subtracting(["sourceInkIDs"])) else {
      throw CollaborationError("invalid_operation", "Правка геометрии не меняет её исходные измерения.")
    }
    var result = self
    for (part, supplied) in patch.object {
      // A pose/style edit touches only that field. Serializing the complete
      // graphic here used to revisit every retained vector vertex per edit.
      switch part {
      case "shape": result.shape = try supplied.decode(Shape.self)
      case "style": result.style = try supplied.decode(Style.self)
      case "label": result.label = try supplied.decode(String.self)
      case "representation": result.representation = try supplied.decode(Representation.self)
      case "visible": result.visible = try supplied.decode(Bool.self)
      case "vertices": result.vertices = supplied == .null ? nil : try supplied.decode([SpatialPoint].self)
      case "cornerRadius": result.cornerRadius = supplied == .null ? nil : try supplied.decode(Double.self)
      case "freehand": result.freehand = supplied == .null ? nil : try supplied.decode(NotebookFreehand.self)
      case "transform": result.transform = supplied == .null ? nil : try supplied.decode(NotebookGraphicTransform.self)
      case "path": result.path = supplied == .null ? nil : try supplied.decode(NotebookVectorPath.self)
      case "mask": result.mask = supplied == .null ? nil : try supplied.decode(NotebookGraphicMask.self)
      case "connection":
        if let previous = connection {
          guard !supplied.object.isEmpty, Set(supplied.object.keys).isSubset(of: Set(NotebookGraphicConnection.causalFields)) else {
            throw CollaborationError("invalid_operation", "Правка связи называет её концы, изгиб, наконечники или положение подписи.")
          }
          let old = try JSONValue.encode(previous)
          result.connection = try JSONValue.object(old.object.merging(supplied.object) { _, latest in latest }).decode(NotebookGraphicConnection.self)
        } else { result.connection = supplied == .null ? nil : try supplied.decode(NotebookGraphicConnection.self) }
      default: preconditionFailure("Validated graphic field")
      }
    }
    guard result.isValid else { throw CollaborationError("invalid_operation", "Недопустимая геометрия.") }
    return result
  }

  static let causalFields = ["shape", "style", "label", "representation", "visible", "sourceInkIDs", "vertices", "cornerRadius", "freehand", "transform", "path", "mask"]
  static let allCausalPaths = causalFields.map { [$0] } + NotebookGraphicConnection.causalFields.map { ["connection", $0] }
  var causalPaths: [[String]] {
    Self.causalFields.filter { ($0 != "vertices" || vertices != nil) && ($0 != "cornerRadius" || cornerRadius != nil) && ($0 != "freehand" || freehand != nil) && ($0 != "transform" || transform != nil) && ($0 != "path" || path != nil) && ($0 != "mask" || mask != nil) }.map { [$0] } + (connection == nil ? [] : NotebookGraphicConnection.causalFields.filter { ($0 != "bendPosition" || connection?.bendPosition != nil) && ($0 != "routing" || connection?.routing != nil) && ($0 != "elbowAxis" || connection?.elbowAxis != nil) }.map { ["connection", $0] })
  }
  public var showsGeometry: Bool { visible && representation == .geometry }
  var isValid: Bool {
    style.isValid && label.utf16.count <= 100_000 && sourceInkIDs.count <= (shape == .freehand ? 1024 : 16)
      && Set(sourceInkIDs).count == sourceInkIDs.count
      && (representation != .ink || !sourceInkIDs.isEmpty)
      && (shape == .connector ? connection?.isValid == true : connection == nil)
      && (shape == .freehand ? freehand?.isValid == true : freehand == nil)
      && (shape == .path ? path?.isValid == true : path == nil)
      && (transform?.isValid ?? true) && (shape != .connector || transform == nil)
      && (mask?.isValid ?? true)
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

/// Compact exact visibility relation. Repeated lasso edits append operations;
/// they do not expand immutable measurements into triangles or pixels.
public struct NotebookGraphicMask: Codable, Equatable, Sendable {
  public struct Operation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case intersect, subtract }
    public let kind: Kind
    public let polygon: [SpatialPoint]
    /// A detached fragment freezes the visible revision, sharing the immutable
    /// measured bodies. It must not look up cuts addressed to its former ID.
    public let erasures: [InkElementErasure]?
    public let transform: NotebookGraphicTransform?
    public init(_ kind:Kind,polygon:[SpatialPoint]) {
      self.kind=kind;self.polygon=polygon;erasures=nil;transform=nil
    }
    public init(erasures:[InkElementErasure],transform:NotebookGraphicTransform?) {
      kind = .subtract;polygon=[];self.erasures=erasures;self.transform=transform
    }
  }
  public let operations:[Operation]
  private let preparation = Preparation()
  // A full export must never hold the lock used by live region queries.
  private let regionPreparation = Preparation()
  private enum CodingKeys:String,CodingKey { case operations }
  public static func == (lhs:Self,rhs:Self)->Bool {
    lhs.preparation === rhs.preparation || lhs.operations == rhs.operations
  }
  /// Derived coverage belongs to the immutable local mask, not its screen pose.
  /// Keep the normalized query and one body-size path; zoom cannot grow a cache.
  private final class Preparation: @unchecked Sendable {
    private let lock=NSLock()
    private var unit:CGPath?
    private var body:(CGSize,CGPath)?
    private var builds=0
    var buildCount:Int { lock.withLock { builds } }
    func retainReady(from previous:Preparation)->Bool {
      if self === previous { return true }
      // Publication may borrow completed derivatives, never wait behind a
      // worker's Boolean build. No source or unfinished result is transferred.
      guard previous.lock.try() else { return false }
      let readyUnit=previous.unit,readyBody=previous.body
      previous.lock.unlock()
      guard readyUnit != nil || readyBody != nil,lock.try() else { return false }
      defer { lock.unlock() }
      if unit == nil { unit=readyUnit }
      if body == nil { body=readyBody }
      return true
    }
    func path(size:CGSize,build:()->CGPath)->CGPath {
      lock.withLock {
        let normalized=size == CGSize(width:1,height:1)
        if normalized,let unit { return unit }
        if !normalized,let body,body.0 == size { return body.1 }
        let path=build();builds += 1
        // Erasure preparation cooperates with worker cancellation. A partial
        // result may leave that worker, but never becomes retained visibility.
        if !Task.isCancelled {
          if normalized { unit=path } else { body=(size,path) }
        }
        return path
      }
    }
  }
  var completePathBuildCount:Int { preparation.buildCount }
  public init(operations:[Operation]=[]) { self.operations=operations }
  /// A decoded publication of the same immutable mask keeps its already
  /// prepared coverage. This changes no authored field, pose, clock or limit.
  @discardableResult public func retainPreparedPaths(from previous:Self)->Bool {
    guard self == previous else { return false }
    let complete=preparation.retainReady(from:previous.preparation)
    let region=regionPreparation.retainReady(from:previous.regionPreparation)
    return complete || region
  }
  public var isValid:Bool {
    !operations.isEmpty && operations.count <= 64 && operations.allSatisfy {
      operation in
      if let cuts=operation.erasures {
        return operation.kind == .subtract && operation.polygon.isEmpty
          && !cuts.isEmpty && cuts.count <= 2048 && (operation.transform?.isValid ?? true)
          && cuts.allSatisfy { $0.target.isValid && !$0.samples.isEmpty && $0.samples.count <= 1_000_000 }
      }
      return operation.transform == nil && operation.polygon.count >= 3 && operation.polygon.count <= 2048
        && operation.polygon.allSatisfy {
          $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000
        }
    }
  }
  public func appending(_ kind:Operation.Kind,polygon:[SpatialPoint])->Self {
    .init(operations:operations + [.init(kind,polygon:polygon)])
  }
  public func capturing(_ erasures:[InkElementErasure],transform:NotebookGraphicTransform?)->Self {
    erasures.isEmpty ? self : .init(operations:operations + [.init(erasures:erasures,transform:transform)])
  }
  public func path(in rect:CGRect)->CGPath {
    guard rect.width > 0,rect.height > 0 else { return CGMutablePath() }
    let path=preparation.path(size:rect.size) { buildPath(in:.init(origin:.zero,size:rect.size)) }
    guard rect.origin != .zero else { return path }
    var offset=CGAffineTransform(translationX:rect.minX,y:rect.minY)
    return path.copy(using:&offset)!
  }
  private func buildPath(in rect:CGRect)->CGPath {
    var result:CGPath=CGPath(rect:rect,transform:nil)
    for operation in operations {
      if let cuts=operation.erasures {
        var offset=CGAffineTransform(translationX:rect.minX,y:rect.minY)
        let cut=NotebookElementAppearance.erasurePath(cuts,size:rect.size,transform:operation.transform)
          .copy(using:&offset)!
        result=result.subtracting(cut)
        if result.isEmpty { break }
        continue
      }
      let path=CGMutablePath()
      if let first=operation.polygon.first {
        path.move(to:.init(x:rect.minX+first.x*rect.width,y:rect.minY+first.y*rect.height))
        for p in operation.polygon.dropFirst() {
          path.addLine(to:.init(x:rect.minX+p.x*rect.width,y:rect.minY+p.y*rect.height))
        }
        path.closeSubpath()
      }
      result = operation.kind == .intersect ? result.intersection(path,using:.evenOdd) : result.subtracting(path,using:.evenOdd)
      if result.isEmpty { break }
    }
    return result
  }
  /// The live Metal child is mounted in the displayed outer frame. Project
  /// the authored local mask through that same placement instead of clipping
  /// it as if a rotated/grouped body still occupied its unplaced rectangle.
  public func projectedPath(in rect:CGRect,projection:NotebookGraphicLayout.Projection?)->CGPath {
    guard let projection else { return path(in:rect) }
    var transform=projection.transform
    return path(in:.init(origin:.zero,size:projection.size)).copy(using:&transform) ?? CGMutablePath()
  }
  /// Cheap safe bound for source disclosure. Intersections may narrow the
  /// queried body; subtraction never may. Exact clipping remains `path`.
  public func conservativeBounds(in rect:CGRect,projection:NotebookGraphicLayout.Projection?)->CGRect {
    guard rect.width > 0,rect.height > 0 else { return .null }
    var unit=CGRect(x:0,y:0,width:1,height:1)
    for operation in operations where operation.kind == .intersect {
      let polygon=operation.polygon.reduce(CGRect.null) { box,p in
        box.union(.init(x:p.x,y:p.y,width:0,height:0))
      }
      unit=unit.intersection(polygon)
      if unit.isNull || unit.isEmpty { return .null }
    }
    let sourceSize=projection?.size ?? rect.size
    var bounds=CGRect(x:unit.minX*sourceSize.width,y:unit.minY*sourceSize.height,
      width:unit.width*sourceSize.width,height:unit.height*sourceSize.height)
    if let projection { bounds=bounds.applying(projection.transform) }
    else { bounds.origin.x += rect.minX;bounds.origin.y += rect.minY }
    return bounds.intersection(rect)
  }
  /// The addressed region and its measured absence are operands of the same
  /// visibility relation. Live paint clips this small polygonal region and
  /// executes the measured operands directly, without a full Boolean contour.
  public func regionPath(in rect:CGRect)->CGPath {
    guard rect.width > 0,rect.height > 0 else { return CGMutablePath() }
    let path=regionPreparation.path(size:rect.size) {
      var result:CGPath=CGPath(rect:.init(origin:.zero,size:rect.size),transform:nil)
      for operation in operations where operation.erasures == nil {
        let polygon=CGMutablePath()
        polygon.addLines(between:operation.polygon.map { .init(x:$0.x*rect.width,y:$0.y*rect.height) })
        polygon.closeSubpath()
        result=operation.kind == .intersect ? result.intersection(polygon,using:.evenOdd) : result.subtracting(polygon,using:.evenOdd)
        if result.isEmpty { break }
      }
      return result
    }
    guard rect.origin != .zero else { return path }
    var offset=CGAffineTransform(translationX:rect.minX,y:rect.minY)
    return path.copy(using:&offset)!
  }
  public func projectedRegionPath(in rect:CGRect,projection:NotebookGraphicLayout.Projection?)->CGPath {
    guard let projection else { return regionPath(in:rect) }
    var transform=projection.transform
    return regionPath(in:.init(origin:.zero,size:projection.size)).copy(using:&transform)!
  }
  public var erasesWholeRegion:Bool {
    operations.contains { $0.erasures?.contains { $0.target.wholeElement } == true }
  }
  private var measuredCuts:[NotebookFreehandGeometry.Cut] {
    operations.flatMap { operation in
      (operation.erasures ?? []).map { NotebookFreehandGeometry.Cut($0,transform:operation.transform) }
    }
  }
  public func contains(_ point:SpatialPoint)->Bool {
    let p=CGPoint(x:point.x,y:point.y)
    return !erasesWholeRegion && regionPath(in:.init(x:0,y:0,width:1,height:1)).contains(p,using:.evenOdd)
      && !measuredCuts.contains { $0.contains(p) }
  }
  /// Exact local paint witness. Positive interior witnesses stop immediately;
  /// absence is proved by the same indexed measured triangles, not sampling.
  func intersects(_ query:CGPath,in size:CGSize)->Bool {
    guard !erasesWholeRegion else { return false }
    var remaining=regionPath(in:.init(origin:.zero,size:size)).intersection(query,using:.evenOdd)
    guard !remaining.isEmpty else { return false }
    let cuts=measuredCuts
    guard !cuts.isEmpty else { return true }
    let box=remaining.boundingBoxOfPath
    for x in [0.25,0.5,0.75] {
      for y in [0.25,0.5,0.75] {
        let p=CGPoint(x:box.minX+box.width*x,y:box.minY+box.height*y)
        if remaining.contains(p,using:.evenOdd),
          !cuts.contains(where:{ $0.contains(.init(x:p.x/size.width,y:p.y/size.height)) }) { return true }
      }
    }
    // A hollow contour usually has no paint at the nine interior witnesses.
    // Material outside every cut's conservative bound is nevertheless intact:
    // prove that before expanding thousands of overlapping measured triangles.
    // Bounds are only a positive witness, never an approximation of erasure.
    var untouched = remaining
    for cut in cuts {
      let unit = cut.conservativeBounds
      let bounds = CGRect(x: unit.minX*size.width, y: unit.minY*size.height,
        width: unit.width*size.width, height: unit.height*size.height)
      untouched = untouched.subtracting(CGPath(rect: bounds, transform: nil))
      if untouched.isEmpty { break }
    }
    if !untouched.isEmpty { return true }
    for cut in cuts {
      let box=remaining.boundingBoxOfPath
      let area=CGRect(x:box.minX/size.width,y:box.minY/size.height,width:box.width/size.width,height:box.height/size.height)
      var batch=CGMutablePath(),last:[CGPoint]=[],count=0
      func flush() {
        guard count > 0 else { return }
        remaining=remaining.subtracting(batch.normalized());batch=CGMutablePath();count=0
        // Share actual coverage across independently quantized Boolean batches.
        batch.addLines(between:last);batch.closeSubpath()
      }
      _=cut.triangles(in:area) { triangle in
        let a=CGPoint(x:triangle[0].x*size.width,y:triangle[0].y*size.height)
        let b=CGPoint(x:triangle[1].x*size.width,y:triangle[1].y*size.height)
        let c=CGPoint(x:triangle[2].x*size.width,y:triangle[2].y*size.height)
        last=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) >= 0 ? [a,b,c] : [a,c,b]
        batch.addLines(between:last);batch.closeSubpath();count += 1
        if count == 128 { flush() }
        return remaining.isEmpty || Task.isCancelled
      }
      flush()
      if remaining.isEmpty || Task.isCancelled { return false }
    }
    return true
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
    if graphic.mask?.contains(.init(x:x/width,y:y/height)) == false { return false }
    if graphic.shape == .freehand { return graphic.freehand?.contains(.init(x:x,y:y),size:.init(width:width,height:height),transform:graphic.transform) ?? false }
    if let transform = graphic.transform {
      var base = graphic; base.transform = nil
      let p = transform.unapplying(.init(x:x/width,y:y/height))
      let size = transform.contentSize(in:.init(width:width,height:height))
      return containsInterior(base,width:size.width,height:size.height,x:p.x*size.width,y:p.y*size.height)
    }
    if graphic.shape == .path { return graphic.path?.path(in:.init(x:0,y:0,width:width,height:height)).contains(.init(x:x,y:y)) ?? false }
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
    case .ellipse, .plus, .connector, .freehand, .path: return nil
    }
  }
  public static func hitTest(_ graphic: NotebookGraphic, width: Double, height: Double,
    x: Double, y: Double, tolerance: Double) -> Bool {
    guard graphic.showsGeometry, graphic.shape != .connector, width > 0, height > 0 else { return false }
    if graphic.mask != nil {
      return NotebookElementAppearance(graphic:graphic,layout:nil,size:.init(width:width,height:height),erasures:[])
        .contains(.init(x:x,y:y),tolerance:tolerance)
    }
    if let ink = graphic.freehand {
      return ink.contains(.init(x:x,y:y),size:.init(width:width,height:height),transform:graphic.transform,tolerance:tolerance)
    }
    if graphic.transform != nil || graphic.shape == .path {
      let path = paintPath(graphic,layout:nil,size:.init(width:width,height:height))
      let p = CGPoint(x:x,y:y)
      return path.contains(p) || (tolerance > 0 && path.copy(strokingWithWidth:tolerance*2,lineCap:.round,lineJoin:.round,miterLimit:10).contains(p))
    }
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
    if graphic.transform != nil, let vertices = outlinePolygon(graphic,width:width,height:height) {
      return zip(vertices,vertices.dropFirst()+vertices.prefix(1)).map { segment($0.x*width,$0.y*height,$1.x*width,$1.y*height) }.min() ?? .infinity
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
    case .connector, .freehand, .path: return .infinity
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
  /// An optimistic local command is already the visible causal successor even
  /// though its durable field version is not available until the writer
  /// completes. Only the affected claim component uses this priority.
  public struct PrioritizedCandidate: Sendable {
    public let id: String
    public let graphic: NotebookGraphic
    public init(id: String, graphic: NotebookGraphic) {
      self.id = id; self.graphic = graphic
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
    self.init(ordered.map { ($0.id,$0.graphic) })
  }
  public init(prioritizing candidates: [PrioritizedCandidate], then durable: [Candidate]) {
    let local = candidates.sorted { collaborationIdentity($0.id) > collaborationIdentity($1.id) }
    let changed = Set(local.map { collaborationIdentity($0.id) })
    let ordered = durable.filter { !changed.contains(collaborationIdentity($0.id)) }.sorted { a, b in
      if a.version.human != b.version.human { return a.version.human }
      if a.version.stamp != b.version.stamp { return a.version.stamp > b.version.stamp }
      return a.id > b.id
    }
    self.init(local.map { ($0.id,$0.graphic) } + ordered.map { ($0.id,$0.graphic) })
  }
  private init(_ ordered: [(String,NotebookGraphic)]) {
    var claimed = Set<UUID>(), geometry = Set<String>(), suppressed = Set<UUID>()
    for (id,graphic) in ordered {
      let sources = Set(graphic.sourceInkIDs)
      if graphic.visible && graphic.representation == .ink { continue }
      guard claimed.isDisjoint(with: sources) else { continue }
      claimed.formUnion(sources)
      if !graphic.visible || graphic.representation == .geometry { suppressed.formUnion(sources) }
      if graphic.showsGeometry { geometry.insert(id) }
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
  public var graphicPresentation: NotebookGraphicPresentation { elementProjection.presentation }
}

extension BoardDocument {
  public var graphicPresentationCandidates: [NotebookGraphicPresentation.Candidate] {
    elements.compactMap { element in
      guard let graphic = element.graphic else { return nil }
      return .init(id: element.id, graphic: graphic,
        version: collaboration?.fields[fieldKey(["elements", collaborationIdentity(element.id), "graphic", "sourceInkIDs"])]
          ?? .init(stamp: element.stamp, human: true))
    }
  }
  public var graphicPresentation: NotebookGraphicPresentation {
    .init(graphicPresentationCandidates)
  }
}
