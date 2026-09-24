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

  @Test func repeatedFragmentReadsStillPayTheReadAllowanceAndReleaseTheirEnvelopes() throws {
    try fixture { store, _ in
      let reader = NotebookReadSession(store: store)
      let database = try reader.read { store in
        let database = try #require(store.currentSQL)
        try database.limitReads(.init(rows: 2, bytes: 1_048_576, valueBytes: 524_288, reason: "fragment_reads"))
        let first = try store.storedFragments(address: "workspace.json#", descendants: false)
        #expect(try store.storedFragments(address: "workspace.json#", descendants: false) == first)
        #expect(database.decodedFragmentCount == 1)
        return database
      }
      #expect(database.decodedFragmentCount == 0 && database.decodedFragmentBytes == 0)
      #expect(throws: NotebookStorageError.limitExceeded("fragment_reads")) {
        try reader.read { store in
          try store.currentSQL!.limitReads(.init(rows: 1, bytes: 1_048_576, valueBytes: 524_288, reason: "fragment_reads"))
          _ = try store.storedFragments(address: "workspace.json#", descendants: false)
          _ = try store.storedFragments(address: "workspace.json#", descendants: false)
        }
      }
      #expect(database.decodedFragmentCount == 0 && database.decodedFragmentBytes == 0,
        "Failed reads release both the snapshot and parsed source envelopes")
    }
  }

  @Test func aHundredThousandDistinctEnvelopesCannotGrowTheReadCache() throws {
    try fixture { store, _ in
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: false)
      let start = ContinuousClock.now
      for index in 0..<100_000 {
        let fragment = NotebookStoredFragment(address: "local/\(index).json#", file: "local/\(index).json", parent: nil,
          collection: "", member: "", position: 0, value: .string("source-\(index)"), collections: [])
        let data = try NotebookStore.storageEncoder.encode(fragment)
        #expect(try database.decodeFragmentEnvelope(data) == fragment)
      }
      #expect(database.decodedFragmentCount == 128)
      #expect(database.decodedFragmentBytes <= 524_288)
      print("100000 distinct envelopes: \(start.duration(to: .now)); retained=\(database.decodedFragmentCount)/\(database.decodedFragmentBytes) bytes")
      let large = NotebookStoredFragment(address: "local/large.json#", file: "local/large.json", parent: nil,
        collection: "", member: "", position: 0, value: .string(String(repeating: "x", count: 524_288)), collections: [])
      let reader = try NotebookSQLConnection(url: store.databaseURL, writable: false)
      #expect(try reader.decodeFragmentEnvelope(NotebookStore.storageEncoder.encode(large)) == large)
      #expect(reader.decodedFragmentCount == 0 && reader.decodedFragmentBytes == 0)
      let partial = large.replacing(value: .string(String(repeating: "x", count: 300_000)))
      let partialBytes = try NotebookStore.storageEncoder.encode(partial)
      #expect(try reader.decodeFragmentEnvelope(partialBytes) == partial)
      let other = partial.replacing(value: .string(String(repeating: "y", count: 300_000)))
      #expect(try reader.decodeFragmentEnvelope(NotebookStore.storageEncoder.encode(other)) == other)
      #expect(reader.decodedFragmentCount == 1 && reader.decodedFragmentBytes == partialBytes.count)
      let writer = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      _ = try writer.decodeFragmentEnvelope(partialBytes)
      #expect(writer.decodedFragmentCount == 0)
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
