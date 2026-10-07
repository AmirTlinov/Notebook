import Foundation

/// Metadata from one committed read cut. Payload categories deduplicate hashes
/// internally and may overlap each other; their bytes must not be added together.
/// This inventory does not prove transitive reachability or deletion eligibility.
public struct NotebookStorageUsage: Codable, Equatable, Sendable {
  public struct Cut: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let snapshotID: UUID
    public let readRevision: UInt64
    public let changeSequence: UInt64
    /// The stored journal generation is not the runtime's device identity.
    public let journalGeneration: UUID?
  }

  public struct Payload: Codable, Equatable, Sendable {
    public let count: Int64
    public let bytes: Int64
  }

  public struct CurrentRecords: Codable, Equatable, Sendable {
    public let recordCount: Int64
    public let payload: Payload
  }

  public struct RetainedHistory: Codable, Equatable, Sendable {
    public let changeCount: Int64
    public let changeRecordCount: Int64
    public let manifestCount: Int64
    public let manifestRecordCount: Int64
    /// Sum of change_log.byte_count, not the size of all delivery dependencies.
    public let changeManifestBytes: Int64
    /// Present manifest, record and discovered dependency blobs, once per hash.
    public let payload: Payload
  }

  public struct Incoming: Codable, Equatable, Sendable {
    public let pendingPartCount: Int64
    public let pendingOrderNodeCount: Int64
    /// Present hashes named by the pending part/order indexes, deduplicated.
    public let presentPayload: Payload
    public let missingBlobCount: Int64
  }

  public struct Peer: Codable, Equatable, Sendable {
    public let peerID: UUID
    public let retired: Bool
    public let acknowledgedSequence: UInt64
    public let pendingChangeCount: Int64
    public let pendingManifestBytes: Int64
  }

  public struct Outgoing: Codable, Equatable, Sendable {
    public let knownPeerCount: Int64
    /// At most 64 logical peers, in canonical UUID order. Incoming generations
    /// share one outgoing acknowledgement. Retired peers owe no work.
    public let peers: [Peer]
    public let truncated: Bool
  }

  public enum LogicalStatus: String, Codable, Sendable { case snapshot }
  public enum Reachability: String, Codable, Sendable { case partial }
  public enum FileStatus: String, Codable, Sendable { case unchanged, changed, missing, unavailable }
  public enum SampleStatus: String, Codable, Sendable { case sampled, changed, incomplete }

  public struct FileSample: Codable, Equatable, Sendable {
    public let status: FileStatus
    /// Logical file length, sampled after the SQL inventory; not allocated disk
    /// blocks and not an atomic measurement of the three physical files.
    public let bytes: Int64?
  }

  public struct Physical: Codable, Equatable, Sendable {
    public let database: FileSample
    public let wal: FileSample
    public let shm: FileSample
    public let pageSize: Int64
    public let pageCount: Int64
    public let freelistPages: Int64
    public let startedAt: Date
    public let finishedAt: Date
    /// Even unchanged file attributes are samples, independent of the SQL cut.
    public let sampleStatus: SampleStatus
  }

  public let cut: Cut
  public let logicalStatus: LogicalStatus
  public let blobs: Payload
  public let currentRecords: CurrentRecords
  public let retainedHistory: RetainedHistory
  public let incoming: Incoming
  public let outgoing: Outgoing
  /// Direct references in the reported current/history/dependency indexes and
  /// page-order/cloud-outbox indexes. No payload bodies are followed here.
  public let indexedReferences: Payload
  /// Outside the indexes above. May include valid staged or transitively owned
  /// author data; absence from these indexes is never proof of an orphan.
  public let unclassifiedBlobs: Payload
  public let reachability: Reachability
  public let physical: Physical
}

