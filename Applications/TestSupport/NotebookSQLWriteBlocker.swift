import Foundation
import NotebookCore
import SQLite3

/// Isolated tests hold a real SQLite writer transaction while the app accepts
/// input. No production lock file or alternate writer path is installed.
final class NotebookSQLWriteBlocker {
  private var database: OpaquePointer?

  init(store: NotebookStore) throws {
    guard sqlite3_open_v2(store.databaseURL.path, &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let database else { throw failure("open") }
    guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
      sqlite3_close(database)
      self.database = nil
      throw failure("begin")
    }
  }

  func release() throws {
    guard let database else { return }
    guard sqlite3_exec(database, "ROLLBACK", nil, nil, nil) == SQLITE_OK else { throw failure("release") }
    sqlite3_close(database)
    self.database = nil
  }

  deinit {
    if let database { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); sqlite3_close(database) }
  }

  private func failure(_ operation: String) -> NSError {
    NSError(domain: "NotebookSQLWriteBlocker", code: Int(sqlite3_errcode(database)),
      userInfo: [NSLocalizedDescriptionKey: "SQL test blocker could not \(operation)"])
  }
}
