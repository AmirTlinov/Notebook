import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Shared history reads and appends only addressed entries")
struct SharedContextReadTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-read-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }

  @Test func appendAndReadAmongAHundredThousandEntriesNeverDecodeAnUnrequestedBody() throws {
    try fixture { store, actor in
      let first = try store.appendContext(references: [], author: .human, actor: actor, text: "Root")
      let root = store.contextFile(first.id) + "#"
      var corrupt = ""
      try store.commandTransaction {
        let database = store.currentSQL!
        for index in 1..<100_000 {
          let entry = SharedContextEntry(author: .agent, references: [], replyTo: first.entry.id, text: "Reply \(index)", stamp: .init(counter: UInt64(index + 1), actor: actor))
          let address = root + "/entries/@" + entry.id.uuidString.lowercased()
          try store.writeFragment(.init(address: address, file: store.contextFile(first.id), parent: root,
            collection: "entries", member: entry.id.uuidString.lowercased(), position: index,
            value: .encode(entry), collections: []), database: database)
          if index == 50_000 { corrupt = address }
        }
        let bad = try database.putBlob(Data("not JSON".utf8))
        try database.run("UPDATE records SET hash=? WHERE address=?", [.text(bad), .text(corrupt)])
      }
      let before = try store.currentChangeCursor()
      let accepted = try store.appendContext(references: [], author: .agent, actor: actor,
        contextID: first.id, replyTo: first.entry.id, text: "Addressed append")
      #expect(accepted.id == first.id)
      #expect(accepted.entry.stamp.counter == 100_001)
      #expect(try store.currentChangeCursor() == before + 1)
      try store.readTransaction { _ throws -> Void in
        let database = store.currentSQL!
        sqlite3_progress_handler(database.handle, 50_000, { _ in 1 }, nil)
        defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
        let page = try store.sharedContextPage(contextID: first.id, limit: 64)
        #expect(page.entries.count == 64)
        #expect(page.entries.first == first.entry)
        #expect(page.nextEntryID == page.entries.last?.id)
        let directory = try store.sharedContexts(contextID: first.id, limit: 1)
        #expect(directory.contexts.first?.firstEntry == first.entry)
        #expect(directory.contexts.first?.lastEntry == accepted.entry)
        let changes = try database.rows("SELECT address FROM change_records WHERE sequence=?", [.integer(Int64(before + 1))])
        #expect(changes.count == 1)
        #expect(changes[0][0].text == root + "/entries/@" + accepted.entry.id.uuidString.lowercased())
      }
    }
  }

  @Test func continuationKeepsOneCutAndRefusesAnUnknownParentWithoutPublication() throws {
    try fixture { store, actor in
      let first = try store.appendContext(references: [], author: .human, actor: actor, text: "Question")
      let second = try store.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: first.entry.id, text: "Reply")
      let page = try store.sharedContextPage(contextID: first.id, limit: 1)
      let next = try store.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID, expectedCursor: page.readCursor, limit: 1)
      #expect(next.entries == [second.entry]); #expect(next.nextEntryID == nil)
      #expect(throws: NotebookStorageError.self) { try store.sharedContextPage(contextID: first.id, afterEntryID: first.entry.id) }
      let cursor = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) {
        try store.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: UUID(), text: "Orphan")
      }
      #expect(try store.currentChangeCursor() == cursor)
      _ = try store.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: second.entry.id, text: "Next")
      #expect(throws: NotebookStorageError.transactionConflict) {
        try store.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID, expectedCursor: page.readCursor)
      }
    }
  }

  @Test func byteBoundReturnsAContinuationInsteadOfPretendingTheHistoryIsComplete() throws {
    try fixture { store, actor in
      let first = try store.appendContext(references: [], author: .human, actor: actor, text: String(repeating: "q", count: 1_048_576))
      for _ in 0..<5 {
        _ = try store.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: first.entry.id, text: String(repeating: "a", count: 1_048_576))
      }
      let page = try store.sharedContextPage(contextID: first.id, limit: 64)
      #expect(page.entries.count == 3)
      #expect(page.nextEntryID != nil)
      let rest = try store.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID, expectedCursor: page.readCursor)
      #expect(rest.entries.count == 3); #expect(rest.nextEntryID == nil)
      let encoded = try JSONValue.encode(page)
      #expect(encoded["readCursor"]?.string == page.readCursor)
      #expect(encoded["format"] == nil)
    }
  }

  @Test func unrelatedWritesAndSelectionDoNotInvalidateHistoryButItsOwnWritesDo() throws {
    try fixture { store, actor in
      let first = try store.appendContext(references: [], author: .human, actor: actor, text: "First")
      let second = try store.appendContext(references: [], author: .agent, actor: actor,
        contextID: first.id, replyTo: first.entry.id, text: "Second")
      let other = try store.appendContext(references: [], author: .human, actor: actor, text: "Other")
      let page = try store.sharedContextPage(contextID: first.id, limit: 1)
      let directory = try store.sharedContexts(contextID: nil, limit: 1)
      try store.selectSharedContext(other.id, actor: actor)
      try store.publishRecords(writes: ["local/history-test.json": .object(["value": .string("unrelated")])])
      #expect(try store.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID,
        expectedCursor: page.readCursor).entries == [second.entry])
      let remaining = try store.sharedContexts(contextID: nil, limit: 1,
        afterContextID: directory.nextContextID, expectedCursor: directory.readCursor)
      #expect(remaining.contexts.first?.id == first.id)
      #expect(remaining.selection?.contextID == other.id)
      _ = try store.appendContext(references: [], author: .agent, actor: actor,
        contextID: other.id, replyTo: other.entry.id, text: "Other reply")
      #expect(try store.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID,
        expectedCursor: page.readCursor).entries == [second.entry])
      #expect(throws: NotebookStorageError.transactionConflict) {
        try store.sharedContexts(contextID: nil, limit: 1, afterContextID: directory.nextContextID, expectedCursor: directory.readCursor)
      }
      try store.publishRecords(writes: [:], removals: [store.contextFile(first.id)])
      #expect(throws: NotebookStorageError.transactionConflict) {
        try store.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID, expectedCursor: page.readCursor)
      }
    }
  }

  @Test func directoryRetainsSelectedPreviewAndPaginatesWithoutLosingOlderContexts() throws {
    try fixture { store, actor in
      let selected = try store.appendContext(references: [], author: .human, actor: actor, text: "Selected", select: true)
      for index in 0..<7 { _ = try store.appendContext(references: [], author: .agent, actor: actor, text: "Context \(index)") }
      let first = try store.sharedContexts(contextID: nil, limit: 3)
      #expect(first.contexts.count == 3)
      #expect(first.selectedContext?.id == selected.id)
      let second = try store.sharedContexts(contextID: nil, limit: 3, afterContextID: first.nextContextID, expectedCursor: first.readCursor)
      let last = try store.sharedContexts(contextID: nil, limit: 3, afterContextID: second.nextContextID, expectedCursor: second.readCursor)
      #expect(last.nextContextID == nil)
      #expect(Set((first.contexts + second.contexts + last.contexts).map(\.id)).count == 8)
      try store.selectSharedContext(nil, actor: actor)
      #expect(try store.sharedContexts(contextID: nil, limit: 3).selectedContext == nil)
      #expect(try store.sharedContextEntry(contextID: selected.id, entryID: selected.entry.id) == selected.entry)
    }
  }
}
