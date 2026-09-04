import Foundation

public enum SpatialInkTool: String, Codable, Sendable {
  case pen
  case eraser
}

public struct SpatialInkColor: Codable, Equatable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double

  public init(red: Double, green: Double, blue: Double) {
    precondition([red, green, blue].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    self.red = red
    self.green = green
    self.blue = blue
  }

  public static let black = SpatialInkColor(red: 0.035, green: 0.034, blue: 0.031)

  var isValid: Bool {
    [red, green, blue].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
  }
}

public struct SpatialInkSample: Codable, Equatable, Sendable {
  public let point: SpatialPoint
  /// Board samples keep their tile so a far-away stroke never loses
  /// precision. Cover samples use `point` in the cover's local coordinates.
  public let worldPoint: WorldPoint?
  public let timeOffset: Double
  public let width: Double
  public let opacity: Double
  public let force: Double
  public let azimuth: Double
  public let altitude: Double

  public init(
    point: SpatialPoint,
    worldPoint: WorldPoint? = nil,
    timeOffset: Double,
    width: Double,
    opacity: Double,
    force: Double,
    azimuth: Double,
    altitude: Double
  ) {
    precondition(
      timeOffset.isFinite && timeOffset >= 0
        && width.isFinite && width > 0
        && opacity.isFinite && opacity >= 0 && opacity <= 1
        && force.isFinite && force >= 0
        && azimuth.isFinite && altitude.isFinite
    )
    self.point = point
    self.worldPoint = worldPoint
    self.timeOffset = timeOffset
    self.width = width
    self.opacity = opacity
    self.force = force
    self.azimuth = azimuth
    self.altitude = altitude
  }

  var isValid: Bool {
    point.isValid && (worldPoint?.isValid ?? true)
      && timeOffset.isFinite && timeOffset >= 0
      && width.isFinite && width > 0
      && opacity.isFinite && opacity >= 0 && opacity <= 1
      && force.isFinite && force >= 0
      && azimuth.isFinite && altitude.isFinite
  }
}

public struct SpatialInkSpan: Codable, Equatable, Sendable {
  public let surface: SurfaceID
  public let samples: [SpatialInkSample]

  public init(surface: SurfaceID, samples: [SpatialInkSample]) {
    precondition(surface.kind != .page && !samples.isEmpty)
    self.surface = surface
    self.samples = samples
  }

  var isValid: Bool {
    surface.isValid && surface.kind != .page
      && !samples.isEmpty && samples.allSatisfy(\.isValid)
      && samples.allSatisfy {
        surface.kind == .board
          ? $0.worldPoint != nil
          : $0.worldPoint == nil
      }
  }
}

public struct SpatialInkAction: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let tool: SpatialInkTool
  public let color: SpatialInkColor
  public let spans: [SpatialInkSpan]
  public let stamp: VersionStamp
  public private(set) var isActive: Bool
  public private(set) var stateStamp: VersionStamp

  public init(
    id: UUID = UUID(),
    tool: SpatialInkTool,
    color: SpatialInkColor = .black,
    spans: [SpatialInkSpan],
    stamp: VersionStamp,
    isActive: Bool = true,
    stateStamp: VersionStamp? = nil
  ) {
    precondition(!spans.isEmpty)
    self.id = id
    self.tool = tool
    self.color = color
    self.spans = spans
    self.stamp = stamp
    self.isActive = isActive
    self.stateStamp = stateStamp ?? stamp
    precondition(isValid)
  }

  @discardableResult
  mutating func setActive(_ active: Bool, actor: UUID) -> Bool {
    guard active != isActive,
      let next = stateStamp.advanced(by: actor)
    else { return false }
    isActive = active
    stateStamp = next
    return true
  }

  mutating func mergeState(_ other: Self) -> Bool {
    guard id == other.id,
      stamp == other.stamp,
      tool == other.tool,
      color == other.color,
      spans == other.spans,
      stateStamp < other.stateStamp
    else { return false }
    isActive = other.isActive
    stateStamp = other.stateStamp
    return true
  }

  var isValid: Bool {
    color.isValid && !spans.isEmpty && spans.allSatisfy(\.isValid)
      && stamp.counter <= VersionStamp.maximumCounter
      && stateStamp.counter <= VersionStamp.maximumCounter
      && !(stateStamp < stamp)
  }
}

public struct SpatialInkJournal: Codable, Equatable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public private(set) var actions: [SpatialInkAction]
  public private(set) var stamp: VersionStamp

  public init(actions: [SpatialInkAction] = [], stamp: VersionStamp) {
    format = Self.formatVersion
    self.actions = actions
    self.stamp = stamp
    precondition(isValid)
  }

  /// Active pen actions retain editable content even when a later eraser
  /// covers their pixels. Undo must remain able to recover that content.
  public func containsEditableInk(on surface: SurfaceID) -> Bool {
    actions.contains { action in
      action.isActive && action.tool == .pen
        && action.spans.contains { span in
          span.surface == surface && span.samples.contains { $0.opacity > 0 }
        }
    }
  }

  @discardableResult
  public mutating func append(
    tool: SpatialInkTool,
    color: SpatialInkColor = .black,
    spans: [SpatialInkSpan],
    actor: UUID,
    id: UUID = UUID()
  ) -> SpatialInkAction? {
    guard !actions.contains(where: { $0.id == id }),
      !spans.isEmpty,
      let next = stamp.advanced(by: actor)
    else { return nil }
    let action = SpatialInkAction(
      id: id,
      tool: tool,
      color: color,
      spans: spans,
      stamp: next
    )
    actions.append(action)
    stamp = next
    return action
  }

  @discardableResult
  public mutating func undoLast(
    actor: UUID,
    touching surface: SurfaceID? = nil
  ) -> SpatialInkAction? {
    guard let index = actions.lastIndex(where: { action in
      action.isActive
        && (surface == nil || action.spans.contains { $0.surface == surface })
    }), let next = stamp.advanced(by: actor)
    else { return nil }
    guard actions[index].setActive(false, actor: actor) else { return nil }
    stamp = next
    return actions[index]
  }

  @discardableResult
  public mutating func merge(_ other: Self) -> Bool {
    guard other.isValid else { return false }
    var changed = false
    var byID = Dictionary(uniqueKeysWithValues: actions.enumerated().map {
      ($0.element.id, $0.offset)
    })
    for incoming in other.actions {
      if let index = byID[incoming.id] {
        if actions[index].mergeState(incoming) { changed = true }
      } else {
        byID[incoming.id] = actions.count
        actions.append(incoming)
        changed = true
      }
    }
    actions.sort { first, second in
      first.stamp == second.stamp
        ? first.id.uuidString < second.id.uuidString
        : first.stamp < second.stamp
    }
    if stamp < other.stamp {
      stamp = other.stamp
      changed = true
    }
    return changed
  }

  public var isValid: Bool {
    guard format == Self.formatVersion,
      stamp.counter <= VersionStamp.maximumCounter,
      actions.allSatisfy(\.isValid)
    else { return false }
    let ids = actions.map(\.id)
    return Set(ids).count == ids.count
  }
}
