import Foundation

public struct PageSize: Codable, Equatable, Sendable {
  /// Larger values are not a physical iPad page and can exhaust render memory.
  public static let maximumDimension = 2_048.0

  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) {
    precondition(
      width.isFinite && height.isFinite
        && width > 0 && height > 0
        && width <= Self.maximumDimension
        && height <= Self.maximumDimension
    )
    self.width = width
    self.height = height
  }

  var isValid: Bool {
    width.isFinite && height.isFinite
      && width > 0 && height > 0
      && width <= Self.maximumDimension
      && height <= Self.maximumDimension
  }
}

public struct PageRect: Codable, Equatable, Sendable {
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

  func isContained(in pageSize: PageSize) -> Bool {
    x.isFinite
      && y.isFinite
      && width.isFinite
      && height.isFinite
      && width > 0
      && height > 0
      && x >= 0
      && y >= 0
      && x + width <= pageSize.width
      && y + height <= pageSize.height
  }
}

public enum AgentElementKind: String, Codable, Sendable {
  case markdown
  case web
}

public struct AgentElement: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: AgentElementKind
  public let frame: PageRect
  public let source: String
  public let html: String
  public let css: String
  public let javaScript: String
  public let state: JSONValue

  public init(
    id: String,
    kind: AgentElementKind,
    frame: PageRect,
    source: String,
    html: String,
    css: String = "",
    javaScript: String = "",
    state: JSONValue = .object([:])
  ) {
    precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.id = id
    self.kind = kind
    self.frame = frame
    self.source = source
    self.html = html
    self.css = css
    self.javaScript = javaScript
    self.state = state
  }

  public func updating(state: JSONValue) -> Self {
    Self(
      id: id,
      kind: kind,
      frame: frame,
      source: source,
      html: html,
      css: css,
      javaScript: javaScript,
      state: state
    )
  }

  public func updating(frame: PageRect) -> Self {
    Self(
      id: id,
      kind: kind,
      frame: frame,
      source: source,
      html: html,
      css: css,
      javaScript: javaScript,
      state: state
    )
  }
}

public struct PageDocument: Codable, Equatable, Identifiable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public let id: UUID
  public let size: PageSize
  public private(set) var drawingData: Data
  public private(set) var drawingStamp: VersionStamp
  public private(set) var elements: [AgentElement]
  public private(set) var agentStamp: VersionStamp

  public init(
    id: UUID = UUID(),
    size: PageSize,
    actor: UUID,
    drawingData: Data = Data(),
    elements: [AgentElement] = []
  ) {
    format = Self.formatVersion
    self.id = id
    self.size = size
    self.drawingData = drawingData
    drawingStamp = VersionStamp(counter: 0, actor: actor)
    self.elements = elements
    agentStamp = VersionStamp(counter: 0, actor: actor)
    precondition(isValid)
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
      size.isValid,
      drawingStamp.counter <= VersionStamp.maximumCounter,
      agentStamp.counter <= VersionStamp.maximumCounter
    else { return false }

    let ids = elements.map(\.id)
    return Set(ids).count == ids.count
      && elements.allSatisfy {
        !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && $0.frame.isContained(in: size)
          && $0.state.isValid
      }
  }

  @discardableResult
  public mutating func replaceDrawing(_ data: Data, actor: UUID) -> Bool {
    guard data != drawingData,
      let stamp = drawingStamp.advanced(by: actor)
    else { return false }
    return replaceDrawing(data, stamp: stamp)
  }

  @discardableResult
  public mutating func replaceDrawing(
    _ data: Data,
    stamp: VersionStamp
  ) -> Bool {
    guard drawingStamp < stamp,
      stamp.counter <= VersionStamp.maximumCounter
    else { return false }
    drawingData = data
    drawingStamp = stamp
    return true
  }

  @discardableResult
  public mutating func replaceElements(
    _ elements: [AgentElement],
    actor: UUID
  ) -> Bool {
    guard elements != self.elements,
      let stamp = agentStamp.advanced(by: actor)
    else { return false }
    return replaceElements(elements, stamp: stamp)
  }

  @discardableResult
  public mutating func replaceElements(
    _ elements: [AgentElement],
    stamp: VersionStamp
  ) -> Bool {
    guard agentStamp < stamp,
      stamp.counter <= VersionStamp.maximumCounter
    else { return false }
    var candidate = self
    candidate.elements = elements
    candidate.agentStamp = stamp
    guard candidate.isValid else { return false }
    self = candidate
    return true
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id, size == other.size, other.isValid else { return false }
    var changed = false
    if drawingStamp < other.drawingStamp {
      drawingData = other.drawingData
      drawingStamp = other.drawingStamp
      changed = true
    }
    if agentStamp < other.agentStamp {
      elements = other.elements
      agentStamp = other.agentStamp
      changed = true
    }
    return changed
  }
}
