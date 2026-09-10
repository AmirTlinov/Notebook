import Foundation
import Testing
@testable import NotebookCore

@Suite("Delivery accumulation belongs to the bounded SQL transaction")
struct NotebookPendingChangesTests {
  private enum Failure: Error { case injected }

  @Test func aHundredThousandChangesArePagedAndPublishOrderedParts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-changes-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    try store.commandTransaction {
      let database = store.currentSQL!
      for index in 0..<100_000 {
        let address = String(format: "synthetic/%06d.json#", index)
        try database.recordChange(.init(address: address, blobHash: nil))
      }
      #expect(database.pendingChangeCount == 100_000)
      #expect(try database.rows("PRAGMA temp_store").first?[0].integer == 1)
      #expect(try database.rows("PRAGMA temp.cache_size").first?[0].integer == -2048)
      #expect(try database.changePage().count == 64)
      #expect(try database.changePage(after: "synthetic/099997.json#").map(\.address) == ["synthetic/099998.json#", "synthetic/099999.json#"])
      #expect(throws: NotebookStorageError.self) { try database.changePage(limit: 16_385) }
    }
    try store.readTransaction { _ throws -> Void in
      let database = store.currentSQL!
      #expect(database.pendingChangeCount == 0)
      #expect(try database.rows("SELECT name FROM sqlite_temp_master WHERE type='table'").isEmpty)
      let rootHash = try #require(database.rows("SELECT manifest_hash FROM change_log").first?[0].text)
      let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: database.blob(rootHash))
      #expect(manifest.records.isEmpty)
      #expect(manifest.parts.count == 7)
      var total = 0, previous = ""
      for hash in manifest.parts {
        let part = try JSONDecoder().decode(NotebookChangeManifest.self, from: database.blob(hash))
        #expect(part.records.count <= 16_384)
        #expect(part.transactionID == manifest.transactionID)
        for record in part.records {
          #expect(record.address > previous); previous = record.address; total += 1
        }
      }
      #expect(total == 100_000)
      #expect(try database.rows("SELECT count(*) FROM change_records").first?[0].integer == 100_000)
    }
  }

  @Test func repeatedWritesPublishOnlyTheFinalMutationAndRollbackLosesItsWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-change-final-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    #expect(throws: Failure.self) {
      try store.commandTransaction {
        let database = store.currentSQL!
        try database.recordChange(.init(address: "discard.json#", blobHash: nil))
        throw Failure.injected
      }
    }
    #expect(try store.currentChangeCursor() == 0)
    try store.commandTransaction {
      let database = store.currentSQL!
      #expect(database.pendingChangeCount == 0)
      try database.recordChange(.init(address: "retained.json#", blobHash: String(repeating: "1", count: 64)))
      try database.recordChange(.init(address: "retained.json#", blobHash: nil))
      #expect(database.pendingChangeCount == 1)
      #expect(try database.hasChange("retained.json#"))
      #expect(try !database.hasChange("discard.json#"))
      #expect(try database.changePage().first?.blobHash == nil)
    }
    #expect(try store.currentChangeCursor() == 1)
    #expect(try store.sqlRead { try $0.rows("SELECT address FROM change_records").first?[0].text } == "retained.json#")
  }

  @Test func dependencyWorkIsPagedDeduplicatedAndRetainsItsFirstSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-owners-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    try store.commandTransaction {
      let database = store.currentSQL!
      for index in 0..<100_000 {
        try database.noteOwner(.capturedPageOrder, String(format: "%06d", index), value: "first")
      }
      #expect(try !database.noteOwner(.capturedPageOrder, "000000", value: "later"))
      #expect(try database.ownerValue(.capturedPageOrder, "000000") == "first")
      var count = 0, previous = ""
      try database.visitOwners(.capturedPageOrder) { key in
        #expect(key > previous); count += 1; previous = key
      }
      #expect(count == 100_000)
      try database.noteOwner(.referencePending, "parent")
      #expect(try database.takeOwner(.referencePending) == "parent")
      try database.noteOwner(.referencePending, "parent")
      #expect(try database.takeOwner(.referencePending) == "parent")
      #expect(try database.takeOwner(.referencePending) == nil)
      #expect(try database.rows("PRAGMA temp.cache_size").first?[0].integer == -2048)
    }
    try store.readTransaction { _ throws -> Void in
      #expect(try !store.currentSQL!.hasOwner(.capturedPageOrder))
      #expect(try store.currentSQL!.rows("SELECT name FROM sqlite_temp_master WHERE type='table'").isEmpty)
    }
  }
}
