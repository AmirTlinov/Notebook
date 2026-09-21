@testable import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class SceneCompositionSQLTests: XCTestCase {
  @MainActor
  func testBoardReturnReusesPixelsAcrossPresenceAndEntryCameraCommitsButNotContentEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let before = try store.loadIndex(), treeBefore = try store.loadBoard(items: before.items)
    var workspace = before, tree = treeBefore
    let child = UUID()
    XCTAssertNotNil(workspace.createBoard(title: "A", actor: actor, boardID: child))
    XCTAssertTrue(tree.createBoard(child, in: header.rootBoardID, near: .zero, actor: actor))
    for index in 0..<8 {
      XCTAssertTrue(tree.upsertElement(.init(id: "text-\(index)", surface: .board(child), kind: .nativeText,
        frame: .init(x: Double(index % 4) * 40, y: Double(index / 4) * 40, width: 32, height: 32),
        worldOrigin: .zero, source: "\(index)", stamp: workspace.stamp), in: child, expected: nil, actor: actor))
    }
    _ = try store.saveWorkspaceEdits(before: before, after: workspace, boardBefore: treeBefore, boardAfter: tree)
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    let home = SessionPresence(boardID: child, mode: .board,
      camera: .init(center: .init(x: 80, y: 40), scale: 1), viewport: .init(x: 320, y: 256))
    func prepare(_ presence: SessionPresence) async throws {
      try store.savePresence(presence)
      let current = try store.workspaceHeader()
      let hierarchy = try store.loadBoard(items: workspace.items)
      let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
      let oldPaint = coordinator.published?.paintID
      coordinator.prepare(source: .init(store: store, revision: current.cursor, workspaceID: current.workspaceID),
        presence: presence, frame: .init(index: index, presence: presence, portalCamera: hierarchy.portalCamera), pinned: [], displayScale: 1)
      let deadline = ContinuousClock.now + .seconds(5)
      while coordinator.published?.paintID == oldPaint, coordinator.failure == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertNotEqual(coordinator.published?.paintID, oldPaint)
      XCTAssertNil(coordinator.failure)
    }
    try await prepare(home)
    let ids = Set(try XCTUnwrap(coordinator.published).rasters.values.map(\.entryID))
    XCTAssertFalse(ids.isEmpty, "Eight text owners require at least one passive tile")
    // Keep only IDs, not an old cohort or lease: eviction must remain real.
    try await prepare(.init(boardID: header.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 20000, y: 20000), scale: 1), viewport: home.viewport))
    var moved = tree
    XCTAssertTrue(moved.updatePortalCamera(.init(center: .init(x: 80, y: 40), scale: 1.2), for: child, actor: actor))
    _ = try store.saveBoardEdits(before: tree, after: moved)
    let start = ContinuousClock.now
    try await prepare(home)
    XCTAssertEqual(Set(try XCTUnwrap(coordinator.published).rasters.values.map(\.entryID)), ids)
    let warm = start.duration(to: .now)
    var edited = moved
    let old = try XCTUnwrap(moved.board(child)?.elements.first { $0.id == "text-7" })
    var replacement = old
    XCTAssertTrue(replacement.update(source: "Changed content", actor: actor))
    XCTAssertTrue(edited.upsertElement(replacement, in: child, expected: old.stamp, actor: actor))
    _ = try store.saveBoardEdits(before: moved, after: edited)
    try await prepare(home)
    XCTAssertTrue(ids.isDisjoint(with: try XCTUnwrap(coordinator.published).rasters.values.map(\.entryID)), "Real content cannot reuse the old pixels")
    let proof = XCTAttachment(string: "SQL A→parent→A: reusedTiles=\(ids.count); warmPublication=\(warm)")
    proof.name = "sql-board-return"; proof.lifetime = .keepAlways; add(proof)
  }

  func testPassiveConnectionDemotionIncludesItsMovableEndpointsAcrossPainterRuns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var hierarchy = before
    _ = hierarchy.moveItem(workspace.selectedItemID, in: initial.rootBoardID, to: .init(x: 100_000, y: 100_000), actor: actor)
    let a = UUID().uuidString, b = "b", c = "c"
    let nodes = [a, b, c]
    for (index, id) in (nodes + ["ab", "bc", "ca"]).enumerated() {
      let connection: NotebookGraphicConnection? = index < 3 ? nil : .init(
        start: .init(point: .zero, binding: .init(elementID: nodes[index - 3].lowercased())),
        end: .init(point: .zero, binding: .init(elementID: nodes[(index - 2) % 3].lowercased())), bend: 20)
      let graphic = NotebookGraphic(shape: connection == nil ? .ellipse : .connector, label: id, connection: connection)
      let element = SpatialElement(id: id, surface: .board(initial.rootBoardID), kind: .graphic,
        frame: .init(x: Double(index % 3) * 100, y: 0, width: 60, height: 60),
        worldOrigin: .zero, source: "", graphic: graphic, stamp: .init(counter: 0, actor: actor))
      XCTAssertTrue(hierarchy.upsertElement(element, in: initial.rootBoardID, expected: nil, actor: actor))
      let barrier = SpatialElement(id: "barrier-\(index)", surface: .board(initial.rootBoardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 40, height: 40), worldOrigin: .init(x: 100_000, y: 100_000),
        source: "Not adjacent", stamp: .init(counter: 0, actor: actor))
      XCTAssertTrue(hierarchy.upsertElement(barrier, in: initial.rootBoardID, expected: nil, actor: actor))
    }
    _ = try store.saveBoardEdits(before: before, after: hierarchy)
    let header = try store.workspaceHeader()
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: initial.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 130, y: 30), scale: 1), viewport: .init(x: 400, y: 400))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: [], displayScale: 2, previous: nil)
    let edge = try XCTUnwrap(plan.presentedOwners.first { $0.id == .element("ab") })
    let endpoint = try XCTUnwrap(plan.presentedOwners.first { $0.id == .element(a) })
    XCTAssertEqual(plan.vectorRuns.count, 6)
    let reduced = try XCTUnwrap(plan.demoting(edge, presence: presence, frame: frame, displayScale: 2))
    let demoted = Set(plan.presentedOwners).subtracting(reduced.presentedOwners)
    XCTAssertEqual(Set(demoted.map(\.id)), [.element("ab"), .element(a), .element(b)])
    XCTAssertLessThan(reduced.reductionPotential, plan.reductionPotential)
    for owner in demoted {
      let entry = try XCTUnwrap(index.paintEntry(id: owner.id, boardID: initial.rootBoardID))
      XCTAssertEqual(reduced.bands.filter { $0.plane == owner.plane && $0.range.contains(entry) }.count, 1)
    }
    let pinned = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: [.element(a)], displayScale: 2, previous: nil)
    XCTAssertNil(try pinned.demoting(edge, presence: presence, frame: frame, displayScale: 2),
      "A node's pin also protects the live connection that must follow its draft")
    let nodeOnly = try XCTUnwrap(plan.demoting(endpoint, presence: presence, frame: frame, displayScale: 2))
    XCTAssertTrue(nodeOnly.allowsLive(.element("ab"), in: endpoint.plane),
      "A passive endpoint need not flatten its editable connection or the entire cyclic graph")
  }

  func testFragmentedNativeRunsCountOnlyPopulatedRasterBandsAndKeepManyNativePins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var hierarchy = before
    _ = hierarchy.moveItem(workspace.selectedItemID, in: initial.rootBoardID, to: .init(x: 100_000, y: 100_000), actor: actor)
    for index in 0..<40 {
      for isNative in [true, false] {
        let element = SpatialElement(id: "\(isNative ? "node" : "off-window")-\(index)", surface: .board(initial.rootBoardID),
          kind: isNative ? .graphic : .nativeText,
          frame: .init(x: Double(index % 8) * 50, y: Double(index / 8) * 50, width: 36, height: 36),
          worldOrigin: isNative ? .zero : .init(x: 100_000, y: 100_000), source: "",
          graphic: isNative ? .init(label: "\(index)") : nil, stamp: .init(counter: 0, actor: actor))
        XCTAssertTrue(hierarchy.upsertElement(element, in: initial.rootBoardID, expected: nil, actor: actor))
      }
    }
    _ = try store.saveBoardEdits(before: before, after: hierarchy)
    let header = try store.workspaceHeader()
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: initial.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 200, y: 150), scale: 1), viewport: .init(x: 600, y: 600))
    let pins = Set((0..<10).map { WorkspaceSpatialID.element("node-\($0)") })
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil }, pinned: pins)
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: pins, displayScale: 2, previous: nil)
    XCTAssertEqual(plan.vectorRuns.count, 40, "Off-window neighbours still split authored runs")
    XCTAssertTrue(plan.liveOwners.isEmpty, "Native pins are not physical program hosts")
    XCTAssertTrue(plan.tiles.isEmpty, "Empty painter ranges allocate no pixel buffers")
    XCTAssertLessThanOrEqual(plan.primitiveCount, SceneCompositionPlan.maximumPrimitives)
    for pin in pins { XCTAssertTrue(plan.allowsLive(pin, in: .board(initial.rootBoardID))) }
    for owner in plan.presentedOwners {
      XCTAssertEqual(plan.allowsLive(owner.id, in: owner.plane), plan.rank(id: owner.id, in: owner.plane) != nil)
      XCTAssertFalse(plan.allowsLive(owner.id, in: .board(UUID())))
    }
    XCTAssertFalse(plan.allowsLive(.element("absent"), in: .board(initial.rootBoardID)))
    let data = try await source.liveData(plan: plan, presence: presence, frame: frame)
    XCTAssertNotNil(data.referenceBasis)
  }

  func testNativeVectorRunsUseAuthoredAdjacencyWithoutSpendingLiveHostSlots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var hierarchy = before
    _ = hierarchy.moveItem(workspace.selectedItemID, in: initial.rootBoardID, to: .init(x: 100_000, y: 100_000), actor: actor)
    for index in 0..<30 {
      let element = SpatialElement(id: "node-\(index)", surface: .board(initial.rootBoardID), kind: .graphic,
        frame: .init(x: Double(index % 6) * 60, y: Double(index / 6) * 60, width: 48, height: 48),
        worldOrigin: .zero, source: "", graphic: .init(label: "\(index)"), stamp: .init(counter: 0, actor: actor))
      XCTAssertTrue(hierarchy.upsertElement(element, in: initial.rootBoardID, expected: nil, actor: actor))
      if index == 14 {
        let barrier = SpatialElement(id: "barrier", surface: .board(initial.rootBoardID), kind: .nativeText,
          frame: .init(x: 0, y: 0, width: 100, height: 30), worldOrigin: .zero, source: "Above 0–14, below 15–29",
          stamp: .init(counter: 0, actor: actor))
        XCTAssertTrue(hierarchy.upsertElement(barrier, in: initial.rootBoardID, expected: nil, actor: actor))
      }
    }
    _ = try store.saveBoardEdits(before: before, after: hierarchy)
    let header = try store.workspaceHeader()
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: initial.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 180, y: 150), scale: 1), viewport: .init(x: 600, y: 600))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: [.element("node-0")], displayScale: 2, previous: nil)
    XCTAssertEqual(plan.vectorRuns.map { $0.owners.count }, [15, 15])
    XCTAssertEqual(plan.liveOwners.map(\.id), [.element("barrier")])
    XCTAssertLessThanOrEqual(plan.primitiveCount, SceneCompositionPlan.maximumPrimitives)
    let plane = SceneCompositionPlane.board(initial.rootBoardID)
    for number in 0..<30 {
      let id = WorkspaceSpatialID.element("node-\(number)")
      let entry = try XCTUnwrap(index.paintEntry(id: id, boardID: initial.rootBoardID))
      XCTAssertTrue(plan.allowsLive(id, in: plane))
      XCTAssertFalse(plan.bands.contains { $0.plane == plane && $0.range.contains(entry) }, "No raster duplicate beneath a vector run")
    }
    XCTAssertLessThan(try XCTUnwrap(plan.rank(id: .element("node-0"), in: plane)), try XCTUnwrap(plan.rank(id: .element("barrier"), in: plane)))
    XCTAssertLessThan(try XCTUnwrap(plan.rank(id: .element("barrier"), in: plane)), try XCTUnwrap(plan.rank(id: .element("node-29"), in: plane)))
    let data = try await source.liveData(plan: plan, presence: presence, frame: frame)
    XCTAssertNotNil(data.referenceBasis, "Every vector retains addressed authorship in the shared pointing proof")
    let pinnedOwner = try XCTUnwrap(plan.vectorRuns.first?.owners.first)
    XCTAssertNil(try plan.demoting(pinnedOwner, presence: presence, frame: frame, displayScale: 2))
    let optional = try XCTUnwrap(plan.vectorRuns.last?.owners.first)
    let reduced = try XCTUnwrap(plan.demoting(optional, presence: presence, frame: frame, displayScale: 2))
    XCTAssertLessThan(reduced.reductionPotential, plan.reductionPotential)
    XCTAssertEqual(reduced.liveOwners, plan.liveOwners, "Native detail yields without replacing the program's host")
    XCTAssertEqual(reduced.protectedOwners, plan.protectedOwners)
    XCTAssertTrue(reduced.allowsLive(pinnedOwner.id, in: plane))
    let demotedEntry = try XCTUnwrap(index.paintEntry(id: optional.id, boardID: initial.rootBoardID))
    XCTAssertEqual(reduced.bands.filter { $0.plane == plane && $0.range.contains(demotedEntry) }.count, 1)
  }

  func testSQLTileBatchKeepsAddressedCoverageAndRejectsAnObsoleteCut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), original = try store.loadBoard(items: workspace.items)
    var hierarchy = original
    // A fixed body strictly inside one cell isolates addressed tile coverage
    // from native text's fitted height and conservative edge padding.
    let element = SpatialElement(id: "visible", surface: .board(initial.rootBoardID), kind: .graphic,
      frame: .init(x: -16, y: -16, width: 32, height: 32), worldOrigin: .zero, source: "",
      graphic: .init(shape: .rectangle),
      stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(element, in: initial.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveBoardEdits(before: original, after: hierarchy)
    let header = try store.workspaceHeader()
    let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    let origin = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let keys = try (-8..<8).flatMap { row in try (-8..<8).map { column in
      SceneCompositionTileKey(workspaceID: header.workspaceID, revision: header.cursor,
        plane: .board(initial.rootBoardID), tile: try XCTUnwrap(origin.offset(columns: column, rows: row)),
        range: .whole(.elements), presentationScale: 1, viewportWidth: 834, viewportHeight: 1194,
        focusedItemID: nil, mode: WorkspaceSemanticMode.board.rawValue)
    } }
    let start = ContinuousClock.now
    let populated = try await source.tilesRequiringPaint(keys)
    print("SQL tile batch: 256 cells, \(start.duration(to: .now))")
    let identity = try store.scenePaintRevision(target: .init(kind: .board, id: initial.rootBoardID))
    XCTAssertEqual(populated, keys.filter { $0.tile == origin }.map { $0.withContentRevision(identity) })
    let paint = try await source.readElementForPaint(element.id, boardID: initial.rootBoardID)
    XCTAssertEqual(paint?.element, try store.readSpatialElement(boardID: initial.rootBoardID, elementID: element.id))
    XCTAssertEqual(paint?.layout, try store.readGraphicResolution(target: .init(kind: .board, id: initial.rootBoardID), elementID: element.id).layout)
    XCTAssertEqual(paint?.erasures, [])
    var changed = hierarchy
    XCTAssertTrue(changed.moveItem(workspace.selectedItemID, in: initial.rootBoardID,
      to: .init(x: 1_024, y: 0), actor: actor))
    _ = try store.saveBoardEdits(before: hierarchy, after: changed)
    do {
      _ = try await source.tilesRequiringPaint(keys)
      XCTFail("A completed batch cannot certify a different durable cut")
    } catch NotebookStorageError.transactionConflict { }
    do {
      _ = try await source.readElementForPaint(element.id, boardID: initial.rootBoardID)
      XCTFail("A cached erasure/body dependency cannot admit a different durable cut")
    } catch NotebookStorageError.transactionConflict { }
  }

  @MainActor
  func testFocusedMaterialDoesNotAllocateItsInvisibleParentUnderPassivePressure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let actor = UUID(), store = NotebookStore(root: root)
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var workspace = try store.loadIndex(), hierarchy = try store.loadBoard(items: workspace.items)
    let child = try XCTUnwrap(workspace.createBoard(title: "Child", actor: actor))
    XCTAssertTrue(hierarchy.createBoard(child.id, in: initial.rootBoardID, near: .zero, actor: actor))
    let item = try XCTUnwrap(workspace.createDocument(title: "Visible paper", actor: actor))
    XCTAssertTrue(hierarchy.addItem(item.id, to: child.id, near: .zero, actor: actor))
    let document = DocumentDocument(id: item.id, actor: actor, paperSize: .a4,
      blocks: [.markdown(id: "text", source: "The actual opened paper")])
    try store.saveDocumentWorkspaceBundle(index: workspace, document: document,
      state: .init(id: item.id, actor: actor), board: hierarchy)
    var ink = try store.readSpatialInk(surfaces: [.board(initial.rootBoardID)])
    XCTAssertNotNil(ink.append(tool: .pen, spans: [.init(surface: .board(initial.rootBoardID), samples: [
      .init(point: .zero, worldPoint: .zero, timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], actor: actor))
    try store.saveSpatialInk(ink)
    let resources = SceneRenderResources(profile: .interactive)
    // Match the real refusal without constructing 127 MiB of unrelated data.
    // The current paper's input allocation still fits the unchanged total cap.
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 1_024 * 1_024, priority: .passive))
    defer { pressure.release() }
    let registry = SpatialInkSurfaceRegistry()
    // Use one physical owner for both focused-cover and opened-document phases.
    let composition = SceneCompositionTiles(resources: resources, surfaceRegistry: registry)
    addTeardownBlock { @MainActor in await composition.stop(); await registry.stopSceneInk() }
    for mode in [WorkspaceSemanticMode.cover, .document] {
      let presence = SessionPresence(boardID: child.id, mode: mode,
        camera: .init(scale: 0.5), viewport: .init(x: 834, y: 1194),
        focusedItemID: item.id, openProgress: mode == .document ? 1 : 0, selectedItemID: item.id)
      let state = try NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport)
      XCTAssertNotNil(state.hierarchy.board(initial.rootBoardID), "Navigation retains the parent's metadata")
      XCTAssertFalse(state.inkSurfaces.contains(.board(initial.rootBoardID)), "A metadata ancestor is not a visible ink surface")
      XCTAssertFalse(state.ink.actions.contains { $0.spans.contains { $0.surface == .board(initial.rootBoardID) } })
      let index = WorkspaceSceneIndex(workspace: state.workspace, hierarchy: state.hierarchy, paperSizes: state.paperSizes)
      let requested = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
      let source = SceneCompositionSource(store: store, revision: state.header.cursor, workspaceID: state.header.workspaceID)
      let frame = requested
      XCTAssertNil(frame.presences[initial.rootBoardID], "An invisible parent is not a prerequisite for opening a material")
      composition.prepare(source: source, presence: presence, frame: requested, pinned: [.item(item.id)], displayScale: 2)
      let deadline = ContinuousClock.now + .seconds(10)
      while composition.isPreparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertNil(composition.failure, "\(composition.budgetFailures)")
      let installed = try XCTUnwrap(composition.published)
      XCTAssertEqual(installed.plan.inkBoardIDs, [child.id])
      XCTAssertTrue(installed.plan.allowsLive(.item(item.id), in: .board(child.id)))
      XCTAssertFalse(installed.liveData.ink.actions.contains { $0.spans.contains { $0.surface == .board(initial.rootBoardID) } })
    }
    let returned = SessionPresence(boardID: initial.rootBoardID, mode: .board,
      camera: .init(scale: 0.5), viewport: .init(x: 834, y: 1194), selectedItemID: item.id)
    let parent = try NotebookSceneState.read(store: store, presence: returned, viewport: returned.viewport)
    XCTAssertTrue(parent.inkSurfaces.contains(.board(initial.rootBoardID)))
    XCTAssertEqual(parent.ink.actions.first { $0.id == ink.actions[0].id }, ink.actions[0],
      "Returning reads the same durable ink; excluding an invisible surface does not delete it")
  }

  @MainActor
  func testOpeningDistantChildPublishesItsVisibleProgramsFromTheAddressedWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let beforeWorkspace = try store.loadIndex(), beforeBoard = try store.loadBoard(items: store.loadIndex().items)
    var workspace = beforeWorkspace, hierarchy = beforeBoard
    let child = try XCTUnwrap(workspace.createBoard(title: "Physical acceptance", actor: actor))
    XCTAssertTrue(hierarchy.createBoard(child.id, in: initial.rootBoardID,
      near: .init(tileX: 4, tileY: 4, localX: 0, localY: 0), actor: actor))
    var elements = [
      SpatialElement(id: "physical-acceptance-heading", surface: .board(child.id), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 1120, height: 90), worldOrigin: .zero,
        source: "Four live programs", stamp: .init(counter: 0, actor: actor)),
      SpatialElement(id: "physical-acceptance-notes", surface: .board(child.id), kind: .markdown,
        frame: .init(x: 0, y: 1120, width: 1120, height: 210), worldOrigin: .zero,
        source: "One tap executes once", stamp: .init(counter: 0, actor: actor))
    ]
    for (index, label) in ["A", "B", "C", "D"].enumerated() {
      elements.append(.init(id: "physical-control-" + label, surface: .board(child.id), kind: .web,
        frame: .init(x: Double(index % 2) * 580, y: 120 + Double(index / 2) * 340,
          width: 540, height: 290), worldOrigin: .zero,
        source: label, html: "<button>Increment " + label + "</button>",
        stamp: .init(counter: 0, actor: actor)))
    }
    for index in 0..<2 {
      elements.append(.init(id: "physical-svg-\(index)", surface: .board(child.id), kind: .web,
        frame: .init(x: Double(index) * 580, y: 820, width: 540, height: 240), worldOrigin: .zero,
        source: "Passive drawing", html: "<svg xmlns='http://www.w3.org/2000/svg'><path d='M0 0L540 240'/></svg>",
        stamp: .init(counter: 0, actor: actor)))
    }
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: child.id, expected: nil, actor: actor))
    }
    _ = try store.saveWorkspaceEdits(before: beforeWorkspace, after: workspace, boardBefore: beforeBoard, boardAfter: hierarchy)
    let presence = SessionPresence(boardID: child.id, mode: .board,
      camera: .init(center: .init(x: 560, y: 665), scale: 0.594), viewport: .init(x: 834, y: 1194),
      selectedItemID: beforeWorkspace.selectedItemID, notebookPageID: beforeWorkspace.selectedPageID)
    let loaded = try NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport)
    let index = WorkspaceSceneIndex(workspace: loaded.workspace, hierarchy: loaded.hierarchy, paperSizes: loaded.paperSizes)
    let frame = WorkspaceSceneFrame(index: index, presence: loaded.presence, portalCamera: { loaded.hierarchy.portalCamera($0) })
    XCTAssertTrue(frame.workset(boardID: child.id).elements.contains { $0.id == "physical-control-A" })
    let source = SceneCompositionSource(store: store, revision: loaded.header.cursor, workspaceID: loaded.header.workspaceID)
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop(); try? FileManager.default.removeItem(at: root) }
    coordinator.prepare(source: source, presence: loaded.presence, frame: frame, pinned: [], displayScale: 2)
    try await waitForPublication(coordinator, revision: loaded.header.cursor)
    XCTAssertNil(coordinator.failure)
    let shown = try XCTUnwrap(coordinator.published)
    XCTAssertTrue(shown.frame.workset(boardID: child.id).elements.contains { $0.id == "physical-control-A" })
    XCTAssertEqual(shown.runtimeOwners, Set(["A", "B", "C", "D"].map {
      SceneSourceAddress(plane: .board(child.id), elementID: "physical-control-" + $0)
    }), "Passive labels and SVGs cannot replace a visible input program with a dead snapshot")
  }

  @MainActor
  func testSQLRenderKeepsTheSameCoverPixelsAtEveryWorldCorner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex()
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024)
    func render(at center: WorldPoint) async throws -> Data {
      let before = try store.loadBoard(items: workspace.items)
      var after = before
      XCTAssertTrue(after.moveItem(workspace.selectedItemID, in: header.rootBoardID, to: center, actor: actor))
      _ = try store.saveBoardEdits(before: before, after: after)
      let current = try store.workspaceHeader()
      let source = SceneCompositionSource(store: store, revision: current.cursor, workspaceID: current.workspaceID)
      let presence = SessionPresence(boardID: header.rootBoardID, mode: .board,
        camera: .init(center: center, scale: 0.3), viewport: .init(x: 320, y: 420))
      let rendered = try await SceneCompositionRenderer(source: source, resources: resources).render(presence: presence, scale: 1)
      let image = try XCTUnwrap(UIImage(data: rendered.png)?.cgImage)
      let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let attachment = XCTAttachment(data: rendered.png, uniformTypeIdentifier: "public.png")
      attachment.name = "world-cover-\(center.tileX)-\(center.tileY)"; attachment.lifetime = .keepAlways
      add(attachment)
      return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
    for x: Int64 in [-1, 1] { for y: Int64 in [-1, 1] {
      let localX = x < 0 ? 0 : WorldPoint.tileSize - 1
      let localY = y < 0 ? 0 : WorldPoint.tileSize - 1
      let expected = try await render(at: .init(tileX: 0, tileY: 0, localX: localX, localY: localY))
      let actual = try await render(at: .init(tileX: x * WorldPoint.maximumTileIndex,
        tileY: y * WorldPoint.maximumTileIndex, localX: localX, localY: localY))
      XCTAssertGreaterThan(Set(expected).count, 8, "The control must contain actual cover and grid pixels")
      XCTAssertEqual(actual, expected, "Translating the same physical cover cannot crop or shift its outside projection")
    } }
  }

  @MainActor
  func testColdSourcesFailLocallyWithoutRevokingReadyNeighboursOrTheirPublishedCut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // Six whole 1024-pixel sources exceed this passive pool. Each admission
    // failure belongs to that source; it cannot revoke a ready neighbour or
    // demand a global replacement of their already installed geometry.
    let passivePairAndScratch = (2 * 8 * 2 + 8) * 1024 * 1024
    let resources = SceneRenderResources(byteLimit: passivePairAndScratch, profile: .headless, maximumBackgroundWebSurfaces: 1)
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in
      await coordinator.stop()
      try? FileManager.default.removeItem(at: root)
    }
    let actor = UUID(), store = NotebookStore(root: root)
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex()
    let originalBoard = try store.loadBoard(items: workspace.items)
    var hierarchy = originalBoard
    XCTAssertTrue(hierarchy.moveItem(workspace.selectedItemID, in: initial.rootBoardID,
      to: .init(x: 1_000_000, y: 1_000_000), actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(.init(id: "baseline", surface: .board(initial.rootBoardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 64, height: 64), worldOrigin: .zero, source: "Old visible source",
      html: "<div style='position:absolute;inset:0;background:navy'></div>", stamp: .init(counter: 0, actor: actor)),
      in: initial.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveBoardEdits(before: originalBoard, after: hierarchy)
    hierarchy = try store.loadBoard(items: workspace.items)
    let presence = SessionPresence(boardID: initial.rootBoardID, mode: .board,
      camera: .init(scale: 1), viewport: .init(x: 256, y: 256))
    func source() throws -> SceneCompositionSource {
      let header = try store.workspaceHeader()
      return .init(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    }
    let oldIndex = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let oldSource = try source()
    coordinator.prepare(source: oldSource, presence: presence,
      frame: .init(index: oldIndex, presence: presence, portalCamera: { _ in nil }), pinned: [])
    try await waitForPublication(coordinator, revision: oldSource.revision)
    let readyDeadline = ContinuousClock.now + .seconds(5)
    let baselineAddress = SceneSourceAddress(plane: .board(initial.rootBoardID), elementID: "baseline")
    while coordinator.published?.sourceReceipts[baselineAddress]?.hasCurrentPixels != true,
      ContinuousClock.now < readyDeadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(coordinator.published?.sourceReceipts[baselineAddress]?.hasCurrentPixels == true)
    let old = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    let oldCost = resources.rasterAdmission.pinnedBytes
    XCTAssertGreaterThan(oldCost, 0)
    let before = hierarchy
    var elements: [SpatialElement] = []
    for offset in 0..<6 {
      let element = SpatialElement(id: String(format: "budget-%02d", offset), surface: .board(initial.rootBoardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 512, height: 512), worldOrigin: .init(x: -256, y: -256),
        source: "bounded raster \(offset)", html: "<div style='position:absolute;inset:0;background:rgb(\(offset * 30),80,120)'></div>",
        stamp: .init(counter: 0, actor: actor))
      XCTAssertTrue(hierarchy.upsertElement(element, in: initial.rootBoardID, expected: nil, actor: actor))
      elements.append(element)
    }
    _ = try store.saveBoardEdits(before: before, after: hierarchy)
    hierarchy = try store.loadBoard(items: workspace.items)
    let fresh = try source()
    let freshRevision = await fresh.revision
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let unboundedBytesPlan = try await SceneCompositionPlan.prepare(source: fresh, presence: presence,
      frame: frame, pinned: [], displayScale: 2, previous: old.plan)
    let tileBytes = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: 512, pixelHeight: 512))
    XCTAssertEqual(unboundedBytesPlan.liveOwners.count, 7)
    let renderer = SceneCompositionRenderer(source: fresh, resources: resources)
    let requests = try await renderer.liveRasterRequests(plan: unboundedBytesPlan, frame: frame, displayScale: 2)
    XCTAssertEqual(requests.count, 7)
    let liveCost = requests.reduce(0) { $0 + $1.residentBytes }
    XCTAssertGreaterThan(oldCost + unboundedBytesPlan.tiles.count * tileBytes + liveCost, resources.passiveByteLimit,
      "The actual whole old cut and all cold live sources cannot coexist under this byte limit")
    coordinator.prepare(source: fresh, presence: presence, frame: frame, pinned: [])
    let deadline = ContinuousClock.now + .seconds(20)
    while coordinator.isPreparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertFalse(coordinator.isPreparing)
    let current = try XCTUnwrap(coordinator.published, coordinator.failure ?? "Byte-aware candidate remains whole")
    XCTAssertEqual(current.plan.revision, freshRevision, coordinator.failure ?? "")
    XCTAssertNil(coordinator.failure)
    XCTAssertFalse(current === old)
    XCTAssertTrue(old.liveRasters.values.allSatisfy { !$0.isReleased })
    XCTAssertEqual(current.plan.liveOwners.count, unboundedBytesPlan.liveOwners.count)
    XCTAssertTrue(current.sourceReceipts[baselineAddress]?.hasCurrentPixels == true)
    XCTAssertTrue(current.sourceReceipts.values.contains { if case .failed = $0.status { return true }; return false },
      "The finite pool must produce a local failure instead of pretending every source is sharp")
    XCTAssertTrue(current.sourceReceipts.contains { $0.key != baselineAddress && $0.value.hasCurrentPixels },
      "The same pressure must still allow an independent new source to publish")
    for element in elements {
      let entry = try XCTUnwrap(index.paintEntry(id: .element(element.id), boardID: presence.boardID))
      let live = current.plan.allowsLive(entry.id, in: .board(presence.boardID)) ? 1 : 0
      let painted = current.plan.bands.filter { $0.plane == .board(presence.boardID) && $0.range.contains(entry) }.count
      XCTAssertEqual(live + painted, 1, "Every source is either a retained live raster or one exact static range, never absent")
    }
    XCTAssertEqual(current.rasters.count, current.plan.tiles.count)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)

    let pins = Set(elements.map { WorkspaceSpatialID.element($0.id) } + [.element("baseline")])
    let pinnedFrame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil }, pinned: pins)
    coordinator.prepare(source: fresh, presence: presence, frame: pinnedFrame, pinned: pins)
    let refusalDeadline = ContinuousClock.now + .seconds(5)
    while coordinator.isPreparing, ContinuousClock.now < refusalDeadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNil(coordinator.failure, "A source's refused capture does not invalidate the installed geometry")
    XCTAssertEqual(coordinator.published?.plan.liveOwners.count, current.plan.liveOwners.count)
    XCTAssertTrue(current.rasters.values.allSatisfy { !$0.isReleased })
    XCTAssertFalse(coordinator.isPreparing, "An impossible source is not retried forever without a capacity change")
    await coordinator.stop()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }



  @MainActor
  func testLivePayloadIsOneSQLRevisionAndExcludedHumanChangesCarryStaticPixels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let actor = UUID(), store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var workspace = try store.loadIndex()
    let notebookID = workspace.selectedItemID
    var hierarchy = try store.loadBoard(items: workspace.items)
    XCTAssertTrue(hierarchy.moveItem(notebookID, in: header.rootBoardID, to: .init(x: 1_000_000, y: 1_000_000), actor: actor))
    let documentID = try XCTUnwrap(workspace.createDocument(title: "Live document", actor: actor)?.id)
    XCTAssertTrue(hierarchy.addItem(documentID, to: header.rootBoardID, near: .zero, actor: actor))
    var document = DocumentDocument(id: documentID, actor: actor, blocks: [.markdown(id: "body", source: "Old body")])
    var state = DocumentStateJournal(id: documentID, actor: actor)
    try store.saveDocumentWorkspaceBundle(index: workspace, document: document, state: state, board: hierarchy)
    document = try store.loadDocument(documentID)
    state = try store.loadDocumentState(documentID)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [documentID: .a4])
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(scale: 0.3),
      viewport: .init(x: 512, y: 512), focusedItemID: documentID, selectedItemID: documentID)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil }, pinned: [.item(documentID)])
    func source() throws -> SceneCompositionSource {
      let current = try store.workspaceHeader()
      return .init(store: store, revision: current.cursor, workspaceID: current.workspaceID)
    }
    func plan(_ source: SceneCompositionSource) async throws -> SceneCompositionPlan {
      try await .prepare(source: source, presence: presence, frame: frame, pinned: [.item(documentID)], displayScale: 2, previous: nil)
    }
    let coverSample = SpatialInkSample(point: .zero, timeOffset: 0,
      width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    var initialInk = try store.loadSpatialInk()
    _ = initialInk.append(tool: .pen, spans: [.init(surface: .cover(notebookID), samples: [coverSample])], actor: actor)
    try store.saveSpatialInk(initialInk)
    let before = try source(), oldPlan = try await plan(before)
    let oldData = try await before.liveData(plan: oldPlan, presence: presence, frame: frame)
    XCTAssertTrue(oldData.documents.isEmpty, "A selected closed cover cannot load its document body")
    XCTAssertTrue(oldData.states.isEmpty, "Closed cover admission does not need program state")
    XCTAssertEqual(oldData.documentPaperSizes[documentID], .a4)
    XCTAssertTrue(oldData.pages.isEmpty)
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    coordinator.prepare(source: before, presence: presence, frame: frame, pinned: [.item(documentID)])
    try await waitForPublication(coordinator, revision: before.revision)
    let oldCohort = try XCTUnwrap(coordinator.published)
    let rasterGeneration = resources.rasterGeneration

    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "New body", actor: actor))
    XCTAssertTrue(state.commit(blockID: "body", value: .number(7), actor: actor))
    try store.saveDocument(document); try store.saveDocumentState(state)
    var journal = try store.loadSpatialInk()
    let sample = SpatialInkSample(point: .zero, worldPoint: .zero, timeOffset: 0,
      width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    _ = journal.append(tool: .pen, spans: [.init(surface: .board(header.rootBoardID), samples: [sample])], actor: actor)
    try store.saveSpatialInk(journal)
    let after = try source(), newPlan = try await plan(after)
    let newData = try await after.liveData(plan: newPlan, presence: presence, frame: frame)
    let carry = try await after.canCarryStaticPixels(from: oldPlan, liveData: oldData, to: newPlan, liveData: newData)
    XCTAssertTrue(carry, "A new Pencil action and live document state do not invalidate excluded background paint")
    XCTAssertTrue(oldData.documents.isEmpty)
    XCTAssertTrue(newData.documents.isEmpty, "A body edit cannot pull closed content into the board cohort")
    XCTAssertTrue(newData.states.isEmpty)
    let opened = SessionPresence(boardID: header.rootBoardID, mode: .document, camera: presence.camera,
      viewport: presence.viewport, focusedItemID: documentID, openProgress: 1, selectedItemID: documentID)
    let openedData = try await after.liveData(plan: newPlan, presence: opened, frame: frame,
      previous: (newPlan, newData))
    XCTAssertEqual(openedData.documents[documentID]?.blocks.first?.source, "New body")
    XCTAssertEqual(openedData.states[documentID]?.value(for: "body"), .number(7))
    XCTAssertEqual(newData.ink.actions.count, 1)
    XCTAssertEqual(openedData.ink, newData.ink)
    XCTAssertTrue(newData.ink.actions[0].spans[0].samples.storage === openedData.ink.actions[0].spans[0].samples.storage,
      "The same checked SQL cut keeps its actual relation body, not a freshly decoded equal copy")
    let expanded = SceneCompositionPlan(revision: newPlan.revision, workspaceID: newPlan.workspaceID,
      rootBoardID: newPlan.rootBoardID, inkBoardIDs: newPlan.inkBoardIDs,
      liveOwners: newPlan.liveOwners + [.init(plane: .board(header.rootBoardID), id: .item(notebookID),
        position: .init(layer: .covers, zIndex: 0, key: notebookID.uuidString))],
      protectedOwners: newPlan.protectedOwners, bands: newPlan.bands, coverage: newPlan.coverage,
      presentations: newPlan.presentations, tiles: newPlan.tiles)
    let expandedData = try await after.liveData(plan: expanded, presence: opened, frame: frame,
      previous: (newPlan, newData))
    XCTAssertEqual(expandedData.ink.actions.count, 2,
      "The same revision does not certify ink on a newly admitted surface")
    coordinator.prepare(source: after, presence: presence, frame: frame, pinned: [.item(documentID)])
    try await waitForPublication(coordinator, revision: after.revision)
    let newCohort = try XCTUnwrap(coordinator.published)
    XCTAssertFalse(oldCohort === newCohort, "New live values publish in a new coherent cohort")
    XCTAssertEqual(resources.rasterGeneration, rasterGeneration, "An excluded edit allocates no replacement tile")
    for (key, raster) in newCohort.rasters {
      XCTAssertTrue(oldCohort.rasters[key.atRevision(oldCohort.plan.revision)]?.image === raster.image,
        "The renderer carries the actual retained pixels, not just a cache counter")
    }
    do { try await before.validate(); XCTFail("An old SQL reader cannot publish a new mixed revision") }
    catch NotebookStorageError.transactionConflict { }

    _ = journal.append(tool: .eraser, spans: [
      .init(surface: .board(header.rootBoardID), samples: [sample]),
      .init(surface: .cover(notebookID), samples: [.init(point: .zero, timeOffset: 0,
        width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    ], actor: actor)
    try store.saveSpatialInk(journal)
    let crossSurface = try source(), crossPlan = try await plan(crossSurface)
    let crossData = try await crossSurface.liveData(plan: crossPlan, presence: presence, frame: frame,
      previous: (newPlan, newData))
    XCTAssertEqual(crossData.ink.actions.count, 2, "A new SQL revision reads the newly accepted contact")
    let crossesStatic = try await crossSurface.canCarryStaticPixels(from: newPlan, liveData: newData, to: crossPlan, liveData: crossData)
    XCTAssertFalse(crossesStatic, "A contact spanning a non-excluded physical owner invalidates its static pixels")
  }

  @MainActor
  private func waitForPublication(_ coordinator: SceneCompositionTiles, revision: UInt64) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while coordinator.published?.plan.revision != revision, coordinator.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(coordinator.published?.plan.revision, revision, coordinator.failure ?? "Whole cohort was not published")
  }

  func testStartupAndDiskRefreshLoadOnlyTheActuallyOpenedPaperContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let pageSize = PageSize(width: 834, height: 1194)
    let initial = try store.initializeWorkspace(actor: actor, pageSize: pageSize)
    var workspace = try store.loadIndex()
    let notebookID = workspace.selectedItemID, pageID = try XCTUnwrap(workspace.selectedPageID)
    var hierarchy = try store.loadBoard(items: workspace.items)
    let documentID = try XCTUnwrap(workspace.createDocument(title: "Closed content", actor: actor)?.id)
    XCTAssertTrue(hierarchy.addItem(documentID, to: initial.rootBoardID, near: .zero, actor: actor))
    let document = DocumentDocument(id: documentID, actor: actor,
      blocks: [.markdown(id: "body", source: String(repeating: "The unopened body. ", count: 1_000))])
    var state = DocumentStateJournal(id: documentID, actor: actor)
    XCTAssertTrue(state.commit(blockID: "body", value: .number(7), actor: actor))
    try store.saveDocumentWorkspaceBundle(index: workspace, document: document, state: state, board: hierarchy)
    let draft = DocumentEditingSession(edit: .init(sessionID: UUID(), documentID: documentID, blockID: "body",
      baseSource: document.blocks[0].source, baseVersion: document.sourceVersion(blockID: "body"), source: "Draft", sequence: 1))
    try store.saveDocumentDraft(draft)
    let viewport = SpatialPoint(x: 834, y: 1194)
    for selectedID in [documentID, notebookID] {
      let selectedPageID = selectedID == notebookID ? pageID : nil
      let closed = SessionPresence(boardID: initial.rootBoardID, mode: .board, camera: .init(scale: 0.3),
        viewport: viewport, selectedItemID: selectedID, notebookPageID: selectedPageID)
      try store.savePresence(closed)
      let started = try NotebookSceneState.start(store: store, actor: actor, pageSize: pageSize,
        notebookID: notebookID, pageID: pageID)
      let refreshed = try NotebookDiskRefresh.prepare(store: store, presence: closed, receivingDeviceID: nil).scene
      for snapshot in [started, refreshed] {
        XCTAssertEqual(snapshot.presence.mode, .board)
        XCTAssertEqual(snapshot.presence.selectedItemID, selectedID)
        XCTAssertTrue(snapshot.documents.isEmpty)
        XCTAssertTrue(snapshot.states.isEmpty)
        XCTAssertTrue(snapshot.drafts.isEmpty)
        XCTAssertTrue(snapshot.pages.isEmpty, "A closed notebook also reads its directory without page bodies")
        if selectedID == notebookID { XCTAssertTrue(snapshot.pagePositions.contains { $0.pageID == pageID }) }
        else { XCTAssertEqual(snapshot.paperSizes[documentID], document.paperSize) }
      }
      let opened = SessionPresence(boardID: initial.rootBoardID, mode: selectedID == notebookID ? .page : .document,
        camera: closed.camera, viewport: viewport, focusedItemID: selectedID, openProgress: 1,
        selectedItemID: selectedID, notebookPageID: selectedPageID)
      let openSnapshot = try NotebookDiskRefresh.prepare(store: store, presence: opened, receivingDeviceID: nil).scene
      if selectedID == notebookID { XCTAssertNotNil(openSnapshot.pages[pageID]) }
      else {
        XCTAssertEqual(openSnapshot.documents[documentID]?.blocks, document.blocks)
        XCTAssertEqual(openSnapshot.states[documentID]?.value(for: "body"), .number(7))
        XCTAssertEqual(openSnapshot.drafts.map(\.id), [draft.id])
      }
      let metadata = try NotebookSceneState.read(store: store, presence: opened, viewport: viewport, loadsLiveContent: false)
      XCTAssertTrue(metadata.pages.isEmpty); XCTAssertTrue(metadata.documents.isEmpty)
      XCTAssertTrue(metadata.states.isEmpty); XCTAssertTrue(metadata.drafts.isEmpty)
    }
  }
}
