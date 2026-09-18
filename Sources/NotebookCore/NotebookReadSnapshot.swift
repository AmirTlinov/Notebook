import Foundation

extension NotebookStore {
  /// Called after the query in the SAME WAL snapshot. Reading metadata here
  /// cannot freshen content that the caller has already seen.
  func queryBasis(_ query: NotebookReadQuery, data: JSONValue) throws -> NotebookReadBasis {
    let header = try workspaceHeader()
    let catalogue = CollaborationTarget(kind: .workspace, id: header.rootBoardID)
    var targets: [CollaborationTarget] = []
    func add(_ kind: CollaborationTarget.Kind, _ id: UUID?) { if let id { targets.append(.init(kind: kind, id: id)) } }
    func item(_ id: UUID) throws {
      targets.append(catalogue)
      if let board = try ownerBoardID(of: id) { add(.board, board); targets.append(.init(kind: .cover, id: id, boardID: board)) }
    }
    switch query.kind {
    case .workspaceHeader: targets = [catalogue]
    case .itemLifecycle:
      guard data != .null else { return try readBasis(targets: []) }
      let extent = try data.decode(NotebookItemLifecycle.self)
      try item(extent.item.id)
      let base = try readBasis(targets: targets)
      return .init(workspaceID: base.workspaceID, owners: base.owners.map { owner in
        .init(target: owner.target, revision: owner.revision, stateRevision: owner.stateRevision,
          sourceRevision: owner.sourceRevision, inkRevision: owner.inkRevision,
          lifecycleRevision: owner.target == extent.target ? extent.revision : nil)
      })
    case .itemHeader, .ownerBoard: if let id = query.id { try item(id) }
    case .itemHeaders: for value in data.array { if let id = value["id"]?.string.flatMap(UUID.init(uuidString:)) { try item(id) } }
    case .page, .pageHeader, .pageElement: add(.page, query.id)
    case .document, .documentHeader, .documentBlock, .documentState: add(.document, query.id)
    case .observation: if let target = query.scope?.target { targets.append(target) }
    case .boardItem:
      // This query names an item, not its containing board. The bounded
      // placement projection may show siblings, but does not grant their scope.
      if data != .null, let id = query.id { try item(id) }
    case .boardContentRevision, .scenePaintOrder, .boardElement:
      add(.board, query.id)
      if query.kind == .boardElement, data["surface"]?["kind"] == .string("cover"),
        let id = data["surface"]?["ownerID"]?.string.flatMap(UUID.init(uuidString:)), let boardID = query.id {
        targets.append(.init(kind: .cover, id: id, boardID: boardID))
      }
      if let id = query.coverID, let boardID = query.id { targets.append(.init(kind: .cover, id: id, boardID: boardID)) }
    case .sceneWindow:
      targets.append(catalogue); add(.board, query.id)
      for board in data["boards"]?.array ?? [] { add(.board, board["id"]?.string.flatMap(UUID.init(uuidString:))) }
    case .notebookDirectory, .notebookPages:
      if let id = query.id { try item(id) }
      for entry in data["pages"]?.array ?? [] { add(.page, entry["position"]?["pageID"]?.string.flatMap(UUID.init(uuidString:))) }
    case .notebookPosition: targets = [catalogue]; add(.page, query.id)
    case .workingSet:
      targets = [catalogue]
      for id in query.itemIDs ?? [] { try item(id) }
      for id in query.pageIDs ?? [] { add(.page, id) }
      for id in query.boardIDs ?? [] { add(.board, id) }
      for key in data["documents"]?.object.keys ?? Dictionary<String, JSONValue>().keys { add(.document, UUID(uuidString: key)) }
    case .codeFragment: if data != .null { add(.codeFragment, query.id) }
    case .codeFragments:
      for value in data.array { add(.codeFragment, value["id"]?.string.flatMap(UUID.init(uuidString:))) }
    case .spatialInk:
      for surface in query.surfaces ?? [] {
        guard let id = surface.ownerID else { continue }
        if surface.kind == .cover, let board = try ownerBoardID(of: id) { targets.append(.init(kind: .cover, id: id, boardID: board)) }
        else { add(surface.kind == .codeFragment ? .codeFragment : .board, id) }
      }
    // Historical evidence and session state do not grant a current content
    // basis, and must not silently substitute today's version for that source.
    default: break
    }
    return try readBasis(targets: targets)
  }

  func queryCoverage(_ query: NotebookReadQuery, data: JSONValue) throws -> NotebookReadCoverage {
    if query.kind == .observation { return try data["coverage"]!.decode(NotebookReadCoverage.self) }
    var next = query
    next.next = nil
    var incomplete = false
    switch query.kind {
    case .notebookDirectory:
      if let index = try data["nextIndex"]?.decode(Int.self) { incomplete = true; next.pageIndex = index; next.visibleRoot = data["header"]?["visibleRoot"]?.string }
    case .contexts, .contextEntries:
      if let after = (data["nextContextID"] ?? data["nextEntryID"])?.string.flatMap(UUID.init(uuidString:)) {
        incomplete = true; next.after = after; next.revision = data["readCursor"]?.string
      }
    case .scenePaintOrder:
      if let cursor = data["nextCursor"]?.string { incomplete = true; next.paintCursor = cursor }
    case .itemHeaders, .actions, .codeFragments:
      let limit = query.limit ?? (query.kind == .itemHeaders ? 128 : query.kind == .codeFragments ? 64 : 20)
      if data.array.count == limit, let after = data.array.last?["id"]?.string.flatMap(UUID.init(uuidString:)) { incomplete = true; next.after = after }
    case .sceneWindow:
      // The native window has no continuation in paint order. Do not invent
      // completeness; use scenePaintOrder for exhaustive spatial traversal.
      return .init(complete: data["truncated"] != .bool(true))
    default: break
    }
    guard incomplete else { return .init(complete: true) }
    let token = try Self.storageEncoder.encode(ReadContinuation(workspaceID: workspaceHeader().workspaceID,
      cursor: String(currentReadCursor()), query: next)).base64EncodedString()
    return .init(complete: false, next: "nbread2:" + token)
  }

  private struct ReadContinuation: Codable { let workspaceID: UUID; let cursor: String; let query: NotebookReadQuery }
  func resolveReadContinuation(_ query: NotebookReadQuery) throws -> NotebookReadQuery {
    guard let next = query.next else { return query }
    if query.kind == .observation { return query }
    guard next.hasPrefix("nbread2:") else { throw CollaborationError("invalid_cursor", "Нужно продолжение именно этого SDK-чтения.") }
    guard next.utf8.count < 262_144, let bytes = Data(base64Encoded: String(next.dropFirst(8))),
      let token = try? JSONDecoder().decode(ReadContinuation.self, from: bytes), token.query.kind == query.kind,
      token.query.next == nil, token.workspaceID == (try workspaceHeader().workspaceID) else {
      throw CollaborationError("read_cursor_mismatch", "Продолжение принадлежит другому чтению или пространству.")
    }
    guard token.cursor == String(try currentReadCursor()) else {
      throw CollaborationError("read_cursor_stale", "Снимок изменился. Начните новое ограниченное чтение.")
    }
    let supplied = try JSONValue.encode(query).object, recorded = try JSONValue.encode(token.query).object
    guard supplied.allSatisfy({ key, value in key == "next" || key == "limit" || recorded[key] == value }) else {
      throw CollaborationError("read_cursor_mismatch", "Адрес или область чтения изменились; начните новый ограниченный снимок.")
    }
    var resumed = token.query
    resumed.limit = query.limit ?? resumed.limit
    return resumed
  }
}
