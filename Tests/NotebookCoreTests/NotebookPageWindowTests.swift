import CSQLite
import Foundation
import Testing
@testable import NotebookCore

private final class PageWindowSQLTrace {
  var steps: Int64 = 0
  var queries: [String] = []
  func record(_ statement: OpaquePointer) {
    steps += Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
    if let sql = sqlite3_expanded_sql(statement) {
      queries.append(String(cString: sql)); sqlite3_free(sql)
    }
  }
}

private func measuredPageRead<T>(_ store: NotebookStore, _ read: () throws -> T) throws -> (T, PageWindowSQLTrace) {
  let trace = PageWindowSQLTrace()
  let value = try withExtendedLifetime(trace) {
    try store.readTransaction { _ in
      let database = store.currentSQL!
      // BEGIN precedes installation. PROFILE counts every statement of the
      // complete read closure and COMMIT, including repeated prepared queries.
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
        guard let context, let statement else { return 0 }
        Unmanaged<PageWindowSQLTrace>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement))
        return 0
      }, Unmanaged.passUnretained(trace).toOpaque())
      return try read()
    }
  }
  return (value, trace)
}

struct PageWindowFixture {
  let root: URL
  let store: NotebookStore
  let actor: UUID
  let itemID: UUID
  let pages: [UUID]
  let size = PageSize(width: 834, height: 1194)

  init(count: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-page-window-" + UUID().uuidString)
    let actor = UUID(), store = NotebookStore(root: root), size = PageSize(width: 834, height: 1194)
    self.root = root; self.actor = actor; self.store = store
    let header = try store.initializeWorkspace(actor: actor, pageSize: size)
    let initial = try store.loadIndex()
    let itemID = initial.selectedItemID
    self.itemID = itemID
    var identities = initial.selectedItem.pageIDs
    let parent = "workspace.json#/items/@" + itemID.uuidString.lowercased(), stamp = try #require(initial.stamp.advanced(by: actor))
    if count > 1 {
      // Canonical fixture through the existing writer, not raw invalid rows.
      // The seed cost is outside the addressed read measurement.
      try store.commandTransaction {
        let database = store.currentSQL!
        for position in 1..<count {
          let page = PageDocument(size: size, actor: actor), id = page.id.uuidString.lowercased()
          try store.savePage(page); identities.append(page.id)
          try store.writeFragment(.init(address: parent + "/pageIDs/@" + id, file: "workspace.json", parent: parent,
            collection: "pageIDs", member: id, position: position, value: .string(page.id.uuidString), collections: []), database: database)
          let key = fieldKey(["items", itemID.uuidString.lowercased(), "pageIDs", id])
          try store.writeFragment(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), file: "workspace.json",
            parent: "workspace.json#", collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(ContentFieldVersion(stamp: stamp, human: true)), collections: []), database: database)
        }
        let previous = try store.readPageOrder(itemID)
        let valueRoot = try NotebookPageOrderVector.build(identities, write: { try store.writePageOrderNode($0) })
        try store.writePageOrder(.authored(root: valueRoot, stamp: stamp, human: true, previous: previous), itemID: itemID)
        for field in ["exists", "pageIDs"] {
          let key = fieldKey(["items", itemID.uuidString.lowercased(), field])
          let previous = try #require(try store.storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first)
          let version = ContentFieldVersion(stamp: stamp, human: true, previous: try previous.value.decode(ContentFieldVersion.self))
          try store.writeFragment(previous.replacing(value: try .encode(version)), database: database)
        }
        let root = try #require(try store.storedFragments(address: "workspace.json#", descendants: false).first)
        try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(stamp))), database: database)
      }
    }
    pages = identities
    try store.savePresence(.init(boardID: header.rootBoardID, mode: .page, camera: .init(), viewport: .init(x: 834, y: 1194),
      focusedItemID: itemID, openProgress: 1, selectedItemID: itemID, notebookPageID: identities[0]))
  }

  func clean() { try? FileManager.default.removeItem(at: root) }

  func select(_ id: UUID) throws { try store.savePresence(store.loadPresence().selecting(itemID: itemID, pageID: id)) }

  /// Fault fixture only: the production single writer never mutates hash bytes.
  func corruptBlob(at address: String) throws {
    let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
    try database.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)", [.blob(Data("{".utf8)), .text(address)])
    #expect(sqlite3_changes(database.handle) == 1)
  }

  func reordered(_ ids: [UUID]) throws {
    try store.commandTransaction {
      let database = store.currentSQL!, previous = try store.readPageOrder(itemID)
      let current = try #require(try store.storedFragments(address: "workspace.json#", descendants: false).first)
      let stamp = try #require(try current.value["stamp"]?.decode(VersionStamp.self).advanced(by: actor))
      let parent = "workspace.json#/items/@" + itemID.uuidString.lowercased()
      let retained = Set(ids)
      for id in pages where !retained.contains(id) {
        try store.removeFragment(parent + "/pageIDs/@" + id.uuidString.lowercased(), database: database)
        try store.removeFragment(pageFile(id) + "#", database: database)
        let key = fieldKey(["items", itemID.uuidString.lowercased(), "pageIDs", id.uuidString.lowercased()])
        let field = try #require(try store.storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first)
        try store.writeFragment(field.replacing(value: .encode(ContentFieldVersion(stamp: stamp, human: true, previous: field.value.decode(ContentFieldVersion.self)))), database: database)
      }
      for (position, id) in ids.enumerated() {
        let row = try #require(try store.storedFragments(address: parent + "/pageIDs/@" + id.uuidString.lowercased(), descendants: false).first)
        try store.writeFragment(row.replacing(value: row.value, position: position), database: database)
      }
      let root = try NotebookPageOrderVector.build(ids, write: { try store.writePageOrderNode($0) })
      try store.writePageOrder(.authored(root: root, stamp: stamp, human: true, previous: previous), itemID: itemID)
      let key = fieldKey(["items", itemID.uuidString.lowercased(), "pageIDs"])
      let old = try #require(try store.storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first)
      try store.writeFragment(old.replacing(value: .encode(ContentFieldVersion(stamp: stamp, human: true, previous: old.value.decode(ContentFieldVersion.self)))), database: database)
      try store.writeFragment(current.replacing(value: current.value.setting("stamp", .encode(stamp))), database: database)
    }
  }
}