extension NotebookStore {
  /// Borrows an already admitted, committed read snapshot. A diagnostic never
  /// creates a workspace, performs schema admission or upgrades a writer cut.
  public func storageUsage() throws -> NotebookStorageUsage {
    guard let database = currentSQL, !database.writable,
      let snapshotID = database.readSnapshotIdentity else {
      throw NotebookStorageError.readOnlyTransaction
    }
    return try sqlRead { connection in
      try Task.checkCancellation()
      // Tighten the existing row/byte lease only; its SQL progress handler and
      // consumed instruction allowance remain the enclosing reader's owner.
      try connection.limitReads(.init(rows: 4_096, bytes: 1_048_576, valueBytes: 256,
        reason: "storage_usage_read"))
      guard try connection.rows("PRAGMA application_id").first?[0].integer == 1_313_999_665,
        try connection.rows("PRAGMA user_version").first?[0].integer == Self.currentDatabaseVersion else {
        throw NotebookStorageError.unsupportedFormat
      }
      let startedAt = Date()
      let urls = [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"),
        URL(fileURLWithPath: databaseURL.path + "-shm")]
      let before = urls.map(NotebookStorageFileAttributes.sample)
      let workspaceID = try storedWorkspaceID()
      let revision = try currentReadCursor(), sequence = try currentChangeCursor()
      let generationText = try connection.rows("SELECT value FROM metadata WHERE key='journal_generation'").first?[0].text
      let generation = generationText.flatMap(UUID.init(uuidString:))
      guard generationText == nil || generation != nil else {
        throw NotebookStorageError.corruptRecord("journal generation")
      }

      let history = try storageHistoryReferences(connection)
      let indexed = "SELECT hash FROM current_hashes UNION SELECT hash FROM history_hashes "
        + "UNION SELECT hash FROM page_order_nodes UNION SELECT hash FROM page_order_values"
        + (try storageOptionalReferences(connection, tables: [("cloud_outbox", ["hash"])]))
      let totals = try connection.rows("""
        WITH current_hashes AS MATERIALIZED (SELECT DISTINCT hash FROM records),
        history_hashes AS MATERIALIZED (\(history)),
        indexed_hashes AS MATERIALIZED (\(indexed))
        SELECT COUNT(*), COALESCE(SUM(length(b.data)),0),
          COUNT(c.hash), COALESCE(SUM(CASE WHEN c.hash IS NOT NULL THEN length(b.data) ELSE 0 END),0),
          COUNT(h.hash), COALESCE(SUM(CASE WHEN h.hash IS NOT NULL THEN length(b.data) ELSE 0 END),0),
          COUNT(i.hash), COALESCE(SUM(CASE WHEN i.hash IS NOT NULL THEN length(b.data) ELSE 0 END),0)
        FROM blobs b
        LEFT JOIN current_hashes c ON c.hash=b.hash
        LEFT JOIN history_hashes h ON h.hash=b.hash
        LEFT JOIN indexed_hashes i ON i.hash=b.hash
        """).first!
      let blobs = try storagePayload(totals, offset: 0)
      let currentPayload = try storagePayload(totals, offset: 2)
      let historyPayload = try storagePayload(totals, offset: 4)
      let indexedPayload = try storagePayload(totals, offset: 6)
      guard indexedPayload.count <= blobs.count, indexedPayload.bytes <= blobs.bytes else {
        throw NotebookStorageError.corruptRecord("storage usage references")
      }
      let counts = try connection.rows("""
        SELECT (SELECT COUNT(*) FROM records), (SELECT COUNT(*) FROM change_log),
          (SELECT COUNT(*) FROM change_records), (SELECT COUNT(*) FROM manifests),
          (SELECT COUNT(*) FROM manifest_records), (SELECT COALESCE(SUM(byte_count),0) FROM change_log),
          (SELECT COUNT(*) FROM manifest_parts WHERE loaded=0),
          (SELECT COUNT(*) FROM manifest_order_nodes WHERE expanded=0)
        """).first!
      let pending = try connection.rows("""
        WITH pending_hashes AS (
          SELECT part_hash AS hash FROM manifest_parts WHERE loaded=0
          UNION SELECT hash FROM manifest_order_nodes WHERE expanded=0
        )
        SELECT COUNT(b.hash), COALESCE(SUM(length(b.data)),0),
          COUNT(*)-COUNT(b.hash) FROM pending_hashes p LEFT JOIN blobs b ON b.hash=p.hash
        """).first!
      let outgoing = try storageOutgoing(connection, through: sequence)
      let pageSize = try storageScalar(connection, "PRAGMA page_size")
      let pageCount = try storageScalar(connection, "PRAGMA page_count")
      let freelist = try storageScalar(connection, "PRAGMA freelist_count")
      guard pageSize > 0, freelist <= pageCount else {
        throw NotebookStorageError.corruptRecord("storage usage pages")
      }
      try connection.checkReadAllowance()
      guard currentSQL === database, !database.writable,
        database.readSnapshotIdentity == snapshotID else { throw NotebookStorageError.transactionConflict }
      let files = zip(before, urls.map(NotebookStorageFileAttributes.sample)).map { first, last in first.sample(ending: last) }
      try Task.checkCancellation()
      let sampleStatus: NotebookStorageUsage.SampleStatus = files.contains { $0.status == .unavailable }
        || files[0].status == .missing ? .incomplete : files.contains { $0.status == .changed } ? .changed : .sampled
      return try .init(cut: .init(workspaceID: workspaceID, snapshotID: snapshotID,
          readRevision: revision, changeSequence: sequence, journalGeneration: generation),
        logicalStatus: .snapshot, blobs: blobs,
        currentRecords: .init(recordCount: storageInteger(counts, 0), payload: currentPayload),
        retainedHistory: .init(changeCount: storageInteger(counts, 1), changeRecordCount: storageInteger(counts, 2),
          manifestCount: storageInteger(counts, 3), manifestRecordCount: storageInteger(counts, 4),
          changeManifestBytes: storageInteger(counts, 5), payload: historyPayload),
        incoming: .init(pendingPartCount: storageInteger(counts, 6), pendingOrderNodeCount: storageInteger(counts, 7),
          presentPayload: storagePayload(pending, offset: 0), missingBlobCount: storageInteger(pending, 2)),
        outgoing: outgoing, indexedReferences: indexedPayload,
        unclassifiedBlobs: .init(count: blobs.count-indexedPayload.count, bytes: blobs.bytes-indexedPayload.bytes),
        reachability: .partial, physical: .init(database: files[0], wal: files[1], shm: files[2],
          pageSize: pageSize, pageCount: pageCount, freelistPages: freelist,
          startedAt: startedAt, finishedAt: Date(), sampleStatus: sampleStatus))
    }
  }

