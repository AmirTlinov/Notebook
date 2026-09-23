import Metal
import NotebookCore
import Observation
import PencilKit
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SpatialInkHandoffTests: XCTestCase {
  func testExactSquareCropHasCompleteNativeBackingAndAcceptsItsFirstEdgeSample() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView)
    let crop = canvas.convert(fixture.canvas.bounds, from: fixture.canvas)
    XCTAssertTrue(canvas.bounds.contains(crop),
      "The native backing itself contains all 512 points; admission keeps its strict extent check")
    XCTAssertEqual(canvas.bounds.width, 1024)
    let before = try Self.inkPixelCount(fixture.canvas)
    let first = CGPoint(x: 0, y: 40)
    fixture.contact(tool: .pen, from: first, to: .init(x: 24, y: 80))
    let action = try XCTUnwrap(fixture.actions.last)
    XCTAssertEqual(action.spans.first?.samples.first?.worldPoint,
      fixture.activeCamera.screenToWorld(.init(x: first.x, y: first.y), viewport: fixture.viewport))
    XCTAssertTrue(fixture.canvas.inkView === canvas)
    let installed = try XCTUnwrap(canvas.installedSpatialSource).referenceInk()
    XCTAssertTrue(installed.actions.contains { $0.id == action.id })
    try await Self.waitUntil { canvas.isStableFramePresented }
    XCTAssertGreaterThan(try Self.inkPixelCount(fixture.canvas), before)
    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved, fixture.queue.failure ?? "")
    let childID = fixture.childID
    let durable = try await fixture.queue.submit { try $0.readSpatialInk(surfaces: [.board(childID)]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)
  }

  func testMountedInputReaffirmationDoesNotInvalidateItsOwnObservedResourceGraph() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView)
    try await Self.waitUntil { canvas.isStableFramePresented }
    let changes = ResourceChanges()
    withObservationTracking {
      _ = fixture.resources.activePhysicalOwnerCount
      _ = fixture.resources.passiveReservedBytes
    } onChange: {
      MainActor.assumeIsolated { changes.count += 1 }
    }
    for _ in 0..<100 { fixture.update(tool: .pen) }
    await Task.yield()
    XCTAssertEqual(changes.count, 0,
      "A mounted update must not invalidate itself merely by reaffirming the same input/passive roles")
    XCTAssertTrue(fixture.canvas.inkView === canvas)
    fixture.contact(tool: .pen, from: .init(x: 10, y: 20), to: .init(x: 80, y: 30))
    XCTAssertEqual(fixture.actions.count, 1)
    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved)
  }

  @MainActor
  private final class ResourceChanges { var count = 0 }

  func testNonemptyParentAndChildKeepTheSameCanvasMeshAndFirstAcceptedPointInPortrait() async throws {
    try await assertHandoff(viewport: .init(x: 512, y: 640))
  }

  func testNonemptyParentAndChildKeepTheSameCanvasMeshAndFirstAcceptedPointInLandscape() async throws {
    try await assertHandoff(viewport: .init(x: 640, y: 512))
  }

  func testFullPortraitRetinaBudgetReadiesNonemptyParentAndChildWithoutLoweringInkDensity() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 834, y: 1194), displayScale: 2,
      requiresStaticRaster: true, includesCoverInk: true, includesVisibleParent: true)
    addTeardownBlock { await fixture.close() }
    for id in [fixture.parentID, fixture.childID] {
      let canvas = try XCTUnwrap(fixture.cohort.nativeInk.owners[.board(id)]?.canvas)
      XCTAssertTrue(canvas.isStableFramePrepared)
      XCTAssertFalse(canvas.isStableFramePresented, "A private GPU frame is not a shown board")
      XCTAssertNil(canvas.window, "Preparation must not run a hidden display loop")
      XCTAssertEqual(canvas.bounds.size, CGSize(width: 1024, height: 1280),
        "Motion uses the same 4 by 5 Retina tile pools, including their previously unused edge pixels")
      XCTAssertEqual(canvas.drawableSize.width / canvas.bounds.width, 2, accuracy: 0.001)
      XCTAssertEqual(canvas.drawableSize.height / canvas.bounds.height, 2, accuracy: 0.001)
    }
    XCTAssertFalse(fixture.cohort.rasters.isEmpty, "Native ink must leave room for the visible static materials")
    let cover = try XCTUnwrap(fixture.cohort.nativeInk.owners[.cover(fixture.childID)]?.canvas)
    XCTAssertTrue(cover.isStableFramePrepared)
    XCTAssertFalse(cover.isStableFramePresented)
    XCTAssertGreaterThan(cover.committedSourceNodeCount, 0)
    XCTAssertLessThanOrEqual(fixture.resources.residentBytes + fixture.resources.reservedBytes, 256 * 1024 * 1024)
    try fixture.mountActive(fixture.parentID)
    fixture.contact(tool: .eraser, from: .init(x: 8, y: 8), to: .init(x: 20, y: 12))
    XCTAssertEqual(fixture.actions.count, 1, "The first full-size post-exit contact remains admitted")
  }

  func testIncomingBoardKeepsInputAdmissionWhileTheOldMountStillDisplays() async throws {
    try await assertIncomingInputAdmission(focusedCover: false)
  }

  func testOffscreenInkNeedsNoBackingAndReturnsAtFullDensityWhenProjectedIntoView() async throws {
    let viewport = SpatialPoint(x: 834, y: 1194)
    let fixture = try await Fixture.make(viewport: viewport, displayScale: 2, inkY: 100_000, includesVisibleParent: true)
    addTeardownBlock { await fixture.close() }
    for id in [fixture.parentID, fixture.childID] {
      let canvas = try XCTUnwrap(fixture.cohort.nativeInk.owners[.board(id)]?.canvas)
      XCTAssertGreaterThan(canvas.committedSourceNodeCount, 0, "The offscreen source is retained, not deleted")
      XCTAssertTrue(canvas.isStableFramePresented)
      XCTAssertEqual(canvas.spatialDrawableAccountedBytes, 0, "An empty visible projection does not need full-screen Metal tiles")
      XCTAssertEqual(canvas.residentCommittedBufferBytes, 0)
    }
    let camera = SpatialCamera(center: .init(x: 0, y: 100_000), scale: 1)
    let candidate = try await fixture.prepareResize(viewport: viewport, camera: camera, displayScale: 2)
    try candidate.install()
    let mount = SpatialInkPhysicalMountView(frame: fixture.canvas.bounds)
    fixture.host.view.addSubview(mount)
    defer { mount.unmount(); mount.removeFromSuperview() }
    mount.update(lease: candidate, surface: .board(fixture.childID), boardID: fixture.childID, camera: camera, active: true)
    let canvas = try XCTUnwrap(mount.inkView)
    try await Self.waitUntil { canvas.isStableFramePresented }
    XCTAssertGreaterThan(canvas.spatialDrawableAccountedBytes, 0)
    XCTAssertEqual(canvas.drawableSize.width / canvas.bounds.width, 2, accuracy: 0.001)
    XCTAssertGreaterThan(try Self.inkPixelCount(mount), 100)
    XCTAssertGreaterThan(canvas.committedEraserSourceNodeCount, 0)
  }

  func testIncomingFocusedCoverKeepsInputAdmissionWhileTheOldMountStillDisplays() async throws {
    try await assertIncomingInputAdmission(focusedCover: true)
  }

  private func assertIncomingInputAdmission(focusedCover: Bool) async throws {
    let viewport = SpatialPoint(x: 834, y: 1194)
    let fixture = try await Fixture.make(viewport: viewport, displayScale: 2)
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let old = fixture.cohort
    let oldCanvas = try XCTUnwrap(fixture.canvas.inkView)
    let passive = fixture.resources.rasterAdmission
    let pressure = try XCTUnwrap(fixture.resources.reserveDerivedBytes(
      passive.passiveByteLimit - passive.passiveReservedBytes - passive.pinnedBytes - 1_024 * 1_024,
      priority: .passive))
    defer { pressure.release() }
    let boardID = focusedCover ? fixture.childID : UUID()
    let actor = fixture.actor, stamp = VersionStamp(counter: 0, actor: fixture.actor)
    let item = WorkspaceItem.notebook(title: "Incoming input", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0],
      stamp: stamp, rootBoardID: boardID)
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID,
      board: .init(freeItems: [.init(itemID: item.id,
        center: focusedCover ? .zero : .init(x: 100_000, y: 100_000), zIndex: 0, stamp: stamp)], stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    var journal = fixture.journal
    let surface: SurfaceID = focusedCover ? .cover(item.id) : .board(boardID)
    let samples = [SpatialPoint(x: 100, y: 100), .init(x: 200, y: 100)].enumerated().map { offset, point in
      SpatialInkSample(point: focusedCover ? point : .zero,
        worldPoint: focusedCover ? nil : .init(x: point.x, y: point.y), timeOffset: Double(offset) / 10,
        width: 14, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }
    _ = journal.append(tool: .pen, spans: [.init(surface: surface, samples: samples)], actor: actor)
    let presence = SessionPresence(boardID: boardID, mode: focusedCover ? .cover : .board,
      camera: .init(), viewport: viewport, focusedItemID: focusedCover ? item.id : nil,
      selectedItemID: item.id, notebookPageID: item.pageIDs[0])
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: journal)
    fixture.tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
    let deadline = ContinuousClock.now + .seconds(10)
    while fixture.tiles.isPreparing, ContinuousClock.now < deadline {
      // The old SwiftUI mount may reaffirm its role during any preparation await.
      // It must neither demote the candidate's input nor charge retired input as
      // new passive content before replacement has made its release possible.
      fixture.update(tool: .pen)
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertFalse(fixture.tiles.isPreparing)
    XCTAssertNil(fixture.tiles.failure, "\(fixture.tiles.budgetFailures)")
    let next = try XCTUnwrap(fixture.tiles.published)
    XCTAssertFalse(next === old)
    XCTAssertEqual(next.plan.rootBoardID, boardID)
    let incoming = try XCTUnwrap(next.nativeInk.owners[surface]?.canvas)
    XCTAssertGreaterThan(incoming.committedSourceNodeCount, 0)
    XCTAssertEqual(incoming.drawableSize.width / incoming.bounds.width, 2, accuracy: 0.001)
    try await Self.waitUntil { oldCanvas.isStableFramePresented }
    XCTAssertGreaterThan(try Self.inkPixelCount(fixture.canvas), 100,
      "Old pixels remain retained through the transition")
    XCTAssertLessThanOrEqual(fixture.resources.residentBytes + fixture.resources.reservedBytes, fixture.resources.byteLimit)
  }

  func testReadyPrivateResizeDoesNotChangeInstalledBoundsOrPixelsAndCancellationReleasesItsTargets() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView)
    let bounds = canvas.bounds, drawable = canvas.drawableSize, installs = canvas.spatialMeshInstallCount
    let before = try Self.inkPixelCount(fixture.canvas), reserved = fixture.resources.reservedBytes
    var candidate: SpatialInkSceneLease? = try await fixture.prepareResize(viewport: .init(x: 640, y: 640))
    XCTAssertNotNil(candidate)
    XCTAssertEqual(canvas.bounds, bounds)
    XCTAssertEqual(canvas.drawableSize, drawable)
    XCTAssertEqual(canvas.spatialMeshInstallCount, installs)
    XCTAssertEqual(try Self.inkPixelCount(fixture.canvas), before,
      "Completed replacement GPU work must not resize or show pixels through the old layer")
    XCTAssertGreaterThan(fixture.resources.reservedBytes, reserved,
      "The private target and the displayed target are both actual allocations")
    candidate = nil
    XCTAssertEqual(fixture.resources.reservedBytes, reserved)
    XCTAssertEqual(canvas.bounds, bounds)
    XCTAssertEqual(try Self.inkPixelCount(fixture.canvas), before)
  }

  func testAcceptedPencilRevokesThePreparedResizeWithoutLosingItsFirstSampleOrInstalledTarget() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView), bounds = canvas.bounds
    let source = try XCTUnwrap(canvas.installedSpatialSource).referenceInk()
    let before = try Self.inkPixelCount(fixture.canvas)
    let candidate = try await fixture.prepareResize(viewport: .init(x: 640, y: 640))
    fixture.contact(tool: .pen, from: .init(x: 30, y: 40), to: .init(x: 180, y: 120))
    let action = try XCTUnwrap(fixture.actions.last)
    do { try candidate.install(); XCTFail("An accepted contact must invalidate a privately rendered target") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(canvas.bounds, bounds)
    XCTAssertTrue(fixture.canvas.inkView === canvas)
    XCTAssertNotEqual(try XCTUnwrap(canvas.installedSpatialSource).referenceInk(), source)
    XCTAssertTrue(try XCTUnwrap(canvas.installedSpatialSource).referenceInk().actions.contains { $0.id == action.id })
    let point = try XCTUnwrap(action.spans.first?.samples.first?.worldPoint)
    let expected = fixture.activeCamera.screenToWorld(.init(x: 30, y: 40), viewport: fixture.viewport)
    XCTAssertEqual(expected.delta(to: point).x, 0, accuracy: 0.00001)
    XCTAssertEqual(expected.delta(to: point).y, 0, accuracy: 0.00001)
    try await Self.waitUntil { canvas.isStableFramePresented }
    XCTAssertGreaterThan(try Self.inkPixelCount(fixture.canvas) - before, 100)
    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved, fixture.queue.failure ?? "")
    let childID = fixture.childID
    let durable = try await fixture.queue.submit { try $0.readSpatialInk(surfaces: [.board(childID)]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)
  }

  func testCameraChangeRejectsReadyResizeWithoutInstallingAnotherTargetsProjection() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView), bounds = canvas.bounds
    let source = try XCTUnwrap(canvas.installedSpatialSource).referenceInk()
    let candidate = try await fixture.prepareResize(viewport: .init(x: 640, y: 640))
    canvas.project(camera: .init(center: .init(x: 20, y: 40), scale: 1),
      viewport: .init(x: bounds.width, y: bounds.height))
    do { try candidate.install(); XCTFail("A newer native camera revokes the prepared target projection") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(canvas.bounds, bounds)
    XCTAssertTrue(fixture.canvas.inkView === canvas)
    XCTAssertEqual(try XCTUnwrap(canvas.installedSpatialSource).referenceInk(), source)
  }

  func testEmptyReadinessCannotArriveAfterTheNativeOwnerHasStopped() async throws {
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 32, height: 32), resources: .init())
    let retention = view.retainForSpatialHandoff(displayScale: 2)
    defer { retention.release() }
    var readyCallbacks = 0
    view.onRenderReadinessChange = { if $0 { readyCallbacks += 1 } }
    view.applySpatial(.init(batches: []))
    await view.finishSpatialHandoffFrames()
    // Drain the queued main-actor readiness delivery without a frame timeout.
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertEqual(readyCallbacks, 0)
    XCTAssertFalse(view.isStableFramePresented)
    view.applySpatial(.init(batches: []))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertEqual(readyCallbacks, 0)
    XCTAssertFalse(view.isStableFramePresented)
    XCTAssertEqual(view.spatialDrawableAccountedBytes, 0)
  }

  func testCancelledCandidateKeepsBothInstalledSourcesAndPhysicalOwners() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512), includesVisibleParent: true)
    addTeardownBlock { await fixture.close() }
    let old = fixture.cohort
    let childCanvas = try XCTUnwrap(old.nativeInk.owners[.board(fixture.childID)]?.canvas)
    let parentCanvas = try XCTUnwrap(old.nativeInk.owners[.board(fixture.parentID)]?.canvas)
    let source = try XCTUnwrap(childCanvas.installedSpatialSource)
    let count = fixture.resources.activePhysicalOwnerCount
    var changed = fixture.journal
    _ = changed.append(tool: .pen, spans: [Self.span(surface: .board(fixture.childID), y: 80)], actor: fixture.actor)
    let data = SceneCompositionLiveData(documents: [:], states: [:], pages: [:], ink: changed)
    let candidate = try await fixture.registry.prepareSceneInk(plan: old.plan, frame: old.frame,
      liveData: data, resources: fixture.resources, displayScale: 1)
    XCTAssertFalse(candidate.isInstalled)
    XCTAssertEqual(try childCanvas.installedSpatialSource?.referenceInk(), try source.referenceInk(),
      "Preparing new meshes cannot mutate the old displayed source")
    fixture.registry.beginAction(on: .board(fixture.childID))
    XCTAssertThrowsError(try candidate.install()) { XCTAssertTrue($0 is CancellationError) }
    fixture.registry.finishAction(on: .board(fixture.childID), keepingCommittedMesh: true)
    XCTAssertTrue(fixture.tiles.published === old)
    XCTAssertTrue(fixture.registry.canvas(for: .board(fixture.parentID)) === parentCanvas)
    XCTAssertTrue(fixture.registry.canvas(for: .board(fixture.childID)) === childCanvas)
    XCTAssertEqual(try childCanvas.installedSpatialSource?.referenceInk(), try source.referenceInk())
    XCTAssertEqual(fixture.resources.activePhysicalOwnerCount, count)
  }

  func testChangedExistingSourceKeepsOldPixelsUntilCompletedFrameInstallsAndCameraCASRejectsLateFrame() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView)
    try await Self.waitUntil { canvas.isStableFramePresented }
    let original = try Self.inkPixelCount(fixture.canvas)
    let originalSource = try XCTUnwrap(canvas.installedSpatialSource)
    var journal = fixture.journal
    _ = journal.append(tool: .pen, spans: [Self.span(surface: .board(fixture.childID), y: 80)], actor: fixture.actor)
    let data = SceneCompositionLiveData(documents: [:], states: [:], pages: [:], ink: journal)
    let candidate = try await fixture.registry.prepareSceneInk(plan: fixture.cohort.plan, frame: fixture.cohort.frame,
      liveData: data, resources: fixture.resources, displayScale: 1)
    XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), try originalSource.referenceInk())
    XCTAssertEqual(try Self.inkPixelCount(fixture.canvas), original,
      "A completed but unpublished drawable cannot reach the old visible Metal layer")
    let committed = expectation(description: "the staged layer transaction commits")
    candidate.afterPresentationTransaction { committed.fulfill() }
    try candidate.install()
    await fulfillment(of: [committed], timeout: 5)
    XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), try NotebookReferenceInk(surface: .board(fixture.childID), actions: journal.actions))
    XCTAssertGreaterThan(try Self.inkPixelCount(fixture.canvas), original + 500,
      "Installation uses the already completed pixels, not a promised future drawing callback")

    _ = journal.append(tool: .pen, spans: [Self.span(surface: .board(fixture.childID), y: -80)], actor: fixture.actor)
    let nextData = SceneCompositionLiveData(documents: [:], states: [:], pages: [:], ink: journal)
    let late = try await fixture.registry.prepareSceneInk(plan: fixture.cohort.plan, frame: fixture.cohort.frame,
      liveData: nextData, resources: fixture.resources, displayScale: 1)
    let before = try XCTUnwrap(canvas.installedSpatialSource)
    canvas.project(camera: .init(center: .init(x: 10, y: 0), scale: 1),
      viewport: .init(x: canvas.bounds.width, y: canvas.bounds.height))
    XCTAssertThrowsError(try late.install()) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), try before.referenceInk(),
      "The same source rendered with an obsolete camera cannot publish")
  }

  func testFirstPencilRestoresVisiblePixelsAfterTheLastLineIsCausallyUndone() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    let canvas = try XCTUnwrap(fixture.canvas.inkView)
    try await Self.waitUntil { canvas.isStableFramePresented }
    XCTAssertGreaterThan(try Self.inkPixelCount(fixture.canvas), 100)
    let surface = SurfaceID.board(fixture.childID)
    let ids = fixture.journal.actions.filter { $0.spans.contains { $0.surface == surface } }.map(\.id)
    for id in ids {
      XCTAssertTrue(fixture.journal.deactivate(id, actor: fixture.actor))
      let action = try XCTUnwrap(fixture.journal.actions.first { $0.id == id })
      let command = NotebookSpatialInkCommand.state(actionID: id, creationStamp: action.stamp,
        isActive: false, stateStamp: action.stateStamp, journalStamp: fixture.journal.stamp)
      _ = try await fixture.queue.submit { try $0.commitSpatialInk(command) }
    }
    let empty = try await fixture.registry.prepareSceneInk(plan: fixture.cohort.plan,
      frame: fixture.cohort.frame,
      liveData: .init(documents: [:], states: [:], pages: [:], ink: fixture.journal),
      resources: fixture.resources, displayScale: 1)
    let committed = expectation(description: "the empty layer transaction commits")
    empty.afterPresentationTransaction { committed.fulfill() }
    try empty.install()
    await fulfillment(of: [committed], timeout: 5)
    XCTAssertEqual(canvas.committedSourceNodeCount, 0)
    let blankPixels = try Self.inkPixelCount(fixture.canvas)
    XCTAssertLessThan(blankPixels, 10, "The last undone line must really disappear, not remain behind an empty receipt")
    let requests = canvas.drawableRequestCount
    fixture.contact(tool: .pen, from: .init(x: 40, y: 80), to: .init(x: 400, y: 100))
    let action = try XCTUnwrap(fixture.actions.last)
    XCTAssertEqual(action.spans.first?.surface, surface)
    try await Self.waitUntil { canvas.isStableFramePresented }
    XCTAssertNil(canvas.renderFailure)
    XCTAssertGreaterThan(canvas.drawableRequestCount, requests)
    XCTAssertTrue(fixture.canvas.inkView === canvas, "Undo and new input keep the physical Metal owner")
    XCTAssertGreaterThan(try Self.inkPixelCount(fixture.canvas), blankPixels + 100,
      "A new accepted stroke must restore the empty layer's actual pixels without a scene reload")
    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved, fixture.queue.failure ?? "")
    let durable = try await fixture.queue.submit { try $0.readSpatialInk(surfaces: [surface]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)
    XCTAssertTrue(durable.actions.filter { ids.contains($0.id) }.allSatisfy { !$0.isActive })
  }

  func testNewPencilRevokesPrivateFrameWithoutDroppingItsFirstSample() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    try fixture.mountActive(fixture.childID)
    var changed = fixture.journal
    _ = changed.append(tool: .pen, spans: [Self.span(surface: .board(fixture.childID), y: 80)], actor: fixture.actor)
    let candidate = try await fixture.registry.prepareSceneInk(plan: fixture.cohort.plan, frame: fixture.cohort.frame,
      liveData: .init(documents: [:], states: [:], pages: [:], ink: changed), resources: fixture.resources, displayScale: 1)
    fixture.contact(tool: .pen, from: .init(x: 30, y: 40), to: .init(x: 50, y: 60))
    XCTAssertEqual(fixture.actions.count, 1)
    XCTAssertEqual(fixture.actions.first?.spans.first?.samples.first?.worldPoint,
      fixture.activeCamera.screenToWorld(.init(x: 30, y: 40), viewport: fixture.viewport))
    XCTAssertThrowsError(try candidate.install()) { XCTAssertTrue($0 is CancellationError) }
    let source = try XCTUnwrap(fixture.canvas.inkView?.installedSpatialSource)
    XCTAssertTrue(try source.referenceInk().actions.contains { $0.id == fixture.actions.first?.id })
    XCTAssertFalse(try source.referenceInk().actions.contains { $0.id == changed.actions.last?.id })
    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved)
  }

  func testIncomingBoardDoesNotWaitForRetainedOutgoingOwnerIdentities() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 384, y: 384))
    addTeardownBlock { await fixture.close() }
    let old = fixture.cohort, count = fixture.resources.activePhysicalOwnerCount
    let spareIDs = Set((0..<(8 - count)).map { _ in ScenePhysicalOwner.item(UUID()) })
    let occupied = fixture.resources.reservePhysicalOwners(spareIDs)
    defer { occupied.release() }
    XCTAssertEqual(fixture.resources.activePhysicalOwnerCount, 8)
    let newID = UUID(), actor = fixture.actor
    let stamp = VersionStamp(counter: 0, actor: actor)
    let item = WorkspaceItem.notebook(title: "New physical pin", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp, rootBoardID: newID)
    let hierarchy = BoardHierarchy(rootBoardID: newID, boards: [.init(id: newID,
      board: .init(freeItems: [.init(itemID: item.id, center: .init(x: 100_000, y: 100_000), zIndex: 0, stamp: stamp)], stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: newID, mode: .board, camera: .init(), viewport: .init(x: 384, y: 384))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    fixture.tiles.prepare(source: source, presence: presence, frame: frame, pinned: [])
    try await Self.waitUntil { !fixture.tiles.isPreparing }
    XCTAssertNil(fixture.tiles.failure, "Retained identities consume no backing and cannot block a camera destination")
    let incoming = try XCTUnwrap(fixture.tiles.published)
    XCTAssertFalse(incoming === old)
    XCTAssertEqual(incoming.plan.rootBoardID, newID)
    let canvas = try XCTUnwrap(incoming.nativeInk.owners[.board(newID)]?.canvas)
    XCTAssertTrue(canvas.isStableFramePresented)
    XCTAssertEqual(canvas.spatialDrawableAccountedBytes, 0)
    XCTAssertEqual(fixture.resources.activePhysicalOwnerCount, 9,
      "The outgoing frame stays retained until its real mount releases it")
    XCTAssertTrue(old.nativeInk.owners.values.allSatisfy { $0.canvas.isStableFramePrepared })
    XCTAssertLessThanOrEqual(fixture.resources.residentBytes + fixture.resources.reservedBytes, fixture.resources.byteLimit)
  }

  func testMemorylessAttachmentPreservesFourSamplePenAndEraserAndDrainsOnStop() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512))
    addTeardownBlock { await fixture.close() }
    let canvas = try XCTUnwrap(fixture.cohort.nativeInk.owners[.board(fixture.childID)]?.canvas)
    XCTAssertGreaterThan(canvas.committedSourceNodeCount, 0)
    XCTAssertGreaterThan(canvas.committedEraserSourceNodeCount, 0)
    let device = try XCTUnwrap(canvas.device)
    if device.supportsFamily(.apple1) {
      XCTAssertEqual(canvas.spatialMultisampleStorageMode, .memoryless)
      XCTAssertEqual(canvas.spatialMultisampleAllocatedBytes, 0)
      XCTAssertEqual(canvas.spatialDrawableAccountedBytes, canvas.spatialDrawableByteCeiling * InkCanvasView.spatialFramesInFlight)
      XCTAssertGreaterThanOrEqual(canvas.spatialDrawableByteCeiling,
        Int(canvas.drawableSize.width) * Int(canvas.drawableSize.height) * 4)
    } else {
      XCTAssertEqual(canvas.spatialMultisampleStorageMode, .private)
      XCTAssertGreaterThan(canvas.spatialMultisampleAllocatedBytes, 0)
    }
    await fixture.tiles.stop()
    XCTAssertEqual(fixture.resources.activePhysicalOwnerCount, 0,
      "Shutdown drains submitted work before revoking the physical and backing leases")
    XCTAssertEqual(canvas.spatialDrawableAccountedBytes, 0)
  }

  func testRetiredMountedSceneReleasesItsCohortRasterPinsAndNativeOwners() async throws {
    let retired = try await Self.prepareAndRetireMountedScene()
    try await Self.waitUntil {
      retired.cohort == nil && retired.host == nil && retired.resources.rasterAdmission.pinnedBytes == 0
    }
    XCTAssertNil(retired.cohort, "A retired physical host cannot keep a complete old composition pinned")
    XCTAssertNil(retired.host)
    XCTAssertEqual(retired.resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertEqual(retired.resources.reservedBytes, 0)
    XCTAssertEqual(retired.resources.activePhysicalOwnerCount, 0)
    XCTAssertEqual(retired.registry.registeredPhysicalInkOwnerCount, 0)
  }

  @MainActor private final class RetiredScene {
    let resources: SceneRenderResources, registry: SpatialInkSurfaceRegistry
    weak var cohort: SceneCompositionCohort?
    weak var host: UIViewController?
    init(_ fixture: Fixture) {
      resources = fixture.resources; registry = fixture.registry
      cohort = fixture.cohort; host = fixture.host
    }
  }

  private static func prepareAndRetireMountedScene() async throws -> RetiredScene {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 512), requiresStaticRaster: true, includesVisibleParent: true)
    try fixture.mountActive(fixture.childID)
    XCTAssertFalse(fixture.cohort.rasters.isEmpty, "The retirement fixture must own actual painted fragments")
    try fixture.mountActive(fixture.parentID)
    try fixture.mountActive(fixture.childID)
    XCTAssertGreaterThan(fixture.resources.rasterAdmission.pinnedBytes, 0)
    let retired = RetiredScene(fixture)
    await fixture.close()
    return retired
  }

  private func assertHandoff(viewport: SpatialPoint) async throws {
    let fixture = try await Fixture.make(viewport: viewport, includesVisibleParent: true)
    addTeardownBlock { await fixture.close() }
    let cohort = fixture.cohort
    let parent = try XCTUnwrap(cohort.nativeInk.owners[.board(fixture.parentID)]?.canvas)
    let child = try XCTUnwrap(cohort.nativeInk.owners[.board(fixture.childID)]?.canvas)
    XCTAssertTrue(parent.isStableFramePrepared && child.isStableFramePrepared,
      "Both nonempty planes finish their private frame before the whole cohort publishes")
    XCTAssertFalse(parent.isStableFramePresented || child.isStableFramePresented,
      "Private preparation is not an acknowledgement of on-screen ink")
    XCTAssertEqual(fixture.registry.canvas(for: .board(fixture.parentID)), parent)
    XCTAssertEqual(fixture.registry.canvas(for: .board(fixture.childID)), child)
    let installs = [parent.spatialMeshInstallCount, child.spatialMeshInstallCount]
    try fixture.mountActive(fixture.childID)
    // Begin immediately after installing the real root input coordinator; no
    // scheduling grace period may create the first stroke after the handoff.
    fixture.contact(tool: .pen, from: .init(x: 30, y: 40), to: .init(x: 70, y: 50))
    fixture.contact(tool: .eraser, from: .init(x: 48, y: 42), to: .init(x: 54, y: 49))
    let accepted = try XCTUnwrap(fixture.actions.first)
    XCTAssertEqual(accepted.spans.first?.surface, .board(fixture.childID))
    let expected = fixture.activeCamera.screenToWorld(.init(x: 30, y: 40), viewport: viewport)
    let actual = try XCTUnwrap(accepted.spans.first?.samples.first?.worldPoint)
    XCTAssertEqual(expected.delta(to: actual).x, 0, accuracy: 0.00001)
    XCTAssertEqual(expected.delta(to: actual).y, 0, accuracy: 0.00001)
    let stableSource = try XCTUnwrap(child.installedSpatialSource)
    let tail = try stableSource.referenceInk()
    XCTAssertTrue(tail.actions.contains { $0.id == accepted.id })
    try fixture.mountActive(fixture.parentID)
    let target = CGPoint(x: 8, y: 8)
    fixture.contact(tool: .pen, from: target, to: .init(x: 18, y: 13))
    XCTAssertEqual(fixture.actions.count, 3, "The first post-exit contact is neither dropped nor replayed")
    XCTAssertEqual(fixture.actions.last?.spans.first?.surface, .cover(fixture.childID),
      "At the return boundary the portal cover fills the viewport and owns the first physical contact")
    XCTAssertTrue(fixture.registry.canvas(for: .board(fixture.childID)) === child)
    XCTAssertTrue(fixture.passive.inkView === child)
    XCTAssertEqual(try child.installedSpatialSource?.referenceInk(), tail)
    XCTAssertEqual([parent.spatialMeshInstallCount, child.spatialMeshInstallCount], installs,
      "Projection and accepted tails do not rebuild either complete mesh")
    try await Self.waitUntil { child.isStableFramePresented }
    let afterExit = try Self.inkPixelCount(fixture.passive)
    XCTAssertGreaterThan(afterExit, 100, "The same Metal layer has real nonempty pixels after it becomes passive")
    try fixture.mountActive(fixture.childID)
    XCTAssertTrue(fixture.canvas.inkView === child)
    XCTAssertEqual([parent.spatialMeshInstallCount, child.spatialMeshInstallCount], installs)
    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved, fixture.queue.failure ?? "")
    let durable = try await fixture.queue.submit { try $0.readSpatialInk(surfaces: [.board(fixture.childID), .board(fixture.parentID), .cover(fixture.childID)]) }
    for action in fixture.actions { XCTAssertEqual(durable.actions.first { $0.id == action.id }, action) }
    XCTAssertLessThanOrEqual(fixture.resources.residentBytes + fixture.resources.reservedBytes, fixture.resources.byteLimit)
  }

  private static func span(surface: SurfaceID, y: Double, width: Double = 14, xs: [Double] = [-100, 0, 100]) -> SpatialInkSpan {
    .init(surface: surface, samples: xs.enumerated().map { i, x in
      .init(point: .zero, worldPoint: .init(x: x, y: y), timeOffset: Double(i) / 10,
        width: width, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    })
  }
  private static func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "The native handoff preparation did not complete", file: file, line: line)
  }
  private static func inkPixelCount(_ view: UIView) throws -> Int {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(view.bounds)
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return stride(from: 0, to: cg.width * cg.height * 4, by: 4).filter { bytes[$0] < 160 && bytes[$0 + 1] < 160 && bytes[$0 + 2] < 160 }.count
  }

  @MainActor
  private final class Fixture {
    let actor: UUID, parentID: UUID, childID: UUID, root: URL, store: NotebookStore
    let resources: SceneRenderResources, tiles: SceneCompositionTiles, cohort: SceneCompositionCohort
    var registry: SpatialInkSurfaceRegistry { tiles.surfaceRegistry }
    let viewport: SpatialPoint, window: UIWindow, host = HandoffHost()
    let canvas: SpatialInkContainerView, passive = SpatialInkPhysicalMountView(frame: .zero)
    let gate = NotebookInputGate(), queue: NotebookPersistenceQueue
    var journal: SpatialInkJournal, actions: [SpatialInkAction] = []
    private var physical: WorkspaceInkFixture?
    private var coordinator: SpatialInkCanvas.Coordinator!
    private let touch = HandoffTouch(), event = UIEvent()
    private var currentID: UUID
    var activeCamera: SpatialCamera { cohort.plan.presentations[.board(currentID)]!.camera }

    static func make(viewport: SpatialPoint, displayScale: Double = 1, requiresStaticRaster: Bool = false,
      includesCoverInk: Bool = false, inkY: Double = 0, includesVisibleParent: Bool = false) async throws -> Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-handoff-" + UUID().uuidString)
      let store = NotebookStore(root: root), actor = UUID()
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      let before = try store.loadIndex(), oldBoard = try store.loadBoard(items: before.items)
      var workspace = before, hierarchy = oldBoard
      _ = hierarchy.moveItem(workspace.selectedItemID, in: header.rootBoardID, to: .init(x: 100_000, y: 100_000), actor: actor)
      let child = try XCTUnwrap(workspace.createBoard(title: "Ink handoff", actor: actor))
      _ = hierarchy.createBoard(child.id, in: header.rootBoardID, near: .zero, actor: actor)
      // Test two actually visible planes at portal entry. An opened child no
      // longer allocates its invisible parent solely for a hypothetical exit.
      _ = hierarchy.updatePortalCamera(BoardPortalProjection.portalCamera(from: .init(scale: 1), viewport: viewport),
        for: child.id, actor: actor)
      if requiresStaticRaster {
        // More visible sources than native slots leaves a real painter fragment
        // pinned. Empty painter bands are correctly pruned by the product.
        for index in 0..<8 {
          let element = SpatialElement(id: "retained-fragment-\(index)", surface: .board(child.id), kind: .nativeText,
            frame: .init(x: 0, y: 0, width: 90, height: 64),
            worldOrigin: .init(x: Double(index % 4) * 100 - 200, y: Double(index / 4) * 100 - 140),
            source: "Pin \(index)", stamp: .init(counter: 0, actor: actor))
          XCTAssertTrue(hierarchy.upsertElement(element, in: child.id, expected: nil, actor: actor))
        }
      }
      _ = try store.saveWorkspaceEdits(before: before, after: workspace, boardBefore: oldBoard, boardAfter: hierarchy)
      var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
      for surface in [SurfaceID.board(header.rootBoardID), .board(child.id)] {
        _ = journal.append(tool: .pen, spans: [span(surface: surface, y: inkY)], actor: actor)
        _ = journal.append(tool: .eraser, spans: [span(surface: surface, y: inkY, width: 20, xs: [-20, 0, 20])], actor: actor)
      }
      if includesCoverInk {
        _ = journal.append(tool: .pen, spans: [.init(surface: .cover(child.id), samples: [
          .init(point: .init(x: 100, y: 100), timeOffset: 0, width: 14, opacity: 1, force: 1, azimuth: 0, altitude: 1),
          .init(point: .init(x: 200, y: 100), timeOffset: 0.1, width: 14, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        ])], actor: actor)
      }
      try store.saveSpatialInk(journal)
      let current = try store.workspaceHeader()
      let source = SceneCompositionSource(store: store, revision: current.cursor, workspaceID: current.workspaceID)
      let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
      let presence = SessionPresence(boardID: includesVisibleParent ? header.rootBoardID : child.id, mode: .board,
        camera: includesVisibleParent ? BoardPortalProjection.parentBoundaryCamera(portalCenter: .zero, viewport: viewport) : .init(scale: 1),
        viewport: viewport)
      let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { hierarchy.portalCamera($0) })
      let resources = SceneRenderResources(), tiles = SceneCompositionTiles(resources: resources)
      tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: displayScale)
      try await waitUntil { tiles.published != nil || tiles.failure != nil }
      let cohort = try XCTUnwrap(tiles.published, tiles.failure ?? "")
      let fixture = try Fixture(root: root, store: store, actor: actor, parentID: header.rootBoardID, childID: child.id,
        viewport: viewport, resources: resources, tiles: tiles, cohort: cohort, journal: journal)
      try await waitUntil { fixture.host.appeared }
      return fixture
    }
    init(root: URL, store: NotebookStore, actor: UUID, parentID: UUID, childID: UUID, viewport: SpatialPoint,
      resources: SceneRenderResources, tiles: SceneCompositionTiles, cohort: SceneCompositionCohort, journal: SpatialInkJournal) throws {
      self.root = root; self.store = store; self.actor = actor; self.parentID = parentID; self.childID = childID
      self.viewport = viewport; self.resources = resources; self.tiles = tiles; self.cohort = cohort; self.journal = journal
      currentID = childID; queue = .init(store: store)
      canvas = .init(frame: .init(x: 0, y: 0, width: viewport.x, height: viewport.y))
      window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
      window.rootViewController = host; host.view.addSubview(canvas); host.view.addSubview(passive); window.makeKeyAndVisible()
      passive.frame = .init(x: viewport.x / 2 - 120, y: viewport.y / 2 - 120, width: 240, height: 240)
      coordinator = .init(surfaceRegistry: registry, inputGate: gate) { [weak self] tool, color, spans, _ in self?.accept(tool, color, spans) }
    }
    func mountActive(_ id: UUID) throws {
      coordinator.uninstall(); physical?.close(); currentID = id
      let presence = cohort.plan.presentations[.board(id)]!
      physical = try .init(cohort: cohort, presence: presence, canvas: canvas, parent: host, registry: registry, gate: gate)
      let other = id == childID ? parentID : childID
      passive.update(lease: cohort.nativeInk, surface: .board(other), boardID: other,
        camera: .init(scale: 1), active: false)
      host.view.bringSubviewToFront(passive)
      update(tool: .pen)
    }
    func prepareResize(viewport: SpatialPoint, camera: SpatialCamera? = nil, displayScale: Double = 1) async throws -> SpatialInkSceneLease {
      let header = try store.workspaceHeader()
      let source = SceneCompositionSource(store: store, revision: header.cursor, workspaceID: header.workspaceID)
      let presence = SessionPresence(boardID: currentID, mode: .board, camera: camera ?? activeCamera, viewport: viewport)
      let requested = WorkspaceSceneFrame(index: cohort.frame.index, presence: presence, portalCamera: { _ in nil })
      let frame = requested
      let plan = try await SceneCompositionPlan.prepare(source: source, presence: presence, frame: frame,
        pinned: [], displayScale: displayScale, previous: cohort.plan)
      let liveData = try await source.liveData(plan: plan, presence: presence, frame: frame)
      return try await registry.prepareSceneInk(plan: plan, frame: frame, liveData: liveData,
        resources: resources, displayScale: displayScale)
    }
    func update(tool: DrawingTool) {
      coordinator.update(view: canvas, cohort: cohort, boardID: currentID, camera: activeCamera, viewport: viewport,
        items: physical?.surfaces ?? [], journal: journal, penStyle: .standard, eraserStyle: .standard,
        drawingTool: tool, surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false },
        admitsNewContact: { true }, isEnabled: true, onCommit: { [weak self] tool, color, spans, _ in self?.accept(tool, color, spans) })
    }
    func contact(tool: DrawingTool, from: CGPoint, to: CGPoint) {
      update(tool: tool)
      let pencil = window.gestureRecognizers!.compactMap { $0 as? SpatialPencilGestureRecognizer }.first!
      pencil.reset(); touch.point = from; touch.time += 1
      pencil.touchesBegan([touch], with: event)
      touch.point = to; touch.time += 0.1; pencil.touchesMoved([touch], with: event)
      touch.time += 0.1; pencil.touchesEnded([touch], with: event)
    }
    func accept(_ tool: SpatialInkTool, _ color: SpatialInkColor, _ spans: [SpatialInkSpan]) -> SpatialInkAction? {
      guard let action = journal.append(tool: tool, color: color, spans: spans, actor: actor) else { return nil }
      actions.append(action)
      let command = NotebookSpatialInkCommand.append(action, journalStamp: journal.stamp)
      queue.enqueue(owner: .spatialInk(action.id)) { _ = try $0.commitSpatialInk(command); return false }
      return action
    }
    func close() async {
      coordinator.uninstall(); physical?.close(); passive.unmount()
      _ = await queue.flush(); await tiles.stop()
      // The fixture has awaited viewDidAppear before any test manipulation.
      // Hiding a UIWindow does not remove its root controller, so it cannot
      // acknowledge terminal removal with viewDidDisappear before detaching it.
      window.isHidden = true
      window.rootViewController = nil
      try? FileManager.default.removeItem(at: root)
    }
  }

  @MainActor
  private final class HandoffHost: UIViewController {
    private(set) var appeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); appeared = false }
  }
}

@MainActor
private final class HandoffTouch: UITouch {
  var point = CGPoint.zero, time: TimeInterval = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { time }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func location(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
