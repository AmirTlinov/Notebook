import NotebookCore
import XCTest
@testable import Notebook

final class AgentStateTests: XCTestCase {
  @MainActor
  func testTextCompletionAfterNavigationKeepsItsOriginalBoard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1194))
    let boardA = try XCTUnwrap(model.presence?.boardID)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    let elementID = try XCTUnwrap(model.addNativeText(boardID: boardA, on: notebook, at: .init(x: 100, y: 100)))
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 2000, y: 0)))
    model.updatePresence(.init(boardID: boardB, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    // The editor's debounce or onDisappear can finish after camera ownership changes.
    model.finishNativeTextEditing(boardID: boardA, elementID: elementID, text: "Продолжение у исходника")
    await model.finishPendingPersistence()
    let saved = try model.store.loadBoard(items: XCTUnwrap(model.workspace).items)
    XCTAssertEqual(saved.board(boardA)?.elements.first { $0.id == elementID }?.source,
      "Продолжение у исходника")
    XCTAssertTrue(saved.board(boardB)?.elements.isEmpty == true)
    model.finishNativeTextEditing(boardID: boardA, elementID: elementID, text: "")
    model.updateNativeText(boardID: boardA, elementID: elementID, text: "Не возвращать удалённый предмет")
    await model.finishPendingPersistence()
    let afterDeletion = try model.store.loadBoard(items: XCTUnwrap(model.workspace).items)
    XCTAssertFalse(afterDeletion.board(boardA)?.elements.contains { $0.id == elementID } ?? true)
    XCTAssertTrue(afterDeletion.board(boardB)?.elements.isEmpty == true)
  }

  @MainActor
  func testAcceptedInteractiveInputIsNotDiscardedByNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1194))
    let boardA = try XCTUnwrap(model.presence?.boardID)
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 2000, y: 0)))
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let element = SpatialElement(id: "input-before-navigation", surface: .board(boardA), kind: .web,
      frame: .init(x: 0, y: 0, width: 300, height: 200), worldOrigin: .zero, source: "control",
      html: "<button>Continue</button>", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(element, in: boardA, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    model.updatePresence(.init(boardID: boardB, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(42))
    await model.finishPendingPersistence()
    let saved = try model.store.loadBoard(items: XCTUnwrap(model.workspace).items)
    XCTAssertEqual(saved.board(boardA)?.elements.first { $0.id == element.id }?.state, .number(42))
    XCTAssertTrue(saved.board(boardB)?.elements.isEmpty == true)
    var moved = try XCTUnwrap(model.boardHierarchy?.board(boardA)?.elements.first { $0.id == element.id })
    let beforeFrame = moved.stamp
    XCTAssertTrue(moved.update(frame: .init(x: 80, y: 40, width: 320, height: 220), actor: model.actorID))
    hierarchy = try XCTUnwrap(model.boardHierarchy)
    XCTAssertTrue(hierarchy.upsertElement(moved, in: boardA, expected: beforeFrame, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(43))
    await model.finishPendingPersistence()
    XCTAssertEqual(model.boardHierarchy?.board(boardA)?.elements.first { $0.id == element.id }?.state, .number(43))

    var changed = try XCTUnwrap(model.boardHierarchy?.board(boardA)?.elements.first { $0.id == element.id })
    let beforeSource = changed.stamp
    XCTAssertTrue(changed.update(html: "<button>Different program</button>", actor: model.actorID))
    hierarchy = try XCTUnwrap(model.boardHierarchy)
    XCTAssertTrue(hierarchy.upsertElement(changed, in: boardA, expected: beforeSource, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(99))
    await model.finishPendingPersistence()
    let afterLateReply = try model.store.loadBoard(items: XCTUnwrap(model.workspace).items)
    XCTAssertEqual(afterLateReply.board(boardA)?.elements.first { $0.id == element.id }?.state, .number(43),
      "The previous WebKit program cannot change its replacement")
  }

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
  func testNativeCoverTextKeepsOneDurableEditingLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let elementID = try XCTUnwrap(model.addNativeText(
      boardID: boardID, on: itemID,
      at: SpatialPoint(x: 830, y: 1_190)
    ))

    let draft = try XCTUnwrap(model.board?.elements.first(where: {
      $0.id == elementID
    }))
    XCTAssertEqual(draft.frame.x, WorkspaceItemGeometry.notebook.width - 420)
    XCTAssertEqual(draft.frame.y, WorkspaceItemGeometry.notebook.height - 120)

    model.finishNativeTextEditing(
      boardID: boardID, elementID: elementID,
      text: "Первая мысль"
    )

    let workspace = try XCTUnwrap(model.workspace)
    await model.finishPendingPersistence()
    let saved = try store.loadBoard(items: workspace.items)
    let savedBoard = try XCTUnwrap(saved.board(workspace.rootBoardID))
    XCTAssertEqual(
      savedBoard.elements.first(where: { $0.id == elementID })?.source,
      "Первая мысль"
    )

    model.finishNativeTextEditing(boardID: boardID, elementID: elementID, text: "")

    XCTAssertFalse(model.board?.elements.contains(where: {
      $0.id == elementID
    }) ?? true)
    await model.finishPendingPersistence()
    XCTAssertFalse(
      try store.loadBoard(items: workspace.items)
        .board(workspace.rootBoardID)!.elements.contains(where: {
        $0.id == elementID
      })
    )
  }

  @MainActor
  func testDocumentSourceAndInteractiveStatePersistThroughTheirOwners() async throws {
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

    await model.finishPendingPersistence()
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
  func testRemoteDocumentCatalogWaitsForAllDependencies() async throws {
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
    let delivered = try store.loadDocument(item.id)
    XCTAssertEqual(delivered.id, document.id)
    XCTAssertEqual(delivered.paperSize, document.paperSize)
    XCTAssertEqual(delivered.preamble, document.preamble)
    XCTAssertEqual(delivered.blocks, document.blocks)
    XCTAssertEqual(delivered.contentStamp, document.contentStamp)
    XCTAssertNotNil(delivered.collaboration, "Принятое содержание получает причинные версии полей")
    XCTAssertEqual(try store.loadDocumentState(item.id), state)
    XCTAssertEqual(model.presence?.focusedItemID, item.id)
    XCTAssertEqual(model.presence?.mode, .document)
  }

  @MainActor
  func testRemoteDocumentDeletionRemovesItsDurableOwners() async throws {
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
      spatialInk: SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: actor)),
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
