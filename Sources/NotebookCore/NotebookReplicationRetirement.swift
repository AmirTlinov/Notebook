import Foundation

/// Local membership decision, not a receipt of delivery or a content change.
public struct NotebookPeerRetirement: Codable, Equatable, Sendable {
  public let peerID: UUID
  public let workspaceID: UUID
  public let sourceCursor: UInt64
  public let acknowledgedCursor: UInt64
  public let date: Date
}

extension NotebookStore {
  private static let retiredPeerPrefix = "retired_peer:"

  /// Explicit cold-launch maintenance must work before a migration which is
  /// waiting for this recipient. Never run general admission, import an archive,
  /// remove a cursor, or claim that the recipient received anything.
  @discardableResult
  public func retireReplicationPeer(_ peerID: UUID, workspaceID: UUID,
    expectedCursor: UInt64) throws -> NotebookPeerRetirement {
    guard currentSQL == nil, expectedCursor <= UInt64(Int64.max),
      FileManager.default.fileExists(atPath: databaseURL.path),
      !["workspace.json", "board.json", "spatial-ink.json"].contains(where: {
        FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
      }) else { throw NotebookStorageError.invalidTransaction("peer retirement requires an existing SQLite workspace") }
    let db = try NotebookSQLConnection(url: databaseURL, writable: true)
    try db.run("BEGIN IMMEDIATE")
    do {
      guard try db.rows("PRAGMA application_id").first?[0].integer == 1_313_999_665,
        let version = try db.rows("PRAGMA user_version").first?[0].integer,
        (2...Self.currentDatabaseVersion).contains(version),
        try db.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text == workspaceID.uuidString.lowercased()
      else { throw NotebookStorageError.unsupportedFormat }
      let key = Self.retiredPeerPrefix + peerID.uuidString.lowercased()
      if let data = try db.rows("SELECT value FROM metadata WHERE key=?", [.text(key)]).first?[0].text {
        let previous = try JSONDecoder().decode(NotebookPeerRetirement.self, from: Data(data.utf8))
        guard previous.peerID == peerID, previous.workspaceID == workspaceID,
          previous.sourceCursor == expectedCursor, previous.acknowledgedCursor <= previous.sourceCursor else { throw NotebookStorageError.transactionConflict }
        try db.run("COMMIT"); return previous
      }
      let cursor = try db.rows("SELECT COALESCE(MAX(sequence),0) FROM change_log").first![0].integer!
      guard cursor == Int64(expectedCursor) else { throw NotebookStorageError.transactionConflict }
      let peers = try db.rows("SELECT peer_id FROM peer_cursors").compactMap { $0[0].text }
      guard peers.contains(where: { NotebookReplicationSource(cursorKey: $0)?.deviceID == peerID }) else {
        throw NotebookStorageError.invalidTransaction("unknown replication peer")
      }
      let acknowledged = try db.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='outgoing'",
        [.text(peerID.uuidString.lowercased())]).first?[0].integer ?? 0
      guard acknowledged >= 0, acknowledged <= cursor else { throw NotebookStorageError.corruptRecord("peer retirement cursor") }
      let receipt = NotebookPeerRetirement(peerID: peerID, workspaceID: workspaceID,
        sourceCursor: expectedCursor, acknowledgedCursor: UInt64(acknowledged), date: Date())
      let value = String(decoding: try Self.storageEncoder.encode(receipt), as: UTF8.self)
      try db.run("INSERT INTO metadata(key,value) VALUES(?,?)", [.text(key), .text(value)])
      try db.run("COMMIT"); return receipt
    } catch { try? db.run("ROLLBACK"); throw error }
  }

  public func retiredReplicationPeers() throws -> Set<UUID> {
    try sqlRead { try Self.retiredReplicationPeers(database: $0) }
  }

  static func retiredReplicationPeers(database: NotebookSQLConnection) throws -> Set<UUID> {
    let workspace = try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text
    return try Set(database.rows("SELECT key,value FROM metadata WHERE key LIKE 'retired_peer:%'").map { row in
      guard let key = row[0].text, let value = row[1].text else { throw NotebookStorageError.corruptRecord("retired peer") }
      let receipt = try JSONDecoder().decode(NotebookPeerRetirement.self, from: Data(value.utf8))
      guard key == retiredPeerPrefix + receipt.peerID.uuidString.lowercased(),
        workspace == receipt.workspaceID.uuidString.lowercased(), receipt.acknowledgedCursor <= receipt.sourceCursor
      else { throw NotebookStorageError.corruptRecord("retired peer") }
      return receipt.peerID
    })
  }

  func requireActiveReplicationPeer(_ peerID: UUID, database: NotebookSQLConnection) throws {
    guard try database.rows("SELECT 1 FROM metadata WHERE key=?",
      [.text(Self.retiredPeerPrefix + peerID.uuidString.lowercased())]).isEmpty else {
      throw CollaborationError("replication_peer_retired", "Это сопряжение завершено владельцем пространства. Его история и подтверждения сохранены.")
    }
  }
}
