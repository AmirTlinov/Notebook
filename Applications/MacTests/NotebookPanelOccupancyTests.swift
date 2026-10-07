import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelOccupancyTests: XCTestCase {
  @MainActor
  func testOverviewKeepsNineCoversAtRequestedDensityThroughZoomAndReturn() async throws {
    try await InkRasterRenderer.shared.prepareInk()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-overview-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try fixture.store.workspaceHeader(), target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let first = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    let centers = [(-1141.0, 1512.0), (-1925, 3396), (4195, 4217), (1565, 3751),
      (4550, 1500), (3015, 3389), (1256, 1764), (5959, 1385), (350, 140)]
    try await fixture.move(first.id, boardID: target.id, to: .init(x: centers[0].0, y: centers[0].1))
    try await fixture.apply(centers.dropFirst().map { center in
      .init(kind: .createNotebook, target: target, id: UUID().uuidString,
        values: ["center": try .encode(WorldPoint(x: center.0, y: center.1)), "pageID": try .encode(UUID())])
    })
    try await fixture.apply([.init(kind: .appendInkStroke, target: target, id: UUID().uuidString,
      values: ["width": .number(3), "worldOrigin": try .encode(WorldPoint.zero), "points": .array([
        .object(["x": .number(10), "y": .number(10)]), .object(["x": .number(30), "y": .number(30)])])])])
    var known: [UUID] = []
    for scale in [0.104, 0.104 * 1.728, 0.104] {
      var command = NotebookCommand(command: .panelPresentation)
      command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
        appearance: .init(viewport: .init(x: 1759, y: 1713), pixelScale: 2,
          camera: .init(center: .init(x: 1558, y: 1940), scale: scale)), knownAssets: known)
      let started = ContinuousClock.now
      let reply = try await fixture.send(command)
      let elapsed = started.duration(to: .now)
      let cards = try XCTUnwrap(reply["cards"]?.arrayValues)
      let appearance = try XCTUnwrap(reply["appearance"]), layers = try XCTUnwrap(appearance["layers"]?.arrayValues)
      XCTAssertEqual(cards.count, 9)
      XCTAssertTrue(cards.allSatisfy { $0["frame"] != nil && $0["worldOrigin"] != nil && $0["editable"] == .bool(true) })
      XCTAssertEqual(layers.filter { $0["itemID"] != nil }.count, 9)
      XCTAssertFalse(appearance["diagnostics"]?.arrayValues.contains { $0["kind"] == .string("quality_limit") } == true)
      var pixels = 0
      for layer in layers {
        let width = try XCTUnwrap(layer["pixelWidth"]).decode(Int.self), height = try XCTUnwrap(layer["pixelHeight"]).decode(Int.self)
        pixels += width * height
        guard layer["repeatSize"] == nil else { continue }
        let frame = try XCTUnwrap(layer["frame"]).decode(PageRect.self)
        XCTAssertGreaterThanOrEqual(min(Double(width) / frame.width, Double(height) / frame.height) + 0.000001, scale * 2)
      }
      XCTAssertLessThanOrEqual(pixels, NotebookPanelRenderProjection.maximumDecodedPixels)
      XCTAssertLessThanOrEqual(layers.count, 96)
      known = try layers.map { try XCTUnwrap($0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:))) }
      print("PANEL_OVERVIEW scale=\(scale) cards=\(cards.count) layers=\(layers.count) pixels=\(pixels) preparation=\(elapsed)")
    }
  }

  @MainActor
  func testNonseparatedStackCardsKeepNativeGeometryAndPainterOrder() async throws {
    try await InkRasterRenderer.shared.prepareInk()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-card-geometry-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try fixture.store.workspaceHeader(), target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let first = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    let created = (0..<18).map { _ in UUID() }
    try await fixture.move(first.id, boardID: target.id, to: .zero)
    try await fixture.apply(created.map { id in
      .init(kind: .createNotebook, target: target, id: id.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
    })
    let stackIDs = Array(created.suffix(2)), actor = fixture.model.actorID
    try await fixture.model.performStoreCommand { store in
      let sources = try stackIDs.map { id in try XCTUnwrap(store.readBoardItem(id)?.board.placements.first { $0.id == id }) }
      _ = try store.applyNativePlacementEdits([.init(kind: .stackItems, target: target,
        values: ["itemIDs": try .encode(stackIDs)])], summary: "Prepare overlapping covers", sources: sources, actor: actor)
    }
    let presence = SessionPresence(boardID: target.id, mode: .board,
      camera: .init(center: .zero, scale: 0.5), viewport: .init(x: 900, y: 800))
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: presence.viewport, pixelScale: 1, camera: presence.camera))
    let reply = try await fixture.send(command), cards = try XCTUnwrap(reply["cards"]?.arrayValues)
    XCTAssertEqual(cards.count, 19)
    let source = SceneCompositionSource(store: fixture.store, revision: try fixture.store.currentChangeCursor(), workspaceID: header.workspaceID)
    var items: [RenderedWorkspaceItem] = []
    for card in cards {
      let id = try XCTUnwrap(card["item"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      let read = try await source.item(id, presence: presence), item = try XCTUnwrap(read)
      items.append(item)
      XCTAssertEqual(try XCTUnwrap(card["center"]).decode(WorldPoint.self), item.center)
      XCTAssertEqual(try XCTUnwrap(card["worldOrigin"]).decode(WorldPoint.self), item.center)
      XCTAssertEqual(try XCTUnwrap(card["frame"]).decode(PageRect.self),
        .init(x: -item.geometry.width / 2, y: -item.geometry.height / 2, width: item.geometry.width, height: item.geometry.height))
      if stackIDs.contains(id) { XCTAssertEqual(card["editable"], .bool(false), "Both stack members lie after the sixteen independent candidates") }
    }
    XCTAssertEqual(items.map(\.id), items.sorted { WorkspaceSceneProjection.isPaintedBelow($0, $1, in: presence) }.map(\.id))
    let stack = try XCTUnwrap(fixture.store.readBoardItem(stackIDs[0])?.board.stack(containing: stackIDs[0]))
    XCTAssertTrue(items.filter { stackIDs.contains($0.id) }.contains { $0.center != stack.center }, "A fan member keeps its visible native offset")
  }

  func testEmptyInkWitnessRejectsNewPaintAndClaimedContactKeepsItsMovedCell() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-ink-occupancy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let surface = SurfaceID.board(header.rootBoardID), tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let far = contact(surface: surface, x: 50_000, actor: actor, sequence: 1)
    _ = try store.commitSpatialInk(.append(far, journalStamp: far.stamp))
    let empty = SceneCompositionSource(store: store, revision: try store.currentChangeCursor(), workspaceID: header.workspaceID, recordPixelDependencies: true)
    let key = key(tile, boardID: header.rootBoardID, workspaceID: header.workspaceID)
    let absent = try await empty.tilesRequiringPaint([key])
    XCTAssertTrue(absent.isEmpty)
    let dependencies = try await empty.pixelDependencies(), witness = try XCTUnwrap(dependencies)
    XCTAssertTrue(try witness.isCurrent(store))
    let near = contact(surface: surface, x: 0, actor: actor, sequence: 2)
    _ = try store.commitSpatialInk(.append(near, journalStamp: near.stamp))
    XCTAssertFalse(try witness.isCurrent(store), "A formerly empty ink cell is part of the final publication witness")
    let occupied = SceneCompositionSource(store: store, revision: try store.currentChangeCursor(), workspaceID: header.workspaceID)
    let withPen = try await occupied.tilesRequiringPaint([key])
    XCTAssertEqual(withPen.map(\.tile), [tile])
    _ = try store.commitSpatialInk(.state(actionID: near.id, creationStamp: near.stamp, expectedStateStamp: near.stateStamp,
      isActive: false, stateStamp: .init(counter: 3, actor: actor), journalStamp: .init(counter: 3, actor: actor)))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var hierarchy = before
    let graphic = NotebookGraphic(shape: .freehand, sourceInkIDs: [far.id], freehand: .init(layers: [
      .init(tool: .pen, color: .black, measured: .init(sourceID: far.id, measurements: far.spans[0].samples,
        frame: .init(x: 49_998, y: -2, width: 24, height: 24), origin: .zero))]))
    XCTAssertEqual(graphic.sourceInkContactID, far.id)
    let element = SpatialElement(id: "moved-contact", surface: surface, kind: .graphic,
      frame: .init(x: -12, y: -12, width: 24, height: 24), worldOrigin: .zero, source: "", graphic: graphic,
      stamp: .init(counter: 4, actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(element, in: header.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveBoardEdits(before: before, after: hierarchy)
    let ink = try store.loadSpatialInk(), index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    for source in [SceneCompositionSource(store: store, revision: try store.currentChangeCursor(), workspaceID: header.workspaceID),
      SceneCompositionSource(index: index, hierarchy: hierarchy, journal: ink)] {
      let retained = try await source.tilesRequiringPaint([key])
      XCTAssertEqual(retained.map(\.tile), [tile], "The claimed measured body paints here although its raw contact is outside")
    }
  }

  func testHundredThousandDistantContactsAndElementsDoNotAllocateEmptyInkCells() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 100_000, actor: actor), boardID = WorkspaceRoot.boardID
    let far = WorldPoint(x: 1_000_000, y: 1_000_000)
    let item = WorkspaceItem.notebook(title: "Offscreen owner", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
    let elements = (0..<100_000).map { offset in SpatialElement(id: "far-\(offset)", surface: .board(boardID), kind: .graphic,
      frame: .init(x: 0, y: 0, width: 20, height: 20), worldOrigin: far, source: "", graphic: .init(shape: .rectangle), stamp: stamp) }
    let board = BoardDocument(freeItems: [.init(itemID: item.id, center: far, zIndex: 0, stamp: stamp)], elements: elements, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let samples = contact(surface: .board(boardID), x: 1_000_000, actor: actor, sequence: 1).spans
    let contacts = (0..<100_000).map { offset in SpatialInkAction(tool: .pen, spans: samples,
      stamp: .init(counter: UInt64(offset + 1), actor: actor)) }
    var journal = SpatialInkJournal(actions: contacts, stamp: stamp)
    let near = contact(surface: .board(boardID), x: 0, actor: actor, sequence: 100_001)
    XCTAssertNotNil(journal.append(tool: near.tool, spans: near.spans, actor: actor, id: near.id))
    let tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let keys = try (-2..<2).flatMap { row in try (-2..<2).map { column in
      key(try XCTUnwrap(tile.offset(columns: column, rows: row)), boardID: boardID, workspaceID: index.generationID)
    } }
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: journal)
    let started = ContinuousClock.now
    let retained = try await source.tilesRequiringPaint(keys)
    XCTAssertEqual(retained.map(\.tile), [tile])
    XCTAssertEqual(journal.actionCount, 100_001)
    print("PANEL_INK_OCCUPANCY far_contacts=100000 far_elements=100000 probes=16 retained=1 elapsed=\(started.duration(to: .now))")
  }

  private func key(_ tile: CompositionTile, boardID: UUID, workspaceID: UUID) -> SceneCompositionTileKey {
    .init(workspaceID: workspaceID, revision: 0, plane: .board(boardID), tile: tile, range: .whole(.ink),
      presentationScale: 1, viewportWidth: 512, viewportHeight: 512, focusedItemID: nil, mode: "board")
  }

  private func contact(surface: SurfaceID, x: Double, actor: UUID, sequence: UInt64) -> SpatialInkAction {
    .init(tool: .pen, spans: [.init(surface: surface, samples: [0.0, 20].enumerated().map { offset, dx in
      .init(point: .init(x: x + dx, y: dx), worldPoint: .init(x: x + dx, y: dx), timeOffset: Double(offset),
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })], stamp: .init(counter: sequence, actor: actor))
  }
}
