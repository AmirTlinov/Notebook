import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class SceneCompositionSQLTests: XCTestCase {
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
  func testColdCandidateDemotesOnlyOptionalRastersAndNeverDropsThePublishedCut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    // A whole old/new static pair and bounded artwork/cache scratch fit
    // inside the passive half. Six 1024-pixel live sources cannot coexist;
    // source dimensions, not a historical grid alignment, create the pressure.
    let passivePairAndScratch = (2 * 8 * 2 + 8) * 1024 * 1024
    let resources = SceneRenderResources(byteLimit: 2 * passivePairAndScratch, maximumBackgroundWebSurfaces: 1)
    let coordinator = SceneCompositionTiles(resources: resources, cacheRoot: root.appendingPathComponent("previews/scene-tiles"))
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
    var sawPrivateTile = false, oldWasRetained = true
    let observer = NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange, object: nil, queue: .main) { note in
      guard let key = note.object as? SceneCompositionTileKey, key.revision == freshRevision else { return }
      MainActor.assumeIsolated {
        sawPrivateTile = true
        oldWasRetained = oldWasRetained && old.rasters.values.allSatisfy { !$0.isReleased }
          && old.liveRasters.values.allSatisfy { !$0.isReleased }
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    coordinator.prepare(source: fresh, presence: presence, frame: frame, pinned: [])
    let deadline = ContinuousClock.now + .seconds(20)
    while coordinator.isPreparing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertFalse(coordinator.isPreparing)
    let current = try XCTUnwrap(coordinator.published, coordinator.failure ?? "Byte-aware candidate remains whole")
    XCTAssertEqual(current.plan.revision, freshRevision, coordinator.failure ?? "")
    XCTAssertNil(coordinator.failure)
    XCTAssertFalse(current === old)
    XCTAssertTrue(sawPrivateTile && oldWasRetained)
    XCTAssertLessThan(current.plan.liveOwners.count, unboundedBytesPlan.liveOwners.count)
    XCTAssertFalse(coordinator.budgetFailures.isEmpty)
    XCTAssertLessThanOrEqual(coordinator.budgetFailures.count, unboundedBytesPlan.reductionPotential + 1)
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
    XCTAssertEqual(coordinator.failure, "resource_limit", "Mandatory source quality is refused, not silently demoted")
    XCTAssertTrue(coordinator.published === current)
    XCTAssertTrue(current.rasters.values.allSatisfy { !$0.isReleased })
    XCTAssertEqual(coordinator.budgetFailures.count, 1, "An impossible all-pinned plan is not retried forever")
    await coordinator.stop()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  @MainActor
  func testReturnBoundaryReadsCurrentParentOnceAndKeepsTheWholeOldCutWhilePreparationIsDeferred() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let actor = UUID(), store = NotebookStore(root: root)
    let initial = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let beforeWorkspace = try store.loadIndex()
    let beforeBoard = try store.loadBoard(items: beforeWorkspace.items)
    var workspace = beforeWorkspace, hierarchy = beforeBoard
    XCTAssertTrue(hierarchy.moveItem(workspace.selectedItemID, in: initial.rootBoardID,
      to: .init(x: 100_000, y: 100_000), actor: actor))
    let portal = try XCTUnwrap(workspace.createBoard(title: "Return", actor: actor))
    XCTAssertTrue(hierarchy.createBoard(portal.id, in: initial.rootBoardID, near: .zero, actor: actor))
    let marker = SpatialElement(id: "return-parent-marker", surface: .board(initial.rootBoardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 120, height: 60), worldOrigin: .init(x: 400, y: 0), source: "Before",
      stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(marker, in: initial.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveWorkspaceEdits(before: beforeWorkspace, after: workspace,
      boardBefore: beforeBoard, boardAfter: hierarchy)
    hierarchy = try store.loadBoard(items: store.loadIndex().items)
    let inkSurfaces: [SurfaceID] = [.board(initial.rootBoardID), .board(portal.id), .cover(beforeWorkspace.selectedItemID)]
    var journal = try store.readSpatialInk(surfaces: inkSurfaces)
    for surface in inkSurfaces {
      let sample = SpatialInkSample(point: .zero, worldPoint: surface.kind == .board ? .zero : nil,
        timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      XCTAssertNotNil(journal.append(tool: .pen, spans: [.init(surface: surface, samples: [sample])], actor: actor))
    }
    try store.saveSpatialInk(journal)
    let viewport = SpatialPoint(x: 512, y: 512)
    let child = SessionPresence(boardID: portal.id, mode: .board, camera: .init(scale: 0.5), viewport: viewport)
    // The native child window knows only the parent's addressed aperture. Its
    // truncated metadata cannot stand in for the whole parent's current source.
    let parentPlacement = try XCTUnwrap(store.readBoardItem(portal.id))
    let childNode = try XCTUnwrap(store.readBoardNodeHeader(portal.id))
    let projectedWorkspace = try store.workspaceProjection(items: [portal], selectedItemID: portal.id, selectedPageID: nil)
    let projectedHierarchy = BoardHierarchy(rootBoardID: initial.rootBoardID,
      boards: [parentPlacement, childNode], stamp: hierarchy.stamp)
    let index = WorkspaceSceneIndex(workspace: projectedWorkspace, hierarchy: projectedHierarchy, paperSizes: [:])
    let requested = WorkspaceSceneFrame(index: index, presence: child, portalCamera: { _ in nil })
    XCTAssertFalse(requested.workset(boardID: initial.rootBoardID).elements.contains { $0.id == marker.id })
    func source() throws -> SceneCompositionSource {
      let header = try store.workspaceHeader()
      return .init(store: store, revision: header.cursor, workspaceID: header.workspaceID)
    }
    let oldSource = try source()
    let frame = try await oldSource.compositionFrame(requested: requested, presence: child, pinned: [])
    XCTAssertEqual(frame.returnBoardID, initial.rootBoardID)
    XCTAssertEqual(frame.workset(boardID: initial.rootBoardID).elements.first { $0.id == marker.id }?.source, "Before")
    XCTAssertLessThanOrEqual(frame.primitiveCount, 96)
    let resources = SceneRenderResources(byteLimit: 256 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    coordinator.prepare(source: oldSource, presence: child, frame: requested, pinned: [])
    try await waitForPublication(coordinator, revision: oldSource.revision)
    let old = try XCTUnwrap(coordinator.published)
    XCTAssertEqual(old.plan.inkBoardIDs, [initial.rootBoardID, portal.id])
    XCTAssertEqual(Set(old.liveData.ink.actions.flatMap { $0.spans.map(\.surface) }),
      [.board(initial.rootBoardID), .board(portal.id)],
      "Both handoff boards carry exact source ink; an unrelated cover remains outside the addressed payload")
    XCTAssertTrue(old.plan.allowsLive(.item(portal.id), in: .board(initial.rootBoardID)))
    XCTAssertLessThanOrEqual(old.plan.liveOwners.count + old.plan.inkBoardIDs.count, 8)
    XCTAssertEqual(old.requestedSources, requested.sourceIdentity)
    XCTAssertNotEqual(old.frame.sourceIdentity, requested.sourceIdentity)

    coordinator.prepare(source: oldSource, presence: child, frame: requested, pinned: [])
    XCTAssertFalse(coordinator.isPreparing, "The derived parent generation cannot cause a preparation feedback loop")
    XCTAssertTrue(coordinator.published === old)

    let prior = hierarchy
    var changed = try XCTUnwrap(hierarchy.board(initial.rootBoardID)?.elements.first { $0.id == marker.id })
    let expected = changed.stamp
    XCTAssertTrue(changed.update(source: "After", actor: actor))
    XCTAssertTrue(hierarchy.upsertElement(changed, in: initial.rootBoardID, expected: expected, actor: actor))
    _ = try store.saveBoardEdits(before: prior, after: hierarchy)
    let fresh = try source()
    coordinator.prepare(source: fresh, presence: child, frame: requested, pinned: [], permitsPreparation: { false })
    let deferredDeadline = ContinuousClock.now + .seconds(3)
    while coordinator.isPreparing, ContinuousClock.now < deferredDeadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertFalse(coordinator.isPreparing, "A revoked candidate must complete its bounded cancellation")
    XCTAssertTrue(coordinator.published === old, "A deferred candidate preserves the whole prior parent and child, not an empty return")
    XCTAssertEqual(old.frame.workset(boardID: initial.rootBoardID).elements.first { $0.id == marker.id }?.source, "Before")
    XCTAssertTrue(old.rasters.values.allSatisfy { !$0.isReleased })
    coordinator.prepare(source: fresh, presence: child, frame: requested, pinned: [])
    try await waitForPublication(coordinator, revision: fresh.revision)
    let current = try XCTUnwrap(coordinator.published)
    XCTAssertEqual(current.frame.workset(boardID: initial.rootBoardID).elements.first { $0.id == marker.id }?.source, "After",
      "An old complete parent is not a cache substitute for current same-cut surroundings")
    XCTAssertEqual(current.rasters.count, current.plan.tiles.count)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    do { try await oldSource.validate(); XCTFail("Old parent pixels cannot acquire a new source receipt") }
    catch NotebookStorageError.transactionConflict { }

    let basis = try XCTUnwrap(current.liveData.referenceInkBasis)
    let surfaces = current.plan.presentations.keys.map { plane -> SurfaceID in
      switch plane {
      case .board(let id): .board(id)
      case .cover(_, let id): .cover(id)
      }
    }
    let unchanged = try surfaces.map { try NotebookReferenceInk(surface: $0, actions: journal.actions) }
    XCTAssertEqual(try basis.replacingInk(unchanged), current.liveData.referenceIdentities)
    let tail = SpatialInkSample(point: .zero, worldPoint: .init(x: 20, y: 30), timeOffset: 0,
      width: 7, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    XCTAssertNotNil(journal.append(tool: .pen, spans: [
      .init(surface: .board(initial.rootBoardID), samples: [tail]),
      .init(surface: .board(portal.id), samples: [tail])
    ], actor: actor))
    let replacement = try surfaces.map { try NotebookReferenceInk(surface: $0, actions: journal.actions) }
    let predicted = try basis.replacingInk(replacement)
    try store.saveSpatialInk(journal)
    let canonical = try store.referenceIdentities(targets: current.liveData.referenceIdentities.map(\.target))
    XCTAssertEqual(predicted, canonical,
      "Both retained boards propagate ink through the real common ancestor, including the child's portal cover")
    XCTAssertNotEqual(predicted, current.liveData.referenceIdentities)
    await coordinator.stop()
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
    let before = try source(), oldPlan = try await plan(before)
    let oldData = try await before.liveData(plan: oldPlan, presence: presence, frame: frame)
    XCTAssertEqual(oldData.documents[documentID], document)
    XCTAssertEqual(oldData.states[documentID], state)
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
    var journal = try store.readSpatialInk(surfaces: [.board(header.rootBoardID)])
    let sample = SpatialInkSample(point: .zero, worldPoint: .zero, timeOffset: 0,
      width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    _ = journal.append(tool: .pen, spans: [.init(surface: .board(header.rootBoardID), samples: [sample])], actor: actor)
    try store.saveSpatialInk(journal)
    let after = try source(), newPlan = try await plan(after)
    let newData = try await after.liveData(plan: newPlan, presence: presence, frame: frame)
    let carry = try await after.canCarryStaticPixels(from: oldPlan, liveData: oldData, to: newPlan, liveData: newData)
    XCTAssertTrue(carry, "A new Pencil action and live document state do not invalidate excluded background paint")
    XCTAssertEqual(oldData.documents[documentID]?.blocks.first?.source, "Old body", "Shown passive payload is immutable while another revision prepares")
    XCTAssertEqual(newData.documents[documentID]?.blocks.first?.source, "New body")
    XCTAssertEqual(newData.states[documentID]?.value(for: "body"), .number(7))
    XCTAssertEqual(newData.ink.actions.count, 1)
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
    let crossData = try await crossSurface.liveData(plan: crossPlan, presence: presence, frame: frame)
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
}
