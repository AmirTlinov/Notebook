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
    self.actions = actions
    precondition(isValid)
  }

  public var actionCount: Int { baselineActionCount + actions.count }
  public var isEmpty: Bool { baselinePNG == nil && actions.isEmpty }
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
    let drawing = try PropertyListDecoder().decode(Self.self, from: data.dropFirst(signature.count))
    guard drawing.isValid else { throw InkError.invalidDrawing }
    return drawing
  }

  public func dataRepresentation() throws -> Data {
    guard isValid else { throw InkError.invalidDrawing }
    if isEmpty && baselineActionCount == 0 { return Data() }
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return Self.signature + (try encoder.encode(self))
  }

  public func appending(_ action: PageInkAction) -> Self {
    guard !actions.contains(where: { $0.id == action.id }) else { return self }
    return Self(
      baselinePNG: baselinePNG, baselineActionCount: baselineActionCount,
      actions: actions + [action])
  }

  public enum InkError: Error { case migrationRequired, invalidDrawing }
}

public struct PageInkAction: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let tool: SpatialInkTool
  public let color: SpatialInkColor
  public let samples: [SpatialInkSample]

  public init(
    id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    samples: [SpatialInkSample]
  ) {
    self.id = id
    self.tool = tool
    self.color = color
    self.samples = samples
    precondition(isValid)
  }

  public var isValid: Bool {
    color.isValid && !samples.isEmpty && samples.count <= 1_000_000
      && samples.allSatisfy { $0.isValid && $0.worldPoint == nil }
  }
}
