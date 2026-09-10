import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Replicated document state addresses block history", .serialized)
struct DocumentStateReplicationTests {
  private func fixture(_ body: (NotebookStore, NotebookStore, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-replication-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try deliver(a.changeJournal(after: 0)[0], a, b, actor)
    var index = try a.loadIndex(), tree = try a.loadBoard(items: a.loadIndex().items)
    let created = index.createDocument(title: "State", actor: actor)
    let document = try #require(created)
    let added = tree.addItem(document.id, to: header.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    try a.saveDocumentWorkspaceBundle(index: index,
      document: .init(id: document.id, actor: actor, blocks: [.interactive(id: "body", html: "<button>+</button>")]),
      state: .init(id: document.id, actor: actor), board: tree)
    try deliver(a.changeJournal(after: 1)[0], a, b, actor)
    try body(a, b, actor, document.id)
  }

  private func stage(_ change: NotebookDurableChange, _ a: NotebookStore, _ b: NotebookStore) throws {
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
  private func deliver(_ change: NotebookDurableChange, _ a: NotebookStore, _ b: NotebookStore, _ actor: UUID) throws {
    try stage(change, a, b)
    _ = try b.applyRemoteChange(change, peerID: actor)
  }
  private func addressed(_ store: NotebookStore, _ id: UUID, _ blockID: String) throws -> DocumentStateRecord? {
    try store.storedMember(file: stateFile(id), collection: "records", id: blockID)?.decode(DocumentStateRecord.self)
  }
  private func bounded(_ store: NotebookStore, _ body: () throws -> Void) throws -> Int {
    let count = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    count.initialize(to: 0); defer { count.deinitialize(count: 1); count.deallocate() }
    try store.commandTransaction {
      sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
        let count = raw!.assumingMemoryBound(to: Int.self)
        count.pointee += 1; return count.pointee > 200_000 ? 1 : 0
      }, count)
      try body()
    }
    #expect(count.pointee < 200_000)
    return count.pointee
  }

  @Test func oneBlockAmongOneHundredThousandRetiredStatesDoesNotDecodeOrRenumberThem() throws {
    try fixture { a, b, actor, id in
      let file = stateFile(id), rootAddress = file + "#", clock = VersionStamp(counter: 100_000, actor: actor)
      try b.commandTransaction {
        for index in 0..<100_000 {
          let value = DocumentStateRecord(id: "retired-\(index)", value: .number(Double(index)), stamp: clock)
          try b.writeFragment(.init(address: rootAddress + "/records/@" + value.id, file: file,
            parent: rootAddress, collection: "records", member: value.id, position: index,
            value: try .encode(value), collections: []), database: b.currentSQL!)
        }
        let root = try #require(b.storedFragments(address: rootAddress, descendants: false).first)
        try b.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: b.currentSQL!)
      }
      let kept = try b.storedFragments(address: rootAddress + "/records/@retired-75000")
      try b.commandTransaction {
        let hash = try b.currentSQL!.putBlob(Data("unrequested program and state must not be decoded".utf8))
        for address in [rootAddress + "/records/@retired-50000", documentFile(id) + "#/blocks/@body"] {
          try b.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
        }
      }
      let block = "counter/a~😀", cursor = try b.currentChangeCursor()
      var state = try a.loadDocumentState(id)
      let changed = state.commit(blockID: block, value: .number(1), actor: actor)
      #expect(changed)
      try a.saveDocumentState(state)
      let first = try #require(a.changeJournal(after: 2).first)
      try stage(first, a, b)
      let appendWork = try bounded(b) { _ = try b.applyRemoteChange(first, peerID: actor) }
      #expect(try addressed(b, id, block)?.value == .number(1))
      let edited = state.commit(blockID: block, value: .number(3), actor: actor)
      #expect(edited)
      try a.saveDocumentState(state)
      let second = try #require(a.changeJournal(after: first.sequence).first)
      try stage(second, a, b)
      let editWork = try bounded(b) { _ = try b.applyRemoteChange(second, peerID: actor) }
      let retryWork = try bounded(b) { _ = try b.applyRemoteChange(second, peerID: actor) }
      #expect(try addressed(b, id, block)?.value == .number(3))
      #expect(try b.storedFragments(address: rootAddress + "/records/@retired-75000") == kept)
      #expect(try b.currentChangeCursor() == cursor + 2)
      let changes = try b.readChangedAddresses(after: cursor, through: b.currentChangeCursor()).addresses
      #expect(Set(changes) == [rootAddress, rootAddress + "/records/@" + fieldKey([block])])
      let root = try #require(b.storedFragments(address: rootAddress, descendants: false).first)
      #expect(try root.value["stamp"]?.decode(VersionStamp.self).counter == 100_002)
      print("Document state replication SQL instructions: append=\(appendWork), edit=\(editWork), retry=\(retryWork)")
    }
  }

