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
  case nativeText
  case markdown
  case web
  case graphic
  case group
}

public struct AgentElement: Codable, Equatable, Identifiable, Sendable {
  static func causalFieldKeys(id: String, graphic: NotebookGraphic? = nil, textStyle: NativeTextStyle? = nil,
    parentID: String? = nil, basis: NotebookElementBasis? = nil, allGraphicFields: Bool = false) -> [String] {
    let fields = ["exists", "id", "frame", "content", "css", "javaScript", "state"]
      + (parentID != nil || allGraphicFields ? ["parentID"] : [])
      + (basis != nil || allGraphicFields ? ["basis"] : [])
    let base = fields.map {
      fieldKey(["elements", collaborationIdentity(id), $0])
    }
    let paths = allGraphicFields ? NotebookGraphic.allCausalPaths : (graphic?.causalPaths ?? [])
    return base + (textStyle != nil || allGraphicFields ? [fieldKey(["elements",collaborationIdentity(id),"textStyle"])] : []) + paths.map {
      fieldKey(["elements", collaborationIdentity(id), "graphic"] + $0)
    }
  }

  public let id: String
  public let kind: AgentElementKind
  public let frame: PageRect
  public let source: String
  public let html: String
  public let css: String
  public let javaScript: String
  public let programPackage: String?
  public let state: JSONValue
  public let graphic: NotebookGraphic?
  public let textStyle: NativeTextStyle?
  public let parentID: String?
  public let basis: NotebookElementBasis?

  public init(
    id: String,
    kind: AgentElementKind,
    frame: PageRect,
    source: String,
    html: String,
    css: String = "",
    javaScript: String = "",
    programPackage: String? = nil,
    state: JSONValue = .object([:]),
    graphic: NotebookGraphic? = nil,
    textStyle: NativeTextStyle? = nil,
    parentID: String? = nil,
    basis: NotebookElementBasis? = nil
  ) {
    precondition(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.id = id
    self.kind = kind
    self.frame = frame
    self.source = source
    self.html = html
    self.css = css
    self.javaScript = javaScript
    self.programPackage = programPackage
    self.state = state
    self.graphic = graphic
    self.textStyle = textStyle
    self.parentID = parentID; self.basis = basis
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
      programPackage: programPackage,
      state: state,
      graphic: graphic, textStyle: textStyle, parentID: parentID, basis: basis
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
      programPackage: programPackage,
      state: state,
      graphic: graphic, textStyle: textStyle, parentID: parentID, basis: basis
    )
  }
}

public struct PageDocument: Codable, Equatable, Identifiable, Sendable {
  public static let formatVersion = 1

  public let format: Int
  public let id: UUID
  public let size: PageSize
  private var storedDrawingData: Data
  private var storedDrawingStamp: VersionStamp
  public var drawingStamp: VersionStamp { inkDrawingCache.stamp(fallback:storedDrawingStamp) }
  public var drawingData: Data { (try? inkDrawingCache.data(fallback:storedDrawingData,stamp:drawingStamp)) ?? storedDrawingData }
  public private(set) var elements: [AgentElement] { didSet { elementProjectionCache = .init() } }
  public private(set) var agentStamp: VersionStamp { didSet { elementProjectionCache = .init() } }
  public private(set) var collaboration: CollaborativeContent? { didSet { elementProjectionCache = .init() } }
  private var elementProjectionCache = PageElementProjectionCache()
  private var inkDrawingCache = PageInkDrawingCache()
  /// Runtime identity of immutable element content; drawing and camera do not change it.
  public var elementSourceIdentity: ObjectIdentifier { ObjectIdentifier(elementProjectionCache) }
  var elementProjection: PageElementProjection { elementProjectionCache.value(for:self) }
  /// The archive is the durable boundary; this is its shared decoded runtime
  /// projection. Pending interaction may extend it without waiting for another
  /// archive serialization.
  public func inkDrawing() throws -> PageInkDrawing {
    try inkDrawingCache.value(for:storedDrawingData,stamp:drawingStamp)
  }
  public var inkSource:PageInkSource { .init(stamp:drawingStamp,data:storedDrawingData,cache:inkDrawingCache) }
  private enum CodingKeys: String,CodingKey {
    case format,id,size,drawingData,drawingStamp,elements,agentStamp,collaboration,computations
  }
  public static func == (a:Self,b:Self) -> Bool {
    a.format == b.format && a.id == b.id && a.size == b.size && a.drawingStamp == b.drawingStamp
      && (a.inkDrawingCache === b.inkDrawingCache || a.drawingData == b.drawingData)
      && a.elements == b.elements && a.agentStamp == b.agentStamp
      && a.collaboration == b.collaboration && a.computations == b.computations
  }
  public func element(id:String) -> AgentElement? { elementProjection.element(id) }
  /// Original painter order, with no scan of unrequested graphic sources.
  /// Other content keeps its specialized preparation/readiness owner.
  public func displayElements(graphicIDs:Set<String>) -> [AgentElement] {
    elementProjection.elements(graphicIDs:graphicIDs)
  }
  /// Absent until a user activates ink; not a second page or editor.
  public internal(set) var computations: [NotebookComputation]?

