import CSQLite
import Foundation
import Testing
@testable import NotebookCore

private enum PageAppendFault: Error { case disk }

private final class PageAppendSQLWork: @unchecked Sendable {
  private let lock = NSLock()
  private var count: Int64 = 0
  var value: Int64 { lock.withLock { count } }
  func record(_ database: NotebookSQLConnection) {
    var total: Int64 = 0, statement = sqlite3_next_stmt(database.handle, nil)
    while let current = statement {
      total += Int64(sqlite3_stmt_status(current, SQLITE_STMTSTATUS_VM_STEP, 0))
      statement = sqlite3_next_stmt(database.handle, current)
    }
    lock.withLock { count = total }
  }
}

/// Includes the outer dependency validator, reference indexes and journal.
/// Counting returned rows or measuring only the command closure hides scans.
private func pageAppendSQLSteps(store: NotebookStore, index: WorkspaceIndex, page: PageDocument) throws -> Int64 {
  let work = PageAppendSQLWork()
  let measured = NotebookStore(root: store.root) { phase in
    if phase == .beforeCommit, let database = store.currentSQL { work.record(database) }
  }
  _ = try measured.saveWorkspaceSelection(index: index, createdPage: page)
  return work.value
}

private func fillNotebookPages(store: NotebookStore, index: WorkspaceIndex, count: Int, actor: UUID) throws {
  let itemID = index.selectedItemID.uuidString.lowercased(), parent = "workspace.json#/items/@" + itemID
  let stamp = index.stamp.advanced(by: actor)!
  try store.commandTransaction {
    let database = store.currentSQL!
    var pages = index.selectedItem.pageIDs
    for position in 1..<count {
      let page = PageDocument(size: .init(width: 834, height: 1194), actor: actor), id = page.id.uuidString.lowercased()
      try store.savePage(page)
      pages.append(page.id)
      try store.writeFragment(.init(address: parent + "/pageIDs/@" + id, file: "workspace.json", parent: parent,
        collection: "pageIDs", member: id, position: position, value: .string(page.id.uuidString), collections: []), database: database)
      let key = fieldKey(["items", itemID, "pageIDs", id])
      try store.writeFragment(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), file: "workspace.json", parent: "workspace.json#",
        collection: "collaboration/fields", member: key, position: 0, value: try .encode(ContentFieldVersion(stamp: stamp, human: true)), collections: []), database: database)
    }
    let order = try store.readPageOrder(index.selectedItemID)
    let valueRoot = try NotebookPageOrderVector.build(pages, write: { try store.writePageOrderNode($0) })
    try store.writePageOrder(.authored(root: valueRoot, stamp: stamp, human: true, previous: order), itemID: index.selectedItemID)
    for field in ["exists", "pageIDs"] {
      let key = fieldKey(["items", itemID, field]), address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
      let previous = try #require(try store.storedFragments(address: address, descendants: false).first)
      let version = ContentFieldVersion(stamp: stamp, human: true, previous: try previous.value.decode(ContentFieldVersion.self))
      try store.writeFragment(previous.replacing(value: try .encode(version)), database: database)
    }
    let root = try #require(try store.storedFragments(address: "workspace.json#", descendants: false).first)
    try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(stamp))), database: database)
  }
}

@Suite("A page landing publishes only its addressed membership")
struct NotebookPageAppendTests {
  private let size = PageSize(width: 834, height: 1194)

