import CSQLite
import Darwin
import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed catalog, board and page delivery", .serialized)
struct AddressedReplicationTests {
  private func stage(_ change: NotebookDurableChange, from a: NotebookStore, to b: NotebookStore) throws {
    while true {
      let hashes = try b.missingBlobHashes(for: change)
      if hashes.isEmpty { return }
      for hash in hashes {
        let size = try a.blobSize(hash: hash)
        var bytes = Data()
        while Int64(bytes.count) < size { bytes += try a.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576) }
        try b.stageBlob(data: bytes, expectedHash: hash)
      }
    }
  }

  private final class Trace {
    var steps = 0, rows = 0, blobs = 0, bytes = 0
  }
  private func measured<T>(_ store: NotebookStore, label: String, count: Int, _ operation: () throws -> T) throws -> T {
    let trace = Trace(), start = ContinuousClock.now
    let result = try withExtendedLifetime(trace) {
      try store.commandTransaction {
        let context = Unmanaged.passUnretained(trace).toOpaque()
        sqlite3_progress_handler(store.currentSQL!.handle, 100, { raw in
          Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue().steps += 100; return 0
        }, context)
        sqlite3_trace_v2(store.currentSQL!.handle, UInt32(SQLITE_TRACE_ROW), { _, raw, pointer, _ in
          let trace = Unmanaged<Trace>.fromOpaque(raw!).takeUnretainedValue(), statement = OpaquePointer(pointer!)
          trace.rows += 1
          for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_BLOB {
            trace.blobs += 1; trace.bytes += Int(sqlite3_column_bytes(statement, column))
          }
          return 0
        }, context)
        return try operation()
      }
    }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    print("ADDRESSED_REPLICATION operation=\(label) owners=\(count) elapsed=\(start.duration(to: .now)) rows=\(trace.rows) payload_reads=\(trace.blobs) payload_bytes=\(trace.bytes) sql_steps=\(trace.steps) process_peak_rss=\(usage.ru_maxrss)")
    if ProcessInfo.processInfo.environment["NOTEBOOK_SYNC_BASELINE"] != "1" {
      #expect(trace.blobs < 250)
      #expect(trace.rows < 5_000)
      #expect(trace.steps < 200_000)
    }
    return result
  }

  @Test func oneChangeAmongIndependentOwnersHasAConstantReadSet() throws {
    let count = Int(ProcessInfo.processInfo.environment["NOTEBOOK_SYNC_SCALE"] ?? "1000")!
    #expect(count >= 1000 && count <= 100_000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("addressed-replication-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = NotebookStore(root: directory.appendingPathComponent("a")), b = NotebookStore(root: directory.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let index = try a.loadIndex(), pageID = index.selectedPageID!, itemID = index.selectedItemID
    var page = try a.loadPage(pageID)
    let element = AgentElement(id: "selected/a~😀", kind: .web, frame: .init(x: 10, y: 10, width: 100, height: 100), source: "Original", html: "<p>Original</p>")
    let replaced = page.replaceElements([element, .init(id: "foreign", kind: .web, frame: .init(x: 300, y: 300, width: 100, height: 100), source: "Foreign", html: String(repeating: "x", count: 1_000_000))], actor: actor)
    #expect(replaced)
    try a.savePage(page)
    let boardAddress = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased()
    let stamp = VersionStamp(counter: 0, actor: actor), version = try JSONValue.encode(ContentFieldVersion(stamp: stamp, human: true))
    // Stream real, independently owned documents through the production row
    // writer. The benchmark retains neither a giant catalog nor a giant board.
    try a.commandTransaction {
      let database = a.currentSQL!
      for position in 1..<count {
        let id = UUID(), key = id.uuidString.lowercased(), address = "workspace.json#/items/@" + key
        let item = WorkspaceItem.document(id: id, title: "Foreign \(position)")
        try a.writeFragment(.init(address: address, file: "workspace.json", parent: "workspace.json#", collection: "items", member: key, position: position,
          value: .object(["id": .string(item.id.uuidString), "kind": .string("document"), "title": .string(item.title)]),
          collections: [.init(path: ["pageIDs"], kind: .array)]), database: database)
        try a.publishRecords(writes: [documentFile(id): .encode(DocumentDocument(id: id, actor: actor)), stateFile(id): .encode(DocumentStateJournal(id: id, actor: actor))])
        for field in ["exists", "title", "kind", "pageIDs"] {
          let field = fieldKey(["items", key, field])
          try a.writeFragment(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([field]), file: "workspace.json", parent: "workspace.json#",
            collection: "collaboration/fields", member: field, position: 0, value: version, collections: []), database: database)
        }
        let placement = try WorkspacePlacement.authored(itemID: id, pose: .init(center: .init(x: Double(position) * 2000, y: 2000), zIndex: position), stamp: stamp, human: true, previous: nil)
        try a.writeFragment(.init(address: boardAddress + "/board/placements/@" + key, file: "board.json", parent: boardAddress,
          collection: "board/placements", member: key, position: 0, value: .encode(placement), collections: []), database: database)
      }
    }
    #expect(try a.workspaceHeader().itemCount == count)
    let cursor = try a.currentChangeCursor()
    // No open connection or writer exists during this isolated fixture copy.
    try FileManager.default.copyItem(at: a.root, to: b.root)
    try b.commandTransaction {
      try b.currentSQL!.run("INSERT INTO peer_cursors VALUES(?,'incoming',?)", [.text(actor.uuidString.lowercased()), .integer(Int64(cursor))])
    }
    #expect(try measured(a, label: "save_move", count: count) { try a.moveWorkspaceItem(itemID: itemID, in: header.rootBoardID, to: .init(x: 40, y: 60), actor: actor) })
    let moved = try #require(a.changeJournal(after: cursor).first)
    try stage(moved, from: a, to: b)
    _ = try measured(b, label: "apply_move", count: count) { try b.applyRemoteChange(moved, peerID: actor) }
    #expect(try b.readBoardItem(itemID)?.board.freeItems.first?.center == WorldPoint(x: 40, y: 60))
    let beforeElement = try a.currentChangeCursor()
    _ = try measured(a, label: "save_element", count: count) {
      try moveTestElement(store:a,source:.init(target:.init(kind:.page,id:pageID),id:element.id,page:element),
        frame:.init(x:50,y:70,width:100,height:100),actor:actor)
    }
    let edit = try #require(a.changeJournal(after: beforeElement).first)
    try stage(edit, from: a, to: b)
    _ = try measured(b, label: "apply_element", count: count) { try b.applyRemoteChange(edit, peerID: actor) }
    #expect(try b.readPageElement(pageID: pageID, elementID: element.id)?.frame.x == 50)
    let accepted = try b.currentChangeCursor()
    _ = try measured(b, label: "repeat", count: count) { try b.applyRemoteChange(edit, peerID: actor) }
    #expect(try b.currentChangeCursor() == accepted)
    let target = CollaborationTarget(kind: .workspace, id: header.rootBoardID)
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let rename = CollaborationAction(summary: "Addressed title", expected: [
      .init(target: target, revision: try a.workspaceHeader().stamp.revision),
      .init(target: board, revision: try a.targetContentRevision(target: board))],
      operations: [.init(kind: .renameItem, target: board, id: itemID.uuidString, values: ["title": .string("Walk")])])
    let beforeRename = try a.currentChangeCursor()
    _ = try measured(a, label: "save_title", count: count) { try a.applyCollaborationAction(rename, actor: actor) }
    let title = try #require(a.changeJournal(after: beforeRename).first)
    try stage(title, from: a, to: b)
    _ = try measured(b, label: "apply_title", count: count) { try b.applyRemoteChange(title, peerID: actor) }
    #expect(try b.readItemHeader(itemID)?.title == "Walk")
  }

  @Test func anElementPacketCannotReadUnrelatedInkOrAnotherElement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = NotebookStore(root: directory.appendingPathComponent("a")), b = NotebookStore(root: directory.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)), pageID = try a.loadIndex().selectedPageID!
    var page = try a.loadPage(pageID)
    let replaced = page.replaceElements(["selected", "foreign"].map { .init(id: $0, kind: .markdown, frame: .init(x: 10, y: 10, width: 100, height: 100), source: $0, html: "") }, actor: actor)
    #expect(replaced)
    try a.savePage(page)
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try a.changeJournal(after: 0) { try stage(change, from: a, to: b); _ = try b.applyRemoteChange(change, peerID: actor) }
    try b.commandTransaction {
      for suffix in ["/elements/@foreign", "/drawingData"] {
        try b.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)", [.blob(Data("must not decode".utf8)), .text(pageFile(pageID) + "#" + suffix)])
      }
    }
    let cursor = try a.currentChangeCursor()
    try moveTestElement(store:a,source:.init(target:.init(kind:.page,id:pageID),id:"selected",page:page.elements[0]),
      frame:.init(x:80,y:80,width:100,height:100),actor:actor)
    let packet = try #require(a.changeJournal(after: cursor).first)
    try stage(packet, from: a, to: b)
    _ = try b.applyRemoteChange(packet, peerID: actor)
    #expect(try b.readPageElement(pageID: pageID, elementID: "selected")?.frame.x == 80)
  }

  @Test(arguments: [false, true])
  func independentAndConflictingPageFieldsUseTheExistingOwner(sameField: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = NotebookStore(root: directory.appendingPathComponent("a")), b = NotebookStore(root: directory.appendingPathComponent("b"))
    let actor = UUID(), other = UUID(), header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let pageID = try a.loadIndex().selectedPageID!
    var base = try a.loadPage(pageID)
    let element = AgentElement(id: "element", kind: .web, frame: .init(x: 10, y: 10, width: 100, height: 100), source: "Base", html: "Base")
    let replaced = base.replaceElements([element], actor: actor)
    #expect(replaced)
    try a.savePage(base)
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try a.changeJournal(after: 0) { try stage(change, from: a, to: b); _ = try b.applyRemoteChange(change, peerID: actor) }
    var left = base, right = base
    let changedLeft = left.replaceElements([element.updating(frame: .init(x: 30, y: 40, width: 100, height: 100))], actor: actor)
    let replacement = sameField ? element.updating(frame: .init(x: 70, y: 80, width: 100, height: 100))
      : AgentElement(id: element.id, kind: .web, frame: element.frame, source: "Remote source", html: "Remote source")
    let changedRight = right.replaceElements([replacement], actor: other)
    #expect(changedLeft && changedRight)
    let expected = try left.merging(right)
    let beforeLeft = try a.currentChangeCursor()
    try a.savePage(left); try b.savePage(right)
    let leftChange = try #require(a.changeJournal(after: beforeLeft).first)
    try stage(leftChange, from: a, to: b); _ = try b.applyRemoteChange(leftChange, peerID: actor)
    for change in try b.changeJournal(after: 0) { try stage(change, from: b, to: a); _ = try a.applyRemoteChange(change, peerID: other) }
    let actual = try a.loadPage(pageID), received = try b.loadPage(pageID)
    #expect(actual.elements == expected.elements && received.elements == expected.elements)
    #expect(actual.collaboration == expected.collaboration && received.collaboration == expected.collaboration)
    #expect(try NotebookStore(root: a.root).loadPage(pageID) == actual)
  }
}
