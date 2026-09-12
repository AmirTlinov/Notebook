import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class WorkspaceItemPoseTests: XCTestCase {
  func testDropAcknowledgementUsesOnlyTheMovedItemsCanonicalHeads() throws {
    let item = UUID(), neighbor = UUID(), actor = UUID()
    var before = BoardDocument(freeItems: [], stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(before.addItem(item, near: .zero, actor: actor))
    XCTAssertTrue(before.addItem(neighbor, near: .init(x: 1_000, y: 0), actor: actor))
    var after = before
    XCTAssertTrue(after.moveItem(item, to: .init(x: 420, y: 160), actor: actor))
    let destination = try XCTUnwrap(WorkspaceItemPoseDestination(itemID: item, before: before, after: after))
    XCTAssertEqual(destination.center, WorldPoint(x: 420, y: 160))
    XCTAssertFalse(destination.isObserved(in: before))
    XCTAssertTrue(destination.isObserved(in: after))
    var unrelated = before
    XCTAssertTrue(unrelated.moveItem(neighbor, to: .init(x: 2_000, y: 0), actor: actor))
    XCTAssertFalse(destination.isObserved(in: unrelated), "A larger board clock is not acknowledgement of this drop")
    var subsequent = after
    XCTAssertTrue(subsequent.moveItem(item, to: .init(x: 540, y: 200), actor: UUID()))
    XCTAssertTrue(destination.isObserved(in: subsequent), "The next accepted move retires the old animation destination")

    var stacked = after
    XCTAssertNotNil(stacked.createStack(moving: item, onto: neighbor, actor: actor))
    let stackDestination = try XCTUnwrap(WorkspaceItemPoseDestination(itemID: item, before: after, after: stacked))
    XCTAssertNotNil(stackDestination.stack)
    XCTAssertFalse(stackDestination.isObserved(in: after))
    XCTAssertTrue(stackDestination.isObserved(in: stacked))
    XCTAssertTrue(stacked.unstackItem(item, at: .init(x: -200, y: 300), actor: actor))
    XCTAssertTrue(stackDestination.isObserved(in: stacked), "Unstacking observes the same item, not a retired stack field")
    XCTAssertNil(WorkspaceItemPoseDestination(itemID: item, before: stacked, after: stacked))
  }

  func testPencilFirstSampleUsesThePartlyLiftedNativeBodyAndCommitsBeforeReturn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pose-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    defer { try? FileManager.default.removeItem(at: root) }
    let (boardID, coverID) = try await Task.detached {
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      return (header.rootBoardID, try XCTUnwrap(store.readItemHeaders(limit: 1).first?.id))
    }.value
    let driver = try await Driver.make(boardID: boardID, coverIDs: [coverID], actor: actor)
    defer { driver.close() }
    let pose = try XCTUnwrap(driver.physical.poses[coverID])
    let finger = driver.interaction(coverID), fingerTouch = PoseTouch(type: .direct)
    finger.touchesBegan([fingerTouch], with: nil)
    try await waitUntil { driver.physical.lifted[coverID] == true }
    driver.physical.publish(coverID)
    let animation = try XCTUnwrap(pose.animator)
    animation.pauseAnimation(); animation.fractionComplete = 0.45
    CATransaction.flush()
    try await waitUntil {
      guard let surface = pose.screenSurface(in: driver.canvas) else { return false }
      return surface.screenScale > 0.300_01 && surface.screenScale < 0.310_49
    }
    let source = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    let corner = CGPoint(x: source.frame.minX + 0.01, y: source.frame.minY + 0.01)
    XCTAssertTrue(source.frame.contains(corner))
    XCTAssertFalse(source.contains(corner), "The rotated body's AABB must not claim empty corners")
    XCTAssertEqual(SpatialSurfaceRouter.surface(at: corner, covers: [source], board: .board(boardID)), .board(boardID))
    let first = CGPoint(x: 230, y: 350), second = CGPoint(x: 330, y: 370)
    driver.begin(at: first.applying(source.localToScreen))
    XCTAssertTrue(driver.gate.hasActivePencil, "The first accepted event is never delayed until a later lift or tap")
    XCTAssertNil(driver.registry.installedSource(on: .cover(coverID)), "The first sample already owns the physical ink tail")
    let frozen = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    XCTAssertNil(pose.animator, "The same native ancestor now belongs to the contact lease")
    XCTAssertEqual(driver.physical.lifted[coverID], true, "An already installed rank survives finger cancellation")
    fingerTouch.point.x += 100
    finger.touchesMoved([fingerTouch], with: nil)
    finger.touchesEnded([fingerTouch], with: nil)
    driver.physical.publish(coverID)
    driver.update() // A next composition request must not replace this accepted source.
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), frozen)
    XCTAssertTrue(driver.actions.isEmpty)
    driver.onCommit = {
      XCTAssertEqual(pose.screenSurface(in: driver.canvas), frozen)
      XCTAssertNil(pose.animator)
    }
    driver.end(at: second.applying(source.localToScreen))
    let action = try XCTUnwrap(driver.actions.first), span = try XCTUnwrap(action.spans.first)
    XCTAssertEqual(action.spans.count, 1)
    XCTAssertEqual(span.surface, .cover(coverID))
    XCTAssertEqual(span.samples.first?.point.x ?? -1, first.x, accuracy: 0.001)
    XCTAssertEqual(span.samples.first?.point.y ?? -1, first.y, accuracy: 0.001)
    XCTAssertEqual(span.samples.last?.point.x ?? -1, second.x, accuracy: 0.001)
    XCTAssertEqual(span.samples.last?.point.y ?? -1, second.y, accuracy: 0.001)
    XCTAssertEqual(span.samples.first?.width ?? -1, PenStyle.standard.width / source.screenScale, accuracy: 0.001)
    XCTAssertEqual(span.samples.first?.azimuth ?? -1, source.localAzimuth(0.4), accuracy: 0.001)
    XCTAssertEqual(try driver.registry.installedSource(on: .cover(coverID))?.referenceInk().actions.map(\.id), [action.id],
      "The accepted source is installed before the pose lease releases")
    XCTAssertNotNil(pose.animator, "Only the accepted tail releases the suspended return")
    let stamp = driver.journal.stamp
    let stored = try await Task.detached {
      _ = try store.commitSpatialInk(.append(action, journalStamp: stamp))
      return try store.readSpatialInk(surfaces: [.cover(coverID)])
    }.value
    XCTAssertEqual(stored.actions, [action], "The physical local point, action UUID and immutable samples survive the actual SQL command")
  }

  func testPencilCancelsAnUnexpiredFingerHoldWithoutAFalseTapOrRestart() async throws {
    let driver = try await Driver.make()
    defer { driver.close() }
    let id = driver.coverIDs[0], finger = driver.interaction(driver.coverIDs[0]), touch = PoseTouch(type: .direct)
    var taps = 0
    finger.onTap = { _, _ in taps += 1 }
    finger.touchesBegan([touch], with: nil)
    let surface = try XCTUnwrap(driver.physical.poses[id]?.screenSurface(in: driver.canvas))
    driver.begin(at: CGPoint(x: 200, y: 220).applying(surface.localToScreen))
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertTrue(driver.physical.engaged.isEmpty, "The old 180ms callback cannot revive a cancelled hold")
    touch.point.x += 40; finger.touchesMoved([touch], with: nil); finger.touchesEnded([touch], with: nil)
    XCTAssertEqual(taps, 0)
    driver.end(at: CGPoint(x: 250, y: 240).applying(surface.localToScreen))
    XCTAssertEqual(driver.actions.count, 1)
    finger.touchesBegan([touch], with: nil)
    try await waitUntil { driver.physical.lifted[id] == true }
    XCTAssertEqual(driver.physical.engaged, [id], "A new finger still acquires the same native owner")
    finger.cancelInteraction()
  }

  func testUnpublishedLiftRetractsItsRankBeforePencilAndLatePublicationCannotRaiseIt() async throws {
    let driver = try await Driver.make(coverIDs: [UUID(), UUID()])
    defer { driver.close() }
    let first = driver.coverIDs[0], second = driver.coverIDs[1]
    let pose = try XCTUnwrap(driver.physical.poses[first])
    let baseline = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    pose.beginLift()
    XCTAssertEqual(driver.physical.engaged, [first])
    // Pencil wins the same event-loop interval before SwiftUI installs the rank.
    driver.begin(at: CGPoint(x: 280, y: 350).applying(baseline.localToScreen))
    XCTAssertTrue(driver.gate.hasActivePencil)
    XCTAssertTrue(driver.physical.engaged.isEmpty)
    driver.physical.publish(first, rankOverride: 9_000) // Already queued before the retraction.
    driver.physical.publish(second)
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), baseline)
    let surfaces = try driver.coverIDs.map { try XCTUnwrap(driver.physical.poses[$0]?.screenSurface(in: driver.canvas)) }
    let overlap = CGPoint(x: 400, y: 300)
    XCTAssertEqual(SpatialSurfaceRouter.surface(at: overlap, covers: surfaces, board: .board(driver.boardID)),
      .cover(second), "A not-yet-shown request cannot lift a lower cover above its neighbor during the contact")
    driver.end(at: CGPoint(x: 290, y: 360).applying(baseline.localToScreen))
    XCTAssertEqual(driver.actions.count, 1)
    XCTAssertFalse(pose.isEngaged)
  }

  func testSwiftUIHostKeepsTheActualCoverOrderWhenPencilRetractsAnUnshownLift() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pose-order-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let registry = SpatialInkSurfaceRegistry(), a = UUID(), b = UUID(), boardID = UUID()
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 0.3), viewport: .init(x: 800, y: 600))
    let cohort = try await WorkspaceInkFixture.prepare(boardID: boardID, camera: presence.camera,
      viewport: presence.viewport, items: [
        .init(itemID: a, geometry: .notebook, center: .zero, zIndex: 0),
        .init(itemID: b, geometry: .notebook, center: .zero, zIndex: 1)], registry: registry)
    let host = UIHostingController(rootView: OrderedPoseHost(cohort: cohort, presence: presence, registry: registry)
      .environment(model).environment(\.workspaceSceneFrame, cohort.frame).environment(\.sceneComposition, .init(cohort)))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    try await waitUntil { registry.pose(for: .cover(a))?.cohortID == cohort.id && registry.pose(for: .cover(b))?.cohortID == cohort.id }
    let first = try XCTUnwrap(registry.pose(for: .cover(a))), second = try XCTUnwrap(registry.pose(for: .cover(b)))
    let surface = try XCTUnwrap(first.screenSurface(in: host.view))
    let point = CGPoint(x: 400, y: 500).applying(surface.localToScreen)
    XCTAssertTrue(host.view.hitTest(point, with: nil)?.isDescendant(of: second.contentView) == true)
    first.beginLift()
    let lease = try XCTUnwrap(first.acquirePose(in: host.view))
    // Let SwiftUI process the real @State callbacks, not a hand-built rank list.
    try await Task.sleep(for: .milliseconds(30))
    host.view.layoutIfNeeded()
    XCTAssertFalse(first.isEngaged)
    XCTAssertEqual(first.screenSurface(in: host.view)?.zIndex, surface.zIndex)
    XCTAssertTrue(host.view.hitTest(point, with: nil)?.isDescendant(of: second.contentView) == true,
      "The actual hosting hierarchy, not only a routing helper, keeps the upper cover")
    lease.release()
  }

  func testLiftedPainterTierWinsOverLargeAndEqualDurableZInTheActualHostAndFirstSample() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pose-rank-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    for upperZ in [10_001.0, 10_000.0] {
      let registry = SpatialInkSurfaceRegistry(), boardID = UUID()
      let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 0.3), viewport: .init(x: 800, y: 600))
      let cohort = try await WorkspaceInkFixture.prepare(boardID: boardID, camera: presence.camera,
        viewport: presence.viewport, items: [
          .init(itemID: a, geometry: .notebook, center: .zero, zIndex: 10_000),
          .init(itemID: b, geometry: .notebook, center: .zero, zIndex: upperZ)], registry: registry)
      let host = UIHostingController(rootView: OrderedPoseHost(cohort: cohort, presence: presence, registry: registry)
        .environment(model).environment(\.workspaceSceneFrame, cohort.frame).environment(\.sceneComposition, .init(cohort)))
      let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
      let parent = UIViewController()
      window.rootViewController = parent
      let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 800, height: 600))
      parent.view.addSubview(canvas)
      parent.addChild(host); parent.view.addSubview(host.view)
      host.view.frame = parent.view.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.didMove(toParent: parent); window.makeKeyAndVisible()
      canvas.update(lease: cohort.nativeInk, surface: .board(boardID), boardID: boardID,
        camera: presence.camera, active: true)
      let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: model.inputGate) { _, _, _ in nil }
      defer { coordinator.uninstall(); window.isHidden = true; window.rootViewController = nil }
      try await waitUntil {
        [a, b].allSatisfy { registry.pose(for: .cover($0))?.cohortID == cohort.id && registry.installedSource(on: .cover($0)) != nil }
      }
      let first = try XCTUnwrap(registry.pose(for: .cover(a))), second = try XCTUnwrap(registry.pose(for: .cover(b)))
      let resting = try XCTUnwrap(first.screenSurface(in: host.view))
      let point = CGPoint(x: 300, y: 200).applying(resting.localToScreen)
      XCTAssertTrue(host.view.hitTest(point, with: nil)?.isDescendant(of: second.contentView) == true)
      let restingSurfaces = try [a, b].map { try XCTUnwrap(registry.pose(for: .cover($0))?.screenSurface(in: canvas)) }
      XCTAssertEqual(SpatialSurfaceRouter.surface(at: point, covers: restingSurfaces, board: .board(boardID)), .cover(b),
        "Equal durable z uses the same canonical UUID tie-break as the composed image")
      first.beginLift()
      try await waitUntil { first.screenSurface(in: canvas)?.liftRank != nil }
      host.view.layoutIfNeeded()
      let lifted = try XCTUnwrap(first.screenSurface(in: canvas))
      let inputPoint = CGPoint(x: 300, y: 200).applying(lifted.localToScreen)
      XCTAssertTrue(host.view.hitTest(inputPoint, with: nil)?.isDescendant(of: first.contentView) == true,
        "The same real SwiftUI hierarchy now presents the lower durable-z cover above its neighbor")
      var journal = cohort.liveData.ink, actions: [SpatialInkAction] = []
      coordinator.update(view: canvas, cohort: cohort, boardID: boardID, camera: presence.camera, viewport: presence.viewport,
        items: cohort.frame.workset(boardID: boardID).items.map { .init(itemID: $0.id, geometry: $0.geometry, center: $0.center, zIndex: $0.zIndex) },
        journal: journal, penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
        surfaceRegistry: registry, inputGate: model.inputGate, isItemBeingDeleted: { _ in false },
        admitsNewContact: { true }, isEnabled: true, onCommit: { tool, color, spans in
          guard let action = journal.append(tool: tool, color: color, spans: spans, actor: model.actorID) else { return nil }
          actions.append(action); return action
        })
      let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
      let touch = PoseTouch(type: .pencil), event = UIEvent()
      touch.point = inputPoint
      XCTAssertTrue(pencil.canBeginContact?(touch) == true)
      pencil.touchesBegan([touch], with: event)
      XCTAssertTrue(model.inputGate.hasActivePencil)
      touch.sampleTime += 0.1; touch.point.x += 8
      pencil.touchesMoved([touch], with: event); pencil.touchesEnded([touch], with: event)
      XCTAssertEqual(actions.first?.spans.map(\.surface), [.cover(a)], "The first native contact belongs to the actually raised body, not durable z=10000")
      XCTAssertEqual(actions.first?.spans.first?.samples.first?.point.x ?? -1, 300, accuracy: 0.001)
      XCTAssertEqual(actions.first?.spans.first?.samples.first?.point.y ?? -1, 200, accuracy: 0.001)
    }
  }

  func testTwoReturningBodiesRetainTheirOwnOrderedRanksAndPencilFreezesBoth() async throws {
    let driver = try await Driver.make(coverIDs: [UUID(), UUID()])
    defer { driver.close() }
    let a = driver.coverIDs[0], b = driver.coverIDs[1]
    let first = try XCTUnwrap(driver.physical.poses[a]), second = try XCTUnwrap(driver.physical.poses[b])
    first.beginLift(); driver.physical.publish(a)
    try await pause(first, fraction: 0.7, in: driver.canvas)
    first.cancelManipulation()
    try await pause(first, fraction: 0.2, in: driver.canvas)
    second.beginLift(); driver.physical.publish(a); driver.physical.publish(b)
    try await pause(second, fraction: 0.4, in: driver.canvas)
    XCTAssertEqual(driver.physical.engaged, [a, b], "A returning or causally pending body cannot block its neighbor")
    let sa = try XCTUnwrap(first.screenSurface(in: driver.canvas)), sb = try XCTUnwrap(second.screenSurface(in: driver.canvas))
    XCTAssertLessThan(try XCTUnwrap(sa.liftRank), try XCTUnwrap(sb.liftRank))
    XCTAssertGreaterThan(try XCTUnwrap(sa.liftRank), 8_000)
    driver.begin(at: CGPoint(x: 400, y: 450).applying(sb.localToScreen), tool: .eraser)
    first.cancelManipulation(); second.cancelManipulation()
    driver.physical.publish(a); driver.physical.publish(b)
    XCTAssertEqual(first.screenSurface(in: driver.canvas), sa)
    XCTAssertEqual(second.screenSurface(in: driver.canvas), sb)
    driver.end(at: CGPoint(x: 440, y: 450).applying(sb.localToScreen))
    XCTAssertEqual(driver.actions.first?.tool, .eraser)
    XCTAssertEqual(driver.actions.first?.spans.map(\.surface), [.cover(b)])
    XCTAssertGreaterThan(driver.physical.inks[b]?.committedEraserVertexCount ?? 0, 0)
    XCTAssertEqual(driver.actions.first?.spans.first?.samples.first?.point.x ?? -1, 400, accuracy: 0.001)
  }

  func testRetiredPoseCannotReplayDeferredUpdateOrDisplaceTheNewRegistration() async throws {
    let driver = try await Driver.make()
    defer { driver.close() }
    let id = driver.coverIDs[0], old = try XCTUnwrap(driver.physical.poses[driver.coverIDs[0]])
    let lease = try XCTUnwrap(driver.registry.acquireContact(on: .cover(id), in: driver.canvas))
    driver.physical.publish(id) // A SwiftUI update is retained behind this lease.
    old.uninstall()
    let new = WorkspaceItemPoseController()
    driver.host.addChild(new); driver.host.view.addSubview(new.view)
    new.view.frame = driver.canvas.frame; new.didMove(toParent: driver.host)
    let rendered = try XCTUnwrap(driver.physical.cohort.frame.workset(boardID: driver.boardID).items.first)
    var callbacks: [Bool] = []
    new.update(rendered: rendered, camera: driver.presence.camera, viewport: driver.presence.viewport,
      boardID: driver.boardID, cohortID: driver.physical.cohort.id, cohortRevision: driver.physical.cohort.plan.revision,
      sourceBoard: driver.physical.cohort.frame.index.board(id: driver.boardID), publishedLiftRank: nil,
      projection: nil, registry: driver.registry, inputGate: driver.gate,
      onLiftChanged: { callbacks.append($0) }, onDrop: { _ in XCTFail("Teardown cannot replay a drop"); return nil },
      content: AnyView(Color.white))
    lease.release()
    XCTAssertTrue(driver.registry.pose(for: .cover(id)) === new)
    XCTAssertNil(old.cohortID)
    XCTAssertNil(old.screenSurface(in: driver.canvas))
    driver.physical.publish(id) // Even a stale representable callback remains retired.
    XCTAssertTrue(driver.registry.pose(for: .cover(id)) === new)
    XCTAssertTrue(callbacks.isEmpty)
    new.uninstall(); new.view.removeFromSuperview(); new.removeFromParent()
  }

  func testCausalWinnerSettlesThePendingDropWithoutApplyingTranslationTwice() async throws {
    let driver = try await Driver.make()
    defer { driver.close() }
    let id = driver.coverIDs[0], pose = try XCTUnwrap(driver.physical.poses[id])
    let base = try XCTUnwrap(driver.physical.cohort.frame.index.board(id: driver.boardID))
    var local = base, calls = 0
    driver.physical.onDrop = { _, point in
      calls += 1
      XCTAssertTrue(local.moveItem(id, to: point, actor: driver.actor))
      return .init(itemID: id, before: base, after: local)
    }
    pose.beginLift(); driver.physical.publish(id)
    pose.endTranslation(.init(width: 60, height: 20))
    XCTAssertEqual(calls, 1)
    try await waitUntil { pose.animator == nil }
    let pending = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    XCTAssertTrue(pose.isEngaged)
    // An unrelated publication does not acknowledge this accepted command.
    driver.physical.publish(id, cohortID: UUID())
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), pending)
    XCTAssertTrue(pose.isEngaged)
    var peer = local
    XCTAssertTrue(peer.moveItem(id, to: .init(x: -120, y: 70), actor: UUID()))
    let placement = try XCTUnwrap(peer.placement(of: id))
    let old = try XCTUnwrap(driver.physical.cohort.frame.workset(boardID: driver.boardID).items.first)
    let moved = RenderedWorkspaceItem(item: old.item, geometry: old.geometry, center: placement.center,
      zIndex: Double(placement.zIndex), stackID: nil)
    driver.physical.publish(id, rendered: moved, sourceBoard: peer, cohortID: UUID())
    try await waitUntil { !pose.isEngaged }
    let expected = driver.presence.camera.worldToScreen(placement.center, viewport: driver.presence.viewport)
    XCTAssertEqual(pose.contentView.center.x, expected.x, accuracy: 0.001,
      "The accepted causal winner installs its native model pose exactly once")
    XCTAssertEqual(pose.contentView.center.y, expected.y, accuracy: 0.001)
    // A logical engagement callback precedes Core Animation's next presented
    // transaction. Read that actual pose, not an older presentation layer.
    try await waitUntil {
      guard let surface = pose.screenSurface(in: driver.canvas) else { return false }
      let point = CGPoint(x: old.geometry.width / 2, y: old.geometry.height / 2).applying(surface.localToScreen)
      return abs(point.x - expected.x) < 0.001 && abs(point.y - expected.y) < 0.001
    }
    let current = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    let center = CGPoint(x: old.geometry.width / 2, y: old.geometry.height / 2).applying(current.localToScreen)
    XCTAssertEqual(center.x, expected.x, accuracy: 0.001)
    XCTAssertEqual(center.y, expected.y, accuracy: 0.001)
    XCTAssertEqual(calls, 1)
  }

  func testLateFingerCancellationCannotAnimateThePartlyLiftedRetiredBody() async throws {
    let driver = try await Driver.make()
    defer { driver.close() }
    let id = driver.coverIDs[0], pose = try XCTUnwrap(driver.physical.poses[driver.coverIDs[0]])
    let finger = driver.interaction(id), touch = PoseTouch(type: .direct)
    var cancellations = 0
    finger.onCancelled = { cancellations += 1; pose.cancelManipulation() }
    finger.touchesBegan([touch], with: nil)
    try await waitUntil { driver.physical.lifted[id] == true }
    driver.physical.publish(id)
    try await pause(pose, fraction: 0.5, in: driver.canvas)
    try await waitUntil {
      guard let scale = pose.screenSurface(in: driver.canvas)?.screenScale else { return false }
      return scale > 0.300_01 && scale < 0.310_49
    }
    finger.updateOwnerAvailability { false } // Removal defers its SwiftUI callback.
    XCTAssertEqual(cancellations, 0)
    driver.registry.retirePhysicalOwner(id, on: driver.boardID, through: driver.physical.cohort.plan.revision + 1)
    let frozen = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    try await waitUntil { cancellations == 1 }
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), frozen)
    XCTAssertNil(pose.animator, "A late configuration callback cannot resume the retired body's spring")
    XCTAssertTrue(pose.isEngaged, "The old frame retains its physical painter rank until it unmounts")
    XCTAssertFalse(driver.canBegin(at: CGPoint(x: 300, y: 400).applying(frozen.localToScreen)))
  }

  func testCanonicalRemovalStopsOnlyThatPlacementAndCannotReplayAPendingDrop() async throws {
    let driver = try await Driver.make(coverIDs: [UUID(), UUID()], separated: true)
    defer { driver.close() }
    let a = driver.coverIDs[0], b = driver.coverIDs[1]
    let pose = try XCTUnwrap(driver.physical.poses[a])
    let base = try XCTUnwrap(driver.physical.cohort.frame.index.board(id: driver.boardID))
    var local = base, drops = 0
    driver.physical.onDrop = { _, point in
      drops += 1
      XCTAssertTrue(local.moveItem(a, to: point, actor: driver.actor))
      return .init(itemID: a, before: base, after: local)
    }
    pose.beginLift(); driver.physical.publish(a)
    pose.endTranslation(.init(width: 30, height: 10))
    try await waitUntil { pose.animator == nil }
    let frozen = try XCTUnwrap(pose.screenSurface(in: driver.canvas))
    let revision = driver.physical.cohort.plan.revision + 1
    driver.registry.retirePhysicalOwner(a, on: UUID(), through: revision)
    XCTAssertNil(pose.retiredAtRevision, "A callback about an old board cannot retire another physical placement")
    driver.registry.retirePhysicalOwner(a, on: driver.boardID, through: revision)
    XCTAssertEqual(pose.retiredAtRevision, revision)
    XCTAssertTrue(pose.isEngaged, "The old complete frame retains its actually installed rank until replacement")
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), frozen)
    driver.physical.publish(a) // A stale SwiftUI update still contains the old owner.
    pose.cancelManipulation(); pose.beginLift(); pose.endTranslation(.init(width: 300, height: 0))
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), frozen)
    XCTAssertNil(pose.animator)
    XCTAssertEqual(drops, 1, "A completed deletion or transfer cannot replay the old accepted drop")
    let pointA = CGPoint(x: 300, y: 400).applying(frozen.localToScreen)
    XCTAssertFalse(driver.canBegin(at: pointA))
    let peer = try XCTUnwrap(driver.physical.poses[b]?.screenSurface(in: driver.canvas))
    let pointB = CGPoint(x: 300, y: 400).applying(peer.localToScreen)
    XCTAssertTrue(driver.canBegin(at: pointB), "A retired placement must not disable its still-live neighbor")
    driver.begin(at: pointB)
    XCTAssertTrue(driver.gate.hasActivePencil)
    driver.end(at: CGPoint(x: 340, y: 400).applying(peer.localToScreen))
    XCTAssertEqual(driver.actions.first?.spans.map(\.surface), [.cover(b)])
    XCTAssertEqual(pose.screenSurface(in: driver.canvas), frozen, "Releasing a neighbor's contact cannot revive a retired animation")
    XCTAssertNil(pose.animator)
    XCTAssertEqual(drops, 1)
  }

  func testOnlyTheInstalledCompleteCohortAdmitsANewPencilDuringPreparation() async throws {
    let driver = try await Driver.make()
    defer { driver.close() }
    let surface = try XCTUnwrap(driver.physical.poses[driver.coverIDs[0]]?.screenSurface(in: driver.canvas))
    let point = CGPoint(x: 200, y: 200).applying(surface.localToScreen)
    driver.update(cohort: nil)
    XCTAssertFalse(driver.canBegin(at: point), "No geometry-only or test bypass is admissible")
    driver.update()
    XCTAssertTrue(driver.canBegin(at: point), "The old complete installed cohort remains usable while its replacement prepares")
    driver.blocked.insert(driver.coverIDs[0])
    XCTAssertFalse(driver.canBegin(at: point))
    driver.blocked.removeAll()
    let pose = try XCTUnwrap(driver.physical.poses[driver.coverIDs[0]])
    driver.physical.publish(driver.coverIDs[0], cohortID: UUID())
    XCTAssertFalse(driver.canBegin(at: point), "A native owner from an unshown cohort cannot replace the displayed source")
    driver.physical.publish(driver.coverIDs[0])
    XCTAssertTrue(driver.canBegin(at: point))
    pose.view.removeFromSuperview()
    XCTAssertFalse(driver.canBegin(at: point), "Window removal is a hard physical boundary")
  }

  private func pause(_ pose: WorkspaceItemPoseController, fraction: CGFloat, in view: UIView) async throws {
    let animator = try XCTUnwrap(pose.animator)
    animator.pauseAnimation(); animator.fractionComplete = fraction; CATransaction.flush()
    await Task.yield()
    XCTAssertNotNil(pose.screenSurface(in: view))
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "The native owner did not reach the requested state")
  }

  @MainActor
  func testDropCannotPublishACenterBeyondTheWorldEdgeButCanReturnInside() async throws {
    for sign in [-1, 1] {
      let center = WorldPoint(tileX: Int64(sign) * WorldPoint.maximumTileIndex, tileY: 0,
        localX: sign > 0 ? WorldPoint.tileSize - 1 : 0, localY: 0)
      let driver = try await Driver.make(center: center)
      defer { driver.close() }
      let id = driver.coverIDs[0], pose = try XCTUnwrap(driver.physical.poses[id])
      var drops: [WorldPoint] = []
      driver.physical.onDrop = { _, point in drops.append(point); return nil }
      pose.beginLift(); driver.physical.publish(id)
      pose.endTranslation(.init(width: Double(sign) * 60, height: 0))
      XCTAssertTrue(drops.isEmpty, "A release outside the address range is not a persisted placement")
      pose.cancelManipulation(); pose.beginLift(); driver.physical.publish(id)
      pose.endTranslation(.init(width: Double(sign) * -60, height: 0))
      XCTAssertEqual(drops, [try XCTUnwrap(center.addressOffset(x: Double(sign) * -200, y: 0))])
    }
  }

  @MainActor
  private final class Driver {
    let gate = NotebookInputGate()
    let registry: SpatialInkSurfaceRegistry
    let host = UIViewController(), canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 800, height: 600))
    let window: UIWindow, boardID: UUID, coverIDs: [UUID], actor: UUID, presence: SessionPresence
    let physical: WorkspaceInkFixture
    private var coordinator: SpatialInkCanvas.Coordinator!
    private var fingers: [NotebookInteractionTouchView] = []
    private let touch = PoseTouch(type: .pencil), event = UIEvent()
    var journal: SpatialInkJournal
    private(set) var actions: [SpatialInkAction] = []
    var blocked: Set<UUID> = []
    var onCommit: (() -> Void)?
    private var tool: DrawingTool = .pen
    private var pencil: SpatialPencilGestureRecognizer { window.gestureRecognizers!.compactMap { $0 as? SpatialPencilGestureRecognizer }.first! }

    static func make(boardID: UUID = UUID(), coverIDs: [UUID] = [UUID()], actor: UUID = UUID(), separated: Bool = false, center: WorldPoint = .zero) async throws -> Driver {
      let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(center: center, scale: 0.3), viewport: .init(x: 800, y: 600))
      let items = coverIDs.enumerated().map { index, id in
        SpatialWorkspaceItemSurface(itemID: id, geometry: .notebook, center: center.offsetBy(x: separated ? Double(index) * 1_050 - 525 : 0, y: 0), zIndex: Double(index))
      }
      let cohort = try await WorkspaceInkFixture.prepare(boardID: boardID, camera: presence.camera, viewport: presence.viewport, items: items)
      return try .init(cohort: cohort, presence: presence, ids: coverIDs, actor: actor)
    }
    private init(cohort: SceneCompositionCohort, presence: SessionPresence, ids: [UUID], actor: UUID) throws {
      boardID = presence.boardID; coverIDs = ids; self.actor = actor; self.presence = presence
      registry = cohort.nativeInk.registry
      journal = .init(stamp: .init(counter: 0, actor: actor))
      window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
      window.rootViewController = host; host.view.addSubview(canvas); window.makeKeyAndVisible()
      physical = try .init(cohort: cohort, presence: presence, canvas: canvas, parent: host, registry: registry, gate: gate, journal: journal)
      coordinator = .init(surfaceRegistry: registry, inputGate: gate) { _, _, _ in nil }
      update()
    }
    func update() { update(cohort: physical.cohort) }
    func update(cohort: SceneCompositionCohort?) {
      coordinator.update(view: canvas, cohort: cohort, boardID: boardID,
        camera: presence.camera, viewport: presence.viewport, items: physical.surfaces,
        journal: journal, penStyle: .standard, eraserStyle: .standard, drawingTool: tool,
        surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { [weak self] in self?.blocked.contains($0) == true },
        admitsNewContact: { true }, isEnabled: true, onCommit: { [weak self] tool, color, spans in
          guard let self else { return nil }; onCommit?()
          guard let action = journal.append(tool: tool, color: color, spans: spans, actor: actor) else { return nil }
          actions.append(action); return action
        })
    }
    func canBegin(at point: CGPoint) -> Bool { touch.point = point; return pencil.canBeginContact?(touch) == true }
    func begin(at point: CGPoint, tool: DrawingTool = .pen) {
      self.tool = tool; update(); pencil.reset(); touch.point = point; touch.sampleTime += 1
      pencil.touchesBegan([touch], with: event)
    }
    func end(at point: CGPoint) {
      touch.point = point; touch.sampleTime += 0.1
      pencil.touchesMoved([touch], with: event); pencil.touchesEnded([touch], with: event)
    }
    func interaction(_ id: UUID) -> NotebookInteractionTouchView {
      let finger = NotebookInteractionTouchView(inputGate: gate), pose = physical.poses[id]!
      finger.onLiftChanged = { value in if value { pose.beginLift() } }
      finger.onTranslationChanged = { pose.changeTranslation($0) }
      finger.onTranslationEnded = { pose.endTranslation($0) }
      finger.onCancelled = { pose.cancelManipulation() }
      physical.installInteraction(finger, on: id)
      fingers.append(finger); return finger
    }
    func close() { coordinator.uninstall(); physical.close(); window.isHidden = true; window.rootViewController = nil }
  }
}

