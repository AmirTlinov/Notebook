import Foundation

/// A query is a physical owner plus a bounded projection. Tokens are portable
/// data, never read sessions or authority to mutate the selected neighbours.
public struct NotebookObservationScope: Codable, Equatable, Sendable {
  public enum Field: String, Codable, Sendable { case preview, content, state, geometry }
  public enum Relation: String, Codable, Sendable { case incoming, outgoing, neighbors, container }
  public var target: CollaborationTarget
  public var ids: [String]?
  public var fields: [Field]
  public var expand: [Relation]
  public var bounds: NotebookReadBounds?
  public init(target: CollaborationTarget, ids: [String]? = nil, fields: [Field] = [.preview],
    expand: [Relation] = [], bounds: NotebookReadBounds? = nil) {
    self.target = target; self.ids = ids; self.fields = fields; self.expand = expand; self.bounds = bounds
  }
  private enum CodingKeys: String, CodingKey { case target, ids, fields, expand, bounds }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    target = try c.decode(CollaborationTarget.self, forKey: .target)
    ids = try c.decodeIfPresent([String].self, forKey: .ids)
    fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? [.preview]
    expand = try c.decodeIfPresent([Relation].self, forKey: .expand) ?? []
    bounds = try c.decodeIfPresent(NotebookReadBounds.self, forKey: .bounds)
  }
  func normalized() throws -> Self {
    guard [.page, .document, .board, .cover].contains(target.kind), (target.kind == .cover) == (target.boardID != nil),
      ids == nil || (!ids!.isEmpty && ids!.count <= 32 && ids!.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 120 })),
      !fields.isEmpty, fields.count <= 4, expand.count <= 4,
      !fields.contains(.state) || target.kind == .document,
      bounds == nil || ([.board, .cover].contains(target.kind) && ids == nil),
      expand.isEmpty || ids != nil else {
      throw CollaborationError("invalid_observation", "Нужен физический target, 1–32 ids, допустимые fields и одношаговое expand только от явных ids. bounds относится к доске/обложке.")
    }
    if let bounds { _ = try bounds.validated() }
    return .init(target: target, ids: ids.map { Array(Set($0.map(collaborationIdentity))).sorted() },
      fields: Array(Set(fields)).sorted { $0.rawValue < $1.rawValue },
      expand: Array(Set(expand)).sorted { $0.rawValue < $1.rawValue }, bounds: bounds)
  }
}

public struct NotebookObservationObject: Codable, Sendable {
  public enum Change: String, Codable, Sendable { case upsert, deleted, outOfScope }
  public let target: CollaborationTarget
  public let id: String
  public let change: Change
  public let value: JSONValue?
}

public struct NotebookObservation: Codable, Sendable {
  public let mode: String
  public let reset: String?
  public let header: JSONValue
  public let objects: [NotebookObservationObject]
  public let containers: [NotebookItemHeader]
  public let coverage: NotebookReadCoverage
  /// Absent until every page has been consumed. Never substitute next here.
  public let checkpoint: String?
  public let through: String
}

struct NotebookObservationCursor: Codable {
  var version = 1
  let workspaceID: UUID
  let scope: NotebookObservationScope
  let from: UInt64?
  let through: UInt64
  let position: String?
  let members: [String]?
  let previousMembers: [String]?
  func encode() throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self).base64EncodedString()
  }
  static func decode(_ value: String) throws -> Self {
    guard value.utf8.count <= 196_608, let data = Data(base64Encoded: value),
      let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.version == 1,
      cursor.through <= UInt64(Int64.max), cursor.from == nil || cursor.from! <= cursor.through,
      cursor.position == nil || (!cursor.position!.isEmpty && cursor.position!.utf8.count <= 4096),
      cursor.members == nil || cursor.members!.count <= 256,
      cursor.previousMembers == nil || cursor.previousMembers!.count <= 256,
      (try? cursor.scope.normalized()) == cursor.scope else {
      throw CollaborationError("invalid_observation_cursor", "Курсор наблюдения повреждён или не поддерживается.")
    }
    return cursor
  }
}

extension NotebookReadBounds: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.anchor == rhs.anchor && lhs.region == rhs.region }
}

