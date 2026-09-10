import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Document delivery merges addressed programs and causal fields", .serialized)
struct DocumentSourceReplicationTests {
  private let selected = "counter/a~😀"

  private func fixture(_ body: (NotebookStore, NotebookStore, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-replication-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try deliver(a.changeJournal(after: 0)[0], a, b, actor)
    var index = try a.loadIndex(), tree = try a.loadBoard(items: a.loadIndex().items)
    let created = index.createDocument(title: "Source", actor: actor)
    let item = try #require(created)
    let placed = tree.addItem(item.id, to: header.rootBoardID, near: .zero, actor: actor)
    #expect(placed)
    try a.saveDocumentWorkspaceBundle(index: index,
      document: .init(id: item.id, actor: actor, blocks: [
        .interactive(id: selected, html: "<button>Before</button>", css: "button{color:black}", initialState: .number(3)),
        .markdown(id: "foreign", source: String(repeating: "z", count: 1_000_000)),
        .markdown(id: selected + "/child", source: "Sibling, not a subtree")]),
      state: .init(id: item.id, actor: actor), board: tree)
    try deliver(a.changeJournal(after: 1)[0], a, b, actor)
    #expect(try a.loadDocument(item.id) == b.loadDocument(item.id))
    try body(a, b, actor, item.id)
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
  private func deliver(_ change: NotebookDurableChange, _ a: NotebookStore, _ b: NotebookStore, _ peer: UUID) throws {
    try stage(change, a, b); _ = try b.applyRemoteChange(change, peerID: peer)
  }
  private func block(_ store: NotebookStore, _ id: UUID, _ blockID: String) throws -> DocumentBlock? {
    try store.storedMember(file: documentFile(id), collection: "blocks", id: blockID)?.decode(DocumentBlock.self)
  }
  private func changedSource(_ store: NotebookStore, _ id: UUID, actor: UUID, source: String) throws -> NotebookDurableChange {
    var document = try store.loadDocument(id)
    let changed = document.replaceBlockSource(id: selected, source: source, actor: actor)
    #expect(changed)
    let cursor = try store.currentChangeCursor()
    try store.saveMergedDocument(document)
    return try #require(store.changeJournal(after: cursor).first)
  }
  private final class Counter { var steps = 0 }
  private func bounded(_ store: NotebookStore, _ operation: () throws -> Void) throws -> Int {
    let counter = Counter()
    try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let counter = Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue()
          counter.steps += 1; return counter.steps > 200_000 ? 1 : 0
        }, Unmanaged.passUnretained(counter).toOpaque())
        try operation()
      }
    }
    #expect(counter.steps > 0 && counter.steps < 200_000)
    return counter.steps
  }

  @Test func oneProgramDoesNotDecodeRetiredFieldsOrAnotherProgram() throws {
    try fixture { a, b, actor, id in
      let file = documentFile(id), root = file + "#", historyActor = UUID()
      let clock = VersionStamp(counter: 100_000, actor: historyActor)
      try b.commandTransaction {
        for index in 0..<99_000 {
          let key = "retired-\(index)"
          try b.writeFragment(.init(address: root + "/collaboration/fields/@" + key, file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(ContentFieldVersion(stamp: clock, human: true)), collections: []), database: b.currentSQL!)
        }
        let header = try #require(b.storedFragments(address: root, descendants: false).first)
        try b.writeFragment(header.replacing(value: header.value.setting("contentStamp", try .encode(clock))), database: b.currentSQL!)
      }
      let untouched = [root + "/blocks/@foreign", root + "/blocks/@" + fieldKey([selected + "/child"]), root + "/collaboration/fields/@retired-70000"]
      let beforeRows = try untouched.flatMap { try b.storedFragments(address: $0) }
      try b.commandTransaction {
        let invalid = try b.currentSQL!.putBlob(Data("an unrelated body must not be read".utf8))
        for address in [root + "/blocks/@foreign", root + "/collaboration/fields/@retired-50000"] {
          try b.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(invalid), .text(address)])
        }
      }
      let cursor = try b.currentChangeCursor()
      let packet = try changedSource(a, id, actor: actor, source: "<button>After</button>")
      try stage(packet, a, b)
      let applyWork = try bounded(b) { _ = try b.applyRemoteChange(packet, peerID: actor) }
      let retryWork = try bounded(b) { _ = try b.applyRemoteChange(packet, peerID: actor) }
      #expect(try block(b, id, selected)?.html == "<button>After</button>")
      #expect(try b.currentChangeCursor() == cursor + 1)
      let retained = try untouched.dropFirst().flatMap { try b.storedFragments(address: $0) }
      #expect(retained == beforeRows.filter { $0.address != root + "/blocks/@foreign" })
      let changes = try b.readChangedAddresses(after: cursor, through: b.currentChangeCursor()).addresses
      #expect(!changes.contains { $0.contains("retired-") || $0 == root + "/blocks/@foreign" || $0 == root + "/blocks/@" + fieldKey([selected + "/child"]) })
      #expect(try b.storedFragments(address: root, descendants: false).first?.value["contentStamp"]?.decode(VersionStamp.self).counter == 100_001)
      print("DOCUMENT_SOURCE_REPLICATION foreign_fields=99000 apply=\(applyWork) retry=\(retryWork)")
      // A partial read is not permission to exceed the entire document's
      // causal-field limit when an old implicit field becomes explicit.
      try b.commandTransaction {
        let database = b.currentSQL!
        let implicit = root + "/collaboration/fields/@" + fieldKey([fieldKey(["blocks", selected, "css"])])
        try database.run("DELETE FROM records WHERE address=?", [.text(implicit)])
        let count = Int(try database.rows("SELECT count(*) FROM records WHERE parent=? AND collection='collaboration/fields'", [.text(root)]).first![0].integer!)
        for index in count..<CollaborativeContent.maximumFieldCount {
          let key = "capacity-\(index)"
          try b.writeFragment(.init(address: root + "/collaboration/fields/@" + key, file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(ContentFieldVersion(stamp: clock, human: true)), collections: []), database: database)
        }
      }
      let nextPacket = try changedSource(a, id, actor: actor, source: "<button>Over capacity</button>")
      try stage(nextPacket, a, b)
      let beforeFailure = try b.currentChangeCursor(), savedBlock = try block(b, id, selected)
      #expect(throws: NotebookStorageError.limitExceeded("document_causal_fields")) {
        try b.applyRemoteChange(nextPacket, peerID: actor)
      }
      #expect(try block(b, id, selected) == savedBlock)
      #expect(try b.currentChangeCursor() == beforeFailure)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == packet.sequence)
    }
  }

  @Test func independentSourceStyleAndReorderUseTheSameCausalOwner() throws {
    try fixture { a, b, actor, id in
      let localActor = UUID(), original = try a.loadDocument(id)
      var local = original
      let program = original.blocks[0]
      let styled = DocumentBlock.interactive(id: selected, html: program.html, css: "button{color:red}", initialState: program.initialState)
      let changedLocal = local.replaceContent(blocks: [original.blocks[2], styled, original.blocks[1]], actor: localActor)
      #expect(changedLocal)
      try b.saveMergedDocument(local)
      let packet = try changedSource(a, id, actor: actor, source: "<button>Remote</button>")
      let remote = try a.loadDocument(id)
      var expected = remote; _ = expected.merge(local)
      try deliver(packet, a, b, actor)
      let received = try b.loadDocument(id)
      #expect(received.blocks == expected.blocks)
      #expect(received.preamble == expected.preamble)
      #expect(received.contentStamp == expected.contentStamp)
      #expect(received.blocks.first { $0.id == selected }?.css == "button{color:red}")
      #expect(received.blocks.first { $0.id == selected }?.html == "<button>Remote</button>")
      let cursor = try b.currentChangeCursor()
      _ = try b.applyRemoteChange(packet, peerID: actor)
      #expect(try b.currentChangeCursor() == cursor)
    }
  }

  @Test func membershipAndOrderCrossAddressWindowsWithoutRecreatingProgramState() throws {
    try fixture { a, b, actor, id in
      let ids = ["a0", "a!", "a", "a/child", "a~child", UUID().uuidString, "А"] + (0..<130).map { "block-\($0)" }
      var document = try a.loadDocument(id)
      let source = ids.map { DocumentBlock.interactive(id: $0, html: "<p>\($0)</p>", initialState: .object([
        "records": .array([.object(["id": .string("nested"), "value": .number(1)])])])) }
      let insertedPrograms = document.replaceContent(preamble: "Shared preamble", blocks: source, actor: actor)
      #expect(insertedPrograms)
      var cursor = try a.currentChangeCursor()
      try a.saveMergedDocument(document)
      try deliver(a.changeJournal(after: cursor)[0], a, b, actor)
      #expect(try b.loadDocument(id).blocks == source)
      #expect(try b.loadDocument(id).preamble == "Shared preamble")
      #expect(try b.loadDocumentState(id).records.isEmpty)
      let reordered = Array(source.reversed().dropFirst(3))
      let changedOrder = document.replaceContent(blocks: reordered, actor: actor)
      #expect(changedOrder)
      cursor = try a.currentChangeCursor(); try a.saveMergedDocument(document)
      try deliver(a.changeJournal(after: cursor)[0], a, b, actor)
      #expect(try b.loadDocument(id).blocks == reordered)
      #expect(try b.loadDocumentState(id).records.isEmpty)
    }
  }

  @Test func concurrentHumanAdoptionProtectsARemotelyRemovedProgram() throws {
    try fixture { a, b, actor, id in
      var removed = try a.loadDocument(id), adopted = removed
      let removedProgram = removed.replaceContent(blocks: Array(removed.blocks.dropFirst()), actor: actor)
      #expect(removedProgram)
      let adoptedProgram = adopted.replaceBlockSource(id: selected, source: "<button>Human</button>", actor: UUID())
      #expect(adoptedProgram)
      try b.saveMergedDocument(adopted)
      let cursor = try a.currentChangeCursor(); try a.saveMergedDocument(removed)
      var expected = try a.loadDocument(id); _ = expected.merge(adopted)
      try deliver(a.changeJournal(after: cursor)[0], a, b, actor)
      #expect(try b.loadDocument(id).blocks == expected.blocks)
      #expect(try b.loadDocument(id).collaboration?.fields == expected.collaboration?.fields)
    }
  }

  @Test(arguments: [true, false])
  func nestedInitialStateIsOneAuthoredValueNotAHybridOfTwoPeers(remoteWins: Bool) throws {
    try fixture { a, b, peer, id in
      func state(_ first: Int, _ second: Int, extra: Bool = false) -> JSONValue {
        var records: [JSONValue] = [.object(["id": .string("a"), "value": .number(Double(first))]),
          .object(["id": .string("b"), "value": .number(Double(second))])]
        if extra { records.append(.object(["id": .string("only-local"), "value": .number(9)])) }
        return .object(["records": .array(records), "collaboration": .object(["fields": .object(["ordinary": .string("program data")])])])
      }
      func replacing(_ document: DocumentDocument, _ value: JSONValue, actor: UUID) -> DocumentDocument {
        var document = document, blocks = document.blocks
        let original = blocks[0]
        blocks[0] = .interactive(id: original.id, html: original.html, css: original.css, initialState: value)
        let changed = document.replaceContent(blocks: blocks, actor: actor)
        #expect(changed)
        return document
      }
      var cursor = try a.currentChangeCursor()
      try a.saveMergedDocument(replacing(a.loadDocument(id), state(0, 0), actor: peer))
      try deliver(a.changeJournal(after: cursor)[0], a, b, peer)
      let high = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFE")!
      let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
      let remote = try replacing(a.loadDocument(id), state(1, 0), actor: remoteWins ? high : low)
      let local = try replacing(b.loadDocument(id), state(0, 2, extra: true), actor: remoteWins ? low : high)
      try b.saveMergedDocument(local)
      cursor = try a.currentChangeCursor(); try a.saveMergedDocument(remote)
      let packet = try #require(a.changeJournal(after: cursor).first)
      var expected = remote; _ = expected.merge(local)
      try deliver(packet, a, b, peer)
      let received = try b.loadDocument(id)
      #expect(received.blocks == expected.blocks)
      #expect(received.blocks[0].initialState == (remoteWins ? state(1, 0) : state(0, 2, extra: true)))
      #expect(try b.loadDocumentState(id).records.isEmpty)
    }
  }

  @Test func anOrderVersionCarriesAllAuthoredSlotsEvenWhenOneSlotDidNotChangeAtTheSender() throws {
    try fixture { a, b, peer, id in
      let original = try a.loadDocument(id)
      var remote = original, local = original
      let remoteOrder = remote.replaceContent(blocks: [original.blocks[1], original.blocks[0], original.blocks[2]],
        actor: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFE")!)
      #expect(remoteOrder)
      let localOrder = local.replaceContent(blocks: [original.blocks[2], original.blocks[1], original.blocks[0]],
        actor: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
      #expect(localOrder)
      try b.saveMergedDocument(local)
      let cursor = try a.currentChangeCursor(); try a.saveMergedDocument(remote)
      let packet = try #require(a.changeJournal(after: cursor).first)
      try deliver(packet, a, b, peer)
      #expect(try b.loadDocument(id).blocks == remote.blocks)
    }
  }

  @Test(arguments: ["root", "owner", "collection", "orphan", "causal", "causal-removal"])
  func malformedSourceRollsBackEarlierHeaderAndPrograms(kind: String) throws {
    try fixture { a, b, actor, id in
      var source = try a.loadDocument(id)
      let changed = source.replaceContent(preamble: "Unpublished", actor: actor)
      #expect(changed)
      let file = documentFile(id), before = try b.loadDocument(id), cursor = try b.currentChangeCursor()
      let packet = try b.commandTransaction {
        var rows = try NotebookRecordCodec.encode(.encode(source), file: file)
        let matchingBlock = rows.firstIndex { $0.collection == "blocks" && $0.member == selected }
        let index = try #require(matchingBlock)
        let row = rows[index]
        if kind == "owner" { rows[index] = row.replacing(value: row.value.setting("id", .string("wrong"))) }
        if kind == "collection" { rows[index] = .init(address: row.address, file: file, parent: row.parent, collection: "records", member: row.member, position: row.position, value: row.value, collections: row.collections) }
        if kind == "orphan" { rows.append(.init(address: row.address + "/unowned", file: file, parent: row.address, collection: "unowned", member: "", position: 0, value: .number(7), collections: [])) }
        if kind == "causal", let field = rows.firstIndex(where: { $0.member == "blocks/order" }) {
          rows[field] = rows[field].replacing(value: .object([:]))
        }
        let records = try rows.map { row -> NotebookRecordMutation in
          let removes = (kind == "root" && row.parent == nil) || (kind == "causal-removal" && row.member == "blocks/order")
          return .init(address: row.address, blobHash: removes ? nil : try b.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(row)))
        }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: try b.workspaceHeader().workspaceID, records: records)
        let data = try NotebookStore.storageEncoder.encode(manifest)
        return NotebookDurableChange(sequence: 3, transactionID: manifest.transactionID, manifestHash: try b.currentSQL!.putBlob(data), byteCount: data.count)
      }
      #expect(throws: (any Error).self) { try b.applyRemoteChange(packet, peerID: actor) }
      #expect(try b.loadDocument(id) == before)
      #expect(try b.currentChangeCursor() == cursor)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == 2)
    }
  }

  private enum Fault: Error { case injected }

  @Test(arguments: ["bytes", "fragments"])
  func programBudgetRejectsBeforeDecodingTheFirstIncomingBody(kind: String) throws {
    try fixture { a, b, peer, id in
      let before = try b.loadDocument(id), file = documentFile(id), cursor = try b.currentChangeCursor()
      var source = before
      let initial: JSONValue = kind == "fragments" ? .object(["records": .array((0..<4097).map {
        .object(["id": .string("record-\($0)"), "value": .number(Double($0))])
      })]) : .number(3)
      let changed = source.replaceContent(preamble: "Must roll back", blocks: [.interactive(id: selected, html: "<p>Candidate</p>", initialState: initial)] + Array(before.blocks.dropFirst()), actor: peer)
      #expect(changed)
      let packet = try b.commandTransaction {
        let rows = try NotebookRecordCodec.encode(.encode(source), file: file)
        let records = try rows.map { row -> NotebookRecordMutation in
          let data: Data
          if row.collection == "blocks", row.member == selected {
            data = Data(repeating: 120, count: kind == "bytes" ? 16_777_217 : 1)
          } else { data = try NotebookStore.storageEncoder.encode(row) }
          return .init(address: row.address, blobHash: try b.currentSQL!.putBlob(data))
        }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: try b.workspaceHeader().workspaceID, records: records)
        let bytes = try NotebookStore.storageEncoder.encode(manifest)
        return NotebookDurableChange(sequence: 3, transactionID: manifest.transactionID,
          manifestHash: try b.currentSQL!.putBlob(bytes), byteCount: bytes.count)
      }
      #expect(throws: NotebookStorageError.limitExceeded("document_replication_block")) {
        try b.applyRemoteChange(packet, peerID: peer)
      }
      #expect(try b.loadDocument(id) == before)
      #expect(try b.currentChangeCursor() == cursor)
      #expect(try b.peerCursor(peerID: peer, direction: .incoming) == 2)
    }
  }

  @Test func anOldWireManifestCannotBeInterpretedAsACompleteProgramDeclaration() throws {
    try fixture { a, b, peer, id in
      let source = try changedSource(a, id, actor: peer, source: "<p>Not accepted as format 2</p>")
      try stage(source, a, b)
      let before = try b.loadDocument(id), cursor = try b.currentChangeCursor()
      let retired = try b.commandTransaction {
        let value = try JSONDecoder().decode(JSONValue.self, from: b.currentSQL!.blob(source.manifestHash))
          .setting("format", .number(2))
        let data = try NotebookStore.storageEncoder.encode(value)
        return NotebookDurableChange(sequence: source.sequence, transactionID: source.transactionID,
          manifestHash: try b.currentSQL!.putBlob(data), byteCount: data.count)
      }
      #expect(throws: NotebookStorageError.self) { try b.applyRemoteChange(retired, peerID: peer) }
      #expect(try b.loadDocument(id) == before)
      #expect(try b.currentChangeCursor() == cursor)
      #expect(try b.peerCursor(peerID: peer, direction: .incoming) == 2)
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func sourcePublicationAndIncomingCursorRecoverTogether(fault: NotebookStorageFault) throws {
    try fixture { a, b, actor, id in
      let packet = try changedSource(a, id, actor: actor, source: "<button>Committed</button>")
      try stage(packet, a, b)
      let cursor = try b.currentChangeCursor(), before = try b.loadDocument(id)
      let failing = NotebookStore(root: b.root) { point in
        if String(describing: point) == String(describing: fault) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.applyRemoteChange(packet, peerID: actor) }
      if case .afterCommit = fault {} else {
        #expect(try b.loadDocument(id) == before)
        #expect(try b.currentChangeCursor() == cursor)
        #expect(try b.peerCursor(peerID: actor, direction: .incoming) == 2)
      }
      _ = try b.applyRemoteChange(packet, peerID: actor)
      #expect(try b.loadDocument(id) == a.loadDocument(id))
      #expect(try b.currentChangeCursor() == cursor + 1)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == packet.sequence)
    }
  }
}