  private func storageHistoryReferences(_ connection: NotebookSQLConnection) throws -> String {
    "SELECT manifest_hash AS hash FROM change_log UNION SELECT hash FROM manifests "
      + "UNION SELECT manifest_hash FROM received_transactions "
      + "UNION SELECT blob_hash FROM change_records WHERE blob_hash IS NOT NULL "
      + "UNION SELECT blob_hash FROM manifest_records WHERE blob_hash IS NOT NULL "
      + "UNION SELECT part_hash FROM manifest_parts UNION SELECT hash FROM manifest_order_nodes"
      + (try storageOptionalReferences(connection, tables: [
        ("manifest_inverse_roots", ["receipt_hash", "root_hash"]), ("manifest_inverse_parts", ["hash"]),
        ("manifest_inverse_blobs", ["hash"]), ("manifest_ink_bodies", ["hash"]),
        ("manifest_program_roots", ["hash"]), ("manifest_program_parts", ["hash"])]))
  }

  /// These optional indexes are created by their existing content/transport
  /// owners. Absence is not an instruction to create them during a diagnostic.
  private func storageOptionalReferences(_ connection: NotebookSQLConnection,
    tables: [(String, [String])]) throws -> String {
    let names = tables.map { NotebookSQLValue.text($0.0) }
    let present = try connection.rows("SELECT name,type FROM sqlite_master WHERE name IN ("
      + Array(repeating: "?", count: names.count).joined(separator: ",") + ")", names)
    guard present.allSatisfy({ $0[1].text == "table" }) else { throw NotebookStorageError.corruptRecord("storage usage index") }
    let presentNames = Set(present.compactMap { $0[0].text })
    return tables.filter { presentNames.contains($0.0) }.flatMap { table, columns in
      columns.map { " UNION SELECT \($0) FROM \(table) WHERE \($0) IS NOT NULL" }
    }.joined()
  }