  /// Decoding and encoding happen before publication. The drawing stamp is the
  /// compare-and-swap boundary; unrelated element edits remain on this page.
  public func prepareInkChange(_ mutation: PageInkMutation, stamp: VersionStamp) throws -> PreparedPageInkChange {
    try Task.checkCancellation()
    let current = try inkDrawing()
    let drawing: PageInkDrawing, effective:PageInkMutation,changed:Bool
    switch mutation {
    case .append(let action):
      let previous=current.action(id:action.id)
      drawing = try current.appending(action)
      effective = drawing.action(id:action.id).map(PageInkMutation.append) ?? mutation
      changed = previous == nil
    case .remove(let ids):
      let active=Set(ids.filter { current.action(id:$0)?.isActive == true })
      drawing = current.removing(active);effective = .remove(active)
      changed = !active.isEmpty
    }
    guard changed else {
      return PreparedPageInkChange(pageID: id, baseStamp: drawingStamp,
        stamp: drawingStamp, drawing: current, mutation:effective, data:drawingData)
    }
    guard drawingStamp.counter < VersionStamp.maximumCounter,
      stamp.counter <= VersionStamp.maximumCounter else { throw PageInkDrawing.InkError.invalidDrawing }
    let next = VersionStamp(counter: max(drawingStamp.counter + 1, stamp.counter), actor: stamp.actor)
    try Task.checkCancellation()
    return PreparedPageInkChange(pageID: id, baseStamp: drawingStamp, stamp: next, drawing: drawing, mutation:effective)
  }

  @discardableResult
  public mutating func publishInkChange(_ change: PreparedPageInkChange) -> Bool {
    guard change.pageID == id, change.baseStamp == drawingStamp else { return false }
    storedDrawingData = Data()
    storedDrawingStamp = change.stamp
    inkDrawingCache = .init(change.drawing,stamp:change.stamp)
    return true
  }

  /// The live page and every mounted projection share one retained vector
  /// journal. Admission swaps only its persistent root; archive bytes remain
  /// lazy and SwiftUI does not need a whole-page publication for Pencil-up.
  @discardableResult
  public func publishLiveInkChange(_ change: PreparedPageInkChange) -> Bool {
    guard change.pageID == id, change.baseStamp == drawingStamp else { return false }
    return inkDrawingCache.publish(change)
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
    storedDrawingData = drawingData
    storedDrawingStamp = VersionStamp(counter: 0, actor: actor)
    self.elements = elements
    agentStamp = VersionStamp(counter: 0, actor: actor)
    let keys = ["elements/order"] + elements.flatMap { AgentElement.causalFieldKeys(id: $0.id, graphic: $0.graphic, textStyle: $0.textStyle, parentID: $0.parentID, basis: $0.basis) }
    collaboration = .init(fields: Dictionary(keys.map { ($0, ContentFieldVersion(stamp: agentStamp, human: true)) },
      uniquingKeysWith: { first, _ in first }))
    precondition(isValid)
  }

