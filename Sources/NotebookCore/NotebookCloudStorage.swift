import CryptoKit
import Foundation

public struct NotebookCloudConfiguration: Sendable, Equatable {
  public let account: String?
  public let enabled: Bool
}

/// A transport record, not another document representation. Assets contain
/// chunks of the exact SHA-addressed blob used by direct replication.
public struct NotebookCloudRecord: Sendable, Equatable {
  public static let chunkBytes = 1_048_576
  public let id: String
  public let delivery: NotebookReplicationDelivery?
  public let hash: String?
  public let offset: Int64
  public let totalBytes: Int64
  public var byteCount: Int { Int(min(Int64(Self.chunkBytes), totalBytes - offset)) }

  private init(id: String, delivery: NotebookReplicationDelivery?, hash: String?, offset: Int64, totalBytes: Int64) {
    self.id = id; self.delivery = delivery; self.hash = hash; self.offset = offset; self.totalBytes = totalBytes
  }

  static func delivery(_ value: NotebookReplicationDelivery) throws -> Self {
    let data = try NotebookStore.storageEncoder.encode(value)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return .init(id: "d." + digest, delivery: value, hash: nil, offset: 0, totalBytes: 0)
  }
  public static func chunk(hash: String, offset: Int64, totalBytes: Int64) throws -> Self {
    guard NotebookTransportFraming.isSHA256(hash), (0...NotebookTransportLimits.maximumBlobBytes).contains(totalBytes),
      offset >= 0, offset % Int64(chunkBytes) == 0, offset < totalBytes || (offset == 0 && totalBytes == 0) else { throw NotebookTransportError.invalidBlob }
    return .init(id: "b." + hash + "." + String(offset), delivery: nil, hash: hash, offset: offset, totalBytes: totalBytes)
  }
  public init(delivery: NotebookReplicationDelivery) throws { self = try Self.delivery(delivery) }
}

extension NotebookStore {
  public func prepareCloudStorage() throws {
    try commandTransaction(advancesReadRevision: false) {
      let db = currentSQL!
      for sql in [
        "CREATE TABLE IF NOT EXISTS cloud_control(id INTEGER PRIMARY KEY CHECK(id=1),account TEXT,enabled INTEGER NOT NULL)",
        "INSERT OR IGNORE INTO cloud_control VALUES(1,NULL,0)",
        "CREATE TABLE IF NOT EXISTS cloud_accounts(account TEXT PRIMARY KEY,engine BLOB,cursor INTEGER NOT NULL DEFAULT 0,generation TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS cloud_exports(account TEXT PRIMARY KEY,delivery BLOB NOT NULL)",
        "CREATE TABLE IF NOT EXISTS cloud_outbox(account TEXT NOT NULL,id TEXT NOT NULL,delivery BLOB,hash TEXT,offset INTEGER NOT NULL,total INTEGER NOT NULL,PRIMARY KEY(account,id))",
        "CREATE TABLE IF NOT EXISTS cloud_uploaded(account TEXT NOT NULL,id TEXT NOT NULL,PRIMARY KEY(account,id))",
        "CREATE TABLE IF NOT EXISTS cloud_inbox(account TEXT NOT NULL,id TEXT NOT NULL,source TEXT NOT NULL,sequence INTEGER NOT NULL,snapshot INTEGER NOT NULL,delivery BLOB NOT NULL,PRIMARY KEY(account,id))",
        "CREATE INDEX IF NOT EXISTS cloud_inbox_source ON cloud_inbox(account,source,sequence)",
        "CREATE TABLE IF NOT EXISTS cloud_chunks(account TEXT NOT NULL,hash TEXT NOT NULL,offset INTEGER NOT NULL,total INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(account,hash,offset))"
      ] { try db.run(sql) }
      let columns = Set(try db.rows("PRAGMA table_info(cloud_exports)").compactMap { $0[1].text })
      for (name, definition) in [("plan", "TEXT"), ("ready", "INTEGER NOT NULL DEFAULT 1"),
        ("blob_cursor", "INTEGER NOT NULL DEFAULT 0"), ("record_cursor", "INTEGER NOT NULL DEFAULT 0")] where !columns.contains(name) {
        try db.run("ALTER TABLE cloud_exports ADD COLUMN " + name + " " + definition)
      }
    }
  }

  public func cloudConfiguration() throws -> NotebookCloudConfiguration {
    try sqlRead {
      let row = try $0.rows("SELECT account,enabled FROM cloud_control WHERE id=1").first!
      return .init(account: row[0].text, enabled: row[1].integer == 1)
    }
  }

  public func enableCloud(account: String, source: NotebookReplicationSource) throws {
    guard !account.isEmpty, account.utf8.count <= 512 else { throw NotebookStorageError.invalidTransaction("cloud account") }
    try commandTransaction(advancesReadRevision: false) {
      let db = currentSQL!
      if let old = try db.rows("SELECT generation FROM cloud_accounts WHERE account=?", [.text(account)]).first?[0].text {
        guard old == source.generation.uuidString.lowercased() else { throw NotebookStorageError.invalidTransaction("cloud journal changed; prepare a new device identity") }
      } else {
        try db.run("INSERT INTO cloud_accounts(account,generation) VALUES(?,?)", [.text(account), .text(source.generation.uuidString.lowercased())])
      }
      try db.run("UPDATE cloud_control SET account=?,enabled=1 WHERE id=1", [.text(account)])
    }
  }

