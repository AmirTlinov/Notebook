import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class SceneCameraPlaneTests: XCTestCase {
  @MainActor
  func testConditionalParentUnmountRetiresTheNestedPoseDisplayList() async throws {
    try await assertNestedPoseUnmount(animated: false)
  }

  @MainActor
  func testAnimatedParentUnmountRetiresTheNestedPoseDisplayList() async throws {
    try await assertNestedPoseUnmount(animated: true)
  }

  @MainActor
  private func assertNestedPoseUnmount(animated: Bool) async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nested-pose-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let boardID = UUID(), itemID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(scale: 0.3), viewport: .init(x: 512, y: 512))
    let state = ScenePlaneLifetimeState()
    state.cohort = try await WorkspaceInkFixture.prepare(boardID: boardID,
      camera: presence.camera, viewport: presence.viewport,
      items: [.init(itemID: itemID, geometry: .notebook, center: .zero, zIndex: 0)],
      registry: registry, resources: resources)
    weak let retired = state.cohort
    let host = UIHostingController(rootView: ScenePlaneNestedPoseLifetimeHost(state: state,
      presence: presence, itemID: itemID, registry: registry).environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 512, height: 512)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForLifetime { self.nestedPose(in: host) != nil }
    let pose = try XCTUnwrap(nestedPose(in: host))
    let inner = try XCTUnwrap(pose.children.first as? UIHostingController<AnyView>)
    XCTAssertNotNil(pose.screenSurface(in: host.view))
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)

    // SwiftUI dismantles the nested pose while it is updating the camera's
    // parent graph. A direct call to pose.uninstall is not this lifecycle.
    if animated {
      withAnimation(.easeOut(duration: 0.2)) { state.cohort = nil }
    } else { state.cohort = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    try await waitForLifetime { pose.isContentReleased }
    XCTAssertTrue(pose.isContentReleased)
    XCTAssertNil(pose.handle.owner)
    XCTAssertTrue(pose.children.isEmpty)
    try await waitForLifetime { retired == nil && resources.rasterAdmission.pinnedBytes == 0 }
    withExtendedLifetime((host, inner, pose)) {
      XCTAssertNil(retired)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0,
        "The retired nested display list cannot retain a cohort after its actual parent branch unmount")
    }
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  private func nestedPose(in root: UIViewController) -> WorkspaceItemPoseController? {
    if let pose = root as? WorkspaceItemPoseController { return pose }
    return root.children.lazy.compactMap { self.nestedPose(in: $0) }.first
  }

  @MainActor
  func testTerminalCameraHostRetiresItsDisplayListWhileUIKitKeepsTheInnerHost() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry()
    var cohort: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: UUID(),
      camera: .init(), viewport: .init(x: 256, y: 256), items: [], registry: registry, resources: resources)
    var raster: RasterLease? = try XCTUnwrap(cohort?.rasters.values.first?.retainedCopy())
    weak let retiredRaster = raster
    cohort = nil
    let parent = UIViewController(), controller = SceneCameraPlaneController<Int>()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = parent; window.makeKeyAndVisible()
    parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
    controller.view.frame = parent.view.bounds
    defer { controller.uninstall(); window.isHidden = true; window.rootViewController = nil }
    let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 256, y: 256))
    controller.update(presence: presence, revision: 1) { _, _ in
      AnyView(AgentElementSnapshotView(raster: raster!).frame(width: 256, height: 256))
    }
    window.layoutIfNeeded()
    let innerHost = try XCTUnwrap(controller.children.first)
    let native = try XCTUnwrap(snapshotView(in: controller.contentView))
    XCTAssertNotNil(native.layer.contents, "The regression must first install an actual raster in the display list")
    raster = nil
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)
    controller.uninstall()
    try await waitForLifetime { retiredRaster == nil && resources.rasterAdmission.pinnedBytes == 0 }
    withExtendedLifetime((innerHost, native)) {
      XCTAssertTrue(controller.isRetired)
      XCTAssertNil(native.layer.contents)
      XCTAssertNil(retiredRaster)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0,
        "Keeping UIKit's retired inner host cannot keep its former display-list capture")
    }
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testTerminalPoseRetiresItsDisplayListOnlyAfterTheAcceptedLeaseEnds() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry(), gate = NotebookInputGate()
    let boardID = UUID(), itemID = UUID()
    var cohort: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: boardID,
      camera: .init(), viewport: .init(x: 512, y: 512),
      items: [.init(itemID: itemID, geometry: .notebook, center: .zero, zIndex: 0)],
      registry: registry, resources: resources)
    var raster: RasterLease? = try XCTUnwrap(cohort?.rasters.values.first?.retainedCopy())
    weak let retiredRaster = raster
    let rendered = try XCTUnwrap(cohort?.frame.workset(boardID: boardID).items.first { $0.id == itemID })
    let parent = UIViewController(), controller = WorkspaceItemPoseController()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 512, height: 512)
    window.rootViewController = parent; window.makeKeyAndVisible()
    parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
    controller.view.frame = parent.view.bounds
    defer { controller.uninstall(); window.isHidden = true; window.rootViewController = nil }
    controller.update(rendered: rendered, camera: .init(), viewport: .init(x: 512, y: 512),
      boardID: boardID, cohortID: cohort?.id, cohortRevision: cohort?.plan.revision,
      sourceBoard: cohort?.frame.index.board(id: boardID), publishedLiftRank: nil, projection: nil,
      registry: registry, inputGate: gate, onLiftChanged: { _ in }, onDrop: { _ in nil },
      content: AnyView(AgentElementSnapshotView(raster: raster!)
        .frame(width: rendered.geometry.width, height: rendered.geometry.height)))
    window.layoutIfNeeded()
    let innerHost = try XCTUnwrap(controller.children.first)
    let native = try XCTUnwrap(snapshotView(in: controller.contentView))
    XCTAssertNotNil(native.layer.contents)
    let contact = try XCTUnwrap(controller.acquirePose(in: parent.view))
    let shownBytes = try XCTUnwrap(raster).accountedByteCount
    raster = nil; cohort = nil
    controller.uninstall()
    XCTAssertFalse(controller.isContentReleased)
    XCTAssertNotNil(native.layer.contents, "Accepted input still owns the shown body until its last lease ends")
    XCTAssertNil(retiredRaster, "The native presenter owns its independent lease, not the expired configuration")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, shownBytes)
    contact.release()
    try await waitForLifetime { retiredRaster == nil && resources.rasterAdmission.pinnedBytes == 0 }
    withExtendedLifetime((innerHost, native)) {
      XCTAssertTrue(controller.isContentReleased)
      XCTAssertNil(native.layer.contents)
      XCTAssertNil(retiredRaster)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    }
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  private func snapshotView(in view: UIView) -> AgentSnapshotRasterView? {
    (view as? AgentSnapshotRasterView) ?? view.subviews.lazy.compactMap { self.snapshotView(in: $0) }.first
  }

  @MainActor
  func testShutdownRetiresNativeOwnersBeforeTheExternalHostReleasesItsContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scene-terminal-\(UUID())")
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 100, height: 140))
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: .init(width: 100, height: 140))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    try await waitForLifetime { model.sceneIndex != nil && !model.scenePreparationPending }
    let index = try XCTUnwrap(model.sceneIndex), header = try XCTUnwrap(model.workspaceHeader)
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(scale: 1),
      viewport: .init(x: 256, y: 256))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: model.scenePortalCamera)
    let resources = SceneRenderResources.shared
    let baseline = resources.rasterAdmission.pinnedBytes
    model.compositionTiles.prepare(source: .init(store: store, revision: header.cursor, workspaceID: header.workspaceID),
      presence: presence, frame: frame, pinned: [], displayScale: 1)
    try await waitForLifetime { model.compositionTiles.published != nil }
    weak let latest = model.compositionTiles.published
    var host: UIViewController? = try borrowingHost(model: model, presence: presence)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; host = nil }
    try await waitForLifetime {
      host.flatMap { self.planeController(in: $0) }?.contentPublicationCount == 1
    }
    var controller: SceneCameraPlaneController<UUID>? = try XCTUnwrap(
      host.flatMap { self.planeController(in: $0) })
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, baseline)

    window.isHidden = true; window.rootViewController = nil
    // This external hosting root explicitly borrows the immutable cohort. The
    // model must retire its own native content without revoking another owner's
    // pixels. No root replacement, forced layout or extra frame delivers the ACK.
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    XCTAssertEqual(model.shutdownPhase, .stopped)
    XCTAssertNil(model.compositionTiles.published)
    XCTAssertTrue(controller?.isRetired == true,
      "The final ACK must directly retire even an offscreen native owner")
    withExtendedLifetime(host) {
      XCTAssertNotNil(latest, "The explicitly retained hosting root is still a legitimate raster borrower")
      XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, baseline)
      XCTAssertTrue(latest?.rasters.values.allSatisfy { !$0.isReleased } == true,
        "Shutdown cannot revoke the raster lease held by an external content owner")
      XCTAssertEqual(resources.reservedBytes, 0)
    }

    // Relinquish every UI holder owned by this test. UIKit's removal boundary is
    // not permission for model.shutdown to invalidate a still-borrowed image.
    controller = nil
    host = nil
    try await waitForLifetime { latest == nil && resources.rasterAdmission.pinnedBytes == baseline }
    XCTAssertNil(latest)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, baseline)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  private func borrowingHost(model: NotebookAppModel, presence: SessionPresence) throws -> UIViewController {
    let cohort = try XCTUnwrap(model.compositionTiles.published)
    return UIHostingController(rootView: SceneBorrowedLifetimeHost(cohort: cohort, presence: presence)
      .environment(model))
  }

  @MainActor
  func testConditionalSwiftUIUnmountReleasesTheLastCohortWhileUIKitRetainsTheController() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry()
    let boardID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 1),
      viewport: .init(x: 256, y: 256))
    let state = ScenePlaneLifetimeState()
    state.cohort = try await WorkspaceInkFixture.prepare(boardID: boardID, camera: presence.camera,
      viewport: presence.viewport, items: [], registry: registry, resources: resources)
    let host = UIHostingController(rootView: ScenePlaneLifetimeHost(state: state, presence: presence))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitForLifetime { self.planeController(in: host) != nil }
    let controller = try XCTUnwrap(planeController(in: host))
    try await waitForLifetime { controller.contentPublicationCount == 1 }
    state.cohort = try await WorkspaceInkFixture.prepare(boardID: boardID, camera: presence.camera,
      viewport: presence.viewport, items: [], registry: registry, resources: resources)
    weak let latest = state.cohort
    try await waitForLifetime { controller.contentPublicationCount == 2 }
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)

    // Remove the real SceneCameraPlane branch, not the outer root or its UIKit
    // cache. A retained controller is legitimate; retained retired paint is not.
    state.cohort = nil
    try await waitForLifetime { controller.isRetired && latest == nil && resources.rasterAdmission.pinnedBytes == 0 }
    XCTAssertTrue(controller.isRetired)
    XCTAssertNil(latest)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    var rebuilt = false
    controller.update(presence: presence, revision: UUID()) { _, _ in rebuilt = true; return AnyView(Color.red) }
    controller.uninstall()
    XCTAssertFalse(rebuilt, "A terminally dismantled native owner cannot remount old content through a late callback")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testTerminalPoseReleasesItsContentOnlyAfterTheLastAcceptedLease() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry(), gate = NotebookInputGate()
    let boardID = UUID(), itemID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 0.3),
      viewport: .init(x: 512, y: 512))
    var cohort: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: boardID,
      camera: presence.camera, viewport: presence.viewport,
      items: [.init(itemID: itemID, geometry: .notebook, center: .zero, zIndex: 0)],
      registry: registry, resources: resources)
    weak let retiredCohort = cohort
    let parent = UIViewController(), controller = WorkspaceItemPoseController()
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 512, height: 512)
    window.rootViewController = parent; window.makeKeyAndVisible()
    parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
    defer { controller.uninstall(); window.isHidden = true; window.rootViewController = nil }
    let rendered = try XCTUnwrap(cohort?.frame.workset(boardID: boardID).items.first { $0.id == itemID })
    controller.update(rendered: rendered, camera: presence.camera, viewport: presence.viewport,
      boardID: boardID, cohortID: cohort?.id, cohortRevision: cohort?.plan.revision,
      sourceBoard: cohort?.frame.index.board(id: boardID), publishedLiftRank: nil, projection: nil,
      registry: registry, inputGate: gate, onLiftChanged: { _ in }, onDrop: { _ in nil },
      content: AnyView(ScenePlaneLifetimeContent(cohort: try XCTUnwrap(cohort), presence: presence)))
    parent.view.layoutIfNeeded()
    let first = try XCTUnwrap(controller.acquirePose(in: parent.view))
    let second = try XCTUnwrap(controller.acquirePose(in: parent.view))
    cohort = nil
    controller.uninstall(); controller.uninstall()
    XCTAssertFalse(controller.isContentReleased)
    XCTAssertNotNil(retiredCohort)
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)
    first.release()
    XCTAssertFalse(controller.isContentReleased, "The second accepted lease still owns the measured body")
    XCTAssertEqual(first.surface, second.surface)
    second.release()
    try await waitForLifetime { controller.isContentReleased && retiredCohort == nil && resources.rasterAdmission.pinnedBytes == 0 }
    XCTAssertTrue(controller.isContentReleased)
    XCTAssertNil(retiredCohort)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    second.release(); controller.uninstall()
    controller.update(rendered: rendered, camera: presence.camera, viewport: presence.viewport,
      boardID: boardID, cohortID: UUID(), cohortRevision: 999, sourceBoard: nil,
      publishedLiftRank: nil, projection: nil, registry: registry, inputGate: gate,
      onLiftChanged: { _ in XCTFail("A retired callback cannot run") }, onDrop: { _ in nil }, content: AnyView(Color.red))
    XCTAssertTrue(controller.isContentReleased)
    XCTAssertNil(controller.handle.owner)
    XCTAssertNil(controller.screenSurface(in: parent.view))
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  private func planeController(in root: UIViewController) -> SceneCameraPlaneController<UUID>? {
    if let controller = root as? SceneCameraPlaneController<UUID> { return controller }
    return root.children.lazy.compactMap { self.planeController(in: $0) }.first
  }

  @MainActor
  private func waitForLifetime(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(condition(), "The dismantled content must relinquish its owner within the ordinary UI update")
  }

  func testOneMatrixPreservesWorldPointsAcrossFractionalCameraAndTiledCoordinates() {
    for center in [WorldPoint.zero, .init(tileX: 9_000_000_000_000, tileY: -9_000_000_000_000, localX: 91.3, localY: 107.6)] {
      let anchor = SessionPresence(mode: .board, camera: .init(center: center, scale: 0.371),
        viewport: .init(x: 1194, y: 834))
      for scale in [0.0125, 0.0371, 0.371, 0.6789, 1.39] {
        let current = SessionPresence(mode: .board,
          camera: .init(center: center.offsetBy(x: 531.3, y: -94.19), scale: scale),
          viewport: .init(x: 834, y: 1194))
        let matrix = SceneCameraProjection(anchor: anchor, current: current)
        for offset in [-514.2, -0.03, 0, 792.5] {
          let point = center.offsetBy(x: offset, y: offset * -0.72)
          let mapped = matrix.project(anchor.camera.worldToScreen(point, viewport: anchor.viewport))
          let expected = current.camera.worldToScreen(point, viewport: current.viewport)
          XCTAssertEqual(mapped.x, expected.x, accuracy: 0.000_000_1)
          XCTAssertEqual(mapped.y, expected.y, accuracy: 0.000_000_1)
        }
      }
    }
  }

  @MainActor
  func testCameraChangesOneNativeTransformWithoutReplacingContentOrBounds() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    let controller = SceneCameraPlaneController<Int>()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let initial = SessionPresence(mode: .board, camera: .init(scale: 0.05), viewport: .init(x: 1194, y: 834))
    var builds = 0
    var handlerProjection: ScenePlaneProjection?
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      builds += 1
      handlerProjection = projection
      return AnyView(Color.red.frame(width: 20, height: 30)
        .position(x: 391, y: 284).frame(width: anchor.viewport.x, height: anchor.viewport.y))
    }
    controller.update(presence: initial, revision: 1, content: content)
    let view = controller.contentView
    for i in 0..<400 {
      let scale = 0.05 + Double(i % 170) / 100
      let current = SessionPresence(mode: .board,
        camera: .init(center: .init(x: Double(i) * 0.31, y: Double(i) * -0.14), scale: scale),
        viewport: initial.viewport)
      controller.update(presence: current, revision: 1, isCameraActive: true, content: content)
      XCTAssertEqual(view.bounds, CGRect(x: 0, y: 0, width: 1194, height: 834))
      let screen = view.convert(CGPoint(x: 391, y: 284), to: controller.view)
      let expected = SceneCameraProjection(anchor: initial, current: current).project(.init(x: 391, y: 284))
      XCTAssertEqual(screen.x - controller.view.bounds.minX, expected.x, accuracy: 0.0001)
      XCTAssertEqual(screen.y - controller.view.bounds.minY, expected.y, accuracy: 0.0001)
      XCTAssertEqual(handlerProjection?.current, current)
    }
    XCTAssertEqual(builds, 1)
    XCTAssertEqual(controller.contentPublicationCount, 1)
    XCTAssertEqual(controller.cameraProjectionCount, 401)
    controller.update(presence: initial, revision: 2, content: content)
    XCTAssertEqual(builds, 2, "A content revision, not a camera sample, updates the root")
    XCTAssertTrue(view === controller.contentView)
  }

  @MainActor
  func testFarJumpRebasesBeforeSubtractingUnrelatedWorldTiles() {
    let controller = SceneCameraPlaneController<Int>()
    let viewport = SpatialPoint(x: 1194, y: 834)
    let first = SessionPresence(mode: .board,
      camera: .init(center: .init(tileX: Int64.min + 100, tileY: 0, localX: 0, localY: 0), scale: 0.4), viewport: viewport)
    let last = SessionPresence(mode: .board,
      camera: .init(center: .init(tileX: Int64.max - 100, tileY: 0, localX: 0, localY: 0), scale: 0.4), viewport: viewport)
    var anchors: [WorldPoint] = []
    for presence in [first, last] {
      controller.update(presence: presence, revision: 1, reanchorsOnRevision: false) { anchor, _ in
        anchors.append(anchor.camera.center)
        return AnyView(Color.clear)
      }
    }
    XCTAssertEqual(anchors, [first.camera.center, last.camera.center])
    let screen = controller.contentView.convert(CGPoint(x: viewport.x / 2, y: viewport.y / 2), to: controller.view)
    XCTAssertEqual(screen.x - controller.view.bounds.minX, viewport.x / 2, accuracy: 0.0001)
    XCTAssertEqual(screen.y - controller.view.bounds.minY, viewport.y / 2, accuracy: 0.0001)
  }
  @MainActor
  func testSettlingCameraRebasesInputOnceAndPreservesVisibleGeometry() {
    let controller = SceneCameraPlaneController<Int>()
    let initial = SessionPresence(mode: .board, camera: .init(scale: 1), viewport: .init(x: 1194, y: 834))
    let nearby = SessionPresence(mode: .board, camera: .init(center: .init(x: 1190, y: 0), scale: 1), viewport: initial.viewport)
    let outside = SessionPresence(mode: .board, camera: .init(center: .init(x: 1200, y: 0), scale: 1), viewport: initial.viewport)
    var anchors: [WorldPoint] = []
    for (presence, active) in [(initial, false), (nearby, true), (outside, true), (outside, false), (outside, false)] {
      controller.update(presence: presence, revision: 1, reanchorsOnRevision: false, isCameraActive: active) { anchor, _ in
        anchors.append(anchor.camera.center)
        return AnyView(Color.clear)
      }
    }
    XCTAssertEqual(anchors, [initial.camera.center, outside.camera.center])
    let preparedCenter = CGPoint(x: initial.viewport.x / 2, y: initial.viewport.y / 2)
    let screen = controller.contentView.convert(preparedCenter, to: controller.view)
    XCTAssertEqual(screen.x - controller.view.bounds.minX, initial.viewport.x / 2, accuracy: 0.0001)
    XCTAssertEqual(screen.y - controller.view.bounds.minY, initial.viewport.y / 2, accuracy: 0.0001)
  }

  @MainActor
  func testPreviouslyOffscreenNativeControlReceivesInputAfterCameraPan() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
    let controller = SceneCameraPlaneController<Int>()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; oldKeyWindow?.makeKey() }
    let button = UIButton(type: .system)
    button.setTitle("Control", for: .normal)
    let initial = SessionPresence(mode: .board, camera: .init(scale: 1), viewport: .init(x: 1194, y: 834))
    func content(_ anchor: SessionPresence, _ projection: ScenePlaneProjection) -> AnyView {
      let position = anchor.camera.worldToScreen(.init(x: 693, y: 0), viewport: anchor.viewport)
      return AnyView(ScenePlaneProbeControl(button: button).frame(width: 100, height: 50)
        .position(x: position.x, y: position.y).frame(width: anchor.viewport.x, height: anchor.viewport.y))
    }
    controller.update(presence: initial, revision: 1, content: content)
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let current = SessionPresence(mode: .board, camera: .init(center: .init(x: 500, y: 0), scale: 1), viewport: initial.viewport)
    controller.update(presence: current, revision: 1, isCameraActive: true, content: content)
    XCTAssertEqual(controller.contentPublicationCount, 1)
    controller.update(presence: current, revision: 1, isCameraActive: false, content: content)
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let point = button.convert(CGPoint(x: 50, y: 25), to: controller.view)
    XCTAssertEqual(point.x - controller.view.bounds.minX, 790, accuracy: 1)
    XCTAssertTrue(controller.view.bounds.contains(point))
    let hit = controller.view.hitTest(point, with: nil)
    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
      "The visible control must own its native input, not the prepared viewport bounds: \(String(describing: hit))")
    XCTAssertEqual(controller.contentPublicationCount, 2)
  }

}

