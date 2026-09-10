import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class SceneCompositionTests: XCTestCase {
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
  func testByteReductionKeepsTheAlreadyAdmittedForwardPortalAndItsRealChildPixels() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor), childID = UUID()
    let portal = WorkspaceItem.board(id: childID, title: "Prepared forward aperture")
    let workspace = WorkspaceIndex(items: [portal], selectedItemID: childID, selectedPageID: nil, stamp: stamp)
    let elements: [SpatialElement] = (0..<10).map { offset in
      .init(id: "portal-marker-\(offset)", surface: .board(childID), kind: .web,
        frame: .init(x: 0, y: 0, width: 400, height: 300),
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
    let cohort = try XCTUnwrap(coordinator.published, coordinator.failure ?? "The prepared forward plane must remain whole")
    XCTAssertNil(coordinator.failure)
    XCTAssertFalse(coordinator.budgetFailures.isEmpty, "This is the real cold byte-reduction path, not an unconstrained plan")
    XCTAssertLessThan(cohort.plan.reductionPotential, initial.reductionPotential)
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
  func testColdCacheMissDoesNotRequireDecodeScratchBeforeRenderingAnEmptyTile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture(count: 0, side: 256)
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 256, y: 256))
    let frame = WorkspaceSceneFrame(index: fixture.index, presence: presence, portalCamera: { _ in nil })
    let source = fixture.source()
    let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: [], displayScale: 2, previous: nil)
    let tileBytes = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: 512, pixelHeight: 512))
    let finalBytes = tileBytes * plan.tiles.count
    // The whole result and a clipped artwork fit. An unconditional last-tile
    // cache decode (4 MiB + 8 MiB scratch) provably does not.
    let limit = 2 * (2 * finalBytes + 4 * 1024 * 1024)
    XCTAssertGreaterThan(2 * finalBytes - tileBytes + 12 * 1024 * 1024, limit / 2)
    let resources = SceneRenderResources(byteLimit: limit)
    let coordinator = SceneCompositionTiles(resources: resources, cacheRoot: root)
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
    let final = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: Int(exact.width), pixelHeight: Int(exact.height)))
    let capture = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: Int(exact.width) + 2, pixelHeight: Int(exact.height) + 2))
    XCTAssertEqual(request.residentBytes, final)
    XCTAssertEqual(request.snapshotAdditionalBytes, capture - final)
  }

  @MainActor
  func testReturnWindowAndEveryPhysicalBoardInkShareTheBudgetWithoutEvictingTheApertureOrPins() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let childID = UUID(), grandchildID = UUID()
    let childItem = WorkspaceItem.board(id: childID, title: "Child")
    let grandchildItem = WorkspaceItem.board(id: grandchildID, title: "Grandchild")
    let workspace = WorkspaceIndex(items: [childItem, grandchildItem], selectedItemID: childID,
      selectedPageID: nil, stamp: stamp)
    func elements(_ prefix: String, boardID: UUID) -> [SpatialElement] {
      (0..<120).map { offset in
        .init(id: "\(prefix)-\(offset)", surface: .board(boardID), kind: .nativeText,
          frame: .init(x: 0, y: 0, width: 48, height: 48),
          worldOrigin: .init(x: Double(offset % 10) * 80 - 400, y: Double(offset / 10) * 80 - 400),
          source: "\(prefix) \(offset)", stamp: stamp)
      }
    }
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID, boards: [
      .init(id: workspace.rootBoardID, board: .init(freeItems: [
        .init(itemID: childID, center: .zero, zIndex: 0, stamp: stamp)
      ], elements: elements("parent", boardID: workspace.rootBoardID), stamp: stamp)),
      .init(id: childID, board: .init(freeItems: [
        .init(itemID: grandchildID, center: .init(x: 160, y: 0), zIndex: 0, stamp: stamp)
      ], elements: elements("child", boardID: childID), stamp: stamp)),
      .init(id: grandchildID, board: .init(freeItems: [], stamp: stamp))
    ], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: childID, mode: .board,
      camera: .init(scale: 0.5), viewport: .init(x: 512, y: 512))
    let pins: Set<WorkspaceSpatialID> = [.element("child-119")]
    let requested = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in .init() }, pinned: pins)
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    let frame = try await source.compositionFrame(requested: requested, presence: presence, pinned: pins)
    let parent = frame.workset(boardID: workspace.rootBoardID)
    let parentCoverCount = parent.items.reduce(0) { count, item in
      let cover = frame.covers[item.id]
      return count + (cover?.elements.count ?? 0) + (cover?.aggregates.count ?? 0)
    }
    XCTAssertLessThanOrEqual(parent.items.count + parent.elements.count + parent.aggregates.count + parentCoverCount, 24)
    XCTAssertLessThanOrEqual(frame.primitiveCount, 96)
    XCTAssertTrue(parent.items.contains { $0.id == childID })
    XCTAssertTrue(frame.workset(boardID: childID).elements.contains { $0.id == "child-119" })
    let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
      pinned: pins, displayScale: 2, previous: nil)
    XCTAssertTrue(plan.inkBoardIDs.isSuperset(of: [workspace.rootBoardID, childID]))
    XCTAssertTrue(plan.allowsLive(.item(childID), in: .board(workspace.rootBoardID)))
    for pin in pins { XCTAssertTrue(plan.allowsLive(pin, in: .board(childID))) }
    if plan.allowsLive(.item(grandchildID), in: .board(childID)) {
      XCTAssertTrue(plan.inkBoardIDs.contains(grandchildID))
    } else {
      let entry = try XCTUnwrap(index.paintEntry(id: .item(grandchildID), boardID: childID))
      XCTAssertEqual(plan.bands.filter { $0.plane == .board(childID) && $0.range.contains(entry) }.count, 1,
        "An unpinned portal that cannot fit as another native owner remains whole in the static painter")
    }
    XCTAssertLessThanOrEqual(plan.liveOwners.count + plan.inkBoardIDs.count, 8)
    XCTAssertLessThanOrEqual(plan.tiles.count, 32)
    XCTAssertLessThanOrEqual(plan.primitiveCount, 96)
    XCTAssertFalse(plan.bands.contains { $0.range.layer == .ink }, "Each included board has exactly one physical ink owner")
    let returning = try XCTUnwrap(plan.presentations[.board(workspace.rootBoardID)])
    let bounds = SceneCompositionSource.returnBounds(returning)
    let outward = SessionPresence(boardID: returning.boardID, mode: .board,
      camera: .init(center: returning.camera.center, scale: returning.camera.scale * 0.75), viewport: returning.viewport)
    let visible = WorkspaceSpatialBounds(origin: outward.camera.screenToWorld(.zero, viewport: outward.viewport),
      width: outward.viewport.x / outward.camera.scale, height: outward.viewport.y / outward.camera.scale)
    XCTAssertTrue(bounds.contains(visible), "The continued pinch already reveals the parent's surrounding pixels")
    var coarsest = plan, reductions = 0
    while let next = try coarsest.coarseningCoverage(presence: presence, frame: frame, displayScale: 2) {
      XCTAssertLessThan(next.tiles.count, coarsest.tiles.count)
      coarsest = next; reductions += 1
    }
    XCTAssertLessThanOrEqual(reductions, SceneCompositionPlan.maximumTiles)
    XCTAssertEqual(coarsest.tiles.count, coarsest.bands.count,
      "Every painter range can reach one whole centred tile, not four permanent origin quadrants")
    XCTAssertEqual(coarsest.bands.map(\.id), plan.bands.map(\.id))
    XCTAssertEqual(coarsest.bands.map(\.rank), plan.bands.map(\.rank))
    XCTAssertEqual(coarsest.liveOwners, plan.liveOwners)
    XCTAssertEqual(coarsest.inkBoardIDs, plan.inkBoardIDs)
    let returned = try XCTUnwrap(coarsest.coverage[.board(workspace.rootBoardID)]?.tiles.first)
    XCTAssertTrue(returned.bounds.contains(bounds), "Lower static density cannot crop the return aperture or its surrounding source")
  }

  @MainActor
  func testSettledChildPublicationRetainsTheCompleteParentReturnDuringAnActiveContact() async throws {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor), childID = UUID()
    let portal = WorkspaceItem.board(id: childID, title: "Return boundary")
    let portalCamera = BoardPortalCamera(center: .init(x: 120, y: -70), scale: 0.8)
    let workspace = WorkspaceIndex(items: [portal], selectedItemID: childID,
      selectedPageID: nil, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID, boards: [
      .init(id: workspace.rootBoardID, board: .init(freeItems: [
        .init(itemID: childID, center: .zero, zIndex: 0, stamp: stamp)
      ], stamp: stamp)),
      .init(id: childID, board: .init(freeItems: [], stamp: stamp),
        portalCamera: portalCamera)
    ], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let viewport = SpatialPoint(x: 512, y: 512)
    let parent = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: BoardPortalProjection.parentBoundaryCamera(portalCenter: .zero, viewport: viewport),
      viewport: viewport)
    let child = SessionPresence(boardID: childID, mode: .board,
      camera: BoardPortalProjection.entryCamera(portalCamera: portalCamera, viewport: viewport),
      viewport: viewport)
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy,
      journal: .init(stamp: stamp))
    func frame(_ presence: SessionPresence) -> WorkspaceSceneFrame {
      .init(index: index, presence: presence, portalCamera: { hierarchy.portalCamera($0) })
    }
    let resources = SceneRenderResources(byteLimit: 256 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    coordinator.prepare(source: source, presence: parent, frame: frame(parent), pinned: [])
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    let entered = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    XCTAssertNotNil(entered.plan.presentations[.board(childID)])
    XCTAssertTrue(entered.rasters.values.allSatisfy { !$0.isReleased })

    coordinator.prepare(source: source, presence: child, frame: frame(child), pinned: [])
    try await waitUntil { coordinator.published?.plan.rootBoardID == childID || coordinator.failure != nil }
    let settled = try XCTUnwrap(coordinator.published, coordinator.failure ?? "")
    XCTAssertEqual(settled.plan.rootBoardID, childID,
      "Wait for the actual child publication, not an arbitrary 40 ms after entry")
    XCTAssertFalse(settled === entered)

    // The outgoing camera belongs to the fingers. Background work cannot rescue
    // missing return pixels before lift and must not publish a partial scene.
    coordinator.prepare(source: source, presence: parent, frame: frame(parent), pinned: [],
      permitsPreparation: { false })
    try await waitUntil { !coordinator.isPreparing }
    let duringContact = try XCTUnwrap(coordinator.published)
    XCTAssertNotNil(duringContact.plan.presentations[.board(parent.boardID)],
      "A settled child must not discard the completed physical return boundary")
    XCTAssertEqual(duringContact.rasters.count, duringContact.plan.tiles.count)
    XCTAssertTrue(duringContact.rasters.values.allSatisfy { !$0.isReleased })
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

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
  func testStopReleasesEveryRasterAfterTheLastShownCohortReferenceEnds() async throws {
    let fixture = Fixture(count: 0)
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
    let secondExists = try await cache.hasRecord(second)
    XCTAssertFalse(secondExists)
    let absentSecond = try await cache.load(second)
    XCTAssertNil(absentSecond)
    try await cache.store(image, for: second)
    let evictedFirst = try await cache.load(first)
    XCTAssertNil(evictedFirst)
    let secondExistsAfterWrite = try await cache.hasRecord(second)
    XCTAssertTrue(secondExistsAfterWrite)
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 1)
    try Data("damaged".utf8).write(to: XCTUnwrap(files.first), options: .atomic)
    let corrupted = try await cache.load(second)
    XCTAssertNil(corrupted)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @MainActor
  func testCacheRecordRemovedAfterItsHintIsAnOrdinaryMiss() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = Fixture(count: 0)
    let key = fixture.key(tile: try XCTUnwrap(CompositionTile(containing: .zero, level: 0)), range: .whole(.elements))
    let cache = SceneCompositionTileCache(root: root)
    try await cache.store(try XCTUnwrap(bitmap(side: 512, scale: 1, color: .red).cgImage), for: key)
    let exists = try await cache.hasRecord(key)
    XCTAssertTrue(exists)
    try FileManager.default.removeItem(at: root)
    let disappeared = try await cache.load(key)
    XCTAssertNil(disappeared, "The preflight hint is neither a read receipt nor an allocation grant")
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
    init(count: Int, side: Double = 512, html: String = "<div/>", origin: WorldPoint = .zero) {
      let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
      let item = WorkspaceItem.notebook(title: "Offscreen fixture owner", pageIDs: [UUID()])
      workspace = .init(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
      elements = (0..<count).map { offset in
        SpatialElement(id: String(format: "element-%06d", offset), surface: .board, kind: .web,
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
