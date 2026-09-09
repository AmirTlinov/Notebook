import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SpatialInkConfigurationLifetimeTests: XCTestCase {
  func testCachedBoardConfigurationDoesNotOwnTheRetiredSceneOrNativeSource() async throws {
    try await assertConfigurationLifetime(kind: .board)
  }

  func testCachedCoverConfigurationDoesNotOwnTheRetiredSceneOrNativeSource() async throws {
    try await assertConfigurationLifetime(kind: .cover)
  }

  func testCachedActiveConfigurationReleasesItsInputOwnerAfterActualDismantle() async throws {
    try await assertConfigurationLifetime(kind: .active)
  }

  private enum ConfigurationKind { case board, cover, active }

  private func assertConfigurationLifetime(kind: ConfigurationKind) async throws {
    let resources = SceneRenderResources(), registry = SpatialInkSurfaceRegistry()
    let isCover = kind == .cover
    let boardID = UUID(), itemID = UUID(), actor = UUID()
    let surface = isCover ? SurfaceID.cover(itemID) : .board(boardID)
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    _ = journal.append(tool: .pen, spans: [.init(surface: surface,
      samples: [-80.0, 0, 80].enumerated().map { index, x in
        .init(point: .init(x: x + 200, y: 200),
          worldPoint: isCover ? nil : .init(x: x, y: 0),
          timeOffset: Double(index) / 10, width: 14, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor)
    var cohort: SceneCompositionCohort? = try await WorkspaceInkFixture.prepare(boardID: boardID,
      camera: .init(), viewport: .init(x: 512, y: 512),
      items: [.init(itemID: itemID, geometry: .notebook, center: .zero, zIndex: 0)],
      journal: journal, registry: registry, resources: resources)
    weak let retiredCohort = cohort
    weak let retiredLease = cohort?.nativeInk
    weak let retiredOwner = cohort?.nativeInk.owners[surface]
    weak let retiredCanvas = retiredOwner?.canvas
    let dimensions = try XCTUnwrap(cohort?.frame.workset(boardID: boardID).items.first?.geometry)
    let size = isCover ? CGSize(width: dimensions.width, height: dimensions.height) : CGSize(width: 512, height: 512)
    // Keep the actual old Representable value after its native view dismantles,
    // just as UIKit's cached DisplayList can. No test-only rendering surrogate.
    let cachedConfiguration: AnyView
    switch kind {
    case .cover:
      cachedConfiguration = AnyView(SpatialInkSurfaceView(surface: surface, cohort: cohort!, boardID: boardID, isActive: true)
        .frame(width: size.width, height: size.height))
    case .board:
      cachedConfiguration = AnyView(SpatialBoardInkView(cohort: cohort!, boardID: boardID, camera: .init())
        .frame(width: size.width, height: size.height))
    case .active:
      cachedConfiguration = AnyView(SpatialInkCanvas(cohort: cohort, boardID: boardID,
        camera: .init(), viewport: .init(x: size.width, y: size.height), items: [], journal: journal,
        penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
        surfaceRegistry: registry, inputGate: .init(), isItemBeingDeleted: { _ in false },
        admitsNewContact: { true }, onCommit: { _, _, _ in nil }, isEnabled: true)
        .frame(width: size.width, height: size.height))
    }
    let host = UIHostingController(rootView: cachedConfiguration)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(origin: .zero, size: size)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    try await waitUntil { self.mount(in: host.view)?.inkView === retiredCanvas && retiredCanvas?.isStableFramePresented == true }
    let native = try XCTUnwrap(mount(in: host.view))
    XCTAssertTrue(native.inkView === retiredCanvas)
    XCTAssertGreaterThan(try inkPixelCount(native), 0, "The real prepared canvas must first be shown")
    XCTAssertGreaterThan(retiredCanvas?.committedVertexCount ?? 0, 0)
    XCTAssertNotNil(retiredCanvas?.installedSpatialSource)
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertGreaterThan(resources.reservedBytes, 0)

    // A passive mount needs only native ink. The actual active coordinator also
    // owns the coherent scene it uses to admit a new contact, until dismantle.
    cohort = nil
    if kind == .active {
      XCTAssertNotNil(retiredCohort)
      XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)
    } else {
      try await waitUntil { retiredCohort == nil && resources.rasterAdmission.pinnedBytes == 0 }
    }
    XCTAssertNotNil(retiredLease)
    XCTAssertNotNil(retiredOwner)
    XCTAssertTrue(native.inkView === retiredCanvas)
    XCTAssertGreaterThan(try inkPixelCount(native), 0)
    XCTAssertGreaterThan(retiredCanvas?.committedVertexCount ?? 0, 0)

    host.rootView = AnyView(EmptyView())
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    window.isHidden = true; window.rootViewController = nil
    try await waitUntil {
      native.inkView == nil && retiredLease == nil && retiredOwner == nil && retiredCanvas == nil
        && resources.rasterAdmission.pinnedBytes == 0 && resources.reservedBytes == 0
        && resources.activePhysicalOwnerCount == 0
    }
    withExtendedLifetime((cachedConfiguration, host, native)) {
      XCTAssertNil(retiredCohort)
      XCTAssertNil(retiredLease)
      XCTAssertNil(retiredOwner)
      XCTAssertNil(retiredCanvas, "A cached configuration cannot preserve the retired CPU ink source either")
      XCTAssertNil(native.inkView)
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0)
      XCTAssertEqual(resources.reservedBytes, 0)
      XCTAssertEqual(resources.activePhysicalOwnerCount, 0)
      XCTAssertFalse(registry.sceneInkIsStopped, "Ordinary unmount does not require stopping the whole registry")
    }
    await registry.stopSceneInk()
  }

  private func mount(in view: UIView) -> SpatialInkPhysicalMountView? {
    if let mount = view as? SpatialInkPhysicalMountView { return mount }
    return view.subviews.lazy.compactMap { self.mount(in: $0) }.first
  }

  private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "The actual mounted owner did not complete its lifetime boundary", file: file, line: line)
  }

  private func inkPixelCount(_ view: UIView) throws -> Int {
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
    return stride(from: 0, to: cg.width * cg.height * 4, by: 4).filter {
      bytes[$0] < 160 && bytes[$0 + 1] < 160 && bytes[$0 + 2] < 160
    }.count
  }
}
