import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("One SQL progress owner bounds nested work and observer cancellation")
struct NotebookSQLExecutionTests {
  private final class CancellationGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
  }
  private enum LostCommitReply: Error { case lost }
  enum Work: String, Sendable {
    case scan, count, sort
    var sql: String {
      let input = "WITH RECURSIVE input(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM input WHERE x<1000000) "
      switch self {
      case .scan: return input + "SELECT cancellation_probe(x) FROM input"
      case .count: return input + "SELECT COUNT(cancellation_probe(x)) FROM input"
      case .sort: return input + "SELECT cancellation_probe(x) FROM input ORDER BY x DESC"
      }
    }
  }
  private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func advance() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  }

  @Test(arguments: [false, true], [Work.scan, .count, .sort])
  func cancellationInterruptsAnAggregateBeforeItsFirstRowAndCannotWithdrawAnAcceptedWrite(ownerStop: Bool, work: Work) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let gate = CancellationGate(), cancellation = NotebookReadCancellation()
    let task = Task.detached { () throws -> (Int, Int) in
      let session = NotebookReadSession(store: store, cancellation: cancellation)
      var database: NotebookSQLConnection?, deliveredRows = 0
      do {
        try session.observe { _ in
          let sql = try #require(store.currentSQL); database = sql
          let status = sqlite3_create_function_v2(sql.handle, "cancellation_probe", 1, SQLITE_UTF8,
            Unmanaged.passUnretained(gate).toOpaque(), { context, _, values in
              guard let context, let values, let pointer = sqlite3_user_data(context) else { return }
              let value = sqlite3_value_int64(values[0])
              if value == 1_024 {
                let gate = Unmanaged<CancellationGate>.fromOpaque(pointer).takeUnretainedValue()
                gate.entered.signal()
                _ = gate.release.wait(timeout: .now() + 5)
              }
              sqlite3_result_int64(context, value)
            }, nil, nil, nil)
          #expect(status == SQLITE_OK)
          try sql.forEachRow(work.sql) { _ in deliveredRows += 1 }
        }
        Issue.record("An observer cancelled during SQL execution must not finish its aggregate")
      } catch is CancellationError { }
      let sql = try #require(database)
      var statement = sqlite3_next_stmt(sql.handle, nil), actualSteps = 0
      while let cached = statement {
        if let text = sqlite3_sql(cached), String(cString: text).contains("SELECT") && String(cString: text).contains("cancellation_probe") {
          actualSteps += Int(sqlite3_stmt_status(cached, SQLITE_STMTSTATUS_VM_STEP, 0))
        }
        statement = sqlite3_next_stmt(sql.handle, cached)
      }
      #expect(try sql.rows("SELECT 42").first?[0].integer == 42,
        "The retired observer's progress handler cannot interrupt the next idle-handle use")
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: root)) { acceptedStore in
        try acceptedStore.publishRecords(writes: ["accepted-after-cancel.json": .object(["value": .string("kept")])])
        return "original output"
      }
      let lost = NotebookStore(root: root) { if case .afterCommit = $0 { throw LostCommitReply.lost } }
      do { _ = try accepted.apply(to: lost); Issue.record("The fixture must lose its COMMIT reply") }
      catch let error as NotebookAcceptedWriteError { #expect(error.outcome == .unresolved) }
      #expect(try accepted.apply(to: store) == "original output")
      #expect(try accepted.apply(to: store) == "original output")
      return (deliveredRows, actualSteps)
    }
    let entered = await Task.detached { gate.waitForEntry() }.value
    #expect(entered, "Cancellation is triggered inside the actual SQL aggregate, before any result")
    let start = ContinuousClock.now
    if ownerStop { cancellation.cancel() } else { task.cancel() }
    gate.release.signal()
    let (rows, steps) = try await task.value
    #expect(rows == (work == .scan ? 1_024 : 0) && steps > 1_024 && steps < 100_000)
    #expect(try NotebookStore(root: root).hasStoredValue("accepted-after-cancel.json"))
    print("SQL \(work.rawValue) \(ownerStop ? "owner Stop" : "caller cancellation") joined after \(start.duration(to: .now)); rows=\(rows), actual VM steps=\(steps); accepted COMMIT recovery preserved")
  }

  @Test func nestedHelpersCannotRenewTheOuterAllowanceAndTheNextSnapshotStartsFresh() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let reader = NotebookReadSession(store: store), outer = NotebookSQLExecutionBudget(steps: 10_000, reason: "outer_domain")
    #expect(throws: NotebookStorageError.limitExceeded("read_sql_work")) {
      try reader.read { snapshot in
        let sql = try #require(snapshot.currentSQL)
        try sql.limitReads(.init(rows: 1_000, bytes: 8_000, valueBytes: 8, reason: "small_batch", sqlSteps: 128))
        try sql.withSQLExecution(outer) {
          for _ in 0..<200 {
            let inner = NotebookSQLExecutionBudget(steps: 10_000, reason: "fresh_inner")
            try sql.withSQLExecution(inner) { _ = try sql.rows("SELECT 1") }
          }
        }
      }
    }
    #expect(outer.steps > 0 && outer.steps <= 128)
    #expect(try reader.read { try $0.workspaceHeader() } == store.workspaceHeader())
  }

  @Test func aCaughtSQLRefusalStillRollsBackAllEarlierWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let read = try store.currentReadCursor(), delivery = try store.currentChangeCursor()
    #expect(throws: NotebookStorageError.limitExceeded("finite_command")) {
      try store.commandTransaction(readAllowance: .init(rows: 10_000, bytes: 1_048_576,
        valueBytes: 524_288, reason: "finite_command", sqlSteps: 50_000)) {
        try store.publishRecords(writes: ["partial-before-refusal.json": .object(["value": .number(1)])])
        do {
          _ = try store.currentSQL!.rows("""
            WITH RECURSIVE input(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM input WHERE x<1000000)
            SELECT COUNT(*) FROM input
            """)
        } catch let error as NotebookStorageError { #expect(error == .limitExceeded("finite_command")) }
      }
    }
    let reopened = NotebookStore(root: root)
    #expect(try !reopened.hasStoredValue("partial-before-refusal.json"))
    #expect(try reopened.currentReadCursor() == read && reopened.currentChangeCursor() == delivery)
  }

  @Test func anInterruptedWriteAttestsRollbackAndCannotLeakACaughtRefusalIntoAutocommit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let attempts = Attempts(), read = try store.currentReadCursor(), delivery = try store.currentChangeCursor()
    let accepted = NotebookAcceptedWrite<Void>(witnesses: .init(root: root)) { snapshot in
      attempts.advance()
      try snapshot.publishRecords(writes: ["before-interrupted-write.json": .object(["value": .number(1)])])
      let sql = try #require(snapshot.currentSQL)
      do {
        try sql.withSQLExecution(.init(steps: 1_024, reason: "finite_inner_write")) {
          try sql.run("""
            WITH RECURSIVE input(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM input WHERE x<1000000)
            INSERT INTO metadata(key,value) SELECT 'budget-probe:'||x,CAST(x AS TEXT) FROM input
            """)
        }
      } catch let error as NotebookStorageError { #expect(error == .limitExceeded("finite_inner_write")) }
      #expect(sql.sqlExecutionInterrupted)
      #expect(sqlite3_get_autocommit(sql.handle) != 0, "The actual interrupted INSERT rolled back this explicit transaction")
      do { try sql.run("INSERT INTO metadata(key,value) VALUES('escaped-budget','must not persist')") }
      catch let error as NotebookStorageError { #expect(error == .limitExceeded("finite_inner_write")) }
    }
    for _ in 0..<2 {
      do { try accepted.apply(to: store); Issue.record("Finite work has one definitive refusal") }
      catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .rejected)
        #expect(error.underlying as? NotebookStorageError == .limitExceeded("finite_inner_write"))
      }
    }
    #expect(attempts.value == 1, "Retry returns the attested refusal without reexecuting the original body")
    let reopened = NotebookStore(root: root)
    #expect(try !reopened.hasStoredValue("before-interrupted-write.json"))
    #expect(try reopened.sqlRead { try $0.rows("SELECT value FROM metadata WHERE key='escaped-budget' OR key LIKE 'budget-probe:%'").isEmpty })
    #expect(try reopened.currentReadCursor() == read && reopened.currentChangeCursor() == delivery)
  }
}
