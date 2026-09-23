import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed rendering reuses one idle reader, never a snapshot")
struct NotebookReadSessionTests {
  @Test func repeatedReadsReuseTheHandleAndObserveNewCommits() throws {
    try fixture { store, actor in
      let session = NotebookReadSession(store: store)
      let (first, handle) = try session.read { store in
        (try store.workspaceHeader(), ObjectIdentifier(try #require(store.currentSQL)))
      }
      for _ in 0..<128 {
        try session.read { store throws -> Void in
          #expect(ObjectIdentifier(try #require(store.currentSQL)) == handle)
          #expect(try store.workspaceHeader() == first)
          let nested = try session.read { ObjectIdentifier(try #require($0.currentSQL)) }
          #expect(nested == handle, "Nested addressed reads borrow this cut, not a second transaction")
        }
      }
      var page = try store.loadPage(#require(store.loadIndex().selectedPageID))
      page.replaceDrawing(pageDrawingFixture(Data([7, 8, 9])), actor: actor)
      try store.savePage(page)
      try session.read { store throws -> Void in
        #expect(ObjectIdentifier(try #require(store.currentSQL)) == handle)
        #expect(try store.workspaceHeader().cursor > first.cursor)
        #expect(try store.loadPage(page.id) == page)
        #expect(throws: NotebookStorageError.readOnlyTransaction) { try store.savePage(page) }
      }
      #expect(store.currentSQL == nil)
      let database = try store.prepareDatabase()
      #expect(try database.rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.first?.integer == 0,
        "An idle reader must not hold the previous rendering cut open")
    }
  }

  @Test func readBudgetsAndDecodedContentEndWithTheirSnapshot() throws {
    try fixture { store, _ in
      let session = NotebookReadSession(store: store)
      let prior = try session.read { store in
        let database = try #require(store.currentSQL)
        try database.limitReads(.init(rows: 2, bytes: 16, valueBytes: 8, reason: "one_read"))
        #expect(try database.rows("SELECT 1").first?.first?.integer == 1)
        return (ObjectIdentifier(database), database.inkDecoding)
      }
      for _ in 0..<16 {
        try session.read { store in
          let database = try #require(store.currentSQL)
          #expect(ObjectIdentifier(database) == prior.0)
          #expect(database.inkDecoding !== prior.1)
          #expect(try database.rows("SELECT 2").first?.first?.integer == 2)
        }
      }
      #expect(throws: NotebookStorageError.limitExceeded("refused")) {
        try session.read { store in
          let database = try #require(store.currentSQL)
          try database.limitReads(.init(rows: 0, bytes: 0, valueBytes: 0, reason: "refused"))
          _ = try database.rows("SELECT 1")
        }
      }
      #expect(try session.read { try $0.workspaceHeader() } == store.workspaceHeader())
    }
  }

  @Test func addressedReadCostDoesNotIncludeOpeningAConnectionPerPrimitive() throws {
    try fixture { store, _ in
      let expected = try store.workspaceHeader()
      let freshStart = ContinuousClock.now
      for _ in 0..<128 { #expect(try store.readTransaction { try $0.workspaceHeader() } == expected) }
      let fresh = freshStart.duration(to: .now)
      let reader = NotebookReadSession(store: store), reusedStart = ContinuousClock.now
      for _ in 0..<128 { #expect(try reader.read { try $0.workspaceHeader() } == expected) }
      print("128 addressed header reads: fresh=\(fresh), reused=\(reusedStart.duration(to: .now)); storage-only, not UI latency")
    }
  }

  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }
}
