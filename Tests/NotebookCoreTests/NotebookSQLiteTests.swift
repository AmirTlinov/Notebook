import Foundation
import Testing
@testable import NotebookCore

private enum SQLTestFault: Error { case injected }

@Suite("SQLite owns atomic addressed publication")
struct NotebookSQLiteTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sql-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }

  @Test func rejectsLegacyWithoutWritingAnything() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let old = Data("the only old notebook".utf8), file = root.appendingPathComponent("workspace.json")
    try old.write(to: file)
    #expect(throws: NotebookStorageError.legacyStoreRequiresConversion) { try NotebookStore(root: root).prepare() }
    #expect(try Data(contentsOf: file) == old)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["workspace.json"])
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func rollsBackEveryUncommittedOwnerAndItsJournal(fault: NotebookStorageFault) throws {
    try fixture { store, actor in
      let index = try store.loadIndex(), id = try #require(index.selectedPageID)
      let before = try store.loadPage(id), cursor = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: point) == String(describing: fault) { throw SQLTestFault.injected }
      }
      var page = before; page.replaceDrawing(pageDrawingFixture(Data([1, 2, 3])), actor: actor)
      #expect(throws: SQLTestFault.self) { try failing.savePage(page) }
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.loadPage(id) == before)
      #expect(try reopened.currentChangeCursor() == cursor)
      #expect(try reopened.currentReadCursor() == read)
    }
  }

  @Test func anAmbiguousPostCommitErrorRetainsTheCompletedTransaction() throws {
    try fixture { store, actor in
      let id = try #require(store.loadIndex().selectedPageID)
      var page = try store.loadPage(id); page.replaceDrawing(pageDrawingFixture(Data([4, 5])), actor: actor)
      let cursor = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root) { if case .afterCommit = $0 { throw SQLTestFault.injected } }
      #expect(throws: SQLTestFault.self) { try failing.savePage(page) }
      #expect(try store.loadPage(id) == page)
      #expect(try store.currentChangeCursor() == cursor + 1)
      try store.savePage(page)
      #expect(try store.currentChangeCursor() == cursor + 1)
    }
  }

  @Test func localPresenceAdvancesReadFenceButNeverReplicates() throws {
    try fixture { store, _ in
      let cursor = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let presence = SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
      try store.savePresence(presence)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.currentReadCursor() == read + 1)
      try store.savePresence(presence)
      #expect(try store.currentReadCursor() == read + 1)
      let activity = NotebookInputActivity(deviceID: UUID(), sessionID: UUID(), sequence: 1,
        targets: [.init(kind: .board, id: WorkspaceRoot.boardID)])
      try store.saveInputActivity(activity)
      #expect(try store.currentChangeCursor() == cursor)
      try store.resetInputActivity(deviceID: activity.deviceID)
      #expect(try store.inputActivities().isEmpty)
    }
  }

  @Test func addressedProjectionPreservesUnseenMembersAndFieldVersions() throws {
    try fixture { store, actor in
      var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
      for offset in 0..<20 {
        let createdValue = index.createNotebook(title: "N\(offset)", actor: actor, pageSize: .init(width: 834, height: 1194))
        let created = try #require(createdValue)
        _ = hierarchy.addItem(created.item.id, to: index.rootBoardID, near: .init(x: Double(offset + 1) * 10_000, y: 0), actor: actor)
        try store.saveWorkspaceBundle(index: index, page: created.page, board: hierarchy)
      }
      let id = index.items[0].id
      let window = try store.readSceneWindow(boardID: index.rootBoardID, bounds: .init(origin: .init(x: -500, y: -700), width: 1_000, height: 1_400), limit: 8, pinnedIDs: [id])
      #expect(window.items.count == 1)
      let baseline = BoardHierarchy(rootBoardID: index.rootBoardID, boards: window.boards, stamp: hierarchy.stamp)
      var after = baseline
      let moved = after.moveItem(id, in: index.rootBoardID, to: .init(x: 3, y: 7), actor: actor)
      #expect(moved)
      _ = try store.saveBoardEdits(before: baseline, after: after)
      let durable = try store.loadBoard(items: index.items)
      #expect(Set(durable.itemIDs) == Set(index.items.map(\.id)))
      #expect(durable.board(index.rootBoardID)?.placement(of: id)?.center == .init(x: 3, y: 7))
      let projection = try store.workspaceProjection(items: window.items, selectedItemID: id, selectedPageID: window.items[0].pageIDs.first)
      let prefix = "items/" + id.uuidString.lowercased() + "/"
      #expect(projection.collaboration.fields.filter { $0.key.hasPrefix(prefix) } == index.collaboration.fields.filter { $0.key.hasPrefix(prefix) })
    }
  }

  @Test func duplicateMemberIDsAbortBeforeAnyRowIsPublished() throws {
    try fixture { store, _ in
      let cursor = try store.currentChangeCursor(), value = try #require(try store.storedValue("workspace.json"))
      let items = try #require(value["items"]?.array)
      let invalid = value.setting("items", .array(items + items))
      #expect(throws: NotebookStorageError.self) { try store.publishRecords(writes: ["workspace.json": invalid]) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.storedValue("workspace.json") == value)
    }
  }

  @Test func placementUpdatesAndHistoricalHashesUseAddressIndexes() throws {
    try fixture { store, _ in
      try store.readTransaction { _ in
        for sql in ["SELECT item_id FROM item_owners WHERE address=?", "DELETE FROM item_owners WHERE address=?"] {
          let plan = try store.currentSQL!.rows("EXPLAIN QUERY PLAN " + sql, [.text("placement")]).compactMap { $0[3].text }.joined(separator: " ")
          #expect(plan.contains("item_placement"))
          #expect(!plan.contains("SCAN item_owners"))
        }
        let history = try store.currentSQL!.rows("EXPLAIN QUERY PLAN SELECT blob_hash FROM change_records WHERE address=? AND sequence<=? ORDER BY sequence DESC LIMIT 1", [.text("owner"), .integer(3)]).compactMap { $0[3].text }.joined(separator: " ")
        #expect(history.contains("change_record_history"))
      }
    }
  }
}
