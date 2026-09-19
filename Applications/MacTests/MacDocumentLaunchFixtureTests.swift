#if DEBUG
import NotebookCore
import Observation
import XCTest
@testable import Notebook

@MainActor
final class MacDocumentLaunchFixtureTests: XCTestCase {
  func testReplayedLandingDuringScrollDoesNotPublishAnIntermediateReadingPosition() async throws {
    let model = MacDocumentLaunchFixture.makeModel()
    retainNotebookUntilTeardown(model, removing: model.store.root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let document = try XCTUnwrap(model.activeDocument), block = try XCTUnwrap(document.blocks.first)
    let source = NotebookAppModel.documentPageSourceRevision(document), controller = UUID()
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let record = try DocumentLayoutRecord(receipt: ["sourceKey": source, "layoutScope": "source", "layoutCanonical": true,
      "pageCount": 1, "width": geometry.width, "height": geometry.height,
      "regions": [["id": block.id, "pageIndex": 0, "x": 20.0, "y": 30.0, "width": 100.0, "height": 100.0, "sourceOffset": 0.0]],
      "anchors": [], "reading": [[block.id, "1111111111111111", 0, 0, 10, 0, 30.0]]] as NSDictionary,
      sourceKey: source, blockIDs: [block.id], geometry: geometry)
    model.acceptDocumentReadingLayout(.init(pageCount: 1, sourceRevision: source, record: record), documentID: document.id)
    model.bindDocumentPageController(controller, documentID: document.id, source: source)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: document.id,
      sourceRevision: source, revision: 1, pageIndex: 0, requestID: nil)))
    let original = try XCTUnwrap(model.documentReadingPosition(document.id)), start = try XCTUnwrap(model.presence)
    for revision in 2...8 {
      let camera = SpatialCamera(center: start.camera.center.offsetBy(x: 0, y: Double(revision) * 20), scale: start.camera.scale)
      model.updatePresence(start.replacingCamera(camera), settled: false)
      XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: document.id,
        sourceRevision: source, revision: UInt64(revision), pageIndex: 0, requestID: nil)))
      XCTAssertEqual(model.documentReadingPosition(document.id), original)
    }
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    XCTAssertNotEqual(model.documentReadingPosition(document.id), original)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.readDocumentReadingPosition(document.id), model.documentReadingPosition(document.id))
  }

  func testReplayedDocumentLandingDoesNotInvalidateIdleNavigation() async throws {
    let model = MacDocumentLaunchFixture.makeModel()
    retainNotebookUntilTeardown(model, removing: model.store.root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let document = try XCTUnwrap(model.activeDocument)
    let source = NotebookAppModel.documentPageSourceRevision(document), controller = UUID()
    model.bindDocumentPageController(controller, documentID: document.id, source: source)
    XCTAssertNil(model.documentPageSelection)
    XCTAssertNil(model.documentPageNavigationStatus)
    let invalidation = expectation(description: "A replay of the landed page must not feed back into SwiftUI")
    invalidation.isInverted = true
    withObservationTracking {
      _ = model.documentPageSelection
      _ = model.documentPageNavigationStatus
    } onChange: { invalidation.fulfill() }
    for revision in 1...10 {
      XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller,
        documentID: document.id, sourceRevision: source, revision: UInt64(revision),
        pageIndex: 0, requestID: nil)))
    }
    await fulfillment(of: [invalidation], timeout: 0.05)
    model.unbindDocumentPageController(controller)
  }

  func testDocumentFixtureIncludesTheCanonicalEmptyInkOwnerBeforeStartingThePublisher() async throws {
    let model = MacDocumentLaunchFixture.makeModel()
    retainNotebookUntilTeardown(model, removing: model.store.root)
    let header = try model.store.workspaceHeader()
    let ink = try model.store.loadSpatialInk()
    XCTAssertNotNil(header.boardRevision)
    XCTAssertEqual(header.spatialInkStamp, ink.stamp,
      "An empty spatial ink owner still supplies the current-view receipt's causal revision")

    let presence = try model.store.loadPresence()
    let documentID = try XCTUnwrap(presence.focusedItemID)
    XCTAssertEqual(presence.mode, .document)
    XCTAssertEqual(try model.store.loadDocument(documentID).id, documentID)
    XCTAssertEqual(try model.store.loadDocumentState(documentID).id, documentID)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "The helper fixture did not finish startup")
    XCTAssertEqual(model.loadState, .ready)
    XCTAssertEqual(model.workspaceHeader?.spatialInkStamp, ink.stamp)
    XCTAssertEqual(model.activeDocument?.id, documentID)
  }
}
#endif
