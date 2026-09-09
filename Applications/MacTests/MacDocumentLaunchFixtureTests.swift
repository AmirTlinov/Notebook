import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class MacDocumentLaunchFixtureTests: XCTestCase {
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
