import NotebookCore
import Observation
import XCTest
@testable import Notebook

@MainActor
final class DocumentReadingPublicationTests: XCTestCase {
  func testReplayedLandingDuringScrollDoesNotPublishAnIntermediateReadingPosition() async throws {
    let fixture = try makeFixture(), model = fixture.model
    retainNotebookUntilTeardown(model, removing: model.store.root)
    try await fixture.start()
    let document = try XCTUnwrap(model.activeDocument), block = try XCTUnwrap(document.files.first)
    let source = DocumentPageNavigation.sourceRevision(document), controller = UUID()
    let paper = DocumentPaperLayout.uncompiled, geometry = paper.geometry
    let record = try DocumentLayoutRecord(receipt: ["sourceKey": source, "layoutScope": "source", "layoutCanonical": true,
      "pageCount": 1, "width": geometry.width, "height": geometry.height,
      "pages": [["widthPoints": paper.widthPoints, "heightPoints": paper.heightPoints]],
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
    let fixture = try makeFixture(), model = fixture.model
    retainNotebookUntilTeardown(model, removing: model.store.root)
    try await fixture.start()
    let document = try XCTUnwrap(model.activeDocument)
    let source = DocumentPageNavigation.sourceRevision(document), controller = UUID()
    model.bindDocumentPageController(controller, documentID: document.id, source: source)
    XCTAssertNil(model.documentNavigation.request)
    XCTAssertNil(model.documentNavigation.status)
    let invalidation = expectation(description: "A replay of the landed page must not feed back into SwiftUI")
    invalidation.isInverted = true
    withObservationTracking {
      _ = model.documentNavigation.request
      _ = model.documentNavigation.status
    } onChange: { invalidation.fulfill() }
    for revision in 1...10 {
      XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller,
        documentID: document.id, sourceRevision: source, revision: UInt64(revision),
        pageIndex: 0, requestID: nil)))
    }
    await fulfillment(of: [invalidation], timeout: 0.05)
    model.unbindDocumentPageController(controller)
  }

  private func makeFixture() throws -> MacCommandFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-reading-" + UUID().uuidString)
    let fixture = MacCommandFixture(root: root), actor = fixture.model.actorID
    _ = try fixture.store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    var index = try fixture.store.loadIndex(), hierarchy = try fixture.store.loadBoard(items: index.items)
    let item = try XCTUnwrap(index.createDocument(title: "Reading publication", actor: actor))
    XCTAssertTrue(hierarchy.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor))
    let center = try XCTUnwrap(hierarchy.board(index.rootBoardID)?.focusedCenter(of: item.id))
    let document = DocumentDocument(id: item.id, actor: actor,
      files: [.init(id: "main", path: "main.tex", source: DocumentTemplate.article.files[0].source)])
    try fixture.store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: .init(id: item.id, actor: actor), board: hierarchy)
    let viewport = SpatialPoint(x: 834, y: 1194)
    try fixture.store.savePresence(.init(boardID: index.rootBoardID, mode: .document,
      camera: .init(center: center, scale: WorkspaceItemGeometry.uncompiledDocument.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: item.id, openProgress: 1, documentPageIndex: 0))
    return fixture
  }
}
