import Foundation

public struct NotebookReplicaCloudBinding: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case unconfigured, ready, invalid }
  public enum Issue: String, Codable, Sendable { case incompleteSchema, invalidControl }
  public let status: Status
  public let account: String?
  public let enabled: Bool?
  public let issue: Issue?
}

public struct NotebookReplicaCloudAccount: Codable, Equatable, Sendable {
  public let account: String
  public let journalGeneration: UUID
  /// Cloud upload progress, never a paired device's accepted prefix.
  public let uploadedThrough: UInt64
  public let engineByteCount: Int64?
}

public enum NotebookReplicaCloudPendingObservation: Codable, Equatable, Sendable {
  case export(account: String, ready: Bool, deliveryByteCount: Int64, planID: UUID?, planByteCount: Int64?,
    blobCursor: UInt64, recordCursor: UInt64)
  case outbox(account: String, recordID: String, blobHash: String?, offset: Int64,
    totalBytes: Int64, deliveryByteCount: Int64?)
  case incoming(account: String, recordID: String, source: NotebookReplicationSource,
    senderSequence: UInt64, snapshot: Bool, deliveryByteCount: Int64)
  case chunk(account: String, blobHash: String, offset: Int64, totalBytes: Int64, receivedByteCount: Int64)
}

public struct NotebookReplicaCloudAccountPage: Codable, Equatable, Sendable {
  public let cut: NotebookReplicaInventoryCut
  public let entries: [NotebookReplicaCloudAccount]
  public let next: NotebookReplicaInventoryCursor?
  /// Completeness requires preceding pages in this cut or a verified native anchor.
  public let complete: Bool
  public let scalarWitnessHash: String
}

public struct NotebookReplicaCloudPendingPage: Codable, Equatable, Sendable {
  public let cut: NotebookReplicaInventoryCut
  public let entries: [NotebookReplicaCloudPendingObservation]
  public let next: NotebookReplicaInventoryCursor?
  /// Completeness requires preceding pages in this cut or a verified native anchor.
  public let complete: Bool
  public let scalarWitnessHash: String
}

/// A retained derivative upload-ACK cache entry. Its presence is neither pending
/// work nor acknowledgement from an installed peer replica.
public struct NotebookReplicaCloudReceiptCacheEntry: Codable, Equatable, Sendable {
  public let account: String
  public let recordID: String
}

public struct NotebookReplicaCloudReceiptCachePage: Codable, Equatable, Sendable {
  public let cut: NotebookReplicaInventoryCut
  public let entries: [NotebookReplicaCloudReceiptCacheEntry]
  public let receiptCount: Int
  public let next: NotebookReplicaInventoryCursor?
  /// Completeness requires preceding pages in this cut or a verified native anchor.
  public let complete: Bool
  public let scalarWitnessHash: String
}

/// Optional cloud metadata shares the caller's existing SQL/cancellation lease.
/// This reader never prepares cloud tables, reads engine/delivery/asset bodies,
/// acknowledges a record, or makes a local upload into evidence of peer receipt.
enum NotebookReplicaCloudInventory {
  private static let columns: [(String, [String])] = [
    ("cloud_control", ["id", "account", "enabled"]),
    ("cloud_accounts", ["account", "engine", "cursor", "generation"]),
    ("cloud_exports", ["account", "delivery", "plan", "ready", "blob_cursor", "record_cursor"]),
    ("cloud_outbox", ["account", "id", "delivery", "hash", "offset", "total"]),
    ("cloud_uploaded", ["account", "id"]),
    ("cloud_inbox", ["account", "id", "source", "sequence", "snapshot", "delivery"]),
    ("cloud_chunks", ["account", "hash", "offset", "total", "data"])
  ]