@Suite("Notebook read windows follow one immutable page order")
struct NotebookPageWindowTests {
  @Test func deletionEnumeratesDurableMembershipsAndRollsBackEveryRemovedPage() throws {
    let fixture = try PageWindowFixture(count: 129); defer { fixture.clean() }
    var workspace = try fixture.store.loadIndex()
    let created = workspace.createNotebook(title: "Retained", actor: fixture.actor, pageSize: fixture.size)
    let remaining = try #require(created)
    var board = try fixture.store.loadBoard(items: [workspace.items[0]])
    let placed = board.addItem(remaining.item.id, to: workspace.rootBoardID, near: .zero, actor: fixture.actor)
    #expect(placed)
    try fixture.store.saveWorkspaceBundle(index: workspace, page: remaining.page, board: board)
    try fixture.select(fixture.pages[100])
    let before = try fixture.store.workspaceHeader(), presence = try fixture.store.loadPresence()
    enum Failure: Error { case storage }
    let failing = NotebookStore(root: fixture.root) { if $0 == .beforeCommit { throw Failure.storage } }
    #expect(throws: Failure.self) { try failing.deleteWorkspaceItem(itemID: fixture.itemID, actor: fixture.actor) }
    #expect(try fixture.store.workspaceHeader() == before)
    #expect(try fixture.store.loadPresence() == presence)
    #expect(try fixture.store.pageCount(in: fixture.itemID) == 129)
    for id in fixture.pages { #expect(try fixture.store.loadPage(id).id == id) }
    // Deletion needs indexed identities, not these unrequested member bytes.
    try fixture.corruptBlob(at: "workspace.json#/items/@" + fixture.itemID.uuidString.lowercased() + "/pageIDs/@" + fixture.pages[17].uuidString.lowercased())
    _ = try fixture.store.deleteWorkspaceItem(itemID: fixture.itemID, actor: fixture.actor)
    #expect(try fixture.store.readItemHeader(fixture.itemID) == nil)
    #expect(try fixture.store.loadPresence().selectedItemID == remaining.item.id)
    #expect(try fixture.store.loadPresence().notebookPageID == remaining.page.id)
    for id in fixture.pages { #expect(try !fixture.store.hasStoredValue(pageFile(id))) }
    #expect(try fixture.store.loadPage(remaining.page.id) == remaining.page)
  }


  @Test func wireReadTargetsAndCursorsAreExactAndRejectOldUnboundedQueries() throws {
    for target in [NotebookPageReadTarget.index(4), .page(UUID()), .selection] {
      let wire = try JSONValue.encode(target)
      #expect(wire["kind"]?.string != nil && wire["_0"] == nil)
      #expect(try wire.decode(NotebookPageReadTarget.self) == target)
    }
    let position = NotebookPagePosition(itemID: UUID(), pageID: UUID(), index: 99,
      visibleRoot: String(repeating: "a", count: 64), readCursor: UInt64.max)
    let wire = try JSONValue.encode(position)
    #expect(wire["readCursor"] == .string(String(UInt64.max)))
    #expect(try wire.decode(NotebookPagePosition.self) == position)
    #expect(throws: (any Error).self) { try wire.setting("readCursor", .number(1)).decode(NotebookPagePosition.self) }
    for kind in ["workspaceItems", "workspaceItem", "pageAtIndex", "pageCount"] {
      #expect(throws: CollaborationError.self) {
        try NotebookIPC.decodeCommand(Data("{\"command\":\"read\",\"queries\":[{\"kind\":\"\(kind)\"}]}".utf8))
      }
    }
  }

  @Test func dispatcherSharesTheBodyBudgetAcrossWindowAndAddressedQueries() throws {
    let fixture = try PageWindowFixture(count: 8); defer { fixture.clean() }
    let dispatcher = NotebookCommandDispatcher(store: fixture.store)
    var first = NotebookReadQuery(kind: .notebookPages, id: fixture.itemID)
    first.pages = [.index(0), .index(1), .index(2)]
    var second = NotebookReadQuery(kind: .notebookPages, id: fixture.itemID)
    second.pages = [.index(3), .index(4)]
    var request = NotebookCommand(command: .read)
    request.queries = [first, second]
    #expect(throws: CollaborationError.self) { try dispatcher.handle(request) }
    request.queries = [first, .init(kind: .page, id: fixture.pages[3]), .init(kind: .page, id: fixture.pages[4])]
    #expect(throws: CollaborationError.self) { try dispatcher.handle(request) }
    first.pages = [.selection, .index(7)]
    request.queries = [first, .init(kind: .notebookDirectory, id: fixture.itemID, limit: 3),
      .init(kind: .notebookPosition, id: fixture.pages[7]), .init(kind: .itemHeader, id: fixture.itemID)]
    let response = try dispatcher.handle(request)
    let values = try #require(response["values"]?.array)
    #expect(try values[0].decode(NotebookPageWindow.self).pages.map(\.document.id) == [fixture.pages[0], fixture.pages[7]])
    #expect(values[0]["header"]?["readCursor"] == values[2]["readCursor"])
    #expect(values[3]["pageCount"] == .number(8) && values[3]["pageIDs"] == nil)
    #expect(try values[2].decode(NotebookPagePosition.self).index == 7)
    request.queries = [.init(kind: .notebookPosition, id: UUID())]
    #expect(try dispatcher.handle(request)["values"]?.array == [.null])
  }

  @Test func projectionAppendUsesTheRootTailAndRetainsOnlyPreparedWitnesses() throws {
    let fixture = try PageWindowFixture(count: 1024); defer { fixture.clean() }
    let item = try #require(try fixture.store.readItemHeader(fixture.itemID))
    var projection = try fixture.store.workspaceProjection(items: [item.item], selectedItemID: item.id, selectedPageID: item.firstPageID)
    let original = projection
    #expect(projection.selectedPageIndex == nil, "An incomplete projection cannot claim an array index")
    #expect(projection.selectPage(at: 1, in: item.id, actor: fixture.actor, pageSize: fixture.size) == nil)
    for index in 1024..<1088 {
      let prepared = projection.appendPage(in: item.id, actor: fixture.actor, pageSize: fixture.size)
      let append = try #require(prepared)
      #expect(append.pageIndex == index)
      _ = try fixture.store.saveWorkspaceSelection(index: projection, createdPage: append.createdPage)
      try projection.retainPageProjection([append.pageID])
      #expect(projection.selectedItem.pageIDs.count == 2)
      #expect(projection.pageOrderNodes.count <= 3)
      #expect(projection.collaboration.fields.count <= 8)
    }
    #expect(original.selectedItem.pageIDs == [fixture.pages[0]])
    #expect(original.notebookPageOrder(in: item.id)?.count == 1024)
    #expect(projection.notebookPageOrder(in: item.id)?.count == 1088)
    #expect(try fixture.store.resolveNotebookPage(projection.selectedPageID!, in: item.id)?.index == 1087)
    #expect(try fixture.store.resolveNotebookPage(fixture.pages[700], in: item.id)?.index == 700)
  }


  @Test func selectionFirstLastAndDirectoryCarryTheirActualUUIDAndRoot() throws {
    let fixture = try PageWindowFixture(count: 100); defer { fixture.clean() }
    try fixture.select(fixture.pages[35])
    let window = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID,
      pages: [.index(0), .selection, .page(fixture.pages[99]), .index(36)])
    #expect(window.header.item.pageCount == 100)
    #expect(window.header.item.firstPageID == fixture.pages[0])
    #expect(window.header.selectedPageID == fixture.pages[35] && window.header.selectedPageIndex == 35)
    #expect(window.pages.map(\.position.index) == [0, 35, 99, 36])
    #expect(window.pages.map(\.document.id) == [0, 35, 99, 36].map { fixture.pages[$0] })
    for entry in window.pages {
      #expect(entry.position.itemID == fixture.itemID && entry.position.pageID == entry.document.id)
      #expect(entry.position.visibleRoot == window.header.visibleRoot && entry.position.readCursor == window.header.readCursor)
      #expect(entry.document == (try fixture.store.loadPage(entry.position.pageID)))
    }
    let first = try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: 32, limit: 32,
      expectedVisibleRoot: window.header.visibleRoot)
    #expect(first.pages.map(\.position.pageID) == Array(fixture.pages[32..<64]))
    #expect(first.pages.map(\.position.index) == Array(32..<64))
    #expect(first.nextIndex == 64)
    #expect(first.pages.allSatisfy { $0.size == fixture.size })
    let last = try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: 96, limit: 64)
    #expect(last.pages.map(\.position.pageID) == Array(fixture.pages[96..<100]))
    #expect(last.nextIndex == nil)
    #expect(try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: 100).pages.isEmpty)
    #expect(try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: Int.max).pages.isEmpty)
    let resolved = try #require(try fixture.store.resolveNotebookPage(fixture.pages[35], in: fixture.itemID))
    #expect(resolved == window.pages[1].position)
    #expect(try JSONDecoder().decode(NotebookPageWindow.self, from: JSONEncoder().encode(window)) == window)
  }

  @Test func missingRequestsAndDuplicateResolvedIdentitiesFailBeforeAnyBodyRead() throws {
    let fixture = try PageWindowFixture(count: 4); defer { fixture.clean() }
    try fixture.corruptBlob(at: pageFile(fixture.pages[0]) + "#/drawingData")
    let (header, trace) = try measuredPageRead(fixture.store) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [])
    }
    #expect(header.pages.isEmpty && header.header.item.pageCount == 4)
    #expect(!trace.queries.contains { ($0.contains("r.file=") && !$0.contains("r.file='last-context.json'")) || $0.contains("WITH RECURSIVE") })
    #expect(throws: NotebookStorageError.invalidTransaction("duplicate requested notebook pages")) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.selection, .page(fixture.pages[0])])
    }
    #expect(throws: NotebookStorageError.limitExceeded("notebook_page_window")) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: Array(repeating: .index(0), count: 5))
    }
    for target in [NotebookPageReadTarget.page(UUID()), .index(4)] {
      #expect(throws: CollaborationError.self) {
        try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(0), target])
      }
    }
    #expect(throws: NotebookStorageError.invalidTransaction("negative page index")) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(-1)])
    }
    #expect(throws: (any Error).self) { try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(0)]) }
    #expect(throws: NotebookStorageError.limitExceeded("notebook_page_directory")) {
      try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, limit: 65)
    }
  }

  @Test func directoryIgnoresUnrequestedBodyAndCatalogueCausalFragments() throws {
    let fixture = try PageWindowFixture(count: 100); defer { fixture.clean() }
    for id in [fixture.pages[0], fixture.pages[50], fixture.pages[99]] {
      try fixture.corruptBlob(at: pageFile(id) + "#/drawingData")
    }
    let key = fieldKey(["items", fixture.itemID.uuidString.lowercased(), "pageIDs", fixture.pages[50].uuidString.lowercased()])
    try fixture.corruptBlob(at: "workspace.json#/collaboration/fields/@" + fieldKey([key]))
    let (directory, trace) = try measuredPageRead(fixture.store) {
      try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: 48, limit: 5)
    }
    #expect(directory.pages.map(\.position.pageID) == Array(fixture.pages[48..<53]))
    #expect(!trace.queries.contains { ($0.contains("r.file=") && !$0.contains("r.file='last-context.json'"))
      || $0.contains("WITH RECURSIVE") || $0.contains("r.member>=") })
    let window = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.page(fixture.pages[49])])
    #expect(window.pages.map(\.document.id) == [fixture.pages[49]])
  }

  @Test func selectionAbsenceIsNotAReadyBlankAndCorruptionIsNotAbsence() throws {
    let fixture = try PageWindowFixture(count: 3); defer { fixture.clean() }
    let removed = UUID()
    try fixture.select(removed)
    let header = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: []).header
    #expect(header.selectedPageID == removed && header.selectedPageIndex == nil)
    #expect(try fixture.store.resolveNotebookPage(removed, in: fixture.itemID) == nil)
    #expect(throws: CollaborationError.self) { try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.selection]) }
    try fixture.corruptBlob(at: "last-context.json#")
    #expect(throws: (any Error).self) { try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: []) }
  }

  @Test func aRemovedPreparedPageNeverResolvesToItsFormerSlotOccupant() throws {
    let fixture = try PageWindowFixture(count: 3); defer { fixture.clean() }
    try fixture.select(fixture.pages[1])
    let old = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.selection])
    try fixture.reordered([fixture.pages[0], fixture.pages[2]])
    let header = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: []).header
    #expect(header.item.pageCount == 2 && header.selectedPageID == fixture.pages[1] && header.selectedPageIndex == nil)
    #expect(try fixture.store.resolveNotebookPage(old.pages[0].document.id, in: fixture.itemID) == nil)
    #expect(throws: CollaborationError.self) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.page(old.pages[0].document.id)])
    }
    #expect(throws: CollaborationError.self) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.selection])
    }
    let replacement = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(1)])
    #expect(replacement.pages[0].document.id == fixture.pages[2])
    #expect(replacement.pages[0].position.visibleRoot != old.pages[0].position.visibleRoot)
  }

  @Test func contentSelectionAndOrderShareTheBorrowedWALSnapshot() throws {
    let fixture = try PageWindowFixture(count: 3)
    let completion = PageWindowConcurrentWriter()
    defer { if completion.finished { fixture.clean() } }
    let initial = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(1)])
    var edited = initial.pages[0].document
    let changed = edited.replaceElements([.init(id: "human", kind: .markdown,
      frame: .init(x: 10, y: 10, width: 100, height: 100), source: "new content", html: "new content")], actor: fixture.actor)
    #expect(changed)
    let changedPage = edited, writer = NotebookStore(root: fixture.root)
    let presence = try writer.loadPresence().selecting(itemID: fixture.itemID, pageID: fixture.pages[1])
    try fixture.store.readTransaction { store in
      let before = try store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(1)])
      DispatchQueue.global(qos: .userInitiated).async {
        completion.complete(Result {
          try writer.commandTransaction {
            _ = try writer.saveMergedPage(changedPage)
            try writer.savePresence(presence)
          }
        })
      }
      // Failure watchdog, not a persistence or rendering latency requirement.
      try #require(completion.done.wait(timeout: .now() + 10) == .success)
      try completion.result().get()
      let during = try store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(1)])
      #expect(during == before)
      let directory = try store.readNotebookPageDirectory(itemID: fixture.itemID, from: 1, limit: 1)
      #expect(directory.header == before.header && directory.pages[0].agentStamp == before.pages[0].document.agentStamp)
    }
    let after = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.selection])
    #expect(after.header.readCursor > initial.header.readCursor && after.header.visibleRoot == initial.header.visibleRoot)
    #expect(after.header.selectedPageID == fixture.pages[1] && after.header.selectedPageIndex == 1)
    #expect(after.pages[0].document.elements == changedPage.elements)
  }

  @Test func reorderRejectsStaleSlotsButPreparedUUIDResolvesToItsNewPosition() throws {
    let fixture = try PageWindowFixture(count: 33); defer { fixture.clean() }
    try fixture.select(fixture.pages[32])
    let old = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.page(fixture.pages[32])])
    try fixture.reordered(Array(fixture.pages.reversed()))
    #expect(throws: NotebookStorageError.transactionConflict) {
      try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.index(32)], expectedVisibleRoot: old.header.visibleRoot)
    }
    #expect(throws: NotebookStorageError.transactionConflict) {
      try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: 32, expectedVisibleRoot: old.header.visibleRoot)
    }
    #expect(throws: NotebookStorageError.transactionConflict) {
      try fixture.store.resolveNotebookPage(fixture.pages[32], in: fixture.itemID, expectedVisibleRoot: old.header.visibleRoot)
    }
    let new = try fixture.store.readNotebookPageWindow(itemID: fixture.itemID, pages: [.page(old.pages[0].document.id), .index(32)])
    #expect(new.pages[0].document == old.pages[0].document && new.pages[0].position.index == 0)
    #expect(new.pages[1].document.id == fixture.pages[0])
    #expect(new.header.visibleRoot != old.header.visibleRoot && new.header.readCursor > old.header.readCursor)
    #expect(new.header.selectedPageID == old.header.selectedPageID && new.header.selectedPageIndex == 0)
  }

  @Test func oneThousandPagesHaveBoundedReadWork() throws {
    let fixture = try PageWindowFixture(count: 1_024); defer { fixture.clean() }
    try assertBoundedPageReads(fixture)
  }
}

