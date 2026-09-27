import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// The basis belongs to the installed Metal pixels. Camera samples may move
/// their native parent, but cannot silently redraw those pixels in a new basis.
@MainActor
final class SpatialInkCameraPresentationTests: XCTestCase {
  func testSmallPanAndZoomOutUseInstalledCoverageWithoutPreparingAnotherBasis() async throws {
    for viewport in [SpatialPoint(x: 834, y: 1194), .init(x: 1194, y: 834)] {
      let fixture = try await Fixture.make(viewport: viewport)
      let canvas = fixture.owner.canvas
      let requests = canvas.drawableRequestCount, meshes = canvas.spatialMeshInstallCount
      for camera in [SpatialCamera(center: .init(x: 8, y: 0), scale: 1),
        .init(center: .init(x: 0, y: -8), scale: 1), .init(scale: 0.99)] {
        XCTAssertFalse(fixture.owner.needsProjection(camera: camera, viewport: viewport, refinesDetails: false))
        fixture.update(camera: camera)
        fixture.assertWorldGeometry(camera: camera)
      }
      XCTAssertFalse(fixture.owner.needsProjection(camera: .init(center: .init(x: 8, y: 0), scale: 1),
        viewport: viewport, refinesDetails: true), "Settling a covered pan does not need a new GPU basis")
      XCTAssertEqual(canvas.drawableRequestCount, requests)
      XCTAssertEqual(canvas.spatialMeshInstallCount, meshes)
      XCTAssertTrue(fixture.owner.needsProjection(camera: .init(scale: 2), viewport: viewport, refinesDetails: false),
        "A long pinch eventually refines even before settlement")
      XCTAssertTrue(fixture.owner.needsProjection(camera: .init(center: .init(x: 10_000, y: 0)),
        viewport: viewport, refinesDetails: false), "Finite overscan still requests the missing world area")
      await fixture.close()
    }
  }

  func testOneAcceptedNativeSampleProjectsBothPlanesAndInkBeforeSwiftUIUpdates() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let projection = SceneNativeCameraProjection()
    let initial = SessionPresence(boardID: fixture.boardID, mode: .board,
      camera: .init(scale: 1), viewport: fixture.viewport)
    projection.update(initial)
    fixture.mount.bindCameraProjection(to: projection)
    let controllers = [SceneCameraPlaneController<Int>(), SceneCameraPlaneController<Int>()]
    let controls = [UIButton(type: .system), UIButton(type: .system)]
    let worlds = [WorldPoint(x: -70, y: -55), WorldPoint(x: 90, y: 60)]
    var eventProjections: [ScenePlaneProjection] = []
    for (index, controller) in controllers.enumerated() {
      fixture.host.addChild(controller); fixture.host.view.addSubview(controller.view)
      controller.didMove(toParent: fixture.host); controller.view.frame = fixture.mount.frame
      controller.bindCameraProjection(to: projection)
      controller.update(presence: initial, revision: 0, reanchorsOnRevision: false) { anchor, current in
        eventProjections.append(current)
        let point = anchor.camera.worldToScreen(worlds[index], viewport: anchor.viewport)
        return AnyView(CameraProjectionProbeControl(button: controls[index])
          .frame(width: 20, height: 20).position(x: point.x, y: point.y)
          .frame(width: anchor.viewport.x, height: anchor.viewport.y))
      }
    }
    defer { for controller in controllers { controller.uninstall(); controller.view.removeFromSuperview(); controller.removeFromParent() } }
    fixture.window.layoutIfNeeded()
    let requests = fixture.owner.canvas.drawableRequestCount
    let basis = fixture.owner.canvas.spatialCamera
    for index in 0..<80 {
      let current = SessionPresence(boardID: fixture.boardID, mode: .board,
        camera: .init(center: .init(x: Double(index) / 3, y: -Double(index) / 7),
          // Exceed the ORIGINAL prepared density, not merely return from
          // minification. Covered zoom-out no longer creates a lower basis.
          scale: 0.41 + Double(index) / 60), viewport: fixture.viewport)
      projection.update(current)
      // No SwiftUI update, await or layout turn occurs between the accepted
      // sample and these actual native positions / next-contact coordinates.
      fixture.assertWorldGeometry(camera: current.camera)
      for (offset, controller) in controllers.enumerated() {
        let control = controls[offset]
        let actual = control.convert(.init(x: control.bounds.midX, y: control.bounds.midY), to: controller.view)
        let expected = current.camera.worldToScreen(worlds[offset], viewport: current.viewport)
        // A density rebase lays out UIKit controls on the physical pixel grid.
        // World/ink coordinates above remain exact; native edges may snap.
        XCTAssertEqual(actual.x, expected.x, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertEqual(eventProjections[offset].current, current)
        controller.update(presence: initial, revision: 0, reanchorsOnRevision: false,
          isCameraActive: true) { anchor, current in
            // A bounded density rebase may republish layout, never the stale
            // configuration's camera or a new native control identity.
            eventProjections[offset] = current
            let point = anchor.camera.worldToScreen(worlds[offset], viewport: anchor.viewport)
            return AnyView(CameraProjectionProbeControl(button: controls[offset])
              .frame(width: 20, height: 20).position(x: point.x, y: point.y)
              .frame(width: anchor.viewport.x, height: anchor.viewport.y))
          }
      }
      fixture.update(camera: initial.camera)
      fixture.assertWorldGeometry(camera: current.camera)
      XCTAssertEqual(fixture.mount.camera, current.camera)
    }
    XCTAssertEqual(fixture.owner.canvas.spatialCamera, basis)
    XCTAssertEqual(fixture.owner.canvas.drawableRequestCount, requests)
    XCTAssertTrue(controllers.allSatisfy { $0.contentPublicationCount > 1 && $0.contentPublicationCount < 10 },
      "A multi-LOD pinch refines native paint, but not on every camera sample")
    let last = try XCTUnwrap(projection.current(for: fixture.boardID))
    let held = try XCTUnwrap(fixture.registry.acquireContact(on: fixture.surface, in: fixture.mount))
    let moved = SessionPresence(boardID: fixture.boardID, mode: .board,
      camera: .init(center: .init(x: 11, y: -9), scale: 0.6), viewport: fixture.viewport)
    projection.update(moved)
    fixture.assertWorldGeometry(camera: last.camera)
    held.release()
    fixture.assertWorldGeometry(camera: moved.camera)
  }

