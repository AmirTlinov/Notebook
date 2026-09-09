import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class SceneCompositionTests: XCTestCase {
  @MainActor
  func testCohortPreparesAndRetainsLivePixelsBeforePublication() async throws {
    let fixture = Fixture(count: 1, html: "<div style='position:absolute;inset:0;background:red'></div>")
    let resources = SceneRenderResources(byteLimit: 96 * 1024 * 1024, maximumBackgroundWebSurfaces: 1)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    let pin = WorkspaceSpatialID.element(fixture.elements[0].id)
    coordinator.prepare(source: fixture.source(), presence: fixture.presence,
      frame: fixture.frame(pinned: [pin]), pinned: [pin], displayScale: 2)
    XCTAssertNil(coordinator.published, "An excluded but cold source is not a completed scene")
    let deadline = ContinuousClock.now + .seconds(5)
    while coordinator.published == nil, coordinator.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let cohort = try XCTUnwrap(coordinator.published, coordinator.failure ?? "A whole cohort includes its live pixels")
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
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    // Two complete coverages and the exact source fit this deliberately smaller
    // pool. A metadata refresh must not accidentally test resource exhaustion.
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
    coordinator.prepare(source: fixture.source(), presence: fixture.presence, frame: reachedFrame, pinned: [])
    try await waitUntil { coordinator.published?.id != old.id || coordinator.failure != nil }
    XCTAssertNil(coordinator.failure, "resident=\(resources.residentBytes); reserved=\(resources.reservedBytes); oldTiles=\(old.plan.tiles.count)")
    let current = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    XCTAssertNotEqual(current.id, old.id, "Identical revision and covered pixels cannot acknowledge stale interaction geometry")
    XCTAssertEqual(current.plan.revision, old.plan.revision)
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
      let transferred = try XCTUnwrap(BoardPortalProjection.enteringCamera(from: presence.camera,
        portalCamera: portalCamera, portalCenter: .zero, viewport: viewport))
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
    let fixture = Fixture(count: 3, side: tile.worldSize)
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
  func testCancellationAfterTheFirstCandidateTileKeepsTheWholePreviousCohortAndLeases() async throws {
    let fixture = Fixture(count: 0)
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
  func testStopDrainsSupersededPreparationAndRejectsNewWork() async throws {
    let fixture = Fixture(count: 0)
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
  func testTileDiskCacheChecksIdentityCorruptionAndFiniteEviction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture(count: 0)
    let tile = try XCTUnwrap(CompositionTile(containing: .zero, level: 0))
    let first = fixture.key(tile: tile, range: .whole(.elements))
    let second = first.atRevision(1)
    let cache = SceneCompositionTileCache(root: root, entryLimit: 1)
    let image = try XCTUnwrap(bitmap(side: 512, scale: 1, color: .red).cgImage)
    try await cache.store(image, for: first)
    let ready = try await cache.load(first)
    XCTAssertEqual(ready?.width, 512)
    let absentSecond = try await cache.load(second)
    XCTAssertNil(absentSecond)
    try await cache.store(image, for: second)
    let evictedFirst = try await cache.load(first)
    XCTAssertNil(evictedFirst)
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 1)
    try Data("damaged".utf8).write(to: XCTUnwrap(files.first), options: .atomic)
    let corrupted = try await cache.load(second)
    XCTAssertNil(corrupted)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
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
    init(count: Int, side: Double = 512, html: String = "<div/>") {
      let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
      let item = WorkspaceItem.notebook(title: "Offscreen fixture owner", pageIDs: [UUID()])
      workspace = .init(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
      elements = (0..<count).map { offset in
        SpatialElement(id: String(format: "element-%06d", offset), surface: .board, kind: .web,
          frame: .init(x: 0, y: 0, width: side, height: side), worldOrigin: .zero,
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