  static func binding(in database: NotebookSQLConnection) throws -> NotebookReplicaCloudBinding {
    let schema = try database.rows("""
      SELECT name,CASE WHEN type='table' THEN 1 ELSE 0 END FROM sqlite_master
      WHERE name IN ('cloud_control','cloud_accounts','cloud_exports','cloud_outbox',
        'cloud_uploaded','cloud_inbox','cloud_chunks') ORDER BY name
      """)
    if schema.isEmpty { return .init(status: .unconfigured, account: nil, enabled: false, issue: nil) }
    guard schema.count == columns.count, schema.allSatisfy({ $0[1].integer == 1 }) else {
      return .init(status: .invalid, account: nil, enabled: nil, issue: .incompleteSchema)
    }
    for (table, required) in columns {
      // Fixed names only. The predicate returns at most the required columns;
      // even a damaged schema cannot copy arbitrary column names into Swift.
      let names = required.map { "'" + $0 + "'" }.joined(separator: ",")
      let actual = try database.rows("SELECT name FROM pragma_table_info(?) WHERE name IN (" + names + ")",
        [.text(table)]).compactMap { $0[0].text }
      guard Set(actual) == Set(required), actual.count == required.count else {
        return .init(status: .invalid, account: nil, enabled: nil, issue: .incompleteSchema)
      }
    }
    let rows = try database.rows("""
      SELECT CASE WHEN typeof(id)='integer' AND id=1 THEN id END,
        CASE WHEN account IS NULL THEN 1 ELSE 0 END,
        CASE WHEN typeof(account)='text' AND length(CAST(account AS BLOB)) BETWEEN 1 AND 512
          THEN account END,
        CASE WHEN typeof(enabled)='integer' AND enabled IN (0,1) THEN enabled END
      FROM cloud_control ORDER BY id LIMIT 2
      """)
    guard rows.count == 1, let row = rows.first, row[0].integer == 1,
      let enabled = row[3].integer, row[1].integer == 1 || row[2].text != nil,
      enabled == 0 || row[2].text != nil else {
      return .init(status: .invalid, account: nil, enabled: nil, issue: .invalidControl)
    }
    if let account = row[2].text,
      try database.rows("SELECT 1 FROM cloud_accounts WHERE account=? LIMIT 1", [.text(account)]).isEmpty {
      return .init(status: .invalid, account: account, enabled: enabled == 1, issue: .invalidControl)
    }
    return .init(status: .ready, account: row[2].text, enabled: enabled == 1, issue: nil)
  }

  static func accounts(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryCursor?, limit: Int) throws -> NotebookReplicaCloudAccountPage {
    try NotebookReplicaInventory.validate(in: database, cut: cut, cursor: cursor, section: .cloudAccounts, limit: limit)
    return try accountPage(in: database, cut: cut, after: cursor?.position, limit: limit)
  }

  static func accounts(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    resuming position: NotebookReplicaInventoryPosition,
    expectedControlObservation: NotebookReplicaInventoryCut.ControlObservation, limit: Int) throws -> NotebookReplicaCloudAccountPage {
    try NotebookReplicaInventory.validateResume(in: database, cut: cut, position: position,
      expected: expectedControlObservation, section: .cloudAccounts, limit: limit)
    return try accountPage(in: database, cut: cut, after: position, limit: limit)
  }

  private static func accountPage(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryPosition?, limit: Int) throws -> NotebookReplicaCloudAccountPage {
    try requireReadable(cut.cloud)
    if let cursor {
      guard cursor.kind == 0, (1...512).contains(cursor.key.utf8.count), cursor.subkey.isEmpty,
        cursor.offset == 0 else { throw corrupt("account cursor") }
    }
    var entries: [NotebookReplicaCloudAccount] = [], lastKey = cursor?.key ?? ""
    if cut.cloud.status == .ready {
      let predicate = cursor == nil ? "" : "WHERE account>?"
      let arguments: [NotebookSQLValue] = (cursor.map { [.text($0.key)] } ?? []) + [.integer(Int64(limit))]
      let rows = try database.rows("""
        SELECT CASE WHEN typeof(account)='text' AND length(CAST(account AS BLOB)) BETWEEN 1 AND 512
            THEN account END,
          CASE WHEN typeof(generation)='text' AND length(CAST(generation AS BLOB))=36 THEN generation END,
          CASE WHEN typeof(cursor)='integer' AND cursor>=0 THEN cursor END,
          CASE WHEN engine IS NULL OR typeof(engine)='blob' THEN 1 ELSE 0 END,
          CASE WHEN typeof(engine)='blob' THEN length(engine) END
        FROM cloud_accounts \(predicate) ORDER BY account LIMIT ?
        """, arguments)
      for row in rows {
        guard let account = row[0].text, (cursor == nil && entries.isEmpty) || precedes(lastKey, account),
          row[3].integer == 1 else { throw corrupt("account header") }
        let uploaded = try NotebookReplicaInventory.unsigned(row[2], field: "cloud uploaded cursor")
        guard uploaded <= (cut.acceptedLocalPrefix?.sequence ?? 0) else { throw corrupt("uploaded cursor") }
        entries.append(try .init(account: account,
          journalGeneration: NotebookReplicaInventory.uuid(row[1].text, field: "cloud generation"),
          uploadedThrough: uploaded, engineByteCount: row[4].integer))
        lastKey = account
      }
    }
    let next = entries.count == limit ? NotebookReplicaInventoryCursor(workspaceID: cut.workspaceID,
      borrowedSnapshotID: cut.borrowedSnapshotID, section: .cloudAccounts, kind: 0,
      key: lastKey, subkey: "", offset: 0) : nil
    return try .init(cut: cut, entries: entries, next: next, complete: next == nil,
      scalarWitnessHash: NotebookReplicaInventory.witness(entries, domain: "notebook.replica.cloud-accounts.v1"))
  }

