import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Panel page material reads", .serialized)
struct NotebookPanelPageReadTests {
  private final class SQLReads {
    var statements = 0
    var elementReads = 0
    var erasureReads = 0
    var pageLoads = 0
    func record(_ statement: OpaquePointer) {
      statements += 1
      guard let sql = sqlite3_expanded_sql(statement) else { return }
      defer { sqlite3_free(sql) }
      let text = String(cString: sql)
      if text.contains("FROM records"), text.contains("#/elements/@") { elementReads += 1 }
      if text.contains("FROM ink_element_erasures") { erasureReads += 1 }
      if text.contains("WHERE r.file='pages/") { pageLoads += 1 }
    }
  }

  private func measured<Value>(_ store: NotebookStore, _ operation: () throws -> Value) throws -> (Value, SQLReads) {
    let trace = SQLReads()
    let result = try store.readTransaction { _ in
      let database = store.currentSQL!
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
        guard let context, let statement else { return 0 }
        Unmanaged<SQLReads>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement))
        return 0
      }, Unmanaged.passUnretained(trace).toOpaque())
      defer { sqlite3_trace_v2(database.handle, 0, nil, nil) }
      return try operation()
    }
    return (result, trace)
  }

  private func read(_ store: NotebookStore, pageID: UUID, actor: UUID) throws -> (JSONValue, SQLReads) {
    try measured(store) { try store.readPanel(.init(target: .init(kind: .page, id: pageID)), actor: actor) }
  }

  @Test func mixedPageMatchesAddressedGeometryAndAppearance() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-read-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let frame = PageRect(x: 20, y: 30, width: 100, height: 80)
    let canonicalID = UUID().uuidString.lowercased(), strokeID = UUID(), otherStrokeID = UUID()
    let group = AgentElement(id: "group", kind: .group, frame: .init(x: 200, y: 300, width: 240, height: 120),
      source: "", html: "", basis: .init(size: .init(x: 120, y: 240), transform: .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)))
    func graphic(_ id: String, _ payload: NotebookGraphic, parent: String? = nil) -> AgentElement {
      .init(id: id, kind: .graphic, frame: frame, source: "", html: "", graphic: payload, parentID: parent)
    }
    let shape = graphic("shape", .init(shape: .rectangle, style: .init(fill: .black)), parent: group.id)
    let mask = NotebookGraphicMask().appending(.intersect, polygon: [.zero, .init(x: 0.6, y: 0), .init(x: 0.6, y: 1), .init(x: 0, y: 1)])
    let vertices: [NotebookFreehand.Vertex] = (0..<4095).map {
      .init(x: Double($0 % 3) / 2, y: $0 % 3 == 1 ? 1 : 0, opacity: 1)
    }
    let measured = NotebookGraphic(shape: .freehand, freehand: .init(layers: [.init(color: .black, vertices: vertices)]))
    let elements: [AgentElement] = [group, shape,
      .init(id: canonicalID, kind: .nativeText, frame: frame, source: "Text", html: ""),
      .init(id: "program", kind: .web, frame: frame, source: "Program", html: "<button>Count</button>", state: .number(4)),
      graphic("masked", .init(shape: .rectangle, style: .init(fill: .black), mask: mask)),
      graphic("hidden", .init(shape: .ellipse, visible: false)),
      graphic("measured", measured),
      graphic("claim-a", .init(shape: .rectangle, sourceInkIDs: [strokeID])),
      graphic("claim-z", .init(shape: .ellipse, sourceInkIDs: [strokeID, otherStrokeID])),
      graphic("ink", .init(shape: .rectangle, representation: .ink, sourceInkIDs: [otherStrokeID])),
      graphic("edge", .init(shape: .connector, connection: .init(
        start: .init(point: .zero, binding: .init(elementID: "shape")),
        end: .init(point: .zero, binding: .init(elementID: "masked")), bend: 20))),
      graphic("pending", .init(shape: .connector, connection: .init(
        start: .init(point: .zero, binding: .init(elementID: "missing")), end: .init(point: .init(x: 80, y: 50)))))
    ]
    func sample(_ x: Double, _ y: Double, width: Double) -> SpatialInkSample {
      .init(point: .init(x: x, y: y), timeOffset: 0, width: width, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }
    // Reversed action IDs and creation order exercise the SQL/address and
    // in-memory/paint order projections of the same measured erasures.
    let cuts = [
      PageInkAction(id: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!, tool: .eraser,
        samples: [sample(25, 70, width: 20)], sequence: 1,
        elementTargets: [.init(elementID: canonicalID.uppercased(), frame: frame, wholeElement: true), .init(elementID: "masked", frame: frame)]),
      PageInkAction(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, tool: .eraser,
        samples: [sample(100, 70, width: 20)], sequence: 2,
        elementTargets: [.init(elementID: canonicalID, frame: frame), .init(elementID: "masked", frame: frame)]),
      PageInkAction(tool: .eraser, samples: [sample(70, 70, width: 400)], sequence: 3,
        elementTargets: [.init(elementID: "program", frame: frame, wholeElement: true)]),
      PageInkAction(tool: .eraser, samples: [sample(70, 70, width: 400)], sequence: 4, isActive: false,
        elementTargets: [.init(elementID: "shape", frame: frame)])
    ]
    let drawing = PageInkDrawing(actions: [PageInkAction(id: strokeID, tool: .pen,
      samples: [sample(50, 50, width: 4)])] + cuts)
    var page = try store.loadPage(pageID)
    let changedElements = page.replaceElements(elements, actor: actor)
    let changedDrawing = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor)
    #expect(changedElements && changedDrawing)
    try store.savePage(page)
    let target = CollaborationTarget(kind: .page, id: pageID), cursor = try store.currentReadCursor()
    let loaded = try store.loadPage(pageID)
    let expected = try loaded.elements.map { element -> JSONValue in
      let addressed = try #require(try store.readPageElementSnapshot(pageID: pageID, elementID: element.id))
      var value: [String: JSONValue] = ["source": try .encode(element), "appearance": addressed.appearance]
      if element.graphic != nil { value["graphicResolution"] = try store.readGraphicResolution(target: target, elementID: element.id).readProjection(includeGeometry: true) }
      return .object(value)
    }
    let start = ContinuousClock.now
    let (result, trace) = try read(store, pageID: pageID, actor: actor)
    let elapsed = start.duration(to: .now)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(result["elements"]) == encoder.encode(JSONValue.array(expected)))
    #expect(result["rawInkPresent"] == .bool(true))
    #expect(result["elements"]?.array.first { $0["source"]?["id"] == .string(canonicalID) }?["appearance"]?["state"] == .string("erased"))
    #expect(result["elements"]?.array.first { $0["source"]?["id"] == .string("program") }?["appearance"]?["state"] == .string("erased"))
    #expect(result["elements"]?.array.first { $0["source"]?["id"] == .string("claim-a") }?["graphicResolution"]?["state"] == .string("hidden"))
    #expect(result["elements"]?.array.first { $0["source"]?["id"] == .string("claim-z") }?["graphicResolution"]?["state"] == .string("geometry"))
    print("PANEL_PAGE_MIXED elements=\(elements.count) SQL=\(trace.statements) addressed=\(trace.elementReads) erasures=\(trace.erasureReads) elapsed=\(elapsed) bytes=\(try encoder.encode(result).count)")
    #expect(trace.elementReads == 0, "A loaded page must not reread its bodies or graphic dependencies")
    #expect(trace.erasureReads == 0, "All element masks already belong to the loaded ink source")
    #expect(trace.pageLoads == 1)
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let (content, captureTrace) = try self.measured(store) { try store.capturePanelPageContent(presentation) }
    let (reused, reuseTrace) = try self.measured(store) { try store.readPanel(.init(target: target), actor: actor, reusing: content) }
    #expect(content.page == loaded)
    #expect(content.elements == result["elements"]?.array)
    #expect(reused == result, "The same cut supplies both native material and every mixed-element panel projection")
    #expect(captureTrace.pageLoads == 1 && reuseTrace.pageLoads == 0)
    #expect(reuseTrace.elementReads == 0 && reuseTrace.erasureReads == 0)
    #expect(try store.currentReadCursor() == cursor)
  }

  @Test func contentReuseRefreshesNavigationPresenceHistoryAndCursorAfterAwait() async throws {
    let f = try PageWindowFixture(count: 3); defer { f.clean() }
    let store = f.store, actor = f.actor, itemID = f.itemID, pageID = f.pages[0]
    let target = CollaborationTarget(kind: .page, id: pageID), actionID = UUID()
    _ = try store.editPanel(.init(workspaceID: store.storedWorkspaceID(), actionID: actionID, target: target,
      summary: "Caption", operations: [.init(kind: .insertElement, target: target, id: "caption",
        values: ["kind": .string("nativeText"), "source": .string("Retained content"),
          "frame": try .encode(PageRect(x: 20, y: 30, width: 100, height: 80))])], sources: [.init(id: "caption")]), actor: actor)
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let content = try store.capturePanelPageContent(presentation)
    let before = try store.readPanel(.init(target: target), actor: actor, reusing: content)
    #expect(before["history"]?["undoActionID"] == (try .encode(actionID)))
    let appended = PageDocument(size: f.size, actor: actor)
    // A different completed owner turn changes local history/selection and
    // notebook membership while the retained page's authored source stays put.
    try await Task.detached {
      try store.commandTransaction {
        let admission = try store.makePageAppendAdmission(itemID: itemID, pageID: appended.id, actor: actor, human: true)
        try store.publishPageAppend(page: appended, admission: admission, human: true)
        try store.savePresence(store.loadPresence().selecting(itemID: itemID, pageID: appended.id))
        try store.recordNativeHistory(.command(actionID), domain: .init(target), actor: actor, removing: true)
      }
    }.value
    #expect(try store.referenceRevision(target: target) == presentation.sourceRevision)
    let (after, trace) = try measured(store) {
      try store.readPanel(.init(target: target, includeFitBounds: true), actor: actor, reusing: content)
    }
    #expect(after["elements"] == before["elements"])
    #expect(after["history"]?["undoActionID"] == nil)
    #expect(after["cursor"] != before["cursor"])
    #expect(after["navigation"]?["position"]?["visibleRoot"] != before["navigation"]?["position"]?["visibleRoot"])
    #expect(after["navigation"]?["directory"]?["header"]?["item"]?["pageCount"] == .number(4))
    #expect(after["navigation"]?["directory"]?["header"]?["selectedPageID"] == (try .encode(appended.id)))
    #expect(after["navigation"]?["directory"]?["header"]?["selectedPageIndex"] == .number(3))
    #expect(after["basis"] == (try .encode(store.readBasis(targets: [target], includeSource: true))))
    #expect(after["fitBounds"] != .null)
    #expect(trace.pageLoads == 0, "Publication refreshes dynamic fields without loading the painted page again")
  }

  @Test func retainedContentRejectsChangedSourceTargetAndWorkspace() async throws {
    let f = try PageWindowFixture(count: 2); defer { f.clean() }
    let store = f.store, actor = f.actor, target = CollaborationTarget(kind: .page, id: f.pages[0])
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let content = try store.capturePanelPageContent(presentation)
    #expect(throws: NotebookStorageError.transactionConflict) {
      try store.readPanel(.init(target: .init(kind: .page, id: f.pages[1])), actor: actor, reusing: content)
    }
    let other = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("panel-other-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: other.root) }
    _ = try other.initializeWorkspace(actor: actor, pageSize: f.size, initialPageID: target.id)
    #expect(throws: NotebookStorageError.transactionConflict) {
      try other.readPanel(.init(target: target), actor: actor, reusing: content)
    }
    var changed = content.page
    let didChange = changed.replaceElements([.init(id: "new", kind: .nativeText,
      frame: .init(x: 10, y: 10, width: 100, height: 80), source: "Changed source", html: "")], actor: actor)
    #expect(didChange)
    let changedPage = changed
    _ = try await Task.detached { try store.savePage(changedPage) }.value
    #expect(throws: NotebookStorageError.transactionConflict) { try store.capturePanelPageContent(presentation) }
    #expect(throws: NotebookStorageError.transactionConflict) {
      try store.readPanel(.init(target: target), actor: actor, reusing: content)
    }
  }

  @Test func retainedContentRejectsLiveInkChangeBeforePersistence() throws {
    let f = try PageWindowFixture(count: 1); defer { f.clean() }
    let target = CollaborationTarget(kind: .page, id: f.pages[0])
    let presentation = try f.store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let content = try f.store.capturePanelPageContent(presentation)
    let originalInk = content.page.inkSource, cursor = try f.store.currentReadCursor()
    let stroke = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 40, y: 50),
      timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    let stamp = try #require(content.page.drawingStamp.advanced(by: f.actor))
    let change = try content.page.prepareInkChange(.append(stroke), stamp: stamp)
    #expect(content.page.publishLiveInkChange(change))
    #expect(content.page.inkSource.identity != originalInk.identity)
    #expect(try content.page.inkDrawing().action(id: stroke.id) != nil)
    #expect(try f.store.referenceRevision(target: target) == presentation.sourceRevision)
    #expect(try f.store.currentReadCursor() == cursor)
    #expect(throws: NotebookStorageError.transactionConflict) {
      try f.store.readPanel(.init(target: target, knownCursor: String(cursor)), actor: f.actor, reusing: content)
    }
  }

  @Test func hundredThousandPageElementsUseOneSourceRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-scale-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let file = pageFile(pageID), count = 100_000
    // Populate the existing sparse causal page format through its fragment
    // writer. This measures read-all projection, not causal-field admission.
    try store.commandTransaction {
      for index in 0..<count {
        let id = "element-\(index)", element = AgentElement(id: id, kind: .graphic,
          frame: .init(x: Double(index % 700), y: Double(index % 1000), width: 30, height: 30),
          source: "", html: "", graphic: .init(shape: .rectangle))
        try store.writeFragment(.init(address: file + "#/elements/@" + id, file: file, parent: file + "#",
          collection: "elements", member: id, position: index, value: try .encode(element), collections: []), database: store.currentSQL!)
      }
    }
    let cursor = try store.currentReadCursor(), start = ContinuousClock.now
    let (result, trace) = try read(store, pageID: pageID, actor: actor)
    let elapsed = start.duration(to: .now), entries = try #require(result["elements"]).array
    #expect(entries.count == count)
    #expect(entries.first?["source"]?["id"] == .string("element-0"))
    #expect(entries.last?["source"]?["id"] == .string("element-99999"))
    #expect(entries.last?["graphicResolution"]?["state"] == .string("geometry"))
    #expect(trace.elementReads == 0 && trace.erasureReads == 0)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let captureStarted = ContinuousClock.now
    let (content, captureTrace) = try measured(store) { try store.capturePanelPageContent(presentation) }
    let captureElapsed = captureStarted.duration(to: .now), reuseStarted = ContinuousClock.now
    let (reused, reuseTrace) = try measured(store) { try store.readPanel(.init(target: target), actor: actor, reusing: content) }
    let reuseElapsed = reuseStarted.duration(to: .now)
    #expect(reused == result)
    #expect(content.elements.count == count)
    #expect(captureTrace.pageLoads == 1 && reuseTrace.pageLoads == 0)
    #expect(reuseTrace.elementReads == 0 && reuseTrace.erasureReads == 0)
    #expect(try store.currentReadCursor() == cursor)
    print("PANEL_PAGE_SCALE elements=\(count) SQL=\(trace.statements) addressed=\(trace.elementReads) erasures=\(trace.erasureReads) elapsed=\(elapsed) bytes=\(try JSONEncoder().encode(result).count)")
    print("PANEL_PAGE_CUT_SCALE elements=\(count) capture=\(captureElapsed) reuse=\(reuseElapsed) capture_page_loads=\(captureTrace.pageLoads) reuse_page_loads=\(reuseTrace.pageLoads)")
  }

  @Test(arguments: [63, 64])
  func groupDepthUsesNativePendingProjectionWithoutDiscardingSource(depth: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-depth-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let frame = PageRect(x: 1, y: 1, width: 100, height: 80)
    var elements = (0..<depth).map { index in
      AgentElement(id: "group-\(index)", kind: .group, frame: frame, source: "", html: "",
        parentID: index == 0 ? nil : "group-\(index - 1)", basis: .init(size: .init(x: 100, y: 80)))
    }
    let mask = NotebookGraphicMask().appending(.intersect, polygon: [.zero, .init(x: 0.6, y: 0), .init(x: 0.6, y: 1), .init(x: 0, y: 1)])
    let child = AgentElement(id: "child", kind: .graphic, frame: frame, source: "Authored geometry", html: "",
      graphic: .init(shape: .rectangle, mask: mask), parentID: "group-\(depth - 1)")
    elements.append(child)
    var page = try store.loadPage(pageID)
    let changed = page.replaceElements(elements, actor: actor); #expect(changed)
    try store.savePage(page)
    let loaded = try store.loadPage(pageID), native = loaded.graphicGraph().resolve(child.id)
    let target = CollaborationTarget(kind: .page, id: pageID), cursor = try store.currentReadCursor()
    if depth == 63 { #expect(try store.readGraphicResolution(target: target, elementID: child.id) == native) }
    else {
      #expect(native == .pending([child.id]))
      #expect(throws: NotebookStorageError.self) { try store.readGraphicResolution(target: target, elementID: child.id) }
    }
    let (result, _) = try read(store, pageID: pageID, actor: actor)
    let entry = try #require(result["elements"]?.array.first { $0["source"]?["id"] == .string(child.id) })
    #expect(entry["source"] == (try .encode(child)))
    #expect(entry["graphicResolution"] == (try native.readProjection(includeGeometry: true)))
    #expect(!NotebookPanelEditableSubject.allows(entry))
    #expect(try store.currentReadCursor() == cursor)
  }
}
