import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Spatial replication addresses one measured action", .serialized)
struct SpatialInkReplicationTests {
  private func fixture(_ body: (NotebookStore, NotebookStore, UUID, NotebookWorkspaceHeader) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-replication-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    try deliver(a.changeJournal(after: 0)[0], a, b, actor)
    try body(a, b, actor, header)
  }
  private func address(_ id: UUID) -> String { "spatial-ink.json#/actions/@" + id.uuidString.lowercased() }
  private func action(_ surface: SurfaceID, _ actor: UUID, counter: UInt64 = 1, id: UUID = UUID()) -> SpatialInkAction {
    .init(id: id, tool: .pen, spans: [.init(surface: surface, samples: [.init(point: .init(x: 1, y: 2),
      worldPoint: surface.kind == .board ? .init(x: 1, y: 2) : nil, timeOffset: 0, width: 2,
      opacity: 1, force: 1, azimuth: 0, altitude: 1)])], stamp: .init(counter: counter, actor: actor))
  }
  private func stage(_ change: NotebookDurableChange, _ a: NotebookStore, _ b: NotebookStore) throws {
    while true {
      let hashes = try b.missingBlobHashes(for: change)
      if hashes.isEmpty { return }
      for hash in hashes {
        let size = try a.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < size { data += try a.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try b.stageBlob(data: data, expectedHash: hash)
      }
    }
  }
  private func deliver(_ change: NotebookDurableChange, _ a: NotebookStore, _ b: NotebookStore, _ actor: UUID) throws {
    try stage(change, a, b)
    #expect(try b.applyRemoteChange(change, peerID: actor) == change.sequence)
  }

  @Test func appendStateAndOldEchoAmongOneHundredThousandActionsDoNotReadTheirBodies() throws {
    try fixture { a, b, actor, header in
      let clock = VersionStamp(counter: 100_000, actor: actor)
      var poisoned = "", kept = ""
      try b.commandTransaction {
        for index in 0..<100_000 {
          let stroke = action(.board(header.rootBoardID), actor, counter: UInt64(index + 1))
          for row in try NotebookRecordCodec.encode(.encode(SpatialInkJournal(actions: [stroke], stamp: clock)), file: "spatial-ink.json") where row.parent != nil {
            try b.writeFragment(row.replacing(value: row.value, position: row.collection == "actions" ? index : 0), database: b.currentSQL!)
          }
          if index == 50_000 { poisoned = address(stroke.id) }
          if index == 75_000 { kept = address(stroke.id) }
        }
        let root = try #require(try b.storedFragments(address: "spatial-ink.json#", descendants: false).first)
        try b.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: b.currentSQL!)
      }
      try b.commandTransaction {
        let hash = try b.currentSQL!.putBlob(Data("An unrelated action must not be decoded".utf8))
        try b.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(poisoned)])
      }
      let beforeKept = try b.storedFragments(address: kept), before = try b.currentChangeCursor()
      let stroke = action(.board(header.rootBoardID), actor)
      _ = try a.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp))
      let appended = try a.changeJournal(after: 1)[0]
      try stage(appended, a, b)
      try bounded(b) { _ = try b.applyRemoteChange(appended, peerID: actor) }
      let originalRows = try b.storedFragments(address: address(stroke.id))
      let state = VersionStamp(counter: 2, actor: actor)
      _ = try a.commitSpatialInk(.state(actionID: stroke.id, creationStamp: stroke.stamp, isActive: false, stateStamp: state, journalStamp: state))
      let undo = try a.changeJournal(after: 2)[0]
      try stage(undo, a, b)
      try bounded(b) { _ = try b.applyRemoteChange(undo, peerID: actor) }
      let after = try b.currentChangeCursor()
      try bounded(b) { _ = try b.applyRemoteChange(undo, peerID: actor) }
      let relayed = NotebookDurableChange(sequence: 1, transactionID: appended.transactionID, manifestHash: appended.manifestHash, byteCount: appended.byteCount)
      try bounded(b) { _ = try b.applyRemoteChange(relayed, peerID: UUID()) }
      #expect(try b.currentChangeCursor() == after && after == before + 2)
      let rows = try b.storedFragments(address: address(stroke.id))
      #expect(try !NotebookRecordCodec.decode(rows, root: address(stroke.id)).decode(SpatialInkAction.self).isActive)
      #expect(rows.first { $0.collection == "spans" } == originalRows.first { $0.collection == "spans" })
      #expect(try b.storedFragments(address: kept) == beforeKept)
      #expect(try b.workspaceHeader().spatialInkStamp == clock)
    }
  }

  @Test(arguments: ["spans", "header", "state", "removal", "root"])
  func conflictingPacketRollsBackHistoryReceiptAndCursor(kind: String) throws {
    try fixture { a, b, actor, header in
      let stroke = action(.board(header.rootBoardID), actor)
      _ = try a.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp))
      try deliver(a.changeJournal(after: 1)[0], a, b, actor)
      let before = try b.currentChangeCursor(), kept = try b.storedFragments(address: address(stroke.id))
      let question = try a.appendContext(references: [], author: .human, actor: actor, text: "Must roll back with invalid ink")
      var value = try JSONValue.encode(SpatialInkJournal(actions: [stroke], stamp: stroke.stamp))
      if kind == "root" { value = value.setting("format", .number(99)) }
      if ["spans", "header", "state"].contains(kind) {
        var changed = try JSONValue.encode(stroke)
        if kind == "header" { changed = changed.setting("tool", .string("eraser")) }
        if kind == "state" { changed = changed.setting("isActive", .bool(false)) }
        if kind == "spans" {
          let altered = SpatialInkSpan(surface: .board(header.rootBoardID), samples: [.init(point: .init(x: 90, y: 20),
            worldPoint: .init(x: 90, y: 20), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
          changed = changed.setting("spans", try .encode([altered]))
        }
        value = value.setting("actions", .array([changed]))
      }
      // A valid local writer already refuses immutable sample edits. Construct
      // the hostile wire manifest, not an invalid canonical source archive.
      let fragments = try NotebookRecordCodec.encode(value, file: "spatial-ink.json")
        + a.storedFragments(address: a.contextFile(question.id) + "#")
      let transaction = UUID()
      let change = try b.commandTransaction {
        let records: [NotebookRecordMutation] = try fragments.map { fragment in
          if kind == "removal", fragment.parent != nil, fragment.file == "spatial-ink.json" {
            return .init(address: fragment.address, blobHash: nil)
          }
          let hash = try b.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(fragment))
          return .init(address: fragment.address, blobHash: hash)
        }
        let manifest = NotebookChangeManifest(transactionID: transaction, workspaceID: header.workspaceID, records: records)
        let bytes = try NotebookStore.storageEncoder.encode(manifest), hash = try b.currentSQL!.putBlob(bytes)
        return NotebookDurableChange(sequence: 3, transactionID: transaction, manifestHash: hash, byteCount: bytes.count)
      }
      do { _ = try b.applyRemoteChange(change, peerID: actor); Issue.record("An invalid spatial packet was accepted") }
      catch is NotebookStorageError { }
      #expect(try b.currentChangeCursor() == before)
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == 2)
      #expect(try b.storedFragments(address: address(stroke.id)) == kept)
      #expect(try b.sharedContextEntry(contextID: question.id, entryID: question.entry.id) == nil)
    }
  }

  @Test func deliveredHistoricalInkDoesNotRecreateADeletedCoverOrAuthorizeNewContacts() throws {
    try fixture { a, b, actor, header in
      let deleted = try #require(try a.readItemHeaders(limit: 1).first?.id)
      let before = try b.loadIndex(), boardBefore = try b.loadBoard(items: before.items)
      var workspace = before, hierarchy = boardBefore
      let created = workspace.createNotebook(title: "Retained", actor: actor, pageSize: .init(width: 834, height: 1194))
      let replacement = try #require(created)
      let added = hierarchy.addItem(replacement.item.id, to: header.rootBoardID, near: .init(x: 2000, y: 0), actor: actor)
      #expect(added)
      _ = try b.saveWorkspaceEdits(before: before, after: workspace, boardBefore: boardBefore,
        boardAfter: hierarchy, pages: [replacement.page])
      _ = try b.deleteWorkspaceItem(itemID: deleted, actor: actor)
      let stroke = action(.cover(deleted), actor)
      _ = try a.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp))
      try deliver(a.changeJournal(after: 1)[0], a, b, actor)
      #expect(try b.readItemHeader(deleted) == nil)
      #expect(try b.storedFragments(address: address(stroke.id)).count == 2)
      let newContact = action(.cover(deleted), actor, counter: 2)
      do { _ = try b.commitSpatialInk(.append(newContact, journalStamp: newContact.stamp)); Issue.record("Missing cover accepted a new local contact") }
      catch let error as CollaborationError { #expect(error.code == "target_missing") }
    }
  }

  @Test func independentOldStateAndSeveralManifestPagesConvergeWithoutRenumbering() throws {
    try fixture { a, b, actor, header in
      let strokes = (1...131).map { action(.board(header.rootBoardID), actor, counter: UInt64($0)) }
      try a.commandTransaction {
        for stroke in strokes { _ = try a.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp)) }
      }
      try deliver(a.changeJournal(after: 1)[0], a, b, actor)
      #expect(try a.loadSpatialInk() == b.loadSpatialInk())
      let old = try b.storedFragments(address: address(strokes[0].id))
      let state = VersionStamp(counter: 132, actor: actor)
      _ = try a.commitSpatialInk(.state(actionID: strokes[0].id, creationStamp: strokes[0].stamp,
        isActive: false, stateStamp: state, journalStamp: state))
      try deliver(a.changeJournal(after: 2)[0], a, b, actor)
      let kept = try b.storedFragments(address: address(strokes[1].id)), cursor = try b.currentChangeCursor()
      let root = try NotebookRecordCodec.encode(.encode(SpatialInkJournal(stamp: strokes[0].stamp)), file: "spatial-ink.json").first!
      let change = try b.commandTransaction {
        let records: [NotebookRecordMutation] = try ([root] + old).map { fragment in
          .init(address: fragment.address, blobHash: try b.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(fragment)))
        }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: header.workspaceID, records: records)
        let bytes = try NotebookStore.storageEncoder.encode(manifest), hash = try b.currentSQL!.putBlob(bytes)
        return NotebookDurableChange(sequence: 1, transactionID: manifest.transactionID, manifestHash: hash, byteCount: bytes.count)
      }
      #expect(try b.applyRemoteChange(change, peerID: UUID()) == 1)
      #expect(try b.currentChangeCursor() == cursor)
      #expect(try a.loadSpatialInk() == b.loadSpatialInk())
      #expect(try b.storedFragments(address: address(strokes[1].id)) == kept)
    }
  }

  private enum DiskFailure: Error { case injected }
  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func interruptedPublicationAndLostAcknowledgementKeepOneDurableAction(fault: NotebookStorageFault) throws {
    try fixture { a, b, actor, header in
      let stroke = action(.board(header.rootBoardID), actor)
      _ = try a.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp))
      let change = try a.changeJournal(after: 1)[0]
      try stage(change, a, b)
      let before = try b.currentChangeCursor()
      let failing = NotebookStore(root: b.root) { phase in
        if String(describing: phase) == String(describing: fault) { throw DiskFailure.injected }
      }
      do { _ = try failing.applyRemoteChange(change, peerID: actor); Issue.record("Injected failure was not observed") }
      catch is DiskFailure { }
      let committed = String(describing: fault) == String(describing: NotebookStorageFault.afterCommit)
      #expect(try b.currentChangeCursor() == before + (committed ? 1 : 0))
      #expect(try b.peerCursor(peerID: actor, direction: .incoming) == (committed ? 2 : 1))
      #expect(try b.storedFragments(address: address(stroke.id)).count == (committed ? 2 : 0))
      #expect(try b.applyRemoteChange(change, peerID: actor) == 2)
      #expect(try b.currentChangeCursor() == before + 1)
      #expect(try b.loadSpatialInk().actions == [stroke])
    }
  }

  private final class Counter { var steps = 0 }
  private func bounded(_ store: NotebookStore, _ body: () throws -> Void) throws {
    let counter = Counter()
    try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let value = Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue()
          value.steps += 1; return value.steps < 200_000 ? 0 : 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        try body()
      }
    }
    #expect(counter.steps > 0 && counter.steps < 200_000)
    print("SPATIAL_REPLICATION foreign_actions=100000 vm=\(counter.steps)")
  }
}
