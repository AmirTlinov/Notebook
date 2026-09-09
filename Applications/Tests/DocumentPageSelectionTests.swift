import NotebookCore
import XCTest
@testable import Notebook

final class DocumentPageSelectionTests: XCTestCase {
  @MainActor
  func testPeerRequestIsAppliedByTheIPadPresenceOwner() async throws {
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

    let peerID = UUID(), generation = UUID()
    model.peerConnected(.init(deviceID: peerID, workspaceID: try model.store.workspaceHeader().workspaceID,
      displayName: "Test Mac"), generation: generation)
    model.receivePeerTransient(
      .documentPageSelection(
        DocumentPageSelectionRequest(
          documentID: documentID,
          pageIndex: 3
        )
      ), peerID: peerID, generation: generation
    )

    XCTAssertEqual(model.presence?.documentPageIndex, 3)
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

    let peerID = UUID(), generation = UUID()
    model.peerConnected(.init(deviceID: peerID, workspaceID: try model.store.workspaceHeader().workspaceID,
      displayName: "Test Mac"), generation: generation)
    model.receivePeerTransient(
      .documentPageSelection(
        DocumentPageSelectionRequest(
          documentID: UUID(),
          pageIndex: 2
        )
      ), peerID: peerID, generation: generation
    )

    XCTAssertEqual(model.presence?.documentPageIndex, 0)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }
}
