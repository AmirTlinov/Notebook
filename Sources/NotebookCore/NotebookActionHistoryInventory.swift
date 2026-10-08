import CSQLite
import Foundation

/// Acceptance markers only. A manifest's receipt fragments, full birth proof,
/// historical membership and restoration authority belong to their typed owners.
public struct NotebookActionHistoryInventory {
  public struct Occurrence: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let transactionID: UUID
    public let manifestHash: String
    public let localJournal: LocalJournal?
    public let firstReceived: FirstReceived?
  }

  public struct LocalJournal: Codable, Equatable, Sendable {
    /// This replica's journal position, including transactions it relayed.
    public let sequence: UInt64
    public let manifestByteCount: Int
  }

  public struct FirstReceived: Codable, Equatable, Sendable {
    /// The first delivery route retained by DB29, not the action's author.
    public let source: NotebookReplicationSource
    public let senderSequence: UInt64
  }

  public struct Cursor: Equatable, Sendable {
    fileprivate let workspaceID: UUID
    fileprivate let snapshotID: UUID
    fileprivate let transactionKey: String
  }

  public struct Page: Equatable, Sendable {
    public let workspaceID: UUID
    /// Ephemeral identity of the caller's read transaction; never a durable seal.
    public let borrowedSnapshotID: UUID
    public let occurrences: [Occurrence]
    /// A full page offers another read; the final page may be empty.
    public let next: Cursor?
  }

  static func page(in database: NotebookSQLConnection, workspaceID: UUID,
    after cursor: Cursor? = nil, limit: Int = 64) throws -> Page {
    let snapshotID = try borrowedSnapshot(in: database, workspaceID: workspaceID)
    if let cursor, cursor.workspaceID != workspaceID || cursor.snapshotID != snapshotID {
      throw NotebookStorageError.invalidTransaction("action history inventory read cut changed")
    }
    return try page(in: database, workspaceID: workspaceID, snapshotID: snapshotID,
      afterKey: cursor?.transactionKey ?? "", limit: limit)
  }

  private static func page(in database: NotebookSQLConnection, workspaceID: UUID,
    snapshotID: UUID, afterKey key: String, limit: Int) throws -> Page {
    guard (1...64).contains(limit) else {
      throw NotebookStorageError.limitExceeded("action_history_inventory_page")
    }
    // CASE admits only bounded scalar headers before the SQL connection copies
    // them into Swift. Presence flags distinguish invalid fields from no marker.
    let rows = try database.rows("""
      WITH accepted AS (
        SELECT transaction_id FROM change_log WHERE transaction_id>?
        UNION
        SELECT transaction_id FROM received_transactions WHERE transaction_id>?
        ORDER BY transaction_id LIMIT ?
      )
      \(headerProjection)
      ORDER BY a.transaction_id
      """, [.text(key), .text(key), .integer(Int64(limit))])
    var occurrences: [Occurrence] = []
    occurrences.reserveCapacity(rows.count)
    var lastKey = key
    for row in rows {
      let occurrence = try coalescedOccurrence(row, workspaceID: workspaceID)
      let transactionKey = occurrence.transactionID.uuidString.lowercased()
      guard transactionKey > lastKey else {
        throw NotebookStorageError.corruptRecord("action history inventory marker")
      }
      occurrences.append(occurrence)
      lastKey = transactionKey
    }
    return .init(workspaceID: workspaceID, borrowedSnapshotID: snapshotID, occurrences: occurrences,
      next: rows.count == limit ? .init(workspaceID: workspaceID, snapshotID: snapshotID, transactionKey: lastKey) : nil)
  }

  /// A semantic seek begins in this cut. It never revives an old SQL cursor or
  /// asserts that acceptance remained unchanged between two read transactions.
  static func page(in database: NotebookSQLConnection, workspaceID: UUID,
    afterTransactionID: UUID?, limit: Int = 64) throws -> Page {
    let snapshotID = try borrowedSnapshot(in: database, workspaceID: workspaceID)
    return try page(in: database, workspaceID: workspaceID, snapshotID: snapshotID,
      afterKey: afterTransactionID?.uuidString.lowercased() ?? "", limit: limit)
  }

  /// One exact accepted identity, with the same marker validation as directory
  /// pages. Staged manifests cannot supply this point lookup.
  static func occurrence(in database: NotebookSQLConnection, workspaceID: UUID,
    transactionID: UUID) throws -> Occurrence? {
    _ = try borrowedSnapshot(in: database, workspaceID: workspaceID)
    let key = transactionID.uuidString.lowercased()
    let rows = try database.rows("""
      WITH accepted AS (
        SELECT transaction_id FROM change_log WHERE transaction_id=?
        UNION SELECT transaction_id FROM received_transactions WHERE transaction_id=?
      )
      \(headerProjection)
      """, [.text(key), .text(key)])
    guard let row = rows.first else { return nil }
    return try coalescedOccurrence(row, workspaceID: workspaceID)
  }

  private static func borrowedSnapshot(in database: NotebookSQLConnection, workspaceID: UUID) throws -> UUID {
    guard !database.writable, let snapshotID = database.readSnapshotIdentity,
      sqlite3_get_autocommit(database.handle) == 0 else {
      throw NotebookStorageError.readOnlyTransaction
    }
    // All statements consume the enclosing reader's existing SQL/row/byte and
    // cancellation lease. This helper neither opens nor renews that lease.
    try database.checkReadAllowance()
    let workspace = try database.rows("""
      SELECT CASE WHEN typeof(value)='text' AND length(CAST(value AS BLOB))=36
        THEN value END FROM metadata WHERE key='workspace_id'
      """).first?[0].text
    guard let workspace, let storedWorkspaceID = UUID(uuidString: workspace),
      workspace == storedWorkspaceID.uuidString.lowercased(), storedWorkspaceID == workspaceID else {
      throw NotebookStorageError.corruptRecord("action history inventory workspace")
    }
    // Every entry point rejects keys that a >"" seek cannot visit. Equality
    // and NULL probes retain their persistent unique-index access paths.
    for table in ["change_log", "received_transactions"] {
      guard try database.rows("""
        SELECT 1 FROM \(table) WHERE transaction_id=''
        UNION ALL SELECT 1 FROM \(table) WHERE transaction_id IS NULL LIMIT 1
        """).isEmpty else {
        throw NotebookStorageError.corruptRecord("action history inventory marker")
      }
    }
    return snapshotID
  }

  private static let headerProjection = """
      SELECT
        CASE WHEN typeof(a.transaction_id)='text' AND length(CAST(a.transaction_id AS BLOB))=36
          THEN a.transaction_id END,
        CASE WHEN j.transaction_id IS NOT NULL THEN 1 ELSE 0 END,
        CASE WHEN typeof(j.manifest_hash)='text' AND length(CAST(j.manifest_hash AS BLOB))=64
          THEN j.manifest_hash END,
        CASE WHEN typeof(j.sequence)='integer' AND j.sequence>0 THEN j.sequence END,
        CASE WHEN typeof(j.byte_count)='integer' AND j.byte_count BETWEEN 1 AND 67108864
          THEN j.byte_count END,
        CASE WHEN r.transaction_id IS NOT NULL THEN 1 ELSE 0 END,
        CASE WHEN typeof(r.manifest_hash)='text' AND length(CAST(r.manifest_hash AS BLOB))=64
          THEN r.manifest_hash END,
        CASE WHEN typeof(r.peer_id)='text' AND length(CAST(r.peer_id AS BLOB)) IN (36,73)
          THEN r.peer_id END,
        CASE WHEN typeof(r.sequence)='integer' AND r.sequence>0 THEN r.sequence END,
        CASE WHEN j.transaction_id IS NOT NULL AND r.transaction_id IS NOT NULL
          AND j.manifest_hash IS NOT r.manifest_hash THEN 1 ELSE 0 END
      FROM accepted a
      LEFT JOIN change_log j ON j.transaction_id=a.transaction_id
      LEFT JOIN received_transactions r ON r.transaction_id=a.transaction_id
      """

  private static func coalescedOccurrence(_ row: [NotebookSQLValue], workspaceID: UUID) throws -> Occurrence {
    if row[9].integer == 1 { throw NotebookStorageError.transactionConflict }
    guard let transactionKey = row[0].text, let transactionID = UUID(uuidString: transactionKey),
      transactionKey == transactionID.uuidString.lowercased() else {
      throw NotebookStorageError.corruptRecord("action history inventory marker")
    }
    let local: LocalJournal?, received: FirstReceived?
    var hash: String?
    if row[1].integer == 1 {
      guard let manifestHash = row[2].text, validHash(manifestHash),
        let sequence = row[3].integer, let byteCount = row[4].integer else {
        throw NotebookStorageError.corruptRecord("action history inventory marker")
      }
      hash = manifestHash
      local = .init(sequence: UInt64(sequence), manifestByteCount: Int(byteCount))
    } else { local = nil }
    if row[5].integer == 1 {
      guard let manifestHash = row[6].text, validHash(manifestHash),
        let sourceKey = row[7].text, let source = NotebookReplicationSource(cursorKey: sourceKey),
        let sequence = row[8].integer else {
        throw NotebookStorageError.corruptRecord("action history inventory marker")
      }
      if let hash, hash != manifestHash { throw NotebookStorageError.transactionConflict }
      hash = manifestHash
      received = .init(source: source, senderSequence: UInt64(sequence))
    } else { received = nil }
    guard let hash else { throw NotebookStorageError.corruptRecord("action history inventory marker") }
    return .init(workspaceID: workspaceID, transactionID: transactionID,
      manifestHash: hash, localJournal: local, firstReceived: received)
  }

  private static func validHash(_ hash: String) -> Bool {
    hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
