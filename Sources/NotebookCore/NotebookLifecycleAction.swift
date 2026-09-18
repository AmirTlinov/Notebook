import Foundation

/// A compact domain effect. The inverse holds raw pre-action evidence, never
/// a projected notebook or one giant collection of removed page bodies.
public struct NotebookLifecycleChange: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case appendPage, deleteItem }
  public let kind: Kind
  public let target: CollaborationTarget
  public let pageID: UUID?
  public let beforeItem: NotebookItemHeader?
  public let afterItem: NotebookItemHeader?
}

/// Only successfully published undo groups appear here. A preserved group
/// never masquerades as the original append/deletion being executed again.
public struct NotebookLifecycleUndoChange: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case restoreItem, removePage }
  public let kind: Kind
  public let target: CollaborationTarget
  public let pageID: UUID?
  public let item: NotebookItemHeader?
}

struct NotebookLifecycleUndoResult {
  var changes: [NotebookLifecycleUndoChange] = []
  var preserved: [CollaborationTarget] = []
  var restorationInverse: NotebookLifecycleInverseReference?
}

extension NotebookSQLConnection {
  func noteActionLifecycleFile(_ file: String, itemID: UUID) throws {
    guard let capture = activeActionRecordCapture else { return }
    try noteOwner(.actionLifecycleFile, capture.key + "|" + file, value: itemID.uuidString.lowercased())
  }

  func noteActionLifecycleElement(boardID: UUID, elementID: String, itemID: UUID) throws {
    guard let capture = activeActionRecordCapture else { return }
    try noteOwner(.actionLifecycleElement,
      capture.key + "|" + boardID.uuidString.lowercased() + "|" + collaborationIdentity(elementID), value: itemID.uuidString.lowercased())
  }
}

extension NotebookStore {
  /// The original action's CAS and scope remain in the single action loop.
  /// These branches call exactly the content owners used by native commands.
  func applyLifecycleOperation(_ operation: CollaborationOperation, actor: UUID, human: Bool) throws -> [CollaborationTarget] {
    let target = operation.target
    guard target.kind == .cover, let parentID = target.boardID,
      try ownerBoardID(of: target.id) == parentID else { throw CollaborationError("target_missing", "Предмет отсутствует на указанной доске.", target: target) }
    let rootID = try workspaceHeader().rootBoardID
    switch operation.kind {
    case .appendPage:
      guard let pageID = operation.id.flatMap(UUID.init(uuidString:)), operation.values.isEmpty,
        let item = try readItemHeader(target.id), item.kind == .notebook, let firstID = item.firstPageID else {
        throw CollaborationError("invalid_operation", "Добавление листа называет тетрадь и новый UUID листа без полей замены каталога.")
      }
      let header = try readContentHeader(target: .init(kind: .page, id: firstID))
      guard let size = header.size else { throw NotebookStorageError.corruptRecord("notebook page size") }
      let admission = try makePageAppendAdmission(itemID: target.id, pageID: pageID, actor: actor, human: human)
      try currentSQL!.noteActionLifecycleFile(pageFile(pageID), itemID: target.id)
      try publishPageAppend(page: .init(id: pageID, size: size, actor: actor), admission: admission, human: human)
      return [.init(kind: .workspace, id: rootID), target, .init(kind: .page, id: pageID)]
    case .deleteItem:
      guard operation.id == nil, operation.values.isEmpty else { throw CollaborationError("invalid_operation", "Удаление называет только физическую обложку предмета.") }
      do {
        try deleteWorkspaceItemContent(itemID: target.id, actor: actor, human: human)
      } catch NotebookStoreError.boardContainsContent(_) {
        throw CollaborationError("board_not_empty",
          "Доска содержит предметы, элементы или чернила. Сначала явно удалите или перенесите её содержимое; дочерние предметы не удаляются автоматически.",
          target: target)
      }
      return [.init(kind: .workspace, id: rootID), .init(kind: .board, id: parentID)]
    default: throw CollaborationError("invalid_operation", "Нужна операция жизненного цикла предмета.")
    }
  }

  func coalesceCreatedNotebookSources(_ action: CollaborationAction, before: CollaborationWorkspace,
    after: CollaborationWorkspace, evidence: inout [String: JSONValue]) throws {
    for operation in action.operations where operation.kind == .createNotebook {
      guard let id = operation.id.flatMap(UUID.init(uuidString:)) else { continue }
      let path: [CollaborationPathComponent] = [.field("items"), .member(id.uuidString.lowercased())]
      guard before.files["workspace.json"]?.value(at: path[...]) == nil,
        let item = after.files["workspace.json"]?.value(at: path[...]) else { continue }
      evidence["workspace.json"] = evidence["workspace.json"]?.setting(at: path[...], to: item)
      // These are only this action's at-most-513 newly born pages, never an
      // expansion of an existing notebook's immutable page-order prefix.
      for value in item["pageIDs"]?.array ?? [] {
        guard let page = value.string.flatMap(UUID.init(uuidString:)),
          let source = after.files[pageFile(page)] else {
          throw NotebookStorageError.invalidTransaction("created notebook page source")
        }
        evidence[pageFile(page)] = source
      }
    }
  }