  public func disableCloud(account: String? = nil) throws {
    try commandTransaction(advancesReadRevision: false) {
      if let account { try currentSQL!.run("UPDATE cloud_control SET enabled=0 WHERE id=1 AND account=?", [.text(account)]) }
      else { try currentSQL!.run("UPDATE cloud_control SET enabled=0 WHERE id=1") }
    }
  }

  func requireCloudAccount(_ account: String) throws {
    let configuration = try cloudConfiguration()
    guard configuration.enabled, configuration.account == account else { throw NotebookTransportError.disconnected }
  }

  public func cloudHasUploadedCurrentContent(account: String) throws -> Bool {
    try sqlRead { db in
      try requireCloudAccount(account)
      let uploaded = UInt64(try db.rows("SELECT cursor FROM cloud_accounts WHERE account=?", [.text(account)]).first?[0].integer ?? 0)
      return try uploaded >= currentChangeCursor() && db.rows("SELECT 1 FROM cloud_outbox WHERE account=? LIMIT 1", [.text(account)]).isEmpty
        && db.rows("SELECT 1 FROM cloud_exports WHERE account=? LIMIT 1", [.text(account)]).isEmpty
    }
  }

  public func cloudEngineState(account: String) throws -> Data? {
    try sqlRead { try $0.rows("SELECT engine FROM cloud_accounts WHERE account=?", [.text(account)]).first?[0].blob }
  }
  public func saveCloudEngineState(_ data: Data, account: String) throws {
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account)
      try currentSQL!.run("UPDATE cloud_accounts SET engine=? WHERE account=?", [.blob(data), .text(account)])
    }
  }

  public func cloudOutbox(account: String, limit: Int = 8) throws -> [NotebookCloudRecord] {
    guard (1...16).contains(limit) else { throw NotebookTransportError.resourceLimit }
    return try sqlRead { db in
      try requireCloudAccount(account)
      return try db.rows("SELECT id,delivery,hash,offset,total FROM cloud_outbox WHERE account=? AND EXISTS(SELECT 1 FROM cloud_exports e WHERE e.account=cloud_outbox.account AND e.ready=1) ORDER BY id LIMIT ?", [.text(account), .integer(Int64(limit))]).map { row in
        if let data = row[1].blob { return try .delivery(JSONDecoder().decode(NotebookReplicationDelivery.self, from: data)) }
        return try .chunk(hash: row[2].text!, offset: row[3].integer!, totalBytes: row[4].integer!)
      }
    }
  }

  public func acknowledgeCloudRecords(_ ids: [String], account: String) throws {
    guard ids.count <= 16 else { throw NotebookTransportError.resourceLimit }
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account); let db = currentSQL!
      // Stale engine callbacks cannot consume descriptors still being imported.
      guard try !db.rows("SELECT 1 FROM cloud_exports WHERE account=? AND ready=1", [.text(account)]).isEmpty else { return }
      for id in ids {
        guard try !db.rows("SELECT 1 FROM cloud_outbox WHERE account=? AND id=?", [.text(account), .text(id)]).isEmpty else { continue }
        try db.run("INSERT OR IGNORE INTO cloud_uploaded VALUES(?,?)", [.text(account), .text(id)])
        try db.run("DELETE FROM cloud_outbox WHERE account=? AND id=?", [.text(account), .text(id)])
      }
      if try db.rows("SELECT 1 FROM cloud_outbox WHERE account=? LIMIT 1", [.text(account)]).isEmpty,
        let data = try db.rows("SELECT delivery FROM cloud_exports WHERE account=? AND ready=1", [.text(account)]).first?[0].blob {
        let delivery = try JSONDecoder().decode(NotebookReplicationDelivery.self, from: data)
        try db.run("UPDATE cloud_accounts SET cursor=? WHERE account=?", [.integer(Int64(delivery.change.sequence)), .text(account)])
        try db.run("DELETE FROM cloud_exports WHERE account=?", [.text(account)])
      }
    }
  }

  public func stageCloudDelivery(_ delivery: NotebookReplicationDelivery, account: String, localSource: NotebookReplicationSource) throws {
    let record = try NotebookCloudRecord.delivery(delivery), change = delivery.change
    guard change.sequence > 0, change.sequence <= UInt64(Int64.max), NotebookTransportFraming.isSHA256(change.manifestHash), (1...67_108_864).contains(change.byteCount) else { throw NotebookTransportError.invalidBlob }
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account)
      // CloudKit can return our own writes. They already belong to this local
      // journal and must not wait forever for an incoming cursor of ourselves.
      guard delivery.source != localSource else { return }
      try currentSQL!.run("INSERT OR IGNORE INTO cloud_inbox VALUES(?,?,?,?,?,?)", [.text(account), .text(record.id), .text(delivery.source.cursorKey), .integer(Int64(change.sequence)), .integer(delivery.isSnapshot ? 1 : 0), .blob(try Self.storageEncoder.encode(delivery))])
    }
  }

  public func stageCloudChunk(_ record: NotebookCloudRecord, data: Data, account: String) throws {
    guard let hash = record.hash, data.count == record.byteCount else { throw NotebookTransportError.invalidBlob }
    _ = try NotebookCloudRecord.chunk(hash: hash, offset: record.offset, totalBytes: record.totalBytes)
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account); let db = currentSQL!
      if let size = try db.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(hash)]).first?[0].integer {
        guard size == record.totalBytes else { throw NotebookTransportError.invalidBlob }; return
      }
      if let size = try db.rows("SELECT total FROM cloud_chunks WHERE account=? AND hash=? LIMIT 1", [.text(account), .text(hash)]).first?[0].integer {
        guard size == record.totalBytes else { throw NotebookTransportError.invalidBlob }
      }
      if let old = try db.rows("SELECT data FROM cloud_chunks WHERE account=? AND hash=? AND offset=?", [.text(account), .text(hash), .integer(record.offset)]).first?[0].blob {
        guard old == data else { throw NotebookTransportError.invalidBlob }; return
      }
      try db.run("INSERT INTO cloud_chunks VALUES(?,?,?,?,?)", [.text(account), .text(hash), .integer(record.offset), .integer(record.totalBytes), .blob(data)])
    }
  }

  public func nextCompleteCloudBlob(account: String) throws -> NotebookCloudRecord? {
    try sqlRead { db in
      guard let row = try db.rows("SELECT hash,MAX(total) FROM cloud_chunks WHERE account=? GROUP BY hash HAVING SUM(length(data))=MAX(total) ORDER BY hash LIMIT 1", [.text(account)]).first else { return nil }
      return try .chunk(hash: row[0].text!, offset: 0, totalBytes: row[1].integer!)
    }
  }

  /// File assembly is a read-only worker operation, outside the persistence
  /// queue and Pencil handler. A partial file cannot publish any content.
  public func assembleCloudBlob(_ record: NotebookCloudRecord, account: String, file: URL) throws {
    guard let hash = record.hash else { throw NotebookTransportError.invalidBlob }
    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NotebookTransportError.storageUnavailable }
    let output = try FileHandle(forWritingTo: file); defer { try? output.close() }
    var offset: Int64 = 0
    repeat {
      try Task.checkCancellation()
      let data = try sqlRead { try $0.rows("SELECT data FROM cloud_chunks WHERE account=? AND hash=? AND offset=?", [.text(account), .text(hash), .integer(offset)]).first?[0].blob }
      guard let data, data.count == min(NotebookCloudRecord.chunkBytes, Int(record.totalBytes - offset)) else { throw NotebookTransportError.invalidBlob }
      try output.write(contentsOf: data); offset += Int64(data.count)
    } while offset < record.totalBytes
    try output.synchronize()
  }

  public func installCloudBlob(_ record: NotebookCloudRecord, account: String, file: URL) throws {
    guard let hash = record.hash else { throw NotebookTransportError.invalidBlob }
    try commandTransaction(advancesReadRevision: false) {
      try requireCloudAccount(account)
      try stageBlob(file: file, expectedHash: hash, byteCount: record.totalBytes)
      try currentSQL!.run("DELETE FROM cloud_chunks WHERE account=? AND hash=?", [.text(account), .text(hash)])
    }
  }

  public func cloudInbox(account: String) throws -> [NotebookReplicationDelivery] {
    try sqlRead { db in
      try requireCloudAccount(account)
      return try db.rows("""
        SELECT i.delivery FROM cloud_inbox i LEFT JOIN peer_cursors p ON p.peer_id=i.source AND p.direction='incoming'
        LEFT JOIN metadata r ON r.key='retired_peer:' || substr(i.source,1,36)
        WHERE i.account=? AND r.key IS NULL AND (i.snapshot=1 OR i.sequence<=COALESCE(p.sequence,0)+1)
        ORDER BY i.snapshot DESC,i.sequence,i.id LIMIT 16
        """, [.text(account)]).map { try JSONDecoder().decode(NotebookReplicationDelivery.self, from: $0[0].blob!) }
    }
  }

  @discardableResult
  public func applyCloudDelivery(_ delivery: NotebookReplicationDelivery, account: String,
    protectingInputOn targets: [CollaborationTarget] = []) throws -> UInt64 {
    try commandTransaction {
      try requireCloudAccount(account)
      let cursor = try applyDelivery(delivery, protectingInputOn: targets)
      try currentSQL!.run("DELETE FROM cloud_inbox WHERE account=? AND id=?", [.text(account), .text(NotebookCloudRecord.delivery(delivery).id)])
      return cursor
    }
  }
}
