import CSQLite
import Foundation

/// One synchronous owner inside NotebookPrintedDocumentStore. The database owns
/// both payloads and eviction; no filesystem catalogue must be reconciled.
final class NotebookPrintedArtifactCache {
  struct Record {
    let identity: String
    let metadata: Data
    let pdf: Data
    let syncTeX: Data
    let interactiveMap: Data
  }
  private static let budget = 128 * 1024 * 1024
  private static let limits = [8, 16, 4, 4].map { $0 * 1024 * 1024 }
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private var database: OpaquePointer?
  private enum Failure: Error { case invalidCache, unsafeLocation, sqlite(Int32) }

  init(directory: URL) throws {
    try Task.checkCancellation()
    let fm = FileManager.default
    if let node = try Self.attributes(directory.path) {
      guard node[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafeLocation }
      if try Self.attributes(directory.appendingPathComponent("artifacts.sqlite3").path) == nil {
        try Self.retire(directory)
      }
    }
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for attempt in 0...1 {
      let path = try Self.databasePath(in: directory)
      do {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(path, &opened,
          SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        database = opened
        try check(status)
        try configure()
        return
      } catch {
        if let database { sqlite3_close(database) }
        database = nil
        try Task.checkCancellation()
        let repairable: Bool
        switch error {
        case Failure.invalidCache: repairable = true
        case Failure.sqlite(let code): repairable = [SQLITE_CORRUPT, SQLITE_NOTADB].contains(code & 255)
        default: repairable = false
        }
        guard attempt == 0, repairable else { throw error }
        // Revalidate ownership before replacing only a structurally broken cache.
        _ = try Self.databasePath(in: directory)
        try Self.retire(directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
      }
    }
  }

  deinit { if let database { sqlite3_close(database) } }

  private static func attributes(_ path: String) throws -> [FileAttributeKey: Any]? {
    do { return try FileManager.default.attributesOfItem(atPath: path) }
    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
  }
  private static func databasePath(in directory: URL) throws -> String {
    guard try attributes(directory.path)?[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unsafeLocation }
    // Foundation intentionally keeps /var aliases on macOS; SQLite NOFOLLOW
    // requires the actual path of these already-admitted ancestor directories.
    guard let canonical = directory.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else { throw Failure.unsafeLocation }
    defer { free(canonical) }
    let path = String(cString: canonical) + "/artifacts.sqlite3"
    for suffix in ["", "-journal", "-wal", "-shm"] {
      if let node = try attributes(path + suffix) {
        guard node[.type] as? FileAttributeType == .typeRegular,
          (node[.referenceCount] as? NSNumber)?.intValue == 1 else { throw Failure.unsafeLocation }
      }
    }
    return path
  }
  private static func retire(_ directory: URL) throws {
    let retired = directory.deletingLastPathComponent().appendingPathComponent(
      directory.lastPathComponent + ".retired-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.moveItem(at: directory, to: retired)
    // One bounded cleanup job captures only the retired path, never documents.
    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: retired) }
  }

  private func configure() throws {
    sqlite3_busy_timeout(database, 25)
    sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(Self.limits.reduce(0, +) + 1024))
    try execute("PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA mmap_size=0; PRAGMA cache_size=-2048; PRAGMA temp_store=MEMORY;")
    try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL; PRAGMA max_page_count=65536;")
    let version = try integer("PRAGMA user_version")
    if version == 0 {
      guard try integer("SELECT count(*) FROM sqlite_schema") == 0 else { throw Failure.invalidCache }
      try execute("PRAGMA page_size=4096")
      try transaction {
        try execute("""
          CREATE TABLE cache_state(id INTEGER PRIMARY KEY CHECK(id=1),
            total_bytes INTEGER NOT NULL CHECK(total_bytes BETWEEN 0 AND 134217728),
            clock INTEGER NOT NULL CHECK(clock>=0)) STRICT;
          INSERT INTO cache_state VALUES(1,0,0);
          CREATE TABLE artifacts(identity TEXT PRIMARY KEY NOT NULL, bucket TEXT NOT NULL,
            accessed INTEGER NOT NULL CHECK(accessed>=0)) STRICT;
          CREATE TABLE payloads(identity TEXT PRIMARY KEY NOT NULL REFERENCES artifacts(identity) ON DELETE CASCADE,
            metadata BLOB NOT NULL, pdf BLOB NOT NULL, synctex BLOB NOT NULL, interactive_map BLOB NOT NULL,
            byte_count INTEGER GENERATED ALWAYS AS
              (length(metadata)+length(pdf)+length(synctex)+length(interactive_map)) STORED) STRICT;
          CREATE INDEX artifacts_bucket_access ON artifacts(bucket,accessed DESC);
          CREATE INDEX artifacts_access ON artifacts(accessed);
          CREATE TRIGGER payloads_insert AFTER INSERT ON payloads BEGIN
            UPDATE cache_state SET total_bytes=total_bytes+NEW.byte_count WHERE id=1;
          END;
          CREATE TRIGGER payloads_delete AFTER DELETE ON payloads BEGIN
            UPDATE cache_state SET total_bytes=total_bytes-OLD.byte_count WHERE id=1;
          END;
          CREATE TRIGGER payloads_update AFTER UPDATE ON payloads BEGIN
            UPDATE cache_state SET total_bytes=total_bytes+NEW.byte_count-OLD.byte_count WHERE id=1;
          END;
          CREATE TRIGGER artifacts_insert AFTER INSERT ON artifacts BEGIN
            UPDATE cache_state SET clock=max(clock,NEW.accessed) WHERE id=1;
          END;
          CREATE TRIGGER artifacts_accessed AFTER UPDATE OF accessed ON artifacts BEGIN
            UPDATE cache_state SET clock=max(clock,NEW.accessed) WHERE id=1;
          END;
          PRAGMA user_version=1;
          """)
      }
    } else if version != 1 { throw Failure.invalidCache }
    guard try integer("""
      SELECT count(*) FROM sqlite_schema WHERE (type,name) IN (
        ('table','cache_state'),('table','artifacts'),('table','payloads'),
        ('index','artifacts_bucket_access'),('index','artifacts_access'),
        ('trigger','payloads_insert'),('trigger','payloads_delete'),('trigger','payloads_update'),
        ('trigger','artifacts_insert'),('trigger','artifacts_accessed'))
      """) == 10 else { throw Failure.invalidCache }
    do {
      // Preparing fixed projections verifies the current columns without reading
      // or scanning payload rows. A missing column is a broken cache schema.
      for sql in ["SELECT id,total_bytes,clock FROM cache_state LIMIT 0",
        "SELECT identity,bucket,accessed FROM artifacts LIMIT 0",
        "SELECT identity,metadata,pdf,synctex,interactive_map,byte_count FROM payloads LIMIT 0"] {
        let statement = try prepare(sql); sqlite3_finalize(statement)
      }
    } catch Failure.sqlite(SQLITE_ERROR) { throw Failure.invalidCache }
    guard try integer("PRAGMA page_size") == 4096, try integer("PRAGMA page_count") <= 65536,
      (0..<Int64.max).contains(try integer("SELECT clock FROM cache_state WHERE id=1")),
      (0...Int64(Self.budget)).contains(try integer("SELECT total_bytes FROM cache_state WHERE id=1")) else {
      throw Failure.invalidCache
    }
  }

