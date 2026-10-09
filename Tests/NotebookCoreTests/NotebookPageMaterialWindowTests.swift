import CoreGraphics
import CSQLite
import Foundation
import Testing
@testable import NotebookCore

/// Measures the existing cold reads, including SQLite's internal RTree work.
/// EXPLAIN runs later on a fresh cut, outside both the body and VM allowances.
final class PageMaterialSQLTrace {
  private(set) var steps = 0
  private var statements: [String: (expanded: String, steps: Int)] = [:]
  func attach(_ database: NotebookSQLConnection) {
    var statement = sqlite3_next_stmt(database.handle, nil)
    while let current = statement {
      _ = sqlite3_stmt_status(current, SQLITE_STMTSTATUS_VM_STEP, 1)
      statement = sqlite3_next_stmt(database.handle, current)
    }
    sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, raw, _ in
      guard let context, let raw else { return 0 }
      Unmanaged<PageMaterialSQLTrace>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(raw))
      return 0
    }, Unmanaged.passUnretained(self).toOpaque())
  }
  func detach(_ database: NotebookSQLConnection) { sqlite3_trace_v2(database.handle, 0, nil, nil) }
  private func record(_ statement: OpaquePointer) {
    let count = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
    steps += count
    guard let sql = sqlite3_sql(statement), let expanded = sqlite3_expanded_sql(statement) else { return }
    defer { sqlite3_free(expanded) }
    let query = String(cString: sql)
    statements[query] = (String(cString: expanded), (statements[query]?.steps ?? 0) + count)
  }
  func reportPlans(_ store: NotebookStore, label: String) throws {
    try store.readTransaction { _ in
      for (query, work) in statements.sorted(by: { $0.value.steps > $1.value.steps }) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT") else { continue }
        let plan = try store.currentSQL!.rows("EXPLAIN QUERY PLAN " + work.expanded)
          .compactMap { $0[3].text }.joined(separator: " | ")
        print("\(label)_PLAN steps=\(work.steps) plan=\(plan) sql=\(query.replacingOccurrences(of: "\n", with: " "))")
      }
    }
  }
}

/// Restore the actual v29 disposable-index shape after authoring the fixture.
/// A fresh current database may already contain the admitted v30 index.
func retirePageMaterialFixtureTo29(_ store: NotebookStore) throws {
  let database = try NotebookSQLConnection(url: store.databaseURL, writable: true, create: false)
  try database.run("BEGIN IMMEDIATE")
  do {
    for event in ["insert", "remove", "update"] { try database.run("DROP TRIGGER IF EXISTS page_material_" + event) }
    try database.run("DROP TABLE IF EXISTS page_material_ranges")
    try database.run("DROP TABLE IF EXISTS page_material_entries")
    // v29 indexed page erasers, while v30 also admits existing pen contacts.
    try database.run("DELETE FROM ink_surfaces WHERE kind='page' AND tool='pen'")
    try database.run("PRAGMA user_version=29")
    try database.run("COMMIT")
  } catch { try? database.run("ROLLBACK"); throw error }
}

func pageMaterialAuthoredSnapshot(_ database: NotebookSQLConnection) throws -> [[String]] {
  let queries = [
    "SELECT address,file,parent,collection,member,position,hash FROM records ORDER BY address",
    "SELECT hash,data FROM blobs ORDER BY hash",
    "SELECT key,value FROM metadata ORDER BY key",
    "SELECT sequence,transaction_id,manifest_hash,byte_count FROM change_log ORDER BY sequence",
    "SELECT sequence,address,blob_hash FROM change_records ORDER BY sequence,address",
    "SELECT peer_id,direction,sequence FROM peer_cursors ORDER BY peer_id,direction"
  ]
  return try queries.flatMap { try database.rows($0) }.map { row in
    row.map { $0.text ?? $0.integer.map(String.init) ?? $0.blob?.base64EncodedString() ?? "null" }
  }
}