  static func pending(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryCursor?, limit: Int) throws -> NotebookReplicaCloudPendingPage {
    try NotebookReplicaInventory.validate(in: database, cut: cut, cursor: cursor, section: .cloudPending, limit: limit)
    return try pendingPage(in: database, cut: cut, after: cursor?.position, limit: limit)
  }

  static func pending(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    resuming position: NotebookReplicaInventoryPosition,
    expectedControlObservation: NotebookReplicaInventoryCut.ControlObservation, limit: Int) throws -> NotebookReplicaCloudPendingPage {
    try NotebookReplicaInventory.validateResume(in: database, cut: cut, position: position,
      expected: expectedControlObservation, section: .cloudPending, limit: limit)
    return try pendingPage(in: database, cut: cut, after: position, limit: limit)
  }

  private static func pendingPage(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryPosition?, limit: Int) throws -> NotebookReplicaCloudPendingPage {
    try requireReadable(cut.cloud)
    if let cursor {
      guard (1...4).contains(cursor.kind), (1...512).contains(cursor.key.utf8.count),
        cursor.subkey.utf8.count <= 86, cursor.offset >= 0 else { throw corrupt("pending cursor") }
      switch cursor.kind {
      case 1:
        guard cursor.subkey.isEmpty, cursor.offset == 0 else { throw corrupt("pending cursor") }
      case 2:
        if cursor.subkey.hasPrefix("d.") {
          try deliveryID(cursor.subkey)
          guard cursor.offset == 0 else { throw corrupt("pending cursor") }
        } else {
          let parts = cursor.subkey.split(separator: ".", omittingEmptySubsequences: false)
          guard parts.count == 3, parts[0] == "b", NotebookTransportFraming.isSHA256(String(parts[1])),
            String(cursor.offset) == String(parts[2]), cursor.offset <= NotebookTransportLimits.maximumBlobBytes,
            cursor.offset % Int64(NotebookCloudRecord.chunkBytes) == 0 else { throw corrupt("pending cursor") }
        }
      case 3:
        try deliveryID(cursor.subkey)
        guard cursor.offset == 0 else { throw corrupt("pending cursor") }
      case 4:
        _ = try NotebookReplicaInventory.hash(cursor.subkey, field: "cloud chunk cursor")
        guard cursor.offset <= NotebookTransportLimits.maximumBlobBytes,
          cursor.offset % Int64(NotebookCloudRecord.chunkBytes) == 0 else { throw corrupt("pending cursor") }
      default: throw corrupt("pending cursor")
      }
    }
    var entries: [NotebookReplicaCloudPendingObservation] = []
    var lastKind = cursor?.kind ?? 0, lastAccount = cursor?.key ?? ""
    var lastKey = cursor?.subkey ?? "", lastOffset = cursor?.offset ?? 0
    if cut.cloud.status == .ready {
      var kindToRead = cursor?.kind ?? 1
      var afterPosition = cursor
      while entries.count < limit && kindToRead <= 4 {
        let rows = try pendingRows(in: database, kind: kindToRead, after: afterPosition, limit: limit - entries.count)
        for row in rows {
          guard let rawKind = row[0].integer, let account = row[1].text, let key = row[2].text,
            let offset = row[3].integer else { throw corrupt("pending header") }
          let kind = Int(rawKind)
          guard kind > lastKind || (kind == lastKind && (precedes(lastAccount, account) ||
            (sameBytes(account, lastAccount) && (precedes(lastKey, key) || (sameBytes(key, lastKey) && offset > lastOffset))))) else {
            throw corrupt("pending position")
          }
          let entry: NotebookReplicaCloudPendingObservation
          switch kind {
          case 1:
            guard key.isEmpty, offset == 0, let ready = row[10].integer else { throw corrupt("export header") }
            if let planBytes = row[9].integer, planBytes < 0 { throw corrupt("export plan") }
            let planID: UUID?
            if row[9].integer != nil { planID = try NotebookReplicaInventory.uuid(row[15].text, field: "cloud export plan") }
            else { planID = nil }
            guard ready == 1 || planID != nil else { throw corrupt("export plan") }
            entry = try .export(account: account, ready: ready == 1,
              deliveryByteCount: bytes(row[8], field: "export bytes"), planID: planID, planByteCount: row[9].integer,
              blobCursor: NotebookReplicaInventory.unsigned(row[11], field: "cloud blob cursor"),
              recordCursor: NotebookReplicaInventory.unsigned(row[12], field: "cloud record cursor"))
          case 2:
            guard let total = row[13].integer else { throw corrupt("outbox total") }
            if let payloadBytes = row[8].integer {
              try deliveryID(key)
              guard row[14].integer == 1, offset == 0, total == 0 else { throw corrupt("outbox delivery") }
              entry = try .outbox(account: account, recordID: key, blobHash: nil, offset: offset,
                totalBytes: total, deliveryByteCount: bytes(.integer(payloadBytes), field: "outbox bytes"))
            } else {
              let hash = try NotebookReplicaInventory.hash(row[4].text, field: "cloud outbox hash")
              let record = try NotebookCloudRecord.chunk(hash: hash, offset: offset, totalBytes: total)
              guard record.id == key else { throw corrupt("outbox chunk ID") }
              entry = .outbox(account: account, recordID: key, blobHash: hash, offset: offset,
                totalBytes: total, deliveryByteCount: nil)
            }
          case 3:
            try deliveryID(key)
            guard offset == 0, let sourceKey = row[5].text,
              let source = NotebookReplicationSource(cursorKey: sourceKey), let snapshot = row[7].integer else {
              throw corrupt("incoming header")
            }
            entry = try .incoming(account: account, recordID: key, source: source,
              senderSequence: NotebookReplicaInventory.unsigned(row[6], positive: true, field: "cloud incoming sequence"),
              snapshot: snapshot == 1, deliveryByteCount: bytes(row[8], field: "incoming bytes"))
          case 4:
            let hash = try NotebookReplicaInventory.hash(row[4].text, field: "cloud chunk hash")
            guard key == hash, let total = row[13].integer else { throw corrupt("chunk header") }
            let record = try NotebookCloudRecord.chunk(hash: hash, offset: offset, totalBytes: total)
            let count = try bytes(row[8], field: "chunk bytes")
            guard count == Int64(record.byteCount) else { throw corrupt("chunk length") }
            entry = .chunk(account: account, blobHash: hash, offset: offset, totalBytes: total, receivedByteCount: count)
          default: throw corrupt("pending kind")
          }
          entries.append(entry); lastKind = kind; lastAccount = account; lastKey = key; lastOffset = offset
        }
        kindToRead += 1; afterPosition = nil
      }
    }
    let next = entries.count == limit ? NotebookReplicaInventoryCursor(workspaceID: cut.workspaceID,
      borrowedSnapshotID: cut.borrowedSnapshotID, section: .cloudPending, kind: lastKind,
      key: lastAccount, subkey: lastKey, offset: lastOffset) : nil
    return try .init(cut: cut, entries: entries, next: next, complete: next == nil,
      scalarWitnessHash: NotebookReplicaInventory.witness(entries, domain: "notebook.replica.cloud-pending.v1"))
  }

