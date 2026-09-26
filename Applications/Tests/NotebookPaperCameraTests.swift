import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// The application's mounted camera owner receives the measured gesture. UI
/// tests separately exercise the hardware recognizers on the physical iPad.
@MainActor
final class NotebookPaperCameraTests: XCTestCase {
  func testOpenNotebookRejectsCameraPhasesWithoutChangingPageOrNavigation() async throws {
    let (model, window) = try await scene(document: false)
    let start = try XCTUnwrap(model.presence), owner = try coordinator(in: window)
    let pair = CGPoint(x: start.viewport.x * 0.4, y: start.viewport.y * 0.43)
    for scale in [CGFloat(1.6), 0.1, 4, 1] {
      let moved = CGPoint(x: pair.x + 42, y: pair.y + 27)
      owner.onCamera(.began(centroid: pair))
      owner.onCamera(.changed(scale: scale, velocity: 0.2, elapsed: 0.2, centroid: moved))
      XCTAssertEqual(model.presence, start)
      owner.onCamera(.ended(scale: scale, velocity: 0, elapsed: 0.3, centroid: moved))
      owner.onCamera(.cancelled)
      try await Task.sleep(for: .milliseconds(35))
      XCTAssertEqual(model.presence, start)
      XCTAssertEqual(model.presencePhase, .settled)
      XCTAssertTrue(owner.defersHorizontalMotionToPageTurn)
      XCTAssertTrue(model.returnPlaces.isEmpty)
    }
  }

  func testOpenDocumentKeepsAnchoredZoomAndPanAfterRelease() async throws {
    let (model, window) = try await scene(document: true)
    let start = try XCTUnwrap(model.presence)
    let pair = CGPoint(x: start.viewport.x * 0.4, y: start.viewport.y * 0.43)
    let moved = CGPoint(x: pair.x + 42, y: pair.y + 27)
    let owner = try coordinator(in: window)
    let geometry = model.itemGeometry(start.focusedItemID)
    let itemID = try XCTUnwrap(start.focusedItemID)
    let center = try XCTUnwrap(model.boardHierarchy?.focusedCenter(of: itemID, in: start.boardID))
    func bounded(_ camera: SpatialCamera) -> SpatialCamera {
      geometry.readingCamera(camera, centeredOn: center, viewport: start.viewport)
    }
    owner.onCamera(.began(centroid: pair))
    for scale in [CGFloat(1.02), 1.4, 4, 1.2, 1.1] {
      owner.onCamera(.changed(scale: scale, velocity: 0.2, elapsed: 0.2, centroid: moved))
      try await Task.sleep(for: .milliseconds(35))
      let actual = try XCTUnwrap(model.presence)
      XCTAssertEqual(actual.mode, start.mode, "An ordinary paper gesture cannot become a cover gesture")
      XCTAssertEqual(actual.openProgress, 1)
      XCTAssertEqual(actual.focusedItemID, start.focusedItemID)
      XCTAssertEqual(actual.notebookPageID, start.notebookPageID)
      XCTAssertEqual(actual.selectedItemID, start.selectedItemID)
      XCTAssertGreaterThanOrEqual(actual.camera.scale, geometry.fitScale(viewport: start.viewport),
        "Keeping page mode alone is insufficient: the visible sheet must not shrink into the board")
      assertCamera(actual.camera, equals: bounded(start.camera.pinched(by: scale,
        from: .init(x: pair.x, y: pair.y), to: .init(x: moved.x, y: moved.y), viewport: start.viewport)))
    }
    owner.onCamera(.ended(scale: 1.1, velocity: -0.2, elapsed: 0.3, centroid: moved))
    try await Task.sleep(for: .milliseconds(450))
    let released = try XCTUnwrap(model.presence)
    XCTAssertEqual(released.mode, start.mode)
    XCTAssertEqual(released.openProgress, 1)
    assertCamera(released.camera, equals: bounded(start.camera.pinched(by: 1.1,
      from: .init(x: pair.x, y: pair.y), to: .init(x: moved.x, y: moved.y), viewport: start.viewport)))
    XCTAssertFalse(owner.defersHorizontalMotionToPageTurn, "Zoomed paper owns two-finger panning, not a curl")

    let panEnd = CGPoint(x: moved.x + 90, y: moved.y + 12)
    owner.onCamera(.began(centroid: moved))
    owner.onCamera(.changed(scale: 1, velocity: 0, elapsed: 0.2, centroid: panEnd))
    owner.onCamera(.ended(scale: 1, velocity: 0, elapsed: 0.3, centroid: panEnd))
    try await Task.sleep(for: .milliseconds(100))
    let panned = try XCTUnwrap(model.presence)
    XCTAssertEqual(panned.mode, start.mode)
    XCTAssertEqual(panned.documentPageIndex, start.documentPageIndex)
    assertCamera(panned.camera, equals: bounded(released.camera.pinched(by: 1,
      from: .init(x: moved.x, y: moved.y), to: .init(x: panEnd.x, y: panEnd.y), viewport: start.viewport)))
  }

