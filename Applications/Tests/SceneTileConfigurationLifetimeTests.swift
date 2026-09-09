import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SceneTileConfigurationLifetimeTests: XCTestCase {
  func testShutdownRetiresCachedNativeTilesWithoutRevokingAnotherBorrower() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tile-shutdown-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry(), boardID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(), viewport: .init(x: 256, y: 256))
    var cohort: SceneCompositionCohort? = try await prepare(presence: presence, resources: resources, registry: registry)
    let staticElement = try XCTUnwrap(cohort?.frame.workset(boardID: boardID).elements.first {
      cohort?.plan.allowsLive(.element($0.id), in: .board(boardID)) == false
    })
    let entry = try XCTUnwrap(cohort?.frame.index.paintEntry(id: .element(staticElement.id), boardID: boardID))
    let band = try XCTUnwrap(cohort?.bands(in: .board(boardID), layer: .elements).first { $0.range.contains(entry) })
    let borrowed = try XCTUnwrap(cohort?.rasters.first {
      $0.key.plane == band.plane && $0.key.range == band.range
    }?.value.retainedCopy())
    let configuration = SceneCompositionTileBandView(cohort: cohort!, band: band, presence: presence)
    let host = UIHostingController(rootView: configuration.frame(width: 256, height: 256).environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    let mounted = rasterViews(in: host.view)
    XCTAssertFalse(mounted.isEmpty)
    XCTAssertTrue(mounted.allSatisfy { $0.layer.contents != nil })
    let before = try pixels(in: host.view)
    XCTAssertGreaterThan(stride(from: 0, to: before.count, by: 4).filter {
      before[$0] > 180 && before[$0 + 1] < 180 && before[$0 + 2] < 180
    }.count, 100, "The handoff must preserve genuinely painted tiles, not empty layers")
    cohort = nil

    // A temporary window handoff is not terminal. The physical presenter keeps
    // its exact pixels even when the configuration's original cohort has gone.
    window.isHidden = true; window.rootViewController = nil
    XCTAssertTrue(mounted.allSatisfy { $0.layer.contents != nil })
    window.rootViewController = host; window.makeKeyAndVisible()
    XCTAssertEqual(try pixels(in: host.view), before)
    window.isHidden = true; window.rootViewController = nil

    // No replacement root, layout pass or SwiftUI dismantle delivers shutdown.
    // The accepted model boundary retires only the native presenter's own lease.
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    XCTAssertTrue(mounted.allSatisfy { $0.layer.contents == nil })
    for native in mounted {
      native.bindSceneLifecycle(to: model)
      native.updateRaster(borrowed, displayScale: 1)
    }
    XCTAssertTrue(mounted.allSatisfy { $0.layer.contents == nil },
      "A late update cannot revive a terminal native presentation")
    let late = AgentSnapshotRasterView()
    late.bindSceneLifecycle(to: model)
    late.updateRaster(borrowed, displayScale: 1)
    XCTAssertNil(late.layer.contents, "A stopped model cannot admit a new native presentation")
    XCTAssertFalse(borrowed.isReleased)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, borrowed.accountedByteCount)
    borrowed.release()
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
    withExtendedLifetime((configuration, host, mounted)) {}
  }

  func testCachedTileBandKeepsOnlyItsShownPixelsUntilActualUnmount() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry(), boardID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(), viewport: .init(x: 256, y: 256))
    var cohort: SceneCompositionCohort? = try await prepare(presence: presence, resources: resources, registry: registry)
    weak let retired = cohort
    let staticElement = try XCTUnwrap(cohort?.frame.workset(boardID: boardID).elements.first {
      cohort?.plan.allowsLive(.element($0.id), in: .board(boardID)) == false
    })
    let entry = try XCTUnwrap(cohort?.frame.index.paintEntry(id: .element(staticElement.id), boardID: boardID))
    let band = try XCTUnwrap(cohort?.bands(in: .board(boardID), layer: .elements).first { $0.range.contains(entry) })
    let shownBytes = try XCTUnwrap(cohort).rasters.filter { $0.key.plane == band.plane && $0.key.range == band.range }
      .values.reduce(0) { $0 + $1.accountedByteCount }
    let configuration = SceneCompositionTileBandView(cohort: cohort!, band: band, presence: presence)
    let host = UIHostingController(rootView: AnyView(configuration.frame(width: 256, height: 256)))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    let before = try pixels(in: host.view)
    XCTAssertGreaterThan(stride(from: 0, to: before.count, by: 4).filter {
      before[$0] > 180 && before[$0 + 1] < 180 && before[$0 + 2] < 180
    }.count, 100, "The real static painter must first produce a visible, alpha-composited tile")
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, shownBytes,
      "A displayed band is only one part of this complete prepared cohort")

    // The cached value may outlive publication. The actual mounted native
    // rasters must still own independent leases for exactly this shown band.
    cohort = nil
    try await waitUntil { retired == nil && resources.rasterAdmission.pinnedBytes == shownBytes }
    XCTAssertNil(retired)
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, shownBytes)
    XCTAssertEqual(try pixels(in: host.view), before, "Dropping the cohort cannot blank or change mounted pixels")

    host.rootView = AnyView(EmptyView())
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    window.isHidden = true; window.rootViewController = nil
    try await waitUntil { resources.rasterAdmission.pinnedBytes == 0 }
    withExtendedLifetime((configuration, host)) {
      XCTAssertNil(retired)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0,
        "A cached tile configuration is not a second owner after its native view dismantles")
    }
    await registry.stopSceneInk()
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertEqual(resources.activePhysicalOwnerCount, 0)
  }

  func testMountedTilesUseThePreparedAlphaBitmapWithoutAnotherRasterCache() async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry(), boardID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(), viewport: .init(x: 256, y: 256))
    let cohort = try await prepare(presence: presence, resources: resources, registry: registry)
    let element = try XCTUnwrap(cohort.frame.workset(boardID: boardID).elements.first {
      !cohort.plan.allowsLive(.element($0.id), in: .board(boardID))
    })
    let entry = try XCTUnwrap(cohort.frame.index.paintEntry(id: .element(element.id), boardID: boardID))
    let band = try XCTUnwrap(cohort.bands(in: .board(boardID), layer: .elements).first { $0.range.contains(entry) })
    let configuration = SceneCompositionTileBandView(cohort: cohort, band: band, presence: presence)
    let host = UIHostingController(rootView: AnyView(configuration.frame(width: 256, height: 256)))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 256, height: 256)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()

    let mounted = rasterViews(in: host.view)
    XCTAssertFalse(mounted.isEmpty, "The contract must inspect actual mounted tile presenters")
    var translucentPixels = 0
    for view in mounted {
      XCTAssertFalse(view.layer.shouldRasterize, "A completed tile must not allocate another per-presenter raster cache")
      XCTAssertEqual(view.layer.minificationFilter, .trilinear)
      let contents = try XCTUnwrap(view.layer.contents)
      guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
        return XCTFail("The native tile must use its completed CGImage directly")
      }
      let bitmap = contents as! CGImage
      XCTAssertEqual(bitmap.width, CompositionTile.pixelSize)
      XCTAssertEqual(bitmap.height, CompositionTile.pixelSize)
      let context = try XCTUnwrap(CGContext(data: nil, width: bitmap.width, height: bitmap.height,
        bitsPerComponent: 8, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(bitmap, in: .init(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
      let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      translucentPixels += stride(from: 3, to: bitmap.width * bitmap.height * 4, by: 4)
        .filter { pixels[$0] > 0 && pixels[$0] < 255 }.count
    }
    XCTAssertGreaterThan(translucentPixels, 100, "Direct native contents must preserve the static painter's alpha")

    host.rootView = AnyView(EmptyView())
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    window.isHidden = true; window.rootViewController = nil
    await registry.stopSceneInk()
  }

  private func rasterViews(in view: UIView) -> [AgentSnapshotRasterView] {
    (view as? AgentSnapshotRasterView).map { [$0] } ?? view.subviews.flatMap { rasterViews(in: $0) }
  }

  private func prepare(presence: SessionPresence, resources: SceneRenderResources,
    registry: SpatialInkSurfaceRegistry) async throws -> SceneCompositionCohort {
    let stamp = VersionStamp(counter: 0, actor: UUID())
    let item = WorkspaceItem.notebook(title: "Offscreen owner", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id,
      selectedPageID: item.pageIDs.first, stamp: stamp, rootBoardID: presence.boardID)
    let elements: [SpatialElement] = (0..<8).map { index in
      .init(id: "tile-lifetime-\(index)", surface: .board(presence.boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 128, height: 128), worldOrigin: .init(x: -64, y: -64),
        source: "A translucent red square", html: "<svg width='128' height='128' viewBox='0 0 128 128'><rect x='16' y='16' width='96' height='96' fill='#ed2020' fill-opacity='.65'/></svg>", stamp: stamp)
    }
    let board = BoardDocument(freeItems: [.init(itemID: item.id, center: .init(x: 1_000_000, y: 1_000_000),
      zIndex: 0, stamp: stamp)], elements: elements, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: presence.boardID,
      boards: [.init(id: presence.boardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
    let tiles = SceneCompositionTiles(resources: resources, surfaceRegistry: registry)
    tiles.prepare(source: source, presence: presence, frame: frame, pinned: [], displayScale: 1)
    let deadline = ContinuousClock.now + .seconds(15)
    while tiles.published == nil, tiles.failure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    return try XCTUnwrap(tiles.published, tiles.failure ?? "The real static source did not finish preparation")
  }

  private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "The shown tile owner did not reach its lifetime boundary", file: file, line: line)
  }

  private func pixels(in view: UIView) throws -> Data {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(view.bounds)
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
  }
}
