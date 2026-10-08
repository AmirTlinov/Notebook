import Foundation
import Testing
@testable import NotebookCore

@Suite("First received acceptance owns its existing read cut", .serialized)
struct NotebookReceivedAcceptanceRevisionTests {
  private struct Fixture: Sendable {
    let origin: NotebookStore
    let replica: NotebookStore
    let source: NotebookReplicationSource
    let noOp: NotebookReplicationDelivery
    let winningSelection: SharedContextSelection
  }
  private struct Marker: Equatable, Sendable {
    let manifest: String
    let source: String
    let sequence: Int64
  }
  private struct State: Equatable, Sendable {
    let readRevision: UInt64
    let changeCursor: UInt64
    let sourceCursor: UInt64
    let marker: Marker?
    let selectionHash: String?
  }

  private func stage(_ delivery: NotebookReplicationDelivery, from origin: NotebookStore, to replica: NotebookStore) throws {
    while true {
      let missing = try replica.missingBlobHashes(for: delivery.change)
      if missing.isEmpty { return }
      for hash in missing {
        let size = try origin.blobSize(hash: hash)
        var bytes = Data()
        while Int64(bytes.count) < size {
          bytes += try origin.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
        }
        try replica.stageBlob(data: bytes, expectedHash: hash)
      }
    }
  }

  private func fixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("received-read-cut-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let origin = NotebookStore(root: root.appendingPathComponent("origin"))
    let replica = NotebookStore(root: root.appendingPathComponent("replica")), actor = UUID()
    let header = try origin.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let source = try origin.replicationSource(deviceID: actor)
    try replica.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try origin.changeJournal(after: 0) {
      try receiveFixtureChanges(.init(source: source, change: change), from: origin, to: replica)
    }
    let cursor = try origin.currentChangeCursor()
    let losing = SharedContextSelection(contextID: nil, stamp: .init(counter: 1, actor: actor))
    try origin.publishRecords(writes: ["collaboration/selection.json": .encode(losing)])
    let delivery = NotebookReplicationDelivery(source: source, change: try #require(origin.changeJournal(after: cursor).first))
    let winning = SharedContextSelection(contextID: nil, stamp: .init(counter: 2, actor: UUID()))
    try replica.publishRecords(writes: ["collaboration/selection.json": .encode(winning)])
    try stage(delivery, from: origin, to: replica)
    try body(.init(origin: origin, replica: replica, source: source, noOp: delivery, winningSelection: winning))
  }

  private func state(_ f: Fixture) throws -> State {
    try NotebookReadSession(store: f.replica).read { store in
      let database = try #require(store.currentSQL)
      let row = try database.rows("SELECT manifest_hash,peer_id,sequence FROM received_transactions WHERE transaction_id=?",
        [.text(f.noOp.change.transactionID.uuidString.lowercased())]).first
      let marker = try row.map { Marker(manifest: try #require($0[0].text), source: try #require($0[1].text),
        sequence: try #require($0[2].integer)) }
      return .init(readRevision: try store.currentReadCursor(), changeCursor: try store.currentChangeCursor(),
        sourceCursor: try store.incomingCursor(source: f.source), marker: marker,
        selectionHash: try database.rows("SELECT hash FROM records WHERE address='collaboration/selection.json#'").first?[0].text)
    }
  }

  /// Production nbread2 is issued/resumed inside a physically readonly session.
  private func read(_ store: NotebookStore, next: String? = nil) throws -> JSONValue {
    try NotebookReadSession(store: store).read { cut in
      #expect(cut.currentSQL?.writable == false)
      var query = NotebookReadQuery(kind: .itemHeaders, limit: 1); query.next = next
      var command = NotebookCommand(command: .read)
      command.queries = [query]; command.readSnapshots = true
      return try #require(try NotebookCommandDispatcher(store: cut).handle(command).array.first)
    }
  }

  private func acceptNoOp(_ f: Fixture, on store: NotebookStore? = nil) throws {
    let store = store ?? f.replica
    try store.commandTransaction(advancesReadRevision: false) {
      let sequence = try store.applyDelivery(f.noOp)
      let contentChanged = try store.transactionHasContentChanges()
      #expect(sequence == f.noOp.change.sequence)
      #expect(!contentChanged, "The losing peer version changes only accepted history")
    }
  }

  @Test func firstReceivedOnlyAcceptanceStalesContinuationAndKnownRetriesStayStable() throws {
    try fixture { f in
      let first = try read(f.replica), next = try #require(first["coverage"]?["next"]?.string)
      #expect(next.hasPrefix("nbread2:"))
      let before = try state(f)
      #expect(before.marker == nil && before.sourceCursor + 1 == f.noOp.change.sequence)
      try acceptNoOp(f)
      let accepted = try state(f)
      #expect(accepted.readRevision == before.readRevision + 1)
      #expect(accepted.sourceCursor == f.noOp.change.sequence)
      #expect(accepted.marker == .init(manifest: f.noOp.change.manifestHash, source: f.source.cursorKey,
        sequence: Int64(f.noOp.change.sequence)))
      #expect(accepted.changeCursor == before.changeCursor && accepted.selectionHash == before.selectionHash)
      #expect(try f.replica.storedValue("collaboration/selection.json")?.decode(SharedContextSelection.self) == f.winningSelection)
      do { _ = try read(f.replica, next: next); Issue.record("A received-only history change resumed an old read cut") }
      catch let error as CollaborationError { #expect(error.code == "read_cursor_stale") }
      let fresh = try read(f.replica), freshNext = try #require(fresh["coverage"]?["next"]?.string)
      #expect(fresh["data"] == first["data"] && fresh["basis"] == first["basis"])
      try acceptNoOp(f)
      #expect(try state(f) == accepted)
      // An already accepted transaction relayed through a new source advances
      // that source's ACK cursor, without minting another accepted occurrence.
      let relay = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
      let relayed = NotebookReplicationDelivery(source: relay, change: .init(sequence: 1,
        transactionID: f.noOp.change.transactionID, manifestHash: f.noOp.change.manifestHash, byteCount: f.noOp.change.byteCount))
      #expect(try f.replica.applyDelivery(relayed) == 1)
      #expect(try f.replica.incomingCursor(source: relay) == 1)
      #expect(try state(f) == accepted)
      #expect(try read(f.replica, next: freshNext)["cursor"] == fresh["cursor"])
    }
  }

  private enum Failure: Error, Sendable { case beforeCommit }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func firstAcceptanceFaultRollsBackMarkerCursorAndReadCut(phase: NotebookStorageFault) throws {
    try fixture { f in
      let before = try state(f), snapshot = try read(f.replica)
      let next = try #require(snapshot["coverage"]?["next"]?.string)
      let failing = NotebookStore(root: f.replica.root, storageFault: { point in
        if point == phase {
          // Verify the fault actually occurs after all acceptance writes, not
          // during staging or admission before the counterexample was reached.
          #expect(try f.replica.currentReadCursor() == before.readRevision + 1)
          #expect(try f.replica.incomingCursor(source: f.source) == f.noOp.change.sequence)
          #expect(try f.replica.currentSQL?.rows("SELECT manifest_hash FROM received_transactions WHERE transaction_id=?",
            [.text(f.noOp.change.transactionID.uuidString.lowercased())]).first?[0].text == f.noOp.change.manifestHash)
          throw Failure.beforeCommit
        }
      })
      #expect(throws: Failure.beforeCommit) { try acceptNoOp(f, on: failing) }
      #expect(try state(f) == before)
      #expect(try read(f.replica, next: next)["cursor"] == snapshot["cursor"])
      try acceptNoOp(f)
      #expect(try state(f).readRevision == before.readRevision + 1)
    }
  }

