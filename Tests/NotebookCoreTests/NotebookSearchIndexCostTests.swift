import CSQLite
import Darwin
import Foundation
import Testing
@testable import NotebookCore

/// Run this method once per process with NOTEBOOK_SEARCH_TRACE_BYTES set to
/// 1024, 1048576 or 4194304. SQL tracing never replaces the progress handler.
@Suite("Isolated search writer cost", .serialized)
struct NotebookSearchIndexCostTests {
  #if DEBUG
  private final class DeliveryWork: @unchecked Sendable {
    let actionID: UUID
    private let lock = NSLock()
    private var passes = 0
    private var bytes: Int64 = 0
    init(actionID: UUID) { self.actionID = actionID }
    func record(_ sample: NotebookActionDeliveryObservation.Sample) {
      guard sample.actionID == actionID else { return }
      lock.lock(); defer { lock.unlock() }
      passes += 1; bytes += Int64(sample.framedBytes)
    }
    func snapshot() -> (passes: Int, bytes: Int64) {
      lock.lock(); defer { lock.unlock() }
      return (passes, bytes)
    }
  }
  #endif
  private final class Gate: @unchecked Sendable {
    let writerBegan = DispatchSemaphore(value: 0), inkAttempted = DispatchSemaphore(value: 0)
    func waitForWriter() throws {
      guard writerBegan.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
    }
  }
  private struct Memory: Codable {
    let mallocLiveBlocks: UInt32, mallocLiveBytes: UInt64, mallocReservedBytes: UInt64
    let sqliteBytes: Int64, residentFootprintBytes: UInt64
    static func read() -> Self {
      var statistics = malloc_statistics_t()
      malloc_zone_statistics(nil, &statistics) // Sum all allocator zones.
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      return .init(mallocLiveBlocks: statistics.blocks_in_use, mallocLiveBytes: UInt64(statistics.size_in_use),
        mallocReservedBytes: UInt64(statistics.size_allocated), sqliteBytes: sqlite3_memory_used(),
        residentFootprintBytes: status == KERN_SUCCESS ? info.phys_footprint : 0)
    }
  }
  private final class Trace: @unchecked Sendable {
    struct SQL: Codable { var executions = 0; var vmSteps: Int64 = 0; var profileNanoseconds: UInt64 = 0 }
    let gate: Gate, competingInk: Bool, coordinate: Bool
    var started: UInt64?, ended: UInt64?, coordinationNanoseconds: UInt64 = 0
    var statements = 0, vmSteps: Int64 = 0
    var liveBlocksPeak: UInt32 = 0, liveBytesPeak: UInt64 = 0, sqliteBytesPeak: Int64 = 0
    var databaseCachePeak: Int32 = 0, statementBytesPeak: Int32 = 0
    var sawInkAttempt = false
    var recordsOwner = false, ownerSQL: [String: SQL] = [:]
    init(gate: Gate, competingInk: Bool = false, coordinate: Bool = true) {
      self.gate = gate; self.competingInk = competingInk; self.coordinate = coordinate
    }
    func attach(_ database: NotebookSQLConnection) {
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE), { event, pointer, raw, duration in
        guard let pointer, let raw else { return 0 }
        let trace = Unmanaged<Trace>.fromOpaque(pointer).takeUnretainedValue(), statement = OpaquePointer(raw)
        let sql = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
        if event == UInt32(SQLITE_TRACE_STMT), trace.competingInk, sql == "BEGIN IMMEDIATE" {
          trace.gate.inkAttempted.signal()
        }
        if event == UInt32(SQLITE_TRACE_PROFILE) {
          trace.statements += 1
          let steps = Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
          trace.vmSteps += steps
          if trace.recordsOwner {
            var work = trace.ownerSQL[sql] ?? SQL()
            work.executions += 1; work.vmSteps += steps
            work.profileNanoseconds += duration?.assumingMemoryBound(to: UInt64.self).pointee ?? 0
            trace.ownerSQL[sql] = work
          }
          trace.sample(sqlite3_db_handle(statement))
          if sql == "BEGIN IMMEDIATE", sqlite3_get_autocommit(sqlite3_db_handle(statement)) == 0 {
            trace.started = DispatchTime.now().uptimeNanoseconds
            if !trace.competingInk && trace.coordinate {
              trace.gate.writerBegan.signal()
              trace.sawInkAttempt = trace.gate.inkAttempted.wait(timeout: .now() + 5) == .success
              trace.coordinationNanoseconds = DispatchTime.now().uptimeNanoseconds - trace.started!
            }
          }
          if sql == "COMMIT", sqlite3_get_autocommit(sqlite3_db_handle(statement)) != 0 {
            trace.ended = DispatchTime.now().uptimeNanoseconds
          }
        }
        return 0
      }, Unmanaged.passUnretained(self).toOpaque())
    }
    func detach(_ database: NotebookSQLConnection) { sqlite3_trace_v2(database.handle, 0, nil, nil) }
    private func sample(_ handle: OpaquePointer?) {
      var statistics = malloc_statistics_t(); malloc_zone_statistics(nil, &statistics)
      liveBlocksPeak = max(liveBlocksPeak, statistics.blocks_in_use)
      liveBytesPeak = max(liveBytesPeak, UInt64(statistics.size_in_use))
      sqliteBytesPeak = max(sqliteBytesPeak, sqlite3_memory_used())
      var current: Int32 = 0, high: Int32 = 0
      if sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_USED, &current, &high, 0) == SQLITE_OK { databaseCachePeak = max(databaseCachePeak, current) }
      if sqlite3_db_status(handle, SQLITE_DBSTATUS_STMT_USED, &current, &high, 0) == SQLITE_OK { statementBytesPeak = max(statementBytesPeak, current) }
    }
    var heldMilliseconds: Double? {
      guard let started, let ended else { return nil }; return Double(ended - started) / 1_000_000
    }
  }

  private enum RollbackProbe: Error { case measured }
  private struct IndexOnlyResult: Encodable {
    let sourceBytes: Int, updateSearchIndexMilliseconds: Double
    let ownerVMSteps: Int64, topLevelSQLProfileMilliseconds: Double, nonSQLOrProfileResolutionMilliseconds: Double
    let sql: [String: Trace.SQL]
    let before: Memory, after: Memory, mallocLiveBlocksAtSQLPeak: UInt32, mallocLiveBytesAtSQLPeak: UInt64
    let sourceHash: String, rollbackPreservedSourceIndexAndCursors: Bool
    let measurement = "Only actual updateSearchIndex, inside the sole writer, followed by deliberate whole-transaction rollback. Top-level PROFILE includes nested FTS; all raw statement profiles are retained and may overlap. SQLite profile timing is millisecond-resolution; residual combines non-SQL preparation and resolution/instrumentation."
  }

  @Test func indexOnlyOneCharacterEditAttributesItsOwnerAndRollsBackTheFixture() throws {
    let count = Int(ProcessInfo.processInfo.environment["NOTEBOOK_SEARCH_TRACE_BYTES"] ?? "1024")!
    let allowed = [1_024, 1_048_576, 4_194_304]
    #expect(allowed.contains(count)); guard allowed.contains(count) else { return }
    let f = try DocumentFileFixture(files: [.init(id: "source", path: "main.tex")])
    let phrase = "Пример Café Ελληνικά 中文 🖋️ <literal> ", padding = count - 1
    let original = "A" + String(repeating: phrase, count: padding / phrase.utf8.count)
      + String(repeating: "x", count: padding % phrase.utf8.count)
    let edited = "B" + original.dropFirst()
    var document = try f.store.loadDocument(f.id)
    _ = document.replaceContent(files: [.init(id: "source", path: "main.tex", source: original)], actor: f.actor)
    _ = try f.store.saveMergedDocument(document)
    let address = documentFile(f.id) + "#/files/@source"
    let fragment = try #require(try f.store.storedFragments(address: address, descendants: false).first)
    let next = fragment.replacing(value: fragment.value.setting("source", .string(edited)))
    let database = try f.store.prepareDatabase(), sourceHash = try #require(try database.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text)
    func indexRows() throws -> [[String]] {
      try database.rows("SELECT address,plain_text,folded FROM search_entries ORDER BY address").map { $0.map { $0.text! } }
        + database.rows("SELECT gram,entry_id FROM search_short ORDER BY gram,entry_id").map { [$0[0].text!, String($0[1].integer!)] }
    }
    let index = try indexRows(), read = try f.store.currentReadCursor(), delivery = try f.store.currentChangeCursor()
    let trace = Trace(gate: Gate(), coordinate: false)
    trace.attach(database); defer { trace.detach(database) }
    let before = Memory.read()
    var duration: UInt64 = 0
    do {
      try f.store.commandTransaction(preparedDatabase: database) {
        let start = DispatchTime.now().uptimeNanoseconds
        trace.recordsOwner = true
        do { try f.store.updateSearchIndex(next, database: database) }
        catch { trace.recordsOwner = false; throw error }
        trace.recordsOwner = false; duration = DispatchTime.now().uptimeNanoseconds - start
        throw RollbackProbe.measured
      }
    } catch RollbackProbe.measured { }
    // Validation below may decode the file again. It is outside the measured
    // updater and must not inflate the attributed allocator/SQL peaks.
    trace.detach(database)
    let after = Memory.read()
    #expect(try indexRows() == index)
    #expect(try database.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text == sourceHash)
    #expect(try f.store.currentReadCursor() == read && f.store.currentChangeCursor() == delivery)
    #expect(try f.store.readDocumentFile(documentID: f.id, fileID: "source")?.file.source == original)
    #expect(try f.store.search("AПример").total == 1 && f.store.search("BПример").total == 0)
    let top = trace.ownerSQL.filter { sql, _ in
      sql.hasPrefix("SELECT rowid,folded FROM search_entries") || sql.hasPrefix("SELECT rowid FROM search_entries")
        || sql.hasPrefix("INSERT INTO search_entries(") || sql.hasPrefix("DELETE FROM search_short")
        || sql.hasPrefix("INSERT INTO search_short(") || sql.hasPrefix("DELETE FROM search_entries")
    }
    let topNanoseconds = top.values.reduce(UInt64(0)) { $0 + $1.profileNanoseconds }
    let ownerSteps = trace.ownerSQL.values.reduce(Int64(0)) { $0 + $1.vmSteps }
    #expect(duration > 0 && ownerSteps > 0 && !top.isEmpty)
    let result = IndexOnlyResult(sourceBytes: count, updateSearchIndexMilliseconds: Double(duration) / 1_000_000,
      ownerVMSteps: ownerSteps, topLevelSQLProfileMilliseconds: Double(topNanoseconds) / 1_000_000,
      nonSQLOrProfileResolutionMilliseconds: Double(max(duration, topNanoseconds) - topNanoseconds) / 1_000_000,
      sql: trace.ownerSQL, before: before, after: after, mallocLiveBlocksAtSQLPeak: trace.liveBlocksPeak,
      mallocLiveBytesAtSQLPeak: trace.liveBytesPeak, sourceHash: sourceHash, rollbackPreservedSourceIndexAndCursors: true)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(result)
    if let path = ProcessInfo.processInfo.environment["NOTEBOOK_SEARCH_TRACE_OUTPUT"] { try data.write(to: URL(fileURLWithPath: path)) }
    print("SEARCH_INDEX_ONLY_COST \(String(decoding: data, as: UTF8.self))")
  }

  private struct Result: Encodable {
    struct Preparation: Encodable {
      let milliseconds: Double
      let maximumPayloadBytes: Int, maximumCompletionBytes: Int
      let retainedPayloadBytes: Int, retainedCompletionBytes: Int
      let acceptedPayloadBytes: Int, acceptedCompletionBytes: Int
      let after: Memory
    }
    let sourceBytes: Int, writerHoldMilliseconds: Double, coordinationMilliseconds: Double
    let preparation: Preparation
    let receiptDeliveryVersionPasses: Int?, receiptDeliveryHashInputBytes: Int64?
    let writerVMSteps: Int64, writerStatements: Int
    let mallocLiveBlocksAtSQLPeak: UInt32, mallocLiveBytesAtSQLPeak: UInt64
    let sqliteBytesAtSQLPeak: Int64, sqliteHighWaterBytes: Int64, databaseCacheBytesAtSQLPeak: Int32, statementBytesAtSQLPeak: Int32
    let before: Memory, after: Memory, processPeakRSSBytes: Int64
    let inkAttemptMilliseconds: Double, inkSaved: Bool, inkFailure: String?, inkWriterHoldMilliseconds: Double?
    let measurement = "Native document-source Save: immutable search preparation completes before BEGIN IMMEDIATE; the mandatory prepared command then commits source, search index, action and draft receipt together. Writer hold is completed BEGIN to completed COMMIT, including instrumentation and coordinated competing ink attempt. Preparation memory is a terminal live sample; malloc peaks are sampled at SQL PROFILE, not total allocation events. Process RSS high water includes setup. Admission costs are code-derived credits, not observed RSS."
  }

  @Test func multilingualOneCharacterEditMeasuresTheActualWriterAndCompetingInk() async throws {
    let count = Int(ProcessInfo.processInfo.environment["NOTEBOOK_SEARCH_TRACE_BYTES"] ?? "1024")!
    let allowed = [1_024, 1_048_576, 4_194_304]
    #expect(allowed.contains(count))
    guard allowed.contains(count) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-cost-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), documentID = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let pageID = try #require(index.selectedPageID)
    let phrase = "Пример Café Ελληνικά 中文 🖋️ <literal> "
    let padding = count - 1, repeats = padding / phrase.utf8.count
    let original = "A" + String(repeating: phrase, count: repeats) + String(repeating: "x", count: padding % phrase.utf8.count)
    let edited = "B" + original.dropFirst()
    #expect(original.utf8.count == count && edited.utf8.count == count)
    _ = index.createDocument(title: "Search cost", actor: actor, documentID: documentID)
    _ = board.addItem(documentID, to: header.rootBoardID, near: .zero, actor: actor)
    try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: documentID, actor: actor,
      files: [.init(id: "source", path: "main.tex", source: original)]), state: .init(id: documentID, actor: actor), board: board)
    let document = try store.loadDocument(documentID)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: documentID, fileID: "source",
      baseSource: original, baseVersion: document.fileVersion(fileID: "source"), source: edited, sequence: 1)
    let before = Memory.read(), preparationStarted = DispatchTime.now().uptimeNanoseconds
    let maximum = try PreparedDocumentSourceEdit.cost(for: edit)
    let prepared = try PreparedDocumentSourceEdit(edit: edit, workspaceID: header.workspaceID)
    let preparation = Result.Preparation(
      milliseconds: Double(DispatchTime.now().uptimeNanoseconds - preparationStarted) / 1_000_000,
      maximumPayloadBytes: maximum.payloadBytes, maximumCompletionBytes: maximum.completionBytes,
      retainedPayloadBytes: prepared.retainedCost.payloadBytes, retainedCompletionBytes: prepared.retainedCost.completionBytes,
      acceptedPayloadBytes: prepared.cost.payloadBytes, acceptedCompletionBytes: prepared.cost.completionBytes,
      after: Memory.read())
    #expect(prepared.retainedCost.bytes <= maximum.bytes)
    #expect(maximum.bytes <= 64 * 1_024 * 1_024 && prepared.cost.bytes <= 256 * 1_024 * 1_024)
    let page = try store.loadPage(pageID), ink = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 10, y: 20),
      timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    let inkStamp = try #require(page.drawingStamp.advanced(by: actor))
    let command = NotebookPageInkCommand(try page.prepareInkChange(.append(ink), stamp: inkStamp))
    let mainSQL = try store.prepareDatabase(), competingStore = NotebookStore(root: root)
    let gate = Gate(), trace = Trace(gate: gate), inkTrace = Trace(gate: gate, competingInk: true)
    trace.attach(mainSQL)
    defer { trace.detach(mainSQL) }
    _ = sqlite3_memory_highwater(1)
    let competitor = Task.detached { () throws -> (Double, Bool, String?) in
      let inkSQL = try competingStore.prepareDatabase()
      inkTrace.attach(inkSQL)
      defer { inkTrace.detach(inkSQL) }
      try gate.waitForWriter()
      let start = DispatchTime.now().uptimeNanoseconds
      do {
        _ = try competingStore.commandTransaction(preparedDatabase: inkSQL) { try competingStore.commitPageInk(pageID: pageID, command: command) }
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, true, nil)
      } catch { return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, false, String(describing: error)) }
    }
    #if DEBUG
      let deliveryWork = DeliveryWork(actionID: edit.sessionID)
    #endif
    do {
      let save = {
        try store.commandTransaction(preparedDatabase: mainSQL) {
          try store.commitDocumentSource(prepared, actor: actor)
        }
      }
      #if DEBUG
        let result = try NotebookActionDeliveryObservation.withObserver(deliveryWork.record, operation: save)
      #else
        let result = try save()
      #endif
      #expect(result.status == .committed)
    }
    catch { gate.writerBegan.signal(); _ = try? await competitor.value; throw error }
    let (inkWait, inkSaved, inkFailure) = try await competitor.value
    let after = Memory.read(), held = try #require(trace.heldMilliseconds)
    #expect(trace.sawInkAttempt && held > 0 && trace.vmSteps > 0)
    #expect(try store.loadDocument(documentID).files.first?.source == edited)
    if inkSaved { #expect(try store.loadPage(pageID).inkDrawing().actions.contains { $0.id == ink.id }) }
    #if DEBUG
      let delivery = deliveryWork.snapshot()
      #expect(delivery.passes == 1 && delivery.bytes > 0)
      let receiptPasses: Int? = delivery.passes, receiptBytes: Int64? = delivery.bytes
    #else
      let receiptPasses: Int? = nil, receiptBytes: Int64? = nil
    #endif
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let result = Result(sourceBytes: count, writerHoldMilliseconds: held,
      coordinationMilliseconds: Double(trace.coordinationNanoseconds) / 1_000_000,
      preparation: preparation,
      receiptDeliveryVersionPasses: receiptPasses, receiptDeliveryHashInputBytes: receiptBytes,
      writerVMSteps: trace.vmSteps, writerStatements: trace.statements,
      mallocLiveBlocksAtSQLPeak: trace.liveBlocksPeak, mallocLiveBytesAtSQLPeak: trace.liveBytesPeak,
      sqliteBytesAtSQLPeak: trace.sqliteBytesPeak, sqliteHighWaterBytes: sqlite3_memory_highwater(0),
      databaseCacheBytesAtSQLPeak: trace.databaseCachePeak, statementBytesAtSQLPeak: trace.statementBytesPeak,
      before: before, after: after, processPeakRSSBytes: Int64(usage.ru_maxrss),
      inkAttemptMilliseconds: inkWait, inkSaved: inkSaved, inkFailure: inkFailure, inkWriterHoldMilliseconds: inkTrace.heldMilliseconds)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(result)
    if let path = ProcessInfo.processInfo.environment["NOTEBOOK_SEARCH_TRACE_OUTPUT"] { try data.write(to: URL(fileURLWithPath: path)) }
    print("SEARCH_WRITER_COST \(String(decoding: data, as: UTF8.self))")
  }
}
