import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// The application's mounted camera owner receives the measured gesture. UI
/// tests separately exercise the hardware recognizers on the physical iPad.
@MainActor
final class NotebookPaperCameraTests: XCTestCase {
  func testOpenNotebookKeepsItsFittedPageDuringZoomInAndTranslation() async throws {
    let (model, window) = try await scene(document: false)
    let start = try XCTUnwrap(model.presence), owner = try coordinator(in: window)
    let pair = CGPoint(x: start.viewport.x * 0.4, y: start.viewport.y * 0.43)
    for scale in [CGFloat(1.6), 4, 1] {
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

  func testLoadedDocumentPaperAdmitsSceneFingers() async throws {
    let (model,window)=try await scene(document:true)
    let item=try XCTUnwrap(model.presence?.focusedItemID)
    let document=try XCTUnwrap(model.documents[item]),state=try XCTUnwrap(model.documentStates[item])
    let deadline=ContinuousClock.now + .seconds(12)
    while !DocumentRenderRegistry.shared.hasLiveSurface(document:document,state:state,pageIndex:0,scope:.paper),ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(30))
    }
    XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document:document,state:state,pageIndex:0,scope:.paper))
    for position in [CGPoint(x:0.94,y:0.8),.init(x:0.25,y:0.6),.init(x:0.75,y:0.6)] {
      let point=CGPoint(x:window.bounds.width*position.x,y:window.bounds.height*position.y)
      let hit=try XCTUnwrap(window.hitTest(point,with:nil))
      var chain=[String](),current:UIView?=hit
      while let view=current {
        chain.append("\(type(of:view))" + ((view as? UIScrollView).map { " scroll=\($0.isScrollEnabled) pan=\($0.panGestureRecognizer.isEnabled)" } ?? ""))
        current=view.superview
      }
      XCTAssertTrue(NotebookSceneFingerRouting.owner(of:hit,at:hit.convert(point,from:window)).permitsSceneNavigation,chain.joined(separator:" > "))
      XCTAssertTrue(model.inputGate.permitsSceneContact(at:point,kind:.finger),chain.joined(separator:" > "))
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
    try await verifyZoomClosesAndReopens(document:true)
  }

  func testNotebookZoomCanCloseAndReopenOnlyItsOwnSurface() async throws {
    try await verifyZoomClosesAndReopens(document:false)
  }

  private func verifyZoomClosesAndReopens(document:Bool) async throws {
    let (model,window)=try await scene(document:document)
    let item=try XCTUnwrap(model.presence?.focusedItemID)
    if document {
      let source=try XCTUnwrap(model.documents[item]),state=try XCTUnwrap(model.documentStates[item])
      let deadline=ContinuousClock.now + .seconds(12)
      while !DocumentRenderRegistry.shared.hasLiveSurface(document:source,state:state,pageIndex:0,scope:.paper),ContinuousClock.now < deadline {
        try await Task.sleep(for:.milliseconds(20))
      }
      XCTAssertTrue(DocumentRenderRegistry.shared.hasLiveSurface(document:source,state:state,pageIndex:0,scope:.paper))
    }
    let start=try XCTUnwrap(model.presence)
    let owner=try coordinator(in:window),pair=CGPoint(x:start.viewport.x/2,y:start.viewport.y/2)
    let originalPaper = document ? try paperFrame(in:window,documentID:item) : nil
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
    if let originalPaper {
      assertCamera(try XCTUnwrap(model.presence).camera,equals:start.camera)
      let reopened=try paperFrame(in:window,documentID:item)
      for (actual,expected) in [(reopened.minX,originalPaper.minX),(reopened.minY,originalPaper.minY),
        (reopened.width,originalPaper.width),(reopened.height,originalPaper.height)] {
        XCTAssertEqual(actual,expected,accuracy:1/window.screen.scale,
          "Reopening must restore the mounted PDF projection, not only the model's camera")
      }
      let image=UIGraphicsImageRenderer(size:window.bounds.size).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
      let attachment=XCTAttachment(image:image);attachment.name="reopened-document-physical-projection";attachment.lifetime = .keepAlways;add(attachment)
    }
  }

  private func paperFrame(in window:UIWindow,documentID:UUID) throws -> CGRect {
    func find(_ view:UIView) -> DocumentPaperView? {
      if let paper=view as? DocumentPaperView,paper.raster?.page.artifact.document.id == documentID,
        SceneSourceVisibility.isVisible(paper) { return paper }
      return view.subviews.lazy.compactMap(find).first
    }
    let paper=try XCTUnwrap(find(window))
    return paper.convert(paper.bounds,to:window)
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
    let item = try XCTUnwrap(document ? model.createDocument(at: .zero) : model.workspace?.selectedItemID)
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
