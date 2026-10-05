import Foundation

/// One addressed stroke retains the measured samples of a completed pen
/// contact. Coordinates belong to the physical owner, never the human camera.
struct CollaborationInkStroke {
  static let maximumAgentPoints = 8192
  static let maximumPoints = 65_536
  let id: UUID
  let color: SpatialInkColor
  let samples: [SpatialInkSample]
  let region: PageRect
  let worldOrigin: WorldPoint?

  init(_ operation: CollaborationOperation, agentAdmission: Bool = false) throws {
    let maximumPoints = agentAdmission ? Self.maximumAgentPoints : Self.maximumPoints
    func invalid() -> CollaborationError {
      .init("invalid_operation", "Штрих ручки содержит UUID, от 1 до \(maximumPoints) конечных измерений, положительную толщину и непрозрачность от 0 до 1.", target: operation.target)
    }
    let values = operation.values
    guard operation.kind == .appendInkStroke,
      [.page, .board, .cover, .codeFragment].contains(operation.target.kind),
      let id = operation.id.flatMap(UUID.init(uuidString:)),
      Set(values.keys).isSubset(of: ["points", "width", "opacity", "color", "worldOrigin"]),
      let points = values["points"], case .array(let raw) = points,
      (1...maximumPoints).contains(raw.count) else { throw invalid() }
    self.id = id
    let width = values["width"] ?? .number(2)
    let opacity = values["opacity"] ?? .number(1)
    guard case .number(let baseWidth) = width, baseWidth.isFinite, baseWidth > 0, (!agentAdmission || baseWidth <= 128),
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
      guard Set(value.object.keys).isSubset(of: ["x", "y", "width", "opacity", "timeOffset", "force", "azimuth", "altitude"]),
        case .number(let x) = value["x"], case .number(let y) = value["y"],
        case .number(let w) = value["width"] ?? width,
        case .number(let alpha) = value["opacity"] ?? opacity,
        case .number(let time) = value["timeOffset"] ?? .number(Double(index) / 120),
        case .number(let force) = value["force"] ?? .number(1),
        case .number(let azimuth) = value["azimuth"] ?? .number(0),
        case .number(let altitude) = value["altitude"] ?? .number(.pi / 2),
        x.isFinite, y.isFinite, (!agentAdmission || (abs(x) <= 1e6 && abs(y) <= 1e6)),
        w.isFinite, w > 0, (!agentAdmission || w <= 128), alpha.isFinite, (0...1).contains(alpha),
        time.isFinite, time >= 0, force.isFinite, force >= 0,
        azimuth.isFinite, altitude.isFinite else { throw invalid() }
      let worldPoint = origin?.addressOffset(x: x, y: y)
      // The finite point delta is already bounded above. Validate its actual
      // address before SpatialInkAction accepts measurements, not an arbitrary
      // smaller origin range and not a later encoding failure.
      guard origin == nil || worldPoint != nil else { throw invalid() }
      return SpatialInkSample(point: .init(x: x, y: y), worldPoint: worldPoint,
        timeOffset: time, width: w, opacity: alpha, force: force, azimuth: azimuth, altitude: altitude)
    }
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for sample in samples {
      let radius = sample.width / 2
      minX = min(minX, sample.point.x - radius); minY = min(minY, sample.point.y - radius)
      maxX = max(maxX, sample.point.x + radius); maxY = max(maxY, sample.point.y + radius)
    }
    let extentWidth = maxX - minX, extentHeight = maxY - minY
    guard [minX, minY, maxX, maxY, extentWidth, extentHeight].allSatisfy(\.isFinite), extentWidth > 0, extentHeight > 0 else { throw invalid() }
    region = .init(x: minX, y: minY, width: extentWidth, height: extentHeight)
  }

  var pageAction: PageInkAction { .init(id: id, tool: .pen, color: color, samples: samples) }
  func span(on target: CollaborationTarget) -> SpatialInkSpan {
    .init(surface: target.kind == .board ? .board(target.id) : target.kind == .codeFragment ? .codeFragment(target.id) : .cover(target.id), samples: samples)
  }
}

extension CollaborationAction {
  var containsInk: Bool { operations.contains { [.appendInkStroke, .convertInkToElement].contains($0.kind) } }

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
