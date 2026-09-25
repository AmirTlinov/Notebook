import Foundation

/// The authored source and state read by a browser, not an aggregate page clock.
/// Geometry edits do not invalidate it; an A -> B -> A edit or recreation does.
public struct NotebookProgramStateBasis: Equatable, Sendable {
  let fields: [String: ContentFieldVersion]
  private let stateKey: String

  init(elementID: String, metadata: CollaborativeContent?, fallback: VersionStamp) {
    let id = collaborationIdentity(elementID)
    stateKey = fieldKey(["elements", id, "state"])
    fields = Dictionary(uniqueKeysWithValues: ["id", "content", "css", "javaScript", "state"].map {
      let key = fieldKey(["elements", id, $0])
      return (key, metadata?.fields[key] ?? .init(stamp: fallback, human: true))
    })
  }

  public func hasSameSource(as other: Self) -> Bool {
    fields.filter { $0.key != stateKey } == other.fields.filter { $0.key != other.stateKey }
  }

  public func hasNewerState(than other: Self) -> Bool {
    guard hasSameSource(as: other), let current = fields[stateKey], let previous = other.fields[other.stateKey] else { return false }
    return current.includes(previous) && !previous.includes(current)
  }

}

extension PageDocument {
  public func programStateBasis(_ id: String) -> NotebookProgramStateBasis? {
    guard elements.contains(where: { $0.id == id && $0.kind == .web }) else { return nil }
    return .init(elementID: id, metadata: collaboration, fallback: agentStamp)
  }

  public func elementIdentityStamp(_ id: String) -> VersionStamp? {
    guard elements.contains(where: { collaborationIdentity($0.id) == collaborationIdentity(id) }) else { return nil }
    return collaboration?.fields[fieldKey(["elements", collaborationIdentity(id), "id"])]?.stamp ?? agentStamp
  }
}

extension BoardDocument {
  public func programStateBasis(_ id: String) -> NotebookProgramStateBasis? {
    guard element(id:id)?.kind == .web else { return nil }
    return .init(elementID: id, metadata: collaboration, fallback: stamp)
  }

  public func elementIdentityStamp(_ id: String) -> VersionStamp? {
    guard elements.contains(where: { collaborationIdentity($0.id) == collaborationIdentity(id) }) else { return nil }
    return collaboration?.fields[fieldKey(["elements", collaborationIdentity(id), "id"])]?.stamp ?? stamp
  }
}

/// One admitted page-program value, including its already chosen causal dot.
/// No ink, other element, geometry or page archive enters the writer queue.
public struct NotebookPageProgramStateCommand: Sendable {
  public let pageID: UUID
  let elementID: String
  let state: JSONValue
  let basis: NotebookProgramStateBasis
  let stamp: VersionStamp
  let versions: [String: ContentFieldVersion]
  public let expectedBasis: NotebookProgramStateBasis

  public init?(before: PageDocument, after: PageDocument, elementID: String) {
    guard before.id == after.id, let basis = before.programStateBasis(elementID),
      let expected = after.programStateBasis(elementID), basis.hasSameSource(as: expected),
      let element = after.elements.first(where: { $0.id == elementID }) else { return nil }
    pageID = after.id; self.elementID = elementID; state = element.state
    self.basis = basis; expectedBasis = expected; stamp = after.agentStamp
    versions = Dictionary(uniqueKeysWithValues: ["state", "exists"].compactMap { field in
      let key = fieldKey(["elements", collaborationIdentity(elementID), field])
      return after.collaboration?.fields[key].map { (key, $0) }
    })
  }
}

/// Durable publication and permission to adopt its value are independent:
/// a losing concurrent value can still add causal knowledge to the journal.
public struct NotebookPageProgramStateReceipt: Sendable {
  public let basis: NotebookProgramStateBasis?
  public let changed: Bool
}

public struct NotebookSpatialProgramStateReceipt: Sendable {
  public let element: SpatialElement
  public let basis: NotebookProgramStateBasis
}

