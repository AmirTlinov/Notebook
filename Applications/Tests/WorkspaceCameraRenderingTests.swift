import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class WorkspaceCameraRenderingTests: XCTestCase {
  @MainActor
  func testLargeDiagramBoardKeepsSnapshotsWhileCullingOffscreenSurfaces() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: -30_000, y: -30_000))
    await model.finishPendingPersistence()
    let boardID = try XCTUnwrap(model.presence?.boardID)
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    // The working set has the physical sizes of the reported dense board,
    // but contains synthetic paths, never the person's document content.
    let sizes = [(2689.3, 3943.4), (2218.4, 1430.1), (1247.1, 1242.4), (3160.6, 2069.2),
      (3681.7, 867.9), (3395.1, 1741.7), (2465.8, 2668.3), (1017.0, 1209.9), (1370.3, 1440.0), (588.5, 696.0)]
    let elements = sizes.enumerated().map { index, size in
      let paths = (0..<40).map { "<path d='M \(40 + $0 * 10) 40 V \(size.1 - 40)'/>" }.joined()
      return SpatialElement(id: UUID().uuidString, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: size.0, height: size.1),
        worldOrigin: .init(x: Double(index % 4) * 4000, y: Double(index / 4) * 4500),
        source: "Diagram minification fixture",
        html: "<svg width='100%' height='100%' viewBox='0 0 \(size.0) \(size.1)'><g stroke='#202020' stroke-width='3.5'>\(paths)</g></svg>",
        stamp: .init(counter: 0, actor: model.actorID))
    }
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    }
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    func show(_ scale: Double) {
      model.updatePresence(.init(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: 7200, y: 6200), scale: scale), viewport: viewport), settled: false)
    }
    show(0.03)
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    let deadline = ContinuousClock.now + .seconds(10)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
    let cohort = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "Whole composition is required before measuring camera frames")
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertLessThanOrEqual(cohort.plan.liveOwners.count + 1, 8)
    XCTAssertLessThanOrEqual(cohort.plan.primitiveCount, 96)
    let images = cohort.rasters.mapValues { ObjectIdentifier($0.image) }
    func webViews(in view: UIView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }
    while !webViews(in: host.view).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let mounted = Set(webViews(in: host.view).map(ObjectIdentifier.init))
    XCTAssertEqual(mounted.count, 0, "Готовые статические SVG освобождают WebKit до движения камеры")
    let end = expectation(description: "Repeated diagram camera frames")
    let driver = CameraFrameDriver()
    driver.step = { frame in
      show(exp(log(0.02) + (log(0.13) - log(0.02)) * (sin(Double(frame) * .pi / 60) + 1) / 2))
      if frame == 480 { driver.stop(); end.fulfill() }
    }
    driver.start()
    await fulfillment(of: [end], timeout: 60)
    driver.stop()
    try await Task.sleep(for: .milliseconds(50))
    let finalWebViews = Set(webViews(in: host.view).map(ObjectIdentifier.init))
    let visible = model.sceneWorkset(presence: try XCTUnwrap(model.presence))
    XCTAssertLessThanOrEqual(finalWebViews.count, visible.elements.count,
      "За экраном не остаются живые WebKit; готовый снимок сохраняет источник")
    XCTAssertTrue(finalWebViews.isSubset(of: mounted),
      "Повтор камеры не запускает новую подготовку уже готовых статических источников")
    XCTAssertTrue(model.compositionTiles.published === cohort)
    for (key, image) in images {
      XCTAssertEqual(cohort.rasters[key].map { ObjectIdentifier($0.image) }, image,
        "Camera contact projects the same completed tiles, not a new source snapshot queue")
    }
    XCTAssertLessThanOrEqual(SceneRenderResources.shared.residentBytes + SceneRenderResources.shared.reservedBytes,
      SceneRenderResources.shared.byteLimit)
    let times = Array(driver.intervals.dropFirst(120)).sorted()
    XCTAssertGreaterThan(times.count, 300)
    let p95 = times[times.count * 95 / 100]
    let report = "frames=\(times.count); p50=\(times[times.count / 2]); p95=\(p95); max=\(times.last!)"
    let attachment = XCTAttachment(string: report)
    attachment.name = "Large diagram camera display-link intervals in seconds"
    attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertLessThan(p95, 0.1, report)
    await model.finishPendingPersistence()
  }

  @MainActor
  func testDenseBoardKeepsFramesMovingDuringZoom() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    var journal = try XCTUnwrap(model.spatialInk)
    var inkOwners: [UUID] = []
    for index in 0..<8 {
      let center = WorldPoint(x: Double(index % 4) * 1100, y: Double(index / 4) * 1500)
      let id = try XCTUnwrap(model.createNotebook(at: center))
      inkOwners.append(id)
      for stroke in 0..<4 {
        let samples = (0..<120).map { point in
          SpatialInkSample(point: SpatialPoint(x: 100 + Double(point) * 4,
            y: 240 + Double(stroke) * 130 + sin(Double(point) / 5) * 70),
            timeOffset: Double(point) / 120, width: stroke == 3 ? 40 : 5,
            opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        _ = journal.append(tool: stroke == 3 ? .eraser : .pen,
          spans: [SpatialInkSpan(surface: .cover(id), samples: samples)], actor: model.actorID)
      }
    }
    let creationsSaved = await model.finishPendingPersistence()
    XCTAssertTrue(creationsSaved)
    try model.store.saveSpatialInk(journal)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.readSpatialInk(surfaces: inkOwners.map(SurfaceID.cover)).actions.count, 32,
      "The scene source contains all eight ink owners; the model projection need not retain them together")
    let size = SpatialPoint(x: 1194, y: 834)
    let center = WorldPoint(x: 1650, y: 750)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: size.x, height: size.y)
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model))
    window.rootViewController = host
    model.updatePresence(SessionPresence(boardID: boardID, mode: .board, camera: SpatialCamera(center: center, scale: 0.15), viewport: size), settled: true)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    let deadline = ContinuousClock.now + .seconds(10)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let resourcesAtPublication = SceneRenderResources.shared
    let preparation = "preparing=\(model.compositionTiles.isPreparing); permits=\(model.permitsBackgroundPreparation); scenePending=\(model.scenePreparationPending); publication=\(model.scenePublicationGeneration); revision=\(model.workspaceHeader?.cursor.description ?? "nil"); physical=\(resourcesAtPublication.activePhysicalOwnerCount); resident=\(resourcesAtPublication.residentBytes); reserved=\(resourcesAtPublication.reservedBytes); refusals=\(model.compositionTiles.budgetFailures)"
    let preparationAttachment = XCTAttachment(string: preparation)
    preparationAttachment.name = "Dense board publication and resource state"
    preparationAttachment.lifetime = .keepAlways; add(preparationAttachment)
    let cohort = try XCTUnwrap(model.compositionTiles.published,
      model.compositionTiles.failure ?? "A frame with real ink must precede the camera measurement: " + preparation)
    let nativeRefusals = model.compositionTiles.budgetFailures.filter { $0.allocation == .nativeInk }
    XCTAssertFalse(nativeRefusals.isEmpty, "Eight inked covers exceed the passive backing allowance")
    for (previous, next) in zip(nativeRefusals, nativeRefusals.dropFirst()) {
      XCTAssertLessThan(next.nativeOwners, previous.nativeOwners,
        "Coarsening static tiles cannot retry the same refused native cover set")
    }
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    let resources = SceneRenderResources.shared
    let resourcesBefore = "web=\(resources.activeWebSurfaceCount); pending=\(resources.pendingWebRequestCount); rasterBytes=\(resources.residentBytes)"
    let end = expectation(description: "camera frames")
    let driver = CameraFrameDriver()
    driver.step = { frame in
      let scale = exp(log(0.035) + (log(0.8) - log(0.035)) * (sin(Double(frame) / 30) + 1) / 2)
      model.updatePresence(SessionPresence(boardID: boardID, mode: .board,
        camera: SpatialCamera(center: center, scale: scale), viewport: size), settled: false)
      if frame == 120 { driver.stop(); end.fulfill() }
    }
    driver.start()
    await fulfillment(of: [end], timeout: 60)
    driver.stop()
    let times = Array(driver.intervals.dropFirst(10)).sorted()
    XCTAssertGreaterThan(times.count, 100)
    guard !times.isEmpty else { return }
    let p95 = times[times.count * 95 / 100]
    let report = "frames=\(times.count); p50=\(times[times.count / 2]); p95=\(p95); max=\(times.last!)"
    let attachment = XCTAttachment(string: report)
    attachment.name = "Dense board camera frame intervals in seconds"
    attachment.lifetime = .keepAlways
    add(attachment)
    let resourceReport = XCTAttachment(string: "before: \(resourcesBefore)\nafter: web=\(resources.activeWebSurfaceCount); pending=\(resources.pendingWebRequestCount); rasterBytes=\(resources.residentBytes)")
    resourceReport.name = "Dense board preparation resources"
    resourceReport.lifetime = .keepAlways
    add(resourceReport)
    XCTAssertLessThan(p95, 0.1, report)
    XCTAssertTrue(model.compositionTiles.published === cohort)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }
}

@MainActor
private final class CameraFrameDriver: NSObject {
  var step: ((Int) -> Void)?
  var intervals: [Double] = []
  var link: CADisplayLink?
  var previous: Double?
  var frame = 0
  func start() {
    link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    link?.add(to: .main, forMode: .common)
  }
  func stop() { link?.invalidate(); link = nil; step = nil }
  @objc func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    if let previous { intervals.append(now - previous) }
    previous = now
    frame += 1
    step?(frame)
  }
}
