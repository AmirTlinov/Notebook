import Foundation

public struct NotebookSearchResult: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { reference.id }
  public let target: CollaborationTarget
  public let elementID: String?
  public let title: String
  public let path: [String]
  public let preview: String
  public let revision: String
  public let reference: CollaborationReference
}

public struct NotebookSearchResponse: Codable, Equatable, Sendable {
  public let status = "ready"
  public let results: [NotebookSearchResult]
  public let total: Int
  public let coverage: NotebookReadCoverage
  public var truncated: Bool { !coverage.complete }
  private enum CodingKeys: String, CodingKey { case status, results, total, truncated, coverage }
  public init(results: [NotebookSearchResult], total: Int, next: String?) {
    self.results = results; self.total = total; coverage = .init(complete: next == nil, next: next)
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    results = try values.decode([NotebookSearchResult].self, forKey: .results)
    total = try values.decode(Int.self, forKey: .total)
    coverage = try values.decode(NotebookReadCoverage.self, forKey: .coverage)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(status, forKey: .status); try values.encode(results, forKey: .results)
    try values.encode(total, forKey: .total); try values.encode(truncated, forKey: .truncated)
    try values.encode(coverage, forKey: .coverage)
  }
}

extension NotebookStore {
  /// FTS and short-substring postings belong to the same commit as their source.
  /// Only the bounded hits resolve physical owners and source versions.
  public func search(_ query: String, limit: Int = 20, filters: NotebookSearchFilters = .init(), next: String? = nil) throws -> NotebookSearchResponse {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 500, query.utf8.count <= 4000, (1...100).contains(limit) else {
      throw CollaborationError("invalid_search", "Введите до 500 символов; выдача содержит от 1 до 100 совпадений.")
    }
    let folded = Self.foldedSearchText(query)
    let filters = try filters.normalized()
    return try readTransaction { _ in
      let workspaceID = try workspaceHeader().workspaceID, changeCursor = try currentChangeCursor()
      let cursor = try next.map { try NotebookSearchCursor.decode($0) }
      if let cursor {
        guard cursor.workspaceID == workspaceID, cursor.query == folded, cursor.filters == filters else {
          throw CollaborationError("search_cursor_mismatch", "Курсор принадлежит другому пространству, запросу или фильтрам; начните новый поиск.")
        }
        guard cursor.changeCursor == String(changeCursor) else {
          throw CollaborationError("search_cursor_stale", "Поисковый срез изменился; начните новый ограниченный поиск без next.")
        }
      }
      let database = currentSQL!, from: String, condition: String, match: String
      if folded.count < 3 {
        from = "search_short p JOIN search_entries s ON s.rowid=p.entry_id"
        condition = "p.gram=?"; match = folded
      } else {
        from = "search_fts JOIN search_entries s ON s.rowid=search_fts.rowid"
        condition = "search_fts MATCH ?"; match = "\"" + folded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }
      var filter = " FROM " + from + " WHERE " + condition + " AND instr(s.folded,?)>0"
      var arguments: [NotebookSQLValue] = [.text(match), .text(folded)]
      if let kinds = filters.kinds {
        filter += " AND s.kind IN (" + Array(repeating: "?", count: kinds.count).joined(separator: ",") + ")"
        arguments += kinds.map { .text($0.rawValue) }
      }
      if let target = filters.target {
        if target.kind == .cover, try ownerBoardID(of: target.id) != target.boardID {
          throw CollaborationError("target_missing", "Обложка больше не принадлежит указанной доске.", target: target)
        }
        let id = target.id.uuidString.lowercased()
        switch target.kind {
        case .page, .document:
          filter += " AND s.kind=? AND s.owner_id=?"
          arguments += [.text(target.kind.rawValue), .text(id)]
        case .board, .cover:
          filter += " AND ((s.kind='spatial' AND s.target_kind=? AND s.target_id=?) OR (s.kind='item' AND s.owner_id=?))"
          arguments += [.text(target.kind.rawValue), .text(id), .text(id)]
        default: throw CollaborationError("invalid_search", "Поиск ограничивается листом, документом, доской или обложкой.")
        }
      }
      // COUNT reads the text index, never owner bodies. Keep its real cost
      // explicit instead of returning an invented total from a caller token.
      let total = Int(try database.rows("SELECT COUNT(*)" + filter, arguments)[0][0].integer!)
      if let cursor {
        filter += " AND (s.kind,s.address)>(?,?)"
        arguments += [.text(cursor.kind), .text(cursor.address)]
      }
      // Sort bounded identities first: do not move every matching plain_text
      // into SQLite's sorter before LIMIT. Only selected hits resolve bodies.
      let matches = try database.rows("SELECT s.kind,s.address" + filter + " ORDER BY s.kind,s.address LIMIT ?",
        arguments + [.integer(Int64(limit + 1))])
      let rows = try matches.prefix(limit).map { row in
        guard let value = try database.rows("SELECT kind,owner_id,target_kind,target_id,element_id,plain_text FROM search_entries WHERE address=?", [.text(row[1].text!)]).first else {
          throw NotebookStorageError.corruptRecord("search result")
        }
        return value
      }
      var results: [NotebookSearchResult] = []
      for row in rows {
        try Task.checkCancellation()
        guard let owner = row[1].text.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord("search owner") }
        let target: CollaborationTarget, location: [String], title: String
        switch row[0].text {
        case "item":
          guard let item = try readItemHeader(owner), let board = try ownerBoardID(of: owner) else { throw NotebookStorageError.corruptRecord("search item") }
          target = .init(kind: item.kind == .board ? .board : .cover, id: owner, boardID: item.kind == .board ? nil : board)
          title = item.title; location = try searchPath(owner)
        case "page":
          guard let itemID = try ownerItemID(ofPage: owner), let item = try readItemHeader(itemID) else { throw NotebookStorageError.corruptRecord("search page") }
          let position = try database.rows("SELECT position FROM records WHERE parent=? AND collection='pageIDs' AND member=?", [.text("workspace.json#/items/@" + itemID.uuidString.lowercased()), .text(owner.uuidString.lowercased())]).first?[0].integer
          guard let position else { throw NotebookStorageError.corruptRecord("page position") }
          target = .init(kind: .page, id: owner); title = item.title; location = try searchPath(itemID) + ["Лист \(position + 1)"]
        case "document":
          guard let item = try readItemHeader(owner) else { throw NotebookStorageError.corruptRecord("search document") }
          target = .init(kind: .document, id: owner); title = item.title; location = try searchPath(owner)
        case "spatial":
          guard let kind = row[2].text.flatMap(CollaborationTarget.Kind.init(rawValue:)), let id = row[3].text.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord("search surface") }
          target = .init(kind: kind, id: id, boardID: kind == .cover ? owner : nil)
          title = try readItemHeader(id)?.title ?? "Пространство"; location = try searchPath(id)
        default: throw NotebookStorageError.corruptRecord("search kind")
        }
        let plain = row[5].text!, elementID = row[4].text
        guard let match = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { throw NotebookStorageError.corruptRecord("search index text") }
        let start = plain.index(match.lowerBound, offsetBy: -60, limitedBy: plain.startIndex) ?? plain.startIndex
        let end = plain.index(match.upperBound, offsetBy: 180, limitedBy: plain.endIndex) ?? plain.endIndex
        let preview = String(plain[start..<end]), revision = try targetContentRevision(target: target)
        let reference = CollaborationReference(target: target, elementID: elementID,
          revision: try referenceRevision(target: target, elementID: elementID), label: preview)
        results.append(.init(target: target, elementID: elementID, title: title, path: location, preview: preview, revision: revision, reference: reference))
      }
      let continuation: String?
      if matches.count > limit, let last = matches.prefix(limit).last {
        continuation = try NotebookSearchCursor(workspaceID: workspaceID, changeCursor: String(changeCursor),
          query: folded, filters: filters, kind: last[0].text!, address: last[1].text!).encode()
      } else { continuation = nil }
      return .init(results: results, total: total, next: continuation)
    }
  }

  private func searchPath(_ id: UUID) throws -> [String] {
    var result: [String] = [], current: UUID? = id, visited = Set<UUID>()
    while let id = current, visited.insert(id).inserted {
      guard result.count < 64 else { result.append("…"); break }
      result.append(try readItemHeader(id)?.title ?? "Пространство")
      current = try ownerBoardID(of: id)
    }
    return result.reversed()
  }
}