@MainActor
private struct OrderedPoseHost: View {
  let cohort: SceneCompositionCohort
  let presence: SessionPresence
  let registry: SpatialInkSurfaceRegistry
  @State private var engaged: [UUID] = []
  var body: some View {
    ZStack {
      ForEach(cohort.frame.workset(boardID: presence.boardID).items) { item in
        let rank = engaged.firstIndex(of: item.id).map { 9_000 + Double($0) }
        WorkspaceItemPose(rendered: item, camera: presence.camera, viewport: presence.viewport,
          boardID: presence.boardID, liftRank: rank, registry: registry,
          onLiftChanged: { value in
            engaged.removeAll { $0 == item.id }
            if value { engaged.append(item.id) }
          }, onDrop: { _ in nil }) {
            Color.blue.frame(width: item.geometry.width, height: item.geometry.height)
              .overlay { SpatialInkSurfaceView(surface: .cover(item.id), cohort: cohort, boardID: presence.boardID, isActive: true) }
          }
          .frame(width: presence.viewport.x, height: presence.viewport.y)
          .zIndex(rank ?? cohort.plan.rank(id: .item(item.id), in: .board(presence.boardID)) ?? 0)
      }
    }.frame(width: presence.viewport.x, height: presence.viewport.y)
  }
}

@MainActor
private final class PoseTouch: UITouch {
  var point = CGPoint(x: 400, y: 300)
  var sampleTime: TimeInterval = 1
  private let inputType: UITouch.TouchType
  init(type: UITouch.TouchType) { inputType = type; super.init() }
  override var type: UITouch.TouchType { inputType }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint { point }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0.4 }
}
