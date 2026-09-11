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
  /// Absent until a user activates ink; not a second page or editor.
  public internal(set) var computations: [NotebookComputation]?

  /// Decoding and encoding happen before publication. The drawing stamp is the
  /// compare-and-swap boundary; unrelated element edits remain on this page.
  public func prepareInkChange(_ mutation: PageInkMutation, stamp: VersionStamp) throws -> PreparedPageInkChange {
    try Task.checkCancellation()
    let current = try PageInkDrawing.decode(drawingData)
    let drawing: PageInkDrawing
    switch mutation {
    case .append(let action): drawing = try current.appending(action)
    case .remove(let ids): drawing = current.removing(ids)
    }
    guard drawing != current else {
      return PreparedPageInkChange(pageID: id, baseStamp: drawingStamp,
        stamp: drawingStamp, drawing: current, data: drawingData)
    }
    guard drawingStamp.counter < VersionStamp.maximumCounter,
      stamp.counter <= VersionStamp.maximumCounter else { throw PageInkDrawing.InkError.invalidDrawing }
    let next = VersionStamp(counter: max(drawingStamp.counter + 1, stamp.counter), actor: stamp.actor)
    let data = try drawing.dataRepresentation()
    try Task.checkCancellation()
    return PreparedPageInkChange(pageID: id, baseStamp: drawingStamp, stamp: next, drawing: drawing, data: data)
  }

  @discardableResult
  public mutating func publishInkChange(_ change: PreparedPageInkChange) -> Bool {
    guard change.pageID == id, change.baseStamp == drawingStamp else { return false }
    drawingData = change.data
    drawingStamp = change.stamp
    return true
  }

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
      computationsAreValid,
      collaboration?.fields["computations"] == nil,
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
    guard let current = try? PageInkDrawing.decode(drawingData),
      let requested = try? PageInkDrawing.decode(data) else { return false }
    do {
      let next = try current.removing(Set(current.activeActions.map(\.id))
        .subtracting(requested.activeActions.map(\.id))).merging(requested)
      return try replaceDrawing(next.dataRepresentation(), stamp: stamp)
    } catch PageInkDrawing.InkError.incompatibleBaseline {
      return replaceDrawing(data, stamp: stamp)
    } catch {
      return false
    }
  }

  @discardableResult
  public mutating func replaceDrawing(
    _ data: Data,
    stamp: VersionStamp
  ) -> Bool {
    (try? mergeDrawing(data, stamp: stamp)) ?? false
  }

  /// Persistent publishers must distinguish a rejected stroke from an
  /// unchanged drawing before they can acknowledge any part of the page.
  private mutating func mergeDrawing(_ data: Data, stamp: VersionStamp) throws -> Bool {
    guard stamp.counter <= VersionStamp.maximumCounter else { throw PageInkDrawing.InkError.invalidDrawing }
    let incoming = try PageInkDrawing.decode(data)
    if data == drawingData {
      guard drawingStamp < stamp else { return false }
      drawingStamp = stamp
      return true
    }
    let current = try PageInkDrawing.decode(drawingData)
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
      // An explicit raster import is a whole-baseline revision; it is not an
      // instruction to ignore an action identity conflict on the same base.
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
      metadata.record(before: before.setting("computations", nil), after: after.setting("computations", nil),
        beforeStamp: agentStamp, stamp: stamp, human: true)
      candidate.collaboration = metadata
    }
    guard candidate.isValid else { return false }
    self = candidate
    return true
  }

  public mutating func merge(_ other: Self) -> Bool {
    guard let resolved = try? merging(other), resolved != self else { return false }
    self = resolved
    return true
  }

  /// Resolve the complete page before publishing any field. A conflicting
  /// stroke also rejects computations and elements carried by that candidate.
  func merging(_ other: Self) throws -> Self {
    guard id == other.id, size == other.size, isValid, other.isValid else {
      throw NotebookStorageError.transactionConflict
    }
    var candidate = self
    candidate.computations = try joinedComputations(other.computations ?? [])
    _ = try candidate.mergeDrawing(other.drawingData, stamp: other.drawingStamp)
    if elements == other.elements && collaboration == other.collaboration && agentStamp == other.agentStamp {
      return candidate
    }
    // The typed computation owner joins above. Agent field clocks never own
    // this collection, including while merging an unrelated element edit.
    let local = try JSONValue.encode(candidate).setting("computations", nil)
    let incoming = try JSONValue.encode(other).setting("computations", nil)
    let merged = CollaborativeContent.merge(local: local, incoming: incoming,
      localState: collaboration, incomingState: other.collaboration,
      localStamp: agentStamp, incomingStamp: other.agentStamp)
    let resolved = try merged.value.decode(PageDocument.self)
    guard resolved.isValid else { throw NotebookStorageError.transactionConflict }
    candidate.elements = resolved.elements
    candidate.collaboration = merged.state
    candidate.agentStamp = mergedContentStamp(local: local, incoming: incoming, result: merged.value,
      localStamp: agentStamp, incomingStamp: other.agentStamp)
    return candidate
  }

  private var computationsAreValid: Bool {
    guard let computations else { return true }
    return !computations.isEmpty && computations.count <= 256
      && Set(computations.map(\.id)).count == computations.count
      && computations.allSatisfy { $0.isValid && $0.source.pageID == id && $0.source.region.isContained(in: size) }
      && computations == computations.sorted(by: NotebookComputation.ordered)
  }

  /// Computation identity belongs to its typed journal, not agent field clocks.
  /// Both page resolution and addressed publication reject a conflicting record.
  func joinedComputations(_ incoming: [NotebookComputation]) throws -> [NotebookComputation]? {
    var result = Dictionary(uniqueKeysWithValues: (computations ?? []).map { ($0.id, $0) })
    for record in incoming {
      result[record.id] = try result[record.id].map { try $0.joining(record) } ?? record
    }
    guard result.count <= 256 else { throw NotebookStorageError.limitExceeded("page_computations") }
    return result.isEmpty ? nil : result.values.sorted(by: NotebookComputation.ordered)
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

public enum PageInkMutation: Sendable {
  case append(PageInkAction)
  case remove(Set<UUID>)
}

/// A validated result prepared away from the input thread. Its constructor is
/// private to the page owner, so publication never needs to decode the archive.
public struct PreparedPageInkChange: Sendable {
  public let pageID: UUID
  public let baseStamp: VersionStamp
  public let stamp: VersionStamp
  public let drawing: PageInkDrawing
  public let data: Data

  fileprivate init(pageID: UUID, baseStamp: VersionStamp, stamp: VersionStamp, drawing: PageInkDrawing, data: Data) {
    self.pageID = pageID; self.baseStamp = baseStamp; self.stamp = stamp
    self.drawing = drawing; self.data = data
  }
}