  func testProjectionResetAndUnmountCannotReviveAPreviousSpaceSample() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let projection = SceneNativeCameraProjection()
    fixture.mount.bindCameraProjection(to: projection)
    let camera = SpatialCamera(center: .init(x: 25, y: -18), scale: 0.7)
    projection.update(.init(boardID: fixture.boardID, mode: .board, camera: camera, viewport: fixture.viewport))
    fixture.assertWorldGeometry(camera: camera)
    fixture.mount.unmount()
    let count = fixture.owner.canvas.drawableRequestCount
    projection.update(.init(boardID: fixture.boardID, mode: .board,
      camera: .init(scale: 0.4), viewport: fixture.viewport))
    XCTAssertEqual(fixture.mount.camera, camera, "A retained unmounted shell receives no camera samples")
    projection.update(nil)
    XCTAssertNil(projection.current(for: fixture.boardID))
    fixture.update(camera: .init(scale: 1))
    fixture.assertWorldGeometry(camera: .init(scale: 1))
    XCTAssertEqual(fixture.owner.canvas.drawableRequestCount, count)
    weak var released: SceneCameraPlaneController<Int>?
    do {
      let controller = SceneCameraPlaneController<Int>()
      released = controller
      controller.bindCameraProjection(to: projection)
    }
    XCTAssertNil(released, "The projection registry owns no native view or scene lifetime")
  }

  func testCameraMovesInstalledPixelsWithoutRequestingAnotherDrawableOrMesh() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.owner.canvas
    let basis = canvas.spatialCamera, pools = canvas.spatialTilePoolIDs
    let requests = canvas.drawableRequestCount, meshes = canvas.spatialMeshInstallCount
    let bytes = fixture.resources.reservedBytes
    for index in 0..<40 {
      let camera = SpatialCamera(center: .init(x: Double(index) / 2, y: -Double(index) / 3),
        scale: 0.8 + Double(index) / 100)
      fixture.update(camera: camera)
      fixture.assertWorldGeometry(camera: camera)
      XCTAssertEqual(canvas.spatialCamera, basis, "A native transform cannot relabel the installed GPU frame")
      XCTAssertEqual(canvas.spatialTilePoolIDs, pools)
    }
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(canvas.drawableRequestCount, requests, "Moving the camera presents existing pixels synchronously")
    XCTAssertEqual(canvas.spatialMeshInstallCount, meshes)
    XCTAssertEqual(fixture.resources.reservedBytes, bytes)
    XCTAssertTrue(canvas.isStableFramePresented)
  }

  func testReadyCameraFrameKeepsOldBasisUntilAtomicInstallAndUsesLatestNativePose() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.owner.canvas, oldBasis = canvas.spatialCamera
    let pools = canvas.spatialTilePoolIDs, bytes = fixture.resources.reservedBytes
    let requested = SpatialCamera(center: .init(x: 12, y: -15), scale: 1.1)
    fixture.update(camera: requested)
    let pixels = try fixture.pixels()
    let pressure = try XCTUnwrap(fixture.resources.reserveDerivedBytes(
      fixture.resources.byteLimit - bytes - 4096, priority: .input))
    defer { pressure.release() }
    let held = fixture.resources.reservedBytes
    let refinementStart = ContinuousClock.now
    let frame = try await canvas.prepareFrame(.spatial(nil,size:canvas.spatialViewport,displayScale:1,camera:requested))
    XCTAssertTrue(frame.isValid)
    XCTAssertEqual(canvas.spatialCamera, oldBasis)
    XCTAssertEqual(try fixture.pixels(), pixels, "Completed GPU preparation has not replaced displayed pixels")
    XCTAssertEqual(fixture.resources.reservedBytes, held, "Camera rebasing reuses the admitted drawable pools")
    let latest = SpatialCamera(center: .init(x: -8, y: 14), scale: 0.93)
    fixture.update(camera: latest)
    fixture.assertWorldGeometry(camera: latest)
    let candidate = fixture.candidate(frame: frame)
    try candidate.install()
    XCTAssertEqual(canvas.spatialCamera, requested)
    fixture.assertWorldGeometry(camera: latest)
    await withCheckedContinuation { continuation in
      frame.afterPresentationTransaction { continuation.resume() }
    }
    XCTAssertEqual(canvas.spatialTilePoolIDs, pools)
    XCTAssertEqual(fixture.resources.reservedBytes, held)
    // Transaction completion releases the private candidate; only the OS
    // drawable receipt proves presentation. Charge BOTH preparation and that
    // receipt against the existing camera-refinement budget.
    let shown = try await NotebookUXObservation.observe(since: refinementStart,
      budget: NotebookUXObservation.zoomRefinement) { canvas.isStableFramePresented }
    XCTAssertTrue(shown.passed, "Native ink refill must be presented within the original 250 ms: \(shown.milliseconds) ms")
    XCTAssertGreaterThan(try fixture.blackPixelCount(), 150, "The same native owner still displays actual ink")
  }

  func testHeldContactDefersBothCameraPoseAndPreparedBasisUntilItsFinalRelease() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let canvas = fixture.owner.canvas, basis = canvas.spatialCamera
    let requested = SpatialCamera(center: .init(x: 30, y: -18), scale: 1.2)
    let frame = try await canvas.prepareFrame(.spatial(nil,size:canvas.spatialViewport,displayScale:1,camera:requested))
    let candidate = fixture.candidate(frame: frame)
    let first = try XCTUnwrap(fixture.registry.acquireContact(on: fixture.surface, in: fixture.mount))
    let second = try XCTUnwrap(fixture.registry.acquireContact(on: fixture.surface, in: fixture.mount))
    defer { first.release(); second.release() }
    let transform = canvas.transform, center = canvas.center
    fixture.update(camera: requested)
    XCTAssertEqual(canvas.transform, transform); XCTAssertEqual(canvas.center, center)
    XCTAssertThrowsError(try candidate.install()) { XCTAssertTrue($0 is CancellationError) }
    first.release()
    XCTAssertEqual(canvas.spatialCamera, basis); XCTAssertEqual(canvas.center, center)
    XCTAssertThrowsError(try candidate.install()) { XCTAssertTrue($0 is CancellationError) }
    second.release()
    fixture.assertWorldGeometry(camera: requested)
    XCTAssertEqual(canvas.spatialCamera, basis, "Releasing input applies the native map before replacing its GPU basis")
    try candidate.install()
    fixture.assertWorldGeometry(camera: requested)
    XCTAssertEqual(canvas.spatialCamera, requested)
    await withCheckedContinuation { continuation in
      frame.afterPresentationTransaction { continuation.resume() }
    }
  }

  func testStationaryRefinementStopsAtTheInstalledFiniteWindow() async throws {
    let fixture = try await Fixture.make(viewport: .init(x: 512, y: 384))
    addTeardownBlock { await fixture.close() }
    let original = try XCTUnwrap(fixture.owner.canvas.spatialCamera)
    XCTAssertFalse(fixture.owner.needsProjection(camera: original, viewport: fixture.viewport, refinesDetails: true),
      "A ready finite backing does not request itself again")
    let moved = SpatialCamera(center: .init(x: 14, y: -12), scale: 1.1)
    XCTAssertTrue(fixture.owner.needsProjection(camera: moved, viewport: fixture.viewport, refinesDetails: true))
    fixture.update(camera: moved)
    let frame = try await fixture.owner.canvas.prepareFrame(.spatial(nil,size:fixture.owner.canvas.spatialViewport,displayScale:1,camera:moved))
    try fixture.candidate(frame: frame).install()
    XCTAssertFalse(fixture.owner.needsProjection(camera: moved, viewport: fixture.viewport, refinesDetails: true))
    await withCheckedContinuation { continuation in
      frame.afterPresentationTransaction { continuation.resume() }
    }
  }

  @MainActor
  private final class Fixture {
    let boardID = UUID(), actor = UUID()
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry()
    let viewport: SpatialPoint, window: UIWindow, host = UIViewController()
    let mount: SpatialInkPhysicalMountView
    var cohort: SceneCompositionCohort!
    var journal: SpatialInkJournal
    var surface: SurfaceID { .board(boardID) }
    var owner: SpatialInkPhysicalOwner { cohort.nativeInk.owners[surface]! }
    private weak var previousWindow: UIWindow?

    static func make(viewport: SpatialPoint = .init(x: 384, y: 512)) async throws -> Fixture {
      let fixture = try Fixture(viewport: viewport)
      _ = fixture.journal.append(tool: .pen, spans: [.init(surface: fixture.surface,
        samples: [-100.0, 0, 100].enumerated().map { index, x in
          .init(point: .zero, worldPoint: .init(x: x, y: 0), timeOffset: Double(index) / 10,
            width: 12, opacity: 1, force: 1, azimuth: 0, altitude: 1)
        })], actor: fixture.actor)
      fixture.cohort = try await WorkspaceInkFixture.prepare(boardID: fixture.boardID,
        camera: .init(scale: 1), viewport: viewport, items: [], journal: fixture.journal,
        registry: fixture.registry, resources: fixture.resources)
      fixture.window.rootViewController = fixture.host
      fixture.host.view.addSubview(fixture.mount); fixture.window.makeKeyAndVisible()
      fixture.update(camera: .init(scale: 1))
      let deadline = ContinuousClock.now + .seconds(5)
      while !fixture.owner.canvas.isStableFramePresented, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertTrue(fixture.owner.canvas.isStableFramePresented)
      XCTAssertGreaterThan(try fixture.blackPixelCount(), 150)
      return fixture
    }

    private init(viewport: SpatialPoint) throws {
      self.viewport = viewport
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      previousWindow = scene.windows.first(where: \.isKeyWindow)
      window = UIWindow(windowScene: scene)
      mount = .init(frame: .init(x: 0, y: 0, width: viewport.x, height: viewport.y))
      journal = .init(stamp: .init(counter: 0, actor: actor))
    }

    func update(camera: SpatialCamera) {
      mount.update(lease: cohort.nativeInk, surface: surface, boardID: boardID, camera: camera, active: true)
      mount.setNeedsLayout(); mount.layoutIfNeeded()
    }
    func candidate(frame: InkCanvasView.PreparedFrame) -> SpatialInkSceneLease {
      .init(registry: registry, rootBoardID: boardID, focusedCoverID: nil,
        owners: [surface: owner], updates: [.init(owner: owner,
          generation: owner.canvas.spatialSourceGeneration, frame: frame, journal: journal)])
    }
    func assertWorldGeometry(camera: SpatialCamera, file: StaticString = #filePath, line: UInt = #line) {
      let canvas = owner.canvas
      guard let basis = canvas.spatialCamera else { return XCTFail("Missing installed basis", file: file, line: line) }
      for world in [WorldPoint.zero, .init(x: -100, y: 30), .init(x: 100, y: -50)] {
        let point = basis.worldToScreen(world, viewport: canvas.spatialViewport)
        let actual = canvas.convert(CGPoint(x: point.x, y: point.y), to: mount)
        let expected = camera.worldToScreen(world, viewport: viewport)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.00001, file: file, line: line)
      }
    }
    private func capture() throws -> CGImage {
      let format = UIGraphicsImageRendererFormat(); format.scale = 1
      return try XCTUnwrap(UIGraphicsImageRenderer(size: mount.bounds.size, format: format).image { context in
        UIColor.white.setFill(); context.fill(mount.bounds)
        mount.drawHierarchy(in: mount.bounds, afterScreenUpdates: true)
      }.cgImage)
    }
    func pixels() throws -> Data { try XCTUnwrap(capture().dataProvider?.data) as Data }
    func blackPixelCount() throws -> Int {
      let image = try capture()
      let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
      let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      return stride(from: 0, to: image.width * image.height * 4, by: 4).filter {
        max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2]) < 80
      }.count
    }
    func close() async {
      mount.unmount(); mount.removeFromSuperview(); await registry.stopSceneInk(); cohort = nil
      window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey()
    }
  }
}

private struct CameraProjectionProbeControl: UIViewRepresentable {
  let button: UIButton
  func makeUIView(context: Context) -> UIButton { button }
  func updateUIView(_ view: UIButton, context: Context) {}
}