  private func storageOutgoing(_ connection: NotebookSQLConnection, through sequence: UInt64) throws -> NotebookStorageUsage.Outgoing {
    var knownPeerCount: Int64 = 0, peers: [NotebookStorageUsage.Peer] = []
    var device: UUID?, acknowledged: Int64 = 0
    func finishPeer() throws {
      guard let device else { return }
      knownPeerCount += 1
      guard peers.count < 64 else { return }
      let key = device.uuidString.lowercased()
      let retired = try !connection.rows("SELECT 1 FROM metadata WHERE key=?", [.text("retired_peer:" + key)]).isEmpty
      let pending: [NotebookSQLValue] = retired ? [.integer(0), .integer(0)] : try connection.rows(
        "SELECT COUNT(*),COALESCE(SUM(byte_count),0) FROM change_log WHERE sequence>? AND sequence<=?",
        [.integer(acknowledged), .integer(Int64(sequence))]).first!
      peers.append(try .init(peerID: device, retired: retired, acknowledgedSequence: UInt64(acknowledged),
        pendingChangeCount: storageInteger(pending, 0), pendingManifestBytes: storageInteger(pending, 1)))
    }
    // Streaming the cursor metadata validates even the omitted tail. Only one
    // device's scalar cursor and the bounded final peer list are retained.
    try connection.forEachRow("SELECT peer_id,direction,sequence FROM peer_cursors ORDER BY peer_id,direction") { row in
      guard let key = row[0].text, let source = NotebookReplicationSource(cursorKey: key),
        let direction = row[1].text, let cursor = row[2].integer, cursor >= 0,
        direction == "incoming" || (direction == "outgoing" && key == source.deviceID.uuidString.lowercased()
          && UInt64(cursor) <= sequence) else { throw NotebookStorageError.corruptRecord("peer_cursors") }
      if device != source.deviceID {
        try finishPeer(); device = source.deviceID; acknowledged = 0
      }
      if direction == "outgoing" { acknowledged = cursor }
    }
    try finishPeer()
    return .init(knownPeerCount: knownPeerCount, peers: peers, truncated: knownPeerCount > Int64(peers.count))
  }

  private func storageScalar(_ connection: NotebookSQLConnection, _ query: String) throws -> Int64 {
    try storageInteger(connection.rows(query).first!, 0)
  }

  private func storageInteger(_ row: [NotebookSQLValue], _ index: Int) throws -> Int64 {
    guard let value = row[index].integer, value >= 0 else { throw NotebookStorageError.corruptRecord("storage usage scalar") }
    return value
  }

  private func storagePayload(_ row: [NotebookSQLValue], offset: Int) throws -> NotebookStorageUsage.Payload {
    try .init(count: storageInteger(row, offset), bytes: storageInteger(row, offset+1))
  }
}

private struct NotebookStorageFileAttributes: Equatable {
  let status: NotebookStorageUsage.FileStatus
  var bytes: Int64? = nil
  var device: UInt64? = nil
  var inode: UInt64? = nil
  var modified: Date? = nil

  static func sample(_ url: URL) -> Self {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let bytes = attributes[.size] as? NSNumber, bytes.int64Value >= 0,
        let device = attributes[.systemNumber] as? NSNumber,
        let inode = attributes[.systemFileNumber] as? NSNumber,
        let modified = attributes[.modificationDate] as? Date else { return .init(status: .unavailable) }
      return .init(status: .unchanged, bytes: bytes.int64Value, device: device.uint64Value,
        inode: inode.uint64Value, modified: modified)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return .init(status: .missing)
    } catch { return .init(status: .unavailable) }
  }

  func sample(ending end: Self) -> NotebookStorageUsage.FileSample {
    let status: NotebookStorageUsage.FileStatus = self.status == .unavailable || end.status == .unavailable
      ? .unavailable : self == end ? end.status : .changed
    return .init(status: status, bytes: end.bytes)
  }
}
