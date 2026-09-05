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
  public var truncated: Bool { total > results.count }
  private enum CodingKeys: String, CodingKey { case status, results, total, truncated }
  public init(results: [NotebookSearchResult], total: Int) { self.results = results; self.total = total }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    results = try values.decode([NotebookSearchResult].self, forKey: .results)
    total = try values.decode(Int.self, forKey: .total)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(status, forKey: .status); try values.encode(results, forKey: .results)
    try values.encode(total, forKey: .total); try values.encode(truncated, forKey: .truncated)
  }
}

extension NotebookStore {
  public func search(_ query: String, limit: Int = 20) throws -> NotebookSearchResponse {
    try Self.search(query, limit: limit, files: collaborationSnapshot())
  }

  /// The app and MCP search one completed content snapshot with identical matching and paths.
  public static func search(_ query: String, limit: Int = 20,
    files: [String: JSONValue]) throws -> NotebookSearchResponse {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 500, (1...100).contains(limit) else {
      throw CollaborationError("invalid_search", "Введите до 500 символов; выдача содержит от 1 до 100 совпадений.")
    }
    guard let indexValue = files["workspace.json"], let treeValue = files["board.json"] else {
      throw CollaborationError("target_missing", "Рабочее место ещё не готово.")
    }
    let index = try indexValue.decode(WorkspaceIndex.self), tree = try treeValue.decode(BoardHierarchy.self)
    let items = Dictionary(uniqueKeysWithValues: index.items.map { ($0.id, $0) })
    var parents: [UUID: UUID] = [:]
    for node in tree.boards { for id in node.board.itemIDs { parents[id] = node.id } }
    func path(_ id: UUID) -> [String] {
      var path: [String] = [], current: UUID? = id, seen: Set<UUID> = []
      while let id = current, seen.insert(id).inserted {
        path.insert(items[id]?.title ?? "Пространство", at: 0); current = parents[id]
      }
      return path
    }
    var hits: [NotebookSearchResult] = [], total = 0
    func add(_ target: CollaborationTarget, title: String, text: String, revision: String,
      elementID: String? = nil, location: [String]? = nil) throws {
      let text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return }
      total += 1
      guard hits.count < limit else { return }
      let start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
      let end = text.index(match.upperBound, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
      let preview = String(text[start..<end])
      let source = try referenceRevision(target: target, elementID: elementID, files: files)
      let reference = CollaborationReference(target: target, elementID: elementID, revision: source, label: preview)
      hits.append(.init(target: target, elementID: elementID, title: title, path: location ?? path(target.id),
        preview: preview, revision: revision, reference: reference))
    }
    for item in index.items {
      guard let parent = parents[item.id], let board = tree.board(parent) else { continue }
      try add(.init(kind: item.kind == .board ? .board : .cover, id: item.id,
        boardID: item.kind == .board ? nil : parent), title: item.title, text: item.title, revision: board.stamp.revision)
      for (offset, id) in item.pageIDs.enumerated() {
        guard let value = files["pages/\(id.uuidString.lowercased()).json"] else { continue }
        let page = try value.decode(PageDocument.self)
        for element in page.elements {
          try add(.init(kind: .page, id: id), title: item.title,
            text: element.source.isEmpty ? element.html : element.source, revision: page.agentStamp.revision,
            elementID: element.id, location: path(item.id) + ["Лист \(offset + 1)"])
        }
      }
      if item.kind == .document, let value = files["documents/\(item.id.uuidString.lowercased()).json"] {
        let document = try value.decode(DocumentDocument.self)
        for block in document.blocks {
          try add(.init(kind: .document, id: item.id), title: item.title, text: block.source,
            revision: document.contentStamp.revision, elementID: block.id)
        }
      }
    }
    for node in tree.boards {
      for element in node.board.elements {
        let target = CollaborationTarget(kind: element.surface.kind == .cover ? .cover : .board,
          id: element.surface.ownerID ?? node.id, boardID: element.surface.kind == .cover ? node.id : nil)
        try add(target, title: items[target.id]?.title ?? "Пространство",
          text: element.source.isEmpty ? element.html : element.source,
          revision: node.board.stamp.revision, elementID: element.id)
      }
    }
    return .init(results: hits, total: total)
  }
}
