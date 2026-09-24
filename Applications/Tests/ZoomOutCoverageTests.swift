import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class ZoomOutCoverageTests: XCTestCase {
  func testNewlyVisibleNotebookAppearsBeforeTheCameraContactEnds() async throws {
    try await checkNewlyVisibleContent(nested: false)
  }

  func testInstalledPinchRevealsPixelsBeforeEitherFingerLifts() async throws {
    try await checkNewlyVisibleContent(nested: false, nativeGesture: true)
  }

  func testInkedNestedBoardRevealsContentDuringContinuousPinch() async throws {
    try await checkNewlyVisibleContent(nested: true)
  }

  func testCameraCoverageAdvancesPastAnExternalCommitWithoutLiftingFingers() async throws {
    try await checkNewlyVisibleContent(nested: true, advancesSource: true)
  }

  func testMixedSceneRefinesPixelsWhileZoomRemainsHeld() async throws {
    try await checkNewlyVisibleContent(nested: true, mixed: true, nativeGesture: true)
  }

  private func checkNewlyVisibleContent(nested: Bool, advancesSource: Bool = false, mixed: Bool = false,
    nativeGesture: Bool = false) async throws {
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
    if nested {
      let parent = try XCTUnwrap(model.presence?.boardID)
      let child = try XCTUnwrap(model.createBoard(at: .zero))
      func ink(_ surface: SurfaceID) {
        _ = model.appendSpatialInk(tool: .pen, color: .black, spans: [.init(surface: surface,
          samples: [0.0, 100.0].map { .init(point: .init(x: $0, y: $0), worldPoint: .init(x: $0, y: $0),
            timeOffset: $0 / 100, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1) })])
      }
      ink(.board(parent))
      model.updatePresence(.init(boardID: child, mode: .board, camera: .init(),
        viewport: .init(x: 834, y: 1194)), settled: true)
      _ = model.createNotebook(at: .zero)
      ink(.board(child))
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      await model.reloadExternalChanges()?.value
    }
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    model.moveItem(first, to: .zero)
    let distant = try XCTUnwrap(model.createNotebook(at: .init(x: 2400, y: 0)))
    model.selectItem(first)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let fixtureItems = try model.store.readItemHeaders(limit: 8).map(\.item)
    XCTAssertEqual(fixtureItems.count, nested ? 4 : 2)
    let before = try model.store.loadBoard(items: fixtureItems)
    var after = before
    let diagram = SpatialElement(id: "offscreen-diagram", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 400, height: 300), worldOrigin: .init(x: 1700, y: 800),
      source: "A blue circle to reveal while zooming out", html: "<svg viewBox='0 0 400 300'><rect width='400' height='300' fill='white'/><circle cx='200' cy='150' r='100' fill='#156dd9'/></svg>",
      css: "", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(after.upsertElement(diagram, in: boardID, expected: nil, actor: model.actorID))
    if mixed {
      for i in 0..<3 {
        let program = SpatialElement(id: "program-\(i)", surface: .board(boardID), kind: .web,
          frame: .init(x: 0, y: 0, width: 350, height: 180), worldOrigin: .init(x: 1500 + Double(i % 2)*420, y: 100 + Double(i/2)*250),
          source: "Interactive program", html: "<button onclick='this.textContent=Number(this.textContent)+1'>1</button><input value='Input stays live'>",
          css: "body{background:white;font:24px sans-serif}button,input{font:inherit}", stamp: .init(counter: 0, actor: model.actorID))
        XCTAssertTrue(after.upsertElement(program, in: boardID, expected: nil, actor: model.actorID))
      }
      for i in 0..<2 {
        let label = SpatialElement(id: "label-\(i)", surface: .board(boardID), kind: .nativeText,
          frame: .init(x: 0, y: 0, width: 900, height: 80), worldOrigin: .init(x: 1500, y: 30 + Double(i)*650),
          source: "Чёткий текст и тонкие линии · \(i)", textStyle: .init(fontSize: 28), stamp: .init(counter: 0, actor: model.actorID))
        XCTAssertTrue(after.upsertElement(label, in: boardID, expected: nil, actor: model.actorID))
      }
      let svg = SpatialElement(id: "thin-lines", surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 400, height: 250), worldOrigin: .init(x: 2120, y: 800),
        source: "Vector line detail", html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 250'><rect width='400' height='250' fill='white'/><path d='M20 210L130 40L220 180L380 30' fill='none' stroke='#123' stroke-width='1.5'/><text x='20' y='235' font-size='20'>SVG thin lines</text></svg>", stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(after.upsertElement(svg, in: boardID, expected: nil, actor: model.actorID))
    }
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    let viewport = SpatialPoint(x: 834, y: 1194)
    var pinch: HeldCoveragePinch?
    var cameraDelivery = NotebookUXObservation.CameraDelivery(), expectedCameraInputs = 0
    func show(center: WorldPoint, scale: Double, settled: Bool) {
      if let pinch {
        let due = CACurrentMediaTime()
        expectedCameraInputs += 1
        pinch.move(center: center, scale: scale)
        if let input = pinch.recognizer.cameraInput {
          cameraDelivery.inputs.append(.init(id: input, due: due, scale: scale, center: center,
            requiresAction: pinch.recognizer.intent == .magnification))
        }
        return
      }
      model.updatePresence(.init(boardID: boardID, mode: .board,
        camera: .init(center: center, scale: scale), viewport: viewport), settled: settled)
    }
    let initialScale = nested ? 3.2 : 0.8
    show(center: .zero, scale: initialScale, settled: true)
    window.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    let initialDeadline = ContinuousClock.now + .seconds(8)
    while (model.compositionTiles.published == nil || model.scenePreparationPending || model.compositionTiles.isPreparing),
      ContinuousClock.now < initialDeadline { try await Task.sleep(for: .milliseconds(20)) }
    let initial = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "Initial notebook")
    if nested {
      XCTAssertEqual(initial.plan.inkBoardIDs, [boardID], "Explicit Back does not reserve invisible parent ink")
      XCTAssertTrue(initial.plan.meetsRequiredDensity)
    }
    XCTAssertFalse(initial.plan.allowsLive(.item(distant), in: .board(boardID)))
    // Preparing offscreen material is the intended solution, not a failure.
    // Prove that this source really starts outside the camera instead of
    // forbidding its bounded prefetch owner.
    XCTAssertTrue(SceneSourceCapture.visibleRect(source: agentElementSnapshotSource(diagram),
      origin: diagram.worldOrigin ?? .zero, presence: try XCTUnwrap(model.presence)).isNull)
    if advancesSource {
      let before = try model.store.loadBoard(items: fixtureItems)
      var changed = before
      let extra = SpatialElement(id: "new-peer-label", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 200, height: 50), worldOrigin: .init(x: 5000, y: 5000),
        source: "Peer content outside this viewport", stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(changed.upsertElement(extra, in: boardID, expected: nil, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: changed)
      // Deliberately leave the displayed cut behind a new durable source. The
      // next camera window must advance safely, not wait for a fingers-up event.
    }
    let originalInk = model.spatialInk
    let contact = UUID()
    if nativeGesture {
      pinch = try HeldCoveragePinch(window: window, presence: XCTUnwrap(model.presence))
      pinch?.recognizer.onCameraHandled = { input, entered, handled in
        guard let camera = model.presence?.camera else { return }
        cameraDelivery.receipts.append(.init(id: input, scale: camera.scale, center: camera.center,
          entered: entered, handled: handled))
      }
    } else { model.inputGate.beginContact(source: contact) }
    defer {
      pinch?.recognizer.onCameraHandled = nil
      pinch?.end()
      if !nativeGesture { model.inputGate.endContact(source: contact) }
    }
    let start = ContinuousClock.now
    var firstShown: Duration?
    var firstVisible: Duration?
    var probeVisible: ContinuousClock.Instant?, pixelsShown: Duration?
    let address = SceneSourceAddress(plane: .board(boardID), elementID: diagram.id)
    var committedCoverage = NotebookUXObservation.Coverage()
    var pixelCoverage = NotebookUXObservation.Coverage()
    var firstMissingPixels: (UIImage, String)?
    var preparationTimeline: [String] = [], previousPreparation = ""
    model.compositionTiles.onPreparationPhase = { id, phase in
      preparationTimeline.append("\(start.duration(to: .now)): request=\(id.uuidString.prefix(6)); phase=\(phase)")
    }
    defer { model.compositionTiles.onPreparationPhase = nil }
    // Observe every UIKit commit without taking a screenshot or forcing a CA
    // flush inside the render loop. This proves submitted native coverage, NOT
    // physical scanout/FPS. Separate pixel probes below check its appearance.
    let coverageLink = UIUpdateLink(view: window)
    coverageLink.addAction(to: .afterCATransactionCommit) { _, _ in
      guard model.inputIsActive, let current = model.presence else { return }
      let point = current.camera.worldToScreen(.init(x: 1900, y: 950), viewport: current.viewport)
      guard window.bounds.contains(CGPoint(x: point.x, y: point.y)) else { return }
      committedCoverage.record(model.compositionTiles.published?.hasInstalledPixels(for: address) == true)
    }
    coverageLink.isEnabled = nativeGesture
    defer { coverageLink.isEnabled = false }
    // Keep taking real camera samples. Holding the final view without lifting
    // is not enough: coverage must make progress while samples keep arriving.
    for step in 0..<150 {
      let progress = min(1, Double(step) / 45)
      let scale = exp(log(initialScale) + (log(0.2) - log(initialScale)) * progress)
      // Establish pinch intent before translating the pair; otherwise the
      // initial centroid displacement correctly classifies as two-finger pan.
      let translation = nativeGesture ? max(0, (progress - 0.15) / 0.85) : progress
      let center = WorldPoint(x: 1100 * translation + (step > 45 ? sin(Double(step) / 8) * 20 : 0), y: 0)
      let sampleStart = ContinuousClock.now
      show(center: center, scale: scale, settled: false)
      if nativeGesture, probeVisible == nil, let current = model.presence {
        let point = current.camera.worldToScreen(.init(x: 1900, y: 950), viewport: current.viewport)
        if window.bounds.contains(CGPoint(x: point.x, y: point.y)) {
          // Include the revealing input handler and the first display wait.
          probeVisible = sampleStart
        }
      }
      if firstVisible == nil, let current = model.presence {
        let visible = SceneSourceCapture.visibleRect(source: agentElementSnapshotSource(diagram),
          origin: diagram.worldOrigin ?? .zero, presence: current)
        if !visible.isNull && !visible.isEmpty { firstVisible = start.duration(to: .now) }
      }
      try await Task.sleep(for: .milliseconds(16))
      let current = try XCTUnwrap(model.presence)
      let cohort = model.compositionTiles.published
      let preparation = "indexed=\(model.sceneIndex?.element(id: diagram.id, boardID: boardID) != nil); receipt=\(cohort?.sourceReceipts[address].map { String(describing: $0.status) } ?? "absent"); installed=\(cohort?.hasInstalledPixels(for: address) == true); scenePending=\(model.scenePreparationPending); preparing=\(model.compositionTiles.isPreparing); web=\(SceneRenderResources.shared.activeWebSurfaceCount); pendingWeb=\(SceneRenderResources.shared.pendingWebRequestCount)"
      if preparation != previousPreparation {
        preparationTimeline.append("\(start.duration(to: .now)): scale=\(current.camera.scale); \(preparation)")
        previousPreparation = preparation
      }
      if !nativeGesture {
        XCTAssertEqual(current.camera.scale, scale, accuracy: 0.00001)
        XCTAssertEqual(current.camera.center.delta(to: center).x, 0, accuracy: 0.001)
        XCTAssertEqual(current.camera.center.delta(to: center).y, 0, accuracy: 0.001)
      }
      let resources = SceneRenderResources.shared
      XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
      XCTAssertLessThanOrEqual(resources.pendingWebRequestCount, mixed ? 7 : nested ? 2 : 1,
        "Camera samples replace the next address instead of accumulating WebKit work")
      if let cohort = model.compositionTiles.published,
        cohort.nativeInk.owners[.cover(distant)]?.canvas.isDescendant(of: host.view) == true,
        cohort.hasInstalledPixels(for: address),
        firstShown == nil { firstShown = start.duration(to: ContinuousClock.now) }
      if nativeGesture {
        let point = current.camera.worldToScreen(.init(x:1900,y:950),viewport:current.viewport)
        if CGRect(origin:.zero,size:window.bounds.size).contains(CGPoint(x:point.x,y:point.y)) {
          // UIKit can deliver the recognizer action during the display wait,
          // after the immediate presence read above. Keep that input's origin.
          if probeVisible == nil { probeVisible = sampleStart }
          let pixels = try NotebookUXObservation.Pixels(window: window)
          let visible = try pixels.matches([(.init(x:point.x,y:point.y),.blue)])
          if !visible, firstMissingPixels == nil {
            firstMissingPixels = (pixels.image,
              "step=\(step); elapsed=\(start.duration(to: .now)); point=\(point); camera=\(current.camera); \(preparation)")
          }
          // No initial 100 ms of blank paper is forgiven. Missing on the first
          // applicable observation is as much a defect as disappearing later.
          pixelCoverage.record(visible)
          if pixelsShown == nil, visible {
            pixelsShown = try XCTUnwrap(probeVisible).duration(to: .now)
          }
        }
      }
    }
    let shown = model.compositionTiles.published
    let diagnostic = "firstVisible=\(String(describing: firstVisible)); firstShown=\(String(describing: firstShown)); active=\(model.inputIsActive); phase=\(model.presencePhase); scenePending=\(model.scenePreparationPending); preparing=\(model.compositionTiles.isPreparing); failure=\(model.compositionTiles.failure ?? "none"); refusals=\(model.compositionTiles.budgetFailures); diagramLive=\(shown?.plan.allowsLive(.element(diagram.id), in: .board(boardID)) == true); diagramPixels=\(shown?.hasInstalledPixels(for: address) == true); coverMounted=\(shown?.nativeInk.owners[.cover(distant)]?.canvas.isDescendant(of: host.view) == true); rasterViews=\(rasterViews(in: host.view).count); receipts=\(String(describing: shown?.sourceReceipts[address])); items=\(shown?.frame.workset(boardID: boardID).items.map(\.id) ?? [])"
    let report = XCTAttachment(string: diagnostic); report.name = "Zoom-out coverage while camera remains active"; report.lifetime = .keepAlways; add(report)
    let timeline = XCTAttachment(string: preparationTimeline.joined(separator: "\n"))
    timeline.name = "Held zoom preparation timeline"; timeline.lifetime = .keepAlways; add(timeline)
    XCTAssertNotNil(firstShown, diagnostic)
    XCTAssertTrue(model.inputIsActive)
    XCTAssertEqual(model.presencePhase, .active)
    XCTAssertEqual(model.spatialInk, originalInk)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: diagram.id)?.html, diagram.html)
    let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
    let pixels = XCTAttachment(image: image); pixels.name = "New notebook and diagram during zoom-out"; pixels.lifetime = .keepAlways; add(pixels)
    if nativeGesture {
      if let firstMissingPixels {
        let pixels = XCTAttachment(image: firstMissingPixels.0)
        pixels.name = "First missing held-zoom pixels"; pixels.lifetime = .keepAlways; add(pixels)
        let state = XCTAttachment(string: firstMissingPixels.1)
        state.name = "First missing held-zoom state"; state.lifetime = .keepAlways; add(state)
      }
      XCTAssertTrue(pixelCoverage.passed,
        "Zero blank observations from first exposure: \(pixelCoverage.missing)/\(pixelCoverage.checked) missing. First observed pixels=\(String(describing: pixelsShown)); capture time is not FPS")
      let presence = try XCTUnwrap(model.presence)
      let probe = presence.camera.worldToScreen(.init(x: 1900, y: 950), viewport: presence.viewport)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window: window).matches([
        (.init(x: probe.x, y: probe.y), .blue)
      ]), "The newly visible SVG must have actual blue pixels before either installed contact ends")
      XCTAssertEqual(pinch?.recognizer.intent, .magnification)
    }
    if mixed {
      var refinementStart: ContinuousClock.Instant?, refinedAfter: Duration?
      for step in 0..<90 {
        let progress = min(1, Double(step)/45)
        if step == 45 { refinementStart = .now }
        show(center: .init(x: 2000, y: 530), scale: exp(log(0.2) + (log(0.752)-log(0.2))*progress), settled: false)
        try await Task.sleep(for: .milliseconds(16))
        if let refinementStart, refinedAfter == nil, let detailed = model.compositionTiles.published,
          detailed.plan.meetsRequiredDensity,
          [diagram.id, "thin-lines"].allSatisfy({ id in
            guard let receipt = detailed.sourceReceipts[.init(plane: .board(boardID), elementID: id)] else { return false }
            return receipt.hasCurrentPixels && receipt.installedScale * sqrt(2.0) >= 0.752 * 2
          }), let current = model.presence {
          let point = current.camera.worldToScreen(.init(x: 1900, y: 950), viewport: current.viewport)
          if try NotebookUXObservation.Pixels(window: window).matches([(.init(x: point.x, y: point.y), .blue)]) {
            refinedAfter = refinementStart.duration(to: .now)
          }
        }
      }
      XCTAssertLessThanOrEqual(try XCTUnwrap(refinedAfter, "Held zoom never installed current full-density material"),
        NotebookUXObservation.zoomRefinement,
        "Refinement gets 250 ms from the input requesting final density, not five seconds after the gesture loop")
      let detailed = try XCTUnwrap(model.compositionTiles.published)
      XCTAssertTrue(model.inputIsActive)
      XCTAssertEqual(model.presencePhase, .active)
      XCTAssertTrue(detailed.plan.meetsRequiredDensity, "A small mixed scene cannot settle for blurry overview tiles")
      for id in [diagram.id, "thin-lines"] {
        let receipt = try XCTUnwrap(detailed.sourceReceipts[.init(plane: .board(boardID), elementID: id)])
        XCTAssertTrue(receipt.hasCurrentPixels)
        XCTAssertGreaterThanOrEqual(receipt.installedScale * sqrt(2.0), 0.752 * 2)
      }
      XCTAssertNil(model.compositionTiles.failure)
      let note = XCTAttachment(string: "tiles=\(detailed.plan.tiles.map { "\($0.pixelSize)/\($0.tile.worldSize)" }); refusals=\(model.compositionTiles.budgetFailures); heldBytes=\(SceneRenderResources.shared.rasterAdmission.heldBytes)")
      note.name = "Mixed scene held-zoom density"; note.lifetime = .keepAlways; add(note)
      let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let screenshot = XCTAttachment(image: image)
      screenshot.name = "Mixed scene during held zoom"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    if nativeGesture {
      coverageLink.isEnabled = false
      XCTAssertEqual(cameraDelivery.inputs.count, expectedCameraInputs)
      XCTAssertTrue(cameraDelivery.passed,
        "Every measured camera pose needs an installed action within its original 5/16.67-ms budgets, before finger-up")
      let handling = XCTAttachment(string: cameraDelivery.report)
      handling.name = "Held coverage camera delivery"; handling.lifetime = .keepAlways; add(handling)
      XCTAssertTrue(committedCoverage.passed,
        "Visible material must have native pixels at EVERY observed UIKit commit, from first exposure through refinement: \(committedCoverage.missing)/\(committedCoverage.checked) holes. No grace period, no average")
      let note = XCTAttachment(string: "commits=\(committedCoverage.checked); committed holes=\(committedCoverage.missing); pixel probes=\(pixelCoverage.checked); blank pixel probes=\(pixelCoverage.missing). UIKit commits are not OS display acknowledgements.")
      note.name = "Held zoom zero-hole coverage"; note.lifetime = .keepAlways; add(note)
    }
    if let pinch { pinch.end() }
    else {
      model.inputGate.endContact(source: contact)
      model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    }
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

/// Delivers measured fingers to the recognizer and contact observer installed by
/// SpatialWorkspaceView. No direct presence update or extra preparation call can
/// conceal a missing camera-to-composition wake-up.
@MainActor final class HeldCoveragePinch {
  let recognizer: TwoFingerPaperGestureRecognizer
  private let observer: NotebookContactObserver
  private let basis: SessionPresence
  private let first: UXTouch, second: UXTouch
  private let event = UIEvent()
  private var ended = false
  private var contacts: Set<UITouch> { [first, second] }

  init(window: UIWindow, presence: SessionPresence) throws {
    recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TwoFingerPaperGestureRecognizer }.first)
    observer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
    basis = presence
    first = UXTouch(window: window, kind: .direct); second = UXTouch(window: window, kind: .direct)
    first.point = .init(x: presence.viewport.x / 2 - 200, y: presence.viewport.y / 2)
    second.point = .init(x: presence.viewport.x / 2 + 200, y: presence.viewport.y / 2)
    second.sampleTime = first.sampleTime
    for touch in [first, second] { touch.sourceView = window.hitTest(touch.point, with: event) }
    observer.touchesBegan(contacts, with: event)
    recognizer.touchesBegan(contacts, with: event)
  }

  func move(center: WorldPoint, scale: Double) {
    let delta = basis.camera.center.delta(to: center), halfDistance = 200 * scale / basis.camera.scale
    let centroid = CGPoint(x: basis.viewport.x / 2 - delta.x * scale, y: basis.viewport.y / 2 - delta.y * scale)
    first.point = .init(x: centroid.x - halfDistance, y: centroid.y)
    second.point = .init(x: centroid.x + halfDistance, y: centroid.y)
    first.sampleTime += 0.016; second.sampleTime = first.sampleTime
    first.touchPhase = .moved; second.touchPhase = .moved
    recognizer.touchesMoved(contacts, with: event)
  }

  func end() {
    guard !ended else { return }; ended = true
    first.touchPhase = .ended; second.touchPhase = .ended
    recognizer.touchesEnded(contacts, with: event)
    observer.touchesEnded(contacts, with: event)
  }
}
