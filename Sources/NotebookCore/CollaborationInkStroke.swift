import Foundation

/// One agent stroke becomes the same measured samples as a completed Pencil
/// contact. Coordinates belong to the physical owner, never the human camera.
struct CollaborationInkStroke {
  static let maximumPoints = 8192
  let id: UUID
  let color: SpatialInkColor
  let samples: [SpatialInkSample]
  let region: PageRect
  let worldOrigin: WorldPoint?

  init(_ operation: CollaborationOperation) throws {
    func invalid() -> CollaborationError {
      .init("invalid_operation", "Штрих ручки содержит UUID, от 1 до 8192 точек, толщину до 128 points и непрозрачность от 0 до 1.", target: operation.target)
    }
    let values = operation.values
    guard operation.kind == .appendInkStroke,
      [.page, .board, .cover, .codeFragment].contains(operation.target.kind),
      let id = operation.id.flatMap(UUID.init(uuidString:)),
      Set(values.keys).isSubset(of: ["points", "width", "opacity", "color", "worldOrigin"]),
      let points = values["points"], case .array(let raw) = points,
      (1...Self.maximumPoints).contains(raw.count) else { throw invalid() }
    self.id = id
    let width = values["width"] ?? .number(2)
    let opacity = values["opacity"] ?? .number(1)
    guard case .number(let baseWidth) = width, baseWidth.isFinite, baseWidth > 0, baseWidth <= 128,
      case .number(let baseOpacity) = opacity, baseOpacity.isFinite, (0...1).contains(baseOpacity) else { throw invalid() }
    color = try (values["color"] ?? .encode(SpatialInkColor.black)).decode(SpatialInkColor.self)
    guard color.isValid else { throw invalid() }
    if operation.target.kind == .board {
      guard let origin = values["worldOrigin"] else { throw invalid() }
      worldOrigin = try origin.decode(WorldPoint.self)
    } else {
      guard values["worldOrigin"] == nil else { throw invalid() }
      worldOrigin = nil
    }
    let origin = worldOrigin
    samples = try raw.enumerated().map { index, value in
      guard Set(value.object.keys).isSubset(of: ["x", "y", "width", "opacity"]),
        case .number(let x) = value["x"], case .number(let y) = value["y"],
        case .number(let w) = value["width"] ?? width,
        case .number(let alpha) = value["opacity"] ?? opacity,
        x.isFinite, y.isFinite, abs(x) <= 1e6, abs(y) <= 1e6,
        w.isFinite, w > 0, w <= 128, alpha.isFinite, (0...1).contains(alpha) else { throw invalid() }
      let worldPoint = origin?.addressOffset(x: x, y: y)
      // The finite point delta is already bounded above. Validate its actual
      // address before SpatialInkAction accepts measurements, not an arbitrary
      // smaller origin range and not a later encoding failure.
      guard origin == nil || worldPoint != nil else { throw invalid() }
      return SpatialInkSample(point: .init(x: x, y: y), worldPoint: worldPoint,
        timeOffset: Double(index) / 120, width: w, opacity: alpha, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    let minX = samples.map { $0.point.x - $0.width / 2 }.min()!
    let minY = samples.map { $0.point.y - $0.width / 2 }.min()!
    let maxX = samples.map { $0.point.x + $0.width / 2 }.max()!
    let maxY = samples.map { $0.point.y + $0.width / 2 }.max()!
    region = .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  var pageAction: PageInkAction { .init(id: id, tool: .pen, color: color, samples: samples) }
  func span(on target: CollaborationTarget) -> SpatialInkSpan {
    .init(surface: target.kind == .board ? .board(target.id) : target.kind == .codeFragment ? .codeFragment(target.id) : .cover(target.id), samples: samples)
  }
}

extension CollaborationAction {
  var containsInk: Bool { operations.contains { $0.kind == .appendInkStroke } }

  /// Stroke UUIDs in the operation own undo. Never capture a whole drawing as
  /// a replaceable field: another contact can append to it before undo runs.
  func ownsInkField(_ change: CollaborationFieldChange) -> Bool {
    guard containsInk else { return false }
    if change.file == "spatial-ink.json" { return true }
    return change.path == [.field("drawingData")] && operations.contains {
      $0.kind == .appendInkStroke && $0.target.kind == .page
        && change.file == "pages/\($0.target.id.uuidString.lowercased()).json"
    }
  }
}
