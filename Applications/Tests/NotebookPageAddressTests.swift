import CSQLite
import Foundation
import XCTest
@testable import NotebookCore
@testable import Notebook

final class NotebookPageAddressTests: XCTestCase {
  @MainActor
  func testAWithdrawnNeighbourReadCannotEvictTheCurrentPageWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    for index in 1..<8 {
      XCTAssertEqual(model.selectNotebookPage(index, notebookID: item, expectedRoot: model.notebookPageRoot(item)!), index)
    }
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let order = try XCTUnwrap(model.notebookPageRoot(item))
    await model.prepareNotebookPage(at: 0, in: item)
    _ = model.selectNotebookPage(0, notebookID: item, expectedRoot: order)
    model.retainNotebookPageWindow([0, 1, 2, 3], in: item, root: order)
    for index in 1...3 { await model.prepareNotebookPage(at: index, in: item) }
    let drained = await model.finishPendingPersistence(); XCTAssertTrue(drained)
    let expected = try (0...3).map { try XCTUnwrap(model.notebookPage(at: $0, in: item)?.id) }
    XCTAssertNil(model.notebookPage(at: 6, in: item))

    for reenter in [false, true] {
      // Pause storage, not MainActor. A direction change withdraws the old read
      // while it waits behind an accepted write; the next swipe can demand it again.
      let (entered, start) = AsyncStream<Void>.makeStream()
      let release = DispatchSemaphore(value: 0)
      let writer = Task {
        try await model.performStoreCommand { _ in
          start.yield(); start.finish(); _ = release.wait(timeout: .now() + 5)
        }
      }
      defer { release.signal() }
      for await _ in entered { break }
      model.retainNotebookPageWindow([0, 1, 3, 6], in: item, root: order)
      let obsolete = Task { await model.prepareNotebookPage(at: 6, in: item) }
      await Task.yield()
      model.retainNotebookPageWindow([0, 1, 2, 3], in: item, root: order)
      var renewed: Task<Void, Never>?
      if reenter {
        model.retainNotebookPageWindow([0, 1, 3, 6], in: item, root: order)
        renewed = Task { await model.prepareNotebookPage(at: 6, in: item) }
        await Task.yield()
      }
      release.signal(); try await writer.value; await obsolete.value; await renewed?.value
      if reenter {
        XCTAssertNotNil(model.notebookPage(at: 6, in: item), "A renewed consumer cannot inherit the withdrawn read's cancellation")
        XCTAssertTrue([0, 1, 3, 6].allSatisfy { model.notebookPage(at: $0, in: item) != nil })
      } else {
        XCTAssertNil(model.notebookPage(at: 6, in: item), "Withdrawn preparation cannot occupy a live page slot")
        XCTAssertEqual((0...3).compactMap { model.notebookPage(at: $0, in: item)?.id }, expected,
          "A completed obsolete read must not remove a sheet already admitted for immediate reverse")
      }
      XCTAssertEqual(model.activePage?.id, expected[0])
      XCTAssertEqual(model.pages.count, 4)
    }
  }

  @MainActor
  func testColdNotebookReadsCurrentPaperBeforeUnrequestedPageBodies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let size = NotebookAppModel.defaultPageSize
    _ = try store.initializeWorkspace(actor: actor, pageSize: size)
    var workspace = try store.loadIndex()
    let itemID = workspace.selectedItemID, firstID = try XCTUnwrap(workspace.selectedPageID)
    let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .page, camera: .init(),
      viewport: .init(x: 834, y: 1194), focusedItemID: itemID, openProgress: 1,
      selectedItemID: itemID, notebookPageID: firstID)
    try store.savePresence(presence)
    var appended: [UUID] = []
    for index in 1..<4 {
      let value = try XCTUnwrap(workspace.appendPage(in: itemID, actor: actor, pageSize: size))
      var page = try XCTUnwrap(value.createdPage)
      if index > 1 {
        page = PageDocument(id: page.id, size: size, actor: actor, elements: [.init(id: "far-source", kind: .markdown,
          frame: .init(x: 20, y: 20, width: 300, height: 200),
          source: String(repeating: "Far paper.", count: 60_000), html: "<p>Far paper</p>")])
      }
      _ = try store.saveWorkspaceSelection(index: workspace, createdPage: page)
      appended.append(page.id)
    }
    try store.savePresence(presence)
    XCTAssertThrowsError(try store.readTransaction { store in
      try store.currentSQL!.limitReads(.init(rows: 512, bytes: 256 * 1_024, valueBytes: 64 * 1_024,
        reason: "whole_directory_body_negative_control"))
      return try store.readNotebookPageWindow(itemID: itemID, pages: ([firstID] + appended).map { .page($0) })
    }, "Reading all directory bodies, as cold startup previously did, exceeds the same budget")
    let cold = try store.readTransaction { store in
      try store.currentSQL!.limitReads(.init(rows: 512, bytes: 256 * 1_024, valueBytes: 64 * 1_024,
        reason: "cold_notebook_current_paper"))
      return try NotebookSceneState.read(store: store, presence: presence, viewport: presence.viewport)
    }
    XCTAssertEqual(Set(cold.pages.keys), [firstID])
    XCTAssertEqual(cold.pagePositions.count, 4, "The directory remains independent from its page bodies")
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: size)
    XCTAssertEqual(model.notebookPageCount(itemID), 4)
    XCTAssertEqual(model.activePage?.id, firstID)
    XCTAssertNil(model.notebookPage(at: 3, in: itemID))
    await model.prepareNotebookPage(at: 3, in: itemID)
    XCTAssertEqual(model.notebookPage(at: 3, in: itemID)?.id, appended[2])
    XCTAssertEqual(model.notebookPage(at: 3, in: itemID)?.elements.first?.source.count, 600_000)
  }

  @MainActor
  func testCoverageRetainsThePreparedDistantUUIDInsteadOfReinterpretingItsIndex() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    for index in 1..<12 {
      XCTAssertEqual(model.selectNotebookPage(index, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), index)
    }
    var saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareNotebookPage(at: 0, in: itemID)
    _ = model.selectNotebookPage(0, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? "")
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareNotebookPage(at: 9, in: itemID)
    let prepared = try XCTUnwrap(model.notebookPage(at: 9, in: itemID)), presence = try XCTUnwrap(model.presence)
    // A real coverage request republishes metadata without reading page bodies.
    let distant = SessionPresence(boardID: presence.boardID, mode: .page,
      camera: .init(center: .init(x: 40_000, y: 40_000), scale: 1), viewport: presence.viewport,
      focusedItemID: itemID, openProgress: 1, selectedItemID: itemID, notebookPageID: presence.notebookPageID)
    model.updatePresence(distant, settled: true)
    _ = model.sceneWorkset(presence: distant)
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(model.notebookPage(at: 9, in: itemID)?.id, prepared.id)
    await model.reloadExternalChanges()?.value
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(model.notebookPage(at: 9, in: itemID)?.id, prepared.id)
    XCTAssertEqual(model.selectNotebookPage(9, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 9)
    XCTAssertEqual(model.presence?.notebookPageID, prepared.id)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
  }

  @MainActor
  func testConcurrentDurableAppendReconcilesTheAcceptedUUIDAtItsActualTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID), oldRoot = try XCTUnwrap(model.notebookPageRoot(itemID))
    var peer = try model.store.loadIndex()
    let append = try XCTUnwrap(peer.appendPage(in: itemID, actor: UUID(), pageSize: NotebookAppModel.defaultPageSize))
    _ = try model.store.saveWorkspaceSelection(index: peer, createdPage: append.createdPage)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: itemID, expectedRoot: oldRoot), 1)
    let acceptedID = try XCTUnwrap(model.presence?.notebookPageID)
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(model.notebookPageCount(itemID), 3)
    XCTAssertEqual(model.presence?.notebookPageID, acceptedID)
    XCTAssertEqual(model.notebookPageIndex(acceptedID, in: itemID), 2)
    XCTAssertEqual(try model.store.resolveNotebookPage(append.pageID, in: itemID)?.index, 1)
    XCTAssertEqual(try model.store.resolveNotebookPage(acceptedID, in: itemID)?.index, 2)
  }

  @MainActor
  func testOneHundredThousandSheetsUseBoundedSceneAndDistantUUIDNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-page-address-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), itemID = UUID()
    let size = NotebookAppModel.defaultPageSize
    let ids = try await Task.detached {
      // The archive-sized constructor is a seed only. No UI read below receives
      // this array, its causal fields, or a complete workspace snapshot.
      let pages = (0..<100_000).map { _ in PageDocument(size: size, actor: actor) }
      let workspace = WorkspaceIndex(items: [.notebook(id: itemID, title: "100000 sheets", pageIDs: pages.map(\.id))],
        selectedItemID: itemID, selectedPageID: pages[50_000].id, stamp: .init(counter: 0, actor: actor))
      let board = BoardHierarchy.initial(rootBoardID: workspace.rootBoardID, itemIDs: [itemID], actor: actor)
      try store.commandTransaction {
        for page in pages { try store.savePage(page) }
        try store.saveWorkspaceBundle(index: workspace, page: pages[0], board: board)
        try store.saveSpatialInk(.init(stamp: workspace.stamp))
        try store.savePresence(.init(boardID: workspace.rootBoardID, mode: .page, camera: .init(), viewport: .init(x: 834, y: 1194),
          focusedItemID: itemID, openProgress: 1, selectedItemID: itemID, notebookPageID: pages[50_000].id))
      }
      // An unrequested membership's encoded body cannot be read accidentally.
      // Its indexed UUID/position and immutable order remain intact.
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      let address = "workspace.json#/items/@" + itemID.uuidString.lowercased() + "/pageIDs/@" + pages[17].id.uuidString.lowercased()
      try database.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)", [.blob(Data("{".utf8)), .text(address)])
      return (pages[0].id, pages[50_000].id, pages[77_777].id, pages.last!.id)
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: size)
    let drained = await model.finishPendingPersistence()
    XCTAssertTrue(drained, model.persistenceFailure ?? "")
    XCTAssertEqual(model.loadState, .ready)
    XCTAssertEqual(model.notebookPageCount(itemID), 100_000)
    XCTAssertEqual(model.presence?.notebookPageID, ids.1)
    XCTAssertEqual(model.notebookPageIndex(ids.1, in: itemID), 50_000)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.workspace?.selectedItem.pageIDs.count), 5)
    XCTAssertNil(model.notebookPage(at: 77_777, in: itemID), "Unloaded existing paper is not a ready blank")
    await model.prepareNotebookPage(at: 77_777, in: itemID)
    let readRoot = try XCTUnwrap(model.notebookPageRoot(itemID))
    XCTAssertEqual(model.notebookPage(at: 77_777, in: itemID)?.id, ids.2)
    XCTAssertEqual(model.selectNotebookPage(77_777, notebookID: itemID, expectedRoot: readRoot), 77_777)
    XCTAssertEqual(model.presence?.notebookPageID, ids.2)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    let resolved = await model.navigateToNotebookPage(id: ids.3, isCurrent: { true })
    XCTAssertTrue(resolved)
    XCTAssertEqual(model.notebookPageIndex(ids.3, in: itemID), 99_999)
    XCTAssertEqual(model.selectNotebookPage(100_000, notebookID: itemID, expectedRoot: readRoot), 100_000)
    let newID = try XCTUnwrap(model.presence?.notebookPageID)
    XCTAssertNil(model.selectNotebookPage(0, notebookID: itemID, expectedRoot: readRoot), "A previous root cannot commit a newly interpreted slot")
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(try store.resolveNotebookPage(newID, in: itemID)?.index, 100_000)
    XCTAssertEqual(model.notebookPageCount(itemID), 100_001)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.workspace?.selectedItem.pageIDs.count), 5)
  }
}
