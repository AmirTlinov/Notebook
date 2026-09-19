#if DEBUG
import NotebookCore
import Observation
import XCTest
@testable import Notebook

@MainActor
final class MacDocumentLaunchFixtureTests: XCTestCase {
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
