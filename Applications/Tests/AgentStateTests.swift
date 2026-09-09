import NotebookCore
import XCTest
@testable import Notebook

final class AgentStateTests: XCTestCase {
  @MainActor
  func testTextCompletionAfterNavigationKeepsItsOriginalBoard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: PageSize(width: 834, height: 1194))
    let boardA = try XCTUnwrap(model.presence?.boardID)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    let elementID = try XCTUnwrap(model.addNativeText(boardID: boardA, on: notebook, at: .init(x: 100, y: 100)))
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 2000, y: 0)))
    model.updatePresence(.init(boardID: boardB, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    // The editor's debounce or onDisappear can finish after camera ownership changes.
    model.finishNativeTextEditing(boardID: boardA, elementID: elementID, text: "Продолжение у исходника")
    await model.finishPendingPersistence()
    let saved = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertEqual(saved.board(boardA)?.elements.first { $0.id == elementID }?.source,
      "Продолжение у исходника")
    XCTAssertTrue(saved.board(boardB)?.elements.isEmpty == true)
    model.finishNativeTextEditing(boardID: boardA, elementID: elementID, text: "")
    model.updateNativeText(boardID: boardA, elementID: elementID, text: "Не возвращать удалённый предмет")
    await model.finishPendingPersistence()
    let afterDeletion = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertFalse(afterDeletion.board(boardA)?.elements.contains { $0.id == elementID } ?? true)
    XCTAssertTrue(afterDeletion.board(boardB)?.elements.isEmpty == true)
  }

  @MainActor
  func testAcceptedInteractiveInputIsNotDiscardedByNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: PageSize(width: 834, height: 1194))
    let boardA = try XCTUnwrap(model.presence?.boardID)
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 2000, y: 0)))
    let creationSaved = await model.finishPendingPersistence()
    XCTAssertTrue(creationSaved, model.persistenceFailure ?? "")
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let element = SpatialElement(id: "input-before-navigation", surface: .board(boardA), kind: .web,
      frame: .init(x: 0, y: 0, width: 300, height: 200), worldOrigin: .zero, source: "control",
      html: "<button>Continue</button>", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(element, in: boardA, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    model.updatePresence(.init(boardID: boardB, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(42))
    await model.finishPendingPersistence()
    let saved = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertEqual(saved.board(boardA)?.elements.first { $0.id == element.id }?.state, .number(42))
    XCTAssertTrue(saved.board(boardB)?.elements.isEmpty == true)
    var moved = try XCTUnwrap(try model.store.readSpatialElement(boardID: boardA, elementID: element.id))
    let beforeFrame = moved.stamp
    XCTAssertTrue(moved.update(frame: .init(x: 80, y: 40, width: 320, height: 220), actor: model.actorID))
    hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertTrue(hierarchy.upsertElement(moved, in: boardA, expected: beforeFrame, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(43))
    await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardA, elementID: element.id)?.state, .number(43))

    var changed = try XCTUnwrap(try model.store.readSpatialElement(boardID: boardA, elementID: element.id))
    let beforeSource = changed.stamp
    XCTAssertTrue(changed.update(html: "<button>Different program</button>", actor: model.actorID))
    hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertTrue(hierarchy.upsertElement(changed, in: boardA, expected: beforeSource, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(99))
    await model.finishPendingPersistence()
    let afterLateReply = try model.store.loadBoard(items: model.store.loadIndex().items)
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

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: PageSize(width: 834, height: 1_194))
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

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: PageSize(width: 834, height: 1_194))
    let documentID = try XCTUnwrap(
      model.createDocument(at: .zero, paperSize: .letter)
    )

    let creationSaved = await model.finishPendingPersistence()
    XCTAssertTrue(creationSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(try store.loadDocument(documentID).paperSize, .letter)

    let document = try store.loadDocument(documentID)
    let source = try XCTUnwrap(document.blocks.first { $0.id == "body" }?.source)
    let status = try await model.commitDocumentSource(edit: .init(
      sessionID: UUID(), documentID: documentID, blockID: "body", baseSource: source,
      baseVersion: document.sourceVersion(blockID: "body"), source: "# Отредактировано на iPad", sequence: 1
    ))
    XCTAssertEqual(status, .committed)
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
    let deleted = await model.deleteItem(documentID)
    XCTAssertTrue(deleted)
    XCTAssertThrowsError(try store.loadDocument(documentID))
    XCTAssertThrowsError(try store.loadDocumentState(documentID))
  }

  @MainActor
  func testRemoteDocumentCatalogWaitsForAllDependencies() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: PageSize(width: 834, height: 1_194))
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

    await model.finishPendingPersistence()
    let peer = NotebookStore(root: root.appendingPathComponent("peer")), peerID = UUID()
    try NotebookPeerFixture.copy(from: store, to: peer, peerID: model.actorID)
    try peer.saveDocumentWorkspaceBundle(index: remoteIndex, document: document, state: state, board: remoteBoard)
    let changes = try peer.changeJournal(after: 0, limit: 16)
    let change = try XCTUnwrap(changes.last)
    try NotebookPeerFixture.stage(change, from: peer, to: store)
    XCTAssertEqual(model.workspace, original, "Staged blobs are not a visible publication")
    XCTAssertEqual(try store.loadIndex().items, original.items)
    try await NotebookPeerFixture.deliver(from: peer, to: model, peerID: peerID)

    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertNotNil(try store.readWorkspaceItem(item.id))
    XCTAssertEqual(try store.loadIndex().items, remoteIndex.items)
    XCTAssertEqual(model.workspace?.selectedItemID, original.selectedItemID,
      "Receiving independent content does not redirect the iPad's human selection")
    let delivered = try store.loadDocument(item.id)
    XCTAssertEqual(delivered.id, document.id)
    XCTAssertEqual(delivered.paperSize, document.paperSize)
    XCTAssertEqual(delivered.preamble, document.preamble)
    XCTAssertEqual(delivered.blocks, document.blocks)
    XCTAssertEqual(delivered.contentStamp, document.contentStamp)
    XCTAssertNotNil(delivered.collaboration, "Принятое содержание получает причинные версии полей")
    XCTAssertEqual(try store.loadDocumentState(item.id), state)
    XCTAssertEqual(model.presence?.focusedItemID, original.selectedItemID)
    XCTAssertEqual(model.presence?.mode, .page)
  }

  @MainActor
  func testRemoteDocumentDeletionRemovesItsDurableOwners() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: PageSize(width: 834, height: 1_194))
    let documentID = try XCTUnwrap(
      model.createDocument(at: .zero, paperSize: .a4)
    )
    await model.finishPendingPersistence()
    let peer = NotebookStore(root: root.appendingPathComponent("peer")), peerID = UUID()
    try NotebookPeerFixture.copy(from: store, to: peer, peerID: model.actorID)
    _ = try peer.deleteWorkspaceItem(itemID: documentID, actor: UUID())
    try await NotebookPeerFixture.deliver(from: peer, to: model, peerID: peerID)

    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertNil(model.documents[documentID])
    XCTAssertNil(model.documentStates[documentID])
    XCTAssertNil(try store.readWorkspaceItem(documentID))
    XCTAssertThrowsError(try store.loadDocument(documentID))
    XCTAssertThrowsError(try store.loadDocumentState(documentID))
  }
}
