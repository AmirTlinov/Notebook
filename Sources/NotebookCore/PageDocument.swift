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
  public private(set) var collaboration: CollaborativeContent?

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
    collaboration = nil
    agentStamp = VersionStamp(counter: 0, actor: actor)
    precondition(isValid)
  }

  var isValid: Bool {
    guard format == Self.formatVersion,
      collaboration?.isValid ?? true,
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

  /// Representation migration preserves the version of the same visible drawing.
  mutating func migrateInkRepresentation(_ data: Data) throws {
    _ = try PageInkDrawing.decode(data)
    drawingData = data
  }

  @discardableResult
  public mutating func replaceDrawing(_ data: Data, actor: UUID) -> Bool {
    guard data != drawingData,
      let stamp = drawingStamp.advanced(by: actor)
    else { return false }
    if let current = try? PageInkDrawing.decode(drawingData),
      let requested = try? PageInkDrawing.decode(data),
      let next = try? current.removing(Set(current.activeActions.map(\.id))
        .subtracting(requested.activeActions.map(\.id))).merging(requested),
      let encoded = try? next.dataRepresentation() {
      return replaceDrawing(encoded, stamp: stamp)
    }
    return replaceDrawing(data, stamp: stamp)
  }

  @discardableResult
  public mutating func replaceDrawing(
    _ data: Data,
    stamp: VersionStamp
  ) -> Bool {
    guard stamp.counter <= VersionStamp.maximumCounter else { return false }
    if data == drawingData {
      guard drawingStamp < stamp else { return false }
      drawingStamp = stamp
      return true
    }
    if let current = try? PageInkDrawing.decode(drawingData),
      let incoming = try? PageInkDrawing.decode(data) {
      do {
        let merged = try current.merging(incoming)
        let frontier = max(drawingStamp, stamp)
        let winner = drawingStamp > stamp ? current : incoming
        let resolvedStamp = merged == winner ? frontier : (frontier.advanced(by: frontier.actor) ?? frontier)
        guard merged != current || drawingStamp != resolvedStamp else { return false }
        drawingData = merged == current ? drawingData : merged == incoming ? data : try merged.dataRepresentation()
        drawingStamp = resolvedStamp
        return true
      } catch PageInkDrawing.InkError.incompatibleBaseline {
        // Importing/replacing the archived PencilKit raster remains an explicit
        // whole-baseline revision. Native contacts on that baseline merge above.
      } catch { return false }
    }
    guard drawingStamp < stamp else { return false }
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
    var metadata = collaboration ?? CollaborativeContent()
    if let before = try? JSONValue.encode(self), let after = try? JSONValue.encode(candidate) {
      metadata.record(before: before, after: after, beforeStamp: agentStamp, stamp: stamp, human: true)
      candidate.collaboration = metadata
    }
    guard candidate.isValid else { return false }
    self = candidate
    return true
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard id == other.id, size == other.size, other.isValid else { return false }
    var changed = false
    if replaceDrawing(other.drawingData, stamp: other.drawingStamp) { changed = true }
    if elements == other.elements && collaboration == other.collaboration && agentStamp == other.agentStamp {
      return changed
    }
    if let local = try? JSONValue.encode(self), let incoming = try? JSONValue.encode(other) {
      let merged = CollaborativeContent.merge(local: local, incoming: incoming,
        localState: collaboration, incomingState: other.collaboration,
        localStamp: agentStamp, incomingStamp: other.agentStamp)
      if let resolved = try? merged.value.decode(PageDocument.self), resolved.isValid {
        if elements != resolved.elements || collaboration != merged.state { changed = true }
        elements = resolved.elements
        collaboration = merged.state
        agentStamp = mergedContentStamp(local: local, incoming: incoming, result: merged.value,
          localStamp: agentStamp, incomingStamp: other.agentStamp)
      }
    }
    return changed
  }

  @discardableResult
  public mutating func mergeElements(_ elements: [AgentElement], stamp: VersionStamp,
    collaboration: CollaborativeContent?) -> Bool {
    var incoming = self
    incoming.elements = elements
    incoming.agentStamp = stamp
    incoming.collaboration = collaboration
    return merge(incoming)
  }
}