  private static func pendingRows(in database: NotebookSQLConnection, kind: Int,
    after: NotebookReplicaInventoryPosition?, limit: Int) throws -> [[NotebookSQLValue]] {
    let projection: String, table: String, order: String, seek: String
    var arguments: [NotebookSQLValue] = []
    switch kind {
    case 1:
      table = "cloud_exports"; order = "account"; seek = "account>?"
      projection = """
        1,account,'',0,NULL,NULL,NULL,NULL,
        CASE WHEN typeof(delivery)='blob' THEN length(delivery) END,
        CASE WHEN plan IS NULL THEN NULL WHEN typeof(plan)='text' THEN length(CAST(plan AS BLOB)) ELSE -1 END,
        ready,blob_cursor,record_cursor,NULL,plan
        """
      if let after { arguments = [.text(after.key)] }
    case 2:
      table = "cloud_outbox"; order = "account,id"; seek = "(account,id)>(?,?)"
      projection = """
        2,account,id,offset,hash,NULL,NULL,NULL,
        CASE WHEN delivery IS NULL THEN NULL WHEN typeof(delivery)='blob' THEN length(delivery) ELSE -1 END,
        NULL,NULL,NULL,NULL,total,NULL
        """
      if let after { arguments = [.text(after.key), .text(after.subkey)] }
    case 3:
      table = "cloud_inbox"; order = "account,id"; seek = "(account,id)>(?,?)"
      projection = """
        3,account,id,0,NULL,source,sequence,snapshot,
        CASE WHEN typeof(delivery)='blob' THEN length(delivery) END,NULL,NULL,NULL,NULL,NULL,NULL
        """
      if let after { arguments = [.text(after.key), .text(after.subkey)] }
    case 4:
      table = "cloud_chunks"; order = "account,hash,offset"; seek = "(account,hash,offset)>(?,?,?)"
      projection = """
        4,account,hash,offset,hash,NULL,NULL,NULL,
        CASE WHEN typeof(data)='blob' THEN length(data) END,NULL,NULL,NULL,NULL,total,NULL
        """
      if let after { arguments = [.text(after.key), .text(after.subkey), .integer(after.offset)] }
    default: throw corrupt("pending kind")
    }
    arguments.append(.integer(Int64(limit)))
    let predicate = after == nil ? "" : "WHERE " + seek
    // LIMIT applies to a single existing primary-key seek before the scalar
    // projection, without sorting/materializing all pending delivery bodies.
    return try database.rows("""
      WITH pending(kind,account,key,position,hash,source,sequence,snapshot,payload,plan,ready,blob_cursor,record_cursor,total,plan_key) AS (
        SELECT \(projection) FROM \(table) \(predicate) ORDER BY \(order) LIMIT ?
      )
      SELECT kind,
        CASE WHEN typeof(account)='text' AND length(CAST(account AS BLOB)) BETWEEN 1 AND 512 THEN account END,
        CASE WHEN typeof(key)='text' AND length(CAST(key AS BLOB))<=86 THEN key END,
        CASE WHEN typeof(position)='integer' AND position>=0 THEN position END,
        CASE WHEN typeof(hash)='text' AND length(CAST(hash AS BLOB))=64 THEN hash END,
        CASE WHEN typeof(source)='text' AND length(CAST(source AS BLOB)) IN (36,73) THEN source END,
        CASE WHEN typeof(sequence)='integer' AND sequence>0 THEN sequence END,
        CASE WHEN typeof(snapshot)='integer' AND snapshot IN (0,1) THEN snapshot END,
        payload,plan,
        CASE WHEN typeof(ready)='integer' AND ready IN (0,1) THEN ready END,
        CASE WHEN typeof(blob_cursor)='integer' AND blob_cursor>=0 THEN blob_cursor END,
        CASE WHEN typeof(record_cursor)='integer' AND record_cursor>=0 THEN record_cursor END,
        CASE WHEN typeof(total)='integer' AND total>=0 THEN total END,
        CASE WHEN hash IS NULL THEN 1 ELSE 0 END,
        CASE WHEN typeof(plan_key)='text' AND length(CAST(plan_key AS BLOB))=36 THEN plan_key END
      FROM pending ORDER BY account,key,position
      """, arguments)
  }

