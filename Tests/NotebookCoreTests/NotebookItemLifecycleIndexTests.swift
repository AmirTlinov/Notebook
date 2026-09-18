import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Item lifecycle derived index", .serialized)
struct NotebookItemLifecycleIndexTests {
  typealias Fixture = NotebookItemLifecycleTests.Fixture

  @Test func crossKindDocumentIsRejectedWithoutCorruptingTheNotebookExtent() throws {
    let f = try Fixture(), before = try #require(try f.store.readItemLifecycle(f.itemID))
    let document = DocumentDocument(id: f.itemID, actor: f.actor)
    let state = DocumentStateJournal(id: f.itemID, actor: f.actor)
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: CocoaError.self) { try f.store.saveDocument(document) }
    #expect(throws: CocoaError.self) { try f.store.saveDocumentState(state) }
    #expect(try f.store.currentChangeCursor() == cursor)
    // The lower storage writer also rejects the cross-kind pair at commit;
    // no derived lifecycle contribution may survive its rollback.
    #expect(throws: (any Error).self) {
      try f.store.commandTransaction {
        try f.store.publishCollaboration(writes: [documentFile(f.itemID): try .encode(document),
          stateFile(f.itemID): try .encode(state)])
      }
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try !f.store.hasStoredValue(documentFile(f.itemID)))
    #expect(try !f.store.hasStoredValue(stateFile(f.itemID)))
    let after = try #require(try f.store.readItemLifecycle(f.itemID))
    #expect(after.bodyRecordCount == before.bodyRecordCount)
  }

  @Test func documentBodiesJoinTheirCatalogItemInOneNativePublication() throws {
    let f = try Fixture(), id = UUID()
    let document = DocumentDocument(id: id, actor: f.actor, blocks: [.interactive(id: "answer", html: "<button>Choose</button>")])
    let state = DocumentStateJournal(id: id, actor: f.actor)
    // Native creation publishes catalogue, source and state together. A
    // source-only cut cannot mint the missing ownership or a retired baseline.
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: (any Error).self) {
      try f.store.commandTransaction {
        try f.store.publishCollaboration(writes: [documentFile(id): try .encode(document),
          stateFile(id): try .encode(state)])
      }
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    let before = try f.store.loadIndex(), treeBefore = try f.store.loadBoard(items: before.items)
    var after = before, treeAfter = treeBefore
    let created = after.createDocument(title: "Arrived later", actor: f.actor, documentID: id)
    #expect(created != nil)
    let placed = treeAfter.addItem(id, to: before.rootBoardID, near: .zero, actor: f.actor)
    #expect(placed)
    _ = try f.store.saveWorkspaceEdits(before: before, after: after, boardBefore: treeBefore, boardAfter: treeAfter,
      documents: [document], states: [state])
    let extent = try #require(try f.store.readItemLifecycle(id))
    #expect(extent.bodyRecordCount >= 3)
    var next = state
    let changed = next.commit(blockID: "answer", value: .string("Human"), actor: f.actor, human: true)
    #expect(changed)
    try f.store.saveDocumentState(next)
    #expect(try f.store.readItemLifecycle(id)?.revision != extent.revision)
  }

  @Test func boardExtentIncludesRemovedElementCausalHistoryWithoutChangingPixels() throws {
    let f = try Fixture(), id = UUID(), header = try f.store.workspaceHeader()
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let op = CollaborationOperation(kind: .createBoard, target: target, id: id.uuidString,
      values: ["center": try .encode(WorldPoint.zero)])
    let base = try f.store.readBasis(targets: [target, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Child board", expected: base.owners, operations: [op]), actor: f.actor)
    let before = try #require(try f.store.readItemLifecycle(id)), pixels = try f.store.referenceRevision(target: before.target)
    try f.store.commandTransaction {
      let parent = "board.json#/boards/@" + id.uuidString.lowercased(), key = fieldKey(["elements", "removed", "exists"])
      let version = ContentFieldVersion(stamp: .init(counter: 1, actor: UUID()), human: true, previous: nil)
      try f.store.writeFragment(.init(address: parent + "/board/collaboration/fields/@" + fieldKey([key]),
        file: "board.json", parent: parent, collection: "board/collaboration/fields", member: key,
        position: 0, value: try .encode(version), collections: []), database: f.store.currentSQL!)
    }
    #expect(try f.store.referenceRevision(target: before.target) == pixels)
    #expect(try f.store.readItemLifecycle(id)?.revision != before.revision)
  }

  @Test func schemaAdmissionRebuildsOnlyMetadataWithoutRepublishingOrDecodingBodies() throws {
    let f = try Fixture(); try f.write(f.pageID, text: "Unseen stored page")
    let before = try #require(try f.store.readItemLifecycle(f.itemID)), cursor = try f.store.currentReadCursor()
    try f.store.commandTransaction(advancesReadRevision: false) {
      let db = f.store.currentSQL!
      try db.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data("No body decoder may visit this".utf8)), .text(pageFile(f.pageID) + "#/elements/@label")])
      for table in ["lifecycle_members", "lifecycle_items", "lifecycle_files"] { try db.run("DROP TABLE " + table) }
      try db.run("PRAGMA user_version=7")
    }
    let reopened = NotebookStore(root: f.store.root)
    #expect(try reopened.readItemLifecycle(f.itemID) == before)
    #expect(try reopened.currentReadCursor() == cursor)
  }
}


extension NotebookItemLifecycleIndexTests {
  @Test func migrationMetadataPagesSeekInsideAFileWithOneHundredThousandRecords() throws {
    // A SQL metadata fixture, not a fabricated Notebook document. Exercise the
    // actual migration query and macOS SQLite plan without loading any body.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-sql-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try NotebookSQLConnection(url: root, writable: true, create: true)
    try db.run("CREATE TABLE records(address TEXT PRIMARY KEY,file TEXT,hash TEXT)")
    try db.run("CREATE INDEX record_files ON records(file,address)")
    let file = "pages/00000000-0000-4000-8000-000000000001.json"
    try db.run("WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<99999) INSERT INTO records SELECT printf('%06d',i),?,printf('%064d',i) FROM n", [.text(file)])
    final class Counter { var value = 0 }
    var counts: [Int] = []
    for after in ["", "050000", "099000"] {
      let counter = Counter()
      sqlite3_progress_handler(db.handle, 1, { raw in
        Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue().value += 1; return 0
      }, Unmanaged.passUnretained(counter).toOpaque())
      defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
      let rows = try db.rows(NotebookStore.lifecycleScanSQL,
        [.text(file), .text(after), .text("pages/\u{10ffff}")])
      #expect(rows.count == 256)
      counts.append(counter.value)
    }
    #expect(counts.allSatisfy { $0 < 10_000 })
    print("LIFECYCLE_METADATA_SEEK records=100000 batch=256 vm_steps=\(counts)")
  }
}
