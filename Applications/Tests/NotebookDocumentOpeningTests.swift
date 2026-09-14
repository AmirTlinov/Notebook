import Foundation
import XCTest
@testable import NotebookCore
@testable import Notebook

@MainActor
final class NotebookDocumentOpeningTests: XCTestCase {
  func testAcceptedOpeningReadsAnAlreadySelectedCoverBeforeAnyCameraSample() async throws {
    let (model, first, second) = try await fixture()
    let closed = try XCTUnwrap(model.presence)
    XCTAssertEqual(closed.selectedItemID, first.id)
    XCTAssertEqual(closed.openProgress, 0)
    XCTAssertTrue(model.documents.isEmpty)
    // This is the former open path before its camera animation. Selection by
    // itself correctly stays light, but it cannot own an accepted opening.
    model.documentMeasurements.request(documentID: first.id, pageIndex: 0, cause: .open)
    model.selectItem(first.id)
    _ = await model.finishPendingPersistence()
    XCTAssertNil(model.documents[first.id])
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await opening.value
    XCTAssertEqual(model.documents[first.id], first)
    XCTAssertEqual(model.documentStates[first.id]?.id, first.id)
    XCTAssertNil(model.documents[second.id])
    XCTAssertNil(model.documentStates[second.id])
    XCTAssertEqual(model.presence, closed, "Reading the accepted body cannot jump the actual camera")
  }

