import NotebookCore
import XCTest
@testable import Notebook

final class MacModelLifecycleTests: XCTestCase {
  @MainActor
  func testMCPStyleFileChangeReloadsWithoutAMountedWindow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)

    var changed = try XCTUnwrap(model.board)
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let center = WorldPoint(x: 740, y: 960)
    XCTAssertTrue(
      changed.moveNotebook(notebookID, to: center, actor: UUID())
    )
    try store.saveBoard(changed, notebookIDs: [notebookID])

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while model.board?.stamp != changed.stamp,
      clock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(model.board?.stamp, changed.stamp)
    XCTAssertEqual(model.board?.focusedCenter(of: notebookID), center)
  }
}