private struct PageMaterialFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-material-" + UUID().uuidString)
  let actor = UUID(), itemID = UUID(), pageID = UUID()
  let store: NotebookStore
  init() throws {
    store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194),
      initialNotebookID: itemID, initialPageID: pageID)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func replace(_ elements: [AgentElement]) throws {
    var page = try store.loadPage(pageID)
    _ = page.replaceElements(elements, actor: actor)
    try store.savePage(page)
  }
  func read(_ bounds: CGRect = .init(x: 0, y: 0, width: 200, height: 200), ink: Set<UUID> = [],
    limit: Int = 256) throws -> NotebookPageMaterialWindow {
    try store.readPageMaterialWindow(itemID: itemID, pageID: pageID, bounds: bounds, sourceInkIDs: ink, limit: limit)
  }
  func edit(_ id: String, values: [String: JSONValue]) throws {
    let target = CollaborationTarget(kind: .page, id: pageID)
    _ = try store.applyNativeElementEdits([.init(kind: .updateElement, target: target, id: id, values: values)],
      summary: "Изменить материал", sources: [store.readNativeElementSource(target: target, id: id)], actor: actor)
  }
}

@Suite("Cold page material uses addressed geometry and one source cut")
struct NotebookPageMaterialWindowTests {
  @Test func unadmittedReadRefusesAndIndexAdmissionPreservesContentAndCursors() throws {
    let f = try PageMaterialFixture(); defer { f.clean() }
    try f.replace([
      .init(id: "text", kind: .nativeText, frame: .init(x: 20, y: 20, width: 120, height: 40), source: "Hello", html: ""),
      .init(id: "large-program", kind: .web, frame: .init(x: 600, y: 600, width: 100, height: 100),
        source: "Offscreen", html: String(repeating: "x", count: 8 * 1_024 * 1_024))
    ])
    try f.edit("text", values: ["source": .string("Accepted text")])
    let history = try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor)
    #expect(!history.isEmpty)
    let read = try f.store.currentReadCursor(), change = try f.store.currentChangeCursor()
    try retirePageMaterialFixtureTo29(f.store)
    let db = try NotebookSQLConnection(url: f.store.databaseURL, writable: true, create: false)
    #expect(try db.rows("PRAGMA user_version").first?[0].integer == 29)
    #expect(try db.rows("SELECT name FROM sqlite_master WHERE name LIKE 'page_material_%'").isEmpty)
    let before = try pageMaterialAuthoredSnapshot(db)
    let reader = try NotebookSQLConnection(url: f.store.databaseURL, writable: false, create: false)
    do {
      _ = try f.store.readTransaction(using: reader) { _ in try f.read() }
      Issue.record("No partial or full-page fallback before local admission")
    } catch let error as CollaborationError { #expect(error.code == "page_material_not_admitted") }
    #expect(try pageMaterialAuthoredSnapshot(db) == before)
    _ = try f.store.prepareDatabase()
    #expect(try f.read().elements.map(\.id) == ["text"])
    #expect(try f.store.currentReadCursor() == read)
    #expect(try f.store.currentChangeCursor() == change)
    #expect(try pageMaterialAuthoredSnapshot(db) == before)
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor) == history)
    #expect(try db.rows("PRAGMA user_version").first?[0].integer == NotebookStore.currentDatabaseVersion)
    let reopened = NotebookStore(root: f.root)
    #expect(try reopened.readPageMaterialWindow(itemID: f.itemID, pageID: f.pageID, bounds: .init(x: 0, y: 0, width: 200, height: 200)).elements.map(\.id) == ["text"])
    #expect(throws: NotebookStorageError.limitExceeded("page_element_read")) {
      try reopened.readPageElement(pageID: f.pageID, elementID: "large-program")
    }
  }

  @Test func fittedTextAndTransformedGroupUseSamePlacementAsCompletePage() throws {
    let f = try PageMaterialFixture(); defer { f.clean() }
    let group = AgentElement(id: "whole", kind: .group, frame: .init(x: 100, y: 80, width: 300, height: 200), source: "", html: "",
      basis: .init(size: .init(x: 200, y: 100), transform: .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)))
    let text = AgentElement(id: "text", kind: .nativeText, frame: .init(x: 10, y: 10, width: 100, height: 5),
      source: "One\nTwo\nThree", html: "", textStyle: .init(fontSize: 20), parentID: "whole")
    let other = AgentElement(id: "offscreen", kind: .markdown, frame: .init(x: 600, y: 600, width: 20, height: 20), source: "Other", html: "")
    try f.replace([group, text, other])
    let complete = try f.store.loadPage(f.pageID).graphicGraph()
    let placed = try #require(complete.placement(text.id)), shown = NotebookElementPresentation(text, placement: placed)
    let point = CGPoint(x: 5, y: shown.localBounds.maxY - 2).applying(placed.transform)
    let bounds = CGRect(x: point.x, y: point.y, width: 1, height: 1)
    let material = try f.read(bounds)
    #expect(material.elements.map(\.id) == [text.id])
    #expect(material.dependencies.map(\.id) == [group.id])
    #expect(material.graphicGraph.placement(text.id) == placed)
    #expect(material.sources.count == 2)
    let currentSource = try f.store.readNativeElementSource(target: .init(kind: .page, id: f.pageID), id: text.id)
    #expect(material.source(for: text.id)?.versions == currentSource.versions)
    try f.edit(group.id, values: ["frame": .encode(group.frame.updatingOrigin(x: 200, y: 180))])
    #expect(try f.read(bounds).elements.isEmpty)
    #expect(try f.read(bounds.offsetBy(dx: 100, dy: 100)).elements.map(\.id) == [text.id])
    #expect(material.graphicGraph.placement(text.id) == placed, "The old immutable cut retains its own frame")
  }

  @Test func crossingConnectorCarriesOffWindowEndpointsAndRetainsCausalDeleteUndo() throws {
    let f = try PageMaterialFixture(); defer { f.clean() }
    func shape(_ id: String, x: Double) -> AgentElement {
      .init(id: id, kind: .graphic, frame: .init(x: x, y: 50, width: 40, height: 40), source: "", html: "", graphic: .init(shape: .rectangle))
    }
    let edge = AgentElement(id: "edge", kind: .graphic, frame: .init(x: 10, y: 10, width: 100, height: 100), source: "", html: "",
      graphic: .init(shape: .connector, connection: .init(start: .init(point: .zero, binding: .init(elementID: "left")),
        end: .init(point: .zero, binding: .init(elementID: "right")))))
    try f.replace([shape("left", x: 10), edge, shape("right", x: 700)])
    let bounds = CGRect(x: 300, y: 65, width: 20, height: 10)
    let window = try f.read(bounds)
    #expect(window.elements.map(\.id) == ["edge"])
    #expect(window.dependencies.map(\.id) == ["left", "right"])
    let complete = try f.store.loadPage(f.pageID).graphicGraph()
    #expect(window.graphicGraph.resolve("edge") == complete.resolve("edge"))
    let source = try #require(window.source(for: "edge")), target = source.target
    let removed = try f.store.applyNativeElementEdits([.init(kind: .removeElement, target: target, id: "edge")],
      summary: "Удалить стрелку", sources: [source], actor: f.actor)
    #expect(try f.read(bounds).elements.isEmpty)
    _ = try f.store.undoCollaborationAction(removed.receipt.id, actor: f.actor)
    #expect(try f.read(bounds).elements.map(\.id) == ["edge"])
    // An equal-bodied causal successor must still invalidate the old intent.
    #expect(throws: CollaborationError.self) {
      try f.store.applyNativeElementEdits([.init(kind: .removeElement, target: target, id: "edge")],
        summary: "Старое удаление", sources: [source], actor: f.actor)
    }
  }

  @Test func offscreenClaimWinnerAndNativeDeletionRetainCanonicalArbitration() throws {
    let f = try PageMaterialFixture(); defer { f.clean() }
    let ink = UUID()
    func shape(_ id: String, x: Double) -> AgentElement {
      .init(id: id, kind: .graphic, frame: .init(x: x, y: 20, width: 60, height: 60), source: "", html: "",
        graphic: .init(shape: .rectangle, sourceInkIDs: [ink]))
    }
    try f.replace([shape("a-loser", x: 20), shape("z-winner", x: 700)])
    let hidden = try f.read(ink: [ink])
    #expect(hidden.elements.isEmpty)
    #expect(hidden.dependencies.map(\.id) == ["a-loser", "z-winner"])
    #expect(hidden.graphicPresentation.suppressedInkIDs == [ink])
    #expect(hidden.graphicGraph.resolve("a-loser") == .hidden)
    let winner = try #require(hidden.source(for: "z-winner"))
    let removed = try f.store.applyNativeElementEdits([.init(kind: .removeElement, target: winner.target, id: winner.id)],
      summary: "Удалить победившую фигуру", sources: [winner], actor: f.actor)
    #expect(try f.read(ink: [ink]).elements.isEmpty, "Native deletion retains a hidden source claim")
    _ = try f.store.undoCollaborationAction(removed.receipt.id, actor: f.actor)
    #expect(try f.read(ink: [ink]).elements.isEmpty)
    try f.edit(winner.id, values: ["graphic": .object(["representation": .string("ink")])])
    #expect(try f.read(ink: [ink]).elements.map(\.id) == ["a-loser"])
  }

  @Test func addressedErasuresFollowActivityAndOverflowDoesNotPublishPartialCoverage() throws {
    let f = try PageMaterialFixture(); defer { f.clean() }
    let elements = (0..<3).map { i in AgentElement(id: "box-\(i)", kind: .graphic,
      frame: .init(x: 20 + Double(i) * 50, y: 20, width: 30, height: 30), source: "", html: "", graphic: .init(shape: .rectangle)) }
    try f.replace(elements)
    let samples = [10.0, 40.0].map { y in SpatialInkSample(point: .init(x: 35, y: y), timeOffset: y / 100,
      width: 10, opacity: 1, force: 1, azimuth: 0, altitude: 1) }
    let action = PageInkAction(tool: .eraser, samples: samples).erasingElements([.init(elementID: "box-0", frame: elements[0].frame)])
    var page = try f.store.loadPage(f.pageID)
    let change = try page.prepareInkChange(.append(action), stamp: .init(counter: 10, actor: f.actor))
    let changed = page.publishInkChange(change); #expect(changed); try f.store.savePage(page)
    let window = try f.read()
    #expect(window.elementErasures["box-0"]?.count == 1)
    #expect(window.elementErasures["box-1"] == nil)
    #expect(throws: NotebookStorageError.self) { try f.read(limit: 2) }
    let undo = try page.prepareInkChange(.setActive([action.id], false), stamp: .init(counter: 11, actor: f.actor))
    let undone = page.publishInkChange(undo); #expect(undone); try f.store.savePage(page)
    #expect(try f.read().elementErasures.isEmpty)
    #expect(window.elementErasures["box-0"]?.count == 1)
  }
}