extension NotebookStore {
  public func observeContent(scope supplied: NotebookObservationScope, since: String? = nil, next: String? = nil,
    limit: Int = 32) throws -> NotebookObservation {
    guard (1...32).contains(limit), since == nil || next == nil else {
      throw CollaborationError("invalid_observation", "Укажите limit 1–32 и только один из since/next.")
    }
    let scope = try supplied.normalized()
    return try readTransaction { _ in
      try currentSQL!.limitReads(.agentCommand)
      let workspace = try workspaceHeader(), through = try currentChangeCursor()
      let prior = try (next ?? since).map(NotebookObservationCursor.decode)
      if let prior, prior.workspaceID != workspace.workspaceID {
        throw CollaborationError("observation_cursor_mismatch", "Курсор принадлежит другому пространству.")
      }
      if next != nil {
        guard let prior, prior.position != nil, prior.scope == scope else {
          throw CollaborationError("observation_cursor_mismatch", "next требует исходную область, fields и expand.")
        }
        guard prior.through == through else {
          throw CollaborationError("observation_cursor_stale", "Содержание изменилось между страницами; начните чтение от последнего полного checkpoint либо новый снимок.")
        }
      } else if let prior, prior.position != nil {
        throw CollaborationError("observation_incomplete", "Продолжите next до получения checkpoint; неполная страница не является since.")
      }
      if let prior, prior.scope == scope { try requireChangeHistory(after: prior.from ?? prior.through) }
      let sameScope = prior?.scope == scope
      let from = next != nil ? prior?.from : (sameScope ? prior?.through : nil)
      guard from == nil || from! <= through else { throw CollaborationError("invalid_observation_cursor", "Курсор опережает журнал.") }
      let layout = ObservationLayout(scope.target)
      if let prior {
        let previousLayout = ObservationLayout(prior.scope.target)
        for address in (prior.members ?? []) + (prior.previousMembers ?? []) + [prior.position].compactMap({ $0 }) {
          let id = Self.observationMember(address, prefix: previousLayout.prefix)
          guard address.hasPrefix(previousLayout.prefix), !id.isEmpty, id.utf16.count <= 120,
            address == previousLayout.address(id) else {
            throw CollaborationError("invalid_observation_cursor", "Курсор содержит адрес вне физического владельца.")
          }
        }
      }
      let metadata = try observationHeader(scope.target)
      let members = try observationMembers(scope, layout: layout)
      if next != nil, members != prior!.members {
        throw CollaborationError("observation_cursor_mismatch", "Курсор не соответствует раскрытию исходной области.")
      }
      let previous = next != nil ? prior!.previousMembers : (sameScope ? prior?.members : nil)
      let position = next != nil ? prior!.position : nil
      let candidates = try observationCandidates(scope, layout: layout, from: from, through: through,
        members: members, previous: previous, after: position, limit: limit + 1)
      let selected = candidates.prefix(limit)
      let objects = try selected.compactMap { address -> NotebookObservationObject? in
        let id = Self.observationMember(address, prefix: layout.prefix)
        let rows = try boundedStoredFragments([(address, false)], maximumCount: 1, maximumBytes: 4 * 1_024 * 1_024, budget: "observation_member")
        guard let root = rows.first else {
          if previous == nil, let from, [.board, .cover].contains(scope.target.kind),
            try !observationPreviouslyOnSurface(address, target: scope.target, at: from) { return nil }
          return .init(target: scope.target, id: id, change: .deleted, value: nil)
        }
        guard root.address == address, root.parent == layout.root, root.collection == layout.collection,
          root.value["id"]?.string.map(collaborationIdentity) == id else {
          throw NotebookStorageError.corruptRecord(address)
        }
        let inMembers = members.map { $0.contains(address) } ?? true
        let inSurface = try observationSurfaceMatches(root, target: scope.target)
        guard inMembers && inSurface else {
          if previous == nil, !inSurface, let from,
            try !observationPreviouslyOnSurface(address, target: scope.target, at: from) { return nil }
          // A physically present member leaving this query is not a deletion.
          return .init(target: scope.target, id: id, change: .outOfScope, value: nil)
        }
        let value = try observationValue(root, scope: scope, header: metadata)
        if scope.ids == nil, value["appearance"]?["state"] == .string("erased") {
          return from == nil ? nil : .init(target: scope.target, id: id, change: .outOfScope, value: nil)
        }
        return .init(target: scope.target, id: root.value["id"]?.string ?? id, change: .upsert, value: value)
      }
      let complete = candidates.count <= limit
      let token = NotebookObservationCursor(workspaceID: workspace.workspaceID, scope: scope, from: complete ? nil : from,
        through: through, position: complete ? nil : selected.last, members: members, previousMembers: complete ? nil : previous)
      let encoded = try token.encode()
      var containers: [NotebookItemHeader] = []
      if scope.expand.contains(.container) {
        let id = try scope.target.kind == .page ? ownerItemID(ofPage: scope.target.id)
          : scope.target.id
        if let id, let header = try readItemHeader(id) { containers.append(header) }
      }
      return .init(mode: from == nil ? "snapshot" : "delta", reset: prior != nil && !sameScope ? "scope_changed" : nil,
        header: metadata, objects: objects, containers: containers, coverage: .init(complete: complete, next: complete ? nil : encoded),
        checkpoint: complete ? encoded : nil, through: String(through))
    }
  }

