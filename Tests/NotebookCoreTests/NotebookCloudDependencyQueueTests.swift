import CSQLite
import Foundation
import Testing
@testable import NotebookCore

struct NotebookCloudDependencyQueueTests {
  @Test func pendingDependencyLookupIsIndexedAfter100000ExpandedNodes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try NotebookSQLConnection(url: url, writable: true, create: true)
    // Exact temporary table/index/query of the cloud dependency admission owner.
    // This measures SQL work, not network delivery or the full CloudKit route.
    try NotebookStore.createCloudOrderQueue(database)
    try database.run("WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<99999) INSERT INTO cloud_order_nodes(hash,expanded) SELECT printf('%064d',i),1 FROM n")
    let select = "SELECT hash FROM cloud_order_nodes WHERE expanded=0 ORDER BY hash LIMIT 1"
    let plan = try database.rows("EXPLAIN QUERY PLAN " + select).compactMap { $0.last?.text }.joined(separator: "\n")
    #expect(plan.contains("cloud_order_pending"))
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database.handle, select, -1, &statement, nil) == SQLITE_OK)
    let query = try #require(statement); defer { sqlite3_finalize(query) }
    var steps = 0
    for index in 100_000..<101_000 {
      let hash = String(format: "%064d", index)
      try database.run("INSERT OR IGNORE INTO cloud_order_nodes(hash) VALUES(?)", [.text(hash)])
      try database.run("INSERT OR IGNORE INTO cloud_order_nodes(hash) VALUES(?)", [.text(hash)])
      #expect(sqlite3_step(query) == SQLITE_ROW)
      #expect(String(cString: sqlite3_column_text(query, 0)) == hash)
      #expect(sqlite3_step(query) == SQLITE_DONE)
      steps += Int(sqlite3_stmt_status(query, SQLITE_STMTSTATUS_VM_STEP, 1))
      sqlite3_reset(query)
      try database.run("UPDATE cloud_order_nodes SET expanded=1 WHERE hash=?", [.text(hash)])
    }
    #expect(sqlite3_step(query) == SQLITE_DONE)
    #expect(steps < 25_000, "No repeated scan through expanded dependencies")
    #expect(try database.rows("SELECT COUNT(*) FROM cloud_order_nodes")[0][0].integer == 101_000)
    print("CLOUD_DEPENDENCY_LOOKUP expanded=100000 admitted=1000 lookup_vm_steps=\(steps)")
  }
}
