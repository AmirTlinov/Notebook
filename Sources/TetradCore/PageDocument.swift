import Foundation

public struct PageSize: Codable, Equatable, Sendable {
  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) {
    precondition(width > 0 && height > 0)
    self.width = width
    self.height = height
  }
}

public struct PageRect: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    precondition(width > 0 && height > 0)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
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
    precondition(!id.isEmpty)
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
}

public struct PageDocument: Codable, Equatable, Identifiable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public let id: UUID
  public let size: PageSize
  public var drawingData: Data
  public var drawingStamp: VersionStamp
  public var elements: [AgentElement]
  public var agentStamp: VersionStamp

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
  }

  public mutating func replaceDrawing(_ data: Data, actor: UUID) {
    guard data != drawingData else { return }
    drawingData = data
    drawingStamp = drawingStamp.advanced(by: actor)
  }

  public mutating func replaceElements(
    _ elements: [AgentElement],
    actor: UUID
  ) {
    guard elements != self.elements else { return }
    self.elements = elements
    agentStamp = agentStamp.advanced(by: actor)
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id else { return false }
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