func assertBoundedPageReads(_ fixture: PageWindowFixture) throws {
  let count = fixture.pages.count
  try fixture.select(fixture.pages[count / 2])
  let (window, windowTrace) = try measuredPageRead(fixture.store) {
    try fixture.store.readNotebookPageWindow(itemID: fixture.itemID,
      pages: [.index(0), .selection, .page(fixture.pages[count - 2]), .index(count - 1)])
  }
  #expect(window.pages.map(\.document.id) == [0, count / 2, count - 2, count - 1].map { fixture.pages[$0] })
  #expect(windowTrace.steps > 0 && windowTrace.steps < 10_000)
  let (directory, directoryTrace) = try measuredPageRead(fixture.store) {
    try fixture.store.readNotebookPageDirectory(itemID: fixture.itemID, from: count - 64, limit: 64)
  }
  #expect(directory.pages.map(\.position.pageID) == Array(fixture.pages.suffix(64)))
  #expect(directoryTrace.steps > 0 && directoryTrace.steps < 20_000)
  let (resolved, resolveTrace) = try measuredPageRead(fixture.store) {
    try fixture.store.resolveNotebookPage(fixture.pages[count - 1], in: fixture.itemID)
  }
  #expect(resolved?.index == count - 1 && resolved?.pageID == fixture.pages[count - 1])
  #expect(resolveTrace.steps > 0 && resolveTrace.steps < 2_000)
  for trace in [windowTrace, directoryTrace, resolveTrace] {
    #expect(trace.queries.contains("COMMIT"))
    #expect(!trace.queries.contains { $0.contains("r.member>=") || $0.contains("WHERE r.file='workspace.json'") })
  }
  let (projection, projectionTrace) = try measuredPageRead(fixture.store) {
    let header = try #require(try fixture.store.readItemHeaders(limit: 1).first)
    return try fixture.store.workspaceProjection(items: [header.item], selectedItemID: header.id, selectedPageID: header.firstPageID)
  }
  #expect(projection.selectedItem.pageIDs == [fixture.pages[0]])
  #expect(projection.collaboration.fields.count <= 8 && projection.pageOrderNodes.count <= 4)
  #expect(projectionTrace.steps > 0 && projectionTrace.steps < 4_000)
  #expect(!projectionTrace.queries.contains { $0.contains("r.member>=") || $0.contains("WITH RECURSIVE") })
  print("PAGE_WINDOW_SCALE pages=\(count) window_vm=\(windowTrace.steps) directory64_vm=\(directoryTrace.steps) resolve_vm=\(resolveTrace.steps) projection_vm=\(projectionTrace.steps)")
}

private final class PageWindowConcurrentWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<Void, any Error>?
  let done = DispatchSemaphore(value: 0)
  var finished: Bool { lock.withLock { value != nil } }
  func complete(_ result: Result<Void, any Error>) { lock.withLock { value = result }; done.signal() }
  func result() throws -> Result<Void, any Error> { try lock.withLock { try #require(value) } }
}
