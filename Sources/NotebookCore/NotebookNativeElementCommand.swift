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

extension NotebookStore {
  private func pageElementCommandProjection(pageID: UUID, elementID: String) throws -> JSONValue {
    let file = pageFile(pageID), root = file + "#", id = collaborationIdentity(elementID)
    let addresses = [(root, false), (root + "/elements/@" + fieldKey([id]), true)]
      + (["elements/order"] + AgentElement.causalFieldKeys(id: id, allGraphicFields: true)).map {
        (root + "/collaboration/fields/@" + fieldKey([$0]), false)
      }
    let rows = try boundedStoredFragments(addresses, maximumCount: 4096, maximumBytes: 4 * 1024 * 1024,
      budget: "page_element_command").map { row in
        row.parent == nil ? row.replacing(value: row.value,
        collections: row.collections.filter { ![["drawingData"], ["computations"]].contains($0.path) }) : row
      }
    return try NotebookRecordCodec.decode(rows, root: root)
  }

  /// A stopped browser model may retire only after this source/state-guarded
  /// write commits. Geometry is read from storage, never rolled back by a frame.
  public func checkpointProgramState(target: CollaborationTarget, rendered: AgentElement,
    state: JSONValue, basis: NotebookProgramStateBasis, actor: UUID) throws -> NotebookProgramStateBasis? {
    guard state.isValid, rendered.kind == .web else { throw NotebookStorageError.invalidTransaction("program checkpoint") }
    return try commandTransaction {
      switch target.kind {
      case .page:
        guard try ownerItemID(ofPage: target.id) != nil else { return nil }
        let before = try pageElementCommandProjection(pageID: target.id, elementID: rendered.id)
        let page = try before.decode(NotebookPageElementProjection.self)
        guard basis == NotebookProgramStateBasis(elementID: rendered.id, metadata: page.collaboration, fallback: page.agentStamp) else { return nil }
        guard let element = page.elements.first(where: { $0.id == rendered.id }),
          element.kind == rendered.kind, element.source == rendered.source, element.html == rendered.html,
          element.css == rendered.css, element.javaScript == rendered.javaScript, element.programPackage == rendered.programPackage,
          element.state == rendered.state else { return nil }
        if element.state == state { return basis }
        guard let stamp = page.agentStamp.advanced(by: actor) else { throw NotebookStorageError.limitExceeded("page clock") }
        var after = try before.setting("elements", .encode([element.updating(state: state)])).setting("agentStamp", .encode(stamp))
        var metadata = page.collaboration
        metadata.record(before: before, after: after, beforeStamp: page.agentStamp, stamp: stamp, human: true)
        after = try after.setting("collaboration", .encode(metadata))
        try publishProjectionEdits(file: pageFile(target.id), before: before, after: after)
        return .init(elementID: rendered.id, metadata: metadata, fallback: stamp)
      case .board:
        guard let before = try spatialElementProjection(boardID: target.id, elementID: rendered.id),
          let board = before.board(target.id), basis == board.programStateBasis(rendered.id),
          var element = board.elements.first,
          element.kind == .web, element.source == rendered.source, element.html == rendered.html,
          element.css == rendered.css, element.javaScript == rendered.javaScript, element.programPackage == rendered.programPackage,
          element.state == rendered.state else { return nil }
        if element.state == state { return basis }
        let expected = element.stamp
        var after = before
        guard element.update(state: state, actor: actor),
          after.upsertElement(element, in: target.id, expected: expected, actor: actor) else {
          throw NotebookStorageError.transactionConflict
        }
        _ = try saveBoardEdits(before: before, after: after)
        return try spatialElementProjection(boardID: target.id, elementID: rendered.id)?.board(target.id)?.programStateBasis(rendered.id)
      default: throw NotebookStorageError.invalidTransaction("program checkpoint target")
      }
    }
  }

  @discardableResult
  public func moveWorkspaceItem(itemID: UUID, in boardID: UUID, to center: WorldPoint, actor: UUID) throws -> Bool {
    guard center.isValid else { throw NotebookStorageError.invalidTransaction("item center") }
    return try commandTransaction {
      guard let node = try readBoardItem(itemID), node.id == boardID else { return false }
      let header = try workspaceHeader()
      let before = BoardHierarchy(rootBoardID: header.rootBoardID, boards: [node], stamp: header.boardStamp ?? node.board.stamp)
      var after = before
      guard after.moveItem(itemID, in: boardID, to: center, actor: actor) else { return false }
      _ = try saveBoardEdits(before: before, after: after)
      return true
    }
  }

  private func spatialElementProjection(boardID: UUID, elementID: String) throws -> BoardHierarchy? {
    guard try isLiveBoard(boardID) else { return nil }
    let node = "board.json#/boards/@" + boardID.uuidString.lowercased()
    guard try !storedFragments(address: node, descendants: false).isEmpty else { return nil }
    let elementRows = try storedFragments(address: node + "/board/elements/@" + fieldKey([collaborationIdentity(elementID)]))
    guard !elementRows.isEmpty else { return nil }
    if let surface = try elementRows.first?.value["surface"]?.decode(SurfaceID.self), surface.kind == .cover {
      guard let item = surface.ownerID, try ownerBoardID(of: item) == boardID else { return nil }
    }
    var rows = try storedFragments(address: "board.json#", descendants: false)
    rows += try storedFragments(address: node, descendants: false)
    rows += elementRows
    try appendBoardCausalFragments(to: &rows, address: node)
    return try NotebookRecordCodec.decode(rows, root: "board.json#").decode(BoardHierarchy.self)
  }

  /// The rendered program, not its former frame or state, authorizes an input
  /// message. Geometry and independent state already on disk are read here.
  @discardableResult
  public func commitSpatialElementState(boardID: UUID, rendered: SpatialElement,
    state: JSONValue, actor: UUID) throws -> SpatialElement? {
    guard state.isValid else { throw NotebookStorageError.invalidTransaction("element state") }
    return try commandTransaction {
      guard let before = try spatialElementProjection(boardID: boardID, elementID: rendered.id),
        var element = before.board(boardID)?.elements.first else { return nil }
      guard element.surface == rendered.surface, element.kind == rendered.kind,
        element.source == rendered.source, element.html == rendered.html,
        element.css == rendered.css, element.javaScript == rendered.javaScript, element.programPackage == rendered.programPackage else {
        throw CollaborationError("source_conflict", "Сообщение принадлежит прежней программе элемента.")
      }
      guard element.state != state else { return element }
      let expected = element.stamp
      var after = before
      guard element.update(state: state, actor: actor), after.upsertElement(element, in: boardID, expected: expected, actor: actor) else {
        throw NotebookStorageError.transactionConflict
      }
      _ = try saveBoardEdits(before: before, after: after)
      return element
    }
  }
}
