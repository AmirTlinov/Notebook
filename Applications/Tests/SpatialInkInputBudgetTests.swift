import MetalKit
import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// The ordinary scene's passive pixels and the first Pencil drawable compete
/// inside one real 256 MiB owner. No synthetic reservations fill the ledger.
@MainActor
final class SpatialInkInputBudgetTests: XCTestCase {
  func testTwelvePointNineInchRetinaFirstContactFitsBesideTheFullPassiveHalf() async throws {
    try await assertLargeRetinaFirstContact(viewport: .init(x: 1024, y: 1366))
  }

  func testThirteenInchRetinaFirstContactFitsBesideTheFullPassiveHalf() async throws {
    try await assertLargeRetinaFirstContact(viewport: .init(x: 1032, y: 1376))
  }

  func testInstalledBoardGrowsToTheNewViewportBeforeAcceptingInkOutsideItsOldBacking() async throws {
    let oldViewport = SpatialPoint(x: 512, y: 640), viewport = SpatialPoint(x: 1024, y: 1366)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("resized-native-input-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex()
    var hierarchy = try store.loadBoard(items: workspace.items)
    XCTAssertTrue(hierarchy.moveItem(workspace.selectedItemID, in: header.rootBoardID,
      to: .init(x: 100_000, y: 100_000), actor: actor))
    try store.saveBoard(hierarchy, items: workspace.items)
    let resources = SceneRenderResources(), tiles = SceneCompositionTiles(resources: resources)
    let queue = NotebookPersistenceQueue(store: store), accepted = BudgetAcceptedInk(actor: actor, queue: queue)
    let baseline = try XCTUnwrap(accepted.journal.append(tool: .pen,
      spans: [.init(surface: .board(header.rootBoardID), samples: [-100.0, 0, 100].enumerated().map { index, x in
        .init(point: .zero, worldPoint: .init(x: x, y: 0), timeOffset: Double(index) / 10,
          width: 14, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor))
    try store.saveSpatialInk(accepted.journal)
    let gate = NotebookInputGate(), host = BudgetInputHost()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let mount = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: oldViewport.x, height: oldViewport.y))
    let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: tiles.surfaceRegistry, inputGate: gate) {
      accepted.append(tool: $0, color: $1, spans: $2)
    }
    addTeardownBlock { @MainActor [weak coordinator] in
      coordinator?.uninstall(); mount.unmount(); mount.removeFromSuperview()
      window.isHidden = true; window.rootViewController = nil
      let saved = await queue.flush()
      XCTAssertTrue(saved, queue.failure ?? "")
      await tiles.stop()
      XCTAssertEqual(resources.reservedBytes, 0)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    let current = try store.workspaceHeader()
    let source = SceneCompositionSource(store: store, revision: current.cursor, workspaceID: current.workspaceID)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let camera = SpatialCamera(scale: 1)
    let oldPresence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: camera, viewport: oldViewport)
    let oldFrame = WorkspaceSceneFrame(index: index, presence: oldPresence, portalCamera: { _ in nil })
    tiles.prepare(source: source, presence: oldPresence, frame: oldFrame, pinned: [], displayScale: 2)
    let firstDeadline = ContinuousClock.now + .seconds(5)
    while tiles.published == nil, tiles.failure == nil, ContinuousClock.now < firstDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let old = try XCTUnwrap(tiles.published, tiles.failure ?? "The nonempty small viewport must be genuinely ready")
    window.frame = mount.frame; host.view.backgroundColor = .white
    window.rootViewController = host; host.view.addSubview(mount); window.makeKeyAndVisible()
    let appearanceDeadline = ContinuousClock.now + .seconds(5)
    while !host.appeared, ContinuousClock.now < appearanceDeadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(host.appeared)
    func update(_ cohort: SceneCompositionCohort, viewport: SpatialPoint) {
      coordinator.update(view: mount, cohort: cohort, boardID: header.rootBoardID,
        camera: camera, viewport: viewport, items: [], journal: accepted.journal,
        penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
        surfaceRegistry: tiles.surfaceRegistry, inputGate: gate, isItemBeingDeleted: { _ in false },
        admitsNewContact: { true }, isEnabled: true,
        onCommit: { accepted.append(tool: $0, color: $1, spans: $2) })
    }
    update(old, viewport: oldViewport)
    let canvas = try XCTUnwrap(mount.inkView), oldBounds = canvas.bounds.size
    let oldDrawable = canvas.drawableSize, oldInstalls = canvas.spatialMeshInstallCount
    XCTAssertGreaterThan(try blackPixelCount(capture(mount)), 100, "The old canvas must have real pixels, not just a retained source")
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: camera, viewport: viewport)
    let nextFrame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    tiles.prepare(source: source, presence: presence, frame: nextFrame, pinned: [], displayScale: 2)
    let nextDeadline = ContinuousClock.now + .seconds(5)
    while tiles.published === old, tiles.failure == nil, ContinuousClock.now < nextDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let next = try XCTUnwrap(tiles.published, tiles.failure ?? "The larger viewport must prepare one complete successor")
    XCTAssertFalse(next === old)
    XCTAssertEqual(next.plan.presentations[.board(header.rootBoardID)]?.viewport, viewport)
    XCTAssertEqual(next.rasters.count, next.plan.tiles.count)
    window.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    mount.frame = window.frame; host.view.layoutIfNeeded()
    update(next, viewport: viewport)
    XCTAssertTrue(mount.inkView === canvas)
    XCTAssertTrue(next.nativeInk.owners[.board(header.rootBoardID)] === old.nativeInk.owners[.board(header.rootBoardID)])
    XCTAssertEqual(canvas.spatialMeshInstallCount, oldInstalls, "Changing a target size must not rebuild the unchanged ink source")
    let expectedSize = BoardPortalProjection.renderViewport(viewport: .init(x: viewport.y, y: viewport.y))
    XCTAssertEqual(canvas.bounds.width, expectedSize.x, accuracy: 0.001)
    XCTAssertEqual(canvas.bounds.height, expectedSize.y, accuracy: 0.001)
    let before = capture(mount), beforePixels = try blackPixelCount(before)
    XCTAssertGreaterThan(beforePixels, 100, "The accepted old ink must survive the prepared target-size swap")
    let first = CGPoint(x: 80, y: 120), last = CGPoint(x: 120, y: 620)
    let oldBackingInNewViewport = CGRect(x: (viewport.x - oldBounds.width) / 2,
      y: (viewport.y - oldBounds.height) / 2, width: oldBounds.width, height: oldBounds.height)
    XCTAssertFalse(oldBackingInNewViewport.contains(first))
    XCTAssertFalse(oldBackingInNewViewport.contains(last))
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = BudgetPencilTouch(window: window), event = UIEvent()
    touch.point = first; pencil.touchesBegan([touch], with: event)
    XCTAssertTrue(gate.hasActivePencil)
    touch.point = last; touch.sampleTime += 0.1; pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    let action = try XCTUnwrap(accepted.journal.actions.last)
    XCTAssertNotEqual(action.id, baseline.id)
    XCTAssertEqual(accepted.journal.actions.count, 2)
    let point = try XCTUnwrap(action.spans.first?.samples.first?.worldPoint)
    let expectedPoint = camera.screenToWorld(.init(x: first.x, y: first.y), viewport: viewport)
    XCTAssertEqual(expectedPoint.delta(to: point).x, 0, accuracy: 0.00001)
    XCTAssertEqual(expectedPoint.delta(to: point).y, 0, accuracy: 0.00001)
    let frameDeadline = ContinuousClock.now + .seconds(5)
    while !canvas.isStableFramePresented, canvas.renderFailure == nil, ContinuousClock.now < frameDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let after = capture(mount), afterPixels = try blackPixelCount(after)
    let report = "oldViewport=\(oldViewport); viewport=\(viewport); oldBounds=\(oldBounds); bounds=\(canvas.bounds.size); "
      + "oldDrawable=\(oldDrawable); drawable=\(canvas.drawableSize); beforePixels=\(beforePixels); afterPixels=\(afterPixels); "
      + "acceptedUUID=\(action.id); failure=\(String(describing: canvas.renderFailure)); "
      + "pinned=\(resources.rasterAdmission.pinnedBytes); reserved=\(resources.reservedBytes)"
    let receipt = XCTAttachment(string: report); receipt.name = "same-board-viewport-growth"; receipt.lifetime = .keepAlways; add(receipt)
    for (name, image) in [("resized-before-contact", before), ("resized-first-line", after)] {
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    XCTAssertNil(canvas.renderFailure, report)
    XCTAssertEqual(canvas.drawableSize.width / canvas.bounds.width, 2, accuracy: 0.001, report)
    XCTAssertEqual(canvas.drawableSize.height / canvas.bounds.height, 2, accuracy: 0.001, report)
    XCTAssertGreaterThan(afterPixels - beforePixels, 100, "The first line outside the old backing must be visible. " + report)
    XCTAssertTrue(tiles.published === next)
    XCTAssertTrue(try XCTUnwrap(canvas.installedSpatialSource).referenceInk().actions.contains { $0.id == action.id })
    let saved = await queue.flush()
    XCTAssertTrue(saved, queue.failure ?? "")
    let boardID = header.rootBoardID
    let durable = try await queue.submit { try $0.readSpatialInk(surfaces: [.board(boardID)]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

  /// Exercise the real aspect-correct native canvas, not an unreachable 4096²
  /// square. The finite images below fill the ordinary passive allowance; they
  /// are held RasterLeases, not synthetic byte reservations or WebKit work.
  private func assertLargeRetinaFirstContact(viewport: SpatialPoint) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("large-retina-input-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex()
    var hierarchy = try store.loadBoard(items: workspace.items)
    XCTAssertTrue(hierarchy.moveItem(workspace.selectedItemID, in: header.rootBoardID,
      to: .init(x: 100_000, y: 100_000), actor: actor))
    try store.saveBoard(hierarchy, items: workspace.items)
    let resources = SceneRenderResources(), tiles = SceneCompositionTiles(resources: resources)
    let queue = NotebookPersistenceQueue(store: store)
    let accepted = BudgetAcceptedInk(actor: actor, queue: queue)
    let gate = NotebookInputGate(), host = BudgetInputHost()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let mount = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: viewport.x, height: viewport.y))
    let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: tiles.surfaceRegistry, inputGate: gate) {
      accepted.append(tool: $0, color: $1, spans: $2)
    }
    let pressure = BudgetPinnedRasters()
    addTeardownBlock { @MainActor [weak coordinator] in
      coordinator?.uninstall(); mount.unmount(); mount.removeFromSuperview()
      window.isHidden = true; window.rootViewController = nil
      let saved = await queue.flush()
      XCTAssertTrue(saved, queue.failure ?? "")
      await tiles.stop(); pressure.release()
      XCTAssertEqual(resources.reservedBytes, 0, "Submitted native work must drain before temporary-store removal")
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(), viewport: viewport)
    let current = try store.workspaceHeader()
    let source = SceneCompositionSource(store: store, revision: current.cursor, workspaceID: current.workspaceID)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 2)
    let deadline = ContinuousClock.now + .seconds(5)
    while tiles.published == nil, tiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let cohort = try XCTUnwrap(tiles.published, tiles.failure ?? "The empty SQL board must prepare without a WebKit source")
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertTrue(cohort.frame.workset(boardID: header.rootBoardID).items.isEmpty)
    window.frame = mount.frame
    host.view.backgroundColor = .white
    window.rootViewController = host; host.view.addSubview(mount); window.makeKeyAndVisible()
    let appearanceDeadline = ContinuousClock.now + .seconds(5)
    while !host.appeared, ContinuousClock.now < appearanceDeadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(host.appeared)
    coordinator.update(view: mount, cohort: cohort, boardID: header.rootBoardID,
      camera: presence.camera, viewport: viewport, items: [], journal: accepted.journal,
      penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
      surfaceRegistry: tiles.surfaceRegistry, inputGate: gate, isItemBeingDeleted: { _ in false },
      admitsNewContact: { true }, isEnabled: true,
      onCommit: { accepted.append(tool: $0, color: $1, spans: $2) })
    let canvas = try XCTUnwrap(mount.inkView)
    XCTAssertTrue(canvas === tiles.surfaceRegistry.canvas(for: .board(header.rootBoardID)))
    XCTAssertTrue(canvas.window === window)
    XCTAssertEqual(canvas.committedVertexCount, 0)
    XCTAssertEqual(canvas.spatialDrawableAccountedBytes, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
    try pressure.fillPassiveHalf(resources)
    let beforeAdmission = resources.rasterAdmission
    XCTAssertEqual(beforeAdmission.pinnedBytes, resources.passiveByteLimit)
    XCTAssertEqual(beforeAdmission.passiveReservedBytes, 0)
    XCTAssertEqual(resources.byteLimit, 256 * 1024 * 1024)
    XCTAssertEqual(resources.passiveByteLimit, 128 * 1024 * 1024)

    let device = try XCTUnwrap(canvas.device), layer = try XCTUnwrap(canvas.layer as? CAMetalLayer)
    let width = Int(ceil(canvas.bounds.width * 2)), height = Int(ceil(canvas.bounds.height * 2))
    XCTAssertLessThanOrEqual(max(width, height), 4096, "This physical viewport may not silently lose its 2× input density")
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: canvas.colorPixelFormat,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private; descriptor.usage = .renderTarget
    let footprint = device.heapTextureSizeAndAlign(descriptor: descriptor)
    let aligned = ((footprint.size + footprint.align - 1) / footprint.align) * footprint.align
    let rowFloor = ((width * 4 + 255) / 256) * 256 * height
    let drawableFootprint = max(aligned, rowFloor)
    var multisampleFootprint = 0
    if device.supportsTextureSampleCount(4), !device.supportsFamily(.apple1) {
      descriptor.textureType = .type2DMultisample; descriptor.sampleCount = 4
      let footprint = device.heapTextureSizeAndAlign(descriptor: descriptor)
      multisampleFootprint = ((footprint.size + footprint.align - 1) / footprint.align) * footprint.align
    }
    let targetBytes = drawableFootprint * layer.maximumDrawableCount + multisampleFootprint
    let inputRoom = resources.byteLimit - beforeAdmission.heldBytes
    let before = capture(mount), beforePixels = try blackPixelCount(before)
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = BudgetPencilTouch(window: window), event = UIEvent()
    let first = CGPoint(x: 100, y: 200), last = CGPoint(x: 700, y: 230)
    touch.point = first; pencil.touchesBegan([touch], with: event)
    XCTAssertTrue(gate.hasActivePencil)
    touch.point = last; touch.sampleTime += 0.1; pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    XCTAssertFalse(gate.hasActivePencil)
    let action = try XCTUnwrap(accepted.journal.actions.last)
    XCTAssertEqual(action.spans.first?.surface, .board(header.rootBoardID))
    let actual = try XCTUnwrap(action.spans.first?.samples.first?.worldPoint)
    let expected = presence.camera.screenToWorld(.init(x: first.x, y: first.y), viewport: viewport)
    XCTAssertEqual(expected.delta(to: actual).x, 0, accuracy: 0.00001)
    XCTAssertEqual(expected.delta(to: actual).y, 0, accuracy: 0.00001)
    let frameDeadline = ContinuousClock.now + .seconds(5)
    while !canvas.isStableFramePresented, canvas.renderFailure == nil, ContinuousClock.now < frameDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let after = capture(mount), afterPixels = try blackPixelCount(after)
    let report = "viewport=\(viewport); nativeBounds=\(canvas.bounds.size); requestedPixels=\(width)x\(height); "
      + "device=\(device.name); heapSize=\(footprint.size); heapAlign=\(footprint.align); rowFloor=\(rowFloor); "
      + "drawableCount=\(layer.maximumDrawableCount); targetBytes=\(targetBytes); inputRoom=\(inputRoom); "
      + "passivePinned=\(beforeAdmission.pinnedBytes); actualDrawable=\(canvas.drawableSize); "
      + "admittedBytes=\(canvas.spatialDrawableAccountedBytes); nativeReserved=\(resources.reservedBytes); "
      + "blackBefore=\(beforePixels); blackAfter=\(afterPixels); failure=\(String(describing: canvas.renderFailure)); UUID=\(action.id)"
    let receipt = XCTAttachment(string: report); receipt.name = "large-retina-first-contact-descriptor"; receipt.lifetime = .keepAlways; add(receipt)
    for (name, image) in [("large-retina-before", before), ("large-retina-first-line", after)] {
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    XCTAssertLessThan(targetBytes, inputRoom, "The actual Metal descriptor must leave room for the first contact's geometry. " + report)
    XCTAssertNil(canvas.renderFailure, report)
    XCTAssertEqual(canvas.spatialDrawableAccountedBytes, targetBytes, report)
    XCTAssertEqual(canvas.drawableSize.width / canvas.bounds.width, 2, accuracy: 0.001, report)
    XCTAssertEqual(canvas.drawableSize.height / canvas.bounds.height, 2, accuracy: 0.001, report)
    XCTAssertGreaterThan(canvas.committedVertexCount, 0)
    XCTAssertGreaterThan(afterPixels - beforePixels, 100, "A persisted action is not a rendered first line. " + report)
    XCTAssertTrue(tiles.published === cohort)
    XCTAssertTrue(try XCTUnwrap(canvas.installedSpatialSource).referenceInk().actions.contains { $0.id == action.id })
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, beforeAdmission.pinnedBytes, "Input cannot revoke the old picture's pins")
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit, report)
    let saved = await queue.flush()
    XCTAssertTrue(saved, queue.failure ?? "")
    let boardID = header.rootBoardID
    let durable = try await queue.submit { try $0.readSpatialInk(surfaces: [.board(boardID)]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)
  }

  func testColdDenseRetinaBoardRendersAndPersistsItsFirstPencilContactUnderSharedRasterPressure() async throws {
    let resources = SceneRenderResources.shared
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0,
      "This cold-input test must not mistake a leaked previous scene for its own passive raster pressure")
    XCTAssertEqual(resources.reservedBytes, 0)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cold-ink-budget-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView())
      host.view.layoutIfNeeded()
      window.isHidden = true; window.rootViewController = nil
      let stopped = await model.shutdown()
      XCTAssertTrue(stopped, model.persistenceFailure ?? "The test writer must stop before its temporary store is removed")
      if stopped { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let moved = await model.finishPendingPersistence()
    XCTAssertTrue(moved, model.persistenceFailure ?? "")

    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let elementIDs = (0..<7).map { "cold-input-panel-\($0)" }
    for (offset, id) in elementIDs.enumerated() {
      // Seven real 1024² transparent sources ask the ordinary planner for
      // dense passive coverage at 2×. Its finite demotion policy remains free
      // to choose a cheaper complete representation; the pen must still work.
      let x = 30 + offset * 120
      let element = SpatialElement(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 1024, height: 1024), worldOrigin: .zero,
        source: "Passive panel \(offset)",
        html: "<svg width='100%' height='100%' viewBox='0 0 1024 1024'><rect width='1024' height='1024' fill='#d8e8f0' fill-opacity='.12'/><path d='M \(x) 30 V 994' stroke='#b8d4e8' stroke-width='5'/></svg>",
        stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(hierarchy.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    }
    let prepared = hierarchy, items = try XCTUnwrap(model.workspace?.items)
    try await model.performStoreCommand { try $0.saveBoard(prepared, items: items) }
    await model.reloadExternalChanges()?.value
    let readyStore = await model.finishPendingPersistence()
    XCTAssertTrue(readyStore, model.persistenceFailure ?? "")
    let viewport = SpatialPoint(x: 834, y: 1194)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 512, y: 512), scale: 1), viewport: viewport)
    window.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host
    model.updatePresence(presence, settled: true)
    window.makeKeyAndVisible()
    let deadline = ContinuousClock.now + .seconds(15)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    var cohort = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "The complete dense scene must precede the first contact")
    XCTAssertEqual(Set(cohort.frame.workset(boardID: boardID).elements.map(\.id)), Set(elementIDs))
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertTrue(cohort.rasters.values.allSatisfy { !$0.isReleased })
    let canvas = try XCTUnwrap(cohort.nativeInk.registry.canvas(for: .board(boardID)))
    while canvas.window == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNotNil(canvas.window)
    XCTAssertEqual(canvas.committedVertexCount, 0)
    XCTAssertTrue(try XCTUnwrap(canvas.installedSpatialSource).referenceInk().actions.isEmpty)
    let accountingBefore = resources.rasterAdmission
    let before = capture(host.view)
    let beforePixels = try blackPixelCount(before)
    let previousRequests = canvas.drawableRequestCount
    let blocker = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? blocker.release() }

    // A real writer barrier prevents a later canonical scene revision from
    // retroactively rescuing the first live frame. It does not delay Pencil.
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = BudgetPencilTouch(window: window), event = UIEvent()
    let first = CGPoint(x: 100, y: 200), last = CGPoint(x: 700, y: 230)
    touch.point = first; pencil.touchesBegan([touch], with: event)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    touch.point = last; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event); pencil.touchesEnded([touch], with: event)
    XCTAssertFalse(model.inputGate.hasActivePencil)
    let action = try XCTUnwrap(model.spatialInk?.actions.last)
    XCTAssertEqual(action.spans.first?.surface, .board(boardID))
    let actual = try XCTUnwrap(action.spans.first?.samples.first?.worldPoint)
    let expected = presence.camera.screenToWorld(.init(x: first.x, y: first.y), viewport: viewport)
    XCTAssertEqual(expected.delta(to: actual).x, 0, accuracy: 0.00001)
    XCTAssertEqual(expected.delta(to: actual).y, 0, accuracy: 0.00001)
    XCTAssertGreaterThan(canvas.committedVertexCount, 0)
    let frameDeadline = ContinuousClock.now + .seconds(5)
    while !canvas.isStableFramePresented, canvas.renderFailure == nil, ContinuousClock.now < frameDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let after = capture(host.view)
    let afterPixels = try blackPixelCount(after)
    let report = "passivePinned=\(accountingBefore.pinnedBytes); otherReserved=\(accountingBefore.reservedBytes); "
      + "live=\(cohort.plan.liveOwners.count); tiles=\(cohort.plan.tiles.count); "
      + "nativeBounds=\(canvas.bounds.size); drawable=\(canvas.drawableSize); "
      + "drawableBytes=\(canvas.spatialDrawableAccountedBytes); renderFailure=\(String(describing: canvas.renderFailure)); "
      + "blackBefore=\(beforePixels); blackAfter=\(afterPixels); accepted=\(action.id)"
    let receipt = XCTAttachment(string: report); receipt.name = "cold-retina-first-pencil-byte-admission"; receipt.lifetime = .keepAlways; add(receipt)
    for (name, image) in [("cold-dense-before-pencil", before), ("cold-dense-first-pencil", after)] {
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    XCTAssertNil(canvas.renderFailure, report)
    XCTAssertGreaterThan(canvas.drawableRequestCount, previousRequests, report)
    XCTAssertEqual(canvas.drawableSize.width / canvas.bounds.width, 2, accuracy: 0.001, report)
    XCTAssertEqual(canvas.drawableSize.height / canvas.bounds.height, 2, accuracy: 0.001, report)
    XCTAssertGreaterThan(afterPixels - beforePixels, 100,
      "Accepted CPU geometry and a successful SQL write do not substitute for the visible first line. " + report)
    XCTAssertTrue(model.compositionTiles.published === cohort)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)

    try blocker.release()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let durable = try await model.performStoreCommand { try $0.readSpatialInk(surfaces: [.board(boardID)]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)

    // The protected input allowance cannot strand the old dense picture.
    // First reconcile the committed stroke, then change a real raster source.
    // The current complete picture stays pinned while each successor prepares.
    for revision in 0..<2 {
      if revision > 0 {
        let element = try XCTUnwrap(model.sceneIndex?.element(id: elementIDs[0], boardID: boardID))
        model.commitSpatialElementState(boardID: boardID, rendered: element, state: .object(["revision": .number(1)]))
        let stateSaved = await model.finishPendingPersistence()
        XCTAssertTrue(stateSaved, model.persistenceFailure ?? "")
      }
      let cursor = try await model.performStoreCommand { try $0.workspaceHeader().cursor }
      let replacementDeadline = ContinuousClock.now + .seconds(15)
      while (model.compositionTiles.published?.plan.revision != cursor
        || model.compositionTiles.isPreparing || model.scenePreparationPending),
        model.compositionTiles.failure == nil, ContinuousClock.now < replacementDeadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertNil(model.compositionTiles.failure,
        "A whole successor must fit while its predecessor remains visible; dense revision \(revision)")
      let replacement = try XCTUnwrap(model.compositionTiles.published)
      XCTAssertEqual(replacement.plan.revision, cursor)
      XCTAssertEqual(Set(replacement.frame.workset(boardID: boardID).elements.map(\.id)), Set(elementIDs))
      XCTAssertTrue(replacement.nativeInk.registry.canvas(for: .board(boardID)) === canvas)
      XCTAssertTrue(replacement.rasters.values.allSatisfy { !$0.isReleased })
      if revision > 0 {
        XCTAssertEqual(replacement.frame.index.element(id: elementIDs[0], boardID: boardID)?.state,
          .object(["revision": .number(1)]))
      }
      cohort = replacement
      XCTAssertGreaterThan(try blackPixelCount(capture(host.view)) - beforePixels, 100,
        "Replacing passive content must preserve the first line's actual pixels")
      XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    }
  }

  private func capture(_ view: UIView) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(view.bounds)
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
  }
  private func blackPixelCount(_ image: UIImage) throws -> Int {
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return stride(from: 0, to: cg.width * cg.height * 4, by: 4).filter {
      bytes[$0] < 90 && bytes[$0 + 1] < 90 && bytes[$0 + 2] < 90 && bytes[$0 + 3] > 200
    }.count
  }
}

