import Foundation
import NotebookCore
import XCTest
@testable import Notebook

final class PageTurnSelectionTests: XCTestCase {
  @MainActor
  func testRapidNotebookLandingsAdvanceMemoryBeforePersistenceCatchesUp()
    async throws
  {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebookID = try XCTUnwrap(model.workspace?.selectedItemID)

    XCTAssertEqual(
      model.selectNotebookPage(1, notebookID: notebookID),
      1
    )
    XCTAssertEqual(
      model.selectNotebookPage(2, notebookID: notebookID),
      2
    )
    XCTAssertEqual(model.workspace?.selectedPageIndex, 2)
    XCTAssertEqual(model.workspace?.selectedItem.pageIDs.count, 3)

    var persistedIndex: WorkspaceIndex?
    for _ in 0..<100 {
      if let candidate = try? store.loadIndex(),
        candidate.selectedPageIndex == 2
      {
        persistedIndex = candidate
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let persisted = try XCTUnwrap(persistedIndex)
    let selectedPageID = try XCTUnwrap(persisted.selectedPageID)
    XCTAssertEqual(try store.loadPage(selectedPageID).id, selectedPageID)
  }
}
