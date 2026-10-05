import CSQLite
import Foundation
import NotebookTypesetter

/// Corrupt/pressure fixtures use the cache's current schema, never live content.
enum DocumentPrintCacheFixture {
  static func connection<T>(_ directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    guard (try FileManager.default.attributesOfItem(atPath: directory.path))[.type] as? FileAttributeType == .typeDirectory,
      let canonical = directory.withUnsafeFileSystemRepresentation({ realpath($0, nil) }) else {
      throw NotebookTypesetterError("Cannot resolve fixture cache directory")
    }
    defer { free(canonical) }
    var database: OpaquePointer?
    let result = sqlite3_open_v2(String(cString: canonical) + "/artifacts.sqlite3",
      &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil)
    guard result == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw NotebookTypesetterError("Cannot open fixture cache")
    }
    defer { sqlite3_close(database) }
    return try body(database)
  }
  static func execute(_ directory: URL, _ sql: String) throws {
    try connection(directory) { database in
      guard sqlite3_exec(database, "PRAGMA foreign_keys=ON;" + sql, nil, nil, nil) == SQLITE_OK else {
        throw NotebookTypesetterError(String(cString: sqlite3_errmsg(database)))
      }
    }
  }
  static func bytes(_ directory: URL, _ sql: String) throws -> Data? {
    try connection(directory) { database in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NotebookTypesetterError(String(cString: sqlite3_errmsg(database)))
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      let count = Int(sqlite3_column_bytes(statement, 0))
      guard count <= 16*1024*1024 else { throw NotebookTypesetterError("Fixture result too large") }
      return sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: count) } ?? Data()
    }
  }
}