@MainActor
private final class BudgetAcceptedInk {
  let actor: UUID, queue: NotebookPersistenceQueue
  var journal: SpatialInkJournal
  init(actor: UUID, queue: NotebookPersistenceQueue) {
    self.actor = actor; self.queue = queue
    journal = .init(stamp: .init(counter: 0, actor: actor))
  }
  func append(tool: SpatialInkTool, color: SpatialInkColor, spans: [SpatialInkSpan]) -> SpatialInkAction? {
    guard let action = journal.append(tool: tool, color: color, spans: spans, actor: actor) else { return nil }
    let command = NotebookSpatialInkCommand.append(action, journalStamp: journal.stamp)
    queue.enqueue(owner: .spatialInk(action.id)) { _ = try $0.commitSpatialInk(command); return false }
    return action
  }
}

@MainActor
private final class BudgetPinnedRasters {
  private var leases: [RasterLease] = []
  func fillPassiveHalf(_ resources: SceneRenderResources) throws {
    while resources.rasterAdmission.pinnedBytes < resources.passiveByteLimit {
      let remaining = resources.passiveByteLimit - resources.rasterAdmission.pinnedBytes
      let width = 512, height = min(512, remaining / (width * 4 * 2))
      guard height > 0 else { XCTFail("The real raster pressure must exactly cover the passive half"); return }
      let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: width, pixelHeight: height))
      let image: UIImage = try autoreleasepool {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor(red: CGFloat(leases.count % 7) / 8, green: 0.6, blue: 0.9, alpha: 1).cgColor)
        context.fill(.init(x: 0, y: 0, width: width, height: height))
        return UIImage(cgImage: try XCTUnwrap(context.makeImage()), scale: 1, orientation: .up)
      }
      let source = AgentElement(id: "retained-passive-\(leases.count)", kind: .web,
        frame: .init(x: 0, y: 0, width: Double(width), height: Double(height)), source: "Prepared passive pixels", html: "<svg/>")
      XCTAssertTrue(resources.store(image, for: source, reservation: reservation))
      leases.append(try XCTUnwrap(resources.retainRaster(for: source)))
    }
    XCTAssertTrue(leases.allSatisfy { !$0.isReleased })
  }
  func release() { leases.forEach { $0.release() }; leases.removeAll() }
}

@MainActor
private final class BudgetInputHost: UIViewController {
  private(set) var appeared = false
  override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
}

@MainActor
private final class BudgetPencilTouch: UITouch {
  weak var sourceWindow: UIWindow?
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint {
    guard let view, let sourceWindow else { return point }
    return view.convert(point, from: sourceWindow)
  }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