  func testDocumentZoomCanCloseAndReopenOnlyItsOwnSurface() async throws {
    let (model,window)=try await scene(document:true)
    let start=try XCTUnwrap(model.presence),item=try XCTUnwrap(start.focusedItemID)
    let owner=try coordinator(in:window),pair=CGPoint(x:start.viewport.x/2,y:start.viewport.y/2)
    owner.onCamera(.began(centroid:pair))
    owner.onCamera(.changed(scale:0.1,velocity:-2,elapsed:0.2,centroid:pair))
    XCTAssertEqual(model.presence?.focusedItemID,item)
    owner.onCamera(.ended(scale:0.1,velocity:-2,elapsed:0.3,centroid:pair))
    try await waitFor(model,mode:.board)
    XCTAssertNil(model.presence?.focusedItemID)
    let factor=CGFloat(model.itemGeometry(item).fitScale(viewport:start.viewport)/(try XCTUnwrap(model.presence?.camera.scale)))
    owner.onCamera(.began(centroid:pair))
    owner.onCamera(.changed(scale:factor*1.1,velocity:2,elapsed:0.2,centroid:pair))
    owner.onCamera(.ended(scale:factor*1.1,velocity:2,elapsed:0.3,centroid:pair))
    try await waitFor(model,mode:start.mode)
    XCTAssertEqual(model.presence?.focusedItemID,item)
    XCTAssertEqual(model.presence?.notebookPageID,start.notebookPageID)
    XCTAssertEqual(model.presence?.documentPageIndex,start.documentPageIndex)
  }

  func testClosedCoverOwnsItsHitAndReopensByTheSameTapCallback() async throws {
    let (model,window)=try await scene(document:false, startsOnBoard:true)
    let start=try XCTUnwrap(model.presence)
    let point=CGPoint(x:start.viewport.x/2,y:start.viewport.y/2)
    try await Task.sleep(for:.milliseconds(300))
    let hit=window.hitTest(point,with:nil)
    var chain:[String]=[];var view=hit
    while let current=view { chain.append("\(type(of:current)) enabled=\(current.isUserInteractionEnabled)");view=current.superview }
    XCTAssertTrue(model.inputGate.permitsSceneContact(at:point,kind:.finger),chain.joined(separator:" > "))
    let cover=try XCTUnwrap(hit as? NotebookInteractionTouchView,chain.joined(separator:" > "))
    cover.onTap(cover.convert(point,from:window),2)
    try await waitFor(model,mode:.page)
    XCTAssertEqual(model.returnPlaces.last?.presence, start, "The opening retains its actual board camera")
  }

  private func waitFor(_ model:NotebookAppModel,mode:WorkspaceSemanticMode) async throws {
    let deadline=ContinuousClock.now + .seconds(12)
    while model.presence?.mode != mode || model.presencePhase != .settled {
      guard ContinuousClock.now < deadline else { XCTFail("Surface did not settle: \(String(describing:model.presence)); \(model.scenePreparationDiagnostic ?? "")");return }
      try await Task.sleep(for:.milliseconds(20))
    }
  }

  private func scene(document: Bool, startsOnBoard: Bool = false) async throws -> (NotebookAppModel, UIWindow) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paper-camera-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(document ? model.createDocument(at: .zero, paperSize: .a4) : model.workspace?.selectedItemID)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let board = try XCTUnwrap(model.workspace?.rootBoardID)
    let center = try XCTUnwrap(model.boardHierarchy?.focusedCenter(of: item, in: board))
    let nativeScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let size = nativeScene.effectiveGeometry.coordinateSpace.bounds.size
    let viewport = SpatialPoint(x: size.width, y: size.height)
    let fit = model.itemGeometry(item).fitScale(viewport: viewport)
    model.updatePresence(.init(boardID: board, mode: startsOnBoard ? .board : document ? .document : .page,
      camera: .init(center: center, scale: fit * (startsOnBoard ? 0.35 : 1)), viewport: viewport,
      focusedItemID: startsOnBoard ? nil : item, openProgress: startsOnBoard ? 0 : 1), settled: true)
    return (model, try await mountNotebookScene(model))
  }

  private func coordinator(in window: UIWindow) throws -> WorkspaceGestureLayer.Coordinator {
    try XCTUnwrap(window.gestureRecognizers?.compactMap { $0.delegate as? WorkspaceGestureLayer.Coordinator }.first)
  }

  private func assertCamera(_ actual: SpatialCamera, equals expected: SpatialCamera,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.scale, expected.scale, accuracy: 1e-10, file: file, line: line)
    let delta = expected.center.delta(to: actual.center)
    XCTAssertEqual(delta.x, 0, accuracy: 1e-8, file: file, line: line)
    XCTAssertEqual(delta.y, 0, accuracy: 1e-8, file: file, line: line)
  }
}
