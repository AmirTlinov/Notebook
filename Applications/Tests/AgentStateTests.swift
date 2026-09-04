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
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let elementID = try XCTUnwrap(model.addNativeText(
      on: itemID,
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

    let workspace = try XCTUnwrap(model.workspace)
    let saved = try store.loadBoard(items: workspace.items)
    let savedBoard = try XCTUnwrap(saved.board(workspace.rootBoardID))
    XCTAssertEqual(
      savedBoard.elements.first(where: { $0.id == elementID })?.source,
      "Первая мысль"
    )

    model.finishNativeTextEditing(elementID: elementID, text: "")

    XCTAssertFalse(model.board?.elements.contains(where: {
      $0.id == elementID
    }) ?? true)
    XCTAssertFalse(
      try store.loadBoard(items: workspace.items)
        .board(workspace.rootBoardID)!.elements.contains(where: {
        $0.id == elementID
      })
    )
  }

  @MainActor
  func testDocumentSourceAndInteractiveStatePersistThroughTheirOwners() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let documentID = try XCTUnwrap(
      model.createDocument(at: .zero, paperSize: .letter)
    )

    XCTAssertEqual(try store.loadDocument(documentID).paperSize, .letter)

    model.replaceDocumentBlockSource(
      documentID: documentID,
      blockID: "body",
      source: "# Отредактировано на iPad"
    )
    model.commitDocumentState(
      documentID: documentID,
      blockID: "counter",
      value: .object(["count": .number(4)])
    )

    XCTAssertEqual(
      try store.loadDocument(documentID).blocks.first?.source,
      "# Отредактировано на iPad"
    )
    XCTAssertEqual(
      try store.loadDocumentState(documentID).value(for: "counter"),
      .object(["count": .number(4)])
    )
    XCTAssertTrue(model.deleteItem(documentID))
    XCTAssertThrowsError(try store.loadDocument(documentID))
    XCTAssertThrowsError(try store.loadDocumentState(documentID))
  }

  @MainActor
  func testRemoteDocumentCatalogWaitsForAllDependencies() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let original = try XCTUnwrap(model.workspace)
    var remoteIndex = original
    var remoteBoard = try XCTUnwrap(model.boardHierarchy)
    let remoteActor = UUID()
    let item = try XCTUnwrap(remoteIndex.createDocument(
      title: "Сетевой документ",
      actor: remoteActor
    ))
    XCTAssertTrue(remoteBoard.addItem(
      item.id,
      to: original.rootBoardID,
      near: WorldPoint(x: 1_200, y: 300),
      actor: remoteActor
    ))
    let document = DocumentDocument(
      id: item.id,
      actor: remoteActor,
      blocks: [.markdown(id: "body", source: "# Доставлено целиком")]
    )
    let state = DocumentStateJournal(id: item.id, actor: remoteActor)

    model.receivePeerMessage(.index(remoteIndex))
    XCTAssertEqual(model.workspace, original)
    XCTAssertEqual(try store.loadIndex(), original)

    model.receivePeerMessage(.document(document))
    model.receivePeerMessage(.documentState(state))
    XCTAssertEqual(model.workspace, original)
    model.receivePeerMessage(.board(remoteBoard))

    XCTAssertEqual(model.workspace, remoteIndex)
    XCTAssertEqual(try store.loadIndex(), remoteIndex)
    XCTAssertEqual(try store.loadDocument(item.id), document)
    XCTAssertEqual(try store.loadDocumentState(item.id), state)
    XCTAssertEqual(model.presence?.focusedItemID, item.id)
    XCTAssertEqual(model.presence?.mode, .document)
  }

  @MainActor
  func testRemoteDocumentDeletionRemovesItsDurableOwners() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let documentID = try XCTUnwrap(
      model.createDocument(at: .zero, paperSize: .a4)
    )
    var remoteIndex = try XCTUnwrap(model.workspace)
    var remoteBoard = try XCTUnwrap(model.boardHierarchy)
    let actor = UUID()
    XCTAssertNotNil(remoteIndex.deleteItem(documentID, actor: actor))
    XCTAssertTrue(remoteBoard.deleteItem(
      documentID,
      from: remoteIndex.rootBoardID,
      kind: .document,
      actor: actor
    ))

    model.receivePeerMessage(.board(remoteBoard))
    model.receivePeerMessage(.index(remoteIndex))

    XCTAssertNil(model.documents[documentID])
    XCTAssertNil(model.documentStates[documentID])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: store.documentURL(documentID).path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: store.documentStateURL(documentID).path
    ))
  }
}