extension NotebookStore {
  private func pageElementCommandProjection(pageID: UUID, elementID: String, admittedStateBytes: Int? = nil) throws -> JSONValue {
    let file = pageFile(pageID), root = file + "#", id = collaborationIdentity(elementID)
    let elementAddress = root + "/elements/@" + fieldKey([id])
    let metadata = [(root, false)]
      + (["elements/order"] + AgentElement.causalFieldKeys(id: id, allGraphicFields: true)).map {
        (root + "/collaboration/fields/@" + fieldKey([$0]), false)
      }
    let rows = try programElementCommandFragments(metadata: metadata, elementAddress: elementAddress,
      admittedStateBytes: admittedStateBytes, budget: "page_element_command")
    return try NotebookRecordCodec.decode(rows.map { row in
      row.parent == nil ? row.replacing(value: row.value,
        collections: row.collections.filter { ![["drawingData"], ["computations"]].contains($0.path) }) : row
    }, root: root)
  }

  /// The admitted immutable transfer owns the current value's memory until
  /// durability. Source and metadata retain their ordinary addressed budget.
  /// Both page and spatial commands borrow that credit, never reserve it again.
  private func programElementCommandFragments(metadata: [(String, Bool)], elementAddress: String,
    admittedStateBytes: Int?, budget: String) throws -> [NotebookStoredFragment] {
    let sourceLimit = 4 * 1024 * 1024
    guard let admittedStateBytes else {
      return try boundedStoredFragments(metadata + [(elementAddress, true)], maximumCount: 4096,
        maximumBytes: Int64(sourceLimit), budget: budget)
    }
    guard admittedStateBytes > 0, admittedStateBytes <= Int.max - sourceLimit * 8 else {
      throw NotebookStorageError.limitExceeded("program_state_admission")
    }
    let headers = try boundedStoredFragments(metadata, maximumCount: 4096, maximumBytes: Int64(sourceLimit), budget: budget)
    let element = try programStateFragments(address: elementAddress, admittedBytes: admittedStateBytes + sourceLimit * 8)
    let encoder = JSONEncoder()
    var sourceBytes = 0, sourceRows = 0
    for row in headers + element where !row.address.hasPrefix(elementAddress + "/state/") {
      let source = row.address == elementAddress ? row.replacing(value: row.value.setting("state", .null),
        collections: row.collections.filter { $0.path.first != "state" }) : row
      sourceBytes += try encoder.encode(source).count; sourceRows += 1
      guard sourceBytes <= sourceLimit, sourceRows <= 4096 else { throw NotebookStorageError.limitExceeded(budget) }
    }
    return headers + element
  }

  @discardableResult
  public func commitPageProgramState(_ command: NotebookPageProgramStateCommand, admittedStateBytes: Int? = nil) throws -> NotebookPageProgramStateReceipt {
    guard command.state.isValid, command.versions.count == 2, command.versions.values.allSatisfy(\.isValid),
      command.stamp.counter <= VersionStamp.maximumCounter else { throw NotebookStorageError.invalidTransaction("page program state") }
    return try commandTransaction {
      guard try ownerItemID(ofPage: command.pageID) != nil else { return .init(basis: nil, changed: false) }
      let before = try pageElementCommandProjection(pageID: command.pageID, elementID: command.elementID, admittedStateBytes: admittedStateBytes)
      let page = try before.decode(NotebookPageElementProjection.self)
      let storedBasis = NotebookProgramStateBasis(elementID: command.elementID, metadata: page.collaboration, fallback: page.agentStamp)
      guard command.basis.hasSameSource(as: storedBasis),
        let element = page.elements.first(where: { $0.id == command.elementID && $0.kind == .web }) else { return .init(basis: nil, changed: false) }
      return try commitPageProgramState(before: before, page: page, element: element, state: command.state,
        stamp: command.stamp, versions: command.versions)
    }
  }

