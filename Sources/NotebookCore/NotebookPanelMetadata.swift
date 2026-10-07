import Foundation

/// Finite metadata needed by a presented panel. Cursors discover commits;
/// addressed content, navigation and Undo decide whether its scene changed.
public struct NotebookPanelMetadata: Equatable, Sendable {
  public let workspaceID: UUID
  public let target: CollaborationTarget
  public let readCursor: UInt64
  public let changeCursor: UInt64
  public let sourceRevision: String
  public let basis: NotebookReadBasis
  public let navigation: JSONValue
  public let history: JSONValue

  public func hasSameScene(as other: Self) -> Bool {
    workspaceID == other.workspaceID && target == other.target && sourceRevision == other.sourceRevision
      && basis == other.basis && history == other.history
      && (navigation == other.navigation || navigationSceneIdentity == other.navigationSceneIdentity)
  }

  /// Directory read clocks attest a WAL cut. Only addressed order, selection
  /// and page metadata belong to the scene; wire values retain every clock.
  private var navigationSceneIdentity: JSONValue {
    guard case .object = navigation else { return navigation }
    func withoutReadClock(_ value: JSONValue) -> JSONValue {
      guard case .object = value else { return value }
      return value.setting("readCursor", nil)
    }
    var identity = navigation
    if let position = navigation["position"] { identity = identity.setting("position", withoutReadClock(position)) }
    if var directory = navigation["directory"], case .object = directory {
      if let header = directory["header"] { directory = directory.setting("header", withoutReadClock(header)) }
      if case .array(let pages)? = directory["pages"] {
        directory = directory.setting("pages", .array(pages.map { page in
          guard let position = page["position"] else { return page }
          return page.setting("position", withoutReadClock(position))
        }))
      }
      identity = identity.setting("directory", directory)
    }
    return identity
  }

  public func updating(_ snapshot: JSONValue) throws -> JSONValue {
    snapshot.setting("cursor", .string(String(readCursor))).setting("basis", try .encode(basis))
      .setting("history", history).setting("navigation", navigation)
  }
}

extension NotebookStore {
  public func readPanelMetadata(workspaceID: UUID, target: CollaborationTarget, actor: UUID) throws -> NotebookPanelMetadata {
    try readTransaction { _ in
      guard try storedWorkspaceID() == workspaceID,
        [.page, .board].contains(target.kind), target.boardID == nil else {
        throw CollaborationError("invalid_panel_surface", "Метаданным панели нужен адрес её пространства и поверхности.")
      }
      if target.kind == .board { try requireLiveBoard(target.id) }
      else { _ = try readContentHeader(target: target) }
      var navigation: JSONValue = .null
      if target.kind == .page, let itemID = try ownerItemID(ofPage: target.id),
        let boardID = try ownerBoardID(of: itemID), let position = try resolveNotebookPage(target.id, in: itemID) {
        navigation = .object(["parentBoard": try .encode(CollaborationTarget(kind: .board, id: boardID)),
          "itemID": try .encode(itemID), "position": try .encode(position),
          "directory": try .encode(readNotebookPageDirectory(itemID: itemID, from: max(0, position.index - 1), limit: 3))])
      }
      var history: [String: JSONValue] = [:]
      if case .command(let actionID)? = try nativeHistory(domain: .init(target), actor: actor).last {
        let head = try actionReadModel(actionID)
        if head.author == .human, head.action.operations.allSatisfy({ $0.target == target }) {
          history["undoActionID"] = try .encode(actionID)
        }
      }
      return try .init(workspaceID: workspaceID, target: target,
        readCursor: currentReadCursor(), changeCursor: currentChangeCursor(),
        sourceRevision: referenceRevision(target: target), basis: readBasis(targets: [target], includeSource: true),
        navigation: navigation, history: .object(history))
    }
  }
}
