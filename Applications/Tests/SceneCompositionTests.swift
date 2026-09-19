import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class SceneCompositionTests: XCTestCase {
  @MainActor
  func testStaticSourceStartsBeforeTheFirstCompositionTileCompletes() async throws {
    let fixture = Fixture(count: 8, side: 32,
      html: "<div style='background:red'>Pending</div><script>window.notebook.ready(new Promise(resolve => setTimeout(resolve,700)))</script>")
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    var sourceWasAlreadyRunning: Bool?
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { note in
      guard let key = note.object as? SceneCompositionTileKey, key.workspaceID == fixture.index.generationID else { return }
      MainActor.assumeIsolated {
        if sourceWasAlreadyRunning == nil { sourceWasAlreadyRunning = resources.activeBackgroundWebSurfaceCount > 0 }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: fixture.frame(), pinned: [], displayScale: 1)
    try await waitUntil { sourceWasAlreadyRunning != nil }
    XCTAssertEqual(sourceWasAlreadyRunning, true, "The first placeholder pass cannot be the prerequisite for starting source preparation")
    let address = SceneSourceAddress(plane: .board(fixture.presence.boardID), elementID: fixture.elements.last!.id)
    try await waitUntil { coordinator.published?.sourceReceipts[address]?.hasCurrentPixels == true }
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testVisibleSourcePrecedesAlphabeticallyEarlierOverscanNeighbour() async throws {
    let fixture = Fixture(count: 0), boardID = fixture.presence.boardID, stamp = fixture.workspace.stamp
    let elements: [SpatialElement] = [("a-neighbour", 220.0), ("z-visible", 0.0)].map { id, x in
      .init(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 32, height: 32), worldOrigin: .init(x: x, y: 0), source: id,
        html: "<svg viewBox='0 0 32 32'><rect width='32' height='32' fill='red'/></svg>", stamp: stamp)
    }
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: fixture.hierarchy.boards[0].board.freeItems,
        elements: elements, stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: hierarchy, paperSizes: [:])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: fixture.journal)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(scale: 1), viewport: .init(x: 320, y: 256))
    let resources = SceneRenderResources(maximumBackgroundWebSurfaces: 1), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    var completed: [String] = []
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { note in
      guard let id = note.object as? String, elements.contains(where: { $0.id == id }) else { return }
      MainActor.assumeIsolated { if !completed.contains(id) { completed.append(id) } }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    coordinator.prepare(source: source, presence: presence,
      frame: .init(index: index, presence: presence, portalCamera: { _ in nil }), pinned: [], displayScale: 1)
    try await waitUntil { completed.count == 2 }
    XCTAssertEqual(completed, ["z-visible", "a-neighbour"], "The single background executor serves missing visible pixels before overscan")
  }

  @MainActor
  func testWarmReturnReusesCompositionEntriesAndRevisionChangeDoesNot() async throws {
    let fixture = Fixture(count: 8, side: 32, kind: .nativeText)
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    func prepare(_ presence: SessionPresence, revision: UInt64 = 0) async throws {
      let paint = coordinator.published?.paintID
      coordinator.prepare(source: fixture.source(revision: revision), presence: presence,
        frame: .init(index: fixture.index, presence: presence, portalCamera: { _ in nil }), pinned: [], displayScale: 1)
      try await waitUntil { coordinator.published?.paintID != paint || coordinator.failure != nil }
      XCTAssertNil(coordinator.failure)
    }
    try await prepare(fixture.presence)
    let first = try XCTUnwrap(coordinator.published).rasters.mapValues(\.entryID)
    XCTAssertFalse(first.isEmpty)
    let away = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
      camera: .init(center: .init(x: 12_000, y: 0), scale: 1), viewport: fixture.presence.viewport)
    try await prepare(away)
    XCTAssertTrue(try XCTUnwrap(coordinator.published).rasters.isEmpty)
    let started = ContinuousClock.now
    try await prepare(fixture.presence)
    XCTAssertEqual(try XCTUnwrap(coordinator.published).rasters.mapValues(\.entryID), first,
      "A → B → A must borrow the original composition entries, not render identical new images")
    let warm = started.duration(to: .now)
    try await prepare(away)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - resources.passiveReservedBytes, priority: .passive))
    XCTAssertTrue(first.keys.allSatisfy { resources.image(for: .composition($0)) == nil })
    pressure.release()
    try await prepare(fixture.presence)
    XCTAssertTrue(Set(first.values).isDisjoint(with: try XCTUnwrap(coordinator.published).rasters.values.map(\.entryID)),
      "Real eviction permits a fresh render, not an unbounded retained cohort cache")
    try await prepare(away)
    try await prepare(fixture.presence, revision: 1)
    XCTAssertTrue(Set(first.values).isDisjoint(with: try XCTUnwrap(coordinator.published).rasters.values.map(\.entryID)))
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
    let report = XCTAttachment(string: "warmReturnToPublished=\(warm); reusedCompositionTiles=\(first.count); peakAccountedBytes=\(resources.peakAccountedBytes)")
    report.name = "warm-composition-return"; report.lifetime = .keepAlways; add(report)
  }

  @MainActor
  func testWarmStaticWebCompositionKeepsReadinessWithoutRetainingItsOldCohort() async throws {
    let fixture = Fixture(count: 8, side: 32,
      html: "<svg viewBox='0 0 32 32'><rect width='32' height='32' fill='red'/></svg>")
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    func prepare(_ presence: SessionPresence) async throws {
      let paint = coordinator.published?.paintID
      coordinator.prepare(source: fixture.source(), presence: presence,
        frame: .init(index: fixture.index, presence: presence, portalCamera: { _ in nil }), pinned: [], displayScale: 1)
      try await waitUntil { coordinator.published?.paintID != paint || coordinator.failure != nil }
      XCTAssertNil(coordinator.failure)
    }
    try await prepare(fixture.presence)
    // Eight sources share the bounded background queue. Wait for completion,
    // not a 3-second deadline intended for one scene publication.
    let deadline = ContinuousClock.now + .seconds(10)
    while coordinator.isPreparing, coordinator.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(coordinator.isPreparing)
    XCTAssertTrue(coordinator.published?.sourceReceipts.values.allSatisfy(\.hasCurrentPixels) == true)
    let first = try XCTUnwrap(coordinator.published).rasters.mapValues(\.entryID)
    weak let retired = coordinator.published
    XCTAssertFalse(first.isEmpty)
    let away = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
      camera: .init(center: .init(x: 12_000, y: 0), scale: 1), viewport: fixture.presence.viewport)
    try await prepare(away)
    try await waitUntil { retired == nil }
    try await prepare(fixture.presence)
    let returned = try XCTUnwrap(coordinator.published)
    XCTAssertEqual(returned.rasters.mapValues(\.entryID), first)
    XCTAssertTrue(returned.sourceReceipts.values.allSatisfy(\.hasCurrentPixels))
    XCTAssertTrue(returned.tileSources.values.contains { !$0.isEmpty })
  }

  @MainActor
  func testCompositionCacheNeverReusesPendingOrSupersededSourcePixels() throws {
    let fixture = Fixture(count: 1, side: 32)
    let resources = SceneRenderResources(byteLimit: 32 * 1024 * 1024, profile: .headless)
    let source = agentElementSnapshotSource(fixture.elements[0])
    let address = SceneSourceAddress(plane: .board(fixture.presence.boardID), elementID: source.id)
    let tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 4))
    let key = fixture.key(tile: tile, range: .whole(.elements))
    func store(_ source: SceneRasterSource) throws -> RasterLease {
      let image = bitmap(side: 32, scale: 1, color: .red)
      let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 32, pixelHeight: 32))
      return try XCTUnwrap(resources.storeAndRetain(image, for: source, reservation: reservation))
    }
    let sourcePixels = try store(.agent(source)), composed = try store(.composition(key))
    defer { sourcePixels.release(); composed.release() }
    let demand = SceneSourceDemand(source: source, minimumScale: 1)
    resources.cacheComposition(composed, receipts: [address: .init(demand: demand, installedSource: nil,
      installedScale: 0, status: .pending)], sources: [:])
    XCTAssertNil(resources.retainComposition(key, accepts: { _ in true }))
    let ready = SceneSourceReceipt(demand: demand, installedSource: source, installedScale: 1, status: .ready)
    resources.cacheComposition(composed, receipts: [address: ready], sources: [address: sourcePixels])
    let hit = try XCTUnwrap(resources.retainComposition(key, accepts: { $0[address]?.hasCurrentPixels == true }))
    XCTAssertEqual(hit.entryID, composed.entryID); hit.release()
    let newer = try store(.agent(source)); defer { newer.release() }
    XCTAssertNil(resources.retainComposition(key, accepts: { _ in true }), "Same-source newer live pixels invalidate dependent warm entries")
    resources.cacheComposition(composed, receipts: [address: ready], sources: [address: sourcePixels])
    XCTAssertNil(resources.retainComposition(key, accepts: { _ in true }), "An awaited old paint cannot undo that invalidation")
    XCTAssertFalse(composed.isReleased, "Invalidation does not revoke currently displayed pixels")
  }

  @MainActor
  func testFinalPopulatedGridAndWorldPixelKeysSurviveReversedPinch() async throws {
    let fixture = Fixture(count: 16, side: 32, kind: .nativeText)
    let source = fixture.source()
    var previous: SceneCompositionPlan?
    var warmed: Set<SceneCompositionTileKey>?
    for scale in [0.99, 1.01, 0.99, 1.01, 0.995, 1.005] {
      let view = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
        camera: .init(scale: scale), viewport: .init(x: 320, y: 256))
      let frame = WorkspaceSceneFrame(index: fixture.index, presence: view, portalCamera: { _ in nil })
      let plan = try await SceneCompositionPlan.prepare(source: source, presence: view, frame: frame,
        pinned: [], displayScale: 1, previous: previous)
      let keys = Set(plan.tiles.filter { $0.range.layer == .elements })
      XCTAssertFalse(keys.isEmpty)
      if let previous { XCTAssertEqual(plan.coverage[.board(view.boardID)]?.level, previous.coverage[.board(view.boardID)]?.level) }
      if let warmed { XCTAssertEqual(keys, warmed, "Subpixel zoom must not replace prepared world pixels") }
      if scale == 1.01 { warmed = keys }
      XCTAssertTrue(plan.meetsRequiredDensity)
      previous = plan
    }
    let world = try XCTUnwrap(warmed?.first)
    func key(_ layer: ScenePaintPosition.Layer, scale: Double) -> SceneCompositionTileKey {
      .init(workspaceID: world.workspaceID, revision: world.revision, plane: world.plane, tile: world.tile,
        range: .whole(layer), presentationScale: scale, viewportWidth: 320, viewportHeight: 256,
        focusedItemID: nil, mode: "board")
    }
    XCTAssertEqual(key(.elements, scale: 1), key(.elements, scale: 1.01))
    XCTAssertNotEqual(key(.covers, scale: 1), key(.covers, scale: 1.01), "Portal content still depends on camera projection")
    XCTAssertNotEqual(world, world.atRevision(world.revision + 1))
  }

  @MainActor
  func testWholeSourcePixelsAlsoRequireZoomDensityDuringContact() throws {
    let fixture = Fixture(count: 1, side: 200)
    let element = agentElementSnapshotSource(try XCTUnwrap(fixture.elements.first))
    let receipt = SceneSourceReceipt(demand: .init(source: element, minimumScale: 1, worldOrigin: .zero),
      installedSource: element, installedScale: 1, status: .ready)
    XCTAssertTrue(receipt.coversVisibleWindow(in: fixture.presence, pixelDensity: 1, refinesDetails: true))
    XCTAssertFalse(receipt.coversVisibleWindow(in: fixture.presence, pixelDensity: 2, refinesDetails: false),
      "A full image is spatial coverage, not an unlimited-density zoom texture")
    let sharp = SceneSourceReceipt(demand: receipt.demand, installedSource: element, installedScale: 2, status: .ready)
    XCTAssertTrue(sharp.coversVisibleWindow(in: fixture.presence, pixelDensity: 2, refinesDetails: true),
      "Reuse the actual sharper pixels, not merely the original request's lower minimum")
  }

  @MainActor
  func testCroppedSourceSeparatesCoverageFromGestureDensity() throws {
    let fixture = Fixture(count: 1, side: 5000)
    let element = try XCTUnwrap(fixture.hierarchy.boards[0].board.elements.first)
    let source = agentElementSnapshotSource(element)
    let receipt = SceneSourceReceipt(demand: .init(source: source, minimumScale: 1,
      region: .init(x: 0, y: 0, width: 512, height: 512), worldOrigin: .zero),
      installedSource: source, installedScale: 1, status: .ready,
      installedRegion: .init(x: 0, y: 0, width: 512, height: 512))
    let view = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
      camera: .init(center: .init(x: 256, y: 256), scale: 1.01), viewport: .init(x: 320, y: 256))
    XCTAssertTrue(receipt.coversVisibleWindow(in: view, pixelDensity: 1.01, refinesDetails: false))
    XCTAssertFalse(receipt.coversVisibleWindow(in: view, pixelDensity: 1.01, refinesDetails: true))
    let outside = SessionPresence(boardID: view.boardID, mode: .board,
      camera: .init(center: .init(x: 800, y: 256), scale: 1), viewport: view.viewport)
    XCTAssertFalse(receipt.coversVisibleWindow(in: outside, pixelDensity: 1, refinesDetails: false))
  }

  @MainActor
  func testAnInstalledProgramCannotBeDemotedByANewNeighbourAndDeletionStillRetiresIt() async throws {
    let fixture = Fixture(count: 0), boardID = fixture.presence.boardID, stamp = fixture.workspace.stamp
    let program = SpatialElement(id: "z-running", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 96, height: 96), worldOrigin: .zero,
      source: "An unsaved field", html: "<input value='Keep my draft'>", stamp: stamp)
    let neighbours = (0..<6).map { offset in
      SpatialElement(id: "b-neighbour-\(offset)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 32, height: 32), worldOrigin: .zero, source: "\(offset)", stamp: stamp)
    }
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 48, y: 48), scale: 1), viewport: .init(x: 320, y: 256))
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    func prepare(_ elements: [SpatialElement], counter: UInt64) {
      let revision = VersionStamp(counter: counter, actor: stamp.actor)
      let hierarchy = BoardHierarchy(rootBoardID: boardID,
        boards: [.init(id: boardID, board: .init(freeItems: fixture.hierarchy.boards[0].board.freeItems,
          elements: elements, stamp: revision))], stamp: revision)
      let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: hierarchy, paperSizes: [:])
      let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: fixture.journal)
      coordinator.prepare(source: source, presence: presence,
        frame: .init(index: index, presence: presence, portalCamera: { _ in nil }), pinned: [])
    }
    prepare(neighbours + [program], counter: 1)
    try await waitUntil { coordinator.published != nil }
    let old = try XCTUnwrap(coordinator.published)
    let reference = InteractiveElementReference.board(boardID: boardID, elementID: program.id)
    let lease = try await resources.acquireWebSurface(priority: .liveProgram, source: reference)
    defer { lease.release() }
    let address = try XCTUnwrap(coordinator.registerRuntimeSource(focus: reference,
      source: agentElementSnapshotSource(program), policy: .exact(scale: 2), leaseID: lease.id, cohort: old))
    XCTAssertNil(old.sourceRasters[address], "The live program has no static replacement yet")
    let added = SpatialElement(id: "a-new", surface: .board(boardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 32, height: 32), worldOrigin: .zero, source: "New", stamp: stamp)
    prepare([added] + neighbours + [program], counter: 2)
    try await waitUntil { coordinator.published?.id != old.id || coordinator.failure != nil }
    let current = try XCTUnwrap(coordinator.published)
    XCTAssertNil(coordinator.failure)
    XCTAssertTrue(current.plan.allowsLive(.element(program.id), in: .board(boardID)),
      "A neighbour cannot replace an installed program with a pending static producer")
    XCTAssertTrue(current.runtimeOwners.contains(address))
    XCTAssertEqual(resources.webActivity(for: reference).activeLeaseCount, 1)
    prepare([added] + neighbours, counter: 3)
    try await waitUntil { coordinator.published?.id != current.id || coordinator.failure != nil }
    XCTAssertNil(coordinator.failure)
    XCTAssertFalse(coordinator.published?.plan.allowsLive(.element(program.id), in: .board(boardID)) == true,
      "Protecting the installed representation never resurrects a deleted source")
  }

  @MainActor
  func testStaticSVGPublishesWithoutRetainingAProgramExecutor() async throws {
    let fixture = Fixture(count: 0), stamp = fixture.workspace.stamp, boardID = fixture.presence.boardID
    let element = SpatialElement(id: "static-svg", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 96, height: 96), worldOrigin: .zero, source: "Static drawing",
      html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 96 96'><rect width='96' height='96' fill='red'/></svg>", stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: fixture.hierarchy.boards[0].board.freeItems,
        elements: [element], stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: hierarchy, paperSizes: [:])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: fixture.journal)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 48, y: 48), scale: 1), viewport: .init(x: 320, y: 256))
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    coordinator.prepare(source: source, presence: presence,
      frame: .init(index: index, presence: presence, portalCamera: { _ in nil }), pinned: [])
    let address = SceneSourceAddress(plane: .board(boardID), elementID: element.id)
    try await waitUntil { coordinator.published?.sourceReceipts[address]?.hasCurrentPixels == true }
    XCTAssertFalse(try XCTUnwrap(coordinator.published).runtimeOwners.contains(address))
    try await waitUntil { resources.activeWebSurfaceCount == 0 }
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testPendingSourceBecomesReadyWhileCameraDensityContinuesChanging() async throws {
    let fixture = Fixture(count: 0), stamp = fixture.workspace.stamp, boardID = fixture.presence.boardID
    var elements = (0..<7).map { index in
      SpatialElement(id: "a-camera-pin-\(index)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 32, height: 64), worldOrigin: .zero, source: "\(index)", stamp: stamp)
    }
    let delayed = SpatialElement(id: "z-camera-pending", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 96, height: 96), worldOrigin: .zero,
      source: "A single delayed render", html: "<div style='position:absolute;inset:0;background:red'></div><script>window.notebook.ready(new Promise(resolve => setTimeout(resolve,1300)))</script>", stamp: stamp)
    elements.append(delayed)
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: fixture.hierarchy.boards[0].board.freeItems,
        elements: elements, stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: hierarchy, paperSizes: [:])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: fixture.journal)
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    let address = SceneSourceAddress(plane: .board(boardID), elementID: delayed.id)
    let pins = Set(elements.prefix(7).map { WorkspaceSpatialID.element($0.id) })
    var readyDuringMotion = false
    for step in 0..<40 {
      let presence = SessionPresence(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: 64 + Double(step % 3), y: 64), scale: 0.6 + Double(step % 9) / 20),
        viewport: .init(x: 320, y: 256))
      coordinator.prepare(source: source, presence: presence,
        frame: .init(index: index, presence: presence, portalCamera: { _ in nil }, pinned: pins), pinned: pins,
        displayScale: 2, refinesDetails: false)
      try await Task.sleep(for: .milliseconds(80))
      if coordinator.published?.sourceReceipts[address]?.hasCurrentPixels == true { readyDuringMotion = true }
    }
    XCTAssertTrue(readyDuringMotion, "A 1.3-second source must complete during uninterrupted camera changes")
    XCTAssertLessThanOrEqual(resources.activeWebSurfaceCount, 6)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testAReadySourcePublishesWhileItsSharedBandNeighbourIsStillLoading() async throws {
    let fixture = Fixture(count: 0), stamp = fixture.workspace.stamp
    let boardID = fixture.presence.boardID
    var elements = (0..<7).map { offset in
      SpatialElement(id: "a-\(offset)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 32, height: 32), worldOrigin: .zero, source: "\(offset)", stamp: stamp)
    }
    elements += [
      .init(id: "z-slow", surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 96, height: 96), worldOrigin: .zero,
        source: "Delayed neighbour", html: "<script>window.notebook.ready(new Promise(resolve => setTimeout(resolve, 5000)))</script><div style='position:absolute;inset:0;background:blue'></div>", stamp: stamp),
      .init(id: "z-healthy", surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 96, height: 96), worldOrigin: .init(x: 64, y: 0),
        source: "Ready neighbour", html: "<div style='position:absolute;inset:0;background:red'></div>", stamp: stamp)
    ]
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: fixture.hierarchy.boards[0].board.freeItems,
        elements: elements, stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: hierarchy, paperSizes: [:])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: fixture.journal)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 128, y: 64), scale: 1), viewport: .init(x: 320, y: 256))
    let resources = SceneRenderResources(), coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    // Keep both Web sources in the same static band rather than relying on
    // native labels winning the live-owner ordering over interactive programs.
    let pins = Set(elements.prefix(7).map { WorkspaceSpatialID.element($0.id) })
    coordinator.prepare(source: source, presence: presence,
      frame: .init(index: index, presence: presence, portalCamera: { _ in nil }, pinned: pins), pinned: pins)
    let healthy = SceneSourceAddress(plane: .board(boardID), elementID: "z-healthy")
    let slow = SceneSourceAddress(plane: .board(boardID), elementID: "z-slow")
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(), layers: [ScenePaintPosition.Layer] = [.elements, .covers]
    let controllers = layers.map { _ in SceneCameraPlaneController<UUID>() }
    window.frame = .init(x: 0, y: 0, width: presence.viewport.x, height: presence.viewport.y)
    window.rootViewController = host; window.makeKeyAndVisible()
    for controller in controllers {
      host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
      controller.view.frame = window.bounds
    }
    defer {
      controllers.forEach { $0.uninstall() }
      window.isHidden = true; window.rootViewController = nil
    }
    var readyAt: ContinuousClock.Instant?
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { note in
      guard (note.object as? String) == healthy.elementID else { return }
      MainActor.assumeIsolated { if readyAt == nil { readyAt = .now } }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let deadline = ContinuousClock.now + .seconds(3)
    var shown: UUID?, publicationAt: ContinuousClock.Instant?, mainPublications: [Duration] = []
    while ContinuousClock.now < deadline {
      if let cohort = coordinator.published, cohort.paintID != shown {
        let began = ContinuousClock.now
        for (layer, controller) in zip(layers, controllers) {
          controller.update(presence: presence, revision: cohort.paintID, reanchorsOnRevision: false,
            installation: cohort.installation(for: layer)) { anchor, _ in
              AnyView(ZStack {
                ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(boardID), layer: layer, presence: anchor)) { band in
                  band.zIndex(Double(band.rank))
                }
              }.frame(width: anchor.viewport.x, height: anchor.viewport.y))
            }
        }
        mainPublications.append(began.duration(to: .now)); shown = cohort.paintID
        if cohort.sourceReceipts[healthy]?.hasCurrentPixels == true { publicationAt = began }
      }
      if coordinator.published?.hasInstalledPixels(for: healthy) == true { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(coordinator.published?.hasInstalledPixels(for: healthy) == true)
    let installedAt = ContinuousClock.now, capturedAt = try XCTUnwrap(readyAt)
    let report = XCTAttachment(string: "healthyReadyToPublished=\(capturedAt.duration(to: try XCTUnwrap(publicationAt))); healthyReadyToNativeInstalled=\(capturedAt.duration(to: installedAt)); synchronousPlanePublications=\(mainPublications); slowNeighbourStillPending=\(coordinator.published?.sourceReceipts[slow]?.hasCurrentPixels != true); peakAccountedBytes=\(resources.peakAccountedBytes)")
    report.name = "ready-to-native-install-barrier"; report.lifetime = .keepAlways; add(report)
    let first = try XCTUnwrap(coordinator.published)
    XCTAssertFalse(first.sourceReceipts[slow]?.hasCurrentPixels == true,
      "The ready source publishes before its neighbour's five-second readiness promise")
    XCTAssertTrue(first.tileSources.values.contains { $0.contains(healthy) && $0.contains(slow) },
      "This must exercise two sources sharing one painter tile, not merely separate live layers")
    XCTAssertTrue(first.tileSources.filter { $0.value.contains(healthy) }.keys.allSatisfy { first.rasters[$0] != nil })
    XCTAssertEqual(first.sourceReceipts[healthy]?.status, .ready)
    let point = WorldPoint(x: 140, y: 48)
    let key = try XCTUnwrap(first.tileSources.first { key, sources in
      sources.contains(healthy) && key.tile.bounds.contains(.init(origin: point, width: 0.01, height: 0.01))
    }?.key)
    let image = try XCTUnwrap(first.rasters[key]?.image.cgImage)
    let data = try pixels(image), local = key.tile.origin.delta(to: point)
    let x = min(image.width - 1, Int(local.x / key.tile.worldSize * Double(image.width)))
    let y = min(image.height - 1, Int(local.y / key.tile.worldSize * Double(image.height)))
    let pixel = (y * image.width + x) * 4
    XCTAssertGreaterThan(data[pixel], 240); XCTAssertLessThan(data[pixel + 1], 15)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

  @MainActor
  func testSparseThreePaperAndTwoProgramSceneAllocatesFineOccupiedCellsBeforeThePhysicalQuota() async throws {
    let stamp = VersionStamp(counter: 0, actor: UUID())
    let papers = (0..<3).map { WorkspaceItem.notebook(title: "Paper \($0)", pageIDs: [UUID()]) }
    let workspace = WorkspaceIndex(items: papers, selectedItemID: papers[0].id,
      selectedPageID: papers[0].pageIDs[0], stamp: stamp)
    let boardID = workspace.rootBoardID
    var elements = (0..<6).map { index in
      SpatialElement(id: "1-filler-\(index)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 100, height: 60),
        worldOrigin: .init(x: -450 + Double(index) * 150, y: -380), source: "\(index)", stamp: stamp)
    }
    for (id, x) in [("0-control", 100.0), ("z-vector", -300.0)] {
      elements.append(.init(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 200, height: 180), worldOrigin: .init(x: x, y: -150),
        source: id, html: "<svg viewBox='0 0 200 180'><path d='M20 20L180 160' stroke='red'/></svg>", stamp: stamp))
    }
    let board = BoardDocument(freeItems: papers.enumerated().map { index, item in
      .init(itemID: item.id, center: .init(x: Double(index - 1) * 1100, y: 1350), zIndex: index, stamp: stamp)
    }, elements: elements, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    for zoom in [0.37, 0.4916067, 0.56, 0.7] {
      let presence = SessionPresence(boardID: boardID, mode: .board,
        camera: .init(center: .zero, scale: zoom), viewport: .init(x: 820, y: 1180))
      let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
      let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
        pinned: [], displayScale: 2, previous: nil)
      XCTAssertEqual(plan.liveOwners.count, 7)
      XCTAssertFalse(plan.allowsLive(.element("z-vector"), in: .board(boardID)))
      for item in frame.workset(boardID: boardID).items {
        let rect = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
        if rect.x < presence.viewport.x, rect.y < presence.viewport.y, rect.x + rect.width > 0, rect.y + rect.height > 0 {
          XCTAssertTrue(plan.allowsLive(.item(item.id), in: .board(boardID)),
            "Passive labels cannot evict visible paper into camera-dependent tiles")
        }
      }
      XCTAssertTrue(plan.meetsRequiredDensity)
      XCTAssertLessThanOrEqual(plan.tiles.count, SceneCompositionPlan.maximumTiles)
      let largest = (plan.tiles.map(\.pixelSize).max() ?? 0) + 2
      let resident = try plan.tiles.reduce(0) { total, tile in
        total + (try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: tile.pixelSize, pixelHeight: tile.pixelSize)))
      }
      let scratch = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: largest, pixelHeight: largest))
      XCTAssertLessThan(resident + scratch, 64 * 1024 * 1024,
        "Small occupied sources must fit alongside their shown predecessor, not demand 150–206 MiB of empty cells")
    }
  }

  @MainActor
  func testEmptyBandsDoNotLowerActualVisibleTileDensity() async throws {
    let fixture = Fixture(count: 9, side: 1280, kind: .nativeText)
    let presence = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
      camera: .init(center: .init(x: 640, y: 640), scale: 0.3313472587), viewport: .init(x: 834, y: 1194))
    let plan = try await SceneCompositionPlan.prepare(source: fixture.source(), presence: presence,
      frame: .init(index: fixture.index, presence: presence, portalCamera: { _ in nil }),
      pinned: [], displayScale: 2, previous: nil)
    XCTAssertGreaterThan(plan.bands.count, 3)
    XCTAssertFalse(plan.tiles.isEmpty)
    XCTAssertTrue(plan.meetsRequiredDensity)
    XCTAssertLessThanOrEqual(plan.tiles.count, SceneCompositionPlan.maximumTiles)
    for tile in plan.tiles {
      XCTAssertGreaterThanOrEqual(Double(tile.pixelSize) / tile.tile.worldSize / presence.camera.scale, 2)
    }
  }

  @MainActor
  func testReleasedPressureRefinesTheStationaryCameraWithoutAnotherPrepareCall() async throws {
    let fixture = Fixture(count: 9, side: 1280, kind: .nativeText)
    let presence = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
      camera: .init(center: .init(x: 640, y: 640), scale: 0.3313472587), viewport: .init(x: 834, y: 1194))
    let resources = SceneRenderResources()
    // Leave 8 MiB in the actual passive pool: enough for a coarse occupied
    // fragment, below this fixture's fine grid and its composition scratch.
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 8 * 1024 * 1024,
      priority: .passive))
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in pressure.release(); await coordinator.stop() }
    coordinator.prepare(source: fixture.source(), presence: presence,
      frame: .init(index: fixture.index, presence: presence, portalCamera: { _ in nil }), pinned: [], displayScale: 2)
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    let coarse = try XCTUnwrap(coordinator.published, coordinator.failure ?? "No pressure fallback")
    XCTAssertTrue(coordinator.hasQualityDebt, "The fixture must first display a genuinely coarser admitted lattice")
    XCTAssertFalse(coarse.plan.meetsRequiredDensity)
    pressure.release()
    try await waitUntil { coordinator.published?.plan.meetsRequiredDensity == true }
    let refined = try XCTUnwrap(coordinator.published)
    XCTAssertNotEqual(refined.paintID, coarse.paintID)
    XCTAssertEqual(refined.plan.presentations[.board(presence.boardID)]?.camera, presence.camera)
    XCTAssertFalse(coordinator.hasQualityDebt)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
  }

  @MainActor
  func testTableKeepsScreenDensityBesideTwoNativePaperCovers() async throws {
    let stamp = VersionStamp(counter: 0, actor: UUID())
    let notebook = WorkspaceItem.notebook(title: "Notebook", pageIDs: [UUID()])
    let document = WorkspaceItem.document(title: "Document")
    let workspace = WorkspaceIndex(items: [notebook, document], selectedItemID: notebook.id,
      selectedPageID: notebook.pageIDs[0], stamp: stamp)
    let table = SpatialElement(id: "table", surface: .board(workspace.rootBoardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 1280, height: 1120), worldOrigin: .init(x: 700, y: 0),
      source: "Table", html: "<svg viewBox='0 0 1280 1120'><rect width='1280' height='1120' fill='white'/><text x='30' y='100' font-size='40'>A clear table</text></svg>",
      css: "html,body,svg{margin:0;width:100%;height:100%}", stamp: stamp)
    let board = BoardDocument(freeItems: [
      .init(itemID: notebook.id, center: .init(x: -1300, y: 0), zIndex: 0, stamp: stamp),
      .init(itemID: document.id, center: .zero, zIndex: 1, stamp: stamp)
    ], elements: [table], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [document.id: .a4])
    let resources = SceneRenderResources(profile: .headless), registry = SpatialInkSurfaceRegistry()
    let tiles = SceneCompositionTiles(resources: resources, surfaceRegistry: registry)
    addTeardownBlock { @MainActor in await tiles.stop(); await registry.stopSceneInk() }
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    for zoom in [0.1254612818717936, 0.3009028410296117] {
      let old = tiles.published
      let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
        camera: .init(center: .init(x: 600, y: 200), scale: zoom), viewport: .init(x: 834, y: 1194))
      let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
      tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
      let deadline = ContinuousClock.now + .seconds(10)
      let address = SceneSourceAddress(plane: .board(workspace.rootBoardID), elementID: table.id)
      while (tiles.published === old || tiles.published?.sourceReceipts[address]?.hasCurrentPixels != true),
        tiles.failure == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let next = try XCTUnwrap(tiles.published, tiles.failure ?? "No prepared scene")
      XCTAssertFalse(next === old)
      for item in [notebook, document] {
        XCTAssertTrue(next.plan.allowsLive(.item(item.id), in: .board(workspace.rootBoardID)))
        XCTAssertNotNil(next.nativeInk.owners[.cover(item.id)], "Paper keeps its native input owner")
      }
      let raster = try XCTUnwrap(next.liveRasters.first { $0.key.id == .element(table.id) }?.value,
        "A small on-screen table must not collapse to a 26-pixel overview tile: \(tiles.budgetFailures)")
      let expectedWidth = floor(table.frame.width * zoom * 2)
      XCTAssertGreaterThanOrEqual(Double(try XCTUnwrap(raster.image.cgImage).width), expectedWidth)
      XCTAssertLessThan(raster.pixelScale, 1, "Off-screen canonical density cannot evict visible material")
      XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
    }
  }

  @MainActor
  func testMixedPaperCoversPublishInLandscapeWithoutDroppingTheirInputOwners() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let notebook = WorkspaceItem.notebook(title: "Notebook", pageIDs: [UUID()])
    let document = WorkspaceItem.document(title: "A4 document")
    let workspace = WorkspaceIndex(items: [notebook, document], selectedItemID: document.id,
      selectedPageID: nil, stamp: stamp)
    let board = BoardDocument(freeItems: [
      .init(itemID: notebook.id, center: .zero, zIndex: 0, stamp: stamp),
      .init(itemID: document.id, center: .init(x: 1016, y: 792), zIndex: 1, stamp: stamp)
    ], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [document.id: .a4])
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 640, y: -1890), scale: 0.1425), viewport: .init(x: 1194, y: 834))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    var journal = SpatialInkJournal(stamp: stamp)
    for surface in [SurfaceID.board(workspace.rootBoardID), .cover(notebook.id), .cover(document.id)] {
      XCTAssertNotNil(journal.append(tool: .pen, spans: [.init(surface: surface, samples: [100.0, 200].enumerated().map { index, x in
        .init(point: .init(x: x, y: 100), worldPoint: surface.kind == .board ? .init(x: x, y: 100) : nil, timeOffset: Double(index) / 10,
          width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor))
    }
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: journal)
    let resources = SceneRenderResources(profile: .headless), registry = SpatialInkSurfaceRegistry()
    let tiles = SceneCompositionTiles(resources: resources, surfaceRegistry: registry)
    addTeardownBlock { @MainActor in await tiles.stop(); await registry.stopSceneInk() }
    tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
    let deadline = ContinuousClock.now + .seconds(10)
    while tiles.published == nil, tiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let cohort = try XCTUnwrap(tiles.published, tiles.failure ?? "The mixed paper scene must publish: \(tiles.budgetFailures)")
    XCTAssertTrue(cohort.rasters.isEmpty, "Empty painter ranges must not consume the space needed by real paper ink")
    for item in [notebook, document] {
      XCTAssertTrue(cohort.plan.allowsLive(.item(item.id), in: .board(presence.boardID)))
      let owner = try XCTUnwrap(cohort.nativeInk.owners[.cover(item.id)])
      XCTAssertEqual(owner.canvas.contentScaleFactor, 2)
      XCTAssertGreaterThan(owner.canvas.spatialDrawableAccountedBytes, 0, "Already drawn ink must own real backing")
      XCTAssertTrue(owner.canvas.isStableFramePresented)
    }
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, 256 * 1024 * 1024)
  }

  @MainActor
  func testEmptyTileProofKeepsCoverageAndUnknownPagesKeepTheirPainter() async throws {
    let empty = Fixture(count: 0)
    let original = try await SceneCompositionPlan.prepare(source: empty.source(), presence: empty.presence,
      frame: empty.frame(), pinned: [], displayScale: 2, previous: nil)
    XCTAssertTrue(original.tiles.isEmpty, "Empty-range proof precedes the density allocation")
    let sparse = try await original.removingEmptyTiles(source: empty.source())
    XCTAssertTrue(sparse.tiles.isEmpty)
    XCTAssertEqual(sparse.coverage, original.coverage)
    XCTAssertEqual(sparse.bands.map(\.id), original.bands.map(\.id))
    XCTAssertEqual(sparse.reductionPotential, original.reductionPotential,
      "Empty pixels cannot spend or reset the geometric retry bound")
    do {
      _ = try await original.removingEmptyTiles(source: empty.source(revision: 1))
      XCTFail("A different source revision cannot prove these tiles empty")
    } catch NotebookStorageError.transactionConflict { }

    let dense = Fixture(count: 100)
    let last = ScenePaintPosition(layer: .elements, zIndex: 0, key: dense.elements[98].id)
    let tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let key = dense.key(tile: tile, range: .init(layer: .elements, lower: last, upper: nil))
    let retained = try await dense.source().tilesRequiringPaint([key])
    XCTAssertEqual(retained, [key], "Two pages without a match do not prove the remaining source absent")
  }

  @MainActor
  func testEmptyTileProofRetainsACoverWhoseShadowCrossesTheBoundary() async throws {
    let fixture = Fixture(count: 0), item = fixture.workspace.items[0]
    let tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let board = BoardDocument(freeItems: [.init(itemID: item.id,
      center: tile.bounds.maximum.offsetBy(x: WorkspaceItemGeometry.notebook.width / 2 + 50, y: -256),
      zIndex: 0, stamp: fixture.workspace.stamp)], stamp: fixture.workspace.stamp)
    let hierarchy = BoardHierarchy(rootBoardID: fixture.workspace.rootBoardID,
      boards: [.init(id: fixture.workspace.rootBoardID, board: board)], stamp: board.stamp)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: hierarchy, paperSizes: [:])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: fixture.journal)
    let key = fixture.key(tile: tile, range: .whole(.covers))
    let retained = try await source.tilesRequiringPaint([key])
    XCTAssertEqual(retained, [key], "Paper outside the tile can still cast visible pixels inside it")
  }

  @MainActor
  func testSmallStackKeepsBothPhysicalCoversUnderTheSharedBudget() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let lower = WorkspaceItem.notebook(id: UUID(), title: "Lower", pageIDs: [UUID()])
    let upper = WorkspaceItem.notebook(id: UUID(), title: "Upper", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [lower, upper], selectedItemID: upper.id,
      selectedPageID: upper.pageIDs[0], stamp: stamp)
    var board = BoardDocument.initial(itemIDs: [lower.id, upper.id], actor: actor)
    XCTAssertNotNil(board.createStack(moving: upper.id, onto: lower.id, actor: actor))
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: board.stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let viewport = SpatialPoint(x: 820, y: 1180)
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(center: try XCTUnwrap(board.stack(containing: lower.id)?.center),
        scale: WorkspaceItemGeometry.notebook.coverScale(viewport: viewport)), viewport: viewport)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    let resources = SceneRenderResources()
    // Use exactly one shared pool for admission, static pixels and native ink.
    let tiles = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await tiles.stop() }
    tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
    try await waitUntil { tiles.published != nil || tiles.failure != nil }
    let cohort = try XCTUnwrap(tiles.published, tiles.failure ?? "The small stack must publish")
    for item in [lower, upper] {
      XCTAssertTrue(cohort.plan.allowsLive(.item(item.id), in: .board(presence.boardID)),
        "A two-cover stack must retain both real input and accessibility owners")
      XCTAssertNotNil(cohort.nativeInk.owners[.cover(item.id)])
    }
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, 256 * 1024 * 1024)
    XCTAssertLessThanOrEqual(cohort.plan.liveOwners.count + cohort.plan.inkBoardIDs.count, 8)
  }

  @MainActor
  func testNativePressureRemovesOnlyOptionalCarriersWithoutCoarseningTheirBacking() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let items = (0..<3).map { WorkspaceItem.notebook(title: "Carrier \($0)", pageIDs: [UUID()]) }
    let workspace = WorkspaceIndex(items: items, selectedItemID: items[0].id,
      selectedPageID: items[0].pageIDs[0], stamp: stamp)
    let element = SpatialElement(id: "unrelated-raster", surface: .board(workspace.rootBoardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 100, height: 100), worldOrigin: .zero, source: "Retained", stamp: stamp)
    let board = BoardDocument(freeItems: items.enumerated().map { index, item in
      .init(itemID: item.id, center: .init(x: Double(index) * 100, y: 0), zIndex: index, stamp: stamp)
    }, elements: [element], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(scale: 0.15), viewport: .init(x: 512, y: 512))
    let pin = WorkspaceSpatialID.item(items[0].id)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil }, pinned: [pin])
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    let initial = try await SceneCompositionPlan.prepare(source: source, presence: presence,
      frame: frame, pinned: [pin], displayScale: 2, previous: nil)
    XCTAssertEqual(initial.nativeOwnerCount, 4)
    let plane = SceneCompositionPlane.board(presence.boardID)
    var reduced = initial, reductions = 0
    while let next = try reduced.reducingNativeOwners(presence: presence, frame: frame, displayScale: 2) {
      XCTAssertLessThan(next.nativeOwnerCount, reduced.nativeOwnerCount)
      XCTAssertLessThan(next.reductionPotential, reduced.reductionPotential)
      XCTAssertEqual(next.protectedOwners, initial.protectedOwners)
      XCTAssertTrue(next.allowsLive(.element(element.id), in: plane),
        "Dropping a raster-only element cannot make a native cover allocation smaller")
      XCTAssertTrue(next.allowsLive(pin, in: plane))
      for item in items {
        let entry = try XCTUnwrap(index.paintEntry(id: .item(item.id), boardID: presence.boardID))
        let live = next.allowsLive(entry.id, in: plane) ? 1 : 0
        let painted = next.bands.filter { $0.plane == plane && $0.range.contains(entry) }.count
        XCTAssertEqual(live + painted, 1)
      }
      reduced = next; reductions += 1
    }
    XCTAssertEqual(reductions, 2)
    XCTAssertEqual(reduced.nativeOwnerCount, 2, "Root ink and the pinned carrier cannot yield to pressure")
    XCTAssertEqual(reduced.inkBoardIDs, initial.inkBoardIDs)
  }

  @MainActor
  func testBytePressureCoarsensWholeBoundsWithoutChangingPinsOrPainterSources() async throws {
    let fixture = Fixture(count: 2)
    let presence = SessionPresence(mode: .board,
      camera: .init(center: .init(x: 256, y: 256), scale: 1), viewport: .init(x: 256, y: 256))
    let pin = WorkspaceSpatialID.element(fixture.elements[0].id)
    let frame = WorkspaceSceneFrame(index: fixture.index, presence: presence, portalCamera: { _ in nil }, pinned: [pin])
    let original = try await SceneCompositionPlan.prepare(source: fixture.source(), presence: presence,
      frame: frame, pinned: [pin], displayScale: 2, previous: nil)
    let optional = try XCTUnwrap(original.liveOwners.first { !original.protectedOwners.contains($0) })
    let demoted = try XCTUnwrap(try original.demoting(optional, presence: presence, frame: frame, displayScale: 2))
    let coarse = try XCTUnwrap(try demoted.coarseningCoverage(presence: presence, frame: frame, displayScale: 2))
    XCTAssertLessThan(demoted.reductionPotential, original.reductionPotential)
    XCTAssertLessThan(coarse.reductionPotential, demoted.reductionPotential)
    XCTAssertLessThan(coarse.tiles.count, demoted.tiles.count)
    XCTAssertEqual(coarse.liveOwners, demoted.liveOwners)
    XCTAssertEqual(coarse.protectedOwners, original.protectedOwners)
    XCTAssertEqual(coarse.inkBoardIDs, demoted.inkBoardIDs)
    XCTAssertEqual(coarse.presentations, demoted.presentations)
    XCTAssertEqual(coarse.bands.map(\.id), demoted.bands.map(\.id))
    XCTAssertEqual(coarse.bands.map(\.rank), demoted.bands.map(\.rank))
    let plane = SceneCompositionPlane.board(presence.boardID)
    XCTAssertEqual(coarse.rank(id: pin, in: plane), demoted.rank(id: pin, in: plane))
    let tiles = try XCTUnwrap(coarse.coverage[plane]?.tiles)
    let first = try XCTUnwrap(tiles.first), last = try XCTUnwrap(tiles.last)
    let completeBounds = WorkspaceSpatialBounds(origin: first.origin, maximum: last.bounds.maximum)
    let requestedBounds = WorkspaceSpatialBounds(
      origin: presence.camera.screenToWorld(.init(x: -96, y: -96), viewport: presence.viewport),
      width: (presence.viewport.x + 192) / presence.camera.scale,
      height: (presence.viewport.y + 192) / presence.camera.scale)
    XCTAssertTrue(completeBounds.contains(requestedBounds), "Coarsening cannot crop the prepared margin or camera window")
    XCTAssertTrue(tiles.allSatisfy { $0.level >= demoted.coverage[plane]!.level })
    for element in fixture.elements {
      let entry = try XCTUnwrap(fixture.index.paintEntry(id: .element(element.id), boardID: presence.boardID))
      let live = coarse.allowsLive(entry.id, in: plane) ? 1 : 0
      let staticRanges = coarse.bands.filter { $0.plane == plane && $0.range.contains(entry) }.count
      XCTAssertEqual(live + staticRanges, 1, "A source remains in exactly one original painter position")
    }
    XCTAssertEqual(CompositionTile.pixelSize, 512)
  }

  @MainActor
  func testIndependentChildSourcesKeepTheForwardPortalAndItsRealPixels() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor), childID = UUID()
    let portal = WorkspaceItem.board(id: childID, title: "Prepared forward aperture")
    let workspace = WorkspaceIndex(items: [portal], selectedItemID: childID, selectedPageID: nil, stamp: stamp)
    let elements: [SpatialElement] = (0..<10).map { offset in
      .init(id: "portal-marker-\(offset)", surface: .board(childID), kind: .web,
        frame: .init(x: 0, y: 0, width: 800, height: 600),
        worldOrigin: .init(x: Double(offset % 3) * 500, y: Double(offset / 3) * 400),
        source: "Visible portal marker", html: "<svg width='100%' height='100%' viewBox='0 0 400 300'><circle cx='200' cy='150' r='65' fill='#ed2020'/></svg>",
        stamp: stamp)
    }
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID, boards: [
      .init(id: workspace.rootBoardID, board: .init(freeItems: [
        .init(itemID: childID, center: .zero, zIndex: 0, stamp: stamp)
      ], stamp: stamp)),
      .init(id: childID, board: .init(freeItems: [], elements: elements, stamp: stamp))
    ], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(scale: 0.35), viewport: .init(x: 834, y: 1194))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    let initial = try await SceneCompositionPlan.prepare(source: source, presence: presence,
      frame: frame, pinned: [], displayScale: 2, previous: nil)
    let aperture = try XCTUnwrap(initial.liveOwners.first { $0.id == .item(childID) })
    XCTAssertTrue(initial.protectedOwners.contains(aperture))
    XCTAssertNil(try initial.demoting(aperture, presence: presence, frame: frame, displayScale: 2),
      "A cheaper flat cover cannot replace the already admitted continuing camera destination")
    var reduced = initial
    while let optional = reduced.liveOwners.first(where: { !reduced.protectedOwners.contains($0) }) {
      let next = try XCTUnwrap(try reduced.demoting(optional, presence: presence, frame: frame, displayScale: 2))
      XCTAssertLessThan(next.reductionPotential, reduced.reductionPotential)
      XCTAssertTrue(next.protectedOwners.contains(aperture))
      XCTAssertNotNil(next.presentations[.board(childID)])
      XCTAssertTrue(next.inkBoardIDs.contains(childID))
      reduced = next
    }
    let resources = SceneRenderResources()
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    coordinator.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    try await waitUntil {
      coordinator.published?.sourceReceipts.contains { $0.key.plane.boardID == childID && $0.value.hasCurrentPixels } == true
    }
    let cohort = try XCTUnwrap(coordinator.published, coordinator.failure ?? "The prepared forward plane must remain whole")
    XCTAssertNil(coordinator.failure)
    XCTAssertTrue(cohort.plan.protectedOwners.contains(aperture))
    XCTAssertNotNil(cohort.plan.presentations[.board(childID)])
    XCTAssertNotNil(cohort.nativeInk.owners[.board(childID)])
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertLessThanOrEqual(cohort.plan.liveOwners.count + cohort.plan.inkBoardIDs.count, 8)
    XCTAssertLessThanOrEqual(cohort.plan.primitiveCount, 96)
    XCTAssertLessThanOrEqual(resources.rasterAdmission.pinnedBytes + resources.passiveReservedBytes, 128 * 1024 * 1024)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, 256 * 1024 * 1024)
    let childImages = Array(cohort.rasters.filter { $0.key.plane == .board(childID) && $0.key.range.layer == .elements }.values)
      + Array(cohort.liveRasters.filter { $0.key.plane == .board(childID) }.values)
    var redPixels = 0
    for raster in childImages {
      let bytes = try pixels(XCTUnwrap(raster.image.cgImage))
      redPixels += stride(from: 0, to: bytes.count, by: 4).filter {
        bytes[$0] > 180 && bytes[$0 + 1] < 80 && bytes[$0 + 2] < 80 && bytes[$0 + 3] > 180
      }.count
    }
    XCTAssertGreaterThan(redPixels, 10, "Prepared child content contains real marker pixels, not only metadata")
  }

  @MainActor
  func testColdStaticTileFitsItsActualOutputAndArtworkBudget() async throws {
    let fixture = Fixture(count: 8, side: 32, kind: .nativeText)
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 256, y: 256))
    let frame = WorkspaceSceneFrame(index: fixture.index, presence: presence, portalCamera: { _ in nil })
    let source = fixture.source()
    let fullPlan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: [], displayScale: 2, previous: nil)
    let plan = try await fullPlan.removingEmptyTiles(source: source)
    XCTAssertFalse(plan.tiles.isEmpty, "The eighth source remains in the static painter")
    let tileBytes = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: 512, pixelHeight: 512))
    let finalBytes = tileBytes * plan.tiles.count
    // The shown result, its replacement and clipped artwork fit; no unrelated
    // cache-decoding reservation belongs to this output path.
    let limit = 2 * (2 * finalBytes + 4 * 1024 * 1024)
    XCTAssertGreaterThan(2 * finalBytes - tileBytes + 12 * 1024 * 1024, limit / 2)
    let resources = SceneRenderResources(byteLimit: limit)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    coordinator.prepare(source: source, presence: presence, frame: frame, pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    let cohort = try XCTUnwrap(coordinator.published, coordinator.failure ?? "Cold tiles render without a fictitious cache grant")
    XCTAssertEqual(cohort.rasters.count, plan.tiles.count)
    XCTAssertTrue(cohort.rasters.values.allSatisfy { !$0.isReleased })
    XCTAssertTrue(coordinator.budgetFailures.isEmpty)
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, limit)
    await coordinator.stop()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testRasterAdmissionUsesTheActualRetainedEntryOnceAcrossMultipleLeases() throws {
    let fixture = Fixture(count: 1, side: 256)
    let source = agentElementSnapshotSource(fixture.elements[0])
    let image = bitmap(side: 256, scale: 2, color: .red)
    let pixels = try XCTUnwrap(image.cgImage)
    let cost = pixels.bytesPerRow * pixels.height * 2
    let resources = SceneRenderResources(byteLimit: cost * 2)
    XCTAssertTrue(resources.store(image, for: source))
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    let first = try XCTUnwrap(resources.retainRaster(for: source, minimumScale: 1))
    let second = try XCTUnwrap(resources.retainRaster(for: source, minimumScale: 1))
    XCTAssertEqual(first.accountedByteCount, cost)
    XCTAssertEqual(first.pixelScale, 2, "A higher-density matching cache entry has its real, not requested, cost")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, cost)
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 1)
    let temporary = try XCTUnwrap(resources.reserveDerivedBytes(cost, priority: .input))
    XCTAssertEqual(resources.rasterAdmission.heldBytes, cost * 2)
    XCTAssertFalse(resources.rasterAdmission.fits(additionalBytes: 1, additionalCount: 0))
    first.release()
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, cost)
    second.release(); temporary.release()
    XCTAssertEqual(resources.rasterAdmission.heldBytes, 0)
  }

  @MainActor
  func testCarriedRasterCopiesTheExactRetainedEntryInsteadOfANewerCacheAlias() throws {
    let fixture = Fixture(count: 1, side: 256)
    let source = agentElementSnapshotSource(fixture.elements[0])
    let red = bitmap(side: 256, scale: 2, color: .red)
    let blue = bitmap(side: 256, scale: 2, color: .blue)
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    XCTAssertTrue(resources.store(red, for: source))
    let shown = try XCTUnwrap(resources.retainRaster(for: source))
    XCTAssertTrue(resources.store(blue, for: source))
    let alias = try XCTUnwrap(resources.retainRaster(for: source))
    let carried = try XCTUnwrap(shown.retainedCopy())
    XCTAssertTrue(alias.image === blue)
    XCTAssertTrue(carried.image === red)
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 2)
    shown.release()
    XCTAssertFalse(carried.isReleased)
    alias.release(); carried.release()
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
  }

  @MainActor
  func testLiveRasterAdmissionUsesTheSameRoundedExactExtentAsWebKitExecution() throws {
    let element = SpatialElement(id: "fractional-square", surface: .board, kind: .web,
      frame: .init(x: 0, y: 0, width: 2050.1, height: 2049.7), worldOrigin: .zero,
      source: "Fractional extent", html: "<div/>", stamp: .init(counter: 0, actor: UUID()))
    let owner = SceneCompositionLiveOwner(plane: .board(WorkspaceRoot.boardID), id: .element(element.id),
      position: .init(layer: .elements, zIndex: 0, key: element.id))
    let request = try SceneCompositionRenderer.LiveRasterRequest(owner: owner, element: element, displayScale: 2)
    let display = try XCTUnwrap(AgentSnapshotPolicy.display(scale: 2).pixelSize(for: request.source))
    let exact = try XCTUnwrap(AgentSnapshotPolicy.exact(scale: request.requestedScale).pixelSize(for: request.source))
    XCTAssertGreaterThan(exact.width, display.width, "The display cap is not the exact snapshot allocation extent")
    let budget = try XCTUnwrap(SceneRenderResources.webSnapshotBudget(pixelSize: exact))
    XCTAssertEqual(request.residentBytes, budget.resident)
    XCTAssertEqual(request.snapshotAdditionalBytes, budget.capture - budget.resident)
  }





  @MainActor
  func testAdmittedSourceSurvivesInputPauseAndPublishesOnlyAfterTheBarrierOpens() async throws {
    let fixture = Fixture(count: 1, html: """
      <div style='position:absolute;inset:0;background:red'></div>
      <script>window.notebook.ready(new Promise(resolve => setTimeout(resolve, 450)))</script>
      """)
    let resources = SceneRenderResources(byteLimit: 96 * 1024 * 1024,
      profile: .headless, maximumBackgroundWebSurfaces: 1)
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    let pin = WorkspaceSpatialID.element(fixture.elements[0].id)
    let source = fixture.source(), frame = fixture.frame(pinned: [pin])
    let element = agentElementSnapshotSource(fixture.elements[0])
    let address = SceneSourceAddress(plane: .board(fixture.presence.boardID), elementID: element.id)
    var permitsInstallation = true
    func prepare() {
      coordinator.prepare(source: source, presence: fixture.presence, frame: frame,
        pinned: [pin], displayScale: 2, permitsPreparation: { permitsInstallation })
    }
    prepare()
    try await waitUntil {
      coordinator.published?.sourceReceipts[address]?.hasCurrentPixels == false
        && resources.activeWebSurfaceCount == 1
    }
    let old = try XCTUnwrap(coordinator.published)
    permitsInstallation = false
    prepare()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(resources.activeWebSurfaceCount, 1,
      "An input transition retains the admitted runtime and its still-running readiness promise")
    try await waitUntil { resources.image(for: element, minimumScale: 2) != nil }
    XCTAssertTrue(coordinator.published === old,
      "Completing pixels does not replace the contact's published scene while installation is closed")
    XCTAssertFalse(old.sourceReceipts[address]?.hasCurrentPixels == true)
    permitsInstallation = true
    prepare()
    try await waitUntil { coordinator.published?.sourceReceipts[address]?.hasCurrentPixels == true }
    let ready = try XCTUnwrap(coordinator.published?.sourceRasters[address])
    XCTAssertNotNil(ready.image(for: .agent(element), minimumScale: 2))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

  @MainActor
  func testGeometryPublishesBeforeItsSourceAndThenRetainsTheReadyPixels() async throws {
    let fixture = Fixture(count: 1, html: "<div style='position:absolute;inset:0;background:red'></div>")
    // This fixture has no mounted native consumer. Give the source job the
    // headless execution owner instead of reserving an interactive WK that
    // only a real PreparedAgentElementView is allowed to create.
    let resources = SceneRenderResources(byteLimit: 96 * 1024 * 1024,
      profile: .headless, maximumBackgroundWebSurfaces: 1)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    let pin = WorkspaceSpatialID.element(fixture.elements[0].id)
    coordinator.prepare(source: fixture.source(), presence: fixture.presence,
      frame: fixture.frame(pinned: [pin]), pinned: [pin], displayScale: 2)
    XCTAssertNil(coordinator.published, "Addressed geometry is prepared asynchronously")
    let deadline = ContinuousClock.now + .seconds(5)
    while coordinator.published == nil, coordinator.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let geometry = try XCTUnwrap(coordinator.published, coordinator.failure ?? "Geometry can mount while this source prepares")
    XCTAssertTrue(geometry.runtimeOwners.isEmpty, "This fixture's source is owned by its headless producer")
    let address = SceneSourceAddress(plane: .board(fixture.presence.boardID), elementID: fixture.elements[0].id)
    while coordinator.published?.sourceReceipts[address]?.hasCurrentPixels != true,
      coordinator.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let cohort = try XCTUnwrap(coordinator.published)
    XCTAssertTrue(cohort.sourceReceipts[address]?.hasCurrentPixels == true)
    XCTAssertEqual(cohort.geometryID, geometry.geometryID, "Source completion preserves the installed geometry owner")
    let owner = try XCTUnwrap(cohort.plan.liveOwners.first { $0.id == pin })
    let raster = try XCTUnwrap(cohort.liveRasters[owner])
    let source = agentElementSnapshotSource(fixture.elements[0])
    XCTAssertNotNil(raster.image(for: .agent(source), minimumScale: 2))
    let image = try XCTUnwrap(raster.image.cgImage)
    let rgba = try pixels(image)
    let center = ((image.height / 2) * image.width + image.width / 2) * 4
    XCTAssertGreaterThan(rgba[center], 240); XCTAssertLessThan(rgba[center + 1], 10)
    XCTAssertFalse(raster.isReleased, "The cohort protects this source from eviction before its first physical view mounts")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "The preparation executor is closed before the published frame is observed")
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

  @MainActor
  func testSameCursorAndPixelCoverageCannotKeepAnOldWindowWithoutItsReachedOwner() async throws {
    let fixture = Fixture(count: 1, side: 256)
    let resources = SceneRenderResources()
    // Use the production interactive pool, including its protected input half.
    // The measured old/new output pair must fit: this tests metadata delivery,
    // not optional-owner demotion under an intentionally undersized pool.
    XCTAssertTrue(resources.store(bitmap(side: 256, scale: 4, color: .red),
      for: agentElementSnapshotSource(fixture.elements[0])))
    let oldBoard = try XCTUnwrap(fixture.hierarchy.board(fixture.presence.boardID))
    let oldHierarchy = BoardHierarchy(rootBoardID: fixture.hierarchy.rootBoardID, boards: [
      .init(id: fixture.presence.boardID, board: .init(freeItems: oldBoard.freeItems, stamp: oldBoard.stamp))
    ], stamp: fixture.hierarchy.stamp)
    let oldIndex = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: oldHierarchy, paperSizes: [:])
    let oldWindow = WorkspaceSceneFrame(index: oldIndex, presence: fixture.presence, portalCamera: { _ in nil })
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    // The addressed renderer already knows the source, but the previous
    // bounded metadata window has not delivered its physical owner yet.
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: oldWindow, pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    let old = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    XCTAssertTrue(old.plan.liveOwners.isEmpty)
    let reachedFrame = fixture.frame()
    let reachedPlan = try await SceneCompositionPlan.prepare(source: fixture.source(), presence: fixture.presence,
      frame: reachedFrame, pinned: [], displayScale: 2, previous: old.plan)
    let reachedRaster = try XCTUnwrap(resources.retainRaster(for: agentElementSnapshotSource(fixture.elements[0]), minimumScale: 2))
    let tileBytes = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: 512, pixelHeight: 512))
    let artworkBytes = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: 514, pixelHeight: 514))
    let reachedOutputBytes = reachedPlan.tiles.count * tileBytes + reachedRaster.accountedByteCount
    reachedRaster.release()
    XCTAssertLessThanOrEqual(2 * reachedOutputBytes + artworkBytes, resources.passiveByteLimit,
      "The exact live source and two complete raster cuts fit without borrowing protected input bytes")
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: reachedFrame, pinned: [])
    try await waitUntil { coordinator.published?.id != old.id || coordinator.failure != nil }
    XCTAssertNil(coordinator.failure, "resident=\(resources.residentBytes); reserved=\(resources.reservedBytes); oldTiles=\(old.plan.tiles.count)")
    let current = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    XCTAssertNotEqual(current.id, old.id, "Identical revision and covered pixels cannot acknowledge stale interaction geometry")
    XCTAssertEqual(current.plan.revision, old.plan.revision)
    XCTAssertTrue(coordinator.budgetFailures.isEmpty, "Metadata delivery must not be conflated with byte-pressure demotion")
    XCTAssertEqual(current.frame.sourceIdentity, reachedFrame.sourceIdentity)
    XCTAssertTrue(current.plan.allowsLive(.element(fixture.elements[0].id), in: .board(fixture.presence.boardID)))
    XCTAssertTrue(current.frame.workset(boardID: fixture.presence.boardID).elements.contains { $0.id == fixture.elements[0].id })
    XCTAssertTrue(old.rasters.values.allSatisfy { !$0.isReleased }, "Preparing the replacement does not blank the previous complete frame")
  }

  @MainActor
  func testPreparedPortalPlaneTransfersTheSameWorldPointWithoutAnotherCohort() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID()), childID = UUID()
    let item = WorkspaceItem.board(id: childID, title: "Prepared portal")
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: nil, stamp: stamp)
    let portalCamera = BoardPortalCamera(center: .init(x: 120, y: -70), scale: 0.8)
    let root = BoardDocument(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID, boards: [
      .init(id: workspace.rootBoardID, board: root),
      .init(id: childID, board: .init(freeItems: [], stamp: stamp), portalCamera: portalCamera)
    ], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    for viewport in [SpatialPoint(x: 834, y: 1194), .init(x: 1194, y: 834)] {
      let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
        camera: BoardPortalProjection.parentBoundaryCamera(portalCenter: .zero, viewport: viewport), viewport: viewport)
      let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in portalCamera }, pinned: [.item(childID)])
      let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: .init(counter: 0, actor: actor)))
      let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
        pinned: [.item(childID)], displayScale: 2, previous: nil)
      let preparedChild = try XCTUnwrap(plan.presentations[.board(childID)])
      let transferred = BoardPortalProjection.entryCamera(portalCamera: portalCamera, viewport: viewport)
      let point = WorldPoint(x: 160, y: -45)
      let local = preparedChild.camera.worldToScreen(point, viewport: preparedChild.viewport)
      let center = presence.camera.worldToScreen(.zero, viewport: viewport)
      let size = SpatialPoint(x: WorkspaceItemGeometry.notebook.width * presence.camera.scale,
        y: WorkspaceItemGeometry.notebook.height * presence.camera.scale)
      let before = SpatialPoint(x: center.x - size.x / 2 + local.x * size.x / preparedChild.viewport.x,
        y: center.y - size.y / 2 + local.y * size.y / preparedChild.viewport.y)
      let after = transferred.worldToScreen(point, viewport: viewport)
      XCTAssertEqual(before.x, after.x, accuracy: 0.000_001)
      XCTAssertEqual(before.y, after.y, accuracy: 0.000_001)
      XCTAssertNotNil(plan.coverage[.board(childID)])
      XCTAssertNotNil(plan.coverage[.board(workspace.rootBoardID)], "The same retained cohort permits returning to the parent")
      XCTAssertLessThanOrEqual(plan.tiles.count, 32)
    }
  }

  @MainActor
  func testHundredThousandCoincidentSourcesHaveFinitePainterBandsAndOnePinnedOwner() async throws {
    let fixture = Fixture(count: 100_000)
    let pin = WorkspaceSpatialID.element(fixture.elements[50_000].id)
    let frame = fixture.frame(pinned: [pin])
    let plan = try await SceneCompositionPlan.prepare(source: fixture.source(), presence: fixture.presence,
      frame: frame, pinned: [pin], displayScale: 2, previous: nil)
    XCTAssertLessThanOrEqual(plan.tiles.count, 32)
    XCTAssertLessThanOrEqual(plan.liveOwners.count + 1, 8)
    XCTAssertLessThanOrEqual(plan.primitiveCount, 96)
    XCTAssertTrue(plan.allowsLive(pin, in: .board(fixture.presence.boardID)))
    let bands = plan.bands.filter { $0.plane == .board(fixture.presence.boardID) && $0.range.layer == .elements }
    for element in fixture.elements {
      let id = WorkspaceSpatialID.element(element.id)
      let entry = try XCTUnwrap(fixture.index.paintEntry(id: id, boardID: fixture.presence.boardID))
      XCTAssertEqual(bands.filter { $0.range.contains(entry) }.count,
        plan.allowsLive(id, in: .board(fixture.presence.boardID)) ? 0 : 1,
        "A source appears once in static painter order or once as a live owner")
    }
  }

  @MainActor
  func testMissingPinAndExcessPhysicalOwnersFailInsteadOfDisappearing() async throws {
    let fixture = Fixture(count: 10)
    for pins: Set<WorkspaceSpatialID> in [[.element("absent")], Set(fixture.elements.prefix(8).map { .element($0.id) })] {
      do {
        _ = try await SceneCompositionPlan.prepare(source: fixture.source(), presence: fixture.presence,
          frame: fixture.frame(), pinned: pins, displayScale: 2, previous: nil)
        XCTFail("A missing or over-budget input owner cannot silently become a static image")
      } catch SceneRenderError.snapshotPending { }
    }
  }

  @MainActor
  func testTransparentRangesAndLiveMiddleProduceTheSamePixelsAsWholePainterOrder() async throws {
    let tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let fixture = Fixture(count: 3, side: tile.worldSize, origin: tile.origin)
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024)
    for (element, color) in zip(fixture.elements, [UIColor.red, .green, .blue]) {
      XCTAssertTrue(resources.store(bitmap(side: tile.worldSize, scale: 2, color: color.withAlphaComponent(0.5)),
        for: agentElementSnapshotSource(element)))
    }
    let renderer = SceneCompositionRenderer(source: fixture.source(), resources: resources)
    defer { renderer.finishPreparation() }
    let middleEntry = try XCTUnwrap(fixture.index.paintEntry(id: .element(fixture.elements[1].id),
      boardID: fixture.presence.boardID))
    let middle = ScenePaintPosition(layer: .elements, zIndex: middleEntry.zIndex, key: fixture.elements[1].id)
    let full = try await renderer.renderTile(key: fixture.key(tile: tile, range: .whole(.elements)), presentation: fixture.presence)
    defer { full.release() }
    let before = try await renderer.renderTile(key: fixture.key(tile: tile,
      range: .init(layer: .elements, lower: nil, upper: middle)), presentation: fixture.presence)
    defer { before.release() }
    let after = try await renderer.renderTile(key: fixture.key(tile: tile,
      range: .init(layer: .elements, lower: middle, upper: nil)), presentation: fixture.presence)
    defer { after.release() }
    let live = try XCTUnwrap(resources.retainRaster(for: agentElementSnapshotSource(fixture.elements[1])))
    defer { live.release() }
    let result = try await SceneRasterCompositor.create(size: .init(width: 512, height: 512), scale: 1, resources: resources)
    let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
    try await result.draw(before, in: rect)
    try await result.draw(live, in: rect)
    try await result.draw(after, in: rect)
    let png = try await result.finishPNG()
    let actual = try pixels(XCTUnwrap(UIImage(data: png)?.cgImage))
    let expected = try pixels(XCTUnwrap(full.image.cgImage))
    XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 256, 2)
    XCTAssertGreaterThan(actual[3], 210, "This is composed transparent paint, not a blank count placeholder")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Ready source rasters need no executor")
  }

  @MainActor
  func testForeignRevisionIsRejectedBeforeAnyRasterAllocation() async throws {
    let fixture = Fixture(count: 0)
    let resources = SceneRenderResources()
    let renderer = SceneCompositionRenderer(source: fixture.source(), resources: resources)
    let key = fixture.key(tile: try XCTUnwrap(CompositionTile(containing: .zero, level: 0)), range: .whole(.elements)).atRevision(1)
    do { _ = try await renderer.renderTile(key: key, presentation: fixture.presence); XCTFail("A tile cannot claim another revision") }
    catch NotebookStorageError.transactionConflict { }
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.residentBytes, 0)
  }

  @MainActor
  func testScenePreflightReclaimsAnOffscreenOfferBeforeRejectingTheIncomingBoard() async throws {
    let fixture = Fixture(count: 32, side: 32, kind: .nativeText)
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .interactive)
    let unused = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 1_024, priority: .passive))
    var releases = 0
    let offerID = UUID()
    let owner = resources.registerReclamationOwner {
      unused.isReleased ? [] : [.init(id: offerID, bytes: unused.byteCount, rasterCount: 0,
        value: .neighbour, distance: 2, restorationMilliseconds: 1,
        release: { releases += 1; unused.release(); return nil })]
    }
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { resources.unregisterReclamationOwner(owner); unused.release() }
    addTeardownBlock { @MainActor in await coordinator.stop() }
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    XCTAssertEqual(releases, 1, "A preflight estimate must consult the actual resource owner, not bypass its disposable offers")
    XCTAssertNil(coordinator.failure)
    let incoming = try XCTUnwrap(coordinator.published)
    XCTAssertEqual(incoming.rasters.count, incoming.plan.tiles.count)
    XCTAssertFalse(incoming.rasters.isEmpty)
    XCTAssertLessThanOrEqual(resources.rasterAdmission.pinnedBytes + resources.passiveReservedBytes, resources.passiveByteLimit)
  }

  @MainActor
  func testCancellationAfterTheFirstCandidateTileKeepsTheWholePreviousCohortAndLeases() async throws {
    let fixture = Fixture(count: 8, side: 32, kind: .nativeText)
    // Old complete coverage and the first unpublished candidate coexist. This
    // test exercises cancellation, not intentional resource admission failure.
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    let old = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    let interrupted = expectation(description: "first candidate raster")
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange, object: nil, queue: .main) { note in
      guard let key = note.object as? SceneCompositionTileKey, key.revision == 1 else { return }
      MainActor.assumeIsolated { coordinator.cancelPreparation(); interrupted.fulfill() }
    }
    defer { NotificationCenter.default.removeObserver(observer); coordinator.removePublishedCoverage() }
    coordinator.prepare(source: fixture.source(revision: 1), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    await fulfillment(of: [interrupted], timeout: 3)
    try await waitUntil { resources.reservedBytes == 0 }
    XCTAssertTrue(coordinator.published === old)
    XCTAssertEqual(old.rasters.count, old.plan.tiles.count)
    XCTAssertTrue(old.rasters.values.allSatisfy { !$0.isReleased })
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

  @MainActor
  func testCameraSamplesFinishTheCurrentImageAndKeepOnlyTheLatestNextView() async throws {
    let fixture = Fixture(count: 8, side: 32, kind: .nativeText)
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    let firstPixels = expectation(description: "The current image is not cancelled by camera samples")
    firstPixels.assertForOverFulfill = false
    let workspaceID = fixture.index.generationID
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
      object: nil, queue: .main) { note in
      guard let key = note.object as? SceneCompositionTileKey, key.workspaceID == workspaceID else { return }
      if key.presentationScale == 1 { firstPixels.fulfill() }
      XCTAssertNotEqual(key.presentationScale, 0.5, "The superseded waiting view must not be rendered")
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let source = fixture.source()
    coordinator.prepare(source: source, presence: fixture.presence, frame: fixture.frame(),
      pinned: [], refinesDetails: false)
    let last = SessionPresence(mode: .board,
      camera: .init(center: .init(x: 12_000, y: 0), scale: 0.25), viewport: fixture.presence.viewport)
    for view in [SessionPresence(mode: .board,
      camera: .init(center: .init(x: 4_000, y: 0), scale: 0.5), viewport: fixture.presence.viewport), last] {
      coordinator.prepare(source: source, presence: view,
        frame: .init(index: fixture.index, presence: view, portalCamera: { _ in nil }),
        pinned: [], refinesDetails: false)
    }
    await fulfillment(of: [firstPixels], timeout: 3)
    try await waitUntil { !coordinator.isPreparing }
    XCTAssertNil(coordinator.failure)
    XCTAssertEqual(coordinator.published?.plan.presentations[.board(last.boardID)]?.camera, last.camera,
      "The last queued view progresses even after camera samples stop")
    await coordinator.stop()
    XCTAssertNil(coordinator.published)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testStopDrainsSupersededPreparationAndRejectsNewWork() async throws {
    let fixture = Fixture(count: 8, side: 32, kind: .nativeText)
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    XCTAssertNotNil(coordinator.published, coordinator.failure ?? "")
    let interrupted = expectation(description: "candidate has produced pixels")
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange, object: nil, queue: .main) { note in
      guard let key = note.object as? SceneCompositionTileKey, key.revision == 1 else { return }
      MainActor.assumeIsolated {
        coordinator.cancelPreparation()
        interrupted.fulfill()
      }
    }
    coordinator.prepare(source: fixture.source(revision: 1), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    await fulfillment(of: [interrupted], timeout: 3)
    NotificationCenter.default.removeObserver(observer)
    await coordinator.stop()
    XCTAssertNil(coordinator.published)
    XCTAssertFalse(coordinator.isPreparing)
    XCTAssertEqual(resources.reservedBytes, 0, "Even a cancelled job whose current handle was cleared has finished its resource ownership")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    let resident = resources.residentBytes
    coordinator.prepare(source: fixture.source(revision: 2), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    await coordinator.stop()
    XCTAssertNil(coordinator.published)
    XCTAssertFalse(coordinator.isPreparing)
    XCTAssertEqual(resources.residentBytes, resident, "A stopped composition owner cannot allocate or republish")
  }

  @MainActor
  func testStopReleasesEveryRasterAfterTheLastShownCohortReferenceEnds() async throws {
    let fixture = Fixture(count: 8, side: 32, kind: .nativeText)
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    var shown = try XCTUnwrap(coordinator.published, coordinator.failure ?? "") as SceneCompositionCohort?
    weak let retired = shown
    coordinator.prepare(source: fixture.source(revision: 1), presence: fixture.presence, frame: fixture.frame(), pinned: [])
    try await waitUntil { coordinator.published?.plan.revision == 1 || coordinator.failure != nil }
    XCTAssertEqual(coordinator.published?.plan.revision, 1, coordinator.failure ?? "")
    await coordinator.stop()
    XCTAssertNil(coordinator.published)
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0, "A still shown old cohort retains its actual pixels after stop")
    XCTAssertTrue(shown!.rasters.values.allSatisfy { !$0.isReleased })
    shown = nil
    XCTAssertNil(retired, "Neither a completed preparation task nor the cache retains a retired cohort")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate())
  }

  private func bitmap(side: Double, scale: Double, color: UIColor) -> UIImage {
    let pixels = Int(ceil(side * scale))
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
      bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor); context.fill(.init(x: 0, y: 0, width: pixels, height: pixels))
    return UIImage(cgImage: context.makeImage()!, scale: scale, orientation: .up)
  }
  private func pixels(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * context.height))
  }

  private struct Fixture {
    let workspace: WorkspaceIndex
    let hierarchy: BoardHierarchy
    let journal: SpatialInkJournal
    let index: WorkspaceSceneIndex
    let elements: [SpatialElement]
    let presence: SessionPresence
    init(count: Int, side: Double = 512, html: String = "<div/>", origin: WorldPoint = .zero,
      kind: SpatialElementKind = .web) {
      let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
      let item = WorkspaceItem.notebook(title: "Offscreen fixture owner", pageIDs: [UUID()])
      workspace = .init(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
      elements = (0..<count).map { offset in
        SpatialElement(id: String(format: "element-%06d", offset), surface: .board, kind: kind,
          frame: .init(x: 0, y: 0, width: side, height: side), worldOrigin: origin,
          source: "source \(offset)", html: html, stamp: .init(counter: 0, actor: actor))
      }
      let board = BoardDocument(freeItems: [.init(itemID: item.id, center: .init(x: -1_000_000, y: -1_000_000), zIndex: 0, stamp: stamp)], elements: elements, stamp: stamp)
      hierarchy = .init(rootBoardID: WorkspaceRoot.boardID, boards: [.init(id: WorkspaceRoot.boardID, board: board)], stamp: stamp)
      journal = .init(stamp: stamp)
      index = .init(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
      presence = .init(mode: .board, camera: .init(center: .init(x: side / 2, y: side / 2), scale: 1), viewport: .init(x: 512, y: 512))
    }
    func frame(pinned: Set<WorkspaceSpatialID> = []) -> WorkspaceSceneFrame {
      .init(index: index, presence: presence, portalCamera: { _ in nil }, pinned: pinned)
    }
    func source(revision: UInt64 = 0) -> SceneCompositionSource {
      .init(index: index, hierarchy: hierarchy, journal: journal, revision: revision)
    }
    func key(tile: CompositionTile, range: ScenePaintRange) -> SceneCompositionTileKey {
      .init(workspaceID: index.generationID, revision: 0, plane: .board(presence.boardID), tile: tile,
        range: range, presentationScale: presence.camera.scale, viewportWidth: presence.viewport.x,
        viewportHeight: presence.viewport.y, focusedItemID: nil, mode: "board")
    }
  }
}
