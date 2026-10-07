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
    func record(_ statement: OpaquePointer) {
      statements += 1
      guard let sql = sqlite3_expanded_sql(statement) else { return }
      defer { sqlite3_free(sql) }
      let text = String(cString: sql)
      if text.contains("FROM records"), text.contains("#/elements/@") { elementReads += 1 }
      if text.contains("FROM ink_element_erasures") { erasureReads += 1 }
    }
  }

  private func read(_ store: NotebookStore, pageID: UUID, actor: UUID) throws -> (JSONValue, SQLReads) {
    let trace = SQLReads()
    let result = try store.readTransaction { _ in
      let database = store.currentSQL!
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
        guard let context, let statement else { return 0 }
        Unmanaged<SQLReads>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement))
        return 0
      }, Unmanaged.passUnretained(trace).toOpaque())
      defer { sqlite3_trace_v2(database.handle, 0, nil, nil) }
      return try store.readPanel(.init(target: .init(kind: .page, id: pageID)), actor: actor)
    }
    return (result, trace)
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
    #expect(try store.currentReadCursor() == cursor)
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
    #expect(try store.currentReadCursor() == cursor)
    print("PANEL_PAGE_SCALE elements=\(count) SQL=\(trace.statements) addressed=\(trace.elementReads) erasures=\(trace.erasureReads) elapsed=\(elapsed) bytes=\(try JSONEncoder().encode(result).count)")
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
