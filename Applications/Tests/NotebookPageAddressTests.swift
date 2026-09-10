import CSQLite
import Foundation
import XCTest
@testable import NotebookCore
@testable import Notebook

final class NotebookPageAddressTests: XCTestCase {
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
