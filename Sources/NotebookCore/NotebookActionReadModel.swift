import Foundation

/// Read-only description of an immutable action receipt. It carries no source
/// bodies, inverse values or executable request. The writer derives it once;
/// the index is bound to the exact stored receipt hash and is never replicated.
public struct NotebookActionReadModel: Codable, Equatable, Sendable, Identifiable {
  public struct Operation: Codable, Equatable, Sendable {
    public let kind: CollaborationOperation.Kind
    public let target: CollaborationTarget
    public let id: String?
    public let frame: PageRect?
    let itemIDs: [UUID]
    let strokeID: UUID?
    let strokeRegion: PageRect?
    let strokeOrigin: WorldPoint?

    init(_ operation: CollaborationOperation) throws {
      kind = operation.kind; target = operation.target; id = operation.id
      frame = try? operation.values["frame"]?.decode(PageRect.self)
      itemIDs = kind == .stackItems ? try operation.values["itemIDs"]?.decode([UUID].self) ?? [] : []
      let stroke = kind == .appendInkStroke ? try? CollaborationInkStroke(operation) : nil
      strokeID = stroke?.id; strokeRegion = stroke?.region; strokeOrigin = stroke?.worldOrigin
    }


  }

  public struct Action: Codable, Equatable, Sendable {
    public let summary: String
    public let resolvedContextID: UUID
    public let references: [CollaborationReference]
    public let operations: [Operation]
  }

  public struct Field: Codable, Equatable, Sendable {
    public let file: String
    public let path: [CollaborationPathComponent]
    let afterDigest: String?
    let retiredPlacement: Bool

    init(_ field: CollaborationFieldChange) throws {
      file = field.file; path = field.path
      afterDigest = try Self.digest(field.after, file: file, path: path)
      retiredPlacement = usesRetiredPlacementOwner(field)
    }
    static func digest(_ value: JSONValue?, file: String, path: [CollaborationPathComponent]) throws -> String? {
      try collaborationComparable(value, file: file, path: path).map(collaborationHash)
    }
  }

  public struct Undo: Codable, Equatable, Sendable {
    public let restored: Int
    public let completedAt: Date
    public let preserved: [Field]
  }

  public let id: UUID
  public let actionVersion: String
  public let action: Action
  public let createdAt: Date
  public let requestFingerprint: String?
  public let revisions: [CollaborationExpectation]
  public let changes: [Field]
  public let undo: Undo?
  public var summary: String { action.summary }

  public init(_ receipt: CollaborationReceipt) throws {
    id = receipt.id; actionVersion = try receipt.deliveryVersion()
    action = try .init(summary: receipt.summary, resolvedContextID: receipt.action.resolvedContextID,
      references: receipt.action.references, operations: receipt.action.operations.map(Operation.init))
    createdAt = receipt.createdAt; requestFingerprint = receipt.requestFingerprint
    revisions = receipt.revisions; changes = try receipt.changes.map(Field.init)
    undo = try receipt.undo.map { try .init(restored: $0.restored, completedAt: $0.completedAt,
      preserved: $0.preserved.map(Field.init)) }
  }

  public func continuations(in files: [String: JSONValue]) throws -> [CollaborationContinuation] {
    try continuations(currentValue: { files[$0.file]?.value(at: $0.path[...]) },
      currentVersion: { collaborationFieldVersion(file: files[$0.file], path: $0.path) })
  }

  func continuations(currentValue: (Field) throws -> JSONValue?,
    currentVersion: (Field) throws -> ContentFieldVersion?) throws -> [CollaborationContinuation] {
    guard undo == nil else { return [] }
    return try changes.compactMap { field in
      try Task.checkCancellation()
      guard !field.retiredPlacement else { return nil }
      let current = try currentValue(field)
      guard try Field.digest(current, file: field.file, path: field.path) != field.afterDigest else { return nil }
      let version = try currentVersion(field)
      let removed = current == nil || (placementAddress(field.file, field.path) != nil
        && (try? current?.decode(WorkspacePlacement.self))?.pose == nil)
      return .init(file: field.file, path: field.path, author: removed ? .removed : version?.human == false ? .agent : .human)
    }
  }
}

extension DeviceActionReceipt {
  public func matches(_ action: NotebookActionReadModel) -> Bool {
    id == action.id && actionVersion == action.actionVersion && revisions == action.revisions
  }
}

extension NotebookStore {
  /// Compare the receipt's actual field addresses, not a command-shaped
  /// projection or the viewport's partial copy of a physical owner.
  func actionContinuations(_ action: NotebookActionReadModel) throws -> [CollaborationContinuation] {
    try readTransaction { store in
      try action.continuations(currentValue: { field in
        try store.readCollaborationValue(file: field.file, path: field.path)
      }, currentVersion: { field in
        try collaborationFieldVersion(path: field.path) { path in
          try store.readCollaborationValue(file: field.file, path: path)
        }
      })
    }
  }