private extension PageRect {
  func updatingOrigin(x: Double, y: Double) -> Self { .init(x: x, y: y, width: width, height: height) }
}

@Test("Cold material decodes the same viewport bodies at 1000 and 100000 page elements")
func pageMaterialWindowAtOneHundredThousandElements() throws {
  let f = try PageMaterialFixture(); defer { f.clean() }
  let parent = pageFile(f.pageID) + "#"
  var previous = 0, counts: [Int] = []
  for count in [1000, 100000] {
    try f.store.commandTransaction {
      for i in previous..<count {
        let element = AgentElement(id: "body-\(i)", kind: .markdown,
          frame: .init(x: i < 3 ? 10 + Double(i) * 10 : 600, y: i < 3 ? 10 : 600, width: 4, height: 4), source: "Body", html: "")
        try f.store.writeFragment(.init(address: parent + "/elements/@" + element.id, file: pageFile(f.pageID), parent: parent,
          collection: "elements", member: element.id, position: i, value: .encode(element), collections: []), database: f.store.currentSQL!)
      }
    }
    previous = count
    let trace = PageMaterialSQLTrace()
    try f.store.readTransaction { _ in
      let database = f.store.currentSQL!
      try database.limitReads(.init(rows: 256, bytes: 128_000, valueBytes: 16_000,
        reason: "Cold page reads only the viewport and addressed dependency closure", jsonDecodeBytes: 1_000_000, sqlSteps: 10_000))
      trace.attach(database)
      defer { trace.detach(database) }
      let window = try f.read(.init(x: 0, y: 0, width: 50, height: 50))
      #expect(window.elements.map(\.id) == ["body-0", "body-1", "body-2"])
      #expect(window.dependencies.isEmpty)
      #expect(window.sources.count == 3)
      counts.append(database.decodedFragmentCount)
      print("PAGE_MATERIAL_COLD total=\(count) visible=3 decoded_fragments=\(database.decodedFragmentCount) decoded_bytes=\(database.decodedFragmentBytes) sql_vm_steps=\(trace.steps)")
    }
    try trace.reportPlans(f.store, label: "PAGE_MATERIAL_\(count)")
  }
  #expect(counts[0] == counts[1])
}
