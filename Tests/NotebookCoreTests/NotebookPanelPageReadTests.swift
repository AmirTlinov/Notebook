import CoreGraphics
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

  private func read(_ store: NotebookStore, pageID: UUID, actor: UUID,
    bounds: NotebookReadBounds? = nil) throws -> (JSONValue, SQLReads) {
    try measured(store) { try store.readPanel(.init(target: .init(kind: .page, id: pageID), bounds: bounds), actor: actor) }
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
    #expect(try content.projection().elements == result["elements"]?.array)
    #expect(try content.projection(in: .init(anchor: .zero,
      region: .init(x: 0, y: 0, width: loaded.size.width, height: loaded.size.height))).elements == expected,
      "Bounding the full physical page preserves addressed mixed geometry, measured ink and erasure projection")
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
    let refreshedCut = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let (warm, warmTrace) = try measured(store) { try store.capturePanelPageContent(refreshedCut, reusing: content.source) }
    #expect(warmTrace.pageLoads == 0)
    #expect(warm.page.elementSourceIdentity == content.page.elementSourceIdentity)
    #expect(warm.page.inkSource.identity == content.page.inkSource.identity)
    #expect(try store.readPanel(.init(target: target, includeFitBounds: true), actor: actor, reusing: warm) == after,
      "The retained immutable source does not retain its prior history, membership, presence or read cursor")
  }

  @Test func boundedPageProjectionKeepsNativeBodiesConnectionsAndWholeSources() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-window-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID(), size = PageSize(width: 1000, height: 1000)
    _ = try store.initializeWorkspace(actor: actor, pageSize: size, initialPageID: pageID)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let area = CGRect(x: 480, y: 480, width: 40, height: 40), strokeID = UUID()
    func shape(_ id: String, _ frame: PageRect, _ graphic: NotebookGraphic = .init(shape: .rectangle),
      parent: String? = nil) -> AgentElement {
      .init(id: id, kind: .graphic, frame: frame, source: "", html: "", graphic: graphic, parentID: parent)
    }
    var shifted = NotebookGraphic(shape: .rectangle, style: .init(fill: .black))
    // Production transforms keep their unit corners inside the authored body.
    // This admitted subframe paints x=480...500 inside the whole x=450...550.
    shifted.transform = .init(a: 0.2, b: 0, c: 0, d: 1, tx: 0.3, ty: 0)
    let elements: [AgentElement] = [
      .init(id: "group", kind: .group, frame: .init(x: 100, y: 100, width: 100, height: 100), source: "", html: "",
        basis: .init(size: .init(x: 100, y: 100), transform: .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0))),
      shape("escaped", .init(x: 380, y: -310, width: 30, height: 30), parent: "group"),
      shape("left", .init(x: 80, y: 490, width: 20, height: 20)),
      shape("right", .init(x: 850, y: 490, width: 20, height: 20)),
      shape("edge", .init(x: 800, y: 800, width: 50, height: 50), .init(shape: .connector,
        connection: .init(start: .init(point: .zero, binding: .init(elementID: "left")),
          end: .init(point: .zero, binding: .init(elementID: "right"))))),
      .init(id: "overflow", kind: .nativeText, frame: .init(x: 480, y: 430, width: 100, height: 10),
        source: Array(repeating: "Body", count: 8).joined(separator: "\n"), html: ""),
      .init(id: "program", kind: .web, frame: .init(x: 470, y: 485, width: 40, height: 20), source: "Counter",
        html: "<button>Count</button>", state: .number(17)),
      shape("hidden", .init(x: 490, y: 490, width: 10, height: 10), .init(shape: .rectangle, visible: false)),
      shape("pending", .init(x: 490, y: 490, width: 10, height: 10), .init(shape: .connector,
        connection: .init(start: .init(point: .zero, binding: .init(elementID: "missing")), end: .init(point: .init(x: 10, y: 10))))),
      shape("ink", .init(x: 495, y: 485, width: 10, height: 10), .init(shape: .rectangle, representation: .ink, sourceInkIDs: [strokeID])),
      shape("shifted", .init(x: 450, y: 490, width: 100, height: 20), shifted),
      shape("thick", .init(x: 455, y: 490, width: 5, height: 5), .init(shape: .rectangle, style: .init(strokeWidth: 60))),
      .init(id: "distant", kind: .web, frame: .init(x: 900, y: 900, width: 40, height: 40), source: "Elsewhere",
        html: String(repeating: "outside ", count: 8192))]
    var page = try store.loadPage(pageID)
    let changedElements = page.replaceElements(elements, actor: actor); #expect(changedElements)
    let drawing = PageInkDrawing(actions: [
      .init(id: strokeID, tool: .pen, samples: [.init(point: .init(x: 500, y: 490), timeOffset: 0,
        width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)]),
      .init(tool: .eraser, samples: [.init(point: .init(x: 490, y: 495), timeOffset: 0,
        width: 400, opacity: 1, force: 1, azimuth: 0, altitude: 1)], sequence: 1,
        elementTargets: [.init(elementID: "program", frame: elements[6].frame, wholeElement: true)])])
    let changedDrawing = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor); #expect(changedDrawing)
    try store.savePage(page)
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 400, y: 400), pixelScale: 1)))
    let content = try store.capturePanelPageContent(presentation), graph = content.page.graphicGraph()
    let text = try #require(graph.elementPresentation("overflow"))
    #expect(!area.intersects(CGRect(x: elements[5].frame.x, y: elements[5].frame.y,
      width: elements[5].frame.width, height: elements[5].frame.height)))
    #expect(area.intersects(text.bounds), "Native TextKit overflow, not the authored height, decides body membership")
    #expect(!area.intersects(CGRect(x: elements[4].frame.x, y: elements[4].frame.y,
      width: elements[4].frame.width, height: elements[4].frame.height)))
    let connection = try #require(graph.resolve("edge").layout)
    #expect(area.intersects(CGRect(x: connection.frame.x, y: connection.frame.y,
      width: connection.frame.width, height: connection.frame.height)))
    let anchor = WorldPoint(tileX: -1, tileY: 0, localX: WorldPoint.tileSize - 300, localY: 50)
    let bounds = NotebookReadBounds(anchor: anchor, region: .init(x: 780, y: 430, width: 40, height: 40))
    let (result, trace) = try measured(store) { try store.readPanel(.init(target: target, bounds: bounds), actor: actor, reusing: content) }
    let entries = try #require(result["elements"]).array, ids = entries.compactMap { $0["source"]?["id"]?.string }
    let expectedIDs = ["group", "escaped", "edge", "overflow", "program", "hidden", "pending", "ink", "shifted", "thick"]
    #expect(ids == expectedIDs, "Whole sources keep painter order; endpoint resolution remains in the full typed graph")
    #expect(result["worldOrigin"] == (try .encode(WorldPoint.zero)))
    #expect(result["size"] == (try .encode(size)))
    #expect(result["rawInkPresent"] == .bool(true))
    #expect(entries.first { $0["source"]?["id"] == .string("program") }?["appearance"]?["state"] == .string("erased"))
    #expect(entries.first { $0["source"]?["id"] == .string("hidden") }?["graphicResolution"]?["state"] == .string("hidden"))
    #expect(entries.first { $0["source"]?["id"] == .string("pending") }?["graphicResolution"] ==
      (try graph.resolve("pending").readProjection(includeGeometry: true)))
    for entry in entries {
      let id = try #require(entry["source"]?["id"]?.string), source = try #require(elements.first { $0.id == id })
      #expect(entry["source"] == (try .encode(source)), "Filtering never clips the editable source or program state")
      if source.graphic != nil { #expect(entry["graphicResolution"] == (try graph.resolve(id).readProjection(includeGeometry: true))) }
    }
    #expect(trace.pageLoads == 0 && trace.elementReads == 0 && trace.erasureReads == 0)
    #expect(content.page.elements == elements)
    #expect(try JSONEncoder().encode(result).count < 65_536, "The large excluded program is never part of the bounded reply")
    let next = try store.readPanel(.init(target: target,
      bounds: .init(anchor: .zero, region: .init(x: 880, y: 880, width: 80, height: 80)),
      knownCursor: result["cursor"]?.string), actor: actor, reusing: content)
    #expect(next["unchanged"] == nil && next["cursor"] == result["cursor"])
    #expect(next["elements"]?.array.compactMap { $0["source"]?["id"]?.string } == ["distant"],
      "A newly exposed window receives sources even without a content commit")
    let exactID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    let aliases = [exactID, exactID.lowercased()].map { AgentElement(id: $0, kind: .nativeText,
      frame: .init(x: 490, y: 490, width: 20, height: 20), source: $0, html: "") }
    let aliased = PageDocument(size: size, actor: actor, elements: aliases)
    let aliasedProjection = try NotebookPanelPageContent.projection(aliased,
      bounds: .init(origin: .init(x: 480, y: 480), width: 40, height: 40))
    #expect(aliasedProjection.elements.map { $0["source"] } == (try aliases.map(JSONValue.encode)),
      "Normalized visibility candidates disclose every exact authored alias in painter order")
    #expect(aliased.interactionElements(ids: [exactID.lowercased()]).first == aliases.first,
      "The ordinary canonical interaction lookup keeps its first-source contract")
  }

  @Test func boundedPageReadValidatesBeforeUnchangedAndKeepsTiledAnchors() throws {
    let f = try PageWindowFixture(count: 1); defer { f.clean() }
    let target = CollaborationTarget(kind: .page, id: f.pages[0]), cursor = String(try f.store.currentReadCursor())
    let invalid = try JSONValue.object(["anchor": try .encode(WorldPoint.zero),
      "region": .object(["x": .number(0), "y": .number(0), "width": .number(0), "height": .number(10)])]).decode(NotebookReadBounds.self)
    do {
      _ = try f.store.readPanel(.init(target: target, bounds: invalid, knownCursor: cursor), actor: f.actor)
      Issue.record("Invalid bounds cannot bypass admission through an unchanged cursor")
    } catch let error as CollaborationError { #expect(error.code == "invalid_region") }
    let distant = try f.store.readPanel(.init(target: target,
      bounds: .init(anchor: .init(tileX: WorldPoint.maximumTileIndex, tileY: 0, localX: 0, localY: 0),
        region: .init(x: 0, y: 0, width: 100, height: 100))), actor: f.actor)
    #expect(distant["elements"]?.array.isEmpty == true)
    #expect(distant["worldOrigin"] == (try .encode(WorldPoint.zero)))
    #expect(try f.store.readPanel(.init(target: target, knownCursor: cursor), actor: f.actor)["unchanged"] == .bool(true))
  }

  @Test func panelMetadataIgnoresNavigationReadClocksButRetainsAddressedChanges() throws {
    let f = try PageWindowFixture(count: 3); defer { f.clean() }
    let store = f.store, actor = f.actor, target = CollaborationTarget(kind: .page, id: f.pages[0])
    let workspaceID = try store.storedWorkspaceID(), captionActionID = UUID()
    func metadata() throws -> NotebookPanelMetadata {
      try store.readPanelMetadata(workspaceID: workspaceID, target: target, actor: actor)
    }
    _ = try store.editPanel(.init(workspaceID: workspaceID, actionID: captionActionID, target: target,
      summary: "Page caption", operations: [.init(kind: .insertElement, target: target, id: "caption",
        values: ["kind": .string("nativeText"), "source": .string("Unchanged caption"),
          "frame": try .encode(PageRect(x: 20, y: 30, width: 100, height: 80))])], sources: [.init(id: "caption")]), actor: actor)
    let before = try metadata(), board = CollaborationTarget(kind: .board, id: try store.workspaceHeader().rootBoardID)
    let foreignActionID = UUID()
    _ = try store.applyNativeAction(.init(id: foreignActionID, additionalOwners: [board], summary: "Another surface",
      expected: store.readBasis(targets: [board]).owners,
      operations: [.init(kind: .insertElement, target: board, id: "elsewhere",
        values: ["kind": .string("nativeText"), "source": .string("Board caption"),
          "worldOrigin": try .encode(WorldPoint.zero), "frame": try .encode(PageRect(x: 20, y: 30, width: 100, height: 80))])]), actor: actor)
    let unrelated = try metadata()
    #expect(unrelated.readCursor > before.readCursor && unrelated.changeCursor > before.changeCursor)
    #expect(unrelated.navigation != before.navigation)
    #expect(unrelated.sourceRevision == before.sourceRevision && unrelated.basis == before.basis)
    #expect(unrelated.history == before.history)
    #expect(unrelated.history["undoActionID"] == (try .encode(captionActionID)))
    #expect(try store.nativeHistory(domain: .board(board.id), actor: actor).last == .command(foreignActionID))
    #expect(unrelated.hasSameScene(as: before))
    let position = try #require(unrelated.navigation["position"]).decode(NotebookPagePosition.self)
    let directory = try #require(unrelated.navigation["directory"]).decode(NotebookPageDirectory.self)
    #expect(position.readCursor == unrelated.readCursor && directory.header.readCursor == unrelated.readCursor)
    #expect(directory.pages.allSatisfy { $0.position.readCursor == unrelated.readCursor }, "Wire navigation keeps every WAL read clock")

    try f.select(f.pages[1])
    let selected = try metadata()
    #expect(selected.sourceRevision == unrelated.sourceRevision && selected.basis == unrelated.basis)
    #expect(selected.history == unrelated.history)
    #expect(selected.navigation["directory"]?["header"]?["selectedPageID"] == (try .encode(f.pages[1])))
    #expect(!selected.hasSameScene(as: unrelated), "Actual page selection changes navigation")

    let caption = try #require(try store.readPageElement(pageID: target.id, elementID: "caption")), updatedActionID = UUID()
    _ = try store.editPanel(.init(workspaceID: workspaceID, actionID: updatedActionID, target: target,
      summary: "Update page caption", operations: [.init(kind: .updateElement, target: target, id: caption.id,
        values: ["source": .string("Changed caption")])], sources: [.init(id: caption.id, page: caption)]), actor: actor)
    let changed = try metadata()
    #expect(changed.sourceRevision != selected.sourceRevision && changed.basis != selected.basis)
    #expect(changed.history["undoActionID"] == (try .encode(updatedActionID)))
    #expect(changed.history != selected.history && !changed.hasSameScene(as: selected))
  }

  @Test func retainedContentRejectsChangedSourceTargetAndWorkspace() async throws {
    let f = try PageWindowFixture(count: 2); defer { f.clean() }
    let store = f.store, actor = f.actor, target = CollaborationTarget(kind: .page, id: f.pages[0])
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let content = try store.capturePanelPageContent(presentation)
    let bounds = NotebookReadBounds(anchor: .zero, region: .init(x: 0, y: 0, width: 150, height: 150))
    let before = try store.readPanel(.init(target: target, bounds: bounds), actor: actor, reusing: content)
    #expect(throws: NotebookStorageError.transactionConflict) {
      try store.readPanel(.init(target: .init(kind: .page, id: f.pages[1])), actor: actor, reusing: content)
    }
    let other = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("panel-other-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: other.root) }
    _ = try other.initializeWorkspace(actor: actor, pageSize: f.size, initialPageID: target.id)
    #expect(throws: NotebookStorageError.transactionConflict) {
      try other.readPanel(.init(target: target), actor: actor, reusing: content)
    }
    let otherCut = try other.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let (otherContent, otherTrace) = try measured(other) { try other.capturePanelPageContent(otherCut, reusing: content.source) }
    #expect(otherTrace.pageLoads == 1)
    #expect(otherContent.page.elementSourceIdentity != content.page.elementSourceIdentity,
      "A matching UUID in another store/workspace never borrows a retained capability")
    var changed = content.page
    let didChange = changed.replaceElements([.init(id: "new", kind: .nativeText,
      frame: .init(x: 600, y: 900, width: 100, height: 80), source: "Changed outside the window", html: "")], actor: actor)
    #expect(didChange)
    let changedPage = changed
    _ = try await Task.detached { try store.savePage(changedPage) }.value
    #expect(throws: NotebookStorageError.transactionConflict) { try store.capturePanelPageContent(presentation) }
    #expect(throws: NotebookStorageError.transactionConflict) {
      try store.readPanel(.init(target: target, bounds: bounds, knownCursor: String(store.currentReadCursor())), actor: actor, reusing: content)
    }
    let after = try store.readPanel(.init(target: target, bounds: bounds), actor: actor)
    #expect(after["elements"] == before["elements"], "Offscreen edits invalidate the whole source fence even when bounded hits stay the same")
    let changedCut = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let (changedContent, changedTrace) = try measured(store) { try store.capturePanelPageContent(changedCut, reusing: content.source) }
    #expect(changedTrace.pageLoads == 1)
    #expect(changedContent.page.elementSourceIdentity != content.page.elementSourceIdentity)
    #expect(changedContent.page.elements == changedPage.elements)
    #expect(try store.readPanel(.init(target: target, bounds: bounds), actor: actor, reusing: changedContent) == after)
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
    let (fresh, trace) = try measured(f.store) { try f.store.capturePanelPageContent(presentation, reusing: content.source) }
    #expect(trace.pageLoads == 1, "Advancing the live journal root revokes reuse even before a SQLite commit")
    #expect(fresh.page.inkSource.identity != content.page.inkSource.identity)
    #expect(try fresh.page.inkDrawing().action(id: stroke.id) == nil, "Fresh capture remains the admitted durable WAL value")
  }

  @Test func hundredThousandPageElementsUseOneSourceRead() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-scale-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let file = pageFile(pageID), count = 100_000
    let (_, emptyMetadataTrace) = try measured(store) {
      try store.readPanelMetadata(workspaceID: store.storedWorkspaceID(),
        target: .init(kind: .page, id: pageID), actor: actor)
    }
    // Populate the existing sparse causal page format through its fragment
    // writer. The cut still loads all typed source; visual disclosure encodes
    // only this material window, not causal-field admission or input latency.
    try store.commandTransaction {
      for index in 0..<count {
        let frame = index < 3 ? PageRect(x: 20 + Double(index) * 10, y: 20, width: 30, height: 30)
          : index == count - 1 ? PageRect(x: 60, y: 60, width: 30, height: 30)
          : PageRect(x: 600 + Double(index % 100), y: 900 + Double(index % 100), width: 30, height: 30)
        let id = "element-\(index)", element = AgentElement(id: id, kind: .graphic,
          frame: frame, source: "", html: "", graphic: .init(shape: .rectangle))
        try store.writeFragment(.init(address: file + "#/elements/@" + id, file: file, parent: file + "#",
          collection: "elements", member: id, position: index, value: try .encode(element), collections: []), database: store.currentSQL!)
      }
    }
    let metadataStart = ContinuousClock.now
    let (metadata, metadataTrace) = try measured(store) {
      try store.readPanelMetadata(workspaceID: store.storedWorkspaceID(),
        target: .init(kind: .page, id: pageID), actor: actor)
    }
    let metadataElapsed = metadataStart.duration(to: .now)
    #expect(metadataTrace.pageLoads == 0 && metadataTrace.elementReads == 0 && metadataTrace.erasureReads == 0)
    #expect(metadataTrace.statements == emptyMetadataTrace.statements,
      "Checking a panel checkpoint must not add SQL work as its page grows")
    #expect(metadata.sourceRevision == (try store.referenceRevision(target: .init(kind: .page, id: pageID))))
    let cursor = try store.currentReadCursor(), start = ContinuousClock.now
    let bounds = NotebookReadBounds(anchor: .zero, region: .init(x: 0, y: 0, width: 100, height: 100))
    let (result, trace) = try read(store, pageID: pageID, actor: actor, bounds: bounds)
    let elapsed = start.duration(to: .now), entries = try #require(result["elements"]).array
    #expect(entries.count == 4)
    #expect(entries.compactMap { $0["source"]?["id"]?.string } == ["element-0", "element-1", "element-2", "element-99999"])
    #expect(entries.first?["source"]?["id"] == .string("element-0"))
    #expect(entries.last?["source"]?["id"] == .string("element-99999"))
    #expect(entries.last?["graphicResolution"]?["state"] == .string("geometry"))
    #expect(trace.elementReads == 0 && trace.erasureReads == 0)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let presentation = try store.requestPanelPresentation(.init(target: target,
      appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1)))
    let captureStarted = ContinuousClock.now
    let (content, captureTrace) = try measured(store) { try store.capturePanelPageContent(presentation) }
    let captureElapsed = captureStarted.duration(to: .now), projectionStarted = ContinuousClock.now
    let projected = try content.projection(in: bounds), projectionElapsed = projectionStarted.duration(to: .now)
    let reuseStarted = ContinuousClock.now
    let (reused, reuseTrace) = try measured(store) { try store.readPanel(.init(target: target, bounds: bounds), actor: actor, reusing: content) }
    let reuseElapsed = reuseStarted.duration(to: .now)
    #expect(reused == result)
    #expect(content.page.elements.count == count, "Bounding disclosure never shrinks the native source cut or its full-page fence")
    #expect(projected.elements == entries)
    #expect(captureTrace.pageLoads == 1 && reuseTrace.pageLoads == 0)
    #expect(reuseTrace.elementReads == 0 && reuseTrace.erasureReads == 0)
    let retainedSource = content.sourceForRetention()
    let warmStarted = ContinuousClock.now
    let (warmContent, warmTrace) = try measured(store) { try store.capturePanelPageContent(presentation, reusing: retainedSource) }
    let warmElapsed = warmStarted.duration(to: .now)
    #expect(warmTrace.pageLoads == 0 && warmTrace.elementReads == 0 && warmTrace.erasureReads == 0)
    #expect(warmContent.page.elements.count == count)
    #expect(warmContent.page.elementSourceIdentity == content.page.elementSourceIdentity)
    #expect(warmContent.page.inkSource.identity == content.page.inkSource.identity)
    let warmReadStarted = ContinuousClock.now
    let (warmResult, warmReadTrace) = try measured(store) {
      try store.readPanel(.init(target: target, bounds: bounds), actor: actor, reusing: warmContent)
    }
    let warmReadElapsed = warmReadStarted.duration(to: .now)
    #expect(warmReadTrace.pageLoads == 0 && warmResult == result)
    #expect(try store.currentReadCursor() == cursor)
    let bytes = try JSONEncoder().encode(result).count
    #expect(bytes < 65_536, "The actual 100K-source reply fits the panel's encoded budget with only four exposed whole bodies")
    print("PANEL_PAGE_SCALE source_elements=\(count) projected_elements=\(entries.count) SQL=\(trace.statements) addressed=\(trace.elementReads) erasures=\(trace.erasureReads) elapsed=\(elapsed) bytes=\(bytes)")
    print("PANEL_PAGE_CUT_SCALE source_elements=\(count) capture=\(captureElapsed) projection=\(projectionElapsed) reuse=\(reuseElapsed) capture_page_loads=\(captureTrace.pageLoads) reuse_page_loads=\(reuseTrace.pageLoads)")
    print("PANEL_PAGE_SOURCE_WARM source_elements=\(count) capture=\(warmElapsed) read=\(warmReadElapsed) capture_page_loads=\(warmTrace.pageLoads) read_page_loads=\(warmReadTrace.pageLoads) sources=\(entries.count) bytes=\(bytes) admission_estimate=\(retainedSource.admissionEstimateBytes ?? 0) direct_capability=true publisher_grant=false")
    print("PANEL_METADATA_SCALE elements=\(count) SQL=\(metadataTrace.statements) empty_SQL=\(emptyMetadataTrace.statements) elapsed=\(metadataElapsed) page_loads=\(metadataTrace.pageLoads)")
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
    let bounded = try store.readPanel(.init(target: target,
      bounds: .init(anchor: .zero, region: .init(x: 0, y: 0, width: 180, height: 180))), actor: actor)
    #expect(bounded["elements"]?.array.first { $0["source"]?["id"] == .string(child.id) } == entry,
      "An admitted pending source remains explicit at the native group-depth boundary")
    #expect(try store.currentReadCursor() == cursor)
  }
}
