import CSQLite
import Foundation

/// Raw evidence for one action, not a durable inverse or an alternate writer.
struct NotebookActionRecordChange: Codable, Equatable {
  let address: String
  let beforeHash: String?
  let afterHash: String?
}

struct NotebookActionRecordCaptureState {
  let actionID: UUID
  let key: String
  var count = 0
  var failure: Error?
}

extension NotebookSQLConnection {
  /// Only the content segment is captured. Its caller publishes the receipt
  /// and frozen result after this scope has closed, on the same transaction.
  func withActionRecordCapture<T>(actionID: UUID, _ body: () throws -> T) throws -> T {
    guard writable, sqlite3_get_autocommit(handle) == 0 else { throw NotebookStorageError.readOnlyTransaction }
    guard activeActionRecordCapture == nil else { throw NotebookStorageError.invalidTransaction("nested action record capture") }
    if !actionRecordCapturesPrepared {
      try run("CREATE TEMP TABLE notebook_action_record_captures(action_id TEXT PRIMARY KEY,record_count INTEGER NOT NULL) WITHOUT ROWID")
      try run("CREATE TEMP TABLE notebook_action_record_changes(action_id TEXT NOT NULL,address TEXT NOT NULL,before_hash TEXT,after_hash TEXT,PRIMARY KEY(action_id,address)) WITHOUT ROWID")
      try run("PRAGMA temp.cache_size=-2048")
      actionRecordCapturesPrepared = true
    }
    let key = actionID.uuidString.lowercased()
    try run("INSERT OR IGNORE INTO notebook_action_record_captures(action_id,record_count) VALUES(?,0)", [.text(key)])
    guard sqlite3_changes64(handle) == 1 else { throw NotebookStorageError.invalidTransaction("reused action record capture") }
    activeActionRecordCapture = .init(actionID: actionID, key: key)
    defer { activeActionRecordCapture = nil }
    let result = Result { try body() }
    let capture = activeActionRecordCapture!
    try run("UPDATE notebook_action_record_captures SET record_count=? WHERE action_id=?", [.integer(Int64(capture.count)), .text(key)])
    // A caught writer refusal cannot make an incomplete capture successful.
    if let failure = capture.failure { throw failure }
    return try result.get()
  }

  /// Hooks supply hashes they already read; capture never decodes an old body.
  func recordActionRecordChange(address: String, beforeHash: String?, afterHash: String?) throws {
    guard var capture = activeActionRecordCapture else { return }
    if let failure = capture.failure { throw failure }
    guard beforeHash != afterHash else { return }
    defer { activeActionRecordCapture = capture }
    do {
      let identity: [NotebookSQLValue] = [.text(capture.key), .text(address)]
      try run("INSERT OR IGNORE INTO notebook_action_record_changes(action_id,address,before_hash,after_hash) VALUES(?,?,?,?)",
        identity + [beforeHash.map(NotebookSQLValue.text) ?? .null, afterHash.map(NotebookSQLValue.text) ?? .null])
      if sqlite3_changes64(handle) == 1 {
        capture.count += 1
        guard capture.count <= 8_388_608 else { throw NotebookStorageError.limitExceeded("action_record_capture") }
      } else {
        try run("UPDATE notebook_action_record_changes SET after_hash=? WHERE action_id=? AND address=?",
          [afterHash.map(NotebookSQLValue.text) ?? .null] + identity)
        // Returning to the original value is a net no-op, including a transient
        // birth followed by deletion. A later mutation starts at that same value.
        try run("DELETE FROM notebook_action_record_changes WHERE action_id=? AND address=? AND before_hash IS after_hash", identity)
        if sqlite3_changes64(handle) == 1 { capture.count -= 1 }
      }
    } catch {
      capture.failure = error
      throw error
    }
  }

  func actionRecordCaptureCount(actionID: UUID) throws -> Int {
    if let capture = activeActionRecordCapture, capture.actionID == actionID { return capture.count }
    guard actionRecordCapturesPrepared else { return 0 }
    return Int(try rows("SELECT record_count FROM notebook_action_record_captures WHERE action_id=?",
      [.text(actionID.uuidString.lowercased())]).first?[0].integer ?? 0)
  }

  func actionRecordCapturePage(actionID: UUID, after address: String = "", limit: Int = 64) throws -> [NotebookActionRecordChange] {
    guard (1...16_384).contains(limit) else { throw NotebookStorageError.limitExceeded("action_record_capture_page") }
    guard actionRecordCapturesPrepared else { return [] }
    return try rows("SELECT address,before_hash,after_hash FROM notebook_action_record_changes WHERE action_id=? AND address>? ORDER BY address LIMIT ?",
      [.text(actionID.uuidString.lowercased()), .text(address), .integer(Int64(limit))]).map {
        .init(address: $0[0].text!, beforeHash: $0[1].text, afterHash: $0[2].text)
      }
  }
}
