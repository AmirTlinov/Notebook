import Foundation

public enum SpatialInkTool: String, Codable, Sendable {
  case pen
  case eraser
}

public struct SpatialInkColor: Codable, Hashable, Sendable {
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
  public let samples: InkMeasurements
  public let elementTargets: [InkElementTarget]?

  public init(surface: SurfaceID, samples: [SpatialInkSample], elementTargets: [InkElementTarget]? = nil) {
    self.init(surface:surface,measurements:.init(samples),elementTargets:elementTargets)
  }
  public init(surface: SurfaceID, measurements: InkMeasurements, elementTargets: [InkElementTarget]? = nil) {
    precondition(surface.kind != .page && !measurements.isEmpty)
    self.surface = surface
    self.samples = measurements
    self.elementTargets = elementTargets?.isEmpty == false ? elementTargets : nil
  }

  var isValid: Bool {
    (elementTargets == nil || (elementTargets!.allSatisfy { $0.isValid && ($0.worldOrigin != nil) == (surface.kind == .board) }
      && Set(elementTargets!.map(\.elementID)).count == elementTargets!.count))
      && surface.isValid && surface.kind != .page
      && !samples.isEmpty && samples.count <= 1_000_000
      && (surface.kind == .board ? samples.isWorld : samples.isPaper)
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
  var retainedPayloadBytes:Int {
    MemoryLayout<Self>.stride + spans.capacity * MemoryLayout<SpatialInkSpan>.stride
      + spans.reduce(0) { total, span in
        total + span.samples.payloadBytes
          + (span.elementTargets?.capacity ?? 0) * MemoryLayout<InkElementTarget>.stride
          + (span.elementTargets ?? []).reduce(0) { $0 + $1.elementID.utf8.count * 2 }
      }
  }

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
      && (tool == .eraser || spans.allSatisfy { $0.elementTargets == nil })
      && stamp.counter <= VersionStamp.maximumCounter
      && stateStamp.counter <= VersionStamp.maximumCounter
      && !(stateStamp < stamp)
  }
}

public struct SpatialInkJournal: Codable, Equatable, Sendable {
  public static let formatVersion = 2

  public let format: Int
  private(set) var storage: SpatialInkActionStorage
  public var actions: [SpatialInkAction] { storage.actions }
  public var orderedActions: some Sequence<SpatialInkAction> & Sendable { storage.orderedActions }
  public var actionCount: Int { storage.count }
  public var sourceIdentity:ObjectIdentifier {ObjectIdentifier(storage)}
  /// Conservative retained metadata for both immutable nodes per action and
  /// their shared contact index, including indirect identifiers and capacity.
  /// Shared roots are intentionally charged to each retaining cache entry.
  public var retainedMetadataBytes: Int {
    128 + actionCount * (MemoryLayout<SpatialInkAction>.stride + 128) + storage.contactIndex.retainedMetadataBytes
  }
  public var retainedPayloadBytes:Int { storage.retainedPayloadBytes }
  public private(set) var stamp: VersionStamp

  public init(actions: [SpatialInkAction] = [], stamp: VersionStamp) {
    format = Self.formatVersion
    storage = .init(actions)
    self.stamp = stamp
    precondition(isValid)
  }

  public func action(id: UUID) -> SpatialInkAction? { storage.action(id) }

  /// Source membership and causal gates, excluding the aggregate journal clock.
  /// Warm accepted changes are compared without enumerating their history.
  public func hasSameActionStates(as other: Self) -> Bool {
    storage.hasSameActionStates(as: other.storage)
  }

  public func hasSameActions(as other: Self) -> Bool {
    storage === other.storage || (actionCount == other.actionCount && orderedActions.elementsEqual(other.orderedActions))
  }

  private enum CodingKeys: String, CodingKey { case format, actions, stamp }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    format = try values.decode(Int.self, forKey: .format)
    storage = .init(try values.decode([SpatialInkAction].self, forKey: .actions))
    stamp = try values.decode(VersionStamp.self, forKey: .stamp)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(format, forKey: .format)
    try values.encode(actions, forKey: .actions)
    try values.encode(stamp, forKey: .stamp)
  }
  public static func == (left: Self, right: Self) -> Bool {
    left.format == right.format && left.stamp == right.stamp
      && left.hasSameActions(as: right)
  }

  /// Active pen actions retain editable content even when a later eraser
  /// covers their pixels. Undo must remain able to recover that content.
  public func containsEditableInk(on surface: SurfaceID) -> Bool {
    orderedActions.contains { action in
      action.isActive && action.tool == .pen
        && action.spans.contains { span in
          span.surface == surface && span.samples.hasVisibleInk
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
    guard storage.action(id) == nil,
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
    storage = storage.appending(action)
    stamp = next
    return action
  }

  @discardableResult
  public mutating func deactivate(_ id: UUID, actor: UUID) -> Bool {
    setActive(false,id:id,actor:actor)
  }

  @discardableResult
  public mutating func activate(_ id: UUID, actor: UUID) -> Bool {
    setActive(true,id:id,actor:actor)
  }

  private mutating func setActive(_ active:Bool,id:UUID,actor:UUID)->Bool {
    guard var action = storage.action(id), action.isActive != active,
      let next = stamp.advanced(by: actor), action.setActive(active, actor: actor) else { return false }
    storage = storage.replacing(action)
    stamp = next
    return true
  }

  /// Publish the exact gate chosen by an addressed native command. An absent
  /// action is outside this geometry window: advance its clock, not its bodies.
  @discardableResult
  public mutating func applyState(_ result: NotebookSpatialInkResult) -> Bool {
    guard result.creationStamp.counter <= VersionStamp.maximumCounter,
      result.stateStamp >= result.creationStamp, result.journalStamp >= result.stateStamp,
      result.journalStamp.counter <= VersionStamp.maximumCounter else { return false }
    if let action = storage.action(result.actionID) {
      guard action.stamp == result.creationStamp, result.stateStamp >= action.stateStamp else { return false }
      if result.stateStamp == action.stateStamp {
        guard result.isActive == action.isActive else { return false }
      } else {
        storage = storage.replacing(.init(id: action.id, tool: action.tool, color: action.color,
          spans: action.spans, stamp: action.stamp, isActive: result.isActive, stateStamp: result.stateStamp))
      }
    }
    stamp = max(stamp, result.journalStamp)
    return true
  }

  @discardableResult
  public mutating func undoLast(
    actor: UUID,
    touching surface: SurfaceID? = nil
  ) -> SpatialInkAction? {
    guard var action = storage.order?.last(where: { action in
      action.isActive
        && (surface == nil || action.spans.contains { $0.surface == surface })
    }), let next = stamp.advanced(by: actor)
    else { return nil }
    guard action.setActive(false, actor: actor) else { return nil }
    storage = storage.replacing(action)
    stamp = next
    return action
  }

  @discardableResult
  public mutating func merge(_ other: Self) -> Bool {
    guard other.isValid else { return false }
    var changed = false
    var actions = self.actions
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
    storage = .init(actions)
    if stamp < other.stamp {
      stamp = other.stamp
      changed = true
    }
    return changed
  }

  public var isValid: Bool {
    guard format == Self.formatVersion,
      stamp.counter <= VersionStamp.maximumCounter,
      storage.isValid
    else { return false }
    return true
  }
}
