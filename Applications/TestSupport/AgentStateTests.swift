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
    let address = NotebookToolAddress(surface: .cover(notebook), boardID: boardA, worldOrigin: nil,
      bounds: .init(x: 0, y: 0, width: WorkspaceItemGeometry.notebook.width, height: WorkspaceItemGeometry.notebook.height))
    let elementID = try XCTUnwrap(model.beginToolText(at: .init(x: 100, y: 100), address: address, screenScale: 1))
    model.commitNativeText(reference: address.reference(elementID), text: "Начало", finish: false)
    let initialSaved = await model.finishPendingPersistence(); XCTAssertTrue(initialSaved)
    await model.reloadExternalChanges()?.value
    let retained = try XCTUnwrap(model.boardHierarchy?.board(boardA)?.elements.first { $0.id == elementID })
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 2000, y: 0)))
    model.updatePresence(.init(boardID: boardB, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    // The editor's debounce or onDisappear can finish after camera ownership changes.
    model.commitNativeText(reference:.spatial(boardID:boardA,elementID:elementID),text:"Продолжение у исходника",finish:false,retainedSpatial:retained)
    await model.finishPendingPersistence()
    let saved = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertEqual(saved.board(boardA)?.elements.first { $0.id == elementID }?.source,
      "Продолжение у исходника")
    XCTAssertTrue(saved.board(boardB)?.elements.isEmpty == true)
    model.commitNativeText(reference:.spatial(boardID:boardA,elementID:elementID),text:"",finish:true,retainedSpatial:retained)
    model.commitNativeText(reference:.spatial(boardID:boardA,elementID:elementID),text:"Не возвращать удалённый предмет",finish:false,retainedSpatial:retained)
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
    let sourceBasis = try XCTUnwrap(model.boardHierarchy?.board(boardA)?.programStateBasis(element.id))
    model.updatePresence(.init(boardID: boardB, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(42), onCommitted: .init(sourceBasis: sourceBasis) { _ in })
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
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(43), onCommitted: .init(sourceBasis: sourceBasis) { _ in })
    await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardA, elementID: element.id)?.state, .number(43))

    var changed = try XCTUnwrap(try model.store.readSpatialElement(boardID: boardA, elementID: element.id))
    let beforeSource = changed.stamp
    XCTAssertTrue(changed.update(html: "<button>Different program</button>", actor: model.actorID))
    hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertTrue(hierarchy.upsertElement(changed, in: boardA, expected: beforeSource, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    model.commitSpatialElementState(boardID: boardA, rendered: element, state: .number(99), onCommitted: .init(sourceBasis: sourceBasis) { _ in })
    await model.finishPendingPersistence()
    let afterLateReply = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertEqual(afterLateReply.board(boardA)?.elements.first { $0.id == element.id }?.state, .number(43),
      "The previous WebKit program cannot change its replacement")
  }

  @MainActor
  func testAcceptedPageStateAfterEvictionKeepsEveryRevisionWithoutReopeningPaper() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let element = AgentElement(id: "retiring", kind: .web, frame: .init(x: 0, y: 0, width: 160, height: 120), source: "Retiring value", html: "<output>Value</output>")
    page.replaceElements([element], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let basis = try XCTUnwrap(model.pages[page.id]?.programStateBasis(element.id))
    let other = try XCTUnwrap(model.createNotebook(at: .init(x: 30_000, y: 30_000)))
    model.selectItem(other)
    _ = await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
    XCTAssertNil(model.pages[page.id], "The retiring page must really leave the loaded scene")
    let cursor = try model.store.currentChangeCursor()
    for value in [1.0, 2.0, 3.0] {
      let accepted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        if !model.commitElementState(pageID: page.id, elementID: element.id, state: .number(value),
          onCommitted: .init(sourceBasis: basis, { done.resume(returning: $0 != nil) })) { done.resume(returning: false) }
      }
      XCTAssertTrue(accepted)
      XCTAssertEqual(try model.store.readPageElement(pageID: page.id, elementID: element.id)?.state, .number(value))
    }
    _ = await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
    let file = "pages/" + page.id.uuidString.lowercased() + ".json"
    let changes = try model.store.changeJournal(after: cursor).filter { change in
      try model.store.readChangedAddresses(after: change.sequence - 1, through: change.sequence)
        .addresses.contains { $0.hasPrefix(file) }
    }
    XCTAssertEqual(changes.count, 3)
    XCTAssertNil(model.pages[page.id]); XCTAssertEqual(model.presence?.selectedItemID, other)
  }

  @MainActor
  func testWarmPageNoOpCannotAdoptStoredSourceABAOrANewerState() async throws {
    for sourceABA in [true, false] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
      retainNotebookUntilTeardown(model, removing: root)
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      var page = try XCTUnwrap(model.activePage)
      let element = AgentElement(id: "stale-no-op", kind: .web,
        frame: .init(x: 0, y: 0, width: 160, height: 120), source: "Original program",
        html: "<output>Value</output>", state: .number(0))
      page.replaceElements([element], actor: model.actorID)
      try model.store.savePage(page); await model.reloadExternalChanges()?.value
      let observed = try XCTUnwrap(model.pages[page.id])
      let basis = try XCTUnwrap(observed.programStateBasis(element.id))
      var durable = try model.store.loadPage(page.id)
      for index in 1...2 {
        let next = sourceABA
          ? AgentElement(id: element.id, kind: .web, frame: element.frame,
            source: index == 1 ? "Temporary replacement" : element.source, html: element.html, state: element.state)
          : element.updating(state: .number(Double(index)))
        XCTAssertTrue(durable.replaceElements([next], actor: model.actorID))
        try model.store.savePage(durable)
      }
      XCTAssertEqual(model.pages[page.id], observed, "The warm model must still be behind the addressed SQL owner")
      let cursor = try model.store.currentChangeCursor()
      var admitted = false
      let receipt = await withCheckedContinuation { (done: CheckedContinuation<NotebookProgramStateBasis?, Never>) in
        admitted = model.commitElementState(pageID: page.id, elementID: element.id, state: element.state,
          onCommitted: .init(sourceBasis: basis) { done.resume(returning: $0) })
        if !admitted { done.resume(returning: nil) }
      }
      XCTAssertTrue(admitted, "The stale warm no-op must reach the actual FIFO writer, not bypass this race")
      XCTAssertNil(receipt, "A no-op cannot borrow the replacement source or another value's durable basis")
      let saved = await model.finishPendingPersistence()
      XCTAssertTrue(saved, model.persistenceFailure ?? "")
      XCTAssertEqual(try model.store.readPageElement(pageID: page.id, elementID: element.id)?.state,
        sourceABA ? element.state : .number(2))
      if sourceABA { XCTAssertEqual(try model.store.currentChangeCursor(), cursor) }
      _ = await model.shutdown()
    }
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
    let bounds = CGRect(x: 0, y: 0, width: WorkspaceItemGeometry.notebook.width, height: WorkspaceItemGeometry.notebook.height)
    let address = NotebookToolAddress(surface: .cover(itemID), boardID: boardID, worldOrigin: nil, bounds: bounds)
    let elementID = try XCTUnwrap(model.beginToolText(at: .init(x: 830, y: 1_190), address: address, screenScale: 1))
    let draft = try XCTUnwrap(model.selectionSession.nativeText)
    XCTAssertEqual(draft.reference, address.reference(elementID))
    XCTAssertEqual(draft.frame, .init(x: 830, y: 1_190, width: bounds.width - 830, height: bounds.height - 1_190))
    XCTAssertFalse(model.board?.elements.contains { $0.id == elementID } ?? true,
      "Empty text belongs to the editor, not a second persistent insertion path")

    model.commitNativeText(reference:.spatial(boardID:boardID,elementID:elementID),text:"Первая мысль",finish:true)

    let workspace = try XCTUnwrap(model.workspace)
    await model.finishPendingPersistence()
    let saved = try store.loadBoard(items: workspace.items)
    let savedBoard = try XCTUnwrap(saved.board(workspace.rootBoardID))
    XCTAssertEqual(
      savedBoard.elements.first(where: { $0.id == elementID })?.source,
      "Первая мысль"
    )
    XCTAssertEqual(try store.nativeHistory(domain: .cover(itemID), actor: model.actorID).count, 1,
      "The first nonempty text is one ordinary native command")

    model.commitNativeText(reference:.spatial(boardID:boardID,elementID:elementID),text:"",finish:true)

    let removed = EditableElementReference.spatial(boardID:boardID,elementID:elementID)
    XCTAssertNil(model.nativeTextTarget(removed))
    XCTAssertNil(model.elementGeometry(removed))
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

    var document = try store.loadDocument(documentID)
    XCTAssertTrue(document.replaceContent(blocks: document.blocks + [
      .interactive(id: "counter", html: "<button>Count</button>", initialState: .object(["count": .number(0)]))
    ], actor: model.actorID))
    _ = try store.saveMergedDocument(document)
    let presence = try XCTUnwrap(model.presence)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: documentID,
      openProgress: 1, selectedItemID: documentID), settled: true)
    await model.finishPendingPersistence()
    await model.reloadExternalChanges()?.value
    document = try XCTUnwrap(model.documents[documentID])
    let source = try XCTUnwrap(document.blocks.first { $0.id == "body" }?.source)
    let status = try await model.commitDocumentSource(edit: .init(
      sessionID: UUID(), documentID: documentID, blockID: "body", baseSource: source,
      baseVersion: document.sourceVersion(blockID: "body"), source: "# Отредактировано на iPad", sequence: 1
    ))
    XCTAssertEqual(status, .committed)
    let stateVersion = try await model.commitDocumentState(
      documentID: documentID,
      blockID: "counter",
      value: .object(["count": .number(4)]),
      programIdentity: document.programIdentity(blockID: "counter")
    )
    XCTAssertNotNil(stateVersion)

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
    let initialSaved = await model.finishPendingPersistence()
    XCTAssertTrue(initialSaved, model.persistenceFailure ?? "")
    let original = try XCTUnwrap(model.workspace)
    let peer = NotebookStore(root: root.appendingPathComponent("peer")), peerID = UUID()
    try NotebookPeerFixture.copy(from: store, to: peer, peerID: model.actorID)
    // The peer authors a canonical archive, not the iPad's bounded scene projection.
    let originalCatalog = try peer.loadIndex()
    var remoteIndex = originalCatalog
    var remoteBoard = try peer.loadBoard(items: originalCatalog.items)
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

    try peer.saveDocumentWorkspaceBundle(index: remoteIndex, document: document, state: state, board: remoteBoard)
    let changes = try peer.changeJournal(after: 0, limit: 16)
    let change = try XCTUnwrap(changes.last)
    try NotebookPeerFixture.stage(change, from: peer, to: store)
    XCTAssertEqual(model.workspace, original, "Staged blobs are not a visible publication")
    XCTAssertEqual(try store.loadIndex().items, originalCatalog.items)
    try await NotebookPeerFixture.deliver(from: peer, to: model, peerID: peerID)

    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertNotNil(try store.readItemHeader(item.id))
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
    _ = try peer.deleteTestItem(itemID: documentID, actor: UUID())
    try await NotebookPeerFixture.deliver(from: peer, to: model, peerID: peerID)

    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertNil(model.documents[documentID])
    XCTAssertNil(model.documentStates[documentID])
    XCTAssertNil(try store.readItemHeader(documentID))
    XCTAssertThrowsError(try store.loadDocument(documentID))
    XCTAssertThrowsError(try store.loadDocumentState(documentID))
  }
}
