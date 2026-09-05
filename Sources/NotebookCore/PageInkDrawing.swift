import Foundation

/// A page owns the ordered pen and eraser operations that produced its pixels.
/// A migrated page starts with the final visible PNG of its previous drawing.
public struct PageInkDrawing: Codable, Equatable, Sendable {
  private static let signature = Data("NotebookInk/1\n".utf8)
  public let baselinePNG: Data?
  public let baselineActionCount: Int
  public private(set) var actions: [PageInkAction]

  public init(baselinePNG: Data? = nil, baselineActionCount: Int = 0, actions: [PageInkAction] = [])
  {
    self.baselinePNG = baselinePNG
    self.baselineActionCount = baselineActionCount
    self.actions = actions.enumerated().map { index, action in
      action.sequence == 0 ? action.ordered(UInt64(index + 1)) : action
    }
    precondition(isValid)
  }

  public var activeActions: [PageInkAction] { actions.filter(\.isActive) }
  public var actionCount: Int { baselineActionCount + actions.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }
  public var isEmpty: Bool { baselinePNG == nil && !actions.contains(where: \.isActive) }
  public var isValid: Bool {
    baselineActionCount >= 0 && baselineActionCount <= 1_000_000
      && (baselinePNG.map {
        $0.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) && $0.count <= 64 * 1024 * 1024
      } ?? true)
      && actions.allSatisfy(\.isValid) && Set(actions.map(\.id)).count == actions.count
  }

  public static func needsMigration(_ data: Data) -> Bool {
    !data.isEmpty && !data.starts(with: signature)
  }

  public static func decode(_ data: Data) throws -> Self {
    if data.isEmpty { return Self() }
    guard data.starts(with: signature) else { throw InkError.migrationRequired }
    var decoded = try PropertyListDecoder().decode(Self.self, from: data.dropFirst(signature.count))
    guard decoded.isValid else { throw InkError.invalidDrawing }
    // Native archives written before shared ink have array order but no clock.
    // Adopt that exact order once; later appends carry their own sequence.
    if decoded.actions.contains(where: { $0.sequence == 0 }) {
      decoded.actions = decoded.actions.enumerated().map { index, action in
        action.sequence == 0 ? action.ordered(UInt64(index + 1)) : action
      }
    }
    return decoded
  }

  public func dataRepresentation() throws -> Data {
    guard isValid else { throw InkError.invalidDrawing }
    if baselinePNG == nil && actions.isEmpty && baselineActionCount == 0 { return Data() }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return Self.signature + (try encoder.encode(self))
  }

  public func appending(_ action: PageInkAction) -> Self {
    guard !actions.contains(where: { $0.id == action.id }) else { return self }
    let last = actions.map(\.sequence).max() ?? 0
    guard last < VersionStamp.maximumCounter else { return self }
    return Self(
      baselinePNG: baselinePNG, baselineActionCount: baselineActionCount,
      actions: actions + [action.ordered(last + 1)])
  }

  /// An undo retains a tombstone: an older device cannot resurrect the stroke.
  public func removing(_ ids: Set<UUID>) -> Self {
    Self(baselinePNG: baselinePNG, baselineActionCount: baselineActionCount,
      actions: actions.map { ids.contains($0.id) ? $0.deactivated() : $0 })
  }

  public func merging(_ other: Self) throws -> Self {
    guard baselinePNG == other.baselinePNG, baselineActionCount == other.baselineActionCount else {
      throw InkError.incompatibleBaseline
    }
    var byID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    for incoming in other.actions {
      if let current = byID[incoming.id] {
        guard current.sequence == incoming.sequence, current.tool == incoming.tool,
          current.color == incoming.color, current.samples == incoming.samples else { throw InkError.actionIDConflict }
        byID[incoming.id] = current.isActive ? incoming : current
      } else { byID[incoming.id] = incoming }
    }
    return Self(baselinePNG: baselinePNG, baselineActionCount: baselineActionCount,
      actions: byID.values.sorted {
        $0.sequence == $1.sequence ? $0.id.uuidString < $1.id.uuidString : $0.sequence < $1.sequence
      })
  }

  public enum InkError: Error { case migrationRequired, invalidDrawing, incompatibleBaseline, actionIDConflict }
}

public struct PageInkAction: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let tool: SpatialInkTool
  public let color: SpatialInkColor
  public let samples: [SpatialInkSample]
  public let sequence: UInt64
  public let isActive: Bool

  public init(
    id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    samples: [SpatialInkSample], sequence: UInt64 = 0, isActive: Bool = true
  ) {
    self.id = id
    self.tool = tool
    self.color = color
    self.samples = samples
    self.sequence = sequence
    self.isActive = isActive
    precondition(isValid)
  }

  public var isValid: Bool {
    sequence <= VersionStamp.maximumCounter && color.isValid && !samples.isEmpty && samples.count <= 1_000_000
      && samples.allSatisfy { $0.isValid && $0.worldPoint == nil }
  }

  private enum CodingKeys: String, CodingKey { case id, tool, color, samples, sequence, isActive }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    tool = try values.decode(SpatialInkTool.self, forKey: .tool)
    color = try values.decode(SpatialInkColor.self, forKey: .color)
    samples = try values.decode([SpatialInkSample].self, forKey: .samples)
    sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
    isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    guard isValid else { throw PageInkDrawing.InkError.invalidDrawing }
  }

  fileprivate func ordered(_ sequence: UInt64) -> Self {
    Self(id: id, tool: tool, color: color, samples: samples, sequence: sequence, isActive: isActive)
  }

  fileprivate func deactivated() -> Self {
    isActive ? Self(id: id, tool: tool, color: color, samples: samples, sequence: sequence, isActive: false) : self
  }
}