  struct ObservationLayout {
    let file: String, root: String, collection: String, fields: String, prefix: String
    init(_ target: CollaborationTarget) {
      if target.kind == .page || target.kind == .document {
        file = target.kind == .page ? pageFile(target.id) : documentFile(target.id)
        root = file + "#"; collection = target.kind == .page ? "elements" : "blocks"; fields = "collaboration/fields"
      } else {
        file = "board.json"; root = file + "#/boards/@" + (target.boardID ?? target.id).uuidString.lowercased()
        collection = "board/elements"; fields = "board/collaboration/fields"
      }
      prefix = root + "/" + collection + "/@"
    }
    func address(_ id: String) -> String { prefix + fieldKey([collaborationIdentity(id)]) }
  }
  static func observationMember(_ address: String, prefix: String) -> String {
    String(address.dropFirst(prefix.count)).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
  }
  func observationHeader(_ target: CollaborationTarget) throws -> JSONValue {
    if target.kind == .page || target.kind == .document { return try .encode(readContentHeader(target: target)) }
    return .object(["target": try .encode(target), "contentRevision": .string(try targetContentRevision(target: target))])
  }
  func observationSurfaceMatches(_ root: NotebookStoredFragment, target: CollaborationTarget) throws -> Bool {
    if target.kind == .page || target.kind == .document { return true }
    let surface = try root.value["surface"]?.decode(SurfaceID.self)
    return surface == (target.kind == .cover ? .cover(target.id) : .board(target.id))
  }
  func observationPreviouslyOnSurface(_ address: String, target: CollaborationTarget, at cursor: UInt64) throws -> Bool {
    guard let hash = try currentSQL!.rows("SELECT blob_hash FROM change_records WHERE address=? AND sequence<=? ORDER BY sequence DESC LIMIT 1", [.text(address), .integer(Int64(cursor))]).first?[0].text else { return false }
    guard try blobSize(hash: hash) <= 4 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("observation_previous_member") }
    let row = try currentSQL!.decodedStoredFragment(from:currentSQL!.blob(hash))
    return try observationSurfaceMatches(row, target: target)
  }
  func observationValue(_ root: NotebookStoredFragment, scope: NotebookObservationScope, header: JSONValue) throws -> JSONValue {
    var result: [String: JSONValue] = [:]
    if scope.target.kind != .document {
      let id = root.value["id"]!.string!, graphic = try root.value["graphic"]?.decode(NotebookGraphic.self)
      let layout = try graphic == nil ? nil : readGraphicResolution(target: scope.target, elementID: id).layout
      let frame = try layout?.frame ?? root.value["frame"]!.decode(PageRect.self)
      let surface: SurfaceID = scope.target.kind == .page ? .page(scope.target.id)
        : scope.target.kind == .cover ? .cover(scope.target.id) : .board(scope.target.id)
      result["appearance"] = try NotebookElementAppearance.readProjection(graphic: graphic, layout: layout,
        size: .init(width: frame.width, height: frame.height), erasures: readElementErasures(on: surface, elementID: id))
    }
    if scope.fields.contains(.preview) {
      result["kind"] = root.value["kind"]
      result["preview"] = .string(String((root.value["source"]?.string ?? root.value["graphic"]?["label"]?.string ?? "").prefix(160)))
    }
    if scope.fields.contains(.content) {
      let rows = try boundedStoredFragments([(root.address, true)], maximumCount: 4096, maximumBytes: 4 * 1_024 * 1_024, budget: "observation_content")
      let value = try NotebookRecordCodec.decode(rows, root: root.address)
      let valid: Bool
      switch scope.target.kind {
      case .page:
        let element = try value.decode(AgentElement.self), size = try header["size"]!.decode(PageSize.self)
        valid = PageDocument.elementsAreValid([element], in: size)
      case .document: valid = try value.decode(DocumentBlock.self).isValid
      default: valid = try value.decode(SpatialElement.self).isValid
      }
      guard valid else { throw NotebookStorageError.corruptRecord(root.address) }
      result["content"] = value
    }
    if scope.fields.contains(.state) {
      let read = try readDocumentBlock(documentID: scope.target.id, blockID: root.value["id"]!.string!)
      result["state"] = read?.state
      result["stateVersion"] = try .encode(read?.stateVersion)
      result["sourceVersion"] = try .encode(read?.sourceVersion)
    }
    if scope.fields.contains(.geometry) {
      result["frame"] = root.value["frame"]; result["worldOrigin"] = root.value["worldOrigin"]
      if root.value["graphic"] != nil {
        result["graphicResolution"] = try readGraphicResolution(target: scope.target, elementID: root.value["id"]!.string!).readProjection()
      }
    }
    return .object(result)
  }
}
