import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// Installed native finger owner, actual cover ink, the ordinary model writer
/// and whole-window pixels. Synthetic contacts are not hardware-finger latency.
@MainActor
final class NotebookItemDropUXTests: XCTestCase {
  func testInstalledDeleteControlAndRepeatedHistoryPreserveActualCoverInk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-delete-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID), a = try XCTUnwrap(model.workspace?.selectedItemID)
    let aCenter = WorldPoint(x: -900, y: 0), bCenter = WorldPoint(x: 900, y: 0)
    let bResult = await model.createNotebook(at: bCenter)
    let b = try XCTUnwrap(bResult), local = CGPoint(x: 417, y: 800)
    XCTAssertNotNil(model.moveItem(a, to: aCenter))
    for (id, color) in [(a, SpatialInkColor(red: 0, green: 0.15, blue: 1)), (b, .init(red: 1, green: 0, blue: 0))] {
      XCTAssertNotNil(model.appendSpatialInk(tool: .pen, color: color, spans: [.init(surface: .cover(id), samples: [
        .init(point: .init(x: local.x - 30, y: local.y), timeOffset: 0, width: 80, opacity: 1, force: 1, azimuth: 0, altitude: 1),
        .init(point: .init(x: local.x + 30, y: local.y), timeOffset: 0.1, width: 80, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      ])]))
    }
    let presence = SessionPresence(boardID: board, mode: .board,
      camera: .init(center: .zero, scale: 0.25), viewport: .init(x: 1194, y: 834))
    model.updatePresence(presence, settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let window = try await mountNotebookScene(model)
    let left = screen(local, center: aCenter, presence: presence), right = screen(local, center: bCenter, presence: presence)
    try await assertUX("item-delete-original-pixels", since: .now, budget: .seconds(2), window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([(left, .blue), (right, .red)])
    }
    model.selectWorkspaceItem(a, boardID: board)
    try await assertUX("item-delete-installed-control", since: .now, window: window) {
      self.findControls(in: window)?.destructiveActions.first is UIAction
    }
    let controls = try XCTUnwrap(findControls(in: window))
    let remove = try XCTUnwrap(controls.destructiveActions.first as? UIAction)
    UIButton().sendAction(remove) // Execute the installed native menu's real command.
    try await assertUX("item-delete-no-old-pixels", since: .now, budget: .seconds(2), window: window) {
      try model.workspace?.item(id: a) == nil && NotebookUXObservation.Pixels(window: window).matches([(left, .paper), (right, .red)])
    }
    for _ in 0..<2 {
      let previousRevision = try XCTUnwrap(model.compositionTiles.published).plan.revision
      let start = ContinuousClock.now
      var committed: Duration?
      var phases: [String] = []
      model.compositionTiles.onPreparationPhase = { _, phase in
        phases.append("\(start.duration(to: .now)): \(phase)")
      }
      // Observe the restored native owners after their CA commit. Repeated
      // window readback here would compete with the very mount being timed.
      let link = UIUpdateLink(view: window)
      link.addAction(to: .afterCATransactionCommit) { _, _ in
        guard committed == nil, let cohort = model.compositionTiles.published,
          let revision = model.workspaceHeader?.cursor,
          cohort.plan.rootBoardID == board, cohort.plan.revision > previousRevision,
          cohort.validatedSpatialRevision >= revision, cohort.isPaintInstalled,
          [a, b].allSatisfy({ id in
            guard model.workspace?.item(id: id) != nil, !model.isItemBeingDeleted(id),
              cohort.frame.index.item(id: id) != nil,
              let pose = model.compositionTiles.surfaceRegistry.pose(for: .cover(id)) else { return false }
            return pose.boardID == board && pose.cohortID == cohort.id
              && pose.cohortRevision == cohort.plan.revision && pose.retiredAtRevision == nil
              && !pose.isContentReleased && pose.contentView.window === window
          }) else { return }
        committed = start.duration(to: .now)
      }
      link.isEnabled = true
      defer { link.isEnabled = false; model.compositionTiles.onPreparationPhase = nil }
      model.undoLastSurfaceAction()
      let undone = await model.finishPendingPersistence(); XCTAssertTrue(undone)
      let readiness = try await NotebookUXObservation.observe(since: start,
        budget: NotebookUXObservation.correctnessTimeout) { committed != nil }
      link.isEnabled = false; model.compositionTiles.onPreparationPhase = nil
      let cohort = model.compositionTiles.published
      let report = "Undo native restoration: committed=\(String(describing: committed)); observed=\(readiness.elapsed); ceiling=\(readiness.budget); SQL=\(String(describing: model.workspaceHeader?.cursor)); cohort=\(String(describing: cohort?.plan.revision)); paintInstalled=\(cohort?.isPaintInstalled == true). CA commit and mounted owners, not physical scanout.\n" + phases.joined(separator: "\n")
      let readinessEvidence = XCTAttachment(string: report)
      readinessEvidence.name = "item-delete-undo-native-readiness"; readinessEvidence.lifetime = .keepAlways; add(readinessEvidence)
      XCTAssertTrue(committed.map { $0 <= readiness.budget } == true, report)
      // One independent picture checks material after the native observation;
      // its capture cost does not become an application latency measurement.
      let captureStart = ContinuousClock.now
      let pixels = try NotebookUXObservation.Pixels(window: window)
      let correct = try pixels.matches([(left, .blue), (right, .red)])
      let captureEvidence = XCTAttachment(string: "correct=\(correct); capture+check=\(captureStart.duration(to: .now)); one post-readiness window capture")
      captureEvidence.name = "item-delete-undo-keeps-material"; captureEvidence.lifetime = .keepAlways; add(captureEvidence)
      XCTAssertTrue(correct, "The first post-readiness picture must restore both covers and their ink")
      let shot = XCTAttachment(image: pixels.image)
      shot.name = "item-delete-undo-actual-window"; shot.lifetime = .keepAlways; add(shot)
      model.redoLastSurfaceAction()
      let repeated = await model.finishPendingPersistence(); XCTAssertTrue(repeated)
      try await assertUX("item-delete-redo-no-resurrection", since: .now, window: window) {
        try NotebookUXObservation.Pixels(window: window).matches([(left, .paper), (right, .red)])
      }
    }
  }

  func testHeldCoverDropKeepsItsInkAndIsOneVisibleUndoRedo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-drop-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID), a = try XCTUnwrap(model.workspace?.selectedItemID)
    let aCenter = WorldPoint(x: -900, y: 0), bCenter = WorldPoint(x: 900, y: 0)
    let bResult = await model.createNotebook(at: bCenter)
    let b = try XCTUnwrap(bResult)
    XCTAssertNotNil(model.moveItem(a, to: aCenter))
    let local = CGPoint(x: 417, y: 800)
    for (id, color) in [(a, SpatialInkColor(red: 0, green: 0.15, blue: 1)),
      (b, .init(red: 1, green: 0, blue: 0))] {
      XCTAssertNotNil(model.appendSpatialInk(tool: .pen, color: color, spans: [.init(surface: .cover(id), samples: [
        .init(point: .init(x: local.x - 30, y: local.y), timeOffset: 0, width: 80, opacity: 1, force: 1, azimuth: 0, altitude: 1),
        .init(point: .init(x: local.x + 30, y: local.y), timeOffset: 0.1, width: 80, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      ])]))
    }
    let presence = SessionPresence(boardID: board, mode: .board,
      camera: .init(center: .zero, scale: 0.25), viewport: .init(x: 1194, y: 834))
    model.updatePresence(presence, settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let history = try model.store.nativeHistory(domain: .board(board), actor: model.actorID)
    let window = try await mountNotebookScene(model)
    let registry = model.compositionTiles.surfaceRegistry
    try await assertUX("item-drop-ready", since: .now, budget: .seconds(2), window: window) {
      registry.pose(for: .cover(a)) != nil && registry.pose(for: .cover(b)) != nil
    }
    let pose = try XCTUnwrap(registry.pose(for: .cover(a)))
    let finger = try XCTUnwrap(findFinger(in: pose.contentView))
    let observer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
    let original = screen(local, center: aCenter, presence: presence)
    let target = screen(local, center: bCenter, presence: presence)
    try await assertUX("item-drop-original-pixels", since: .now, budget: .seconds(2), window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([(original, .blue), (target, .red)])
    }

    let touch = UXTouch(window: window, kind: .direct), event = ItemDropEvent()
    touch.point = original; touch.sourceView = finger; event.touch = touch
    observer.touchesBegan([touch], with: event); finger.touchesBegan([touch], with: event)
    try await Task.sleep(for: .milliseconds(320))
    XCTAssertTrue(pose.isManipulating, "The installed quiet hold must own this drag")
    touch.point = target; touch.touchPhase = .moved; touch.sampleTime += 0.1
    observer.touchesMoved([touch], with: event); finger.touchesMoved([touch], with: event)
    touch.touchPhase = .ended
    finger.touchesEnded([touch], with: event); observer.touchesEnded([touch], with: event)
    let command = try XCTUnwrap(model.itemPlacementCommands[a])
    XCTAssertTrue(model.itemPlacementCommands[b] === command)
    try await assertUX("item-drop-published", since: .now, budget: .seconds(2), window: window) {
      command.accepted != nil && !pose.isEngaged
    }
    let stack = try XCTUnwrap(model.board?.stack(containing: a))
    XCTAssertEqual(stack.center, bCenter); XCTAssertEqual(stack.itemIDs, [b, a])
    let fanCenter = try XCTUnwrap(WorkspaceItemStackPresentation.focusedCenter(of: a, in: stack))
    let dropped = screen(local, center: fanCenter, presence: presence)
    try await assertUX("item-drop-keeps-actual-ink", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([(original, .paper), (dropped, .blue)])
    }
    XCTAssertEqual(try model.store.nativeHistory(domain: .board(board), actor: model.actorID), history + [.command(command.id)])
    model.undoLastSurfaceAction()
    let undone = await model.finishPendingPersistence(); XCTAssertTrue(undone)
    try await assertUX("item-drop-one-undo-restores-ink", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([(original, .blue), (target, .red)])
    }
    XCTAssertNil(model.board?.stack(containing: a))
    model.redoLastSurfaceAction()
    let repeated = await model.finishPendingPersistence(); XCTAssertTrue(repeated)
    try await assertUX("item-drop-one-redo-restores-stack", since: .now, window: window) {
      try NotebookUXObservation.Pixels(window: window).matches([(original, .paper), (dropped, .blue)])
    }
    XCTAssertEqual(model.board?.stack(containing: a)?.id, stack.id)
    let image = XCTAttachment(image: try NotebookUXObservation.Pixels(window: window).image)
    image.name = "item-drop-redo-actual-window"; image.lifetime = .keepAlways; add(image)
  }

  private func screen(_ local: CGPoint, center: WorldPoint, presence: SessionPresence) -> CGPoint {
    let geometry = WorkspaceItemGeometry.notebook
    let point = presence.camera.worldToScreen(center.offsetBy(x: local.x - geometry.width / 2,
      y: local.y - geometry.height / 2), viewport: presence.viewport)
    return .init(x: point.x, y: point.y)
  }

  private func findFinger(in view: UIView) -> NotebookInteractionTouchView? {
    if let owner = view as? NotebookInteractionTouchView { return owner }
    for child in view.subviews {
      if let found = self.findFinger(in: child) { return found }
    }
    return nil
  }

  private func findControls(in view: UIView) -> NotebookSelectionControlsView? {
    if let controls = view as? NotebookSelectionControlsView, controls.window != nil, !controls.isHidden { return controls }
    for child in view.subviews {
      if let found = self.findControls(in: child) { return found }
    }
    return nil
  }
}

@MainActor private final class ItemDropEvent: UIEvent {
  var touch: UITouch?
  override var allTouches: Set<UITouch>? { touch.map { [$0] } }
}