  static func receipts(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryCursor?, limit: Int) throws -> NotebookReplicaCloudReceiptCachePage {
    try NotebookReplicaInventory.validate(in: database, cut: cut, cursor: cursor, section: .cloudReceipts, limit: limit)
    return try receiptPage(in: database, cut: cut, after: cursor?.position, limit: limit)
  }

  static func receipts(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    resuming position: NotebookReplicaInventoryPosition,
    expectedControlObservation: NotebookReplicaInventoryCut.ControlObservation, limit: Int) throws -> NotebookReplicaCloudReceiptCachePage {
    try NotebookReplicaInventory.validateResume(in: database, cut: cut, position: position,
      expected: expectedControlObservation, section: .cloudReceipts, limit: limit)
    return try receiptPage(in: database, cut: cut, after: position, limit: limit)
  }

  private static func receiptPage(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryPosition?, limit: Int) throws -> NotebookReplicaCloudReceiptCachePage {
    try requireReadable(cut.cloud)
    if let cursor {
      guard cursor.kind == 0, (1...512).contains(cursor.key.utf8.count),
        cursor.subkey.utf8.count <= 86, cursor.offset == 0 else { throw corrupt("receipt cache cursor") }
      try recordID(cursor.subkey)
    }
    var entries: [NotebookReplicaCloudReceiptCacheEntry] = []
    var lastAccount = cursor?.key ?? "", lastKey = cursor?.subkey ?? ""
    if cut.cloud.status == .ready {
      let predicate = cursor == nil ? "" : "WHERE (account,id)>(?,?)"
      let arguments: [NotebookSQLValue] = (cursor.map { [.text($0.key), .text($0.subkey)] } ?? []) + [.integer(Int64(limit))]
      let rows = try database.rows("""
        SELECT CASE WHEN typeof(account)='text' AND length(CAST(account AS BLOB)) BETWEEN 1 AND 512
            THEN account END,
          CASE WHEN typeof(id)='text' AND length(CAST(id AS BLOB))<=86 THEN id END
        FROM cloud_uploaded \(predicate) ORDER BY account,id LIMIT ?
        """, arguments)
      for row in rows {
        guard let account = row[0].text, let id = row[1].text,
          (cursor == nil && entries.isEmpty) || precedes(lastAccount, account)
            || (sameBytes(lastAccount, account) && precedes(lastKey, id)) else { throw corrupt("receipt cache header") }
        try recordID(id)
        entries.append(.init(account: account, recordID: id)); lastAccount = account; lastKey = id
      }
    }
    let next = entries.count == limit ? NotebookReplicaInventoryCursor(workspaceID: cut.workspaceID,
      borrowedSnapshotID: cut.borrowedSnapshotID, section: .cloudReceipts, kind: 0,
      key: lastAccount, subkey: lastKey, offset: 0) : nil
    return try .init(cut: cut, entries: entries, receiptCount: entries.count, next: next, complete: next == nil,
      scalarWitnessHash: NotebookReplicaInventory.witness(entries, domain: "notebook.replica.cloud-receipt-cache.v1"))
  }

