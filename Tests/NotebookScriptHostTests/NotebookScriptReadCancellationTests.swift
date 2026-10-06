import CSQLite
import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@MainActor
@Suite("One script run owns its observational host tasks")
struct NotebookScriptReadCancellationTests {
  enum Boundary: String, Sendable, Equatable { case explicitCancel, caller, workerTerminal, shutdown }

  private final class SQLGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
  }

  private actor Reader {
    private let store: NotebookStore
    private let session: NotebookReadSession
    private let gate: SQLGate
    private var armed = false
    private(set) var heldSnapshot: UUID?
    private(set) var latestSnapshot: UUID?
    private(set) var deliveredRows = 0
    private(set) var actualSteps = 0
    private(set) var wasCancelled = false

    init(store: NotebookStore, gate: SQLGate) {
      self.store = store; session = NotebookReadSession(store: store); self.gate = gate
    }
    func arm() { armed = true }

    func observe(_ operation: @Sendable (NotebookQueryCut) throws -> JSONValue) throws -> JSONValue {
      do {
        return try session.observe { cut in
          let sql = try #require(store.currentSQL)
          latestSnapshot = sql.readSnapshotIdentity
          if armed {
            armed = false; heldSnapshot = latestSnapshot
            defer {
              var statement = sqlite3_next_stmt(sql.handle, nil)
              while let cached = statement {
                if let text = sqlite3_sql(cached), String(cString: text).contains("SELECT SUM(script_read_probe") {
                  actualSteps += Int(sqlite3_stmt_status(cached, SQLITE_STMTSTATUS_VM_STEP, 0))
                }
                statement = sqlite3_next_stmt(sql.handle, cached)
              }
            }
            let status = sqlite3_create_function_v2(sql.handle, "script_read_probe", 1, SQLITE_UTF8,
              Unmanaged.passUnretained(gate).toOpaque(), { context, _, values in
                guard let context, let values, let pointer = sqlite3_user_data(context) else { return }
                let value = sqlite3_value_int64(values[0])
                if value == 1_024 {
                  let gate = Unmanaged<SQLGate>.fromOpaque(pointer).takeUnretainedValue()
                  gate.entered.signal(); _ = gate.release.wait(timeout: .now() + 5)
                }
                sqlite3_result_int64(context, value)
              }, nil, nil, nil)
            #expect(status == SQLITE_OK)
            try sql.forEachRow("""
              WITH RECURSIVE input(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM input WHERE x<1000000)
              SELECT SUM(script_read_probe(x)) FROM input
              """) { _ in deliveredRows += 1 }
          }
          return try operation(cut)
        }
      } catch {
        wasCancelled = error is CancellationError
        throw error
      }
    }
  }

  @Test(arguments: [Boundary.explicitCancel, .caller, .workerTerminal, .shutdown])
  func runCancellationInterruptsActualSQLBeforeItsFirstRowAndKeepsAcceptedContent(boundary: Boundary) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("script-read-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let frame = PageRect(x: 0, y: 0, width: 100, height: 100)
    var page = try store.loadPage(pageID)
    page.replaceElements([.init(id: "addressed", kind: .markdown, frame: frame,
      source: "before writer", html: "<p>before writer</p>")], actor: actor)
    try store.savePage(page)
    let gate = SQLGate(), reader = Reader(store: store, gate: gate)
    defer { gate.release.signal() }
    func coordinator() -> NotebookScriptCoordinator {
      .init(command: { _ in throw CollaborationError("unexpected_effect", "This probe only observes") },
        reader: { try await reader.observe($0) },
        persistence: { operation in try await MainActor.run { try operation(store) } }, workingDirectory: root)
    }
    let host = coordinator()
    try await host.start()
    let run = UUID()
    _ = try store.admitScriptRun(.init(op: .start, runID: run, code: "host read lifetime"))
    _ = try store.setScriptRunState(run, state: .running)
    // Exercise the real broker/Coordinator host boundary without launching XPC.
    host.active = run
    let args = JSONValue.object(["target": try .encode(CollaborationTarget(kind: .page, id: pageID)),
      "elementID": .string("addressed")])
    let bytes = try JSONEncoder().encode(args)
    await reader.arm()
    let call = Task { await host.host(.init(runID: run, sequence: 1, method: "observe", arguments: bytes)) }
    let entered = await Task.detached { gate.waitUntilEntered() }.value
    #expect(entered, "Cancel is triggered inside actual SQL, before it can emit an aggregate row")
    guard entered else {
      call.cancel(); gate.release.signal(); _ = await call.value; await host.shutdown(); return
    }
    #expect(host.hostReadTasks[run]?.count == 1 && host.acceptedCalls == 1)

    let accepted = NotebookAcceptedWrite(witnesses: .init(root: root)) { acceptedStore in
      var page = try acceptedStore.loadPage(pageID)
      page.replaceElements([.init(id: "addressed", kind: .markdown, frame: frame,
        source: "accepted writer", html: "<p>accepted writer</p>")], actor: actor)
      try acceptedStore.savePage(page)
      return "original writer receipt"
    }
    let receipt = try accepted.apply(to: store)
    let readCursor = try store.currentReadCursor(), deliveryCursor = try store.currentChangeCursor()
    var ending: Task<Void, Error>?
    switch boundary {
    case .explicitCancel:
      ending = Task { _ = try await host.handle(.init(op: .cancel, runID: run, waitMilliseconds: 0)) }
    case .caller: call.cancel()
    case .workerTerminal: ending = Task<Void, Error> { await host.finishWorkerReads(run) }
    case .shutdown: ending = Task<Void, Error> { await host.shutdown() }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while host.hostReadTasks[run]?.values.contains(where: { !$0.isCancelled }) == true,
      ContinuousClock.now < deadline { await Task.yield() }
    #expect(host.hostReadTasks[run]?.count == 1,
      "Cancellation retains the task while its SQL callback is still held")
    #expect(host.hostReadTasks[run]?.values.allSatisfy(\.isCancelled) == true)
    gate.release.signal()
    let reply = await call.value
    try await ending?.value
    #expect(reply.code != nil && host.hostReadTasks.isEmpty && host.acceptedCalls == 1)
    let wasCancelled = await reader.wasCancelled, deliveredRows = await reader.deliveredRows
    #expect(wasCancelled && deliveredRows == 0)
    let steps = await reader.actualSteps
    #expect(steps > 1_024 && steps < 100_000, "Cancellation reaches SQL before finishing the million-row aggregate")
    #expect(try accepted.apply(to: store) == receipt)
    #expect(try store.currentReadCursor() == readCursor)
    #expect(try store.currentChangeCursor() == deliveryCursor)

    let next = boundary == .shutdown ? coordinator() : host
    if boundary == .shutdown { try await next.start() }
    let nextRun = UUID()
    _ = try store.admitScriptRun(.init(op: .start, runID: nextRun, code: "next fresh read"))
    _ = try store.setScriptRunState(nextRun, state: .running)
    next.active = nextRun; next.acceptedCalls = 0
    let fresh = await next.host(.init(runID: nextRun, sequence: 1, method: "observe", arguments: bytes))
    #expect(fresh.code == nil && next.acceptedCalls == 1 && next.hostReadTasks.isEmpty)
    let freshBytes = try #require(fresh.value)
    let value = try JSONDecoder().decode(JSONValue.self, from: freshBytes)
    #expect(value["data"]?["objects"]?.array.first?["value"]?["content"]?["source"] == .string("accepted writer"))
    #expect(value["cursor"] == .string(String(readCursor)))
    let oldSnapshot = await reader.heldSnapshot, newSnapshot = await reader.latestSnapshot
    #expect(oldSnapshot != nil && newSnapshot != nil && oldSnapshot != newSnapshot)
    #expect(try accepted.apply(to: store) == receipt)
    await next.shutdown()
    print("Script \(boundary.rawValue) cancelled before SQL row 1; actual VM steps=\(steps); next cut and accepted receipt preserved")
  }
}
