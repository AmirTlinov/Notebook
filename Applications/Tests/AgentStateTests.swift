import NotebookCore
import XCTest
@testable import Notebook

final class AgentStateTests: XCTestCase {
  @MainActor
  func testInteractiveElementCanCommitAnyJSONRoot() {
    XCTAssertEqual(AgentWebCoordinator.decodeState(7), .number(7))
    XCTAssertEqual(AgentWebCoordinator.decodeState("готово"), .string("готово"))
    XCTAssertEqual(AgentWebCoordinator.decodeState(NSNull()), .null)
    XCTAssertEqual(
      AgentWebCoordinator.decodeState(["enabled": true]),
      .object(["enabled": .bool(true)])
    )
  }

  @MainActor
  func testNativeCoverTextKeepsOneDurableEditingLifecycle() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let elementID = try XCTUnwrap(model.addNativeText(
      on: notebookID,
      at: SpatialPoint(x: 830, y: 1_190)
    ))

    let draft = try XCTUnwrap(model.board?.elements.first(where: {
      $0.id == elementID
    }))
    XCTAssertEqual(draft.frame.x, NotebookGeometry.width - 420)
    XCTAssertEqual(draft.frame.y, NotebookGeometry.height - 120)

    model.finishNativeTextEditing(
      elementID: elementID,
      text: "Первая мысль"
    )

    let notebookIDs = Set(try XCTUnwrap(model.workspace).notebooks.map(\.id))
    let saved = try store.loadBoard(notebookIDs: notebookIDs)
    XCTAssertEqual(
      saved.elements.first(where: { $0.id == elementID })?.source,
      "Первая мысль"
    )

    model.finishNativeTextEditing(elementID: elementID, text: "")

    XCTAssertFalse(model.board?.elements.contains(where: {
      $0.id == elementID
    }) ?? true)
    XCTAssertFalse(
      try store.loadBoard(notebookIDs: notebookIDs).elements.contains(where: {
        $0.id == elementID
      })
    )
  }
}
