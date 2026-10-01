import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Panel overview reads authored material metadata")
struct NotebookPanelMaterialBoundsTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-panel-fit-\(UUID())")
    let actor = UUID()
    let store: NotebookStore
    let header: NotebookWorkspaceHeader
    var target: CollaborationTarget { .init(kind: .board, id: header.rootBoardID) }
    init() throws {
      store = .init(root: root)
      header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func insert(_ id: String, target: CollaborationTarget? = nil, origin: WorldPoint, frame: PageRect) throws {
      let target = target ?? self.target
      _ = try store.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: id, values: [
        "kind": .string("graphic"), "source": .string(""), "worldOrigin": try .encode(origin),
        "frame": try .encode(frame), "graphic": try .encode(NotebookGraphic(shape: .rectangle))])],
        summary: "Фигура", sources: [.init(target: target, id: id)], actor: actor)
    }
    func pen(on boardID: UUID, at point: WorldPoint) throws -> SpatialInkAction {
      let action = SpatialInkAction(tool: .pen, spans: [.init(surface: .board(boardID), samples: [
        .init(point: .zero, worldPoint: point, timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])],
        stamp: .init(counter: 20, actor: actor))
      _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      return action
    }
    func bounds(_ target: CollaborationTarget? = nil) throws -> WorkspaceSpatialBounds {
      let value = try #require(try store.panelMaterialBounds(target: target ?? self.target))
      return .init(origin: value.anchor.offsetBy(x: value.region.x, y: value.region.y), width: value.region.width, height: value.region.height)
    }
  }

  @Test func explicitFitIncludesOffscreenCardsElementsAndInkButNotRetiredSources() throws {
    let f = try Fixture(); defer { f.clean() }
    let original = try f.bounds()
    try f.insert("offscreen", origin: .init(x: 40_000, y: 500), frame: .init(x: 0, y: 0, width: 500, height: 200))
    let pen = try f.pen(on: f.target.id, at: .init(x: -50_000, y: 70_000))
    let cursor = try f.store.currentChangeCursor()
    let local = NotebookPanelReadRequest(target: f.target, bounds: .init(anchor: .zero,
      region: .init(x: -1000, y: -1000, width: 2000, height: 2000)))
    let snapshot = try f.store.readPanel(local, actor: f.actor)
    #expect(snapshot["fitBounds"] == nil)
    #expect(snapshot["elements"]?.array.isEmpty == true)
    var overview = local; overview.knownCursor = snapshot["cursor"]?.string; overview.includeFitBounds = true
    let result = try f.store.readPanel(overview, actor: f.actor)
    #expect(result["unchanged"] == nil)
    let bounds = try f.bounds()
    #expect(bounds.contains(original), "The initial native card remains part of the overview")
    #expect(bounds.contains(.init(origin: .init(x: 40_000, y: 500), width: 500, height: 200)))
    #expect(bounds.contains(.init(origin: .init(x: -50_000, y: 70_000), width: 0, height: 0)))
    #expect(result["fitBounds"] == (try .encode(f.store.panelMaterialBounds(target: f.target))))
    #expect(try f.store.currentChangeCursor() == cursor)

    let source = try #require(try f.store.readSpatialElement(boardID: f.target.id, elementID: "offscreen"))
    _ = try f.store.applyNativeElementEdits([.init(kind: .removeElement, target: f.target, id: source.id)],
      summary: "Убрать фигуру", sources: [.init(target: f.target, id: source.id, spatial: source)], actor: f.actor)
    _ = try f.store.commitSpatialInk(.state(actionID: pen.id, creationStamp: pen.stamp, expectedStateStamp: pen.stateStamp,
      isActive: false, stateStamp: .init(counter: 21, actor: f.actor), journalStamp: .init(counter: 21, actor: f.actor)))
    #expect(try f.bounds() == original)
    let itemID = try #require(try f.store.loadIndex().items.first?.id)
    let page = try #require(try f.store.pageID(at: 0, in: itemID))
    let pageBounds = try #require(try f.store.panelMaterialBounds(target: .init(kind: .page, id: page)))
    #expect(pageBounds.anchor == .zero && pageBounds.region == .init(x: 0, y: 0, width: 834, height: 1194))
  }

  @Test func rootedGroupsAndInkKeepLocalPrecisionAtFarWorldAddresses() throws {
    let f = try Fixture(); defer { f.clean() }
    var index = try f.store.loadIndex(), tree = try f.store.loadBoard(items: index.items)
    let created = index.createBoard(title: "Far board", actor: f.actor)
    let item = try #require(created)
    let placed = tree.createBoard(item.id, in: f.target.id, near: .zero, actor: f.actor)
    #expect(placed)
    try f.store.saveBoardWorkspaceBundle(index: index, board: tree, boardID: item.id)
    let target = CollaborationTarget(kind: .board, id: item.id)
    #expect(try f.store.panelMaterialBounds(target: target) == nil)
    let origin = WorldPoint(tileX: 9_007_199_254_740_000, tileY: -9_007_199_254_740_000, localX: 0.25, localY: 0.5)
    try f.insert("a", target: target, origin: origin, frame: .init(x: 10, y: 20, width: 30, height: 40))
    try f.insert("b", target: target, origin: origin, frame: .init(x: 100, y: 30, width: 60, height: 80))
    let sources = try ["a", "b"].map { id in
      try NotebookNativeElementSource(target: target, id: id, spatial: f.store.readSpatialElement(boardID: item.id, elementID: id))
    }
    _ = try f.store.groupNativeElements(sources, id: "whole", actor: f.actor)
    _ = try f.pen(on: item.id, at: origin.offsetBy(x: 700.125, y: 300.25))
    let bounds = try f.bounds(target)
    #expect(bounds.origin.tileX == origin.tileX && bounds.origin.tileY == origin.tileY)
    #expect(bounds.width < 1000 && bounds.height < 500, "Whole fit never flattens enormous tiled addresses")
    for id in ["a", "b"] {
      let layout = try #require(try f.store.readGraphicResolution(target: target, elementID: id).layout)
      #expect(bounds.contains(.init(origin: layout.origin.offsetBy(x: layout.frame.x, y: layout.frame.y), width: layout.frame.width, height: layout.frame.height)))
    }
    #expect(bounds.contains(.init(origin: origin.offsetBy(x: 700.125, y: 300.25), width: 0, height: 0)))
    #expect(bounds.origin.localX.truncatingRemainder(dividingBy: 1) == 0.25)
  }

  @Test func explicitOverviewScansOneHundredThousandMetadataEntriesWithoutSourceBodies() throws {
    let f = try Fixture(); defer { f.clean() }
    let parent = "board.json#/boards/@" + f.target.id.uuidString.lowercased()
    let stamp = VersionStamp(counter: 0, actor: f.actor)
    // Stream the same canonical fixture used by graphic admission: normal
    // addressed records build their ordinary indexes without a BoardDocument.
    try f.store.commandTransaction {
      for index in 0..<100_000 {
        let id = "fit-\(index)"
        let element = SpatialElement(id: id, surface: .board(f.target.id), kind: .nativeText,
          frame: .init(x: 0, y: 0, width: 24, height: 24), worldOrigin: .init(x: Double(index) * 50, y: 0),
          source: "\(index)", stamp: stamp)
        try f.store.writeFragment(.init(address: parent + "/board/elements/@" + id, file: "board.json", parent: parent,
          collection: "board/elements", member: id, position: index, value: try .encode(element), collections: []), database: f.store.currentSQL!)
      }
    }
    let last = try #require(try f.store.readSpatialElement(boardID: f.target.id, elementID: "fit-99999"))
    let frame = PageRect(x: last.frame.x, y: last.frame.y, width: last.frame.width, height: last.frame.height)
    let placement = try NotebookElementPlacement(id: last.id, frame: frame).updating(frame: frame, basis: last.basis)
    let painted = NotebookElementPresentation(last, placement: placement).frame
    let expected = WorkspaceSpatialBounds(origin: last.worldOrigin!.offsetBy(x: painted.x, y: painted.y), width: painted.width, height: painted.height)
    final class Counter { var steps = 0 }
    let counter = Counter(), cursor = try f.store.currentChangeCursor(), started = ContinuousClock.now
    try f.store.readTransaction { _ in
      let database = f.store.currentSQL!
      try database.limitReads(.init(rows: 20, bytes: 4000, valueBytes: 1000, reason: "Overview reads metadata endpoints, never element or ink bodies"))
      sqlite3_progress_handler(database.handle, 100, { raw in
        Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue().steps += 100
        return 0
      }, Unmanaged.passUnretained(counter).toOpaque())
      defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
      let bounds = try f.bounds()
      #expect(bounds.contains(expected))
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    print("PANEL_FIT_METADATA entries=100000 elapsed=\(started.duration(to: .now)) vm_steps=\(counter.steps) read_rows_budget=20")
  }
}