  /// A browser's already accepted FIFO message remains addressed after its page
  /// leaves the render window. Only captured source identity authorizes it; no
  /// archive/page load or current camera participates in this durable write.
  @discardableResult
  public func commitPageProgramState(pageID: UUID, elementID: String, state: JSONValue,
    basis: NotebookProgramStateBasis, actor: UUID, admittedStateBytes: Int? = nil) throws -> NotebookPageProgramStateReceipt {
    guard state.isValid else { throw NotebookStorageError.invalidTransaction("page program state") }
    return try commandTransaction {
      guard try ownerItemID(ofPage: pageID) != nil else { return .init(basis: nil, changed: false) }
      let before = try pageElementCommandProjection(pageID: pageID, elementID: elementID, admittedStateBytes: admittedStateBytes)
      let page = try before.decode(NotebookPageElementProjection.self)
      let current = NotebookProgramStateBasis(elementID: elementID, metadata: page.collaboration, fallback: page.agentStamp)
      guard basis.hasSameSource(as: current), let element = page.elements.first(where: { $0.id == elementID && $0.kind == .web }) else { return .init(basis: nil, changed: false) }
      return try commitPageProgramState(before: before, page: page, element: element, state: state,
        stamp: page.agentStamp.advanced(by: actor))
    }
  }

  /// One causal merge/publisher for optimistic events, cold accepted events and
  /// frozen checkpoints. The optimistic command keeps its already chosen dot.
  private func commitPageProgramState(before: JSONValue, page: NotebookPageElementProjection, element: AgentElement,
    state: JSONValue, stamp: VersionStamp?, versions: [String: ContentFieldVersion]? = nil) throws -> NotebookPageProgramStateReceipt {
    if versions == nil, element.state == state {
      return .init(basis: .init(elementID: element.id, metadata: page.collaboration, fallback: page.agentStamp), changed: false)
    }
    guard let stamp else { throw NotebookStorageError.limitExceeded("page clock") }
    let incoming = try before.setting("elements", .encode([element.updating(state: state)]))
    var metadata = page.collaboration
    if let versions {
      var fields = metadata.fields
      for (key, version) in versions { fields[key] = version }
      metadata = .init(fields: fields)
    } else { metadata.record(before: before, after: incoming, beforeStamp: page.agentStamp, stamp: stamp, human: true) }
    let merged = try CollaborativeContent.merge(local: before, incoming: incoming,
      localState: page.collaboration, incomingState: metadata, localStamp: page.agentStamp, incomingStamp: stamp)
    let finalStamp = mergedContentStamp(local: before, incoming: incoming, result: merged.value,
      localStamp: page.agentStamp, incomingStamp: stamp)
    let after = try merged.value.setting("agentStamp", .encode(finalStamp)).setting("collaboration", .encode(merged.state))
    let changed = try publishProjectionEdits(file: pageFile(page.id), before: before, after: after)
    // Receiving another winner's version cannot authorize this browser's old
    // heap to overwrite that winner with its next lifecycle checkpoint.
    guard merged.value["elements"]?.array.first(where: { $0["id"]?.string == element.id })?["state"] == state else { return .init(basis: nil, changed: changed) }
    return .init(basis: .init(elementID: element.id, metadata: merged.state, fallback: finalStamp), changed: changed)
  }

  /// A stopped browser model may retire only after this source/state-guarded
  /// write commits. Geometry is read from storage, never rolled back by a frame.
  public func checkpointProgramState(target: CollaborationTarget, rendered: AgentElement,
    state: JSONValue, basis: NotebookProgramStateBasis, actor: UUID, admittedStateBytes: Int? = nil) throws -> NotebookProgramStateBasis? {
    guard state.isValid, rendered.kind == .web else { throw NotebookStorageError.invalidTransaction("program checkpoint") }
    return try commandTransaction {
      switch target.kind {
      case .page:
        guard try ownerItemID(ofPage: target.id) != nil else { return nil }
        let before = try pageElementCommandProjection(pageID: target.id, elementID: rendered.id, admittedStateBytes: admittedStateBytes)
        let page = try before.decode(NotebookPageElementProjection.self)
        guard basis == NotebookProgramStateBasis(elementID: rendered.id, metadata: page.collaboration, fallback: page.agentStamp) else { return nil }
        guard let element = page.elements.first(where: { $0.id == rendered.id }),
          element.kind == rendered.kind, element.source == rendered.source, element.html == rendered.html,
          element.css == rendered.css, element.javaScript == rendered.javaScript, element.programPackage == rendered.programPackage,
          element.state == rendered.state else { return nil }
        return try commitPageProgramState(before: before, page: page, element: element, state: state,
          stamp: page.agentStamp.advanced(by: actor)).basis
      case .board:
        guard let before = try spatialElementProjection(boardID: target.id, elementID: rendered.id, admittedStateBytes: admittedStateBytes),
          let board = before.board(target.id), basis == board.programStateBasis(rendered.id),
          let element = board.elements.first,
          element.kind == .web, element.source == rendered.source, element.html == rendered.html,
          element.css == rendered.css, element.javaScript == rendered.javaScript, element.programPackage == rendered.programPackage,
          element.state == rendered.state else { return nil }
        return try commitSpatialProgramState(before: before, boardID: target.id, element: element,
          state: state, actor: actor)?.basis
      default: throw NotebookStorageError.invalidTransaction("program checkpoint target")
      }
    }
  }