  func testAnUnrelatedCorruptClosedBodyDoesNotBlockAcceptedOpening() async throws {
    let (model, first, second) = try await fixture()
    try await model.performStoreCommand { store in
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      let address = "documents/" + second.id.uuidString.lowercased() + ".json#/blocks/@text"
      try database.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data("not a document block".utf8)), .text(address)])
      XCTAssertThrowsError(try store.loadDocument(second.id))
    }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await opening.value
    XCTAssertEqual(model.documents[first.id], first)
    XCTAssertNil(model.documents[second.id])
    XCTAssertNil(model.persistenceFailure)
  }

  func testResolvedOpeningOutsideTheCameraCacheUsesItsDestinationBoardBeforeAnyCameraSample() async throws {
    let (model, first, second) = try await fixture()
    let oldBoard = try XCTUnwrap(model.presence?.boardID)
    let (boardID, document) = try await model.performStoreCommand { store in
      let actor = UUID(), header = try store.workspaceHeader()
      var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
      let board = try XCTUnwrap(index.createBoard(title: "Distant board", actor: actor))
      XCTAssertTrue(hierarchy.createBoard(board.id, in: header.rootBoardID,
        near: .init(x: 900_000, y: -700_000), actor: actor))
      let item = try XCTUnwrap(index.createDocument(title: "Distant document", actor: actor))
      XCTAssertTrue(hierarchy.addItem(item.id, to: board.id, near: .init(x: 90_000, y: -70_000), actor: actor))
      let document = DocumentDocument(id: item.id, actor: actor, paperSize: .a4,
        blocks: [.markdown(id: "text", source: "Addressed document body")])
      try store.saveDocumentWorkspaceBundle(index: index, document: document,
        state: .init(id: item.id, actor: actor), board: hierarchy)
      return (board.id, try store.loadDocument(document.id))
    }
    XCTAssertNil(model.itemForDisplay(id: document.id), "This is an addressed result outside the bounded scene")
    model.selectItem(document.id)
    let selected = try XCTUnwrap(model.presence)
    XCTAssertEqual(selected.boardID, oldBoard)
    let opening = try XCTUnwrap(model.prepareDocumentOpening(document.id, pageIndex: 0, boardID: boardID))
    await opening.value
    XCTAssertEqual(model.documents[document.id], document)
    XCTAssertNil(model.documents[first.id]); XCTAssertNil(model.documents[second.id])
    XCTAssertEqual(model.presence, selected, "Source preparation does not publish an unpresented destination camera")
  }

  func testCancelledOpeningCannotPublishItsDelayedBody() async throws {
    let (model, first, _) = try await fixture()
    let blocker = NotebookPersistenceFenceContract.Blocker()
    defer { blocker.release() }
    let predecessor = Task { try await model.performStoreCommand { _ in try blocker.hold() } }
    try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    model.inputGate.notifyAcceptedContact()
    blocker.release()
    try await predecessor.value
    await opening.value
    XCTAssertNil(model.documents[first.id])
    XCTAssertNil(model.documentStates[first.id])
    XCTAssertNil(model.persistenceFailure)
    let replacement = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await replacement.value
    XCTAssertEqual(model.documents[first.id], first, "Cancelling one request does not poison later admission")
  }

  func testCancellationBeforeTheFirstTaskTurnRetainsTheSinglePendingReadOwner() async throws {
    let (model, first, _) = try await fixture()
    let blocker = NotebookPersistenceFenceContract.Blocker()
    defer { blocker.release() }
    let predecessor = Task { try await model.performStoreCommand { _ in try blocker.hold() } }
    try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    model.inputGate.notifyAcceptedContact()
    let premature = expectation(description: "The submitted FIFO read still owns the opening task")
    premature.isInverted = true
    var isHoldingWriter = true
    let observer = Task { await opening.value; if isHoldingWriter { premature.fulfill() } }
    // Repeated accepted/revoked openings replace intent, while the one source
    // read stays behind the controlled writer until its actual completion.
    for _ in 0..<5 {
      _ = model.prepareDocumentOpening(first.id, pageIndex: 0)
      model.inputGate.notifyAcceptedContact()
      await Task.yield()
    }
    await fulfillment(of: [premature], timeout: 0.1)
    XCTAssertNil(model.documents[first.id])
    isHoldingWriter = false
    blocker.release()
    try await predecessor.value
    await observer.value
    XCTAssertNil(model.documents[first.id])
    let replacement = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    await replacement.value
    XCTAssertEqual(model.documents[first.id], first)
  }

  func testOnlyTheLatestOpeningSurvivesADelayedPredecessor() async throws {
    let (model, first, second) = try await fixture()
    let blocker = NotebookPersistenceFenceContract.Blocker()
    defer { blocker.release() }
    let predecessor = Task { try await model.performStoreCommand { _ in try blocker.hold() } }
    try await NotebookPersistenceFenceContract.until { blocker.entered.value == true }
    let opening = try XCTUnwrap(model.prepareDocumentOpening(first.id, pageIndex: 0))
    model.selectItem(second.id)
    let replacement = try XCTUnwrap(model.prepareDocumentOpening(second.id, pageIndex: 0))
    blocker.release()
    try await predecessor.value
    await opening.value; await replacement.value
    XCTAssertNil(model.documents[first.id], "A late source cannot enter the new document's live set")
    XCTAssertEqual(model.documents[second.id], second)
    XCTAssertEqual(model.presence?.selectedItemID, second.id)
    XCTAssertEqual(model.presence?.openProgress, 0)
  }

  private func fixture() async throws -> (NotebookAppModel, DocumentDocument, DocumentDocument) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-opening-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let pageSize = NotebookAppModel.defaultPageSize
    let documents = try await Task.detached {
      _ = try store.initializeWorkspace(actor: actor, pageSize: pageSize)
      var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
      let first = try XCTUnwrap(index.createDocument(title: "First", actor: actor))
      XCTAssertTrue(hierarchy.addItem(first.id, to: index.rootBoardID, near: .zero, actor: actor))
      let a = DocumentDocument(id: first.id, actor: actor, paperSize: .a4, blocks: [.markdown(id: "text", source: "First real body")])
      try store.saveDocumentWorkspaceBundle(index: index, document: a, state: .init(id: a.id, actor: actor), board: hierarchy)
      let second = try XCTUnwrap(index.createDocument(title: "Second", actor: actor))
      XCTAssertTrue(hierarchy.addItem(second.id, to: index.rootBoardID, near: .init(x: 2_000, y: 0), actor: actor))
      let b = DocumentDocument(id: second.id, actor: actor, paperSize: .a4, blocks: [.markdown(id: "text", source: "Second closed body")])
      _ = index.selectItem(first.id, actor: actor)
      try store.saveDocumentWorkspaceBundle(index: index, document: b, state: .init(id: b.id, actor: actor), board: hierarchy)
      try store.savePresence(.init(boardID: index.rootBoardID, mode: .cover, camera: .init(),
        viewport: .init(x: 834, y: 1194), focusedItemID: first.id, openProgress: 0, selectedItemID: first.id))
      return (try store.loadDocument(a.id), try store.loadDocument(b.id))
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    XCTAssertTrue(model.documents.isEmpty)
    return (model, documents.0, documents.1)
  }
}
