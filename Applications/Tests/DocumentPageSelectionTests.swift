import NotebookCore
import XCTest
@testable import Notebook

final class DocumentPageSelectionTests: XCTestCase {
  @MainActor
  func testLocalRequestWaitsForNativeLandingAndOldLandingCannotClearNewIntent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let model = NotebookAppModel(
      store: NotebookStore(root: root),
      startsNearbySync: false
    )
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let documentID = try XCTUnwrap(
      model.createDocument(at: .zero, paperSize: .a4)
    )
    let initial = try XCTUnwrap(model.presence)
    model.updatePresence(
      SessionPresence(
        mode: .document,
        camera: initial.camera,
        viewport: initial.viewport,
        focusedItemID: documentID,
        openProgress: 1,
        documentPageIndex: 0
      ),
      settled: true
    )

    XCTAssertEqual(model.selectDocumentPage(3, documentID: documentID), 3)

    XCTAssertEqual(model.presence?.documentPageIndex, 0, "An accepted request is not actual page presence")
    let first = try XCTUnwrap(model.documentPageSelection)
    XCTAssertEqual(first.pageIndex, 3)
    let controller = UUID(), document = try XCTUnwrap(model.documents[documentID])
    let source = NotebookAppModel.documentPageSourceRevision(document)
    model.bindDocumentPageController(controller, documentID: documentID, source: source)
    XCTAssertEqual(model.selectDocumentPage(5, documentID: documentID), 5)
    let second = try XCTUnwrap(model.documentPageSelection)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: documentID,
      sourceRevision: source, revision: 1, pageIndex: 3, requestID: first.id)))
    XCTAssertEqual(model.presence?.documentPageIndex, 3)
    XCTAssertEqual(model.documentPageSelection?.id, second.id, "Actual A cannot erase pending B")
    XCTAssertFalse(model.acceptDocumentPageLanding(.init(controllerID: UUID(), documentID: documentID,
      sourceRevision: source, revision: 2, pageIndex: 7, requestID: second.id)))
    XCTAssertFalse(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: documentID,
      sourceRevision: source + "-old", revision: 2, pageIndex: 7, requestID: second.id)))
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: documentID,
      sourceRevision: source, revision: 2, pageIndex: 5, requestID: second.id)))
    XCTAssertEqual(model.presence?.documentPageIndex, 5)
    XCTAssertNil(model.documentPageSelection)
    XCTAssertFalse(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: documentID,
      sourceRevision: source, revision: 1, pageIndex: 3, requestID: first.id)))
    let actual = try XCTUnwrap(model.presence)
    model.updatePresence(.init(boardID: actual.boardID, mode: .cover, camera: actual.camera,
      viewport: actual.viewport, focusedItemID: documentID, openProgress: 0), settled: true)
    XCTAssertFalse(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: documentID,
      sourceRevision: source, revision: 3, pageIndex: 7, requestID: nil)))
    XCTAssertEqual(model.presence?.focusedItemID, documentID)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  @MainActor
  func testRequestForAnotherDocumentCannotMoveTheFocusedDocument() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let model = NotebookAppModel(
      store: NotebookStore(root: root),
      startsNearbySync: false
    )
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let documentID = try XCTUnwrap(
      model.createDocument(at: .zero, paperSize: .letter)
    )
    let initial = try XCTUnwrap(model.presence)
    model.updatePresence(
      SessionPresence(
        mode: .document,
        camera: initial.camera,
        viewport: initial.viewport,
        focusedItemID: documentID,
        openProgress: 1
      ),
      settled: true
    )

    XCTAssertNil(model.selectDocumentPage(2, documentID: UUID()))

    XCTAssertEqual(model.presence?.documentPageIndex, 0)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }
}