  public init(from decoder:Decoder) throws {
    let values=try decoder.container(keyedBy:CodingKeys.self)
    format=try values.decode(Int.self,forKey:.format);id=try values.decode(UUID.self,forKey:.id)
    size=try values.decode(PageSize.self,forKey:.size);storedDrawingData=try values.decode(Data.self,forKey:.drawingData)
    storedDrawingStamp=try values.decode(VersionStamp.self,forKey:.drawingStamp)
    elements=try values.decode([AgentElement].self,forKey:.elements)
    agentStamp=try values.decode(VersionStamp.self,forKey:.agentStamp)
    collaboration=try values.decodeIfPresent(CollaborativeContent.self,forKey:.collaboration)
    computations=try values.decodeIfPresent([NotebookComputation].self,forKey:.computations)
    guard isValid else { throw DecodingError.dataCorruptedError(forKey:.format,in:values,debugDescription:"Invalid page") }
  }

  public func encode(to encoder:Encoder) throws {
    var values=encoder.container(keyedBy:CodingKeys.self)
    try values.encode(format,forKey:.format);try values.encode(id,forKey:.id);try values.encode(size,forKey:.size)
    try values.encode(drawingData,forKey:.drawingData);try values.encode(drawingStamp,forKey:.drawingStamp)
    try values.encode(elements,forKey:.elements);try values.encode(agentStamp,forKey:.agentStamp)
    try values.encodeIfPresent(collaboration,forKey:.collaboration)
    try values.encodeIfPresent(computations,forKey:.computations)
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

    return Self.elementsAreValid(elements, in: size)
  }

  static func elementsAreValid(_ elements: [AgentElement], in size: PageSize) -> Bool {
    let ids = elements.map(\.id)
    return Set(ids).count == ids.count
      && elements.allSatisfy {
        !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && ($0.parentID == nil && $0.kind != .group ? $0.frame.isContained(in: size) : NotebookElementBasis.validLocalFrame($0.frame))
          && NotebookElementBasis.validParent($0.parentID,childID:$0.id)
          && $0.state.isValid
          && NotebookProgramPackage.validSourceReference($0.programPackage, isProgram: $0.kind == .web, source: $0.source, html: $0.html, css: $0.css, javaScript: $0.javaScript)
          && ($0.textStyle?.isValid(for:$0.source) ?? true)
          && ($0.kind == .nativeText || $0.textStyle == nil)
          && ($0.kind == .graphic ? $0.graphic?.isValid == true : $0.graphic == nil)
          && ($0.kind == .group ? $0.basis?.isValid == true && $0.source.isEmpty && $0.html.isEmpty
            && $0.css.isEmpty && $0.javaScript.isEmpty && $0.state == .object([:]) : ($0.basis?.isValid ?? true))
      }
  }

  /// An addressed edit must not advance the implicit clocks of unseen peers.
  /// Whole-page publication and offline preparation seal those clocks once,
  /// using their existing frontier, without authoring a content change.
  public func materializingCausalVersions() throws -> Self {
    var result = self, metadata = collaboration ?? CollaborativeContent()
    try metadata.materializeVersions(in: Self.elementContent(elements), fallback: agentStamp)
    result.collaboration = metadata
    guard result.isValid else { throw NotebookStorageError.invalidTransaction("page causal fields") }
    return result
  }

  private static func elementContent(_ elements: [AgentElement]) throws -> JSONValue {
    .object(["elements": try .encode(elements)])
  }