  @Test func exhaustedReadRevisionRefusesReceivedOnlyAcceptanceAtomically() throws {
    try fixture { f in
      try f.replica.commandTransaction(advancesReadRevision: false) {
        try f.replica.currentSQL!.run("UPDATE metadata SET value=? WHERE key='read_revision'", [.text(String(Int64.max))])
      }
      let before = try state(f)
      #expect(throws: NotebookStorageError.limitExceeded("read_revision")) { try acceptNoOp(f) }
      #expect(try state(f) == before)
      #expect(try f.replica.deliveryNeedsContent(f.noOp))
    }
  }

  @Test func materialDeliveryUsesTheSameSingleRevisionIncrement() throws {
    try fixture { f in
      try acceptNoOp(f)
      let cursor = try f.origin.currentChangeCursor()
      let newer = SharedContextSelection(contextID: nil, stamp: .init(counter: 3, actor: f.source.deviceID))
      try f.origin.publishRecords(writes: ["collaboration/selection.json": .encode(newer)])
      let delivery = NotebookReplicationDelivery(source: f.source, change: try #require(f.origin.changeJournal(after: cursor).first))
      try stage(delivery, from: f.origin, to: f.replica)
      let before = try state(f)
      try f.replica.commandTransaction(advancesReadRevision: false) {
        let sequence = try f.replica.applyDelivery(delivery)
        let contentChanged = try f.replica.transactionHasContentChanges()
        #expect(sequence == delivery.change.sequence)
        #expect(contentChanged)
      }
      let accepted = try state(f)
      #expect(accepted.readRevision == before.readRevision + 1)
      #expect(accepted.changeCursor == before.changeCursor + 1 && accepted.selectionHash != before.selectionHash)
      #expect(try f.replica.applyDelivery(delivery) == delivery.change.sequence)
      #expect(try state(f) == accepted)
    }
  }
}
