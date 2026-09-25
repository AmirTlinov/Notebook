import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Dense interaction windows avoid repeated eraser expansion", .serialized)
struct NotebookSpatialInkWindowScalingTests {
  private struct Work { let steps: Int; let eraserQueries: Int; let returnedRows: Int }

  @Test func overlappingLongContactsDoNotMultiplyEraserQueries() throws {
    let small = try measure(contacts: 256), large = try measure(contacts: 512)
    #expect(small.eraserQueries == 1 && large.eraserQueries == 1)
    #expect(small.returnedRows == 256 && large.returnedRows == 512)
    #expect(large.steps < small.steps * 3,
      "Doubling admitted pens and erasers must not quadruple repeated coverage-query work")
  }

  @Test func envelopeGapCandidatesDoNotConsumeAdmissionOrDecodeBodies() throws {
    try measureGap(candidates: 8_193)
  }

  @Test func hundredThousandGapCandidatesRemainMetadataOnly() throws {
    try measureGap(candidates: 100_000)
  }

  @Test func tiledBoundaryAndPinnedContactKeepTheirCompleteOffscreenErasers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let surface = SurfaceID.board(header.rootBoardID)
    let origin = WorldPoint(tileX: WorldPoint.maximumTileIndex - 100, tileY: -WorldPoint.maximumTileIndex + 100,
      localX: WorldPoint.tileSize - 50, localY: WorldPoint.tileSize - 50)
    func action(_ tool: SpatialInkTool, _ points: [SpatialPoint], _ counter: UInt64) -> SpatialInkAction {
      .init(tool: tool, spans: [.init(surface: surface, samples: points.enumerated().map { index, point in
        .init(point: point, worldPoint: origin.offsetBy(x: point.x, y: point.y), timeOffset: Double(index),
          width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], stamp: .init(counter: counter, actor: actor))
    }
    let pen = action(.pen, [.init(x: 20, y: 20), .init(x: 10_000, y: 20)], 1)
    let eraser = action(.eraser, [.init(x: 9_995, y: 20)], 2)
    let pinned = action(.pen, [.init(x: 20_000, y: 20_000)], 3)
    let pinEraser = action(.eraser, [.init(x: 20_000, y: 20_000)], 4)
    let gap = action(.eraser, [.init(x: 10_000, y: 10_000)], 5)
    try store.saveSpatialInk(.init(actions: [pen, eraser, pinned, pinEraser, gap], stamp: gap.stamp))
    let coverage = [surface: WorkspaceSpatialBounds(origin: origin, width: 100, height: 100)]
    let window = try store.readSpatialInkWindow(coverage: coverage, pinnedActionIDs: [pinned.id])
    #expect(Set(window.journal.actions.map(\.id)) == [pen.id, eraser.id, pinned.id, pinEraser.id])
    #expect(window.journal.actions.first { $0.id == pen.id } == pen)
    #expect(window.journal.actions.first { $0.id == pinned.id } == pinned)
    #expect(window.covers(coverage, pins: [pinned.id]))
    #expect(!window.covers(coverage, pins: [UUID()]))
    #expect(try window.records.isCurrent(store))
  }

  @Test func streamingRowsShareTheCollectedReadAllowance() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let database = try NotebookSQLConnection(url: file, writable: true, create: true)
    try database.limitReads(.init(rows: 1, bytes: 8, valueBytes: 8, reason: "streaming_rows"))
    var values: [Int64] = []
    #expect(throws: NotebookStorageError.limitExceeded("streaming_rows")) {
      try database.forEachRow("SELECT 1 UNION ALL SELECT 2") { values.append($0[0].integer!) }
    }
    #expect(values == [1])
    #expect(throws: NotebookStorageError.limitExceeded("streaming_rows")) { try database.rows("SELECT 3") }
  }

  private func measureGap(candidates: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let surface = SurfaceID.board(header.rootBoardID)
    func action(_ tool: SpatialInkTool, _ points: [SpatialPoint], _ counter: UInt64) -> SpatialInkAction {
      .init(tool: tool, spans: [.init(surface: surface, samples: points.enumerated().map { index, point in
        .init(point: point, worldPoint: .init(x: point.x, y: point.y), timeOffset: Double(index),
          width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], stamp: .init(counter: counter, actor: actor))
    }
    let horizontal = action(.pen, [.init(x: 10, y: 10), .init(x: 20_000, y: 10)], 1)
    let vertical = action(.pen, [.init(x: 20, y: 20), .init(x: 20, y: 20_000)], 2)
    let eraser = action(.eraser, [.init(x: 19_995, y: 10)], 3)
    let pinned = action(.pen, [.init(x: 20_000, y: 20_000)], 4)
    let pinEraser = action(.eraser, [.init(x: 20_000, y: 20_000)], 5)
    let retained = [horizontal, vertical, eraser, pinned, pinEraser]
    try store.saveSpatialInk(.init(actions: retained, stamp: pinEraser.stamp))
    let stamp = VersionStamp(counter: UInt64(candidates + 5), actor: actor)
    // Ordinary fragment publication builds valid immutable bodies and their
    // derived bounds, without retaining a 100000-action fixture in memory.
    try store.commandTransaction {
      for index in 0..<candidates {
        let gap = action(.eraser, [.init(x: 10_000 + Double(index % 100) / 100, y: 10_000)], UInt64(index + 6))
        let rows = try NotebookRecordCodec.encode(.encode(SpatialInkJournal(actions: [gap], stamp: stamp)), file: "spatial-ink.json")
        for row in rows where row.parent != nil {
          try store.writeFragment(row.replacing(value: row.value, position: row.collection == "actions" ? index + 5 : 0), database: store.currentSQL!)
        }
      }
      let root = try #require(try store.storedFragments(address: "spatial-ink.json#", descendants: false).first)
      try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(stamp))), database: store.currentSQL!)
    }
    let trace = DenseInkSQLWork(), started = ContinuousClock.now
    let coverage = [surface: WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)]
    let window = try store.readTransaction { _ in
      let database = try #require(store.currentSQL)
      trace.attach(database)
      defer { trace.detach(database) }
      return try store.readSpatialInkWindow(coverage: coverage, pinnedActionIDs: [pinned.id])
    }
    #expect(Set(window.journal.actions.map(\.id)) == Set(retained.map(\.id)))
    #expect(window.covers(coverage, pins: [pinned.id]))
    let expectedRows = Set(retained.flatMap { action in
      let address = "spatial-ink.json#/actions/@" + action.id.uuidString.lowercased()
      return [address, address + "/spans"]
    })
    #expect(trace.decodedActionRows == expectedRows, "Envelope gaps never load a header or immutable span body")
    #expect(trace.eraserQueries == 1 && trace.eraserRows == candidates + 2)
    print("GAP_INK_WINDOW candidates=\(candidates) retained=\(window.journal.actions.count) vm_steps=\(trace.steps) eraser_queries=\(trace.eraserQueries) returned_eraser_rows=\(trace.eraserRows) decoded_rows=\(trace.decodedActionRows.count) read_duration=\(started.duration(to: .now))")
  }

  private func measure(contacts: Int) throws -> Work {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let surface = SurfaceID.board(header.rootBoardID)
    func span(_ x: Double, _ end: Double) -> SpatialInkSpan {
      .init(surface: surface, samples: [x, end].enumerated().map { index, x in
        .init(point: .init(x: x, y: 10), worldPoint: .init(x: x, y: 10), timeOffset: Double(index),
          width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })
    }
    // These are different, overlapping (not identical or contained) regions.
    // Their union is a narrow strip, not the rectangle between distant strokes.
    let pens = (0..<contacts).map { index in
      let offset = Double(index) / Double(contacts)
      return SpatialInkAction(tool: .pen, spans: [span(10 + offset, 10_000 + offset)],
        stamp: .init(counter: UInt64(index + 1), actor: actor))
    }
    let erasers = (0..<contacts).map { index in
      SpatialInkAction(tool: .eraser, spans: [span(9_990, 9_992)],
        stamp: .init(counter: UInt64(contacts + index + 1), actor: actor))
    }
    try store.saveSpatialInk(.init(actions: pens + erasers, stamp: .init(counter: UInt64(contacts * 2), actor: actor)))
    let coverage = [surface: WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)]
    let trace = DenseInkSQLWork()
    let records = try store.readTransaction { _ in
      let database = try #require(store.currentSQL)
      trace.attach(database)
      defer { trace.detach(database) }
      return try store.readSpatialInkWindowRecords(coverage: coverage)
    }
    let expected = Set((pens + erasers).flatMap { action in
      let address = "spatial-ink.json#/actions/@" + action.id.uuidString.lowercased()
      return [address, address + "/spans"]
    })
    #expect(Set(records.hashes.keys) == expected, "Every exact pen/eraser header and body survives expansion")
    #expect(try records.isCurrent(store))
    print("DENSE_INK_WINDOW pens=\(contacts) erasers=\(contacts) vm_steps=\(trace.steps) eraser_queries=\(trace.eraserQueries) returned_eraser_rows=\(trace.eraserRows)")
    return .init(steps: trace.steps, eraserQueries: trace.eraserQueries, returnedRows: trace.eraserRows)
  }
}

private final class DenseInkSQLWork {
  var steps = 0, eraserQueries = 0, eraserRows = 0
  var decodedActionRows = Set<String>()
  func attach(_ database: NotebookSQLConnection) {
    sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE | SQLITE_TRACE_ROW), { event, context, raw, _ in
      guard let context, let raw else { return 0 }
      let counter = Unmanaged<DenseInkSQLWork>.fromOpaque(context).takeUnretainedValue()
      let statement = OpaquePointer(raw)
      let sql = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
      let eraserQuery = sql.contains("AND s.tool='eraser'")
      if event == UInt32(SQLITE_TRACE_PROFILE) {
        counter.steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
        if eraserQuery { counter.eraserQueries += 1 }
      } else {
        if eraserQuery { counter.eraserRows += 1 }
        if sql == "SELECT r.address,b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address IN (?,?)",
          let value = sqlite3_column_text(statement, 0) { counter.decodedActionRows.insert(String(cString: value)) }
      }
      return 0
    }, Unmanaged.passUnretained(self).toOpaque())
  }
  func detach(_ database: NotebookSQLConnection) { sqlite3_trace_v2(database.handle, 0, nil, nil) }
}
