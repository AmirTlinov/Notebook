import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed page reads", .serialized)
struct NotebookContentReadTests {
  @Test func oneElementAmongOneHundredThousandDoesNotDecodeOtherBodies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-addressed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let file = pageFile(pageID)
    try store.commandTransaction {
      for index in 0..<100_000 {
        let id = "element-\(index)", element = AgentElement(id: id, kind: .markdown,
          frame: .init(x: 0, y: 0, width: 100, height: 100), source: "source-\(index)", html: "<p>\(index)</p>")
        try store.writeFragment(.init(address: file + "#/elements/@" + id, file: file, parent: file + "#",
          collection: "elements", member: id, position: index, value: try .encode(element), collections: []), database: store.currentSQL!)
      }
    }
    try store.commandTransaction {
      // If either a full read or a prefix-after-decoding sneaks back in, it fails.
      try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data("unrequested body".utf8)), .text(file + "#/elements/@element-0")])
    }
    let cursor = try store.currentReadCursor()
    let count = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    count.initialize(to: 0); defer { count.deinitialize(count: 1); count.deallocate() }
    for attempt in 0..<2 {
      count.pointee = 0
      let start = ContinuousClock.now
      let result = try store.readTransaction { _ in
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let count = raw!.assumingMemoryBound(to: Int.self)
          count.pointee += 1; return count.pointee > 20_000 ? 1 : 0
        }, count)
        defer { sqlite3_progress_handler(store.currentSQL!.handle, 0, nil, nil) }
        let header = try store.readContentHeader(target: .init(kind: .page, id: pageID))
        let result = try #require(try store.readPageElementSnapshot(pageID: pageID, elementID: "element-99999"))
        #expect(result.header == header)
        return result
      }
      #expect(result.element.source == "source-99999")
      #expect(count.pointee > 0 && count.pointee < 20_000)
      print("Page addressed read: records=100000 attempt=\(attempt) SQL instructions=\(count.pointee) elapsed=\(start.duration(to: .now)) response_bytes=\(try JSONEncoder().encode(result).count)")
    }
    #expect(try store.currentReadCursor() == cursor)
  }

  @Test func missingElementAndMissingOwnerAreNotTheSame() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-addressed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), pageID = UUID()
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    #expect(try store.readPageElementSnapshot(pageID: pageID, elementID: "missing") == nil)
    #expect(throws: CollaborationError.self) { try store.readPageElementSnapshot(pageID: UUID(), elementID: "missing") }
    #expect(throws: NotebookStorageError.self) { try store.readPageElementSnapshot(pageID: pageID, elementID: "") }
  }
}
