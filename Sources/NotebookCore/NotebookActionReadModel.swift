import CSQLite
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

    /// A fresh digest of one original document-source field. The source is an
    /// immutable alias, and literal binding gates reuse at each consumer.
    struct SourceDigest {
      private let file: String
      private let path: [CollaborationPathComponent]
      private let source: String
      private let value: String

      private init(_ field: CollaborationFieldChange, source: String, digest: String) {
        file = field.file; path = field.path; self.source = source; value = digest
      }

      static func original(_ receipt: CollaborationReceipt) throws -> Self? {
        guard receipt.undo == nil else { return nil }
        let sources = receipt.changes.filter { documentSource($0) != nil }
        guard sources.count == 1, let source = documentSource(sources[0]),
          let digest = try Field.digest(sources[0].after, file: sources[0].file, path: sources[0].path) else { return nil }
        return .init(sources[0], source: source, digest: digest)
      }

      private static func documentSource(_ field: CollaborationFieldChange) -> String? {
        guard let id = UUID(uuidString: URL(fileURLWithPath: field.file).deletingPathExtension().lastPathComponent),
          field.file == documentFile(id), field.path.count == 3,
          field.path[0] == .field("files"), case .member = field.path[1], field.path[2] == .field("source"),
          case .string(let source) = field.after else { return nil }
        return source
      }

      func digest(for changed: CollaborationFieldChange) -> String? {
        guard DocumentFile.sourcesAreEqual(file, changed.file), path.count == changed.path.count,
          zip(path, changed.path).allSatisfy({ left, right in
            switch (left, right) {
            case (.field(let left), .field(let right)), (.member(let left), .member(let right)):
              return DocumentFile.sourcesAreEqual(left, right)
            default: return false
            }
          }), case .string(let changedSource) = changed.after,
          DocumentFile.sourcesAreEqual(source, changedSource) else { return nil }
        return value
      }
    }

    init(_ field: CollaborationFieldChange, sourceDigest: SourceDigest? = nil) throws {
      file = field.file; path = field.path
      afterDigest = try sourceDigest?.digest(for: field) ?? Self.digest(field.after, file: file, path: path)
      retiredPlacement = usesRetiredPlacementOwner(field)
    }
    static func digest(_ value: JSONValue?, file: String, path: [CollaborationPathComponent]) throws -> String? {
      try collaborationComparable(value, file: file, path: path).map { value in
        #if DEBUG
        try collaborationHash(value, observingEncodedBytes: { bytes in
          if case .string = value, path.count == 3, path[0] == .field("files"),
            case .member = path[1], path[2] == .field("source"), file.hasPrefix("documents/") {
            NotebookPublicationCodecObservation.observer?(.init(phase: .documentSourceDigest, encodedBytes: bytes))
          }
        })
        #else
        try collaborationHash(value)
        #endif
      }
    }
  }

  public struct Undo: Codable, Equatable, Sendable {
    public let restored: Int
    public let completedAt: Date
    public let preserved: [Field]
    public let dependencies: [CollaborationPreservedDependency]?
    public let preservedLifecycle: [CollaborationTarget]?
    public let lifecycleChanges: [NotebookLifecycleUndoChange]?
  }

  public let id: UUID
  public let actionVersion: String
  public let action: Action
  public let createdAt: Date
  public let requestFingerprint: String?
  public let author: SharedContextEntry.Author?
  public let revisions: [CollaborationExpectation]
  public let changes: [Field]
  public let lifecycleChanges: [NotebookLifecycleChange]?
  public let undo: Undo?
  public var summary: String { action.summary }

  public init(_ receipt: CollaborationReceipt) throws {
    try self.init(receipt, version: receipt.deliveryVersion())
  }

  init(_ root: NotebookReceiptPublication.Root) throws {
    try self.init(root.receipt, version: notebookActionDeliveryVersion(root.value), sourceDigest: root.sourceDigest)
  }

  private init(_ receipt: CollaborationReceipt, version: String, sourceDigest: Field.SourceDigest? = nil) throws {
    id = receipt.id; actionVersion = version
    action = try .init(summary: receipt.summary, resolvedContextID: receipt.action.resolvedContextID,
      references: receipt.action.references, operations: receipt.action.operations.map(Operation.init))
    author = receipt.author
    createdAt = receipt.createdAt; requestFingerprint = receipt.requestFingerprint
    revisions = receipt.revisions; changes = try receipt.changes.map { try Field($0, sourceDigest: sourceDigest) }
    lifecycleChanges = receipt.lifecycleChanges
    undo = try receipt.undo.map { try .init(restored: $0.restored, completedAt: $0.completedAt,
      preserved: $0.preserved.map { try Field($0) }, dependencies:$0.dependencies,
      preservedLifecycle:$0.preservedLifecycle, lifecycleChanges:$0.lifecycleChanges) }
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
    database: NotebookSQLConnection, receiptRoot: NotebookReceiptPublication.Root? = nil) throws {
    if let receiptRoot, receiptRoot.address != address {
      throw NotebookStorageError.corruptRecord("receipt publication binding: " + address)
    }
    let indexedReceipt = receiptRoot?.receipt ?? receipt
    try indexFieldRestorations(indexedReceipt, address: address, database: database)
    let model = try receiptRoot.map(NotebookActionReadModel.init) ?? NotebookActionReadModel(indexedReceipt)
    let data = try Self.storageEncoder.encode(model)
    let phaseAt = max(indexedReceipt.createdAt, indexedReceipt.undo?.completedAt ?? indexedReceipt.createdAt)
    let hash = receiptRoot.map { NotebookSQLValue.text($0.hash) } ?? .null
    try database.run("INSERT INTO action_read_models(address,receipt_hash,value,phase_at) SELECT address,hash,?,? FROM records WHERE address=? AND (? IS NULL OR hash=?) ON CONFLICT(address) DO UPDATE SET receipt_hash=excluded.receipt_hash,value=excluded.value,phase_at=excluded.phase_at",
      [.blob(data), .real(phaseAt.timeIntervalSince1970), .text(address), hash, hash])
    if receiptRoot != nil, sqlite3_changes64(database.handle) != 1 {
      throw NotebookStorageError.corruptRecord("receipt publication binding: " + address)
    }
  }

  public func actionReadModel(_ id: UUID) throws -> NotebookActionReadModel {
    guard let model = try actionReadModelIfPresent(id) else {
      throw CollaborationError("target_missing", "Ход не найден: \(id)")
    }
    return model
  }

  /// Replay needs the writer's hash-bound identity, not its authored source
  /// body. A missing root is absence; an existing root without a valid model
  /// remains a refusal and cannot authorize a second execution of the ID.
  func actionReadModelIfPresent(_ id: UUID) throws -> NotebookActionReadModel? {
    try readTransaction { _ in
      let database = currentSQL!, file = "collaboration/actions/" + id.uuidString.lowercased() + ".json"
      let address = file + "#", refusal = NotebookStorageError.corruptRecord("action read model: " + address)
      guard let row = try database.rows("""
        SELECT CASE WHEN typeof(r.hash)='text' AND length(CAST(r.hash AS BLOB))=64 THEN r.hash END,
          CASE WHEN typeof(m.receipt_hash)='text' AND length(CAST(m.receipt_hash AS BLOB))=64 THEN m.receipt_hash END,
          CASE WHEN r.file=? AND r.parent IS NULL AND r.collection='' AND r.member=''
            AND typeof(r.position)='integer' AND r.position=0
            AND typeof(b.data)='blob' AND length(b.data) BETWEEN 1 AND 268435456 THEN 1 ELSE 0 END,
          typeof(m.value),length(m.value)
        FROM records r LEFT JOIN action_read_models m ON m.address=r.address
          LEFT JOIN blobs b ON b.hash=r.hash WHERE r.address=?
        """, [.text(file), .text(address)]).first else { return nil }
      guard let hash = row[0].text, NotebookPageOrderRegister.validHash(hash), row[1].text == hash,
        row[2].integer == 1, row[3].text == "blob", let byteCount = row[4].integer, byteCount > 0 else {
        throw refusal
      }
      guard byteCount <= 8 * 1_024 * 1_024 else { throw NotebookStorageError.limitExceeded("action_read_model") }
      guard let data = try database.rows("SELECT value FROM action_read_models WHERE address=? AND receipt_hash=?",
        [.text(address), .text(hash)]).first?[0].blob, data.count == Int(byteCount) else { throw refusal }
      try database.admitJSONDecode(data, maximumAllocationBytes: NotebookSQLReadAllowance.agentCommand.jsonDecodeBytes)
      let model: NotebookActionReadModel
      do { model = try JSONDecoder().decode(NotebookActionReadModel.self, from: data) }
      catch is DecodingError { throw refusal }
      guard model.id == id, NotebookPageOrderRegister.validHash(model.actionVersion),
        model.requestFingerprint.map(NotebookPageOrderRegister.validHash) ?? true else { throw refusal }
      try database.checkReadAllowance()
      return model
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

  /// Live arrival/display work follows saved phases, not the age of the original
  /// action. Public creation-history pagination remains actionReadModels.
  public func recentActionPhases(limit: Int = 64) throws -> [NotebookActionReadModel] {
    guard (1...128).contains(limit) else { throw NotebookStorageError.limitExceeded("action_page") }
    return try readTransaction { _ in
      try currentSQL!.rows("SELECT m.value,m.receipt_hash,r.hash FROM action_read_models m JOIN records r ON r.address=m.address ORDER BY m.phase_at DESC,m.address DESC LIMIT ?", [.integer(Int64(limit))]).map { row in
        guard row[1].text == row[2].text, let data = row[0].blob else {
          throw NotebookStorageError.corruptRecord("action phase read model")
        }
        return try JSONDecoder().decode(NotebookActionReadModel.self, from: data)
      }
    }
  }
}