  func find(in bucket: String, matching: (String, Data) throws -> Bool) throws -> Record? {
    try Self.validateKey(bucket)
    return try transaction {
      while let candidate = try candidate(in: bucket, matching: matching) {
        let record: Record
        do { record = try load(candidate.0, metadata: candidate.1) }
        catch Failure.invalidCache {
          // load has finalized its SELECT before changing the indexed rows.
          try Task.checkCancellation()
          try delete(candidate.0)
          continue
        }
        let touch = try prepare("UPDATE artifacts SET accessed=? WHERE identity=?")
        defer { sqlite3_finalize(touch) }
        try check(sqlite3_bind_int64(touch, 1, nextAccess()))
        try bind(record.identity, to: touch, at: 2); try done(touch)
        return record
      }
      return nil
    }
  }

  func save(_ record: Record, in bucket: String) throws {
    try Self.validateKey(record.identity); try Self.validateKey(bucket)
    let payloads = [record.metadata, record.pdf, record.syncTeX, record.interactiveMap]
    guard zip(payloads, Self.limits).allSatisfy({ $0.0.count <= $0.1 }) else { throw Failure.invalidCache }
    let bytes = Int64(payloads.reduce(0) { $0 + $1.count })
    try transaction {
      try delete(record.identity)
      var total = try integer("SELECT total_bytes FROM cache_state WHERE id=1")
      while total + bytes > Self.budget {
        try Task.checkCancellation()
        let oldest = try prepare("SELECT a.identity,p.byte_count FROM artifacts AS a INDEXED BY artifacts_access JOIN payloads AS p ON p.identity=a.identity ORDER BY a.accessed LIMIT 1")
        let identity: String, size: Int64
        do {
          defer { sqlite3_finalize(oldest) }
          guard try step(oldest) == SQLITE_ROW else { throw Failure.invalidCache }
          identity = try text(oldest, column: 0); size = sqlite3_column_int64(oldest, 1)
          guard size >= 0, size <= total else { throw Failure.invalidCache }
        }
        try delete(identity); total -= size
      }
      let descriptor = try prepare("INSERT INTO artifacts(identity,bucket,accessed) VALUES(?,?,?)")
      do {
        defer { sqlite3_finalize(descriptor) }
        try bind(record.identity, to: descriptor, at: 1); try bind(bucket, to: descriptor, at: 2)
        try check(sqlite3_bind_int64(descriptor, 3, nextAccess())); try done(descriptor)
      }
      let statement = try prepare("INSERT INTO payloads(identity,metadata,pdf,synctex,interactive_map) VALUES(?,?,?,?,?)")
      defer { sqlite3_finalize(statement) }
      try bind(record.identity, to: statement, at: 1)
      for (index, data) in payloads.enumerated() {
        let status = data.withUnsafeBytes { bytes in
          data.isEmpty ? sqlite3_bind_zeroblob(statement, Int32(index + 2), 0)
            : sqlite3_bind_blob64(statement, Int32(index + 2), bytes.baseAddress, UInt64(bytes.count), Self.transient)
        }
        try check(status)
      }
      try done(statement)
    }
  }

