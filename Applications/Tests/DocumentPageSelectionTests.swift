import NotebookCore
import XCTest
@testable import Notebook

final class DocumentPageSelectionTests: XCTestCase {
  @MainActor
  func testPeerRequestIsAppliedByTheIPadPresenceOwner() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(
      store: NotebookStore(root: root),
      startsNearbySync: false
    )
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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

    model.receivePeerMessage(
      .documentPageSelection(
        DocumentPageSelectionRequest(
          documentID: documentID,
          pageIndex: 3
        )
      )
    )

    XCTAssertEqual(model.presence?.documentPageIndex, 3)
    XCTAssertEqual(model.presence?.focusedItemID, documentID)
  }

  @MainActor
  func testRequestForAnotherDocumentCannotMoveTheFocusedDocument() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(
      store: NotebookStore(root: root),
      startsNearbySync: false
    )
    model.start(pageSize: NotebookAppModel.defaultPageSize)
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

    model.receivePeerMessage(
      .documentPageSelection(
        DocumentPageSelectionRequest(
          documentID: UUID(),
          pageIndex: 2
        )
      )
    )

    XCTAssertEqual(model.presence?.documentPageIndex, 0)
  }
}