  private static func requireReadable(_ binding: NotebookReplicaCloudBinding) throws {
    guard binding.status != .invalid else { throw corrupt("schema/control") }
  }
  private static func deliveryID(_ value: String) throws {
    guard value.hasPrefix("d."), NotebookTransportFraming.isSHA256(String(value.dropFirst(2))) else {
      throw corrupt("delivery ID")
    }
  }
  private static func recordID(_ value: String) throws {
    if value.hasPrefix("d.") { try deliveryID(value); return }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "b", NotebookTransportFraming.isSHA256(String(parts[1])),
      let offset = Int64(parts[2]), String(offset) == String(parts[2]),
      (0...NotebookTransportLimits.maximumBlobBytes).contains(offset),
      offset % Int64(NotebookCloudRecord.chunkBytes) == 0 else { throw corrupt("receipt cache record ID") }
  }
  private static func bytes(_ value: NotebookSQLValue, field: String) throws -> Int64 {
    guard let result = value.integer, (0...NotebookTransportLimits.maximumBlobBytes).contains(result) else {
      throw corrupt(field)
    }
    return result
  }
  // Cloud account keys can be Unicode. Match SQLite's BINARY primary-key
  // order rather than Swift's canonically equivalent String comparison.
  private static func precedes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
  private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
  private static func corrupt(_ field: String) -> NotebookStorageError { NotebookReplicaInventory.corrupt("cloud " + field) }
}
