import Foundation

public struct NotebookBoardPlacementMigrationReceipt: Codable, Equatable, Sendable {
  public let sourceCursor: UInt64
  public let sourceHash: String
  public let resultHash: String
  public let sourceReferences: [NotebookReferenceIdentity]
}

extension BoardDocument {
  /// Explicit conversion of a stored version-two value. The geometry body's
  /// own stamp is evidence of that pose; a joined field/header clock is not.
  /// In particular, two acknowledged replicas may have equal field clocks but
  /// retain body versions zero and one. Migration must not give them one dot.
  public static func migratingStoredVersionTwo(_ source: JSONValue) throws -> Self {
    struct StoredBoard: Decodable {
      let format: Int
      let freeItems: [FreeItemPlacement]
      let stacks: [WorkspaceItemStack]
      let elements: [SpatialElement]
      let stamp: VersionStamp
      let collaboration: CollaborativeContent?
    }
    let old = try source.decode(StoredBoard.self)
    let ids = old.freeItems.map(\.id) + old.stacks.flatMap(\.itemIDs)
    guard old.format == 2, old.stamp.counter <= VersionStamp.maximumCounter,
      old.collaboration?.isValid ?? true, old.freeItems.allSatisfy(\.isValid),
      old.stacks.allSatisfy(\.isValid), Set(ids).count == ids.count,
      Set(old.stacks.map(\.id)).count == old.stacks.count,
      old.elements.allSatisfy(\.isValid), Set(old.elements.map(\.id)).count == old.elements.count else {
      throw NotebookStorageError.invalidTransaction("version-two placement migration source")
    }
    func human(collection: String, id: UUID, stamp: VersionStamp) -> Bool {
      let field = old.collaboration?.fields[fieldKey([collection, id.uuidString.lowercased(), "center"])]
      return field?.stamp.actor == stamp.actor ? field!.human : true
    }
    var placements = try old.freeItems.map { item in
      try WorkspacePlacement.authored(itemID: item.id, pose: .init(center: item.center, zIndex: item.zIndex),
        stamp: item.stamp, human: human(collection: "freeItems", id: item.id, stamp: item.stamp), previous: nil)
    }
    for stack in old.stacks {
      for (offset, id) in stack.itemIDs.enumerated() {
        placements.append(try .authored(itemID: id,
          pose: .init(center: stack.center, zIndex: stack.zIndex, stackID: stack.id, stackOrder: offset),
          stamp: stack.stamp, human: human(collection: "stacks", id: stack.id, stamp: stack.stamp), previous: nil))
      }
    }
    // Previously removed items stay removed. Their old evidence remains in
    // the immutable source blobs; the current register keeps the exact dot.
    let live = Set(ids)
    for (key, version) in old.collaboration?.fields ?? [:] {
      let parts = key.split(separator: "/")
      guard parts.count == 3, parts[0] == "freeItems", parts[2] == "exists",
        let id = UUID(uuidString: String(parts[1])), !live.contains(id) else { continue }
      placements.append(try .authored(itemID: id, pose: nil, stamp: version.stamp,
        human: version.human, previous: nil))
    }
    let fields = old.collaboration?.fields.filter { !$0.key.hasPrefix("freeItems/") && !$0.key.hasPrefix("stacks/") }
    let result = Self(placements: placements, elements: old.elements, stamp: old.stamp,
      collaboration: fields.map(CollaborativeContent.init(fields:)))
    guard result.isValid(itemIDs: live) else { throw NotebookStorageError.invalidTransaction("migrated placement ownership") }
    return result
  }
}

extension NotebookStore {
  private var placementMigrationFile: String { "local/migrations/board-placements-v3.json" }

  /// The normal SQLite admission invokes the same transaction. Rehearsal uses
  /// this entry on an isolated copy; it never imports an historical workspace.
  @discardableResult
  public func migrateBoardPlacements() throws -> NotebookBoardPlacementMigrationReceipt? {
    try prepareDatabase()
    return try storedValue(placementMigrationFile)?.decode(NotebookBoardPlacementMigrationReceipt.self)
  }

  func needsBoardPlacementMigration(database: NotebookSQLConnection) throws -> Bool {
    let rows = try database.rows("SELECT json_extract(CAST(b.data AS TEXT),'$.value.board.format') FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.parent='board.json#' AND r.collection='boards' ORDER BY r.member LIMIT 1")
    return rows.first?[0].integer == 2
  }

  func migrateStoredBoardPlacements(database: NotebookSQLConnection) throws {
    guard try needsBoardPlacementMigration(database: database) else { return }
    let cursor = try currentChangeCursor()
    let peers = try database.rows("SELECT DISTINCT peer_id FROM peer_cursors").compactMap { $0[0].text }
    for peer in peers {
      let acknowledged = UInt64(try database.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='outgoing'", [.text(peer)]).first?[0].integer ?? 0)
      let pending = try database.rows("SELECT 1 FROM change_log WHERE sequence>? AND sequence<=? LIMIT 1",
        [.integer(Int64(acknowledged)), .integer(Int64(cursor))])
      guard pending.isEmpty else {
        throw CollaborationError("placement_migration_pending_peer", "Перед обновлением нужно завершить передачу сохранённых изменений сопряжённому компьютеру. Старые изменения не подтверждены и не будут пропущены.")
      }
    }
    guard let source = try storedValue("board.json"), let nodes = source["boards"]?.array else {
      throw NotebookStorageError.corruptRecord("placement migration tree")
    }
    let references = try database.rows("SELECT owner_key,hash FROM reference_owners WHERE (owner_key LIKE 'board:%' OR owner_key LIKE 'cover:%') AND hash IS NOT NULL").compactMap { row -> NotebookReferenceIdentity? in
      guard let key = row[0].text, let hash = row[1].text else { return nil }
      let parts = key.split(separator: ":")
      guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
      let target: CollaborationTarget
      if parts[0] == "board" { target = .init(kind: .board, id: id) }
      else {
        guard let board = try ownerBoardID(of: id) else { return nil }
        target = .init(kind: .cover, id: id, boardID: board)
      }
      return .init(target: target, revision: hash)
    }
    let nextNodes = try nodes.map { node -> JSONValue in
      guard let board = node["board"], board["format"] == .number(2) else {
        throw NotebookStorageError.invalidTransaction("mixed board migration versions")
      }
      return node.setting("board", try .encode(BoardDocument.migratingStoredVersionTwo(board)))
    }
    let next = source.setting("boards", .array(nextNodes))
    let hierarchy = try next.decode(BoardHierarchy.self)
    guard hierarchy.isValid(items: try loadIndex().items) else { throw NotebookStorageError.invalidTransaction("migration tree ownership") }
    // Old physical indexes are derived data. They are rebuilt by the same row
    // writer inside this transaction; the original immutable blobs stay intact.
    try database.run("DELETE FROM spatial_entries WHERE kind='item'")
    try database.run("DELETE FROM item_owners")
    try publishRecords(writes: ["board.json": next])
    try retireVersionTwoPlacementReferences(database: database)
    let receipt = NotebookBoardPlacementMigrationReceipt(sourceCursor: cursor,
      sourceHash: try collaborationHash(source), resultHash: try collaborationHash(next), sourceReferences: references)
    try publishRecords(writes: [placementMigrationFile: .encode(receipt)])
    try database.run("INSERT INTO metadata(key,value) VALUES('placement_outgoing_floor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(cursor))])
  }
}