  func lifecycleOwns(_ change: CollaborationFieldChange, action: CollaborationAction) throws -> Bool {
    let deleted = Set(action.operations.filter { $0.kind == .deleteItem }.map { $0.target.id.uuidString.lowercased() })
    if let owner = try currentSQL!.ownerValue(.actionLifecycleFile, action.id.uuidString.lowercased() + "|" + change.file) {
      // A notebook born in this action has one creation owner, including the
      // additional pages composed before its first publication.
      let createdHere = action.operations.contains { $0.kind == .createNotebook && $0.id.map(collaborationIdentity) == owner }
      return !createdHere || deleted.contains(owner)
    }
    let path = change.path
    if change.file == "workspace.json", path.first == .field("items") {
      if path.dropFirst().first == .order { return !deleted.isEmpty }
      if path.count >= 2, case .member(let id) = path[1] { return deleted.contains(collaborationIdentity(id)) }
    }
    if change.file == "board.json", path.count >= 2, case .member(let boardID) = path[1] {
      // The board node now retains its ordinary source. Edits performed
      // before deletion belong to conditional field undo, not lifecycle replay.
      if path.count >= 5, case .member(let member) = path[4] {
        if path[3] == .field("placements") { return deleted.contains(collaborationIdentity(member)) }
        if path[3] == .field("elements") {
          return try currentSQL!.ownerValue(.actionLifecycleElement,
            action.id.uuidString.lowercased() + "|" + collaborationIdentity(boardID) + "|" + collaborationIdentity(member)) != nil
        }
      }
    }
    return false
  }

  func lifecycleChanges(_ action: CollaborationAction, before: [UUID: NotebookItemHeader]) throws -> [NotebookLifecycleChange] {
    let deleted = Set(action.operations.filter { $0.kind == .deleteItem }.map(\.target.id))
    var result: [NotebookLifecycleChange] = []
    for operation in action.operations where operation.isLifecycle {
      let prior = before[operation.target.id], after = try readItemHeader(operation.target.id)
      if operation.kind == .deleteItem {
        guard prior != nil else { continue } // A transient birth is never an undo resurrection.
        result.append(.init(kind: .deleteItem, target: operation.target, pageID: nil, beforeItem: prior, afterItem: after))
      } else if prior != nil, !deleted.contains(operation.target.id) {
        result.append(.init(kind: .appendPage, target: operation.target,
          pageID: operation.id.flatMap(UUID.init(uuidString:)), beforeItem: prior, afterItem: after))
      }
    }
    return result
  }

  func targetSurvivesLifecycle(_ target: CollaborationTarget) throws -> Bool {
    switch target.kind {
    case .workspace: return true
    case .page: return try ownerItemID(ofPage: target.id) != nil
    case .cover: return try ownerBoardID(of: target.id) == target.boardID && readItemHeader(target.id) != nil
    case .document: return try readItemHeader(target.id)?.kind == .document
    case .board: return try isLiveBoard(target.id)
    case .codeFragment: return try hasStoredValue(codeFragmentFile(target.id))
    }
  }

  /// Membership is checked at its operation boundary, including this segment's
  /// buffered insertions/removals, not while loading the original footprint.
  func validateReorderMembership(_ operation: CollaborationOperation, before: CollaborationWorkspace,
    after: CollaborationWorkspace) throws {
    guard operation.kind == .reorderElements, operation.target.kind != .page else { return }
    let target = operation.target, surface: SurfaceID = target.kind == .cover ? .cover(target.id) : .board(target.id)
    let boardID = target.boardID ?? target.id
    func count(_ projection: CollaborationWorkspace) throws -> Int {
      try projection.hierarchy.board(boardID)?.elements.filter { $0.surface == surface }.count ?? 0
    }
    if let database = currentSQL, database.writable { try refreshReferenceIndex(database: database) }
    let physical = try currentSQL!.rows("SELECT count(*) FROM reference_element_order WHERE owner_key=?", [.text(target.key)]).first![0].integer!
    let expectedCount = try physical - Int64(count(before)) + Int64(count(after))
    let ids = try operation.values["ids"]?.decode([String].self) ?? []
    guard Int64(ids.count) == expectedCount else { throw CollaborationError("invalid_operation", "Порядок перечисляет всю выбранную поверхность ровно один раз.") }
  }
}
