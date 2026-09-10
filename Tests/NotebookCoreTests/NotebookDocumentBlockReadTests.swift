import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("One document block is a bounded source/state snapshot", .serialized)
struct NotebookDocumentBlockReadTests {
  private let blockID = "counter/a~😀"
  private func fixture(_ body: (NotebookStore, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-block-read-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Addressed programs", actor: actor)
    let item = try #require(created)
    let added = board.addItem(item.id, to: header.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: item.id, actor: actor,
      blocks: [.interactive(id: blockID, html: "<button>+</button>", initialState: .number(42)),
        .markdown(id: "unrequested", source: String(repeating: "x", count: 1_000_000))]),
      state: .init(id: item.id, actor: actor), board: board)
    try body(store, actor, item.id)
  }

  @Test func oneReadAmongOneHundredThousandHistoricalStatesNeverDecodesAnUnrequestedBody() throws {
    try fixture { store, actor, id in
      let file = stateFile(id), clock = VersionStamp(counter: 100_000, actor: actor)
      try store.commandTransaction {
        for index in 0..<100_000 {
          let record = DocumentStateRecord(id: "retired-\(index)", value: .number(Double(index)), stamp: clock)
          try store.writeFragment(.init(address: file + "#/records/@" + record.id, file: file, parent: file + "#",
            collection: "records", member: record.id, position: index, value: try .encode(record), collections: []), database: store.currentSQL!)
        }
        let root = try #require(store.storedFragments(address: file + "#", descendants: false).first)
        try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: store.currentSQL!)
      }
      let stamp = VersionStamp(counter: clock.counter + 1, actor: actor)
      _ = try store.commitDocumentState(.init(documentID: id, record: .init(id: blockID, value: .number(7), stamp: stamp,
        fieldVersion: .init(stamp: stamp, human: true)), journalStamp: stamp))
      let kept = try store.storedFragments(address: file + "#/records/@retired-75000")
      try poison(store, addresses: [file + "#/records/@retired-50000", documentFile(id) + "#/blocks/@unrequested"])
      let cursor = try store.currentChangeCursor()
      let count = UnsafeMutablePointer<Int>.allocate(capacity: 1)
      count.initialize(to: 0); defer { count.deinitialize(count: 1); count.deallocate() }
      let read = try store.readTransaction { _ in
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let count = raw!.assumingMemoryBound(to: Int.self)
          count.pointee += 1; return count.pointee > 200_000 ? 1 : 0
        }, count)
        return try store.readDocumentBlock(documentID: id, blockID: blockID)
      }
      #expect(read?.block.id == blockID && read?.state == .number(7))
      #expect(read?.stateStamp == stamp)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.storedFragments(address: file + "#/records/@retired-75000") == kept)
      #expect(count.pointee > 0 && count.pointee < 200_000)
      print("Addressed document block read: foreign_states=100000 SQL instructions=\(count.pointee)")
    }
  }

  @Test func absentStateAndCommittedJSONNullHaveDifferentWireValues() throws {
    try fixture { store, actor, id in
      let absent = try #require(try store.readDocumentBlock(documentID: id, blockID: blockID))
      #expect(absent.state == nil && absent.block.initialState == .number(42))
      #expect(try JSONValue.encode(absent)["state"] == nil)
      var state = try store.loadDocumentState(id)
      let accepted = state.commit(blockID: blockID, value: .null, actor: actor)
      #expect(accepted)
      _ = try store.commitDocumentState(.init(documentID: id, record: #require(state.records.first), journalStamp: state.stamp))
      let committed = try #require(try store.readDocumentBlock(documentID: id, blockID: blockID))
      #expect(committed.state == .some(.null))
      let value = try JSONValue.encode(committed)
      #expect(value["state"] == .null)
      #expect(try value.decode(NotebookDocumentBlockRead.self) == committed)
      #expect(value["format"] == nil && value["records"] == nil && value["blocks"] == nil)
      #expect(try store.readDocumentBlock(documentID: id, blockID: "missing") == nil)
    }
  }

  @Test func UUIDAliasesAndEscapedIDsChooseTheSameExactProgram() throws {
    try fixture { store, actor, id in
      let uuid = UUID().uuidString
      var document = try store.loadDocument(id)
      let changed = document.replaceContent(blocks: [
        .interactive(id: uuid, html: "<p>UUID</p>"),
        .interactive(id: "a", html: "<p>a</p>"),
        .interactive(id: "a!", html: "<p>a!</p>"),
        .interactive(id: "a0", html: "<p>a0</p>"),
        .interactive(id: "a/child", html: "<p>a/child</p>"),
        .interactive(id: "a~child", html: "<p>a~child</p>")], actor: actor)
      #expect(changed)
      _ = try store.saveMergedDocument(document)
      var state = try store.loadDocumentState(id)
      for block in document.blocks {
        let changed = state.commit(blockID: block.id, value: .object(["blocks": .array([
          .object(["id": .string("child"), "source": .string(block.id)])])]), actor: actor)
        #expect(changed)
      }
      try store.saveDocumentState(state)
      for block in document.blocks {
        let read = try #require(try store.readDocumentBlock(documentID: id, blockID: block.id))
        #expect(read.block == block && read.state == state.value(for: block.id))
        #expect(read.contentStamp == document.contentStamp && read.stateStamp == state.stamp)
      }
      #expect(try store.readDocumentBlock(documentID: id, blockID: uuid.lowercased()) == store.readDocumentBlock(documentID: id, blockID: uuid))
    }
  }

  @Test(arguments: ["bytes", "fragments"])
  func budgetRefusesBeforeDecodingAnyBody(kind: String) throws {
    try fixture { store, actor, id in
      var state = try store.loadDocumentState(id)
      let value: JSONValue = kind == "bytes" ? .string(String(repeating: "x", count: 4 * 1_024 * 1_024))
        : .object(["blocks": .array((0..<4_096).map { .object(["id": .string("child-\($0)"), "value": .number(1)]) })])
      let changed = state.commit(blockID: blockID, value: value, actor: actor)
      #expect(changed)
      try store.saveDocumentState(state)
      try poison(store, addresses: [documentFile(id) + "#"])
      let cursor = try store.currentChangeCursor()
      // Decoding that first root would produce DecodingError, not this limit.
      #expect(throws: NotebookStorageError.limitExceeded("document_block_read")) {
        try store.readDocumentBlock(documentID: id, blockID: blockID)
      }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func mismatchedStoredMembershipCannotBecomeAReadReceipt() throws {
    try fixture { store, _, id in
      let address = documentFile(id) + "#/blocks/@" + fieldKey([blockID])
      try store.commandTransaction {
        let record = try #require(store.storedFragments(address: address, descendants: false).first)
        let malformed = NotebookStoredFragment(address: record.address, file: record.file, parent: record.parent,
          collection: "other", member: record.member, position: record.position, value: record.value, collections: record.collections)
        let hash = try store.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(malformed))
        try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
      }
      #expect(throws: NotebookStorageError.self) { try store.readDocumentBlock(documentID: id, blockID: blockID) }
    }
  }

  @Test func aMissingBlobIsCorruptionNotAnAbsentProgram() throws {
    try fixture { store, _, id in
      let address = documentFile(id) + "#/blocks/@" + fieldKey([blockID])
      // Emulate damaged storage outside the transactional writer. Its normal
      // foreign-key enforcement would refuse this invalid mutation.
      let broken = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      try broken.run("PRAGMA foreign_keys=OFF")
      try broken.run("DELETE FROM blobs WHERE hash=(SELECT hash FROM records WHERE address=?)", [.text(address)])
      #expect(throws: NotebookStorageError.corruptRecord(address)) {
        try store.readDocumentBlock(documentID: id, blockID: blockID)
      }
    }
  }

  @Test func dispatcherBoundsTheWholeBlockBatchBeforeLookingUpAnyTarget() throws {
    try fixture { store, _, id in
      let dispatcher = NotebookCommandDispatcher(store: store)
      var request = NotebookCommand(command: .read)
      request.queries = (0..<5).map { _ in .init(kind: .documentBlock, id: UUID()) }
      do { _ = try dispatcher.handle(request); Issue.record("Five block bodies were admitted") }
      catch let error as CollaborationError { #expect(error.code == "resource_limit") }
      var query = NotebookReadQuery(kind: .documentBlock, id: id); query.elementID = blockID
      request.queries = [query]
      let result = try dispatcher.handle(request)
      let read = try #require(result["values"]?.array.first).decode(NotebookDocumentBlockRead.self)
      #expect(read.block.id == blockID && read.state == nil)
      let stamp = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.self) { try store.readDocumentBlock(documentID: id, blockID: String(repeating: "a", count: 121)) }
      #expect(throws: NotebookStorageError.self) { try store.readDocumentBlock(documentID: id, blockID: "") }
      #expect(try store.currentChangeCursor() == stamp)
    }
  }

  private func poison(_ store: NotebookStore, addresses: [String]) throws {
    try store.commandTransaction {
      let hash = try store.currentSQL!.putBlob(Data("must not decode".utf8))
      for address in addresses { try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)]) }
    }
  }
}