  @Test func prefixLikeBlockIDsAndNestedProgramCollectionsHaveOneCanonicalOrder() throws {
    try fixture { a, b, actor, id in
      var state = try a.loadDocumentState(id)
      let ids = ["a0", "a!", "a", "a/child", "a~child", "Z", "А"] + (0..<129).map { "program-\($0)" }
      for block in ids {
        let value: JSONValue = .object(["blocks": .array([.object(["id": .string("nested"), "source": .string(block)])])])
        let changed = state.commit(blockID: block, value: value, actor: actor)
        #expect(changed)
      }
      try a.saveDocumentState(state)
      let first = try #require(a.changeJournal(after: 2).first)
      try deliver(first, a, b, actor)
      #expect(try a.loadDocumentState(id) == b.loadDocumentState(id))
      #expect(try b.loadDocumentState(id).records.map(\.id) == ids.sorted())
      let kept = try b.storedFragments(address: stateFile(id) + "#/records/@a!")
      let replaced = state.commit(blockID: "a", value: .object(["counter": .number(9)]), actor: actor)
      #expect(replaced)
      try a.saveDocumentState(state)
      try deliver(a.changeJournal(after: first.sequence)[0], a, b, actor)
      #expect(try a.loadDocumentState(id) == b.loadDocumentState(id))
      #expect(try b.storedFragments(address: stateFile(id) + "#/records/@a!") == kept)
      #expect(try b.storedFragments(address: stateFile(id) + "#/records/@a").count == 1)
    }
  }