  @discardableResult
  public mutating func replaceDrawing(_ data: Data, actor: UUID) -> Bool {
    guard data != drawingData,
      let stamp = drawingStamp.advanced(by: actor)
    else { return false }
    guard let current = try? inkDrawing(),
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
  mutating func mergeDrawing(_ data: Data, stamp: VersionStamp) throws -> Bool {
    guard stamp.counter <= VersionStamp.maximumCounter else { throw PageInkDrawing.InkError.invalidDrawing }
    let incoming = try PageInkDrawing.decode(data)
    if data == drawingData {
      guard drawingStamp < stamp else { return false }
      storedDrawingStamp = stamp
      inkDrawingCache = .init(incoming,stamp:stamp)
      return true
    }
    let current = try inkDrawing()
    do {
      let merged = try current.merging(incoming)
      let frontier = max(drawingStamp, stamp)
      let winner = drawingStamp > stamp ? current : incoming
      let resolvedStamp = merged == winner ? frontier : (frontier.advanced(by: frontier.actor) ?? frontier)
      guard merged != current || drawingStamp != resolvedStamp else { return false }
      storedDrawingData = merged == current ? drawingData : merged == incoming ? data : try merged.dataRepresentation()
      storedDrawingStamp = resolvedStamp
      inkDrawingCache = .init(merged,stamp:resolvedStamp)
      return true
    } catch PageInkDrawing.InkError.incompatibleBaseline {
      // An explicit raster import is a whole-baseline revision; it is not an
      // instruction to ignore an action identity conflict on the same base.
    }
    guard drawingStamp < stamp else { return false }
    storedDrawingData = data
    storedDrawingStamp = stamp
    inkDrawingCache = .init(incoming,stamp:stamp)
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
    guard let before = try? Self.elementContent(self.elements),
      let after = try? Self.elementContent(elements) else { return false }
    metadata.record(before: before, after: after,
      beforeStamp: agentStamp, stamp: stamp, human: true)
    candidate.collaboration = metadata
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
    let local = try Self.elementContent(candidate.elements)
    let incoming = try Self.elementContent(other.elements)
    let merged = try CollaborativeContent.merge(local: local, incoming: incoming,
      localState: collaboration, incomingState: other.collaboration,
      localStamp: agentStamp, incomingStamp: other.agentStamp)
    guard let elements = merged.value["elements"] else { throw NotebookStorageError.transactionConflict }
    candidate.elements = try elements.decode([AgentElement].self)
    candidate.collaboration = merged.state
    candidate.agentStamp = mergedContentStamp(local: local, incoming: incoming, result: merged.value,
      localStamp: agentStamp, incomingStamp: other.agentStamp)
    guard candidate.isValid else { throw NotebookStorageError.transactionConflict }
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

/// A page source carries the already decoded runtime value when one exists.
/// Opening a cold page still decodes off-main; publishing a contact never has
/// to serialize it merely to notify the mounted canvas.
public struct PageInkSource:Sendable {
  public let stamp:VersionStamp
  private let data:Data
  private let cache:PageInkDrawingCache
  fileprivate init(stamp:VersionStamp,data:Data,cache:PageInkDrawingCache) {
    self.stamp=stamp;self.data=data;self.cache=cache
  }
  public func drawing() throws -> PageInkDrawing { try cache.value(for:data,stamp:stamp) }
}

private final class PreparedPageInkArchive:@unchecked Sendable {
  private let lock=NSLock()
  private let drawing:PageInkDrawing
  private var prepared:Data?
  init(_ drawing:PageInkDrawing,data:Data?=nil) { self.drawing=drawing;prepared=data }
  func value()->Data { lock.withLock { if let prepared { return prepared };let data=try! drawing.dataRepresentation();prepared=data;return data } }
}

/// A validated result prepared away from the input thread. Its constructor is
/// private to the page owner, so publication never needs to decode the archive.
public struct PreparedPageInkChange: Sendable {
  public let pageID: UUID
  public let baseStamp: VersionStamp
  public let stamp: VersionStamp
  public let drawing: PageInkDrawing
  public let mutation:PageInkMutation
  private let archive:PreparedPageInkArchive
  public var data:Data { archive.value() }

  fileprivate init(pageID: UUID, baseStamp: VersionStamp, stamp: VersionStamp, drawing: PageInkDrawing,
    mutation:PageInkMutation,data:Data?=nil) {
    self.pageID = pageID; self.baseStamp = baseStamp; self.stamp = stamp
    self.drawing = drawing;self.mutation=mutation;archive = .init(drawing,data:data)
  }
}