  private func spatialElementProjection(boardID: UUID, elementID: String, admittedStateBytes: Int?) throws -> BoardHierarchy? {
    guard try isLiveBoard(boardID) else { return nil }
    let node = "board.json#/boards/@" + boardID.uuidString.lowercased(), id = collaborationIdentity(elementID)
    let elementAddress = node + "/board/elements/@" + fieldKey([id])
    let keys = ["elements/order"] + AgentElement.causalFieldKeys(id: id, allGraphicFields: true)
      + ["surface", "worldOrigin", "stamp"].map { fieldKey(["elements", id, $0]) }
    let metadata = [("board.json#", false), (node, false)] + keys.map {
      (node + "/board/collaboration/fields/@" + fieldKey([$0]), false)
    }
    let rows = try programElementCommandFragments(metadata: metadata, elementAddress: elementAddress,
      admittedStateBytes: admittedStateBytes, budget: "spatial_element_command")
    guard let element = rows.first(where: { $0.address == elementAddress }) else { return nil }
    if let surface = try element.value["surface"]?.decode(SurfaceID.self), surface.kind == .cover {
      guard let item = surface.ownerID, try ownerBoardID(of: item) == boardID else { return nil }
    }
    return try NotebookRecordCodec.decode(rows, root: "board.json#").decode(BoardHierarchy.self)
  }

  /// Event and frozen checkpoint write the same addressed state owner. The
  /// caller has checked its source, and a checkpoint also its exact state basis.
  private func commitSpatialProgramState(before: BoardHierarchy, boardID: UUID, element: SpatialElement,
    state: JSONValue, actor: UUID) throws -> NotebookSpatialProgramStateReceipt? {
    guard element.state != state else {
      return before.board(boardID)?.programStateBasis(element.id).map { .init(element: element, basis: $0) }
    }
    let expected = element.stamp
    var after = before, element = element
    guard element.update(state: state, actor: actor), after.upsertElement(element, in: boardID, expected: expected, actor: actor) else {
      throw NotebookStorageError.transactionConflict
    }
    let saved = try saveBoardEdits(before: before, after: after)
    guard let basis = saved.board(boardID)?.programStateBasis(element.id) else { return nil }
    return .init(element: element, basis: basis)
  }

  /// The rendered program, not its former frame or state, authorizes an input
  /// message. Geometry and independent state already on disk are read here.
  @discardableResult
  public func commitSpatialElementState(boardID: UUID, rendered: SpatialElement,
    state: JSONValue, actor: UUID, expectedProgramBasis: NotebookProgramStateBasis,
    admittedStateBytes: Int? = nil) throws -> NotebookSpatialProgramStateReceipt? {
    guard state.isValid else { throw NotebookStorageError.invalidTransaction("element state") }
    return try commandTransaction {
      guard let before = try spatialElementProjection(boardID: boardID, elementID: rendered.id, admittedStateBytes: admittedStateBytes),
        let board = before.board(boardID), let element = board.elements.first else { return nil }
      guard let current = board.programStateBasis(rendered.id), expectedProgramBasis.hasSameSource(as: current) else {
        throw CollaborationError("source_conflict", "Сообщение принадлежит прежней программе элемента.")
      }
      guard element.surface == rendered.surface, element.kind == rendered.kind,
        element.source == rendered.source, element.html == rendered.html,
        element.css == rendered.css, element.javaScript == rendered.javaScript, element.programPackage == rendered.programPackage else {
        throw CollaborationError("source_conflict", "Сообщение принадлежит прежней программе элемента.")
      }
      return try commitSpatialProgramState(before: before, boardID: boardID, element: element, state: state, actor: actor)
    }
  }
}