  fileprivate func fixture(_ body: (NotebookStore, UUID, WorkspaceIndex) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-page-append-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: size)
    let index = try store.loadIndex()
    try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 17, y: 29), scale: 0.7),
      viewport: .init(x: 834, y: 1194), selectedItemID: index.selectedItemID, notebookPageID: index.selectedPageID))
    try body(store, actor, index)
  }

  fileprivate func landing(_ base: WorkspaceIndex, actor: UUID) throws -> (WorkspaceIndex, PageDocument) {
    var index = base
    let result = index.selectPage(at: index.selectedItem.pageIDs.count, in: index.selectedItemID, actor: actor, pageSize: size)
    return try (index, #require(result?.createdPage))
  }

  private func fixedLanding(_ base: WorkspaceIndex, actor: UUID, pageID: UUID) throws -> (WorkspaceIndex, PageDocument) {
    // Fixed UUID ordering makes a reverse-arrival peer test deterministic.
    let stamp = try #require(base.stamp.advanced(by: actor)), item = base.selectedItem
    var metadata = base.collaboration
    for key in [fieldKey(["items", item.id.uuidString.lowercased(), "exists"]),
      fieldKey(["items", item.id.uuidString.lowercased(), "pageIDs"]),
      fieldKey(["items", item.id.uuidString.lowercased(), "pageIDs", pageID.uuidString.lowercased()])] {
      metadata.recordField(key, stamp: stamp, human: true)
    }
    var value = try JSONValue.encode(base)
    let edited = try JSONValue.encode(item).setting("pageIDs", .encode(item.pageIDs + [pageID]))
    value = try value.setting("items", .array([edited])).setting("stamp", .encode(stamp)).setting("collaboration", .encode(metadata))
    var intent = try value.decode(WorkspaceIndex.self)
    try intent.recordChanges(from: base, human: true)
    _ = intent.selectItem(item.id, pageID: pageID, actor: actor)
    return (intent, PageDocument(id: pageID, size: size, actor: actor))
  }

  private func transfer(_ change: NotebookDurableChange, from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
    while true {
      let missing = try destination.missingBlobHashes(for: change)
      if missing.isEmpty { break }
      for hash in missing {
        let bytes = try source.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < bytes { data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try destination.stageBlob(data: data, expectedHash: hash)
      }
    }
    _ = try destination.applyRemoteChange(change, peerID: peer)
  }

  private func drain(_ a: NotebookStore, _ b: NotebookStore, peerA: UUID, peerB: UUID) throws -> Bool {
    for _ in 0..<12 {
      let changesA = try a.changeJournal(after: b.peerCursor(peerID: peerA, direction: .incoming))
      let changesB = try b.changeJournal(after: a.peerCursor(peerID: peerB, direction: .incoming))
      if changesA.isEmpty && changesB.isEmpty { return true }
      for change in changesA { try transfer(change, from: a, to: b, peer: peerA) }
      for change in changesB { try transfer(change, from: b, to: a, peer: peerB) }
    }
    return false
  }

  @Test func oneWriterRejectsAnOrderWithoutSlotsAndSlotsWithoutTheirOrder() throws {
    try fixture { store, actor, base in
      try fillNotebookPages(store: store, index: base, count: 33, actor: actor)
      let index = try store.loadIndex(), before = try store.currentChangeCursor()
      let order = try store.readPageOrder(base.selectedItemID)
      #expect(throws: NotebookStorageError.invalidTransaction("page order position")) {
        try store.commandTransaction {
          let root = try NotebookPageOrderVector.build(index.selectedItem.pageIDs.reversed(), write: { try store.writePageOrderNode($0) })
          try store.writePageOrder(.authored(root: root, stamp: index.stamp.advanced(by: actor)!, human: true, previous: order), itemID: base.selectedItemID)
        }
      }
      let member = "workspace.json#/items/@" + base.selectedItemID.uuidString.lowercased() + "/pageIDs/@" + base.selectedPageID!.uuidString.lowercased()
      #expect(throws: NotebookStorageError.invalidTransaction("page membership position")) {
        try store.commandTransaction {
          let row = try #require(try store.storedFragments(address: member, descendants: false).first)
          try store.writeFragment(row.replacing(value: row.value, position: 1), database: store.currentSQL!)
        }
      }
      #expect(throws: (any Error).self) {
        try store.commandTransaction { try store.removeFragment("workspace.json#/pageOrders/@" + base.selectedItemID.uuidString.lowercased(), database: store.currentSQL!) }
      }
      #expect(try store.currentChangeCursor() == before)
      #expect(try store.loadIndex().selectedItem.pageIDs == index.selectedItem.pageIDs)
    }
  }

  @Test func missingOrHashCorruptOrderDependenciesCannotPublishOrAcknowledgeThePage() throws {
    try fixture { source, actor, base in
      let peer = UUID(), target = NotebookStore(root: source.root.appendingPathComponent("receiver"))
      try target.prepareEmptyWorkspace(workspaceID: source.workspaceHeader().workspaceID)
      for change in try source.changeJournal(after: 0) { try transfer(change, from: source, to: target, peer: peer) }
      let cursor = try source.currentChangeCursor()
      try fillNotebookPages(store: source, index: base, count: 33, actor: actor)
      let change = try #require(try source.changeJournal(after: cursor).first)
      func data(_ hash: String) throws -> Data {
        try source.readBlobChunk(hash: hash, offset: 0, maxBytes: 1_048_576)
      }
      let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: data(change.manifestHash))
      #expect(manifest.format == 2 && manifest.pageOrderRoots.count == 1)
      // Record wrapper hashes are not the raw-node dependency hashes.
      try target.stageBlob(data: data(change.manifestHash), expectedHash: change.manifestHash)
      for record in manifest.records { if let hash = record.blobHash { try target.stageBlob(data: data(hash), expectedHash: hash) } }
      let incomingCursor = try target.peerCursor(peerID: peer, direction: .incoming)
      let publication = try target.currentChangeCursor()
      let root = try #require(manifest.pageOrderRoots.first)
      #expect(try target.missingBlobHashes(for: change).contains(root))
      #expect(throws: (any Error).self) { try target.applyRemoteChange(change, peerID: peer) }
      #expect(try target.pageCount(in: base.selectedItemID) == 1)
      #expect(try target.peerCursor(peerID: peer, direction: .incoming) == incomingCursor)
      #expect(try target.currentChangeCursor() == publication)
      try target.stageBlob(data: data(root), expectedHash: root)
      let child = try #require(try target.missingBlobHashes(for: change).first)
      try target.commandTransaction {
        try target.currentSQL!.run("INSERT INTO blobs(hash,data) VALUES(?,?)", [.text(child), .blob(Data("damaged node".utf8))])
      }
      #expect(throws: NotebookStorageError.blobHashMismatch) { try target.applyRemoteChange(change, peerID: peer) }
      #expect(try target.currentChangeCursor() == publication)
      #expect(try target.peerCursor(peerID: peer, direction: .incoming) == incomingCursor)
      #expect(try target.pageCount(in: base.selectedItemID) == 1)
      try target.commandTransaction {
        try target.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [
          .blob(Data(repeating: 0, count: NotebookPageOrderVector.maximumNodeBytes + 1)), .text(child)])
      }
      #expect(throws: NotebookStorageError.limitExceeded("page_order_node_bytes")) {
        try target.applyRemoteChange(change, peerID: peer)
      }
      #expect(try target.currentChangeCursor() == publication)
      #expect(try target.peerCursor(peerID: peer, direction: .incoming) == incomingCursor)
      #expect(try target.pageCount(in: base.selectedItemID) == 1)
      try target.commandTransaction { try target.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(data(child)), .text(child)]) }
      try transfer(change, from: source, to: target, peer: peer)
      #expect(try target.loadIndex().selectedItem.pageIDs == source.loadIndex().selectedItem.pageIDs)
      #expect(try target.readPageOrder(base.selectedItemID) == source.readPageOrder(base.selectedItemID))
      #expect(try target.peerCursor(peerID: peer, direction: .incoming) == change.sequence)
    }
  }

  @Test(arguments: [false, true])
  func anIncomingProjectionCannotBecomeACanonicalCheckpoint(omitWitness: Bool) throws {
    try fixture { source, _, base in
      let target = NotebookStore(root: source.root.appendingPathComponent("receiver")), peer = UUID()
      let workspaceID = try source.workspaceHeader().workspaceID
      try target.prepareEmptyWorkspace(workspaceID: workspaceID)
      let original = try #require(try source.changeJournal(after: 0).first)
      let encoded = try source.readBlobChunk(hash: original.manifestHash, offset: 0, maxBytes: 1_048_576)
      let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: encoded)
      var records: [NotebookRecordMutation] = []
      for record in manifest.records {
        if omitWitness && (record.address.hasPrefix("workspace.json#/pageOrders/@") || record.address.hasPrefix("workspace.json#/pageOrderNodes/@")) { continue }
        if record.address != "workspace.json#" { records.append(record); continue }
        let bytes = try source.readBlobChunk(hash: #require(record.blobHash), offset: 0, maxBytes: 1_048_576)
        let row = try JSONDecoder().decode(NotebookStoredFragment.self, from: bytes)
        var value = row.value.setting("isProjection", .bool(true)), collections = row.collections
        if omitWitness {
          value = value.setting("pageOrders", .object([:])).setting("pageOrderNodes", .object([:]))
          collections.removeAll { ["pageOrders", "pageOrderNodes"].contains($0.path.first ?? "") }
        }
        let bad = try NotebookStore.storageEncoder.encode(row.replacing(value: value, collections: collections))
        let hash = try source.commandTransaction { try source.currentSQL!.putBlob(bad) }
        records.append(.init(address: record.address, blobHash: hash))
      }
      let counterfeit = NotebookChangeManifest(transactionID: UUID(), workspaceID: workspaceID, records: records,
        pageOrderRoots: omitWitness ? [] : manifest.pageOrderRoots)
      let data = try NotebookStore.storageEncoder.encode(counterfeit)
      let hash = try source.commandTransaction { try source.currentSQL!.putBlob(data) }
      let change = NotebookDurableChange(sequence: 1, transactionID: counterfeit.transactionID, manifestHash: hash, byteCount: data.count)
      #expect(throws: (any Error).self) { try transfer(change, from: source, to: target, peer: peer) }
      #expect(try target.currentChangeCursor() == 0)
      #expect(try target.peerCursor(peerID: peer, direction: .incoming) == 0)
      #expect(try target.sqlRead { try $0.rows("SELECT count(*) FROM records").first![0].integer } == 0)
      try transfer(original, from: source, to: target, peer: peer)
      #expect(try target.loadIndex().selectedItem.pageIDs == base.selectedItem.pageIDs)
    }
  }

  @Test func appendDoesNotReadTheTreeOrAnotherSheetAndKeepsTheCurrentCamera() throws {
    try fixture { store, actor, base in
      let (intent, page) = try landing(base, actor: actor)
      let presence = try store.loadPresence(), before = try store.currentChangeCursor()
      // A broken unrelated body must not be part of this command's read set.
      try store.commandTransaction {
        for address in ["board.json#/boards/@" + base.rootBoardID.uuidString.lowercased(), pageFile(base.selectedPageID!) + "#/drawingData"] {
          try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)", [.blob(Data("unrelated damaged body".utf8)), .text(address)])
        }
      }
      _ = try store.saveWorkspaceSelection(index: intent, createdPage: page)
      #expect(try store.pageCount(in: base.selectedItemID) == 2)
      #expect(try store.pageID(at: 1, in: base.selectedItemID) == page.id)
      #expect(try store.loadPage(page.id) == page)
      #expect(try store.loadPresence() == presence.selecting(itemID: base.selectedItemID, pageID: page.id))
      let changed = try store.readChangedAddresses(after: before, through: store.currentChangeCursor())
      #expect(changed.addresses.count < 16)
      #expect(!changed.addresses.contains { $0.hasPrefix("board.json") || $0.hasPrefix(pageFile(base.selectedPageID!)) })
    }
  }

  @Test func aDeletedOwnerCannotBeResurrectedByItsAcceptedLanding() throws {
    try fixture { store, actor, base in
      let (intent, page) = try landing(base, actor: actor)
      var index = base, board = try store.loadBoard(items: base.items)
      let createdValue = index.createNotebook(title: "Retained", actor: actor, pageSize: size)
      let created = try #require(createdValue)
      let added = board.addItem(created.item.id, to: base.rootBoardID, near: .zero, actor: actor)
      #expect(added)
      try store.saveWorkspaceBundle(index: index, page: created.page, board: board)
      _ = try store.deleteWorkspaceItem(itemID: base.selectedItemID, actor: actor)
      let cursor = try store.currentChangeCursor(), presence = try store.loadPresence()
      #expect(throws: (any Error).self) { _ = try store.saveWorkspaceSelection(index: intent, createdPage: page) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.readItemHeader(base.selectedItemID) == nil)
      #expect(try !store.hasStoredValue(pageFile(page.id)))
      #expect(try store.loadPresence() == presence)
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func aFailedAppendExposesNeitherSelectionMembershipNorItsFirstStroke(fault: NotebookStorageFault) throws {
    try fixture { store, actor, base in
      let (intent, page) = try landing(base, actor: actor)
      let presence = try store.loadPresence(), cursor = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root) { if $0 == fault { throw PageAppendFault.disk } }
      #expect(throws: PageAppendFault.self) { _ = try failing.saveWorkspaceSelection(index: intent, createdPage: page) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.loadPresence() == presence)
      #expect(try store.pageCount(in: base.selectedItemID) == 1)
      #expect(try !store.hasStoredValue(pageFile(page.id)))
      var drawn = page
      _ = drawn.replaceDrawing(pageDrawingFixture(Data("first accepted stroke".utf8)), actor: actor)
      #expect(throws: (any Error).self) { _ = try store.saveMergedPage(drawn) }
      _ = try store.saveWorkspaceSelection(index: intent, createdPage: page)
      _ = try store.saveMergedPage(drawn)
      #expect(try store.loadPage(page.id) == drawn)
      #expect(try store.loadPresence().notebookPageID == page.id)
    }
  }

  @Test func anAfterCommitRetryKeepsTheFirstStrokeAndDoesNotAppendOrRestampTwice() throws {
    try fixture { store, actor, base in
      let (intent, page) = try landing(base, actor: actor)
      let failing = NotebookStore(root: store.root) { if $0 == .afterCommit { throw PageAppendFault.disk } }
      #expect(throws: PageAppendFault.self) { _ = try failing.saveWorkspaceSelection(index: intent, createdPage: page) }
      var drawn = page
      _ = drawn.replaceDrawing(pageDrawingFixture(Data("already durable stroke".utf8)), actor: actor)
      _ = try store.saveMergedPage(drawn)
      let cursor = try store.currentChangeCursor(), before = try store.loadIndex()
      _ = try store.saveWorkspaceSelection(index: intent, createdPage: page)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.loadIndex() == before)
      #expect(try store.loadPage(page.id) == drawn)
      #expect(try store.pageCount(in: base.selectedItemID) == 2)
    }
  }

  @Test(arguments: [false, true])
  func missingOrDamagedPresenceFailsTheWholeAppend(damaged: Bool) throws {
    try fixture { store, actor, base in
      let (intent, page) = try landing(base, actor: actor), presence = try store.loadPresence()
      if damaged {
        try store.commandTransaction {
          try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address='last-context.json#')", [.blob(Data("damaged presence".utf8))])
        }
      } else { try store.publishRecords(writes: [:], removals: ["last-context.json"]) }
      let cursor = try store.currentChangeCursor()
      #expect(throws: (any Error).self) { _ = try store.saveWorkspaceSelection(index: intent, createdPage: page) }
      #expect(throws: (any Error).self) { _ = try store.saveWorkspaceSelection(index: base, createdPage: nil) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try !store.hasStoredValue(pageFile(page.id)))
      #expect(try store.pageCount(in: base.selectedItemID) == 1)
      if !damaged {
        try store.savePresence(presence)
        _ = try store.saveWorkspaceSelection(index: intent, createdPage: page)
        #expect(try store.loadPresence().notebookPageID == page.id)
      }
    }
  }

  @Test func changedDependenciesAreCheckedByUUIDIncludingRemovalAndDuplicateOwnership() throws {
    try fixture { store, actor, base in
      let (intent, page) = try landing(base, actor: actor)
      _ = try store.saveWorkspaceSelection(index: intent, createdPage: page)
      let cursor = try store.currentChangeCursor(), owner = base.selectedItemID.uuidString.lowercased()
      let member = "workspace.json#/items/@" + owner + "/pageIDs/@" + page.id.uuidString.lowercased()
      #expect(throws: NotebookStorageError.self) { try store.publishRecords(writes: [:], removals: [pageFile(page.id)]) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(throws: NotebookStorageError.self) {
        try store.commandTransaction {
          let other = UUID().uuidString.lowercased(), parent = "workspace.json#/items/@" + other
          try store.writeFragment(.init(address: parent + "/pageIDs/@" + page.id.uuidString.lowercased(), file: "workspace.json", parent: parent,
            collection: "pageIDs", member: page.id.uuidString.lowercased(), position: 0, value: .string(page.id.uuidString), collections: []), database: store.currentSQL!)
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(throws: NotebookStorageError.self) {
        try store.commandTransaction {
          let absent = UUID(), parent = "workspace.json#/items/@" + owner
          try store.writeFragment(.init(address: parent + "/pageIDs/@" + absent.uuidString.lowercased(), file: "workspace.json", parent: parent,
            collection: "pageIDs", member: absent.uuidString.lowercased(), position: 2, value: .string(absent.uuidString), collections: []), database: store.currentSQL!)
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(throws: NotebookStorageError.self) {
        try store.commandTransaction {
          try store.removeFragment(member, database: store.currentSQL!)
          try store.publishRecords(writes: [:], removals: [pageFile(page.id)])
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
      try store.commandTransaction {
        let database = store.currentSQL!
        try store.removeFragment(member, database: database)
        try store.publishRecords(writes: [:], removals: [pageFile(page.id)])
        let key = fieldKey(["items", owner, "pageIDs", page.id.uuidString.lowercased()])
        let old = try #require(try store.storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first)
        let previous = try old.value.decode(ContentFieldVersion.self)
        let next = ContentFieldVersion(stamp: previous.stamp.advanced(by: actor)!, human: true, previous: previous)
        try store.writeFragment(old.replacing(value: try .encode(next)), database: database)
        let order = try store.readPageOrder(base.selectedItemID)
        let root = try NotebookPageOrderVector.build([base.selectedPageID!], write: { try store.writePageOrderNode($0) })
        let changedOrder = try NotebookPageOrderRegister.authored(root: root, stamp: next.stamp, human: true, previous: order)
        try store.writePageOrder(changedOrder, itemID: base.selectedItemID)
        let orderKey = fieldKey(["items", owner, "pageIDs"])
        let field = try #require(try store.storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([orderKey]), descendants: false).first)
        try store.writeFragment(field.replacing(value: try .encode(changedOrder.fieldVersion)), database: database)
        let catalog = try #require(try store.storedFragments(address: "workspace.json#", descendants: false).first)
        try store.writeFragment(catalog.replacing(value: catalog.value.setting("stamp", try .encode(next.stamp))), database: database)
      }
      #expect(try store.pageCount(in: base.selectedItemID) == 1)
      #expect(throws: (any Error).self) { _ = try store.saveWorkspaceSelection(index: intent, createdPage: page) }
      #expect(try !store.hasStoredValue(pageFile(page.id)))
    }
  }

  @Test func staleAppendsKeepEveryPageAndCannotAuthorizeATitleOrPlacementChange() throws {
    try fixture { store, actor, base in
      let other = UUID(), (first, pageA) = try landing(base, actor: actor), (second, pageB) = try landing(base, actor: other)
      let board = try store.loadBoard(items: base.items), boardTarget = CollaborationTarget(kind: .board, id: base.rootBoardID)
      let renamed = CollaborationAction(summary: "Independent title", expected: [
        .init(target: .init(kind: .workspace, id: base.rootBoardID), revision: base.stamp.revision),
        .init(target: boardTarget, revision: board.board(base.rootBoardID)!.stamp.revision)], operations: [
          .init(kind: .renameItem, target: boardTarget, id: base.selectedItemID.uuidString, values: ["title": .string("Durable title")])])
      _ = try store.applyCollaborationAction(renamed, actor: other)
      #expect(try store.moveWorkspaceItem(itemID: base.selectedItemID, in: base.rootBoardID, to: .init(x: 911, y: -713), actor: other))
      let physical = try store.readBoardItem(base.selectedItemID), before = try store.currentChangeCursor()
      _ = try store.saveWorkspaceSelection(index: first, createdPage: pageA)
      _ = try store.saveWorkspaceSelection(index: second, createdPage: pageB)
      let durable = try store.loadIndex(), pageIDs = durable.selectedItem.pageIDs
      #expect(pageIDs == [base.selectedPageID!, pageA.id, pageB.id])
      #expect(durable.selectedItem.title == "Durable title")
      #expect(try store.readBoardItem(base.selectedItemID) == physical)
      #expect(try store.loadPage(pageA.id) == pageA && store.loadPage(pageB.id) == pageB)
      let changed = try store.readChangedAddresses(after: before, through: store.currentChangeCursor())
      #expect(!changed.addresses.contains { $0.hasPrefix("board.json") || $0 == "workspace.json#/items/@" + base.selectedItemID.uuidString.lowercased() })
      let field = fieldKey(["items", base.selectedItemID.uuidString.lowercased(), "pageIDs"])
      let version = try #require(durable.collaboration.fields[field])
      #expect(version.includes(try #require(first.collaboration.fields[field])))
      #expect(version.includes(try #require(second.collaboration.fields[field])))
    }
  }

  @Test func validationAndPublicationDoNotScanTheUnchangedMembershipPrefix() throws {
    try fixture { store, actor, base in
      try fillNotebookPages(store: store, index: base, count: 1_024, actor: actor)
      let (intent, page) = try landing(base, actor: UUID())
      let steps = try pageAppendSQLSteps(store: store, index: intent, page: page)
      #expect(steps > 0 && steps < 20_000)
      #expect(try store.pageCount(in: base.selectedItemID) == 1_025)
      #expect(try store.pageID(at: 1_024, in: base.selectedItemID) == page.id)
      let plan = try store.sqlRead { try $0.rows("EXPLAIN QUERY PLAN SELECT MAX(position) FROM records INDEXED BY record_order WHERE parent=? AND collection='pageIDs'", [.text("workspace.json#/items/@" + base.selectedItemID.uuidString.lowercased())]).compactMap { $0[3].text }.joined(separator: " ") }
      #expect(plan.contains("record_order") && !plan.contains("SCAN records"))
      print("PAGE_APPEND_LOCAL pages=1024 sql_vm_steps=\(steps)")
    }
  }

  @Test(arguments: [false, true], [1, 2])
  func independentPeerAppendsRetainTheSamePageSequence(reverseDelivery: Bool, appendCount: Int) throws {
    try fixture { a, _, base in
      let actorA = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!, actorB = UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
      let peerA = UUID(), peerB = UUID(), b = NotebookStore(root: a.root.appendingPathComponent("peer"))
      try b.prepareEmptyWorkspace(workspaceID: a.workspaceHeader().workspaceID)
      for change in try a.changeJournal(after: 0) { try transfer(change, from: a, to: b, peer: peerA) }
      for change in try b.changeJournal(after: 0) { try transfer(change, from: b, to: a, peer: peerB) }
      try b.savePresence(a.loadPresence())
      let aCursor = try a.currentChangeCursor(), bCursor = try b.currentChangeCursor()
      let (left, pageA) = try fixedLanding(base, actor: actorA, pageID: UUID(uuidString: "10000000-0000-4000-8000-000000000011")!)
      let (right, pageB) = try fixedLanding(base, actor: actorB, pageID: UUID(uuidString: "20000000-0000-4000-8000-000000000022")!)
      _ = try a.saveWorkspaceSelection(index: left, createdPage: pageA)
      _ = try b.saveWorkspaceSelection(index: right, createdPage: pageB)
      var authoredA = left, authoredB = right, pages = [base.selectedPageID!, pageA.id, pageB.id]
      if appendCount == 2 {
        let (nextA, pageA2) = try fixedLanding(left, actor: actorA, pageID: UUID(uuidString: "05000000-0000-4000-8000-000000000033")!)
        let (nextB, pageB2) = try fixedLanding(right, actor: actorB, pageID: UUID(uuidString: "15000000-0000-4000-8000-000000000044")!)
        _ = try a.saveWorkspaceSelection(index: nextA, createdPage: pageA2)
        _ = try b.saveWorkspaceSelection(index: nextB, createdPage: pageB2)
        authoredA = nextA; authoredB = nextB; pages += [pageA2.id, pageB2.id]
      }
      let golden = try authoredA.merging(authoredB)
      let changesA = try a.changeJournal(after: aCursor), changesB = try b.changeJournal(after: bCursor)
      if reverseDelivery {
        for change in changesB { try transfer(change, from: b, to: a, peer: peerB) }
        for change in changesA { try transfer(change, from: a, to: b, peer: peerA) }
      } else {
        for change in changesA { try transfer(change, from: a, to: b, peer: peerA) }
        for change in changesB { try transfer(change, from: b, to: a, peer: peerB) }
      }
      let actualA = try a.loadIndex(), actualB = try b.loadIndex()
      #expect(Set(actualA.selectedItem.pageIDs) == Set(pages))
      #expect(Set(actualB.selectedItem.pageIDs) == Set(pages))
      #expect(actualA.selectedItem.pageIDs == actualB.selectedItem.pageIDs)
      #expect(actualA.selectedItem.pageIDs == golden.selectedItem.pageIDs)
      #expect(actualB.selectedItem.pageIDs == golden.selectedItem.pageIDs)
      let item = base.selectedItemID.uuidString.lowercased()
      #expect(actualA.pageOrders[item] == actualB.pageOrders[item])
      #expect(actualA.pageOrders[item] == golden.pageOrders[item])
      #expect(try a.loadPage(pageA.id) == b.loadPage(pageA.id))
      #expect(try a.loadPage(pageB.id) == b.loadPage(pageB.id))
      let beforeA = try a.currentChangeCursor(), beforeB = try b.currentChangeCursor()
      for change in changesA { _ = try b.applyRemoteChange(change, peerID: peerA) }
      for change in changesB { _ = try a.applyRemoteChange(change, peerID: peerB) }
      #expect(try a.currentChangeCursor() == beforeA && b.currentChangeCursor() == beforeB)
      #expect(try drain(a, b, peerA: peerA, peerB: peerB))
      let merged = try a.loadIndex()
      #expect(merged.pageOrders[item] == golden.pageOrders[item])
      let (afterMerge, nextPage) = try landing(merged, actor: actorA)
      _ = try a.saveWorkspaceSelection(index: afterMerge, createdPage: nextPage)
      #expect(try drain(a, b, peerA: peerA, peerB: peerB))
      let finalA = try a.loadIndex(), finalB = try b.loadIndex()
      #expect(finalA.selectedItem.pageIDs == golden.selectedItem.pageIDs + [nextPage.id])
      #expect(finalB.selectedItem.pageIDs == finalA.selectedItem.pageIDs)
      #expect(finalA.pageOrders[item] == finalB.pageOrders[item])
      #expect(finalA.pageOrders[item]?.heads.count == 1)
    }
  }
}

extension NotebookSQLScaleTests {
  @Test func aNewSheetDoesNotReadOneHundredThousandPreviousMemberships() throws {
    let fixture = NotebookPageAppendTests()
    try fixture.fixture { store, actor, base in
      try fillNotebookPages(store: store, index: base, count: 100_000, actor: actor)
      #expect(try store.loadIndex().isValid)
      let (intent, page) = try fixture.landing(base, actor: UUID())
      let cursor = try store.currentChangeCursor(), steps = try pageAppendSQLSteps(store: store, index: intent, page: page)
      #expect(steps > 0 && steps < 20_000)
      #expect(try store.pageCount(in: base.selectedItemID) == 100_001)
      #expect(try store.pageID(at: 100_000, in: base.selectedItemID) == page.id)
      let change = try store.readChangedAddresses(after: cursor, through: store.currentChangeCursor())
      #expect(change.addresses.count < 16)
      #expect(change.addresses.filter { $0.contains("/pageIDs/@") }.count == 1)
      print("PAGE_APPEND_SCALE pages=100000 sql_vm_steps=\(steps) changed_addresses=\(change.addresses.count)")
    }
  }
}