  func remove(_ identity: String) throws {
    try Self.validateKey(identity)
    try transaction { try delete(identity) }
  }

  private func candidate(in bucket: String, matching: (String, Data) throws -> Bool) throws -> (String, Data)? {
    let statement = try prepare("SELECT a.identity,p.metadata FROM artifacts AS a INDEXED BY artifacts_bucket_access JOIN payloads AS p ON p.identity=a.identity WHERE a.bucket=? ORDER BY a.accessed DESC")
    defer { sqlite3_finalize(statement) }
    try bind(bucket, to: statement, at: 1)
    while try step(statement) == SQLITE_ROW {
      try Task.checkCancellation()
      let identity: String, metadata: Data
      do { identity = try text(statement, column: 0); metadata = try blob(statement, column: 1, limit: Self.limits[0]) }
      catch Failure.invalidCache { continue }
      if try matching(identity, metadata) { return (identity, metadata) }
    }
    return nil
  }
  private func load(_ identity: String, metadata: Data) throws -> Record {
    let statement = try prepare("SELECT pdf,synctex,interactive_map FROM payloads WHERE identity=?")
    defer { sqlite3_finalize(statement) }
    try bind(identity, to: statement, at: 1)
    guard try step(statement) == SQLITE_ROW else { throw Failure.invalidCache }
    return Record(identity: identity, metadata: metadata,
      pdf: try blob(statement, column: 0, limit: Self.limits[1]),
      syncTeX: try blob(statement, column: 1, limit: Self.limits[2]),
      interactiveMap: try blob(statement, column: 2, limit: Self.limits[3]))
  }
  private func delete(_ identity: String) throws {
    let statement = try prepare("DELETE FROM artifacts WHERE identity=?")
    defer { sqlite3_finalize(statement) }
    try bind(identity, to: statement, at: 1); try done(statement)
  }
  private func nextAccess() throws -> Int64 {
    let clock = try integer("SELECT clock FROM cache_state WHERE id=1")
    guard clock >= 0, clock < Int64.max else { throw Failure.invalidCache }
    return clock + 1
  }
  private static func validateKey(_ value: String) throws {
    guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw Failure.invalidCache
    }
  }
  private func blob(_ statement: OpaquePointer, column: Int32, limit: Int) throws -> Data {
    guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { throw Failure.invalidCache }
    let count = Int(sqlite3_column_bytes(statement, column))
    try checkColumnFailure()
    guard count <= limit else { throw Failure.invalidCache }
    guard count > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, column) else {
      try checkColumnFailure()
      throw Failure.invalidCache
    }
    return Data(bytes: bytes, count: count)
  }
  private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { throw Failure.invalidCache }
    let count = Int(sqlite3_column_bytes(statement, column))
    try checkColumnFailure()
    guard (1...128).contains(count) else { throw Failure.invalidCache }
    guard let bytes = sqlite3_column_text(statement, column) else {
      try checkColumnFailure()
      throw Failure.invalidCache
    }
    let value = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    try Self.validateKey(value); return value
  }
  private func checkColumnFailure() throws {
    let status = sqlite3_errcode(database)
    guard status == SQLITE_OK || status == SQLITE_ROW || status == SQLITE_DONE else { throw Failure.sqlite(status) }
  }
  private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
    try check(sqlite3_bind_text(statement, index, value, -1, Self.transient))
  }
  private func check(_ status: Int32) throws {
    guard status == SQLITE_OK else { throw Failure.sqlite(status) }
  }
  private func step(_ statement: OpaquePointer) throws -> Int32 {
    let status = sqlite3_step(statement)
    guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Failure.sqlite(status) }
    return status
  }
  private func done(_ statement: OpaquePointer) throws {
    guard try step(statement) == SQLITE_DONE else { throw Failure.invalidCache }
  }
  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
    guard let statement else { throw Failure.invalidCache }
    return statement
  }
  private func execute(_ sql: String) throws { try check(sqlite3_exec(database, sql, nil, nil, nil)) }
  private func integer(_ sql: String) throws -> Int64 {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    guard try step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw Failure.invalidCache }
    return sqlite3_column_int64(statement, 0)
  }
  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
}
