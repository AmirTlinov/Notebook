import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Context replication keeps immutable addresses and causal order")
struct SharedContextReplicationTests {
  private func fixture(_ body: (NotebookStore, NotebookStore, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-replication-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b"))
    let actor = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, peer = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try a.changeJournal(after: 0) { try deliver(change, from: a, to: b, peer: actor) }
    try body(a, b, actor, peer)
  }

  private func stage(_ change: NotebookDurableChange, from a: NotebookStore, to b: NotebookStore) throws {
    while true {
      let missing = try b.missingBlobHashes(for: change)
      if missing.isEmpty { return }
      for hash in missing {
        let count = try a.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < count { data += try a.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try b.stageBlob(data: data, expectedHash: hash)
      }
    }
  }

  private func deliver(_ change: NotebookDurableChange, from a: NotebookStore, to b: NotebookStore, peer: UUID) throws {
    try stage(change, from: a, to: b)
    #expect(try b.applyRemoteChange(change, peerID: peer) == change.sequence)
  }

  private func question(_ a: NotebookStore, _ b: NotebookStore, _ actor: UUID) throws -> SharedContextAppend {
    let first = try a.appendContext(references: [], author: .human, actor: actor, text: "Question")
    try deliver(a.changeJournal(after: 1)[0], from: a, to: b, peer: actor)
    return first
  }

  @Test func oneIncomingEntryAmongAHundredThousandDoesNotReadOrRenumberTheOldHistory() throws {
    try fixture { a, b, actor, peer in
      let first = try question(a, b, actor), file = b.contextFile(first.id), root = b.contextFile(first.id) + "#"
      var corruptedAddress = "", keptAddress = ""
      try b.commandTransaction { () throws -> Void in
        let database = b.currentSQL!
        for index in 1..<100_000 {
          let entry = SharedContextEntry(author: .agent, references: [], replyTo: first.entry.id,
            text: "Old \(index)", stamp: .init(counter: UInt64(index + 1), actor: peer))
          let address = root + "/entries/@" + entry.id.uuidString.lowercased()
          try b.writeFragment(.init(address: address, file: file, parent: root, collection: "entries",
            member: entry.id.uuidString.lowercased(), position: index, value: .encode(entry), collections: []), database: database)
          if index == 50_000 { corruptedAddress = address }
          if index == 75_000 { keptAddress = address }
        }
        let bad = try database.putBlob(Data("unrequested body must not be decoded".utf8))
        try database.run("UPDATE records SET hash=? WHERE address=?", [.text(bad), .text(corruptedAddress)])
      }
      let kept = try b.readTransaction { _ in try b.currentSQL!.rows("SELECT position,hash FROM records WHERE address=?", [.text(keptAddress)]).map { [String($0[0].integer!), $0[1].text!] } }
      let next = try a.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: first.entry.id, text: "New remote reply")
      let change = try a.changeJournal(after: 2)[0]
      try stage(change, from: a, to: b)
      let before = try b.currentChangeCursor()
      try b.commandTransaction { () throws -> Void in
        let database = b.currentSQL!
        sqlite3_progress_handler(database.handle, 100_000, { _ in 1 }, nil)
        defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
        #expect(try b.applyRemoteChange(change, peerID: actor) == change.sequence)
      }
      #expect(try b.currentChangeCursor() == before + 1)
      #expect(try b.sharedContextPage(contextID: first.id, limit: 3).entries.prefix(2) == [first.entry, next.entry])
      #expect(try b.sharedContexts(contextID: first.id).contexts.first?.lastEntry?.stamp.counter == 100_000)
      try b.readTransaction { _ throws -> Void in
        let database = b.currentSQL!
        #expect(try database.rows("SELECT position,hash FROM records WHERE address=?", [.text(keptAddress)]).map { [String($0[0].integer!), $0[1].text!] } == kept)
        #expect(try database.rows("SELECT address FROM change_records WHERE sequence=?", [.integer(Int64(before + 1))]).count == 1)
      }
      #expect(try b.applyRemoteChange(change, peerID: actor) == change.sequence)
      #expect(try b.currentChangeCursor() == before + 1)
      #expect(try b.appendContext(references: [], author: .agent, actor: peer, contextID: first.id,
        replyTo: first.entry.id, text: "After delivery").entry.stamp.counter == 100_001)
    }
  }

  @Test func concurrentEntriesHaveOneCausalOrderWithoutChangingAnExistingOrdinal() throws {
    try fixture { a, b, actor, peer in
      let first = try question(a, b, actor)
      let left = try a.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: first.entry.id, text: "Left")
      let right = try b.appendContext(references: [], author: .human, actor: peer, contextID: first.id, replyTo: first.entry.id, text: "Right")
      let original = try #require(b.changeJournal(after: 0).last)
      let relayed = NotebookDurableChange(sequence: 1, transactionID: original.transactionID, manifestHash: original.manifestHash, byteCount: original.byteCount)
      try deliver(a.changeJournal(after: 2)[0], from: a, to: b, peer: actor)
      try deliver(relayed, from: b, to: a, peer: peer)
      let expected = [first.entry, left.entry, right.entry]
      #expect(try a.sharedContextPage(contextID: first.id).entries == expected)
      #expect(try b.sharedContextPage(contextID: first.id).entries == expected)
      #expect(try a.sharedContexts().contexts.first?.entries == expected)
      #expect(try b.sharedContexts().contexts.first?.entries == expected)
      let page = try b.sharedContextPage(contextID: first.id, limit: 2)
      #expect(try b.sharedContextPage(contextID: first.id, afterEntryID: page.nextEntryID, expectedCursor: page.readCursor).entries == [right.entry])
    }
  }

  @Test func aReplyCanPrecedeItsParentAcrossIncomingAddressPages() throws {
    try fixture { a, b, actor, _ in
      let id = UUID(), file = a.contextFile(id)
      let parent = SharedContextEntry(id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
        author: .human, references: [], text: "Parent sorted after three address pages", stamp: .init(counter: 1, actor: actor))
      var entries = [parent]
      for index in 1...130 {
        entries.append(.init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
          author: .agent, references: [], replyTo: parent.id, text: "Reply \(index)", stamp: .init(counter: UInt64(index + 1), actor: actor)))
      }
      try a.publishRecords(writes: [file: .encode(SharedContext(id: id, entries: entries))])
      let change = try a.changeJournal(after: 1)[0], before = try b.currentChangeCursor()
      try deliver(change, from: a, to: b, peer: actor)
      #expect(try b.currentChangeCursor() == before + 1)
      #expect(try b.sharedContexts().contexts.first?.entries == entries)
      let first = try b.sharedContextPage(contextID: id, limit: 64)
      let second = try b.sharedContextPage(contextID: id, afterEntryID: first.nextEntryID, expectedCursor: first.readCursor, limit: 64)
      let third = try b.sharedContextPage(contextID: id, afterEntryID: second.nextEntryID, expectedCursor: second.readCursor, limit: 64)
      #expect(first.entries + second.entries + third.entries == entries)
      #expect(third.nextEntryID == nil)
    }
  }

  @Test(arguments: ["orphan", "conflict", "removal", "foreignRoot"])
  func invalidPacketRollsBackItsEntriesReceiptAndCursor(kind: String) throws {
    try fixture { a, b, actor, _ in
      let first = try question(a, b, actor), file = a.contextFile(first.id)
      let good = SharedContextEntry(author: .agent, references: [], replyTo: first.entry.id,
        text: "Accepted only if the whole packet is valid", stamp: .init(counter: 2, actor: actor))
      var entries = [first.entry, good]
      if kind == "orphan" { entries.append(.init(author: .agent, references: [], replyTo: UUID(), text: "Orphan", stamp: .init(counter: 3, actor: actor))) }
      if kind == "conflict" { entries[0] = .init(id: first.entry.id, author: .human, references: [], text: "Different immutable content", stamp: first.entry.stamp, createdAt: first.entry.createdAt) }
      if kind == "removal" { entries.removeFirst() }
      try a.publishRecords(writes: [file: .encode(SharedContext(id: kind == "foreignRoot" ? UUID() : first.id, entries: entries))])
      let change = try a.changeJournal(after: 2)[0], before = try b.currentChangeCursor()
      let page = try b.sharedContextPage(contextID: first.id)
      try stage(change, from: a, to: b)
      if kind == "orphan" || kind == "conflict" {
        #expect(throws: CollaborationError.self) { try b.applyRemoteChange(change, peerID: actor) }
      } else {
        #expect(throws: NotebookStorageError.self) { try b.applyRemoteChange(change, peerID: actor) }
      }
      #expect(try b.currentChangeCursor() == before)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == 2)
      #expect(try b.sharedContextPage(contextID: first.id) == page)
      #expect(try b.sharedContextEntry(contextID: first.id, entryID: good.id) == nil)
      #expect(try b.readTransaction { _ in try b.currentSQL!.rows("SELECT 1 FROM received_transactions WHERE transaction_id=?", [.text(change.transactionID.uuidString.lowercased())]).isEmpty })
    }
  }

  @Test func externalIndexPreparationPreservesEveryCanonicalRecordAndRefusesBrokenParentsAtomically() throws {
    try fixture { a, _, actor, _ in
      let first = try a.appendContext(references: [], author: .human, actor: actor, text: "Indexed only outside launch")
      let second = try a.appendContext(references: [], author: .agent, actor: actor, contextID: first.id, replyTo: first.entry.id, text: "Reply")
      let proof = try a.readTransaction { _ in try a.archiveContentProof() }, cursor = try a.currentChangeCursor()
      try a.commandTransaction { try a.currentSQL!.run("DROP TABLE context_entry_order") }
      #expect(throws: NotebookStorageError.unsupportedFormat) { try a.sharedContextPage(contextID: first.id) }
      #expect(throws: NotebookStorageError.unsupportedFormat) { try a.validateArchiveSnapshot() }
      try a.prepareContextOrderIndexForTransfer()
      #expect(try a.readTransaction { _ in try a.archiveContentProof() } == proof)
      #expect(try a.currentChangeCursor() == cursor)
      #expect(try a.sharedContextPage(contextID: first.id).entries == [first.entry, second.entry])
      try a.readTransaction { _ in try a.validateContextOrderIndex() }
      let root = a.contextFile(first.id) + "#"
      let orphan = SharedContextEntry(author: .agent, references: [], replyTo: UUID(), text: "Invalid transfer", stamp: .init(counter: 3, actor: actor))
      try a.commandTransaction {
        _ = try a.writeFragment(.init(address: root + "/entries/@" + orphan.id.uuidString.lowercased(), file: a.contextFile(first.id),
          parent: root, collection: "entries", member: orphan.id.uuidString.lowercased(), position: 89,
          value: .encode(orphan), collections: []), database: a.currentSQL!)
      }
      let before = try a.readTransaction { _ in try a.currentSQL!.rows("SELECT address,context,counter,actor FROM context_entry_order ORDER BY address").map { [$0[0].text!, $0[1].text!, String($0[2].integer!), $0[3].text!] } }
      #expect(throws: CollaborationError.self) { try a.prepareContextOrderIndexForTransfer() }
      #expect(try a.readTransaction { _ in try a.currentSQL!.rows("SELECT address,context,counter,actor FROM context_entry_order ORDER BY address").map { [$0[0].text!, $0[1].text!, String($0[2].integer!), $0[3].text!] } } == before)
    }
  }
}