  /// Walk the existing record collections to the field's owner. A member read
  /// never reconstructs its siblings (or a page's drawing); a whole-owner
  /// change still compares the complete owner, including later human adoption.
  func readCollaborationValue(file: String, path: [CollaborationPathComponent]) throws -> JSONValue? {
    try sqlRead { database in
      func read(_ address: String, _ path: ArraySlice<CollaborationPathComponent>) throws -> JSONValue? {
        try Task.checkCancellation()
        guard let row = try storedFragments(address: address, descendants: false).first else { return nil }
        let collections = row.collections.filter { collection in
          let prefix = collection.path.map(CollaborationPathComponent.field)
          return path.starts(with: prefix) || prefix.starts(with: path)
        }
        for collection in collections {
          let prefix = collection.path.map(CollaborationPathComponent.field)
          guard path.starts(with: prefix) else { continue }
          let tail = path.dropFirst(prefix.count)
          let collectionKey = fieldKey(collection.path)
          switch (collection.kind, tail.first) {
          case (.array, .member(let id)):
            return try read(address + "/" + collectionKey + "/@" + fieldKey([collaborationIdentity(id)]), tail.dropFirst())
          case (.dictionary, .field(let key)):
            return try read(address + "/" + collectionKey + "/@" + fieldKey([key]), tail.dropFirst())
          case (.array, .order) where tail.count == 1:
            // These arrays use canonical record positions. Special causal
            // collections below retain the codec's ordering and validation.
            if file != "spatial-ink.json", !file.hasPrefix("collaboration/contexts/"),
              !file.hasPrefix("document-states/"), collection.path != ["computations"] {
              if collection.path == ["pageIDs"] { return .array([]) }
              let ids = try database.rows("SELECT member FROM records WHERE parent=? AND collection=? ORDER BY position,member",
                [.text(address), .text(collectionKey)])
              return .array(ids.map { .string($0[0].text!) })
            }
          default: break
          }
        }
        guard !collections.isEmpty else { return row.value.value(at: path) }
        // Only the selected collection/subtree is assembled. In particular,
        // elements/order and a single element never pull in drawing samples.
        var rows = [row.replacing(value: row.value, collections: collections)]
        for collection in collections {
          let children = try database.rows("SELECT address FROM records WHERE parent=? AND collection=?",
            [.text(address), .text(fieldKey(collection.path))])
          for child in children {
            try Task.checkCancellation()
            rows += try storedFragments(address: child[0].text!)
          }
        }
        return try NotebookRecordCodec.decode(rows, root: address).value(at: path)
      }
      return try read(file + "#", path[...])
    }
  }

  func indexActionReadModel(_ receipt: CollaborationReceipt, address: String,
    database: NotebookSQLConnection) throws {
    let model = try NotebookActionReadModel(receipt)
    let data = try Self.storageEncoder.encode(model)
    try database.run("INSERT INTO action_read_models(address,receipt_hash,value) SELECT address,hash,? FROM records WHERE address=? ON CONFLICT(address) DO UPDATE SET receipt_hash=excluded.receipt_hash,value=excluded.value",
      [.blob(data), .text(address)])
  }

  public func actionReadModel(_ id: UUID) throws -> NotebookActionReadModel {
    try readTransaction { _ in
      let address = "collaboration/actions/" + id.uuidString.lowercased() + ".json#"
      guard let row = try currentSQL!.rows("SELECT m.value FROM records r LEFT JOIN action_read_models m ON r.address=m.address AND r.hash=m.receipt_hash WHERE r.address=?", [.text(address)]).first
        else { throw CollaborationError("target_missing", "Ход не найден: \(id)") }
      guard let data = row[0].blob else { throw NotebookStorageError.corruptRecord("action read model: " + address) }
      return try JSONDecoder().decode(NotebookActionReadModel.self, from: data)
    }
  }

  public func actionReadModels(afterID: UUID? = nil, contextID: UUID? = nil, limit: Int = 64) throws -> [NotebookActionReadModel] {
    guard (1...128).contains(limit) else { throw NotebookStorageError.limitExceeded("action_page") }
    return try readTransaction { _ in
      let afterFile = afterID.map { "collaboration/actions/" + $0.uuidString.lowercased() + ".json#" }
      let afterTime = try afterFile.flatMap { try currentSQL!.rows("SELECT created_at FROM metadata_index WHERE address=?", [.text($0)]).first?[0] }
      let rows = try currentSQL!.rows("SELECT m.value FROM metadata_index i JOIN records r ON r.address=i.address LEFT JOIN action_read_models m ON m.address=i.address AND r.hash=m.receipt_hash WHERE i.kind='action' AND (? IS NULL OR i.context_id=?) AND (? IS NULL OR i.created_at<? OR (i.created_at=? AND i.address<?)) ORDER BY i.created_at DESC,i.address DESC LIMIT ?", [
        contextID.map { .text($0.uuidString.lowercased()) } ?? .null, contextID.map { .text($0.uuidString.lowercased()) } ?? .null,
        afterTime ?? .null, afterTime ?? .null, afterTime ?? .null, afterFile.map(NotebookSQLValue.text) ?? .null, .integer(Int64(limit))])
      return try rows.map {
        guard let data = $0[0].blob else { throw NotebookStorageError.corruptRecord("action read model") }
        return try JSONDecoder().decode(NotebookActionReadModel.self, from: data)
      }
    }
  }
}
