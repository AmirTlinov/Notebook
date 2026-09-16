import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class ZoomOutCoverageTests: XCTestCase {
  func testNewlyVisibleNotebookAppearsBeforeTheCameraContactEnds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)
      if stopped { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    model.moveItem(first, to: .zero)
    let distant = try XCTUnwrap(model.createNotebook(at: .init(x: 2400, y: 0)))
    model.selectItem(first)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let fixtureItems = try model.store.readItemHeaders(limit: 8).map(\.item)
    XCTAssertEqual(fixtureItems.count, 2)
    let before = try model.store.loadBoard(items: fixtureItems)
    var after = before
    let diagram = SpatialElement(id: "offscreen-diagram", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 400, height: 300), worldOrigin: .init(x: 1700, y: 800),
      source: "A blue circle to reveal while zooming out", html: "<svg viewBox='0 0 400 300'><rect width='400' height='300' fill='white'/><circle cx='200' cy='150' r='100' fill='#156dd9'/></svg>",
      css: "html,body,svg{margin:0;width:100%;height:100%}", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(after.upsertElement(diagram, in: boardID, expected: nil, actor: model.actorID))
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    let viewport = SpatialPoint(x: 834, y: 1194)
    func show(center: WorldPoint, scale: Double, settled: Bool) {
      model.updatePresence(.init(boardID: boardID, mode: .board,
        camera: .init(center: center, scale: scale), viewport: viewport), settled: settled)
    }
    show(center: .zero, scale: 0.8, settled: true)
    window.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    let initialDeadline = ContinuousClock.now + .seconds(8)
    while (model.compositionTiles.published == nil || model.scenePreparationPending || model.compositionTiles.isPreparing),
      ContinuousClock.now < initialDeadline { try await Task.sleep(for: .milliseconds(20)) }
    let initial = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "Initial notebook")
    XCTAssertFalse(initial.plan.allowsLive(.item(distant), in: .board(boardID)))
    XCTAssertFalse(initial.plan.allowsLive(.element(diagram.id), in: .board(boardID)))
    let originalInk = model.spatialInk
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    defer { model.inputGate.endContact(source: contact) }
    let start = ContinuousClock.now
    var firstShown: Duration?
    let address = SceneSourceAddress(plane: .board(boardID), elementID: diagram.id)
    // Keep taking real camera samples. Holding the final view without lifting
    // is not enough: coverage must make progress while samples keep arriving.
    for step in 0..<150 {
      let progress = min(1, Double(step) / 45)
      let scale = exp(log(0.8) + (log(0.2) - log(0.8)) * progress)
      let center = WorldPoint(x: 1100 * progress + (step > 45 ? sin(Double(step) / 8) * 20 : 0), y: 0)
      show(center: center, scale: scale, settled: false)
      try await Task.sleep(for: .milliseconds(16))
      XCTAssertEqual(model.presence?.camera, .init(center: center, scale: scale))
      let resources = SceneRenderResources.shared
      XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
      XCTAssertLessThanOrEqual(resources.pendingWebRequestCount, 1,
        "Camera samples replace the next address instead of accumulating WebKit work")
      if let cohort = model.compositionTiles.published,
        cohort.plan.allowsLive(.element(diagram.id), in: .board(boardID)),
        cohort.nativeInk.owners[.cover(distant)]?.canvas.isDescendant(of: host.view) == true,
        cohort.hasInstalledPixels(for: address),
        firstShown == nil { firstShown = start.duration(to: ContinuousClock.now) }
    }
    let shown = model.compositionTiles.published
    let diagnostic = "firstShown=\(String(describing: firstShown)); active=\(model.inputIsActive); phase=\(model.presencePhase); scenePending=\(model.scenePreparationPending); preparing=\(model.compositionTiles.isPreparing); failure=\(model.compositionTiles.failure ?? "none"); refusals=\(model.compositionTiles.budgetFailures); diagramLive=\(shown?.plan.allowsLive(.element(diagram.id), in: .board(boardID)) == true); diagramPixels=\(shown?.hasInstalledPixels(for: address) == true); coverMounted=\(shown?.nativeInk.owners[.cover(distant)]?.canvas.isDescendant(of: host.view) == true); rasterViews=\(rasterViews(in: host.view).count); receipts=\(String(describing: shown?.sourceReceipts[address])); items=\(shown?.frame.workset(boardID: boardID).items.map(\.id) ?? [])"
    let report = XCTAttachment(string: diagnostic); report.name = "Zoom-out coverage while camera remains active"; report.lifetime = .keepAlways; add(report)
    XCTAssertNotNil(firstShown, diagnostic)
    XCTAssertTrue(model.inputIsActive)
    XCTAssertEqual(model.presencePhase, .active)
    XCTAssertEqual(model.spatialInk, originalInk)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: diagram.id)?.html, diagram.html)
    let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
    let pixels = XCTAttachment(image: image); pixels.name = "New notebook and diagram during zoom-out"; pixels.lifetime = .keepAlways; add(pixels)
    model.inputGate.endContact(source: contact)
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
  }

  func testScenePreparationKeepsPencilAndContentContactProtected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.permitsScenePreparation)
    let finger = UUID(), pencil = UUID()
    model.inputGate.beginContact(source: finger)
    XCTAssertFalse(model.permitsScenePreparation, "A content contact is not a camera gesture")
    model.updatePresence(try XCTUnwrap(model.presence), settled: false)
    XCTAssertTrue(model.permitsScenePreparation)
    XCTAssertFalse(model.permitsBackgroundPreparation, "Camera coverage does not enable unrelated background work")
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    XCTAssertFalse(model.permitsScenePreparation, "Accepted Pencil closes publication even while the camera phase is active")
    model.inputGate.endPencilAction(source: pencil)
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    XCTAssertFalse(model.permitsScenePreparation)
    model.inputGate.endContact(source: finger)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    XCTAssertTrue(model.permitsScenePreparation)
  }

  private func rasterViews(in view: UIView) -> [AgentSnapshotRasterView] {
    (view as? AgentSnapshotRasterView).map { [$0] } ?? view.subviews.flatMap { rasterViews(in: $0) }
  }
}