@MainActor
private final class ScenePlaneLifetimeState: ObservableObject {
  @Published var cohort: SceneCompositionCohort?
}

private struct ScenePlaneLifetimeHost: View {
  @ObservedObject var state: ScenePlaneLifetimeState
  let presence: SessionPresence
  var body: some View {
    if let cohort = state.cohort {
      SceneCameraPlane(presence: presence, revision: cohort.id) { anchor in
        ScenePlaneLifetimeContent(cohort: cohort, presence: anchor)
      }
    } else { Color.clear }
  }
}

private struct ScenePlaneNestedPoseLifetimeHost: View {
  @ObservedObject var state: ScenePlaneLifetimeState
  let presence: SessionPresence
  let itemID: UUID
  let registry: SpatialInkSurfaceRegistry
  var body: some View {
    if let cohort = state.cohort,
      let rendered = cohort.frame.workset(boardID: presence.boardID).items.first(where: { $0.id == itemID }) {
      SceneCameraPlane(presence: presence, revision: cohort.id) { anchor in
        WorkspaceItemPose(rendered: rendered, camera: anchor.camera, viewport: anchor.viewport,
          boardID: presence.boardID, liftRank: nil, registry: registry,
          onLiftChanged: { _ in }, onDrop: { _ in nil }) {
            ScenePlaneLifetimeContent(cohort: cohort, presence: anchor)
              .frame(width: rendered.geometry.width, height: rendered.geometry.height)
          }
      }
      .environment(\.workspaceSceneFrame, cohort.frame)
      .environment(\.sceneComposition, .init(cohort))
    } else { Color.clear }
  }
}

private struct SceneBorrowedLifetimeHost: View {
  let cohort: SceneCompositionCohort
  let presence: SessionPresence
  var body: some View {
    SceneCameraPlane(presence: presence, revision: cohort.id) { anchor in
      ScenePlaneLifetimeContent(cohort: cohort, presence: anchor)
    }
  }
}

private struct ScenePlaneLifetimeContent: View {
  let cohort: SceneCompositionCohort
  let presence: SessionPresence
  var body: some View {
    ZStack {
      ForEach(cohort.bands(in: .board(presence.boardID), layer: .elements)) { band in
        SceneCompositionTileBandView(cohort: cohort, band: band, presence: presence)
      }
    }
  }
}


private struct ScenePlaneProbeControl: UIViewRepresentable {
  let button: UIButton
  func makeUIView(context: Context) -> UIButton { button }
  func updateUIView(_ view: UIButton, context: Context) {}
}
