import Foundation
import Testing
@testable import NotebookCore

private enum ActionCaptureFault: Error { case injected }

@Suite("Action-scoped raw record evidence", .serialized)
struct NotebookActionRecordCaptureTests {
  private final class Fixture {
    let store: NotebookStore
    let file = "capture-fixture.json"
    var root: String { file + "#" }

    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("action-record-capture-\(UUID())"))
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }

    deinit { try? FileManager.default.removeItem(at: store.root) }

    @discardableResult
    func put(_ value: String, member: String? = nil) throws -> String {
      let address = member.map { root + "/values/@" + $0 } ?? root
      try store.writeFragment(.init(address: address, file: file, parent: member == nil ? nil : root,
        collection: member == nil ? "" : "values", member: member ?? "", position: 0,
        value: .string(value), collections: []), database: store.currentSQL!)
      return try #require(store.currentSQL!.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text)
    }
  }

  @Test func firstBeforeSurvivesRepeatedUpdatesAndDeletion() throws {
    let f = try Fixture(), actionID = UUID()
    try f.store.commandTransaction {
      let database = f.store.currentSQL!, original = try f.put("original")
      try database.withActionRecordCapture(actionID: actionID) {
        try f.put("renamed")
        try f.put("updated again")
        try f.store.removeFragment(f.root, database: database)
      }
      #expect(try database.actionRecordCaptureCount(actionID: actionID) == 1)
      #expect(try database.actionRecordCapturePage(actionID: actionID) == [
        .init(address: f.root, beforeHash: original, afterHash: nil)
      ])
    }
  }

  @Test func sequentialActionsHaveIndependentBeforeAndFrozenAfterInsideOneTransaction() throws {
    let f = try Fixture(), firstID = UUID(), secondID = UUID()
    try f.store.commandTransaction {
      let database = f.store.currentSQL!, original = try f.put("original")
      let first = try database.withActionRecordCapture(actionID: firstID) { try f.put("first action") }
      let second = try database.withActionRecordCapture(actionID: secondID) { try f.put("second action") }
      // Context, receipt and frozen result are written after their content scope.
      try f.put("out of scope publication")
      try f.put("receipt", member: "receipt")
      #expect(try database.actionRecordCapturePage(actionID: firstID) == [
        .init(address: f.root, beforeHash: original, afterHash: first)
      ])
      #expect(try database.actionRecordCapturePage(actionID: secondID) == [
        .init(address: f.root, beforeHash: first, afterHash: second)
      ])
      #expect(try database.actionRecordCaptureCount(actionID: firstID) == 1)
      #expect(try database.actionRecordCaptureCount(actionID: secondID) == 1)
    }
  }

  @Test func localWritesInsideTheContentScopeAreNotCaptured() throws {
    let f = try Fixture(), actionID = UUID()
    try f.store.commandTransaction {
      let database = f.store.currentSQL!
      let shared = try database.withActionRecordCapture(actionID: actionID) {
        let localFile = "local/capture-private.json"
        try f.store.writeFragment(.init(address: localFile + "#", file: localFile, parent: nil,
          collection: "", member: "", position: 0, value: .string("private run data"), collections: []), database: database)
        try f.store.removeFragment(localFile + "#", database: database)
        try f.store.writeFragment(.init(address: localFile + "#", file: localFile, parent: nil,
          collection: "", member: "", position: 0, value: .string("private final result"), collections: []), database: database)
        return try f.put("shared content")
      }
      #expect(try database.actionRecordCaptureCount(actionID: actionID) == 1)
      #expect(try database.actionRecordCapturePage(actionID: actionID) == [
        .init(address: f.root, beforeHash: nil, afterHash: shared)
      ])
    }
  }

  @Test func netZeroCannotResurrectTransientRecords() throws {
    let f = try Fixture(), transientID = UUID(), recreatedID = UUID(), returnedID = UUID()
    try f.store.commandTransaction {
      let database = f.store.currentSQL!
      try database.withActionRecordCapture(actionID: transientID) {
        try f.put("temporary")
        try f.store.removeFragment(f.root, database: database)
      }
      #expect(try database.actionRecordCaptureCount(actionID: transientID) == 0)
      #expect(try database.actionRecordCapturePage(actionID: transientID).isEmpty)
      let final = try database.withActionRecordCapture(actionID: recreatedID) {
        try f.put("another temporary birth")
        try f.store.removeFragment(f.root, database: database)
        return try f.put("final birth")
      }
      #expect(try database.actionRecordCapturePage(actionID: recreatedID) == [
        .init(address: f.root, beforeHash: nil, afterHash: final)
      ])
      try database.withActionRecordCapture(actionID: returnedID) {
        try f.put("temporary change")
        try f.put("final birth")
      }
      #expect(try database.actionRecordCaptureCount(actionID: returnedID) == 0)
      #expect(try database.actionRecordCapturePage(actionID: returnedID).isEmpty)
    }
  }

  @Test func descendantDeletionDrainsBoundedOrderedPagesWithoutBodyReads() throws {
    let f = try Fixture(), actionID = UUID(), members = 193
    try f.store.commandTransaction {
      let database = f.store.currentSQL!
      try f.put("root")
      for offset in (0..<members).reversed() { try f.put("stored body", member: String(format: "%04d", offset)) }
      // Neither capture nor generic addressed removal needs an old JSON body.
      try database.run("UPDATE blobs SET data=? WHERE hash IN (SELECT hash FROM records WHERE file=?)",
        [.blob(Data("must remain unread".utf8)), .text(f.file)])
      try database.withActionRecordCapture(actionID: actionID) { try f.store.removeFragment(f.root, database: database) }
      #expect(try database.actionRecordCaptureCount(actionID: actionID) == members + 1)
      var cursor = "", count = 0
      while true {
        let page = try database.actionRecordCapturePage(actionID: actionID, after: cursor, limit: 17)
        #expect(page.count <= 17)
        guard let last = page.last else { break }
        for row in page {
          #expect(row.address > cursor)
          #expect(row.beforeHash != nil)
          #expect(row.afterHash == nil)
          cursor = row.address
        }
        count += page.count
        #expect(count <= members + 1)
        if count > members + 1 { break }
        cursor = last.address
      }
      #expect(count == members + 1)
      #expect(throws: NotebookStorageError.self) { try database.actionRecordCapturePage(actionID: actionID, limit: 0) }
      #expect(throws: NotebookStorageError.self) { try database.actionRecordCapturePage(actionID: actionID, limit: 16_385) }
    }
  }

  @Test func scopeRejectsNestingAndReuseAndClosesWhenBodyThrows() throws {
    let f = try Fixture(), firstID = UUID(), failedID = UUID(), nextID = UUID()
    try f.store.commandTransaction {
      let database = f.store.currentSQL!
      _ = try database.withActionRecordCapture(actionID: firstID) {
        #expect(throws: NotebookStorageError.self) {
          try database.withActionRecordCapture(actionID: UUID()) { try f.put("must not execute") }
        }
      }
      #expect(throws: NotebookStorageError.self) { try database.withActionRecordCapture(actionID: firstID) {} }
      #expect(throws: ActionCaptureFault.self) {
        try database.withActionRecordCapture(actionID: failedID) { throw ActionCaptureFault.injected }
      }
      let next = try database.withActionRecordCapture(actionID: nextID) { try f.put("next action") }
      #expect(try database.actionRecordCapturePage(actionID: nextID) == [
        .init(address: f.root, beforeHash: nil, afterHash: next)
      ])
    }
    try f.store.readTransaction { store in
      #expect(throws: NotebookStorageError.self) { try store.currentSQL!.withActionRecordCapture(actionID: UUID()) {} }
      let count = try store.currentSQL!.actionRecordCaptureCount(actionID: nextID)
      #expect(count == 0,
        "Capture evidence must not leak to a later connection or durable schema")
    }
  }
}