  @Test func causalHumanContinuationWinsAndAnOldEnvelopeCannotRewindIt() throws {
    try fixture { a, b, actor, id in
      var source = try a.loadDocumentState(id)
      let changed = source.commit(blockID: "body", value: .number(1), actor: actor)
      #expect(changed)
      try a.saveDocumentState(source)
      let first = try #require(a.changeJournal(after: 2).first)
      try deliver(first, a, b, actor)
      var human = try b.loadDocumentState(id)
      let continued = human.commit(blockID: "body", value: .number(7), actor: UUID())
      #expect(continued)
      try b.saveDocumentState(human)
      let kept = try b.storedFragments(address: stateFile(id) + "#"), before = try b.currentChangeCursor()
      let original = try a.commandTransaction { try JSONDecoder().decode(NotebookChangeManifest.self, from: a.currentSQL!.blob(first.manifestHash)) }
      let echo = try b.commandTransaction {
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: original.workspaceID, records: original.records)
        let bytes = try NotebookStore.storageEncoder.encode(manifest)
        return NotebookDurableChange(sequence: first.sequence + 1, transactionID: manifest.transactionID,
          manifestHash: try b.currentSQL!.putBlob(bytes), byteCount: bytes.count)
      }
      _ = try b.applyRemoteChange(echo, peerID: actor)
      #expect(try b.loadDocumentState(id) == human)
      #expect(try b.storedFragments(address: stateFile(id) + "#") == kept)
      #expect(try b.currentChangeCursor() == before)
    }
  }

  @Test func aDelayedStateDoesNotRecreateItsDeletedDocument() throws {
    try fixture { a, b, actor, id in
      _ = try b.deleteWorkspaceItem(itemID: id, actor: UUID())
      var source = try a.loadDocumentState(id)
      let changed = source.commit(blockID: "body", value: .number(1), actor: actor)
      #expect(changed)
      try a.saveDocumentState(source)
      try deliver(a.changeJournal(after: 2)[0], a, b, actor)
      #expect(try b.readItemHeader(id) == nil)
      #expect(try b.hasStoredValue(stateFile(id)) == false)
      #expect(try b.hasStoredValue(documentFile(id)) == false)
    }
  }

  @Test(arguments: ["owner", "collection", "orphan", "remove-root", "causal-version"])
  func malformedStateCannotPublishItsOtherValidBlocks(kind: String) throws {
    try fixture { a, b, actor, id in
      var source = try a.loadDocumentState(id)
      for block in ["a", "zz"] {
        let changed = source.commit(blockID: block, value: .number(1), actor: actor)
        #expect(changed)
      }
      try a.saveDocumentState(source)
      let file = stateFile(id), before = try b.currentChangeCursor(), oldState = try b.loadDocumentState(id)
      let manifest = try b.commandTransaction {
        var fragments = try NotebookRecordCodec.encode(.encode(source), file: file)
        let index = try #require(fragments.firstIndex { $0.member == "zz" })
        let value = fragments[index]
        if kind == "owner" {
          fragments[index] = value.replacing(value: value.value.setting("id", .string("a")))
        }
        if kind == "causal-version" {
          let version = ContentFieldVersion(stamp: .init(counter: 3, actor: actor), human: true)
          fragments[index] = value.replacing(value: value.value.setting("fieldVersion", try .encode(version)))
        }
        if kind == "collection" {
          fragments[index] = .init(address: value.address, file: value.file, parent: value.parent,
            collection: "blocks", member: value.member, position: value.position, value: value.value, collections: value.collections)
        }
        if kind == "orphan" {
          fragments.append(.init(address: value.address + "/unowned", file: file, parent: value.address,
            collection: "unowned", member: "", position: 0, value: .number(7), collections: []))
        }
        let records = try fragments.map { row -> NotebookRecordMutation in
          .init(address: row.address, blobHash: kind == "remove-root" && row.parent == nil ? nil
            : try b.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(row)))
        }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: try a.workspaceHeader().workspaceID, records: records)
        let data = try NotebookStore.storageEncoder.encode(manifest)
        return NotebookDurableChange(sequence: 3, transactionID: manifest.transactionID,
          manifestHash: try b.currentSQL!.putBlob(data), byteCount: data.count)
      }
      #expect(throws: NotebookStorageError.self) { try b.applyRemoteChange(manifest, peerID: actor) }
      #expect(try b.loadDocumentState(id) == oldState)
      #expect(try b.currentChangeCursor() == before)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == 2)
    }
  }

  private enum Fault: Error { case injected }
  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func publicationReceiptAndPeerCursorRecoverTogether(fault: NotebookStorageFault) throws {
    try fixture { a, b, actor, id in
      var source = try a.loadDocumentState(id)
      let changed = source.commit(blockID: "body", value: .number(1), actor: actor)
      #expect(changed)
      try a.saveDocumentState(source)
      let packet = try #require(a.changeJournal(after: 2).first)
      try stage(packet, a, b)
      let cursor = try b.currentChangeCursor(), before = try b.loadDocumentState(id)
      let failing = NotebookStore(root: b.root) { point in
        if String(describing: point) == String(describing: fault) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.applyRemoteChange(packet, peerID: actor) }
      if String(describing: fault) != String(describing: NotebookStorageFault.afterCommit) {
        #expect(try b.loadDocumentState(id) == before)
        #expect(try b.currentChangeCursor() == cursor)
        #expect(try b.peerCursor(peerID: actor, direction: .incoming) == 2)
      }
      _ = try b.applyRemoteChange(packet, peerID: actor)
      #expect(try b.loadDocumentState(id) == source)
      #expect(try b.currentChangeCursor() == cursor + 1)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == packet.sequence)
    }
  }
}
