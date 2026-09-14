import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookDocumentReadingTests: XCTestCase {
  func testReflowAndReopeningRequestTheContentAnchorWithoutInventingALanding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let id = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .a4))
    let saved1 = await model.finishPendingPersistence(); XCTAssertTrue(saved1)
    let initial = try XCTUnwrap(model.presence), center = try XCTUnwrap(model.board?.focusedCenter(of: id))
    let viewport = initial.viewport, geometry = model.itemGeometry(id)
    let camera = SpatialCamera(center: center.offsetBy(x: 15, y: 40), scale: geometry.fitScale(viewport: viewport) * 2)
    func open(_ camera: SpatialCamera) {
      model.updatePresence(.init(boardID: initial.boardID, mode: .document, camera: camera, viewport: viewport,
        focusedItemID: id, openProgress: 1, documentPageIndex: 0, selectedItemID: id), settled: true)
    }
    open(camera)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    var document = try XCTUnwrap(model.documents[id])
    var source = NotebookAppModel.documentPageSourceRevision(document)
    model.acceptDocumentReadingLayout(try layout(document, target: 2), documentID: id)
    var controller = UUID()
    model.bindDocumentPageController(controller, documentID: id, source: source)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 1, pageIndex: 2, requestID: nil)))
    let place = try XCTUnwrap(model.documentReadingPosition(id))
    XCTAssertEqual(place.anchor.nodeID, "2222222222222222")
    XCTAssertEqual(place.zoomRatio, 2, accuracy: 0.001)
    XCTAssertEqual(place.centerOffset.y, 40, accuracy: 0.001)
    let saved2 = await model.finishPendingPersistence(); XCTAssertTrue(saved2)
    XCTAssertEqual(try model.store.readDocumentReadingPosition(id), place)

    let block = try XCTUnwrap(document.blocks.first)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, blockID: block.id,
      baseSource: block.source, baseVersion: document.sourceVersion(blockID: block.id),
      source: "Preceding content changes pagination. " + block.source, sequence: 1)
    let status = try await model.commitDocumentSource(edit: edit); XCTAssertEqual(status, .committed)
    document = try XCTUnwrap(model.documents[id]); source = NotebookAppModel.documentPageSourceRevision(document)
    model.acceptDocumentReadingLayout(try layout(document, target: 5), documentID: id)
    XCTAssertEqual(model.presence?.documentPageIndex, 2, "Resolving the anchor does not confirm its display")
    XCTAssertEqual(model.documentPageSelection?.pageIndex, 5)
    controller = UUID(); model.bindDocumentPageController(controller, documentID: id, source: source)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 1, pageIndex: 2, requestID: nil)))
    XCTAssertEqual(model.documentReadingPosition(id), place, "The interim old-number page cannot destroy the reading anchor")
    let request = try XCTUnwrap(model.documentPageSelection)
    XCTAssertTrue(model.acceptDocumentPageLanding(.init(controllerID: controller, documentID: id,
      sourceRevision: source, revision: 2, pageIndex: 5, requestID: request.id)))
    XCTAssertEqual(model.presence?.documentPageIndex, 5)
    XCTAssertEqual(model.documentReadingPosition(id)?.anchor.nodeID, place.anchor.nodeID)

    model.updatePresence(.init(boardID: initial.boardID, mode: .cover, camera: camera,
      viewport: viewport, focusedItemID: id, openProgress: 0, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    open(.init(center: center, scale: geometry.fitScale(viewport: viewport)))
    model.acceptDocumentReadingLayout(try layout(document, target: 5), documentID: id)
    XCTAssertEqual(model.documentPageSelection?.pageIndex, 5)
    XCTAssertEqual(model.presence?.documentPageIndex, 0)
    XCTAssertEqual(try XCTUnwrap(model.presence).camera.scale, camera.scale, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(model.presence).camera.center, camera.center)
    let saved3 = await model.finishPendingPersistence(); XCTAssertTrue(saved3)
    XCTAssertEqual(try NotebookStore(root: root).readDocumentReadingPosition(id)?.anchor.nodeID, place.anchor.nodeID)
  }

  private func layout(_ document: DocumentDocument, target: Int) throws -> DocumentPageLayout {
    let geometry = WorkspaceItemGeometry.document(document.paperSize), id = try XCTUnwrap(document.blocks.first?.id)
    let source = NotebookAppModel.documentPageSourceRevision(document)
    let regions: [[String: Any]] = [0, target].map { page in
      ["id": id, "pageIndex": page, "x": 20.0, "y": 30.0, "width": 100.0, "height": 100.0,
       "sourceOffset": Double(page) * 100]
    }
    let record = try DocumentLayoutRecord(receipt: ["sourceKey": source, "layoutScope": "source", "layoutCanonical": true,
      "pageCount": target + 1, "width": geometry.width, "height": geometry.height, "regions": regions, "anchors": [],
      "reading": [[id, "1111111111111111", 0, 0, 10, 0, 30.0],
        [id, "2222222222222222", target * 100, 0, 10, target, 30.0]]] as NSDictionary,
      sourceKey: source, blockIDs: [id], geometry: geometry)
    return .init(pageCount: record.pageCount, sourceRevision: source, record: record)
  }
}
